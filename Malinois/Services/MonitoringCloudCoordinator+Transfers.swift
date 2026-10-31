// Cloud transfer and heartbeat coordination, owned by MonitoringCloudCoordinator.
import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringCloudCoordinator {

    /// The launch-time pull (owner, 2026-09-04): the log used to fill from iCloud only on the
    /// Event Log's pull-to-refresh, so a fresh install showed "Event Log (0)" until the owner
    /// found the gesture — reading as evidence gone rather than not yet fetched. Runs once the
    /// entitlement has resolved (Pro-gated like every cloud path, through `syncFromCloud`), after
    /// the upload sweep, and says so on Home while it runs. Verify iCloud access runs it too, asking
    /// for at least `minimumLimit` (item 143, `cloudAccessVerified()`).
    func restoreFromCloudAtLaunch(minimumLimit: Int = 0) async {
        guard entitlements.proActive, !cloudRestoreInProgress else { return }
        // A restore owed since the install (item 89, C1) asks for everything, and only a pull
        // that reached iCloud and ran to the end settles it. What the pull brings from before the
        // install counts as history either way (`EventStore.mergeFromCloud`).
        let restoring = eventStore.restoreOwedSince != nil
        // Set before the flag, so Home's first frame already has the right wording.
        currentLaunchPull = Self.launchPullKind(localEventCount: eventStore.events.count, restoreOwed: restoring)
        cloudRestoreInProgress = true
        defer {
            cloudRestoreInProgress = false
            // The restore is what brings another device's records in — the signal Home's
            // notifications line waits for (item 69).
            let lifetime = retainHostForFiniteWork()
            Task { defer { lifetime.keepAlive() }; await self.refreshNotificationHealth() }
        }
        let limit = max(minimumLimit, Self.launchSyncLimit(localEventCount: eventStore.events.count, restoreOwed: restoring,
                                                           cap: EventStore.maxEvents, page: CloudExfiltrator.fetchPageSize))
        let pull = await pullFromCloud(limit: limit)
        if restoring, pull.complete { eventStore.completeRestore() }
        if pull.added > 0 { Log.engine.info("Launch restore pulled \(pull.added, privacy: .public) event(s) from iCloud") }
        await checkCloudCopies()   // item 87: were this phone's copies deleted meanwhile?
    }

    /// Handles a subscription push end to end and reports **what actually happened**.
    ///
    /// The AppDelegate used to post a notification and call the completion handler with
    /// `.newData` in the same breath, while the fetch had not started. That reported success for
    /// work that might fail, and — worse — told iOS the background work was finished while it
    /// was still running, so the system was free to suspend the app mid-copy. The push exists
    /// precisely so the evidence reaches a second device; being suspended halfway defeats it.
    func handleRemotePush() async -> UIBackgroundFetchResult {
        // A push that cold-launches the app arrives while the entitlement check is still
        // running; deciding "free tier, nothing to pull" on the unresolved default skipped
        // the fetch, and the mirrored record landed only when the owner next opened the app
        // (item 65, finding 10). Wait for the answer — bounded, iOS's patience is finite.
        await awaitEntitlementResolution(bound: timing.pushResolveWait)
        let added = await syncFromCloud()
        return Self.pushResult(pro: entitlements.proActive,
                               fetchFailed: cloud.lastFetchFailed, added: added)
    }

    /// Returns once the entitlement check has resolved, or after `bound` — whichever first.
    private func awaitEntitlementResolution(bound: TimeInterval) async {
        let deadline = Date().addingTimeInterval(bound)
        while !entitlements.hasResolved, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Pure (unit-tested). `.failed` is reported only for a query that genuinely failed — a
    /// free-tier device that never pulls, and a pull that found nothing new, are both `.noData`.
    nonisolated static func pushResult(pro: Bool, fetchFailed: Bool, added: Int) -> UIBackgroundFetchResult {
        guard pro else { return .noData }        // the free tier has no cloud to pull from
        if fetchFailed { return .failed }
        return added > 0 ? .newData : .noData
    }

    /// Starts at go-live: the first beat at once, so the session's latest record exists from the
    /// start, then one every `heartbeatInterval`. A Pro watch joins the list the retention pass
    /// trims old trails from (item 52's follow-up 2).
    func startHeartbeat(session: UUID) {
        stopHeartbeat()
        heartbeatSession = session
        cloud.enrollment.registerSession(session)
        if armedPro { registerBeatSession(BeatSession(id: session, start: armedSince ?? Date())) }
        beat()
        heartbeatTimer = Timer.commonMode(interval: timing.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
    }

    /// Stops at the disarm.
    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatSession = nil
        heartbeatSequence = 0
    }

    /// One beat. Numbered whether or not it goes out, so a beat dropped offline is a gap in the
    /// trail, not a backlog sent late (the owner's choice 3a).
    private func beat() {
        guard let session = heartbeatSession, armedSince != nil, settings.cloudBackup else { return }   // item 115
        heartbeatSequence += 1
        guard Heartbeat.beatAllowed(sessionPro: armedPro, online: connectivity.observedOnline) else { return }
        let beat = HeartbeatBeat(session: session, sequence: heartbeatSequence, deviceName: DeviceInfo.name,
                                 batteryLevel: Heartbeat.batteryLevel(fromIOS: UIDevice.current.batteryLevel),
                                 charging: isCharging,
                                 thermalState: MonitoringEngine.thermalStateName(thermalState()))   // follow-up 1, item 38's words
        let lifetime = retainHostForFiniteWork()
        Task { defer { lifetime.keepAlive() }; _ = await sendBeat(beat) }
    }

    private func sendBeat(_ beat: HeartbeatBeat) async -> Bool {
        #if DEBUG
        if let send = beatSendForTesting { return await send(beat) }
        #endif
        return await cloud.pushBeat(beat)
    }

    /// When another phone was last heard from, for the watch whose arm record is `session`.
    func lastHeard(session: UUID) async -> LastHeard {
        #if DEBUG
        if let fetch = latestBeatFetchForTesting { return await fetch(session) }
        #endif
        return await cloud.latestBeat(session: session)
    }

    /// Uploads evidence even after disarm, retaining the record's creation-time cloud permission
    /// when supplied. Retries use current entitlement. Only a still-matching event snapshot
    /// receives the completion's sync state and failure UI; newer evidence keeps its own state. Answers whether the
    /// upload's record reached iCloud, whether or not its copy could mark the row (item 170's codex-3).
    @discardableResult
    func exfiltrate(_ event: Event, cloudAllowedOverride: Bool? = nil, disarmSignal: Bool = true) async -> Bool {
        let allowed = cloudAllowedOverride ?? cloudAllowed
        guard backupAllows(event) else {   // item 115: backup is off, or was when this was recorded
            eventStore.setSyncState(.localOnly, for: event.id)
            return false
        }
        // State changes use their own record type: a routine arm must not raise a tamper alert.
        if event.isStateChange {
            guard allowed else {
                eventStore.setSyncState(.localOnly, for: event.id)
                return false
            }
            eventStore.beginUpload(event.id)   // the log limit leaves an uploading status entry alone too (item 116, R5)
            defer { eventStore.endUpload(event.id) }
            let pushed = await cloud.pushStateChange(event, disarmSignal: disarmSignal)
            applyUploadCompletion(Self.stateChangeSyncState(pushed: pushed), snapshot: event)
            // R3-2: a reset first seen on a STATE push must be acted on, not just detected —
            // this branch used to return before the handler, so an arm/disarm-only session
            // detected the reset and then ignored it: no requeue, cloud silently empty.
            handleEncryptedDataResetIfNeeded()
            return pushed
        }
        // Free-tier evidence stays local. Creation-time permission preserves an armed Pro
        // session's upload after disarm; retries use current entitlement rather than armedPro.
        guard allowed else {
            eventStore.setSyncState(.localOnly, for: event.id)
            return false
        }
        // Retention leaves this event and its media alone until the upload ends (item 114, F5).
        eventStore.beginUpload(event.id)
        defer { eventStore.endUpload(event.id) }
        // The files the log's copy names once the pin holds, not those of the copy this upload was handed: the byte limit
        // may have discarded them in between, and a dropped file still on disk while its write fails must not land after
        // the discard (item 166's codex-27). A row gone from the log keeps its copy's files, as before.
        let attached = eventStore.events.first { $0.id == event.id } ?? event
        let mediaURL = attached.mediaFilename.map { eventStore.mediaDirectory.appendingPathComponent($0) }
        let secondaryURL = attached.secondaryMediaFilename.map { eventStore.mediaDirectory.appendingPathComponent($0) }
        let outcome: CloudExfiltrator.ExfilOutcome
        #if DEBUG
        if let push = evidencePushForTesting {
            outcome = await push(event)
        } else {
            outcome = await cloud.exfiltrate(event, fullMediaURL: mediaURL, secondaryMediaURL: secondaryURL)
        }
        #else
        outcome = await cloud.exfiltrate(event, fullMediaURL: mediaURL, secondaryMediaURL: secondaryURL)
        #endif
        let current = applyUploadCompletion(outcome.syncState, snapshot: event)
        handleEncryptedDataResetIfNeeded()
        let uploaded = outcome.syncState == .synced
        guard current else { return uploaded } // A stale verdict must not alter the newer response's failure UI.
        if outcome.syncState == .synced { cloudPushRefused = false }
        // Only a network-class failure can suggest interference. Server refusals (quota,
        // authentication, schema or key reset) surface on Home without a siren. See ADR 0001.
        switch Self.pushFailureResponse(syncState: outcome.syncState,
                                        isStateChange: event.isStateChange,
                                        interference: outcome.metaFailureWasInterference,
                                        jammingResponse: settings.jammingResponse,
                                        hadConnectivityAtArm: hadConnectivityAtArm,
                                        online: connectivity.isOnline,
                                        watching: state == .armed || state == .triggered) {
        case .goLoud where event.isSignalLoss:
            // The diagnostic records an alarm already raised, not a new tamper. Its
            // completion can arrive after reconnect or in a later watch; never let its
            // failed upload create another diagnostic/alarm. Sync/refusal handling stays.
            break
        case .goLoud:
            Log.engine.error("Evidence push failed while the network path looks up — going loud")
            host?.cloudUploadInterferenceDetected()
        case .surfaceRefusal:
            Log.engine.error("Evidence push was REFUSED by iCloud — keeping covert, surfacing it")
            cloudPushRefused = true
        case .stayQuiet:
            break
        }
        return uploaded
    }

    /// What an observed push failure means (pure, unit-tested; 32.R1 / ADR 0001).
    enum PushFailureResponse: Equatable { case goLoud, surfaceRefusal, stayQuiet }

    /// Go loud only on evidence of interference — a terminal network-class failure, under
    /// the same canary conditions as before. A refusal is surfaced whatever the state (a
    /// disarmed retry that discovers a full iCloud is still worth telling the owner about).
    /// An unclassified failure stays quiet: only evidence may escalate.
    nonisolated static func pushFailureResponse(syncState: CloudSyncState, isStateChange: Bool,
                                                interference: Bool?, jammingResponse: Bool,
                                                hadConnectivityAtArm: Bool, online: Bool,
                                                watching: Bool) -> PushFailureResponse {
        guard syncState == .localOnly, !isStateChange else { return .stayQuiet }
        if interference == false { return .surfaceRefusal }
        guard interference == true, jammingResponse, hadConnectivityAtArm, online, watching else {
            return .stayQuiet
        }
        return .goLoud
    }

    /// Pure (unit-tested; BACKLOG 37): the sync state an arm/disarm audit record lands in
    /// after its push attempt. One lifecycle for evidence and audit rows — a failed push is
    /// `.localOnly` ("safe on device; uploads when a path exists"), exactly like a media
    /// event whose classified attempt exhausted; `.pending` stays the birth/in-flight state.
    /// It used to map failure back to `.pending`, so an offline arm/disarm row parked on
    /// "Syncing…" forever while the media row beside it walked orange → red → green. Retry
    /// coverage is unaffected — every sweep keys on `!= .synced`, which spans both — and the
    /// go-loud gate never sees these rows at all (`pushFailureResponse` excludes state
    /// records; the state branch above also returns before the classifier runs).
    nonisolated static func stateChangeSyncState(pushed: Bool) -> CloudSyncState {
        pushed ? .synced : .localOnly
    }

    /// After marking events owner-attributed locally, re-push their (tiny) meta so the
    /// CloudKit copy and any cross-device alert reflect it too — otherwise the flag only
    /// ever exists on-device (R-06). Deterministic record IDs make it a cheap upsert.
    ///
    /// A re-push that does not complete, including a thumbnail still owed, reopens its still-matching record for the
    /// pending sweep inside the uploader's queue (item 65, finding 3): the record was `.synced`, so a failed fact left
    /// the attribution on this device forever. Reopened, the sweep carries it up on the
    /// next chance (the media re-uploads with it: an upsert of bytes the cloud already
    /// holds, the price of a rare failure path staying simple).
    func reExfiltrateOwnerAttributed(_ ids: Set<UUID>) {
        guard cloudAllowed else { return }
        let updated = eventStore.events.filter { ids.contains($0.id) && backupAllows($0) }   // item 115
        for ev in updated {
            beginBindingUse(ev.id)   // its binding kept until the push ends (codex-6 on 1.8.2's step 17)
            let lifetime = retainHostForFiniteWork()
            Task {
                defer { lifetime.keepAlive() }
                defer { endBindingUse(ev.id) }
                await cloud.pushFact(ev)   // its queued failure hook reopens only the still-matching snapshot
                handleEncryptedDataResetIfNeeded()   // R3-2: fact pushes consume the reset flag too
            }
        }
    }

    /// Pulls mirrored evidence down from iCloud and folds it into the local log (BACKLOG 9b).
    ///
    /// This is the app's first-ever CloudKit **read**. Two deliberate constraints, both from
    /// the risk note attached to the item: the merge only ever *adds* (a local event with the
    /// same id always wins), and every merged copy is marked with `sourceDevice` so a mirror
    /// can never be mistaken for first-hand evidence captured here.
    ///
    /// Pro-gated like every other cloud path — a free user's evidence never left the device,
    /// so there is nothing to pull back.
    @discardableResult
    /// `limit` is per record type. The default is one page, which is right for a push wake-up:
    /// it exists to pull down the event that just fired, not to reconcile the whole log. A
    /// **restore** — pull-to-refresh after a reinstall — asks for the local cap instead, because
    /// stopping early there means silently returning less evidence than iCloud actually holds.
    /// Which of the records count on Home as new is the store's call (`mergeFromCloud`).
    func syncFromCloud(limit: Int = CloudExfiltrator.fetchPageSize) async -> Int {
        await pullFromCloud(limit: limit).added
    }

    /// `syncFromCloud`, and whether the fetch reached iCloud and ran to the end: an owed restore
    /// is settled only then (item 89, C1).
    private func pullFromCloud(limit: Int) async -> (added: Int, complete: Bool) {
        guard entitlements.proActive else { return (0, false) }
        let lease: CloudEnrollment.Lease?
        #if DEBUG
        if cloudFetchForTesting != nil, !requiresCloudLeaseForTesting { lease = nil } else {
            guard let granted = await cloud.acquireCloudLease() else { return (0, false) }
            lease = granted
        }
        #else
        guard let granted = await cloud.acquireCloudLease() else { return (0, false) }
        lease = granted
        #endif
        let fetch = await fetchFromCloud(limit: limit)
        if let lease, !cloud.enrollment.isCurrent(lease) { return (0, false) }
        guard !fetch.events.isEmpty else { return (0, fetch.complete) }
        let added = eventStore.mergeFromCloud(fetch.events)
        if added > 0 { eventCount = eventStore.events.count }
        return (added, fetch.complete)
    }

    /// iCloud's newest records and whether the fetch ran to the end, or, under the test seam,
    /// the closure's.
    private func fetchFromCloud(limit: Int) async -> (events: [Event], complete: Bool) {
        #if DEBUG
        if let fetch = cloudFetchForTesting { return await fetch(limit) }
        #endif
        let events = await cloud.fetchRecentEvents(limit: limit)
        return (events, cloud.lastFetchComplete)
    }

    /// Where one downloaded capture belongs on the event — decided by IDENTITY (its
    /// camera label, or the legacy slot token), never by arrival order (ext-review #2):
    /// dictionary ordering could store rear bytes under a "Front" label, and R3-3's retry
    /// could duplicate the already-held camera into the missing slot, mislabeled, burning
    /// the retry.
    enum MediaPlacement: Equatable {
        case primary(setLabel: Bool)
        case secondary(setLabel: Bool)
        case skip
    }

    /// Pure (unit-tested).
    nonisolated static func mediaPlacement(itemCamera: String?, itemSlot: String,
                                           primaryFilled: Bool, secondaryFilled: Bool,
                                           primaryCamera: String?,
                                           secondaryCamera: String?) -> MediaPlacement {
        if let cam = itemCamera {
            // A capture whose camera the event already names belongs in THAT slot — and
            // nowhere at all once the slot is filled (the no-duplicate rule).
            if primaryCamera == cam { return primaryFilled ? .skip : .primary(setLabel: false) }
            if secondaryCamera == cam { return secondaryFilled ? .skip : .secondary(setLabel: false) }
            // Unnamed slots adopt the capture and take its label.
            if primaryCamera == nil, !primaryFilled { return .primary(setLabel: true) }
            if secondaryCamera == nil, !secondaryFilled { return .secondary(setLabel: true) }
            return .skip
        }
        // Legacy primary/secondary record names carry a position, not a camera — honor it.
        if itemSlot == "primary" { return primaryFilled ? .skip : .primary(setLabel: false) }
        if itemSlot == "secondary" { return secondaryFilled ? .skip : .secondary(setLabel: false) }
        return .skip
    }

    /// How a full-evidence download went: whether anything landed, and whether every
    /// candidate slot in iCloud was actually checked. `complete == false` means captures
    /// may exist beyond what came back (a per-ID fetch failure, or the fetch not running
    /// at all), or a capture that came back could not be kept here (item 167's A2) — the UI
    /// must not present that as "iCloud holds nothing" (R3-3).
    struct EvidenceDownload: Equatable {
        let landed: Bool
        let complete: Bool
    }

    /// iCloud's full-media fetch for one event, or the test's stand-in.
    private func fetchFullMedia(for id: UUID, manifest: [String]?) async -> CloudExfiltrator.FullMediaFetch? {
        #if DEBUG
        if let fetch = fullMediaFetchForTesting { return await fetch(id, manifest) }
        #endif
        return await cloud.fetchFullMedia(for: id, manifest: manifest)
    }

    /// Stage a downloaded asset off the main actor, preserving the existing size caps and file validation.
    /// The returned source is consumed by EventStore; failed staging leaves the event unchanged.
    nonisolated static func stageDownloadedAsset(at url: URL) async -> (media: EventStore.MediaSource, ext: String)? {
        await Task.detached(priority: .userInitiated) { () -> (EventStore.MediaSource, String)? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            let prefix = (try? handle.read(upToCount: 16)).flatMap { $0 } ?? Data()
            try? handle.close()
            switch CloudExfiltrator.mediaKind(ofPrefix: [UInt8](prefix)) {
            case .jpeg:
                // Size judged by metadata BEFORE the whole-file read (F6).
                guard CloudExfiltrator.fileSizeAcceptable(url, limit: Self.maxDownloadedStillBytes),
                      let data = try? Data(contentsOf: url) else { return nil }
                return (.still(data), "jpg")
            case .movie:
                guard CloudExfiltrator.fileSizeAcceptable(url, limit: Self.maxDownloadedMovieBytes) else { return nil }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mov")
                guard (try? FileManager.default.copyItem(at: url, to: tmp)) != nil else { return nil }
                return (.clip(tmp), "mov")
            case nil:
                return nil
            }
        }.value
    }

    /// An iCloud encrypted-data reset purges every record in the zone (34.H13). Apple's
    /// prescribed recovery is a local re-upload: mark everything this device holds as
    /// pending again — the one sanctioned exception to sync-state monotonicity — tell the
    /// owner, and let the existing retry machinery carry it back up. Once per process:
    /// repeated failures while the reset settles must not re-run the requeue storm.
    func handleEncryptedDataResetIfNeeded() {
        guard cloud.encryptedDataResetDetected, !encryptedResetHandled else { return }
        encryptedResetHandled = true
        cloud.acknowledgeEncryptedDataReset()
        let requeued = eventStore.requeueAllForReupload()
        cloudReuploadCount = nil   // this notice is not the launch check's, and stays as it is
        cloudResetNotice = "iCloud's protected data was reset, which cleared the cloud copies. This device is re-uploading \(requeued) event(s)."
        Log.engine.warning("Encrypted-data reset detected; requeued \(requeued, privacy: .public) event(s) for re-upload")
        let lifetime = retainHostForFiniteWork()
        Task { defer { lifetime.keepAlive() }; await retryPendingSync() }
    }

    /// A completion describes only its submitted snapshot. Ignore a changed or deleted event,
    /// preserving pending late evidence or a newer successful upload. Ignore only sync state and the contents of
    /// uploaded-media receipts, which can advance during the upload; the receipt generation and every other field
    /// must still match. This completion compares local cache filenames and the discard-check obligation strictly.
    @discardableResult
    func applyUploadCompletion(_ state: CloudSyncState, snapshot: Event) -> Bool {
        guard matchesUploadSnapshot(snapshot) else { return false }
        eventStore.setSyncState(state, for: snapshot.id)
        return true
    }

    /// A failed fact (including a thumbnail still owed) reopens only its still-matching row. The uploader calls this
    /// inside the event's write queue; a later queued success therefore cannot be demoted by this completion.
    /// Cache paths and discard-check bookkeeping may change during the save without a newer successful fact.
    /// Their current values are kept for the retry; changed capture content, loss, attribution and epoch stay strict.
    func reopenAfterFailedFact(_ snapshot: Event) {
        guard !snapshot.isMirrored, matchesUploadSnapshot(snapshot, forFailedFact: true) else { return }
        eventStore.reopenForReupload(snapshot.id)
    }

    /// Receipts may grow during an upload and sync state may advance. Full-upload completions compare every other
    /// field. Failed facts additionally ignore cache references and the local discard-check obligation: pruning,
    /// downloading and a presence answer can change them during a save, without a newer successful write winning.
    /// This only reopens the current row; its next queued upload reads the current paths, manifest and revision.
    /// Capture identity/content, durable loss, attribution, receipt generation and all other fields remain compared.
    private func matchesUploadSnapshot(_ snapshot: Event, forFailedFact: Bool = false) -> Bool {
        guard var current = eventStore.events.first(where: { $0.id == snapshot.id }) else { return false }
        var submitted = snapshot
        current.cloudSyncState = .pending
        submitted.cloudSyncState = .pending
        current.uploadedMedia = nil   // noted by this upload as its files landed (item 166's codex-23)
        submitted.uploadedMedia = nil
        if forFailedFact {
            current.mediaFilename = nil
            submitted.mediaFilename = nil
            current.secondaryMediaFilename = nil
            submitted.secondaryMediaFilename = nil
            current.mediaDiscardUnchecked = nil
            submitted.mediaDiscardUnchecked = nil
        }
        return current == submitted
    }

    /// Downloads an event's full-resolution capture(s) from iCloud into the local store
    /// (BACKLOG 34.B1) — the retrieval half of the Pro backup promise, Pro-gated like every
    /// cloud path. The store takes ownership exactly as it does for a fresh capture: UUID
    /// filename, evidence-grade protection, derived thumbnail. Also recovers media the
    /// byte cap evicted locally — the cloud copy outlives the local eviction by design. The
    /// files join the record as it is when they land: a fetch can replace a mirror while the
    /// download runs, and writing back the copy read before it undid that (item 96). Camera
    /// placement also uses that current record, after staging and storage have finished, so
    /// newly learned labels and captures from another download cannot be overwritten.
    /// What lands counts toward the media byte limit (item 129, F4): the store runs the limit's
    /// pass as each file is attached, and on a phone over the limit it frees synced media oldest
    /// first, which can be the download itself; the iCloud copy stays, so it can be downloaded again.
    /// A capture iCloud gave that cannot be kept here (it fails to stage or to store) leaves the download incomplete,
    /// as an unchecked slot does: the rest is still to get (item 167's A2).
    func downloadFullEvidence(for id: UUID) async -> EvidenceDownload {
        guard entitlements.proActive else { return EvidenceDownload(landed: false, complete: true) }
        guard let event = eventStore.events.first(where: { $0.id == id }) else {
            return EvidenceDownload(landed: false, complete: true)
        }
        let lease: CloudEnrollment.Lease?
        #if DEBUG
        if fullMediaFetchForTesting != nil, !requiresCloudLeaseForTesting { lease = nil } else {
            guard let granted = await cloud.acquireCloudLease() else { return EvidenceDownload(landed: false, complete: false) }
            lease = granted
        }
        #else
        guard let granted = await cloud.acquireCloudLease() else { return EvidenceDownload(landed: false, complete: false) }
        lease = granted
        #endif
        guard let fetch = await fetchFullMedia(for: id, manifest: event.downloadManifest) else {
            // The fetch never ran (account, network, thrown) — nothing was checked.
            return EvidenceDownload(landed: false, complete: false)
        }
        if let lease, !cloud.enrollment.isCurrent(lease) { return EvidenceDownload(landed: false, complete: false) }
        guard !fetch.media.isEmpty else {
            return EvidenceDownload(landed: false, complete: fetch.complete)
        }
        var landed = false
        var keptAll = true   // every capture that came back is on the record, or one in its place was already (A2)
        for item in fetch.media {
            // Skip known duplicates before copying bytes, but decide again after every await:
            // a cloud merge or another download may fill or name a slot while storage runs.
            func placement(in record: Event) -> MediaPlacement {
                Self.mediaPlacement(itemCamera: item.camera, itemSlot: item.slot,
                                    primaryFilled: record.mediaFilename != nil,
                                    secondaryFilled: record.secondaryMediaFilename != nil,
                                    primaryCamera: record.primaryCamera, secondaryCamera: record.secondaryCamera)
            }
            guard let before = eventStore.events.first(where: { $0.id == id }) else { break }
            guard placement(in: before) != .skip else { continue }
            guard let staged = await Self.stageDownloadedAsset(at: item.fileURL) else { keptAll = false; continue }
            if let lease, !cloud.enrollment.isCurrent(lease) { return EvidenceDownload(landed: landed, complete: false) }
            guard let stored = await eventStore.store(staged.media, ext: staged.ext) else { keptAll = false; continue }
            if let lease, !cloud.enrollment.isCurrent(lease) { return EvidenceDownload(landed: landed, complete: false) }
            guard var current = eventStore.events.first(where: { $0.id == id }) else { break }
            // Placement and attachment use one current snapshot with no suspension between
            // them. A newly learned rear label must not be overwritten by a stale front-slot
            // decision (item 96 integration). If a competing download won, the unused file
            // remains unreferenced and the store's existing orphan sweep reclaims it.
            switch placement(in: current) {
            case .primary(let setLabel):
                current.mediaFilename = stored.filename
                if setLabel { current.primaryCamera = item.camera }
                if current.thumbnailData == nil { current.thumbnailData = stored.thumbnail }
            case .secondary(let setLabel):
                current.secondaryMediaFilename = stored.filename
                if setLabel { current.secondaryCamera = item.camera }
            case .skip:
                continue
            }
            eventStore.update(current)
            landed = true
        }
        return EvidenceDownload(landed: landed, complete: fetch.complete && keptAll)
    }
}
