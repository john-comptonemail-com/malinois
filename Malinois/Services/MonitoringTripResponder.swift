import Foundation

@MainActor
protocol MonitoringTripHost: AnyObject {
    // Read on demand. Do not copy these into a second session/watch snapshot.
    var tripState: MonitoringState { get }
    var tripSession: Int { get }
    var tripCalibrationReview: Bool { get }
    var tripDryRunActive: Bool { get }
    var tripCaptureModeNow: CaptureMode { get }
    var tripCameraPosition: CameraChoice { get }
    var tripCameraShouldBeWarm: Bool { get }
    var tripCloudAllowed: Bool { get }

    // Sensor mechanisms stay on the engine. nil vs [] is preserved for vision traces.
    func tripConsumeDryRun(_ sensor: SensorType) -> Bool
    func tripNoteMotion(at date: Date)
    func tripRecentTrace(for sensor: SensorType) -> [Double]?
    func tripRearmSensor(_ sensor: SensorType)
    func tripRebaselineEnabledSensors()

    // Synchronous root publications, at their original positions in the responder's sequence.
    func tripGoCovert()
    func tripEnterTriggeredState()
    func tripStampTrigger(at date: Date)
    func tripPublishEventCount(_ count: Int)
    func tripNoteCandidateEvent(_ id: UUID)
    func tripReturnToArmedAndRecheckBlackout()

    // Physical response policy stays on root. No alert/siren/screen flags leak into the protocol.
    func tripExtendAlertWindow()
    func tripExtendConfiguredFloodAlert()
    func tripEscalateFlood()
    func tripFinishCapturedResponse()
    func tripStandDownCameraIfNeeded()
    func tripWarmActiveCamera()
    func tripResolveAutoCamera() -> CameraChoice

    // Direct session notice publication differs from policy-checked capture failure reporting.
    func tripSetCameraNotice(_ notice: String?)
    func tripReportCaptureNotice(_ notice: String?)
    func tripLogCameraError()
}

/// Owns trip, flood and interrupted-capture coordination. Hardware and published UI stay on its weak root host.
@MainActor
final class MonitoringTripResponder {
    weak var host: (any MonitoringTripHost)?
    let settings: AppSettings
    let eventStore: EventStore
    let camera: any EvidenceCamera
    let capturePipeline: EvidenceCapturePipeline
    let cloudCoordinator: MonitoringCloudCoordinator
    let connectivity: ConnectivityMonitor
    let timing: EngineTiming
    let thermalState: @MainActor () -> ProcessInfo.ThermalState

    init(settings: AppSettings, eventStore: EventStore, camera: any EvidenceCamera,
         capturePipeline: EvidenceCapturePipeline, cloudCoordinator: MonitoringCloudCoordinator,
         connectivity: ConnectivityMonitor, timing: EngineTiming,
         thermalState: @escaping @MainActor () -> ProcessInfo.ThermalState) {
        self.settings = settings
        self.eventStore = eventStore
        self.camera = camera
        self.capturePipeline = capturePipeline
        self.cloudCoordinator = cloudCoordinator
        self.connectivity = connectivity
        self.timing = timing
        self.thermalState = thermalState
    }

    var correlationWindow: TimeInterval { timing.correlationWindow }

    /// How often, while armed, to free latched-but-uncorroborated sensors.
    var refractorySweepInterval: TimeInterval { timing.refractorySweepInterval }

    var refractoryTimer: Timer?

    // MARK: - Flood coalescing
    /// More than this many trips from one sensor within the window is a "flood"
    /// (someone attacking the sensor to overflow the log), not a real tamper. Set well
    /// above a plausible human tamper rate (~6/min) so ordinary sustained handling — an
    /// actual burglary — isn't misclassified as a synthetic attack.
    nonisolated static let floodTripThreshold = 10

    var floodWindow: TimeInterval { timing.floodWindow }

    /// A flood is considered over once its sensor is quiet this long.
    var sustainedIdleClear: TimeInterval { timing.sustainedIdleClear }

    /// Even during a flood, keep capturing on this cadence (photo-only) so a real tamper
    /// that merely looks like a flood is never left un-photographed. Coalescing then
    /// suppresses log spam and upload volume, not the evidence itself.
    var floodCaptureInterval: TimeInterval { timing.floodCaptureInterval }

    var lastFloodCapture: Date?

    /// Last time the coalesced counter was flushed to disk (F2) — the write, not the count,
    /// is throttled; in-memory stays current and the clear timer flushes the final value.
    var lastFloodPersist: Date?

    var sensorTripTimes: [SensorType: [Date]] = [:]

