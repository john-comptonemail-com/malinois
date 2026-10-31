// Trip coordination owned by MonitoringTripResponder.
import Foundation
import UIKit
import OSLog

extension MonitoringTripResponder {

    /// Pure (unit-tested): is a per-sensor recent trip count high enough to be a flood?
    nonisolated static func isFloodCount(_ count: Int) -> Bool { count > floodTripThreshold }

    /// The flood anchor as the store holds it now, or the engine's copy if the store has lost
    /// it. Item 95: the copy taken at the onset, written back whole at the next coalesced
    /// trip, erased a photo item 54's retry had attached to the record meanwhile, and its
    /// flood-end push was refused as older than the retry's.
    private func storedAnchor(_ held: Event) -> Event {
        eventStore.events.first { $0.id == held.id } ?? held
    }

    /// Called by sensor monitors and by the touch overlay.
    func handleTrip(_ sensor: SensorType) {
        // Test Sensors mode: record the would-trip for the UI to flash and re-arm
        // the monitor so it can fire again — never create an event.
        if host?.tripConsumeDryRun(sensor) == true { return }
        if sensor == .motion { host?.tripNoteMotion(at: Date()) }   // movement → not stationary
        // During an "until clear" recording, trips just refresh the activity
        // clock — and keep any alert/siren alive while tampering continues.
        if capturePipeline.isCapturingUntilClear {
            capturePipeline.noteActivity()
            tripsDuringCapture[armSession, default: []].insert(sensor)   // on the record, not just in the clip's length (item 54)
            extendAlertWindow()
            return
        }
        // A trip while a photo or fixed clip is already being captured (34-review M1):
        // record it for the in-flight event instead of dropping it, and keep a running
        // alert alive — exactly what until-clear trips do above. The capture already running
        // IS the response; the record must still show every sensor that fired.
        if state == .triggered {
            tripsDuringCapture[armSession, default: []].insert(sensor)
            extendAlertWindow()
            return
        }
        // Handle trips while armed, and also during the brief calibration review —
        // the sensors are live then (see startWatching), so a tamper in that window
        // must still fire (fireTrigger ends the review and goes covert first).
        // NOTE: detection deliberately does NOT stop during disarm PIN entry — only the
        // presentation (flash/alert) is suppressed (see the capture host's `mayFlashScreen` / respond).
        // Suppressing detection here would make a hold on the screen a kill switch.
        guard state == .armed || (state == .calibrating && showingCalibrationReview) else { return }
        recentTrips[sensor] = Date()
        latchedSensors.insert(sensor)
        recordFloodTrip(sensor)
        pruneStaleTrips()
        if shouldTrigger() { fireTrigger() }
    }

    /// Pure (unit-tested): an event's sensor list with capture-window trips folded in —
    /// deduplicated, sorted like every other sensor list, existing entries never removed.
    nonisolated static func foldedSensors(_ current: [SensorType],
                                          adding trips: Set<SensorType>) -> [SensorType] {
        let added = trips.subtracting(current)
        guard !added.isEmpty else { return current }
        return (current + added).sorted { $0.rawValue < $1.rawValue }
    }

    /// Pure (unit-tested): whether a cadence capture (blackout / flood) may use the camera
    /// right now. The trigger response owns the pipeline outright (34.H10; ADR 0003), and
    /// cadence captures also exclude EACH OTHER — a blackout escalating during a flood is
    /// exactly when both would otherwise fire together, reconfiguring the session out from
    /// under one another. Cadence captures are the expendable side: skip them when busy,
    /// never the trigger's capture.
    nonisolated static func mayRunCadenceCapture(handlingTrigger: Bool,
                                                 capturingUntilClear: Bool,
                                                 cadenceBusy: Bool) -> Bool {
        !handlingTrigger && !capturingUntilClear && !cadenceBusy
    }

