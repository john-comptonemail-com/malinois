// Existing engine entry points; coordination and state belong to MonitoringTripResponder.
import Foundation

extension MonitoringEngine {
    private func withTripLifetime<Value>(_ operation: @MainActor (MonitoringTripResponder) async -> Value) async -> Value {
        let lifetime = MonitoringTripResponder.FiniteWorkLifetime(owner: self)
        defer { lifetime.keepAlive() }
        return await operation(tripResponder)
    }
    var isHandlingTrigger: Bool { tripResponder.isHandlingTrigger }
    var cadenceCaptureBusy: Bool { tripResponder.cadenceCaptureBusy }
    var tripsDuringCapture: [Int: Set<SensorType>] { tripResponder.tripsDuringCapture }
    var wrongPINsDuringCapture: [Int: Int] { tripResponder.wrongPINsDuringCapture }
    var liveFloodAnchorID: UUID? { tripResponder.liveFloodAnchorID }
    nonisolated static let floodTripThreshold = MonitoringTripResponder.floodTripThreshold
    nonisolated static let aggregateFloodThreshold = MonitoringTripResponder.aggregateFloodThreshold
    #if DEBUG
    var captureStoredForTesting: ((UUID) async -> Void)? {
        get { tripResponder.captureStoredForTesting }
        set { tripResponder.captureStoredForTesting = newValue }
    }
    #endif

    /// Pure (unit-tested): is a per-sensor recent trip count high enough to be a flood?
    nonisolated static func isFloodCount(_ count: Int) -> Bool {
        MonitoringTripResponder.isFloodCount(count)
    }

    /// Called by sensor monitors and by the touch overlay.
    func handleTrip(_ sensor: SensorType) {
        tripResponder.handleTrip(sensor)
    }

    /// Pure (unit-tested): an event's sensor list with capture-window trips folded in —
    /// deduplicated, sorted like every other sensor list, existing entries never removed.
    nonisolated static func foldedSensors(_ current: [SensorType],
                                          adding trips: Set<SensorType>) -> [SensorType] {
        MonitoringTripResponder.foldedSensors(current, adding: trips)
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
        MonitoringTripResponder.mayRunCadenceCapture(handlingTrigger: handlingTrigger, capturingUntilClear: capturingUntilClear, cadenceBusy: cadenceBusy)
    }

    /// The capture session's life, as the camera reports it (item 54; absorbs 32.R9). An
    /// interruption is surfaced while it lasts; its end re-warms the camera per the readiness
    /// policy and takes the one bounded retry; a runtime error — a session killed under the
    /// engine, which used to stay down and unlogged until the next trigger — is recorded as
    /// an audit event, surfaced, and re-warmed. Never on the trigger hot path: a capture that
    /// owns the camera is left alone, and the retry yields to it.
    func handleCameraSessionEvent(_ event: CameraSessionEvent) {
        tripResponder.handleCameraSessionEvent(event)
    }

    /// Pure (unit-tested; item 65, finding 2). A shot that failed with no interruption live at
    /// the end of the attempt is still an interruption's casualty when one began during it — a
    /// short "another app took the camera" that ends before the doomed attempt does — and the
    /// record should carry the system's reason, not "the camera failed while capturing".
    nonisolated static func reclassifiedCaptureFailure(_ failure: CaptureFailureReason?,
                                                       attemptStartedAt: Date,
                                                       interruptedAt: Date?,
                                                       reason: CaptureInterruptionReason?) -> CaptureFailureReason? {
        MonitoringTripResponder.reclassifiedCaptureFailure(failure, attemptStartedAt: attemptStartedAt, interruptedAt: interruptedAt, reason: reason)
    }

    func startRefractorySweep() {
        tripResponder.startRefractorySweep()
    }

    /// Pure: of the latched sensors, which have aged past `window` since their last
    /// trip (or have no recorded trip at all) and are therefore due to be re-armed.
    /// The single source of truth for the refractory decision (unit-tested).
    static func refractoryDueSensors(latched: Set<SensorType>,
                                     trips: [SensorType: Date],
                                     now: Date,
                                     window: TimeInterval) -> Set<SensorType> {
        MonitoringTripResponder.refractoryDueSensors(latched: latched, trips: trips, now: now, window: window)
    }

    nonisolated static func isAggregateFlood(_ triggerCount: Int) -> Bool {
        MonitoringTripResponder.isAggregateFlood(triggerCount)
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
        MonitoringTripResponder.makeFloodEvidenceEvent(
            sensors: sensors,
            motionTrace: motionTrace,
            audioTrace: audioTrace,
            visionTrace: visionTrace,
            offline: offline,
            now: now
        )
    }

    func captureFloodEvidence(_ sensors: [SensorType]) async {
        await withTripLifetime { responder in
            await responder.captureFloodEvidence(sensors)
        }
    }

    /// `wrongPIN`: the response to a wrong disarm PIN (item 49) — the record carries the attempt,
    /// and the capture is one front still whatever the settings say.
    func respond(triggeredSensors: [SensorType], startDate: Date, session: Int,
                 sustained: Bool = false, wrongPIN: Bool = false) async {
        await withTripLifetime { responder in
            await responder.respond(triggeredSensors: triggeredSensors, startDate: startDate, session: session, sustained: sustained, wrongPIN: wrongPIN)
        }
    }

    /// Pure (unit-tested; item 65, finding 2). Whether the one bounded retry should run now
    /// rather than wait for `.interruptionEnded`: the interruption that failed the attempt has
    /// already ended, so no end is coming. A newer interruption still live keeps the wait.
    nonisolated static func retryIsDueNow(interruptedAt: Date?, interruptionEndedAt: Date?) -> Bool {
        MonitoringTripResponder.retryIsDueNow(interruptedAt: interruptedAt, interruptionEndedAt: interruptionEndedAt)
    }

    /// Queue an opportunity for this slot only. A queued callback from an older incident or
    /// watch must not spend a replacement slot. Eligibility is checked when the task runs.
    func scheduleInterruptedCaptureRetry() {
        tripResponder.scheduleInterruptedCaptureRetry()
    }

    /// Owner-facing wording for a session interruption while armed (pure, unit-tested).
    nonisolated static func interruptionNotice(_ reason: CaptureInterruptionReason) -> String {
        MonitoringTripResponder.interruptionNotice(reason)
    }

    /// A wrong PIN on the armed screen's disarm pad (item 49): the attempt to defeat the alarm is
    /// itself evidence. `KeychainService.verify` has already counted it for the lockout, which
    /// this never touches. While a capture is running the attempt joins that record, like any
    /// trip during a capture (the typing is its Touch); otherwise it mints its own record through
    /// the trigger response — the fact first, pushed like any trip, then one front still.
    /// Armed sessions only (the calibration review included, like `handleTrip`): the Home gate
    /// and the other PIN pads stay lockout-only. The alarm and the flash keep their rule —
    /// no fresh alarm or flash while the owner is typing (A-02); a running alarm is kept up.
    func noteWrongDisarmPIN() {
        tripResponder.noteWrongDisarmPIN()
    }

    /// The frame grab for a blackout record already in the log, pushed under the cloud
    /// authorization decided with that record (P-01's live-session no-downgrade).
    func captureBlackoutEvidence(for logged: Event, cloudAllowed sessionAllowed: Bool) async {
        await withTripLifetime { responder in
            await responder.captureBlackoutEvidence(for: logged, cloudAllowed: sessionAllowed)
        }
    }

}