    /// The current coalesced "sustained activity" event, while flooding. Every write works on
    /// the stored copy (`storedAnchor`), since the record can change while the flood runs; this
    /// copy names the record, and stands in for it only if the store has dropped it (item 95).
    var sustainedEvent: Event?

    /// The live flood's record, which the engine still pushes after its row has left a full log: its account binding
    /// is kept (codex-6 on 1.8.2's step 17).
    var liveFloodAnchorID: UUID? { sustainedEvent?.id }

    var sustainedClearTimer: Timer?

    /// Recent trips awaiting the combination check: sensor → timestamp.
    var recentTrips: [SensorType: Date] = [:]

    /// Sensors that have tripped and not yet been re-armed. A one-shot monitor stays
    /// latched until a trigger fires (→ reArm) or the refractory sweep frees it.
    ///
    /// KEEP THE SWEEP — as defence in depth. Every latch path today does reach `reArm()`:
    /// a trip either fires a trigger (respond → reArm), coalesces into a flood (→ reArm),
    /// or lands during a capture and is folded into the in-flight event without latching at
    /// all (`tripsDuringCapture`, 34-review M1). This comment used to claim that a trip
    /// arriving while `isHandlingTrigger` was true latched without a re-arm — that path
    /// never existed: the flag and `.triggered` are always set together, so the state guard
    /// dropped such trips outright (that drop was M1, fixed above). The sweep stays because
    /// its failure mode — a latched monitor silently deaf — is exactly the one worth a
    /// half-second backstop against any future path that forgets (F-15).
    var latchedSensors: Set<SensorType> = []

    var isHandlingTrigger = false

    /// Trips that arrived while a capture was already running (`.triggered`, photo or fixed
    /// clip). Folded into the in-flight event when its capture finishes (34-review M1): a
    /// grab-then-unplug whose cable pull landed inside the ~1–5 s capture window used to be
    /// recorded as "Device motion" only — the second step's trip was dropped with no record
    /// anywhere. Until-clear clips were the only mode that handled the window.
    /// By arm session since Codex's review of 1.7 (70) (item 129, F3), like
    /// `wrongPINsDuringCapture`: one set for the whole engine let a response from an earlier
    /// watch, still saving after a disarm and re-arm, fold the new watch's trips into its own
    /// event and clear them from the new one. A disarm no longer drops the trips pending then
    /// (item 152's lead 14, 1.8.2): the capture's response still folds them when it ends.
    var tripsDuringCapture: [Int: Set<SensorType>] = [:]

    /// Wrong disarm PINs that landed while a capture was already running (item 49). Folded into
    /// the in-flight event alongside `tripsDuringCapture` (the typing is its Touch) and zeroed at
    /// every capture start. Unlike the trips, a disarm does NOT clear it: the capture's response
    /// still finishes after a disarm and folds it, so a PIN-holder's fumbled attempts stay on the
    /// record they landed in even when the right PIN follows before the capture ends.
    /// Wrong PINs typed while a capture ran, by arm session (item 49; per session since the
    /// 2026-09-28 review, item 89 A2): a capture still running when the owner disarms and
    /// re-arms folds only its own session's attempts, and a new session's first trigger clears
    /// only its own count.
    var wrongPINsDuringCapture: [Int: Int] = [:]

    #if DEBUG
    /// Pauses a completed evidence write before its response performs camera cleanup.
    /// Tests replace the watch during this suspension to exercise stale response ownership.
    var captureStoredForTesting: ((UUID) async -> Void)?

    #endif

    /// True while a blackout, flood-cadence or retry capture is using the camera (ADR 0003).
    var cadenceCaptureBusy = false {
        didSet {
            // The interruption's end may have arrived during a flood/blackout still.
            // Its release is the next opportunity; no polling or extra end is needed.
            if oldValue && !cadenceCaptureBusy { scheduleInterruptedCaptureRetry() }
        }
    }

    /// A capture that failed for an interruption, waiting for the interruption to end
    /// (item 54). One slot: the latest such failure; consumed by the one bounded retry.
    var captureRetry: CaptureRetry?

    /// True while the Home camera notice is this handler's interruption text, so the end of
    /// the interruption clears it without wiping a capture-failure notice.
    var interruptionNoticeShowing = false

    /// When the last camera runtime error was acted on. Runtime errors arrive in storms (a
    /// session that cannot start emits one per attempt), so within `cameraErrorDebounce` a
    /// repeat is logged and otherwise ignored — one audit record and one re-warm per storm,
    /// never a record-and-re-warm loop.
    var lastCameraRuntimeErrorAt: Date?