    /// The capture session's life, as the camera reports it (item 54; absorbs 32.R9). An
    /// interruption is surfaced while it lasts; its end re-warms the camera per the readiness
    /// policy and takes the one bounded retry; a runtime error — a session killed under the
    /// engine, which used to stay down and unlogged until the next trigger — is recorded as
    /// an audit event, surfaced, and re-warmed. Never on the trigger hot path: a capture that
    /// owns the camera is left alone, and the retry yields to it.
    func handleCameraSessionEvent(_ event: CameraSessionEvent) {
        switch event {
        case .interrupted(let reason):
            Log.engine.warning("Camera session interrupted: \(reason.rawValue, privacy: .public)")
            lastInterruption = (reason, Date())   // an attempt in flight may be its casualty (item 65, finding 2)
            captureRetry?.interruptionEnded = false   // a newer interruption postpones the same slot
            guard state.isActive else { return }
            host?.tripSetCameraNotice(Self.interruptionNotice(reason))
            interruptionNoticeShowing = true
        case .interruptionEnded:
            Log.engine.info("Camera session interruption ended")
            lastInterruptionEndedAt = Date()
            captureRetry?.interruptionEnded = true
            scheduleInterruptedCaptureRetry()
            if interruptionNoticeShowing {
                host?.tripSetCameraNotice(nil)
                interruptionNoticeShowing = false
            }
            guard state == .armed else { return }
            if cameraShouldBeWarm && !isHandlingTrigger { warmActiveCamera() }
        case .runtimeError(let description):
            Log.engine.error("Camera session runtime error: \(description, privacy: .public)")
            guard state.isActive else { return }
            let now = Date()
            if let last = lastCameraRuntimeErrorAt, now.timeIntervalSince(last) < timing.cameraErrorDebounce { return }
            lastCameraRuntimeErrorAt = now
            host?.tripSetCameraNotice("The camera session failed (\(description)) - it restarts at the next capture.")
            host?.tripLogCameraError()
            if state == .armed && cameraShouldBeWarm && !isHandlingTrigger { warmActiveCamera() }
        }
    }

    /// Saves one original capture and attaches only files that reached storage. A missing
    /// capture is classified by the pipeline; false specifically means a storage failure.
    private func storeInitialCapture(_ capture: EvidenceCapturePipeline.Capture?, secondary: Bool,
                                     in event: inout Event) async -> Bool {
        guard let capture else { return true }
        guard let stored = await eventStore.store(capture.source, ext: capture.ext,
                attachingTo: event, secondary: secondary, camera: capture.camera.rawValue,
                duration: capture.ext == "mov" ? capture.duration : nil, captureIssue: capture.issue?.rawValue) else {
            report(cameraNotice: "A capture could not be saved - see the event for details.")
            return false
        }
        #if DEBUG
        await captureStoredForTesting?(event.id)
        #endif
        event.recordCaptureIssue(capture.issue, camera: capture.camera.rawValue)
        if secondary {
            event.secondaryMediaFilename = stored.filename
            event.secondaryCamera = capture.camera.rawValue
            if capture.ext == "mov" { event.secondaryDuration = capture.duration }
        } else {
            event.mediaFilename = stored.filename
            event.primaryCamera = capture.camera.rawValue
            event.thumbnailData = stored.thumbnail
            if capture.ext == "mov" { event.primaryDuration = capture.duration }
        }
        return true
    }

    /// Item 54's one bounded retry: after an interruption ends, the capture that failed for
    /// it gets a single still — if the session is still armed, the event is recent and still
    /// without media, and no other capture owns the camera. Busy captures preserve the slot
    /// until their release; an expired, disabled or ended watch discards it. The slot is
    /// cleared BEFORE the eligible attempt: one try, whatever happens, never a loop.
    /// The record keeps its reason either way; a photo that lands is labelled as the second
    /// attempt in the detail view. The photo joins the record as it is when the photo lands,
    /// not as it was before the capture: a
    /// flood's anchor gains coalesced trips meanwhile, and writing back the earlier copy walked
    /// them back (item 95).
    private func retryInterruptedCapture() async {
        guard let retry = captureRetry else { return }
        guard retry.session == armSession, state == .armed || state == .triggered,
              settings.isEnabled(.camera),
              Date().timeIntervalSince(retry.failedAt) <= timing.captureRetryWindow,
              let before = eventStore.events.first(where: { $0.id == retry.eventID }),
              before.mediaFilename == nil, before.secondaryMediaFilename == nil else {
            captureRetry = nil
            return
        }
        guard retry.interruptionEnded, state == .armed, !capturePipeline.isBusy,
              Self.mayRunCadenceCapture(handlingTrigger: isHandlingTrigger,
                                        capturingUntilClear: isCapturingUntilClear,
                                        cadenceBusy: cadenceCaptureBusy) else { return }
        // No suspension between claiming the slot and claiming the camera: duplicate
        // notifications and release callbacks can spend this opportunity only once.
        captureRetry = nil
        cadenceCaptureBusy = true
        defer { cadenceCaptureBusy = false }
        let outcome = await capturePipeline.capture(from: retry.camera, mode: .photo,
                                                    illumination: settings.illumination, preservation: .init(event: before, store: eventStore))
        defer {
            // A capture already started may still preserve evidence after disarm, but its
            // completion must not stand down the camera belonging to a replacement watch.
            if retry.session == armSession { standDownCameraIfNeeded() }
        }
        guard let cap = outcome.capture, let stored = await eventStore.store(cap.source, ext: cap.ext,
                attachingTo: before, camera: cap.camera.rawValue) else {
            Log.engine.warning("Retry capture after the interruption failed too — the record keeps its reason")
            return
        }
        var event = eventStore.events.first { $0.id == retry.eventID } ?? before   // as it is now (item 95)
        event.mediaFilename = stored.filename
        event.primaryCamera = cap.camera.rawValue
        event.thumbnailData = stored.thumbnail
        // The record was `.synced` without media (its meta had landed, there was nothing else to
        // send); it now carries a photo the cloud copy lacks, so reopen it — or a failed upload
        // here would never be retried (item 65, finding 3) — in the same write (item 155's S1).
        eventStore.updateAndReopenForReupload(event)
        let merged = eventStore.events.first { $0.id == event.id } ?? event
        exfiltrateInBackground(merged, cloudAllowedOverride: retry.cloudAllowed)
    }

    /// Pure (unit-tested; item 65, finding 2). A shot that failed with no interruption live at
    /// the end of the attempt is still an interruption's casualty when one began during it — a
    /// short "another app took the camera" that ends before the doomed attempt does — and the
    /// record should carry the system's reason, not "the camera failed while capturing".
    nonisolated static func reclassifiedCaptureFailure(_ failure: CaptureFailureReason?,
                                                       attemptStartedAt: Date,
                                                       interruptedAt: Date?,
                                                       reason: CaptureInterruptionReason?) -> CaptureFailureReason? {
        guard failure == .captureFailed, let interruptedAt, let reason,
              interruptedAt >= attemptStartedAt else { return failure }
        return CaptureFailureReason.forCaptureFailure(interruption: reason)
    }

    private func pruneStaleTrips() {
        let cutoff = Date().addingTimeInterval(-correlationWindow)
        recentTrips = recentTrips.filter { $0.value >= cutoff }
    }

    func startRefractorySweep() {
        refractoryTimer?.invalidate()
        refractoryTimer = Timer.commonMode(interval: refractorySweepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let host = self.host else { return }
                let lifetime = FiniteWorkLifetime(owner: host)
                defer { lifetime.keepAlive() }
                self.refractorySweep()
            }
        }
    }

    /// Re-arms any sensor whose trip has aged past the correlation window without firing, so
    /// a one-shot monitor can't stay latched forever and go silently deaf. A backstop: every
    /// latch path today reaches `reArm()` (a trigger's response, the flood path) and a trip
    /// during a capture never latches, so no current path needs it. It stays against a future
    /// path that forgets (see `latchedSensors`, F-15).
    private func refractorySweep() {
        guard state == .armed else { return }   // never during capture / until-clear
        let due = Self.refractoryDueSensors(latched: latchedSensors,
                                            trips: recentTrips,
                                            now: Date(),
                                            window: correlationWindow)
        for sensor in due {
            host?.tripRearmSensor(sensor)
            latchedSensors.remove(sensor)
            recentTrips[sensor] = nil
        }
    }

    /// Pure: of the latched sensors, which have aged past `window` since their last
    /// trip (or have no recorded trip at all) and are therefore due to be re-armed.
    /// The single source of truth for the refractory decision (unit-tested).
    static func refractoryDueSensors(latched: Set<SensorType>,
                                     trips: [SensorType: Date],
                                     now: Date,
                                     window: TimeInterval) -> Set<SensorType> {
        Set(latched.filter { sensor in
            let age = trips[sensor].map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            return age >= window
        })
    }

    private func shouldTrigger() -> Bool {
        settings.triggerMode.shouldFire(for: Set(recentTrips.keys))
    }

    private func fireTrigger() {
        guard !isHandlingTrigger else { return }
        // A tamper during the calibration review: end the review and go covert now,
        // then handle the trigger as usual (state moves calibrating → armed → triggered).
        if showingCalibrationReview { goCovert() }
        let triggered = Array(recentTrips.keys)
        // Record the trigger BEFORE the flood check, so the aggregate rate reflects every
        // trigger attempt — including the ones already being coalesced (F3). Otherwise the
        // count would stall the moment coalescing began and immediately fall back out.
        recentTriggerTimes.append(Date())
        // A sensor being flooded (a motor on the table leg, a loop of noise) shouldn't
        // spin up a full capture + event + upload for every trip — coalesce instead.
        if isFlooding(triggered) {
            handleFloodTrigger(triggered)
            return
        }
        isHandlingTrigger = true
        host?.tripEnterTriggeredState()
        tripsDuringCapture[armSession] = nil   // fresh window for this capture (M1)
        wrongPINsDuringCapture[armSession] = nil
        let startDate = recentTrips.values.min() ?? Date()
        host?.tripStampTrigger(at: Date())
        let session = armSession

        let lifetime = retainHostForFiniteWork()
        Task { defer { lifetime.keepAlive() }; await respond(triggeredSensors: triggered, startDate: startDate, session: session) }
    }

    private func recordFloodTrip(_ sensor: SensorType) {
        let cutoff = Date().addingTimeInterval(-floodWindow)
        var times = (sensorTripTimes[sensor] ?? []).filter { $0 >= cutoff }
        times.append(Date())
        sensorTripTimes[sensor] = times
    }

    private func isFlooding(_ sensors: [SensorType]) -> Bool {
        let cutoff = Date().addingTimeInterval(-floodWindow)
        // Per-sensor: one sensor being hammered (a motor against the table leg).
        if sensors.contains(where: { Self.isFloodCount((sensorTripTimes[$0] ?? []).filter { $0 >= cutoff }.count) }) {
            return true
        }
        // Aggregate: an attacker can stay under the per-sensor bar by alternating sources
        // (a motor AND a speaker at ~8/min each), and every one of those trips would then
        // become an ordinary event — indistinguishable from real evidence at prune time,
        // quietly pushing genuine events past the retention caps (F3). So also flood on the
        // overall *trigger* rate. Counting triggers (not raw sensor trips) is what makes
        // this safe: a genuine tamper that fires motion + touch + proximity together is
        // still ONE trigger, so a real burglary can't be misread as synthetic noise.
        recentTriggerTimes = recentTriggerTimes.filter { $0 >= cutoff }
        return Self.isAggregateFlood(recentTriggerTimes.count)
    }

    nonisolated static func isAggregateFlood(_ triggerCount: Int) -> Bool {
        triggerCount > aggregateFloodThreshold
    }

    private func handleFloodTrigger(_ sensors: [SensorType]) {
        // Abandon stealth — it's an attack — but only once the record exists: here the anchor
        // is the record; at the onset, `respond` escalates right after it writes the onset
        // record (evidence precedes response; item 65, finding 16).
        if sustainedEvent != nil, settings.jammingResponse { host?.tripEscalateFlood() }
        if let held = sustainedEvent {
            // A running alarm stays up while the flood goes on (item 152's lead 5; the owner's ruling (a)): with "Alarm
            // on suspected attack" off nothing else extended it, and it went quiet one window in. Extend only: a faded
            // alarm is not started again, and Stealth has none.
            host?.tripExtendConfiguredFloodAlert()
            // Coalesce log spam, NOT evidence. Extend the one counter event, and still
            // capture on a bounded cadence so sustained real tampering keeps being shot.
            var ev = storedAnchor(held)   // the record as it is now, never the onset's copy (item 95)
            ev.endDate = Date()
            ev.sustainedCount = (ev.sustainedCount ?? 1) + 1
            // Fold in any newly-triggered sensors so the record shows every sensor
            // that fired during the flood, not just the first.
            let added = Set(sensors).subtracting(ev.triggeredSensors)
            if !added.isEmpty {
                ev.triggeredSensors = (ev.triggeredSensors + added).sorted { $0.rawValue < $1.rawValue }
            }
            sustainedEvent = ev
            // Throttle the DISK write, not the count (F2): every coalesced trip used to
            // rewrite the entire log — ~20 whole-log encodes per second under a 20 Hz motor
            // flood, the one per-trip cost coalescing forgot to remove. Disk lags at most
            // ~2 s; the sustained-clear timer flushes the final count.
            let persistDue = Date().timeIntervalSince(lastFloodPersist ?? .distantPast) >= 2
            if persistDue { lastFloodPersist = Date() }
            eventStore.update(ev, persistNow: persistDue)
            scheduleSustainedClear()
            // Keep the cloud copy's count/endDate roughly current so a device taken
            // mid-flood doesn't leave iCloud showing only the onset (R-07). Every 10th
            // trip, not every one — the meta record is a cheap upsert but not free.
            if (ev.sustainedCount ?? 0).isMultiple(of: 10) {
                let snapshot = ev
                pushFactIfCloud(snapshot)
            }
            if Date().timeIntervalSince(lastFloodCapture ?? .distantPast) >= floodCaptureInterval {
                lastFloodCapture = Date()
                let lifetime = retainHostForFiniteWork()
                Task { defer { lifetime.keepAlive() }; await captureFloodEvidence(sensors) }   // photo-only, rate-limited
            }
            reArm()
        } else {
            // Flood onset: full capture for the record, mark it as the sustained event.
            isHandlingTrigger = true
            host?.tripEnterTriggeredState()
            tripsDuringCapture[armSession] = nil   // fresh window for this capture (M1)
            wrongPINsDuringCapture[armSession] = nil
            let startDate = recentTrips.values.min() ?? Date()
            host?.tripStampTrigger(at: Date())
            let session = armSession
            lastFloodCapture = Date()   // onset capture resets the cadence clock
            // The idle-clear is scheduled by `respond` when the anchor is installed — not here,
            // before it exists (item 65, finding 11).
            let lifetime = retainHostForFiniteWork()
            Task { defer { lifetime.keepAlive() }; await respond(triggeredSensors: sensors, startDate: startDate, session: session, sustained: true) }
        }
    }

    /// A bounded, photo-only evidence capture taken during a flood (F-02). Keeps
    /// sustained real tampering photographed without the per-trip cost that made
    /// coalescing stop capture entirely. Mirrors captureBlackoutEvidence.
    /// Builds the record for a flood-cadence still.
    ///
    /// Extracted as a pure function purely so the flood marker is pinned by a test. Its
    /// absence was a real defect: these stills carried no `sustainedCount`, so both prune
    /// passes (`EventStore.pruneToCountCap` and `mediaEvictionOrder`, which classify on
    /// `sustainedCount != nil`) counted them as genuine. One still per `floodCaptureInterval`
    /// then filled `maxEvents` in under three hours and began evicting real events
    /// oldest-first, starting with "Monitoring armed" — precisely the eviction the coalescing
    /// exists to prevent. The marker is invisible in the UI (the detail label only renders
    /// "sustained ×n" for n > 1), so nothing else would catch its removal.
    ///
    /// The trade is deliberate: a genuine attack never runs long enough to reach the cap,
    /// whereas a vibrating desk does — so flood stills are the right thing to shed first.
    nonisolated static func makeFloodEvidenceEvent(sensors: [SensorType],
                                                   motionTrace: [Double],
                                                   audioTrace: [Double],
                                                   visionTrace: [Double]?,
                                                   offline: Bool,
                                                   now: Date = Date()) -> Event {
        Event(startDate: now, endDate: now,
              triggeredSensors: sensors.sorted { $0.rawValue < $1.rawValue },
              motionTrace: motionTrace,
              audioTrace: audioTrace,
              visionTrace: visionTrace,
              cloudSyncState: .pending,
              capturedOffline: offline,
              sustainedCount: 1)
    }

    func captureFloodEvidence(_ sensors: [SensorType]) async {
        let session = armSession
        guard settings.isEnabled(.camera) else { return }
        // A trigger or blackout capture owns the camera (34.H10; ADR 0003): this is a
        // rate-limited EXTRA still, and the flood's sustained event already records the
        // activity — skip, don't queue.
        guard Self.mayRunCadenceCapture(handlingTrigger: isHandlingTrigger,
                                        capturingUntilClear: isCapturingUntilClear,
                                        cadenceBusy: cadenceCaptureBusy) else {
            Log.engine.info("Flood-cadence still skipped — another capture owns the camera")
            return
        }
        cadenceCaptureBusy = true
        defer { cadenceCaptureBusy = false }
        var event = Self.makeFloodEvidenceEvent(
            sensors: sensors,
            motionTrace: host?.tripRecentTrace(for: .motion) ?? [],
            audioTrace: host?.tripRecentTrace(for: .audio) ?? [],
            visionTrace: host?.tripRecentTrace(for: .vision),
            offline: !connectivity.isOnline)
        cloudCoordinator.registerLocalEvent(event)
        beginBindingUse(event.id)   // through the capture, until the upload has it (codex-6 on 0ed887f)
        defer { endBindingUse(event.id) }
        eventStore.add(event)
        host?.tripPublishEventCount(eventStore.events.count)
        let fact = event
        pushFactIfCloud(fact)
        // Authorization decided with the record, before the capture (sixth-review F3).
        let sessionAllowed = cloudAllowed
        let cam: CameraChoice
        switch effectiveCameraPosition {
        case .rear: cam = .rear
        case .auto: cam = resolveAutoCamera()
        default:    cam = .front   // front / both → one grab is enough here
        }
        let outcome = await capturePipeline.capture(from: cam, mode: .photo, illumination: settings.illumination, preservation: .init(event: event, store: eventStore))
        if let cap = outcome.capture, let stored = await eventStore.store(cap.source, ext: cap.ext,
                    attachingTo: event, camera: cap.camera.rawValue) {
            event.mediaFilename = stored.filename
            event.primaryCamera = cam.rawValue
            event.thumbnailData = stored.thumbnail
        } else {
            event.captureFailure = (outcome.failure ?? .storageFailed).rawValue   // the why, on the record (54)
        }
        event.endDate = Date()
        eventStore.updateAndReopenForReupload(event)   // the same for the flood capture (item 155's A1), in one write (S1)
        #if DEBUG
        await captureStoredForTesting?(event.id)
        #endif
        // Re-read the stored copy (sixth-review F2) and push under the creation-time
        // authorization (sixth-review F3).
        let ev = eventStore.events.first { $0.id == event.id } ?? event
        exfiltrateInBackground(ev, cloudAllowedOverride: sessionAllowed)
        if session == armSession { standDownCameraIfNeeded() }
    }

    private func scheduleSustainedClear() {
        sustainedClearTimer?.invalidate()
        sustainedClearTimer = Timer.commonMode(interval: sustainedIdleClear, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let host = self.host else { return }
                let lifetime = FiniteWorkLifetime(owner: host)
                defer { lifetime.keepAlive() }
                self.eventStore.flush()   // capture the final coalesced count on disk (F2)
                // The cloud only heard every 10th count (and the post-capture rich push
                // carries the onset-time snapshot), so without this the record — and every
                // mirror — ended at the last multiple of ten, or at 1 for a short flood,
                // while this device showed the true ×n (the build-25 pair finding). One
                // final push seals the coalesced state; the supersede rule's equal-revision
                // higher-count arm is what lets an already-fetched mirror accept it.
                if let held = self.sustainedEvent {
                    let final = self.storedAnchor(held)
                    self.pushFactIfCloud(final)   // the stored record, with anything added since (item 95)
                }
                self.sustainedEvent = nil
                self.lastFloodCapture = nil
                self.lastFloodPersist = nil
            }
        }
    }

    /// `wrongPIN`: the response to a wrong disarm PIN (item 49) — the record carries the attempt,
    /// and the capture is one front still whatever the settings say.
    func respond(triggeredSensors: [SensorType], startDate: Date, session: Int,
                 sustained: Bool = false, wrongPIN: Bool = false) async {
        // 1. Record the event IMMEDIATELY (metadata + traces), before touching the
        //    camera — so a tamper is always logged even if capture is slow or fails.
        var event = Event(
            startDate: startDate,
            endDate: Date(),
            triggeredSensors: triggeredSensors.sorted { $0.rawValue < $1.rawValue },
            motionTrace: host?.tripRecentTrace(for: .motion) ?? [],
            audioTrace: host?.tripRecentTrace(for: .audio) ?? [],
            visionTrace: host?.tripRecentTrace(for: .vision),
            cloudSyncState: .pending,
            capturedOffline: !connectivity.isOnline,
            sustainedCount: sustained ? 1 : nil,
            wrongPINCount: wrongPIN ? 1 : nil,
            thermalState: MonitoringEngine.thermalStateName(thermalState()))   // item 38, choice 3
        cloudCoordinator.registerLocalEvent(event)
        beginBindingUse(event.id)   // through the capture, until the upload has it (codex-6 on 0ed887f)
        defer { endBindingUse(event.id) }
        eventStore.add(event)
        host?.tripPublishEventCount(eventStore.events.count)
        // Captured during the owner's disarm flow (from the hold press-down through PIN
        // entry): remember it, so a successful PIN can retroactively attribute it to the
        // owner instead of leaving self-disarm spam (R-02).
        host?.tripNoteCandidateEvent(event.id)
        // Flood onset: abandon stealth — it's an attack — now that the onset record is in the
        // log (evidence precedes response; item 65, finding 16). Coalesced trips escalate from
        // `handleFloodTrigger`, where the anchor already is the record.
        if sustained, settings.jammingResponse { host?.tripEscalateFlood() }

        // 1a. Shot 1 — get the FACT into iCloud NOW, before capture even starts, so
        //     the sub-second "the tamper survives a force-restart" guarantee holds
        //     for EVERY mode (a still still takes ~1s to capture + write; a clip up
        //     to 2 min). The full meta (with thumbnail) + media follow in step 4.
        let fact = event
        pushFactIfCloud(fact)
        // The session's cloud authorization, decided WITH the record (sixth-review F3):
        // the fact push above samples it now; the full-evidence push after the capture
        // must use the SAME answer, or a disarm (which clears `armedPro` first) or a trial
        // expiring during a long clip splits the event across tiers — fact in iCloud,
        // media stranded local-only, against P-01's live-session no-downgrade.
        let sessionAllowed = cloudAllowed
        let attemptStartedAt = Date()   // interruptions reported after this are this attempt's (item 65, finding 2)

        // 2. Capture evidence. Single-camera captures are bounded (see below) so
        //    they can't hang the pipeline. "Both" uses multi-cam when supported.
        var primary: EvidenceCapturePipeline.Capture?
        var secondary: EvidenceCapturePipeline.Capture?
        var bothRequested = false
        var failuresByCamera: [String: CaptureFailureReason] = [:]
        var failure: CaptureFailureReason?          // why there is no media, when there is none (54)
        var captureCamera: CameraChoice = .front    // the lens the one bounded retry would use
        if settings.isEnabled(.camera) {
            // A wrong PIN is photographed from the front as one still, whatever the capture
            // settings say (item 49): the typist faces the screen, and a still lands while they
            // are still standing there — a clip or a second lens would only delay it.
            let mode: CaptureMode = wrongPIN ? .photo : captureModeNow
            let position: CameraChoice = wrongPIN ? .front : effectiveCameraPosition
            let light = settings.illumination
            var target: CameraChoice?
            switch position {
            case .front, .rear, .auto:
                target = MonitoringEngine.resolvedCaptureCamera(choice: position,
                                                    faceDown: UIDevice.current.orientation == .faceDown,
                                                    touched: triggeredSensors.contains(.touch))
            case .both:
                bothRequested = true
                if camera.supportsMultiCam {
                    let both = await capturePipeline.captureBoth(mode: mode, illumination: light, preservation: .init(event: event, store: eventStore))
                    primary = both.front
                    secondary = both.rear
                    failure = both.failure
                    failuresByCamera = both.failuresByCamera
                } else {
                    target = .front   // fallback: front only
                    failuresByCamera["rear"] = .cameraUnavailable
                }
            }
            if let target {
                captureCamera = target
                let outcome = await capturePipeline.capture(from: target, mode: mode, illumination: light, preservation: .init(event: event, store: eventStore))
                primary = outcome.capture
                failure = outcome.failure
                if bothRequested, let reason = outcome.failure { failuresByCamera["front"] = reason }
            }
        }

        // 3. Persist captured media (+ thumbnail) OFF the main actor, then attach
        //    the filename/camera/duration to the saved event. If the write fails,
        //    the event keeps its metadata + traces rather than referencing a file
        //    that isn't there — and says so (54).
        let primarySaved = await storeInitialCapture(primary, secondary: false, in: &event)
        let secondarySaved = await storeInitialCapture(secondary, secondary: true, in: &event)
        if !primarySaved {
            failure = .storageFailed
            if bothRequested { failuresByCamera["front"] = .storageFailed }
        }
        if !secondarySaved {
            failure = .storageFailed
            failuresByCamera["rear"] = .storageFailed
        }
        // All original coverage outcomes are now known. Retain per-camera history, even
        // after a retry, but never label surviving footage as a failed whole capture.
        failuresByCamera = failuresByCamera.mapValues { reason in
            Self.reclassifiedCaptureFailure(reason, attemptStartedAt: attemptStartedAt,
                                            interruptedAt: lastInterruption?.at,
                                            reason: lastInterruption?.reason) ?? reason
        }
        let allIssues = (event.captureFailuresByCamera ?? [:]).merging(failuresByCamera.mapValues(\.rawValue)) { _, new in new }
        event.captureFailuresByCamera = allIssues.isEmpty ? nil : allIssues
        if event.mediaFilename != nil || event.secondaryMediaFilename != nil { failure = nil }
        // A shot that failed with no interruption live at the end of the attempt is still an
        // interruption's casualty when one began during it (item 65, finding 2).
        failure = Self.reclassifiedCaptureFailure(failure, attemptStartedAt: attemptStartedAt,
                                                  interruptedAt: lastInterruption?.at,
                                                  reason: lastInterruption?.reason)
        event.captureFailure = failure?.rawValue
        // An interruption-class failure gets one bounded retry when the interruption ends
        // (item 54) — a still for this event, if the session is still armed by then. Parked
        // only while the session that failed the capture is still the live one: a retry never
        // crosses a disarm, and a late capture must not re-park what `disarm()` cleared
        // (item 65, finding 11).
        if let failure, failure.isInterruption || failure == .cameraBusy, session == armSession {
            captureRetry = CaptureRetry(eventID: event.id, camera: captureCamera,
                                        failedAt: Date(), cloudAllowed: sessionAllowed, session: session,
                                        interruptionEnded: (failure == .cameraBusy && lastInterruption == nil) || Self.retryIsDueNow(interruptedAt: lastInterruption?.at,
                                                                             interruptionEndedAt: lastInterruptionEndedAt))
        }
        // Trips that landed during this capture join the record (34-review M1) — the
        // flood coalescer's precedent: coalesce log spam, never evidence. Folded before the
        // final persist and the full cloud push, so both carry the complete sensor list.
        // Only this response's own session's (item 129, F3).
        if let trips = tripsDuringCapture.removeValue(forKey: session), !trips.isEmpty {
            event.triggeredSensors = Self.foldedSensors(event.triggeredSensors, adding: trips)
        }
        // Wrong PINs typed during the capture join the record the same way (item 49).
        // Only this response's own session's (item 89, A2).
        if let attempts = wrongPINsDuringCapture.removeValue(forKey: session), attempts > 0 {
            event.wrongPINCount = (event.wrongPINCount ?? 0) + attempts
        }
        event.endDate = Date()   // now reflects when capture actually finished
        eventStore.updateAndReopenForReupload(event)   // a sweep's sparse upload during the capture is not the last word (item 155's A1), in one write (S1)
        // Re-read the stored copy: `update` preserves monotonic fields written while the
        // capture ran (owner attribution at disarm — sixth-review F2), and the upload below
        // must carry them, or the rich push regresses the cloud record to unattributed.
        let merged = eventStore.events.first { $0.id == event.id } ?? event
        // Flood onset: this becomes the coalescing anchor — subsequent flood trips extend it
        // instead of creating new events — and its idle-clear starts NOW, with the anchor,
        // not at the onset trip: an onset capture longer than the clear interval used to
        // leave an anchor with no timer, and a flood hours later coalesced into it. Only for
        // the live session: a late capture must not re-install an anchor `disarm()` cleared
        // (item 65, finding 11).
        if sustained, session == armSession {
            sustainedEvent = merged
            scheduleSustainedClear()
        }

        // 4. Exfiltrate in the background — ALWAYS, even if the owner disarmed
        //    mid-capture (e.g. they grabbed the phone back from a tamperer). The
        //    evidence must reach iCloud regardless; the media is already on disk,
        //    so this doesn't depend on the (possibly shut-down) camera. Only the
        //    re-arm/alert below are gated on the session still being live.
        exfiltrateInBackground(merged, cloudAllowedOverride: sessionAllowed)

        // A replaced watch still saves and uploads its evidence, but no longer owns the
        // camera. Disarm and the pipeline handle the old attempt's shutdown; another shutdown
        // here could stop the new watch while the old response finishes its media write.
        guard session == armSession else { return }

        // 5. Re-arm the sensors NOW so the next tamper is caught immediately.
        reArm()

        // 5a. Return the camera to cold standby if the readiness policy says so
        //     (Battery saver, or Auto on battery) — this capture is the reason it was
        //     up. This is also the warm→cold handoff after an unplug trigger.
        standDownCameraIfNeeded()

        host?.tripFinishCapturedResponse()
    }

    private func reArm() {
        // Post-TRIGGER re-arm: clear each latch and let motion adopt the new resting
        // pose (a device left in a new spot shouldn't trip forever), without a
        // stop()/start() gap. The refractory sweep uses plain rearm() instead — see F-15.
        host?.tripRebaselineEnabledSensors()
        recentTrips.removeAll()
        latchedSensors.removeAll()
        isHandlingTrigger = false
        host?.tripReturnToArmedAndRecheckBlackout()   // a path lost during the capture (item 65, finding 8)
        // Also wakes a retry whose end notification raced with this trigger, including
        // an until-clear clip. A still-active interruption leaves its slot parked.
        scheduleInterruptedCaptureRetry()
    }

    /// Pure (unit-tested; item 65, finding 2). Whether the one bounded retry should run now
    /// rather than wait for `.interruptionEnded`: the interruption that failed the attempt has
    /// already ended, so no end is coming. A newer interruption still live keeps the wait.
    nonisolated static func retryIsDueNow(interruptedAt: Date?, interruptionEndedAt: Date?) -> Bool {
        guard let interruptedAt, let interruptionEndedAt else { return false }
        return interruptionEndedAt >= interruptedAt
    }

    struct CaptureRetry {
        let eventID: UUID
        let camera: CameraChoice
        let failedAt: Date
        let cloudAllowed: Bool
        let session: Int
        var interruptionEnded: Bool
    }

    /// Queue an opportunity for this slot only. A queued callback from an older incident or
    /// watch must not spend a replacement slot. Eligibility is checked when the task runs.
    func scheduleInterruptedCaptureRetry() {
        guard let retry = captureRetry, retry.interruptionEnded else { return }
        Task { [weak self] in
            guard let self, let host = self.host, self.armSession == retry.session,
                  self.captureRetry?.eventID == retry.eventID else { return }
            let lifetime = FiniteWorkLifetime(owner: host)
            defer { lifetime.keepAlive() }
            await self.retryInterruptedCapture()
        }
    }

    /// Owner-facing wording for a session interruption while armed (pure, unit-tested).
    nonisolated static func interruptionNotice(_ reason: CaptureInterruptionReason) -> String {
        let why: String
        switch reason {
        case .background:     why = "the app is not in the foreground"
        case .anotherApp:     why = "another app is using the camera"
        case .audioClient:    why = "another app is using the microphone"
        case .systemPressure: why = "iOS shed it under system pressure (heat or load)"
        case .unknown:        why = "the system took it"
        }
        return "Camera interrupted - \(why). Captures resume when it returns."
    }
}