    /// Item 65, finding 2: the latest interruption the camera reported, and when the latest one
    /// ended. A capture that fails with no interruption live at the end of its attempt may still
    /// be the casualty of one that began (and ended) during it — the failure is then classified
    /// from this, and the one bounded retry runs at once instead of waiting for an end that has
    /// already come.
    var lastInterruption: (reason: CaptureInterruptionReason, at: Date)?

    var lastInterruptionEndedAt: Date?

    /// Trigger timestamps inside the flood window, for the aggregate check above.
    var recentTriggerTimes: [Date] = []

    /// Pure (unit-tested). Sustained *triggers* per minute across all sensors. Set well
    /// above the ~6/min a human tamperer produces so ordinary — even frantic — handling is
    /// never coalesced, while a synthetic multi-source flood is.
    nonisolated static let aggregateFloodThreshold = 15

    // These adapters always read the current root, including after a suspension.
    var state: MonitoringState { host?.tripState ?? .disarmed }
    var armSession: Int { host?.tripSession ?? -1 }
    var showingCalibrationReview: Bool { host?.tripCalibrationReview ?? false }
    var dryRunActive: Bool { host?.tripDryRunActive ?? false }
    var captureModeNow: CaptureMode { host?.tripCaptureModeNow ?? .photo }
    var effectiveCameraPosition: CameraChoice { host?.tripCameraPosition ?? .front }
    var cameraShouldBeWarm: Bool { host?.tripCameraShouldBeWarm ?? false }
    var cloudAllowed: Bool { host?.tripCloudAllowed ?? false }
    var isCapturingUntilClear: Bool { capturePipeline.isCapturingUntilClear }

    func goCovert() { host?.tripGoCovert() }
    func extendAlertWindow() { host?.tripExtendAlertWindow() }
    func warmActiveCamera() { host?.tripWarmActiveCamera() }
    func standDownCameraIfNeeded() { host?.tripStandDownCameraIfNeeded() }
    func resolveAutoCamera() -> CameraChoice { host?.tripResolveAutoCamera() ?? .front }
    func report(cameraNotice notice: String?) { host?.tripReportCaptureNotice(notice) }
    func beginBindingUse(_ id: UUID) { cloudCoordinator.beginBindingUse(id) }
    func endBindingUse(_ id: UUID) { cloudCoordinator.endBindingUse(id) }
    func pushFactIfCloud(_ event: Event) { cloudCoordinator.pushFactIfCloud(event) }
    func exfiltrateInBackground(_ event: Event, cloudAllowedOverride: Bool? = nil) {
        cloudCoordinator.exfiltrateInBackground(event, cloudAllowedOverride: cloudAllowedOverride)
    }

    /// Acquired before strong finite spawns; for the weak retry, acquired only after task admission.
    struct FiniteWorkLifetime {
        private let owner: (any MonitoringTripHost)?
        init(owner: (any MonitoringTripHost)?) { self.owner = owner }
        func keepAlive() { withExtendedLifetime(owner) {} }
    }
    func retainHostForFiniteWork() -> FiniteWorkLifetime { FiniteWorkLifetime(owner: host) }

    /// Original startWatching fragment, before the connection baseline and monitor start.
    func resetForWatchStart() {
        recentTrips.removeAll()
        latchedSensors.removeAll()
        sensorTripTimes.removeAll()
        recentTriggerTimes.removeAll()   // F8: don't inherit a prior session's aggregate-flood count
        sustainedEvent = nil             // nor its flood anchor (item 65, finding 11)
        lastFloodCapture = nil
        lastFloodPersist = nil
    }
    func discardParkedRetry() { captureRetry = nil }
    func stopRefractorySweep() { refractoryTimer?.invalidate(); refractoryTimer = nil }
    func stopSustainedClearTimer() { sustainedClearTimer?.invalidate(); sustainedClearTimer = nil }
    /// Original post-escalation reset fragment; does not release a capture's cadence claim.
    func resetFloodAfterDisarm() {
        sustainedEvent = nil
        lastFloodCapture = nil
        lastFloodPersist = nil
        sensorTripTimes.removeAll()
        recentTriggerTimes.removeAll()
    }
    /// Original final disarm fragment. Old responses retain their session's fold buckets.
    func clearTriggerStateAfterDisarm() {
        recentTrips.removeAll()
        latchedSensors.removeAll()
        // Not `tripsDuringCapture` nor `wrongPINsDuringCapture`: the in-flight response folds them into its record when
        // its capture ends (item 49; item 152's lead 14), and each is its own session's.
        isHandlingTrigger = false
    }
    func noteCaptureNoticeReplacedInterruption() { interruptionNoticeShowing = false }
}
