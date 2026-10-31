//
//  MonitoringEngine.swift
//  Malinois
//
//  The coordinator / primary view-model. Drives the state machine, owns the
//  sensor monitors, the camera, the cloud exfiltrator and the event store. Its trip
//  responder turns sensor trips into stored evidence; its cloud coordinator owns upload
//  coordination. Its arming flow owns progression and timers. This root retains published
//  watch state, physical response policy and recovery marker transitions.
//
//  State machine:
//    disarmed → guidedAccessCheck → arming (grace) → calibrating (~3s)
//             → armed → triggered → armed (re-arm immediately & keep watching)
//  On a trigger the app captures, re-arms, then uploads to iCloud in the
//  background (upload is not a state). Reaching `disarmed` requires the PIN.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

/// A "go loud" escalation — the app has abandoned covertness because the trigger
/// pattern points to a sophisticated adversary, not an opportunistic snoop.
enum Escalation: Equatable {
    /// Suspected jamming: persists until disarm or reconnect, always sirens.
    case blackout
    /// Sustained synthetic tampering (flooding): a visible warning that fades like a
    /// normal alert (looser trigger, so it shouldn't hold a siren until the PIN).
    case flood

    var message: String {
        switch self {
        case .blackout: return "SIGNAL INTERFERENCE DETECTED\nTHIS DEVICE IS PROTECTED"
        case .flood:    return "SUSTAINED TAMPERING DETECTED\nTHIS DEVICE IS PROTECTED"
        }
    }
    var persists: Bool { self == .blackout }
    var forcesSiren: Bool { self == .blackout }
}

/// What to do with the tamper alert/siren on a trigger.
enum AlertAction: Equatable {
    case none      // nothing (no message mode)
    case present   // start a fresh alert/siren
    case extend    // an alert/siren is already up — keep it alive (re-extend its window)
    case deferred  // the owner is typing their PIN: owed, shown once the typing stops or the pad closes (item 167's A1)
}

@MainActor
final class MonitoringEngine: ObservableObject {

    // MARK: - Published state

    @Published var state: MonitoringState = .disarmed {
        didSet {
            // The app-switcher cover shows the emblem when there is something to hide, and
            // plain black while a watch is live — where a logo would advertise the app that
            // covert mode exists to conceal.
            PrivacyCover.shared.isCovert = state.isActive
        }
    }
    @Published private(set) var guidedAccessEnabled: Bool = UIAccessibility.isGuidedAccessEnabled {
        didSet {
            // On while disarmed, the screen stays on a while; off, it may sleep at once (item 92).
            if guidedAccessEnabled != oldValue { resetGuidedAccessScreenHold() }
            noteGuidedAccessChange(from: oldValue, to: guidedAccessEnabled)   // ended during a watch: a record (item 153)
        }
    }

    /// Whether this iPhone has no device passcode (1.8.2's step 34, item 155's F3): a forced restart then opens it and
    /// ends Guided Access, and the arming screen says so. Read when that screen appears and when the app is back on it
    /// (`refreshDevicePasscode`, in MonitoringEngine+ArmPINCheck.swift, which sets it).
    @Published var devicePasscodeMissing = false

    @Published private(set) var graceRemaining: Int = 0
    @Published private(set) var calibrationProgress: Double = 0   // 0…1
    @Published var lastTriggerDate: Date?
    @Published var eventCount: Int = 0

    /// True while the capture flash (white screen) is lighting a front-camera
    /// shot. ArmedView shows a full-screen white overlay when this is set.
    @Published private(set) var captureFlash = false

    /// When the current armed session began (nil while disarmed). Survives
    /// re-arms after a trigger, so it measures the whole continuous watch.
    @Published private(set) var armedSince: Date?
    /// Duration of the most recent armed session, shown on Home after disarming.
    @Published private(set) var lastArmedDuration: TimeInterval?
    /// The wall-clock window of the most recent armed session (start, end), so Home can
    /// show *when* the device was protected — the end is the forensically useful half
    /// (when protection stopped), not just how long it lasted.
    @Published private(set) var lastArmedInterval: (start: Date, end: Date)?

    /// A camera-related warning to surface on Home (e.g. multi-cam fell back to
    /// front-only). Nil when there's nothing to report.
    @Published private(set) var cameraNotice: String?

    /// A microphone-related warning (denied permission, dead recorder) — sibling of
    /// `cameraNotice`, surfaced on Home (F7).
    @Published private(set) var audioNotice: String?

    /// Set after an alert window ran with the siren owed but never sounding — activation
    /// exhausted its retries against a held audio session (eighth-review M5). Surfaced on
    /// Home once the owner is back; cleared at the next arm.
    @Published private(set) var sirenNotice: String?

    /// CONSUMES the siren's exhaustion flag into `sirenNotice` — called wherever an alert
    /// ends (dismiss, disarm), because the flag is only meaningful for the window just
    /// past. Consuming (SR-1) is what keeps one real exhaustion from resurrecting the
    /// notice after every later session in which the siren never happened to sound.
    private func noteSirenExhaustionIfAny() {
        guard siren.consumeActivationExhausted() else { return }
        sirenNotice = "The siren couldn't sound during the last alert - the audio output was held (a call or another app). The alert and evidence capture ran normally."
    }

    /// Cross-device alerts can be silently impossible on THIS device — Notifications denied
    /// for the app, or APNs registration failed — while Home still says "iCloud ready"
    /// (34.H7). Surfaced beside the camera/mic notices; nil when healthy or when the
    /// feature isn't in play.
    @Published private(set) var notificationNotice: String?
    /// Home offers the notifications prompt while this is true (item 69): a device that will
    /// receive cross-device alerts, and iOS has never been asked.
    @Published private(set) var notificationAskDue = false
    /// Home makes Apple's rating request while this is true (BACKLOG 137; `MonitoringEngine+RatingRequest.swift`).
    @Published var ratingRequestPending = false
    /// The arming screen says the camera could not be asked for because Guided Access was on
    /// (item 69, leg 11 on 40); computed at every arm.
    @Published private(set) var cameraAskBlockedByGuidedAccess = false

    /// iCloud's encrypted data was reset (34.H13): Apple purged the cloud copies, and this
    /// device is re-uploading what it still holds. Surfaced until the next arm.
    @Published private(set) var cloudResetNotice: String?

    /// iCloud REFUSED an evidence upload (quota, auth, schema, key reset) — the server
    /// answered, so it is not interference and must not siren (32.R1); it IS an owner
    /// problem, so Home says so. Cleared when a push succeeds or on the next arm.
    @Published private(set) var cloudPushRefused = false

    /// Set at launch when a prior armed session didn't end cleanly (force-quit /
    /// crash): we recovered the screen brightness and kicked off a re-sync. Shown
    /// on Home; cleared on the next arm.
    @Published private(set) var recoveredInterruptedSession = false
    /// Set when the crash-loop guard declines an automatic re-arm (fable-3; item 132): Home says so. Cleared on the next arm.
    @Published private(set) var reArmSkipped = false
    /// A launch-time pull from iCloud is running (owner, 2026-09-04): Home says so, so an
    /// empty log on a fresh install reads as "still loading", not "gone". `currentLaunchPull`
    /// says whether it is a restore or a routine check.
    @Published private(set) var cloudRestoreInProgress = false
    /// What the running launch pull is doing, for Home's wording (owner, 2026-10-11): a restore
    /// only for an empty log or an owed restore, otherwise a routine check for new events.
    @Published private(set) var currentLaunchPull: LaunchPullKind = .checking
    /// True while the CURRENT arming flow was started automatically after a crash/force-
    /// quit recovery (not by the owner). Cancelling it requires the PIN (R-04).
    @Published private(set) var armWasAutoRecovered = false
    /// The parts of the one-time screen before the first arm while it shows (item 131); set only by
    /// `startCountdownTapped`, cleared by `acknowledgeFirstArmBriefing`, when an arm begins, and when its minute
    /// without a touch runs out (ADR 0050's decision 8); auto-lock and the minute follow it (`firstArmBriefingDidChange`).
    @Published var firstArmBriefing: FirstArmBriefing.Parts? { didSet { firstArmBriefingDidChange() } }

    /// Set at arm when Siren response is selected but the device's media volume is low —
    /// the siren plays at system volume and can't override the hardware buttons, so warn
    /// the owner while they can still turn it up (F-13). Surfaced on the arming screen.
    @Published private(set) var sirenVolumeLow = false

    /// True while the on-screen tamper warning is showing (alert / siren modes).
    /// ArmedView renders the warning message when this is set.
    @Published var alertActive = false
    /// A fresh warning the PIN pad's quiet window held back (`AlertAction.deferred`, item 167's A1): shown when the
    /// window ends or the pad closes without a correct PIN; a disarm clears it.
    private var alertOwedAfterEntry = false

    /// Active "go loud" escalation (jamming blackout or a tamper flood), or nil.
    /// ArmedView shows the reason's warning; the siren behaviour depends on it.
    @Published var escalation: Escalation?
    /// Live network reachability (mirrors the connectivity monitor) — surfaced on
    /// Home as a "you're offline, evidence can't upload" warning.
    @Published var isOnline = true

    /// Result of the most recent calibration — shown as a brief "calibration
    /// complete" review before going covert, and in the Test Sensors view.
    @Published var lastCalibration: CalibrationSummary?
    /// True during the brief post-calibration review on the arming screen.
    @Published private(set) var showingCalibrationReview = false

    /// Live "Test Sensors" (dry-run) state — sensors run and report readings, but
    /// nothing is recorded and the screen never goes covert.
    @Published var dryRunActive = false
    @Published var dryRunReadings: [SensorType: SensorReading] = [:]
    /// Last "would-trip" time per sensor, so the test view can flash it.
    @Published var dryRunTrips: [SensorType: Date] = [:]
    /// Cumulative would-trip count per sensor — a persistent tally that survives
    /// proximity blanking the screen, so the user can confirm it fired even though
    /// the display was off while covered.
    @Published var dryRunCounts: [SensorType: Int] = [:]
    /// Seconds until dry-run calibration begins — a visible "set the phone down" settle window,
    /// so the motion noise floor isn't learned from the hand that just tapped "Test sensors".
    /// The arming flow gets this for free from its grace period; the dry run used to skip
    /// straight to calibrating and learn garbage (BACKLOG 12). Nil once calibrating/running.
    @Published var dryRunCountdown: Int?
    nonisolated static let dryRunSettleSeconds = 3
    /// Bumped by a re-calibration or a stop, so the completion of a calibration that was
    /// abandoned mid-flight finds itself stale and does nothing (item 65, finding 17).
    var dryRunGeneration = 0
    var dryRunSettleTimer: Timer?

    // MARK: - Collaborators

    let settings: AppSettings
    let eventStore: EventStore
    let cloud: CloudExfiltrator
    /// Owns cloud coordination; the engine remains the observable watch host.
    let cloudCoordinator: MonitoringCloudCoordinator
    /// Owns trip, flood and retry coordination; root remains the watch and capture-pipeline host.
    let tripResponder: MonitoringTripResponder
    /// Owns arming progression and timers; root retains publications, hardware and recovery.
    let armingFlow: MonitoringArmingFlow
    /// The capture pipeline, through its seam (`EvidenceCamera`): `CameraController` in the
    /// app, a fake in the characterization tests.
    let camera: any EvidenceCamera
    /// The capture mechanism (1.3 step 5): warm-up, settle, illumination, still or clip, the
    /// both-cameras path. This engine is its host — the conformance sits at the end of the file.
    let capturePipeline: EvidenceCapturePipeline
    /// The disarm-entry state machine (1.3 step 7): the attribution candidate window, the
    /// "actively typing" grace, the pad's timeout/ceiling, and the owner-attribution event
    /// set. This engine hosts it and mirrors its `isActive` into `disarmEntryActive` below.
    let disarmEntry: DisarmEntryCoordinator
    let entitlements: ProEntitlements
    /// Every duration the engine schedules against, through its seam (`EngineTiming`):
    /// `.production` in the app, a compressed copy in the characterization tests.
    let timing: EngineTiming

    var monitors: [SensorType: SensorMonitor] = [:]

    // MARK: - Internal timing

    /// Before the Auto illumination check, give the camera this long to re-meter
    /// the scene the device is *now* in — a resting phone often faces a dark
    /// surface, which would otherwise flash a shot that's actually in a lit room.
    private var autoExposureSettle: TimeInterval { timing.autoExposureSettle }
    /// How long a total connectivity loss must persist before it's treated as
    /// suspected jamming (rides out brief registration flaps / fades).
    var blackoutDebounce: TimeInterval { timing.blackoutDebounce }
    /// A motion trip within this window means the device isn't stationary — the
    /// blackout is then the "tamper carried away" case, not pre-emptive jamming.
    var stationaryWindow: TimeInterval { timing.stationaryWindow }

    var dryRunTimer: Timer?
    var blackoutTimer: Timer?
    private var guidedAccessObserver: NSObjectProtocol?

    // MARK: - Camera battery-readiness
    /// Whether the device is on external power. Drives the Auto readiness policy
    /// (warm while charging, cold-start on battery). Assume true until measured.
    private var isCharging = true
    private var batteryStateObserver: NSObjectProtocol?
    /// Deferred camera teardown when Auto flips to battery, so an unplug that also
    /// fires a trigger still captures from the warm session before it stands down.
    private var cameraStandbyTimer: Timer?
    private var cameraStandbyDelay: TimeInterval { timing.cameraStandbyDelay }

    // MARK: - Jamming / connectivity
    let connectivity: ConnectivityMonitor
    /// Whether a usable network path existed at arm — the canary baseline. Only a
    /// *loss* of a path we demonstrably had is treated as suspicious.
    var hadConnectivityAtArm = false
    var blackoutEscalated = false
    /// Last time the motion sensor tripped, for the stationary check.
    var lastMotionTrip: Date?
    /// When the current total connectivity loss began (nil while online). Feeds the
    /// trigger-time go-loud's blip filter: a WiFi↔cellular handoff can read as a sub-second
    /// unsatisfied path, and a trigger landing inside that instant must not sound the
    /// blackout siren on a coincidence (39.R2.2).
    var offlineSince: Date?

    /// True while the disarm PIN pad is open — a **mirror** of `DisarmEntryCoordinator.isActive`
    /// (1.3 step 7), kept @Published so the PIN pad view binding is unchanged. Suppresses only
    /// the *presentation* — the capture flash and the alert overlay, so they don't fight the
    /// raised PIN-pad brightness — while detection and capture keep running underneath.
    @Published private(set) var disarmEntryActive = false

    /// True while an "until clear" clip is recording; sensor trips refresh
    /// the pipeline's activity clock (which decides when to stop) instead of firing a new
    /// event.
    var isCapturingUntilClear: Bool { capturePipeline.isCapturingUntilClear }

    /// Tamper-alert display (alert / siren response modes).
    let siren = SirenPlayer()   // internal for MonitoringEngine+SirenMicRelease.swift and the tests
    private var alertDismissTimer: Timer?
    private var alertDuration: TimeInterval { timing.alertDuration }      // extends on each new trigger
    nonisolated static let alertScreenBrightness: CGFloat = 0.55
    /// Minimum brightness while the camera is live (2.5.14): the REC badge must be visibly
    /// legible — "the app cannot go blank during recording." Below the alert level so the
    /// alert still reads as the louder state.
    nonisolated static let recordingScreenBrightness: CGFloat = 0.33
    /// Re-runs refreshBrightness when the camera session starts/stops, so the screen
    /// lifts out of covert black the moment recording begins.
    private var recordingIndicatorSub: AnyCancellable?
    /// One-shot on the FIRST entitlement resolution, releasing the launch work the 31.F2
    /// gate deferred (fifth review, round 3 — the flag's third consumer). See `init`.
    private var entitlementResolutionSub: AnyCancellable?
    /// The Audio sensor is paused while the siren sounds so their audio sessions
    /// (mic capture vs. alarm playback) don't fight; resumed when the siren stops.
    private var audioPausedForSiren = false
    /// True while the audio tripwire is paused because a clip is recording (F-14).
    private var audioPausedForCapture = false

    /// Incremented whenever we leave an armed run (disarm / cancel). An in-flight
    /// trigger response captures this at the start and checks it before mutating
    /// state or re-arming, so disarming mid-response can't be clobbered by the
    /// response finishing and calling reArm().
    var armSession = 0

    var previousBrightness: CGFloat = UIScreen.main.brightness

    /// Pure (unit-tested). The display never comes back from a watch below 0.4 (item 69, leg 3
    /// on 40): the pre-arm level is sampled while the owner holds the phone, but auto-brightness
    /// in a dim room can leave it near the floor, and the disarm then drops the screen from the
    /// PIN pad's 0.6 to that. The crash-recovery restore has used this floor since 32; now every
    /// restore does.
    nonisolated static func restoredBrightness(previous: CGFloat) -> CGFloat { max(previous, 0.4) }

    /// Persisted while armed (value = the pre-arm brightness) and cleared on a clean
    /// disarm. If it's still present at launch, the last armed session ended
    /// abnormally — see `recoverInterruptedSessionIfNeeded`.
    static let armedMarkerKey = "com.malinois.armedSession.brightness"
    /// The kernel boot time and the wall clock at the moment a persistent session marker was
    /// planted (BACKLOG 53) — beside `armedMarkerKey` when the watch goes live, and beside
    /// `recoveryInProgressKey` when a recovery countdown starts. Read back with the marker at
    /// the next launch so the interruption record can say whether the DEVICE restarted or only
    /// the app ended (`BootStamp.classify`); cleared with the markers on a clean disarm.
    static let armedBootTimeKey = "com.malinois.armedSession.bootTime"
    static let armedBootStampAtKey = "com.malinois.armedSession.bootStampAt"
    /// Timestamp of the last interrupted-session re-arm *attempt*, to detect a crash loop
    /// and avoid auto-re-arming straight back into it.
    private static let recoveryTimeKey = "com.malinois.recovery.lastAt"
    /// Persisted "a crash-recovery re-arm is owed." Set when an interruption is detected and
    /// cleared after the recovery countdown is covered or a crash-loop refusal is logged.
    /// Persisting it (rather than only an
    /// in-memory flag) is what lets a re-arm deferred on a background launch survive iOS
    /// terminating that launch before the owner foregrounds it — otherwise the marker was
    /// consumed and the re-arm silently lost (M4).
    static let pendingReArmKey = "com.malinois.recovery.pendingReArm"   // internal for +Reinstall.swift
    /// Set while a recovery re-arm's countdown is running (F1): the window between
    /// consuming the owed flag and re-engaging covert used to hold NO persistent marker, so
    /// a second kill during grace/calibration left the next launch blind — no log entry, no
    /// re-arm. Cleared when covert engages (armedMarker takes over) or on a clean disarm.
    static let recoveryInProgressKey = "com.malinois.recovery.inProgress"
    /// Planted when the grace countdown starts and consumed at go-live or cancel (review 3,
    /// R3.2): one left behind at the next launch means the app ended mid-countdown. Named
    /// there, never re-armed — see `recoverInterruptedSessionIfNeeded`.
    static let armingInProgressKey = "com.malinois.arming.inProgress"

    /// Guided Access state as of the last disarm, so the next arm can say whether it changed
    /// while nobody was watching (BACKLOG 24b). Deliberately narrow: the app cannot observe
    /// GA changes while suspended at all — the notification only reaches a running process,
    /// and GA locks the device to a *single* app, so while Malinois is backgrounded any GA
    /// session belongs to something else. Comparing across a disarm is the one question the
    /// code can actually answer, and it is the one that means something: it only fires when
    /// the current state contradicts the owner's own last configuration.
    /// Item 24 part B's memory, retired by item 70 (owner, 2026-09-06): the state was sampled
    /// inside the disarm, before the owner's own exit from Guided Access, so the arming screen
    /// told the person who had ended it "you didn't leave it this way" after every normal
    /// cycle. A launch removes what a 1.3 (44) install left behind.
    private static let retiredGuidedAccessAtDisarmKey = "com.malinois.guidedAccess.atLastDisarm"

    /// Installs synchronous one-way mirrors before settings resolution can write or upload a record.
    private func installCloudCoordinatorMirrors() {
        cloudCoordinator.host = self
        cloudCoordinator.onCloudResetNoticeChange = { [weak self] in self?.cloudResetNotice = $0 }
        cloudCoordinator.onCloudPushRefusedChange = { [weak self] in self?.cloudPushRefused = $0 }
        cloudCoordinator.onCloudRestoreInProgressChange = { [weak self] in self?.cloudRestoreInProgress = $0 }
        cloudCoordinator.onCurrentLaunchPullChange = { [weak self] in self?.currentLaunchPull = $0 }
        cloudCoordinator.onPendingSweepActiveChange = { [weak self] in self?.pendingSweepActive = $0 }
        cloudCoordinator.onPendingSweepWaitingChange = { [weak self] in self?.pendingSweepWaiting = $0 }
    }

    /// Install weak synchronous will-set bridges before startup callbacks can begin an arming flow.
    private func installArmingFlowMirrors() {
        armingFlow.onGraceRemainingChange = { [weak self] in self?.graceRemaining = $0 }
        armingFlow.onCalibrationProgressChange = { [weak self] in self?.calibrationProgress = $0 }
        armingFlow.onShowingCalibrationReviewChange = { [weak self] in self?.showingCalibrationReview = $0 }
        armingFlow.onGuidedAccessLiftedThisArmChange = { [weak self] in self?.guidedAccessLiftedThisArm = $0 }
    }

    // MARK: - Init

    /// Whether the device's protected data — the event log's class-B files among it — is
    /// readable and writable right now. Injected so a test can stage a locked launch
    /// (item 65, finding 18); production reads UIKit. UIKit answers false while the app is
    /// still being built, even on an unlocked phone (item 85), so a false here only makes the
    /// launch recovery wait — for the unlock, or for the app becoming active.
    private let protectedDataAvailable: @MainActor () -> Bool

    /// iOS's thermal state (item 38): `ProcessInfo`'s, injected so a test does not read the
    /// host's (a hot Mac could flake the sentinel's tests: the 2026-09-28 review, item 89 D1).
    let thermalState: @MainActor () -> ProcessInfo.ThermalState   // internal for MonitoringEngine+Thermal.swift

    init(settings: AppSettings,
         eventStore: EventStore,
         cloud: CloudExfiltrator,
         camera: any EvidenceCamera,
         entitlements: ProEntitlements,
         timing: EngineTiming = .production,
         protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
         thermalState: @escaping @MainActor () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        let connectivity = ConnectivityMonitor()
        self.connectivity = connectivity
        self.settings = settings
        self.eventStore = eventStore
        self.cloud = cloud
        self.camera = camera
        self.entitlements = entitlements
        self.timing = timing
        self.protectedDataAvailable = protectedDataAvailable
        self.thermalState = thermalState
        let capturePipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        self.capturePipeline = capturePipeline
        self.disarmEntry = DisarmEntryCoordinator(timing: timing)
        let cloudCoordinator = MonitoringCloudCoordinator(
            settings: settings, eventStore: eventStore, cloud: cloud, entitlements: entitlements,
            timing: timing, connectivity: connectivity, thermalState: thermalState)
        self.cloudCoordinator = cloudCoordinator
        self.tripResponder = MonitoringTripResponder(
            settings: settings, eventStore: eventStore, camera: camera, capturePipeline: capturePipeline,
            cloudCoordinator: cloudCoordinator, connectivity: connectivity, timing: timing, thermalState: thermalState)
        self.armingFlow = MonitoringArmingFlow(settings: settings, eventStore: eventStore, camera: camera, timing: timing)
        self.eventCount = eventStore.events.count
        installCloudCoordinatorMirrors()
        tripResponder.host = self
        armingFlow.host = self
        installArmingFlowMirrors()
        // The backup-off rules come first (item 115): the settings' resolution below can write a record at once, a
        // reset's (codex-12 on 1.8.2), and a record made while backup is off must be kept on this phone like any other.
        watchBackupSetting()
        seedCloudOwnershipIfReadable()
        capturePipeline.host = self
        camera.onSessionEvent = { [weak self] event in self?.handleCameraSessionEvent(event) }
        disarmEntry.host = self
        // Mirror the pad's open state into the @Published property the PIN pad view binds to,
        // so the extraction leaves the view untouched.
        disarmEntry.onActiveChange = { [weak self] active in self?.disarmEntryActive = active }
        siren.onPlayingElsewhere = { [weak self] output in self?.noteSirenPlayedElsewhere(output) }   // ADR 0062

        // The first-use protection baseline (kept if a valid one was saved, so a change left unreported across a
        // restart is still caught, D6) and the device name, once the settings can be read (ADR 0055).
        runLaunchWorkWhenSettingsResolve()
        // Enables UIDevice.orientation (face-up/face-down) for the "Auto" camera.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        buildMonitors()
        observeGuidedAccess()
        observeBatteryState()
        observeRemotePush()
        connectivity.onChange = { [weak self] online in self?.handleConnectivityChange(online) }
        connectivity.start()
        // Lift the covert screen out of true black whenever the camera goes live, and drop
        // back when it stops (2.5.14 — the REC badge must be visible while recording).
        // `.receive(on:)` defers past the @Published willSet, so the property reads current.
        recordingIndicatorSub = camera.isRecordingActivePublisher
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBrightness() }
        handTheUploaderTheLog()   // item 162's A10
        recoverInterruptedSessionIfNeeded()
        UserDefaults.standard.removeObject(forKey: Self.retiredGuidedAccessAtDisarmKey)   // item 70
        // The launch-order hole (fifth review, round 3): this init runs inside the app's
        // synchronous construction chain, so the entitlement check CANNOT have resolved yet —
        // the recovery re-arm above always defers behind the 31.F2 gate, the scene-activation
        // pass (`handleScenePhase`) merely races StoreKit's first answer, and nothing else
        // ever re-ran it. Observe the first resolution and release what the gate deferred:
        // the owed re-arm (SECURITY.md's "visible, cancellable countdown" promise) and the
        // pending-evidence flush (which also pushes a just-logged interruption record).
        // `.filter` drops the initial unresolved value, `.prefix(1)` completes after the
        // first resolution, and `.receive(on:)` defers past the @Published willSet so
        // `hasResolved` reads true inside the handler (same trick as above).
        entitlementResolutionSub = entitlements.$hasResolved
            .filter { $0 }
            .prefix(1)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleEntitlementResolved() }
    }

    /// If a prior armed session didn't disarm cleanly (marker still set after a
    /// force-quit or crash), restore the user's screen brightness — covert mode may
    /// have stranded the *system* brightness near 0 with no chance to reset it — log
    /// the interruption, and owe the auto re-arm. The evidence retry rides the
    /// entitlement-resolution hook instead of running here: this method runs before
    /// the Pro check can possibly have resolved, so a retry fired from here always
    /// no-oped behind its Pro gate (fifth review, R1.2).
    ///
    /// `appIsActive`: the app has just become active, which settles the lock question — an app
    /// on screen means an unlocked phone (item 85).
    private func recoverInterruptedSessionIfNeeded(appIsActive: Bool = false) {
        // Item 65, finding 18: a push can launch the app while the device is locked. Consuming
        // the marker and boot stamp now, the record below goes into a store that cannot
        // persist until the unlock — and if iOS ended the process first, the interruption was
        // gone for good (the owed re-arm survived; the evidence did not). Wait for the unlock,
        // everything untouched, and run once then. The re-arm defers to the foreground anyway.
        // Item 85: this runs inside `MalinoisApp.init`, where UIKit answers "locked" even on an
        // unlocked phone, and an unlocked phone sends no unlock notice — 1.3.2 waited until the
        // next lock and unlock. So the wait also ends when the app becomes active.
        guard appIsActive || protectedDataAvailable() else { observeProtectedDataForRecovery(); return }
        let defaults = UserDefaults.standard
        // Read (and clear) the boot stamp planted with the marker, and classify the ending —
        // the device restarted, or only the app ended (BACKLOG 53). A marker with no stamp
        // (a build before 53) stays unclassified; the record is then the bare "interrupted".
        let cause = BootStamp.classify(armed: consumeBootStamp(), current: BootStamp.current())
        let markerPresent = defaults.object(forKey: Self.armedMarkerKey) != nil
        // A re-arm can be owed even with the marker gone: a prior launch detected the
        // interruption (consuming the marker), deferred the re-arm because it came up in the
        // background, then got terminated before foreground. The persisted flag carries that
        // owed re-arm across the cold launch (M4).
        let reArmOwed = defaults.bool(forKey: Self.pendingReArmKey)
        let recoveryInterrupted = defaults.bool(forKey: Self.recoveryInProgressKey)
        // A countdown that never went live (review 3, R3.2): the marker `startGraceCountdown`
        // plants is consumed at go-live and at cancel, so one left behind means the app ended
        // mid-countdown — an OOM, a thermal kill, a force-quit. Say so; do NOT re-arm: a
        // force-quit during the countdown is the owner's own abort far more often than an
        // attack (review 1, F1 scope (b), declined by the owner). When a recovery path below
        // applies it owns the launch — a recovery countdown plants this marker too.
        let armingInterrupted = defaults.bool(forKey: Self.armingInProgressKey)
        guard markerPresent || reArmOwed || recoveryInterrupted else {
            if armingInterrupted {
                // A swipe-away during the countdown logged the lapse at background time; that
                // record IS this interruption, and a second one said it twice (item 74, line 6).
                let lapseLogged = defaults.bool(forKey: Self.backgroundLapseLoggedKey)
                defaults.removeObject(forKey: Self.backgroundLapseLoggedKey)
                if !lapseLogged { logStateChange("armingInterrupted") }
                retireRecoveryMarker(Self.armingInProgressKey)
            }
            return
        }
        if markerPresent {
            // Fresh interruption: retain its marker until the record and owed re-arm are installed,
            // so another termination cannot erase recovery between those steps. A later launch
            // with only the owed flag does not repeat this work. Restore the pre-arm brightness.
            let savedBrightness = defaults.double(forKey: Self.armedMarkerKey)
            UIScreen.main.brightness = Self.restoredBrightness(previous: CGFloat(savedBrightness))
            recoveredInterruptedSession = true
            // The armed app was killed without a clean disarm (force-quit, Voice Control
            // "Close application", or an OS/OOM crash) — the kill itself leaves no capture, so
            // LOG the fact, so an interruption isn't evidence-free. Its push to the owner's
            // other devices — and the retry of anything else pending — rides
            // `handleEntitlementResolved`: fired from here they always no-oped, this init
            // being unreachable with the Pro check already resolved (fifth review, R1.2).
            // Recorded even when the re-arm is later suppressed.
            //
            // Unless the lapse was already logged when the app was backgrounded, in which case
            // this launch is the tail of that same interruption rather than a new one — except
            // for a RESTART, which is recorded regardless (item 53, found on the Air
            // 2026-09-02: without Guided Access the force-restart's own side-button press
            // backgrounds the session first, and the restart then vanished behind this rule).
            // The re-arm below still runs; only a duplicate record is suppressed.
            let alreadyLogged = defaults.bool(forKey: Self.backgroundLapseLoggedKey)
            defaults.removeObject(forKey: Self.backgroundLapseLoggedKey)
            if Self.shouldLogRelaunchInterruption(cause: cause, lapseAlreadyLogged: alreadyLogged) {
                logInterruptedSession(cause: cause)
            }
            // A re-arm is now owed; persist it so it survives a background launch that iOS
            // terminates before the owner foregrounds it (M4).
            defaults.set(true, forKey: Self.pendingReArmKey)
        } else if recoveryInterrupted {
            // The recovery countdown ITSELF was killed (F1). Log this interruption too and
            // owe a fresh re-arm; the attempt-timed crash-loop guard still breaks kill loops.
            logInterruptedSession(cause: cause)
            defaults.set(true, forKey: Self.pendingReArmKey)
        }

        // The interruption is recorded (or its existing lapse record stands), and the owed re-arm
        // now covers another launch. Retire every predecessor only after that handoff.
        if markerPresent { retireRecoveryMarker(Self.armedMarkerKey) }
        if recoveryInterrupted { retireRecoveryMarker(Self.recoveryInProgressKey) }
        if armingInterrupted { retireRecoveryMarker(Self.armingInProgressKey) }

        // Re-arm re-enters the arming flow with a *visible*, cancellable grace countdown —
        // the owner's cancel window (F-12/R-04). `init` also runs on a background (push)
        // launch where nobody's watching, so defer to the first foreground there; attempt it
        // now on a foreground launch (V-04) — where it defers again behind the entitlement
        // gate, and the resolution hook re-runs it the moment the check completes (round 3).
        // The owed flag persists throughout, so a terminate before any of those loses nothing.
        if UIApplication.shared.applicationState != .background {
            performRecoveryReArm()
        }
    }

    /// The entitlement check just resolved for the first time (see the subscription in
    /// `init`). Run the launch work its gate deferred, the moment that becomes possible
    /// rather than on the next app switch: the owed crash-recovery re-arm, and the
    /// pending-evidence retry — the same pair `handleScenePhase` re-attempts on foreground,
    /// which remains the backstop. A background (push) launch still defers the *visible*
    /// re-arm to the first foreground (V-04): a countdown nobody can see or cancel must not
    /// start unwatched, and the owed flag persists for `handleScenePhase` (M4). The retry
    /// runs either way — it is what pushes an interruption record logged at init, and it
    /// no-ops off Pro.
    private func handleEntitlementResolved() {
        // Item 114's marker is Pro only: hear the event limit's removals from now on, the trims
        // made while the log loaded at launch included, which the store kept (item 116, R6).
        watchCountEvictions()
        // While the launch recovery still waits, the owed re-arm is its to run (item 88): run
        // here first, the recovery would read this countdown's own marker as a killed countdown
        // and record a false interruption. It re-arms when it runs, and the entitlement has
        // resolved by then.
        if state == .disarmed, !launchRecoveryWaiting,
           UserDefaults.standard.bool(forKey: Self.pendingReArmKey),
           UIApplication.shared.applicationState != .background {
            performRecoveryReArm()
        }
        Task {
            await retryPendingSync()
            await restoreFromCloudAtLaunch()   // owner, 2026-09-04: the log fills without a visit to it
        }
    }

    // The launch pull's pure rules (`launchSyncLimit`, `launchPullKind`) are in
    // MonitoringCloudCoordinator+LaunchPull.swift; the compatibility facade forwards existing calls.

    // MARK: - Recovery re-arm, going to the background, the interruption records

    #if DEBUG
    /// Observes an existing recovery marker immediately after its real removal, without adding a scheduling hop.
    var recoveryMarkerRetiredForTesting: ((String) -> Void)?
    #endif

    /// Retires an existing marker. Its caller owns the successor's ordering; the observer only witnesses that order.
    func retireRecoveryMarker(_ key: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        #if DEBUG
        recoveryMarkerRetiredForTesting?(key)
        #endif
    }

    /// Executes an owed crash-recovery re-arm, applying the crash-loop guard. Retires the owed
    /// flag after installing recovery-in-progress, or recording the declined crash-loop attempt.
    /// Times actual *attempts* (not mere detections), so a re-arm that was only deferred
    /// never counts toward the loop. Called from the foreground: directly on a foreground
    /// launch, from `handleEntitlementResolved` the moment the 31.F2 gate first opens, or
    /// from `handleScenePhase` when a deferred re-arm comes due.
    func performRecoveryReArm() {   // internal for MonitoringEngine+Reinstall.swift
        // Same reasoning as the manual path, with the deferral mechanism that already exists:
        // leave the owed re-arm flagged and let the next foreground pass retry it, rather than
        // re-protecting the device with a session that has lost its Pro tripwires.
        guard !armingBlockedByEntitlementCheck else {
            Log.engine.info("Recovery re-arm deferred until the entitlement check completes")
            return
        }
        // No watch behind the PIN-recovery screen (item 152's lead 18): a backup restored onto another iPhone
        // carries the owed re-arm but not the PIN, and a watch nobody can stop must not start. The flag stays owed,
        // and the recovery's end runs it (`noteRecoveryFinished`).
        guard !pinRecoveryPending else {
            Log.engine.info("Recovery re-arm deferred until the PIN recovery completes")
            return
        }
        // Not on the defaults a launch before the first unlock holds (item 165's A3): the countdown's length, the
        // tripwires and the response are the owner's settings, which load at the unlock. The flag stays owed, and their
        // load runs it.
        guard !settings.awaitingUnlock else {
            Log.engine.info("Recovery re-arm deferred until the settings load")
            settings.whenResolved { [weak self] _ in self?.performOwedRecoveryReArm() }
            return
        }
        let defaults = UserDefaults.standard
        // Re-protect automatically (F-12), but if two re-arm attempts land within the window
        // the armed state itself is crashing the app — stop, so we don't loop; better to
        // stay put (the interruption was logged) so the owner can intervene.
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: Self.recoveryTimeKey)
        defaults.set(now, forKey: Self.recoveryTimeKey)
        guard !Self.isCrashLoop(lastAttempt: last, now: now) else {
            reArmSkipped = true   // Home says so (fable-3)
            logStateChange("reArmSkipped")   // and the Event Log, quietly (item 132's remainder; item 153's MAL-10)
            retireRecoveryMarker(Self.pendingReArmKey)   // the recorded refusal consumes this attempt
            return
        }
        // Cover the countdown window (F1): from here until covert engages there is otherwise
        // no persistent marker, so a kill during grace/calibration would vanish silently.
        defaults.set(true, forKey: Self.recoveryInProgressKey)
        plantBootStamp()   // so a kill inside the countdown can still be told from a restart (53)
        retireRecoveryMarker(Self.pendingReArmKey)   // the countdown's successor is installed
        reArmAfterRecovery()
    }

    /// The recovery re-arm the settings' load ran (item 165's A3): only if it is still owed, on a disarmed engine, with
    /// the app in the foreground, where a recovery countdown can be seen and cancelled (V-04).
    private func performOwedRecoveryReArm() {
        guard state == .disarmed, UserDefaults.standard.bool(forKey: Self.pendingReArmKey),
              UIApplication.shared.applicationState != .background else { return }
        performRecoveryReArm()
    }

    /// Pure (unit-tested). Whether the launch-time interruption record is written when a
    /// background lapse was already logged for the same session (item 53, found on the Air
    /// 2026-09-02): only a restart is — it is new information the lapse record cannot carry.
    /// A termination or an unclassified ending is that lapse's tail, and logging it again
    /// would be the duplicate 32.R6 avoids.
    nonisolated static func shouldLogRelaunchInterruption(cause: InterruptionCause?,
                                                          lapseAlreadyLogged: Bool) -> Bool {
        !lapseAlreadyLogged || cause == .rebooted
    }

    /// Pure (unit-tested): two re-arm attempts inside the window mean arming is crash-looping.
    /// A clock set back between attempts makes the delta negative — not "less than 90 seconds
    /// later" but an unknowable gap; it reads as no loop, so a legitimate recovery is never
    /// refused for an epoch that ran backwards (item 73, review 1 F2).
    nonisolated static func isCrashLoop(lastAttempt: TimeInterval, now: TimeInterval,
                                        window: TimeInterval = 90) -> Bool {
        let delta = now - lastAttempt
        return lastAttempt > 0 && delta >= 0 && delta < window
    }

    /// Records that the armed app was killed without a clean disarm, so the interruption
    /// leaves a log entry and a cross-device alert instead of vanishing silently. Even when
    /// the crash-loop guard then declines to re-arm — e.g. someone repeatedly issuing Voice
    /// Control "Close application" — the owner still learns their device is being closed.
    /// Set when a background lapse has already been logged for the *current* armed session, so
    /// crash recovery doesn't log the same lapse a second time at next launch. Cleared on
    /// returning to the foreground, because a kill after that is a genuinely separate
    /// interruption and does deserve its own record.
    static let backgroundLapseLoggedKey = "com.malinois.armed.backgroundLapseLogged"

    /// When a live watch was last sent to the background, on the clock no setting moves (`lapseNow`): its return
    /// records how long nothing was watched (item 153's MAL-06). In memory only: a process killed meanwhile never
    /// resumes, and its relaunch records the interruption instead.
    var backgroundLapseStartedAt: ContinuousClock.Instant?

    /// An active session — arming, calibrating or armed — has been sent to the background,
    /// so protection has stopped, or never finished starting (32.R6).
    ///
    /// iOS gives no way to keep watching: the camera cannot run in the background, and the only
    /// background mode this app declares is `remote-notification`, so the process is suspended
    /// shortly after. Under Guided Access — the configuration Malinois is designed to run in —
    /// this cannot happen at all. Without it, it can, and until now it produced **nothing**: a
    /// stretch with no protection and no entry in the log saying so, which is exactly the
    /// silence this app exists to replace. Someone swiping the app away to handle a device
    /// unobserved is not a hypothetical attacker; it is the obvious move.
    func handleEnteredBackground() {
        guard state.isActive else { return }
        Log.engine.warning("Armed session sent to the background; monitoring has stopped")
        logInterruptedSession(cause: Self.backgroundInterruptionCause(guidedAccessOn: guidedAccessEnabled,
                                                                      duringCountdown: state == .arming))
        UserDefaults.standard.set(true, forKey: Self.backgroundLapseLoggedKey)   // after the record (item 144's L)
        if armedSince != nil, backgroundLapseStartedAt == nil { backgroundLapseStartedAt = lapseNow }   // item 153's MAL-06
    }

    /// Pure (unit-tested; review 3, R3.3 + item 74, line 6): what sent an active session to the
    /// background. During the countdown the watch is not live yet, and the lapse is named for
    /// the countdown so the relaunch does not record the same interruption twice. Under Guided
    /// Access nothing but the lock button can background a live watch — no app switcher, no
    /// Home, calls to voicemail — so that lapse is named a lock; without it a swipe-away is as
    /// likely, and the generic cause stands.
    nonisolated static func backgroundInterruptionCause(guidedAccessOn: Bool, duringCountdown: Bool) -> InterruptionCause {
        if duringCountdown { return .backgroundedDuringCountdown }
        return guidedAccessOn ? .locked : .backgrounded
    }

    /// Logs the interruption record. `cause` is what could be told about the ending — a
    /// restart, an app kill, a backgrounding (BACKLOG 53); nil keeps the bare record.
    private func logInterruptedSession(cause: InterruptionCause?) {
        let event = Event(startDate: Date(), endDate: Date(),
                          triggeredSensors: [], cloudSyncState: .pending, interrupted: true,
                          interruptionCause: cause?.rawValue)
        cloud.enrollment.registerLocalEvent(event)
        eventStore.add(event)
        eventCount = eventStore.events.count
        pushFactIfCloud(event)   // cross-device alert (Pro); free tier keeps it in the local log
    }

    /// Logs an explicit "armed" / "disarmed" record so the timeline of when protection was
    /// on or off is auditable — the point being the disarm case: an attacker who knows the
    /// PIN can turn monitoring off, but there's no delete affordance, so the "disarmed" entry
    /// stands as proof of exactly when it happened (rather than the owner having to infer it
    /// from a re-armed session's start time). Pushed to the cloud as a silent audit record
    /// (BACKLOG 8); a disarm additionally writes the disarm signal that fires the
    /// correctly-worded push on the owner's other devices (BACKLOG 59) — never through the
    /// tamper subscription, whose static body would be wrong and noisy for a routine arm.
    @discardableResult
    func logStateChange(_ kind: String, id: UUID = UUID(), sessionCloudAllowed: Bool? = nil) -> Event {
        // `.pending` rather than `.localOnly`: these now DO leave the device (BACKLOG 8),
        // via the silent `TamperEventState` type. `exfiltrate` resolves the state — and
        // marks it `.localOnly` for a genuinely free user, so the badge stays honest.
        // `id` is the caller's when the record must be found again: a reset's (codex-17 on 1.8.2).
        let event = Event(id: id, startDate: Date(), endDate: Date(),
                          triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
        cloud.enrollment.registerLocalEvent(event)
        eventStore.add(event)
        eventCount = eventStore.events.count
        let record = event
        // Authorization decided NOW, when the record is created — the task runs after the
        // caller returns, and by then the session snapshot may already be cleared (34 review).
        let allowed = sessionCloudAllowed ?? cloudAllowed
        let hold = BackgroundAssertion.begin("malinois-state-task")   // before the task (item 153's MAL-01)
        beginBindingUse(record.id)   // until the upload ends: its pin starts only in the task (codex-6 on 0ed887f)
        Task {
            defer { hold.end(); endBindingUse(record.id) }
            await exfiltrate(record, cloudAllowedOverride: allowed)
        }
        return event
    }

    // MARK: - Thermal sentinel (item 38): the records and the listener are in
    // MonitoringEngine+Thermal.swift; the state a watch keeps stays here.

    var thermalObserver: NSObjectProtocol?
    /// Times each watch against a clock no setting can move (item 113; MonitoringEngine+ClockWatch.swift).
    let clockWatch = ClockWatch()
    /// The thermal record kinds this watch has written: each is written once a session.
    var thermalKindsLogged: Set<String> = []

    /// Re-enter the arming flow after a recovered interruption, skipping the Guided
    /// Access coaching (it was presumably already set up) so the device re-protects on
    /// its own. The grace countdown still runs, so the owner can cancel if present.
    private func reArmAfterRecovery() {
        guard state == .disarmed else { return }
        beginArming()
        armWasAutoRecovered = true   // must set AFTER beginArming (which clears it)
        refreshGuidedAccess()
        // Bypasses the "Require Guided Access" gate on purpose: a crash may well have ended
        // Guided Access, and refusing to re-arm would leave the device unprotected (F-12).
        beginGraceCountdown()
    }

    private func buildMonitors() {
        let motion = makeMotionMonitor()   // stall reports wired (item 144 (g))
        let power = PowerMonitor()
        let proximity = ProximityMonitor()
        let audio = makeAudioMonitor()   // health reports wired (item 105, F-09)
        let vision = VisionMonitor()
        monitors = [
            .motion: motion, .power: power, .proximity: proximity, .audio: audio, .vision: vision
        ]
        // Frames from the camera's video tap feed the vision tripwire (BACKLOG 16).
        camera.onVisionFrame = { [weak vision] frame in vision?.ingest(frame) }
        for (_, m) in monitors {
            m.onTrip = { [weak self] type in self?.handleTrip(type) }
        }
    }

    #if DEBUG

    /// Test-only (item 153's MAL-06): the clock a lapse is timed on, in place of `ContinuousClock`.
    var lapseClockForTesting: (() -> ContinuousClock.Instant)?
    /// Test-only (Codex's note on d084392): the alert-subscription refreshes a reconnect has asked for, counted as it
    /// asks, so a test sees that none was without waiting for a task that would come later.
    var alertRefreshesAskedForTesting = 0

    #endif

    /// A CloudKit push means another of the owner's devices just recorded a tamper. Pull the
    /// evidence down and keep a copy here (BACKLOG 9b) — the point being that the copy then
    /// lives somewhere the attacker holding the *other* device cannot reach.
    ///
    /// Posted by the AppDelegate rather than called directly: UIKit constructs that object
    /// and it has no handle on the engine, so a notification keeps the boundary intact. The
    /// subscription sets `shouldSendContentAvailable`, so this can run with the app in the
    /// background — which is exactly when it matters most and is least visible.
    private func observeRemotePush() {
        RemotePushCoordinator.shared.onPush = { [weak self] in
            await self?.handleRemotePush() ?? .noData
        }
        // A tapped tamper alert routes to the Event Log (owner ask, 2026-08-30). The flag
        // is consumed by Home when it can actually present the PIN gate — a tap while armed
        // waits for the disarm, and a cold-launch tap survives until Home first appears.
        RemotePushCoordinator.shared.onOpenEventLog = { [weak self] in
            self?.eventLogOpenRequested = true
        }
    }

    /// A tapped cross-device alert asked for the Event Log. Home consumes this (and shows
    /// its PIN gate); published so it survives launch/arming states until Home is visible.
    @Published private(set) var eventLogOpenRequested = false
    func consumeEventLogOpenRequest() { eventLogOpenRequested = false }

    /// The one-shot observers behind the locked-launch deferral above: the unlock (item 65,
    /// finding 18) and the app becoming active (item 85), whichever comes first. Idempotent:
    /// only the first locked launch arms them. The first to fire removes both, so the recovery
    /// runs once — a second run would find the recovery countdown's own marker and record it as
    /// a new interruption.
    private var protectedDataRecoveryObserver: NSObjectProtocol?
    private var activeRecoveryObserver: NSObjectProtocol?

    /// The launch recovery has not run yet: it waits for the unlock or the app becoming active
    /// (items 65 and 85). The entitlement hook and the foreground pass defer to it (item 88).
    var launchRecoveryWaiting: Bool { protectedDataRecoveryObserver != nil }   // internal for +Reinstall.swift

    private func observeProtectedDataForRecovery() {
        guard protectedDataRecoveryObserver == nil else { return }
        let center = NotificationCenter.default
        protectedDataRecoveryObserver = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runDeferredRecovery(appIsActive: false) }
            }
        activeRecoveryObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.runDeferredRecovery(appIsActive: true) }
            }
    }

    /// Runs the waiting launch recovery from whichever observer fired first, and removes both.
    /// After the unlock it re-checks, and waits again if the device re-locked meanwhile.
    func runDeferredRecovery(appIsActive: Bool) {
        guard let unlockToken = protectedDataRecoveryObserver else { return }   // already ran
        NotificationCenter.default.removeObserver(unlockToken)
        if let activeToken = activeRecoveryObserver { NotificationCenter.default.removeObserver(activeToken) }
        protectedDataRecoveryObserver = nil
        activeRecoveryObserver = nil
        recoverInterruptedSessionIfNeeded(appIsActive: appIsActive)
    }

    private func observeGuidedAccess() {
        guidedAccessObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshGuidedAccess() }
            }
    }

    func refreshGuidedAccess() {
        guidedAccessEnabled = guidedAccessNow
    }

    /// Whether Guided Access is on: iOS's answer, or, under the test seam, the test's.
    private var guidedAccessNow: Bool {
        #if DEBUG
        if let on = guidedAccessForTesting { return on }
        #endif
        return UIAccessibility.isGuidedAccessEnabled
    }

    #if DEBUG
    /// Test-only (item 92): turns Guided Access on or off as the engine sees it, the way iOS's
    /// notice does. The simulator cannot start a Guided Access session.
    func simulateGuidedAccessForTesting(on: Bool) {
        guidedAccessForTesting = on
        refreshGuidedAccess()
    }
    private var guidedAccessForTesting: Bool?
    /// Test-only (1.8.2's step 34): whether the phone has no passcode, as the engine reads it. The Simulator has one.
    var devicePasscodeMissingForTesting: Bool?
    #endif

    // MARK: - Camera battery-readiness

    nonisolated static func isChargingState(_ state: UIDevice.BatteryState) -> Bool {
        state == .charging || state == .full
    }

    private func observeBatteryState() {
        batteryStateObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleBatteryStateChange() }
            }
    }

    /// Reacts to plug/unplug. Only the Auto policy cares — Instant and Battery saver
    /// are fixed. Plugging in mid-watch restores instant capture; unplugging stands
    /// the camera down (deferred, so a simultaneous unplug trigger still shoots warm).
    private func handleBatteryStateChange() {
        let charging = Self.isChargingState(UIDevice.current.batteryState)
        guard charging != isCharging else { return }
        isCharging = charging
        guard state == .armed, settings.cameraReadiness == .auto, settings.isEnabled(.camera) else { return }
        if cameraShouldBeWarm {
            cameraStandbyTimer?.invalidate(); cameraStandbyTimer = nil
            // Only re-warm if we're not already mid-capture (the session is up then).
            if !isHandlingTrigger && !isCapturingUntilClear { warmActiveCamera() }
        } else {
            scheduleCameraStandby()
        }
    }

    /// Defer standing the camera down: if the unplug also fired a trigger, that
    /// capture runs on the still-warm session and `respond` tears it down after;
    /// otherwise this timer does, once nothing is capturing.
    private func scheduleCameraStandby() {
        cameraStandbyTimer?.invalidate()
        cameraStandbyTimer = Timer.commonMode(interval: cameraStandbyDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.standByCameraIfIdle() }
        }
    }

    private func standByCameraIfIdle() {
        cameraStandbyTimer = nil
        guard state == .armed, !cameraShouldBeWarm, !isHandlingTrigger, !isCapturingUntilClear else { return }
        camera.shutDown()
    }

    // MARK: - Arming flow

    /// Step 1: user tapped Arm → show the Guided Access coaching screen.
    /// Evidence metadata's device name: the owner's label if set, else the (generic on
    /// modern iOS) system name. Refreshed each arm so a Settings edit takes effect (F-24).
    func refreshDeviceName() {   // internal for MonitoringEngine+SettingsGuard.swift
        // Unlabeled fallback is the MODEL name, not `UIDevice.name` — iOS hands apps a
        // generic "iPhone" there, which made every unlabeled device's mirrors anonymous
        // (owner's call, 2026-08-30: two "iPhone Air"s in a log beat two "iPhone"s).
        DeviceInfo.name = Self.sanitizedDeviceLabel(
            settings.deviceLabel,
            fallback: DeviceInfo.marketingName(forIdentifier: DeviceInfo.modelIdentifier))
    }

    /// Pure (unit-tested). The label rides in every cloud record and cross-device alert, so
    /// it is bounded here at the source (34 review, validation) — an unbounded free-text
    /// field has no business inside evidence metadata.
    nonisolated static func sanitizedDeviceLabel(_ raw: String, fallback: String) -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
        return label.isEmpty ? fallback : String(label)
    }

    /// Pure (unit-tested). The tamper warning is owner-authored free text rendered
    /// full-screen at trigger time — same rule as the device label (R1-L4, "store intent,
    /// clamp at use"): bounded at the render so no stored value, however it got there,
    /// can turn the alert screen into an unbounded scroll, and blank falls back to the
    /// default so a cleared field can't blank the tamper screen.
    nonisolated static func sanitizedAlertMessage(_ raw: String, fallback: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        return message.isEmpty ? fallback : String(message)
    }

    // MARK: - Pro gating (snapshot at arm; "store intent, clamp at use")

    /// Pro entitlement captured at arm and held for the whole armed session, so an
    /// entitlement change mid-watch never *downgrades* a live session (paywall spec §5).
    var armedPro = false
    private var effectiveSensors: Set<SensorType> { settings.effectiveEnabledSensors(pro: armedPro) }
    private func sensorEnabled(_ t: SensorType) -> Bool { effectiveSensors.contains(t) }
    var effectiveCameraPosition: CameraChoice { settings.effectiveCameraPosition(pro: armedPro) }
    private var effectiveCaptureMode: CaptureMode { settings.effectiveCaptureMode(pro: armedPro) }

    /// The capture mode to use for a capture happening *right now*.
    ///
    /// Recording a clip needs the microphone, and a capture session holding a mic input takes
    /// the app's audio session — which silences a sounding siren. That made further tampering
    /// *quieten* the alarm: picking the phone up fired a new trigger, the clip capture seized
    /// audio, and the siren stopped. Exactly backwards.
    ///
    /// In Siren mode capture is therefore **stills, from the very first trigger** (F4): the
    /// old gate only collapsed clips once the alarm was *already* sounding, so the first
    /// trigger of a Siren + until-clear session recorded up to 120 s of clip — extended by
    /// the tampering itself — before the alarm ever started, and the ramp then opened quiet.
    /// A ~1 s still satisfies the evidence-before-response invariant (the fact push is
    /// independent of capture mode anyway) and the alarm starts within ~2 s. Little is lost —
    /// a clip's audio track during a blaring siren records the siren.
    private var captureModeNow: CaptureMode {
        Self.captureModeForNow(configured: effectiveCaptureMode,
                               sirenResponse: settings.responseMode == .siren,
                               sirenSounding: siren.isPlaying,
                               escalationForcesSiren: escalation?.forcesSiren ?? false)
    }

    /// Pure (unit-tested). Clips collapse to a still whenever an alarm is sounding OR the
    /// response mode would sound one for this trigger.
    nonisolated static func captureModeForNow(configured: CaptureMode, sirenResponse: Bool,
                                              sirenSounding: Bool,
                                              escalationForcesSiren: Bool) -> CaptureMode {
        guard configured.isClip else { return configured }
        return (sirenResponse || sirenSounding || escalationForcesSiren) ? .photo : configured
    }

    /// Pushes the tamper fact to CloudKit only for a Pro/in-trial session — the free tier
    /// keeps evidence on-device. Single choke point so every push is gated identically.
    /// Cloud is allowed when this session armed as Pro (the `armedPro` snapshot) OR the user
    /// is Pro right now. The `||` only ever ADDS capability, so it can't downgrade a live
    /// session — and because `beginArming` re-snapshots `armedPro` every arm and `disarm()`
    /// clears it, the snapshot is never stale outside a live session. (It used to survive
    /// disarm, which left `cloudAllowed` true for a lapsed-trial user and let a connectivity
    /// change re-establish the push subscription off-session.) The non-session retry path
    /// stays on the strict `entitlements.proActive` gate (`retryPendingSync`) regardless.
    /// This is the coherent gate for every mid-session cloud call — exfiltrate, the fast
    /// fact-push, and the reconnect subscription (P-01).
    var cloudAllowed: Bool { armedPro || entitlements.proActive }

    /// Whether the camera session should be kept warm right now, per the user's
    /// battery-readiness setting and the current charging state.
    private var cameraShouldBeWarm: Bool {
        settings.isEnabled(.camera) && settings.cameraReadiness.keepsCameraWarm(charging: isCharging)
    }

    // MARK: - Camera warm-up at arm (the bounded warm-up itself is EvidenceCapturePipeline.withDeadline)

    /// Bumped on every new warm intent. A warm-up that outlived its deadline still finishes
    /// eventually on the session queue; comparing against the generation it was started
    /// under keeps its state writes (vision-tap status, warm-up-failure notices) from
    /// clobbering whatever a NEWER warm has since established.
    private var cameraWarmGeneration = 0

    /// Brings up the session for whichever camera(s) the settings select — used both
    /// for the pre-arm warm and when Auto flips back to warm (device plugged in).
    func warmActiveCamera() {
        guard settings.isEnabled(.camera) else { return }
        // Never asked yet (Guided Access blocked the ARM tap's ask, item 69): no warm-up and
        // no "camera unavailable" notice — the arming screen carries the honest one.
        guard camera.videoPermission != .notDetermined else { return }
        syncVisionTap()
        // Warm the shape the NEXT CAPTURE will actually use, not the configured one.
        //
        // These two decisions used to disagree, and the disagreement was expensive. Warming
        // used `effectiveCaptureMode` (a clip → mic attached), while every capture during an
        // alarm uses `captureModeNow` (a still → no mic, F4). So each trigger rebuilt the
        // session twice, and because attaching a mic seizes the app's audio session, every
        // rebuild interrupted the siren — which then resumed itself through SirenPlayer's
        // interruption handler. On device (2026-08-26) that was an alarm dying roughly every
        // five seconds and restarting, plus a vision tap torn down and re-established on every
        // cycle, plus a still capture that eventually timed out mid-reconfiguration.
        //
        // Agreeing with `captureModeNow` means that in Siren mode the session is simply never
        // clip-shaped while armed: no mic, no audio-session contention, and the vision tap
        // stays up continuously instead of being rebuilt per trigger.
        let forClips = captureModeNow.isClip
        camera.clipAudio = Self.clipAudioAllowed(setting: settings.clipAudio,
                                                 micGranted: AVAudioApplication.shared.recordPermission == .granted)
        cameraWarmGeneration += 1
        let generation = cameraWarmGeneration
        if effectiveCameraPosition == .both && camera.supportsMultiCam {
            Task { [camera] in
                do { _ = try await EvidenceCapturePipeline.withDeadline(timing.warmUpDeadline) { try await camera.warmUpMultiCam(forClips: forClips) } }
                catch { if generation == cameraWarmGeneration { reportCameraWarmupFailure(error) } }
                guard generation == cameraWarmGeneration else { return }   // a newer warm owns the state now
                visionMonitor?.tapActive = camera.visionTapActive
                visionTapUnavailable = (camera.visionTapActive == false)
                refreshMicNotice()
            }
        } else {
            let warmCamera: CameraChoice
            switch effectiveCameraPosition {
            case .rear: warmCamera = .rear
            case .auto: warmCamera = resolveAutoCamera()
            default:    warmCamera = .front   // front, both-unsupported
            }
            Task { [camera] in
                do { _ = try await EvidenceCapturePipeline.withDeadline(timing.warmUpDeadline) { try await camera.warmUp(forClips: forClips, camera: warmCamera) } }
                catch { if generation == cameraWarmGeneration { reportCameraWarmupFailure(error) } }
                guard generation == cameraWarmGeneration else { return }   // a newer warm owns the state now
                visionMonitor?.tapActive = camera.visionTapActive
                visionTapUnavailable = (camera.visionTapActive == false)
                refreshMicNotice()
            }
        }
    }

    /// Permission preflight (F7): a denied camera or microphone must be surfaced at ARM
    /// time, not discovered when a capture fails. The camera check is independent of the
    /// warm/cold readiness decision — under Auto-on-battery or Battery saver the camera is
    /// never warmed at arm, so warm-up failure reporting alone left a denied camera fully
    /// silent in exactly the common unattended configuration. Only definitive denial warns;
    /// `.notDetermined` just means the launch prompt hasn't been answered yet.
    private func refreshPermissionNotices() {
        let cam = camera.videoPermission
        if settings.isEnabled(.camera), cam == .denied || cam == .restricted {
            cameraNotice = "Camera access is denied - no photo or video evidence can be captured. Allow Camera in iOS Settings → Privacy."
        }
        if settings.isEnabled(.camera), cam == .notDetermined {
            // Only reachable when Guided Access blocked the ARM tap's ask (item 69, leg 11).
            cameraNotice = "The camera hasn't been allowed yet: iOS can't ask while Guided Access is on. End Guided Access and tap ARM again to allow it."
        }
        // Clips need the mic as much as the Sound tripwire does (34.H12): with Sound off
        // and clip capture on, a denied microphone meant every clip recorded SILENTLY with
        // no warning anywhere — discovered only on playback, after the incident.
        if Self.micPermissionMatters(audioSensorOn: sensorEnabled(.audio),
                                     cameraOn: settings.isEnabled(.camera),
                                     captureIsClip: effectiveCaptureMode.isClip,
                                     multiCam: effectiveCameraPosition == .both
                                        && camera.supportsMultiCam,
                                     clipAudioOn: settings.clipAudio),
           AVAudioApplication.shared.recordPermission == .denied {
            audioNotice = "Microphone access is denied - the Sound tripwire won't run and video clips will have no audio. Allow Microphone in iOS Settings → Privacy."
        }
    }

    /// Pure (unit-tested). Whether a denied microphone deserves a warning at arm time: the
    /// Sound tripwire needs it, and so does clip capture — a clip session without a mic
    /// records silently (34.H12).
    nonisolated static func micPermissionMatters(audioSensorOn: Bool, cameraOn: Bool,
                                                 captureIsClip: Bool, multiCam: Bool = false,
                                                 clipAudioOn: Bool = true) -> Bool {
        // In multi-cam ("Both") mode the clip half is moot: those clips carry no audio track
        // by design (31.F10, disclosed) — a GRANTED mic records nothing either, so a denied
        // one is not the reason and the warning would mislead (eighth review, L9). The same
        // holds when the owner keeps clip audio off (item 69). The Sound tripwire's claim on
        // the mic stands in every mode.
        audioSensorOn || (cameraOn && captureIsClip && !multiCam && clipAudioOn)
    }

    /// Pure (unit-tested). A clip session attaches the microphone only when the owner turned
    /// "Record audio in clips" on AND iOS has granted the microphone (item 69).
    nonisolated static func clipAudioAllowed(setting: Bool, micGranted: Bool) -> Bool {
        setting && micGranted
    }

    /// After a warm-up (item 73, review 1 R7): a clip session that asked for the microphone and
    /// could not attach it records silent clips although the owner asked for sound — the
    /// denied-permission notice never covered this, and the console line reached nobody.
    private func refreshMicNotice() {
        guard camera.micUnavailableForClips else { return }
        audioNotice = "The microphone couldn't be attached to the camera - video clips will have no sound."
    }

    /// Surfaces a camera warm-up failure so the user isn't left "armed but blind".
    private func reportCameraWarmupFailure(_ error: Error) {
        let reason = (error as NSError).localizedDescription
        cameraNotice = "Camera unavailable - evidence capture may fail. Check camera permission. (\(reason))"
        Log.engine.error("Camera warm-up failed at arming: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
    }

    /// Pure (unit-tested). Only the RECEIVING side is at stake: the cross-device
    /// subscription fires server-side, so the sending device needs no notification
    /// permission — but a device that cannot show the "tamper detected" push must say so
    /// instead of implying it will arrive (34.H7). Silent on the free tier and when the
    /// owner has the feature off — there is no alert to miss.
    nonisolated static func notificationNotice(authDenied: Bool, registrationFailed: Bool,
                                               notifyOtherDevices: Bool, pro: Bool) -> String? {
        guard pro, notifyOtherDevices else { return nil }
        if authDenied {
            return "Notifications are off for Malinois - tamper alerts from your other devices won't be shown on this device. Allow Notifications in iOS Settings."
        }
        if registrationFailed {
            return "Push registration failed - this device can't receive cross-device tamper alerts right now."
        }
        return nil
    }

    /// Re-reads notification authorization and the APNs outcome. Called on foreground and
    /// at arm — `notificationSettings` is the only way to observe a toggle flipped in iOS
    /// Settings while the app was suspended (the same blind spot Guided Access has).
    func refreshNotificationHealth() async {
        let center = await UNUserNotificationCenter.current().notificationSettings()
        notificationNotice = Self.notificationNotice(
            authDenied: center.authorizationStatus == .denied,
            registrationFailed: RemotePushCoordinator.shared.registrationFailed,
            notifyOtherDevices: settings.notifyOtherDevices,
            pro: entitlements.proActive)
        notificationAskDue = Self.notificationAskIsDue(
            authUndetermined: center.authorizationStatus == .notDetermined,
            notifyOtherDevices: settings.notifyOtherDevices,
            pro: entitlements.proActive,
            cloudReady: cloud.accountState.isReady,
            otherDeviceSeen: Self.otherDeviceSeen(events: eventStore.events, thisDevice: DeviceInfo.name),
            verified: cloud.enrollment.enrolledAccount != nil,   // its durable grant (item 155's A11)
            hidden: OnboardingState.notificationAskHidden)
    }

    /// Pure (unit-tested; item 69 leg 10, item 73): whether evidence from ANOTHER device on the
    /// account has reached this log.
    /// A device's own pre-reinstall records come back mirrored through the launch restore
    /// (item 67), so "any mirrored record" showed the notifications line on a single-device
    /// account after any reinstall (leg 10 on 43, fail-accepted). Only a record stamped with
    /// another device's name counts; a relabelled device sees the line once, and Hide covers it.
    nonisolated static func otherDeviceSeen(events: [Event], thisDevice: String) -> Bool {
        events.contains { $0.isMirrored && $0.sourceDevice != thisDevice }
    }

    /// Home's Hide button (item 69): remembered per install; Settings → iCloud keeps the ask.
    func hideNotificationAsk() {
        OnboardingState.notificationAskHidden = true
        notificationAskDue = false
    }

    /// Pure (unit-tested). iOS shows no permission alert while Guided Access is on, so an ARM
    /// tap under it cannot ask for the camera (item 69, leg 11 on 40): the arming screen says
    /// so when the camera is needed and has never been asked.
    nonisolated static func cameraAskBlocked(guidedAccessOn: Bool, cameraNeeded: Bool,
                                             undetermined: Bool) -> Bool {
        guidedAccessOn && cameraNeeded && undetermined
    }

    /// Pure (unit-tested). Whether Home should offer the notifications prompt (item 69): only
    /// a device that will RECEIVE cross-device alerts is asked — Pro, iCloud ready, Cross-device
    /// alerts on — only while iOS has never been asked, only once evidence from ANOTHER device
    /// on this iCloud account has arrived in this device's log (a record stamped with another
    /// device's name — `otherDeviceSeen`; owner ask 2026-09-05 —
    /// "that number will be very small for a while") or, since 1.8.2, once this installation has
    /// been verified for iCloud (`verified`; item 155's A11: two devices with one name, or an
    /// account with no events yet, never saw it), and not after the owner tapped Hide.
    nonisolated static func notificationAskIsDue(authUndetermined: Bool, notifyOtherDevices: Bool,
                                                 pro: Bool, cloudReady: Bool,
                                                 otherDeviceSeen: Bool, verified: Bool = false, hidden: Bool) -> Bool {
        authUndetermined && notifyOtherDevices && pro && cloudReady && (otherDeviceSeen || verified) && !hidden
    }

    /// Whether a user-initiated arm is currently blocked for want of Guided Access.
    /// Drives the arming screen, which offers both remedies (turn GA on, or lift the
    /// requirement for this arm) rather than dead-ending.
    var armingBlockedByGuidedAccess: Bool {
        armingFlow.armingBlockedByGuidedAccess
    }

    /// One-shot lift of the Guided Access requirement (eighth review, M2 — option A). The
    /// arming screen's escape button used to flip the STORED setting: an unauthenticated,
    /// unlogged, PERMANENT downgrade available to anyone holding the unlocked phone (arming
    /// is deliberately ungated; disarming is the guarded door). Now the stored setting never
    /// changes from the arming screen: the lift covers the current arming flow only, is
    /// logged and pushed as an audit record (`gaLifted`), and expires when the arming screen
    /// closes or the session ends — the owner's future arms re-assert the requirement.
    @Published private(set) var guidedAccessLiftedThisArm = false

    /// Drives the ARM control. Published so the button can disable itself and say why.
    var armingBlockedByEntitlementCheck: Bool {
        armingFlow.armingBlockedByEntitlementCheck
    }

    /// Turns the raw calibration numbers into plain-language quality labels.
    func makeCalibrationSummary() -> CalibrationSummary {
        var motionQ: String?, motionD: String?, audioQ: String?, audioD: String?
        if settings.isEnabled(.motion), let m = monitors[.motion] as? MotionMonitor {
            let n = m.calibratedNoiseFloor
            motionQ = n < 0.008 ? "Very stable" : n < 0.02 ? "Stable" : "Unsteady - may false-trip"
            motionD = String(format: "Background motion: %.3f g", n)
        }
        if sensorEnabled(.audio), let a = monitors[.audio] as? AudioMonitor {
            if !a.healthy {
                // F7: a dead recorder reports the -160 floor, which the thresholds below
                // would praise as "Very quiet" — a failure dressed as excellence.
                audioQ = "Microphone unavailable"
                audioD = "check mic permission"
            } else {
                let db = a.calibratedBaselineDB
                audioQ = db < -55 ? "Very quiet" : db < -42 ? "Quiet" : db < -30 ? "Moderate" : "Noisy - may false-trip"
                audioD = String(format: "ambient %.0f dBFS", db)
            }
        }
        return CalibrationSummary(motionQuality: motionQ, motionDetail: motionD,
                                  audioQuality: audioQ, audioDetail: audioD)
    }

    /// Begin watching: reset the trip/flood state, snapshot the connectivity canary,
    /// and start the monitors + refractory sweep. Does NOT go covert or leave
    /// `.calibrating` — the calibration review stays visible meanwhile, but the
    /// sensors are already live so there's no blind window before covert.
    private func startWatching() {
        tripResponder.resetForWatchStart()
        // Canary baseline: only a *loss* of a path we had at arm is suspicious.
        // Snapshot the OBSERVED reading, not the optimistic default (R1-L2): before NWPath's
        // first report — the crash-recovery re-arm at launch — "had a path at arm" must be
        // false, or a later offline trigger force-sirens in Stealth on a false jamming call.
        hadConnectivityAtArm = connectivity.observedOnline
        blackoutEscalated = false
        lastMotionTrip = nil
        for (_, m) in monitors where m.isEnabled { m.start() }
        startRefractorySweep()
        if armedSince == nil {
            armedSince = Date()          // start of the watch
            markWatchLive()              // recoverable from THIS moment, not from covert (review 1, F1)
            UserDefaults.standard.removeObject(forKey: Self.cancelRunKey)   // the next cancel is its own (item 169's codex-1)
            let armedRecord = logWatchStart()   // "armed", after an owed reinstall record (item 148's 5); once per watch
            startHeartbeat(session: armedRecord.id)     // item 52: its beats name this record
            armingFlow.consumeLiftSpree() // the watch going live consumes the lift spree (R3-8, narrowed by item 73 R3.4)
            OnboardingState.hasArmedOnce = true   // the first-arm Guided Access auto-lift is now spent (68)
        }
        startThermalSentinel()           // item 38; idempotent within a watch
        startClockWatch()                // item 113
        // Reconcile the camera to the readiness policy at go-live: charging may have
        // changed during the grace/calibration since beginArming's pre-warm decision.
        isCharging = Self.isChargingState(UIDevice.current.batteryState)
        if cameraShouldBeWarm { warmActiveCamera() } else { camera.shutDown() }
    }

    /// Recomputes the "siren too quiet to be heard" warning. Reads `outputVolume` on the
    /// *inactive* shared audio session — the property reflects the system volume without
    /// us activating a session, so we don't risk ducking or interrupting other audio just
    /// to sample it (deliberately conservative per M-02; on-device confirmation pending).
    /// Called at `beginArming` and re-sampled at `confirmGuidedAccessAndStartGrace` — the
    /// point just before the grace step that actually renders the warning (V-06).
    private func refreshSirenVolumeWarning() {
        sirenVolumeLow = settings.responseMode == .siren
            && AVAudioSession.sharedInstance().outputVolume < 0.5
    }

    /// End the calibration review and switch to the covert armed state. Also called
    /// early by fireTrigger when a tamper fires during the review.
    func goCovert() {
        armingFlow.goCovert()
    }

    func applyEnabledAndSensitivity() {
        // Use the effective (Pro-aware) set: the audio tripwire is Pro, so on the free tier
        // its monitor stays disabled (the other tripwires are always free).
        let active = effectiveSensors
        for type in SensorType.tripwires {
            guard let m = monitors[type] else { continue }
            m.isEnabled = active.contains(type)
            m.sensitivity = settings.sensitivity(for: type)
        }
        // Vision only means something with a camera to look through.
        if let v = monitors[.vision] { v.isEnabled = active.contains(.vision) && settings.isEnabled(.camera) }
    }

    private var visionMonitor: VisionMonitor? { monitors[.vision] as? VisionMonitor }

    /// True when the vision tripwire was asked for and the camera could not deliver it — the
    /// multi-cam hardware budget, or a connection that attached and stayed inactive. Published
    /// so the arming screen states what this device actually does, instead of predicting it
    /// from the camera setting. `nil` (camera cold) is not a failure and does not set this.
    @Published private(set) var visionTapUnavailable = false

    /// Tell the camera whether to attach the vision tap on its next warm-up. Called before
    /// every warm-up path so a settings change can't leave the tap in the wrong state.
    func syncVisionTap() {
        camera.setVisionTapEnabled(visionTapWanted)
    }

    /// The engine-side truth `syncVisionTap` hands the camera — also consulted directly
    /// where the engine used to read the camera's own flag back from the main actor
    /// (seventh review, #4: that read was half of the cross-queue race).
    var visionTapWanted: Bool {
        sensorEnabled(.vision) && settings.isEnabled(.camera)
    }

    // MARK: - Screen brightness, the idle timer, the covert screen, the boot stamp and the disarm entry's forwarding: in MonitoringEngine+Screen.swift; its state stays here

    /// The Guided Access screen hold's timer (nil: no hold running), and the number of the latest
    /// hold, so a hold whose end was already on its way never ends the one that replaced it.
    var guidedAccessScreenHoldTimer: Timer?

    var guidedAccessScreenHoldNumber = 0

    // MARK: - Tamper response (alert / siren)

    /// Pure (unit-tested). A *running* alert/siren is ALWAYS kept alive (`.extend`), so a
    /// screen touch can't starve its dismiss timer into silence — only a verified PIN stops
    /// the alarm, never a hold (N-01).
    ///
    /// Starting a *fresh* alert is gated on `activeEntry` — the owner appears to be TYPING
    /// their PIN right now (the pad is up AND a key was pressed within the last 20 s; see
    /// `DisarmEntryCoordinator.presentationSuppressed`, A-02) — so a legitimate disarm isn't spammed with alerts
    /// fighting the raised pad brightness. Held back, not dropped (`.deferred`, item 167's A1): it shows once the typing
    /// stops (the same 20 s) or the pad closes without a correct PIN. Mere pad *openness* is deliberately not enough:
    /// the pad stays up for 30–150 s of inactivity, so gating on openness handed anyone
    /// willing to do the 5-second hold that much guaranteed silence. Nor is the broader
    /// "disarm candidate" window: that opens on any touch-down, and gating there let a snoop
    /// hold the alarm off indefinitely just by keeping a finger on the glass (F1).
    /// (33-review L3: the prose and parameter here were one revision behind the code.)
    nonisolated static func alertAction(showsMessage: Bool, alertActive: Bool,
                                        activeEntry: Bool) -> AlertAction {
        guard showsMessage else { return .none }
        if alertActive { return .extend }
        return activeEntry ? .deferred : .present
    }

    /// Shows the on-screen warning (and starts the siren in siren mode). Called
    /// after capture. Re-triggers / ongoing tamper extend the display window.
    private func presentAlert() {
        alertActive = true
        endCaptureLightForTheWarning()   // a lit clip's white screen would cover it (codex-1)
        refreshBrightness()
        if settings.responseMode == .siren {
            // Ramp (opt-out): quiet for 10s, then rise to full over 10s. The owner's disarm
            // (a 5s hold plus a PIN) fits inside the quiet phase, so handling your own device
            // isn't punished — while anyone who doesn't disarm gets the full alarm. The
            // dismiss window is extended to cover the ramp (see alertDismissInterval).
            soundSiren(fullVolume: false)
        }
        scheduleAlertDismiss()
    }

    /// (Re)start the dismiss countdown so continued tampering keeps the alert /
    /// siren alive — including during a long "until clear" recording, where trips
    /// don't fire fresh events.
    func extendAlertWindow() {
        guard alertActive else { return }
        // Continued tampering is fresh evidence the incident is live: if siren activation
        // exhausted its retries against a held audio session, re-arm the attempt budget
        // instead of extending a silent alarm (eighth-review M5).
        siren.ensureSounding()
        scheduleAlertDismiss()
    }

    func scheduleAlertDismiss() {
        alertDismissTimer?.invalidate()
        let interval = Self.alertDismissInterval(
            base: alertDuration,
            sirenRamping: settings.responseMode == .siren && settings.sirenRampUp,
            rampHold: SirenPlayer.rampHoldSeconds, rampFade: SirenPlayer.rampFadeSeconds)
        alertDismissTimer = Timer.commonMode(interval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissAlert() }
        }
    }

    /// Pure (unit-tested). How long the alert/siren runs before fading.
    ///
    /// A **ramped** siren opens quiet and only reaches full volume after the hold plus the
    /// fade. Dismissing at the plain `base` would stop it *before it was ever loud* — which
    /// is exactly what happened: an 8 s dismiss against a 10 s quiet hold meant the alarm
    /// played inaudibly for 8 s and stopped, two seconds before it began to rise, so Siren
    /// mode appeared completely broken. A ramped siren therefore gets the whole ramp **plus**
    /// the base window at full volume.
    nonisolated static func alertDismissInterval(base: TimeInterval, sirenRamping: Bool,
                                                 rampHold: TimeInterval,
                                                 rampFade: TimeInterval) -> TimeInterval {
        sirenRamping ? rampHold + rampFade + base : base
    }

    private func dismissAlert() {
        // A blackout escalation persists until disarm/reconnect; a flood (and normal
        // alert) fades here.
        guard escalation?.persists != true else { return }
        escalation = nil
        alertDismissTimer?.invalidate(); alertDismissTimer = nil
        alertActive = false
        noteSirenExhaustionIfAny()
        siren.stop()
        resumeAudioAfterSiren()
        refreshBrightness()
    }

    /// Stop the Audio tripwire so the siren can own the audio session.
    /// Frees the audio session so the alarm can actually sound.
    ///
    /// Two things can hold it. The audio tripwire's metering recorder is the obvious one.
    /// The subtler one is the **camera**: a clip-configured `AVCaptureSession` keeps a
    /// microphone input attached and, while warm, keeps running — and a capture session owns
    /// the app's audio session. Activating the siren's `.playback` session then fails with
    /// `insufficientPriority` (OSStatus 561017449, `'!pri'`) and the alarm is never heard.
    /// Since a clip is the DEFAULT capture, that meant Siren mode never worked at all.
    ///
    /// **What gets released is the microphone, not the camera** (BACKLOG 17). The original fix
    /// shut the whole session down, which was correct and verifiable under submission pressure
    /// but coarser than the conflict requires: only the mic input holds the audio session. The
    /// video pipeline can keep running, which matters now that the vision tripwire exists —
    /// it stays watching through the alarm rather than going blind for its entire duration,
    /// at exactly the moment someone is most likely to be moving in front of the lens. It also
    /// spares the following trigger a ~1–2 s cold start.
    ///
    /// Nothing is lost on the capture side: `captureModeForNow` already collapses clips to
    /// stills whenever an alarm sounds or is about to (F4), so the movie output is idle during
    /// an alarm regardless — and a clip's audio track during a blaring siren records the siren.
    ///
    /// The ordering discipline is unchanged and is load-bearing: the session deactivates the
    /// app's audio session when its mic goes away, and firing that off without waiting means
    /// the release lands a second or two later and kills a just-started alarm — heard as the
    /// siren sounding briefly and then dying. So await the release, then sound. Releasing is
    /// safe: this trigger's evidence is already captured and pushed by the time any response
    /// fires. The wait is bounded since 1.8.1 (item 152's lead 6): a session queue that never
    /// answers must not keep the alarm silent, and a release that lands late restarts it.
    func soundSiren(fullVolume: Bool) {
        if sensorEnabled(.audio) { monitors[.audio]?.stop() }
        audioPausedForSiren = true
        let mustReleaseMic = effectiveCaptureMode.isClip && settings.isEnabled(.camera)
        Task { @MainActor in
            // Release the microphone, not the camera (BACKLOG 17). The conflict is over the
            // audio session, which only the mic input holds — so the video pipeline can keep
            // running, and the vision tripwire keeps watching through the alarm instead of
            // going blind for its whole duration.
            if mustReleaseMic { _ = await releaseMicForSiren() }   // at most timing.sirenMicReleaseWait (item 152's lead 6)
            // The owner may have disarmed during the wait — don't resurrect the alarm.
            guard alertActive else { return }
            if fullVolume {   // from this iPhone's speaker in Siren mode (ADR 0062)
                siren.goFullVolume(onSpeaker: sirenOnSpeaker)
            } else {
                siren.start(rampUp: settings.sirenRampUp, onSpeaker: sirenOnSpeaker)
            }
            // The dismiss clock runs from the audible start (item 73, review 2 R2.4): the mic
            // release above took time the interval knew nothing about, and the full-volume
            // tail of the ramp lost exactly that much.
            if !fullVolume { scheduleAlertDismiss() }
        }
    }

    /// Resume the Audio tripwire once the siren has released the audio session.
    func resumeAudioAfterSiren() {
        guard audioPausedForSiren else { return }
        audioPausedForSiren = false
        // `.triggered` counts as watching (item 65, finding 1): an alert window that ends while
        // a capture is still in flight must not leave the Sound tripwire stopped for the session.
        guard Self.audioMayResume(state: state) else { return }
        if sensorEnabled(.audio) { monitors[.audio]?.start() }
        if state == .armed, cameraShouldBeWarm { warmActiveCamera() }   // undo the release above — never mid-capture
    }

    /// Stop the Audio tripwire while a clip records WITH audio (F-14): a capture session that
    /// takes the microphone seizes the app's audio session, which otherwise silently interrupts
    /// our metering recorder; making the contention deliberate means the recorder isn't left
    /// stalled after the clip. This pause releases only metering, preserving the shared audio
    /// session that the already-warm camera needs to record sound. A clip that takes no microphone — the default since item 69's
    /// clip-audio setting — has nothing to contend for, and the tripwire keeps listening through
    /// it (item 73, review 1 R2 (a)); the monitor's own self-heal covers a video-only session
    /// that still disturbs the recorder. Not needed while the siren already owns the session.
    @discardableResult func pauseAudioForCapture() -> Bool {
        guard sensorEnabled(.audio), !audioPausedForCapture, !audioPausedForSiren, camera.clipAudio else { return false }
        monitors[.audio]?.pauseForCapture()
        audioPausedForCapture = true
        return true
    }

    func resumeAudioAfterCapture() {
        guard audioPausedForCapture else { return }
        audioPausedForCapture = false
        // Don't restart under the siren (it owns the session); resumeAudioAfterSiren will.
        // The pipeline resumes here the moment the clip ends, while `respond` still owns the
        // response — the engine is `.triggered`, not `.armed`, and gating on `.armed` alone meant
        // the monitor never came back: the Sound tripwire was silently dead from the first clip
        // capture until disarm (item 65, finding 1; shipped that way in 1.2).
        if Self.audioMayResume(state: state), sensorEnabled(.audio), !audioPausedForSiren {
            monitors[.audio]?.start()
        }
    }

    /// Pure (unit-tested; item 65, finding 1). The Sound tripwire may be restarted after a pause
    /// while the watch is live — armed, or mid-response (`.triggered`, the state every capture
    /// runs in). Never on the way to disarmed, where the monitors are being stopped.
    nonisolated static func audioMayResume(state: MonitoringState) -> Bool {
        state == .armed || state == .triggered
    }

    // MARK: - The jamming response (connectivity blackout): in MonitoringEngine+Jamming.swift

    // MARK: - The camera chosen for a capture

    /// Resolves the "Auto (Rear when face down)" camera: rear only when iOS reports
    /// `.faceDown` (screen hidden, rear lens up); front for every other orientation,
    /// including propped and standing — Auto cannot know which side of an upright phone
    /// faces the room (the short Settings label drops the "otherwise Front" that used to
    /// spell this out, because it was truncated in the settings row).
    func resolveAutoCamera() -> CameraChoice {
        UIDevice.current.orientation == .faceDown ? .rear : .front
    }

    /// Pure (unit-tested). The lens a trigger response uses (owner, 2026-09-05; item 69):
    /// Auto is rear only while the phone lies face down; Rear switches to the front lens when
    /// a screen touch is among the trips, because a screen being touched is facing whoever
    /// touches it and the rear lens then sees the floor or a palm; Front and Both are as set.
    nonisolated static func resolvedCaptureCamera(choice: CameraChoice, faceDown: Bool,
                                                  touched: Bool) -> CameraChoice {
        switch choice {
        case .front, .both: return choice
        case .rear:         return touched ? .front : .rear
        case .auto:         return faceDown ? .rear : .front
        }
    }

    /// The full-screen black overlay calls this on any touch.
    func reportTouch() { handleTrip(.touch) }

    // Test Sensors lives in MonitoringEngine+TestSensors.swift. Trip correlation, refractory re-arm,
    // response and flood capture belong to MonitoringTripResponder. EvidenceCapturePipeline owns
    // the capture mechanism; this engine remains its host and performs physical response actions.

    // MARK: - Published cloud-sweep mirrors; coordination state belongs to MonitoringCloudCoordinator

    /// True for the whole life of a pending sweep, whoever started it — the foreground, a
    /// reconnect, the launch, or the Event Log (item 79). The log's banner used to show its
    /// spinner only for its OWN request, which the single-flight guard turns away at once when
    /// a sweep is already running: the spinner vanished while rows were still turning green.
    @Published private(set) var pendingSweepActive = false

    /// True while the sweep waits out a throttle or an outage between passes (item 79). The
    /// banner says so, because a count that has stopped moving otherwise reads as stuck.
    @Published private(set) var pendingSweepWaiting = false

    // MARK: - Disarm (PIN-gated by caller)

    /// The UI must verify the PIN before calling this. An automatic re-arm stopped here before its
    /// watch went live is recorded as a cancelled countdown (item 168's deepseek-5).
    func disarm() {
        // A live watch ended with the PIN (the armed screen's pad) is the hold learned: the tamper
        // warning drops its tip from then on (item 107). A countdown cancelled before going live
        // does not count. Recorded here, not by the screen, so a test can run it (the test-suite
        // audit's P4).
        if state == .armed || state == .triggered { OnboardingState.hasDisarmedOnce = true }
        // The automatic re-arm stopped before its watch went live: only the PIN on its countdown
        // reaches here then (`cancelArming` refuses it, R-04), and no "disarmed" record follows. On
        // the record as a cancelled countdown is, written now, while the session's iCloud
        // authorization holds, so on Pro the other devices hear of it the same way (item 168's
        // deepseek-5: the stop left nothing).
        if armWasAutoRecovered, armedSince == nil, state == .arming || state == .calibrating {
            logStateChange("armingCancelled")
        }
        armSession &+= 1   // invalidate any in-flight trigger response
        cameraWarmGeneration += 1   // a warm-up still answering is stale: its state writes are dropped (review 3, R3.1)
        // A correct PIN means the owner: anything captured while the pad was open was their
        // own handling, so attribute it rather than spamming the log with it. The coordinator
        // tears its own state down (which clears the @Published mirror) and hands back the set.
        let ownerHandled = disarmEntry.takeOwnerEventsOnDisarm()
        if !ownerHandled.isEmpty {
            eventStore.markOwnerAttributed(ownerHandled)
            reExfiltrateOwnerAttributed(ownerHandled)   // update the cloud copy too (R-06)
        }
        // The disarm audit record must carry the SESSION's cloud authorization, decided
        // before the snapshot below is cleared: its upload task runs after this function
        // returns, and reading `cloudAllowed` at execution time stranded the one record
        // whose whole job is surviving the attacker whenever a trial expired mid-session
        // (34 review).
        let sessionCloudAllowed = cloudAllowed
        // Release the session's Pro snapshot. Left true, `cloudAllowed` stayed true after a
        // trial lapsed, so a later connectivity change re-established the cross-device push
        // subscription for a now-free user (handleConnectivityChange gates on `cloudAllowed`,
        // which the invariant note above wrongly assumed only the proActive-gated retry path
        // could reach). Evidence upload was never affected — arming re-snapshots.
        armedPro = false
        armWasAutoRecovered = false
        clearGuidedAccessLift()   // a lift covers one arm; the session it authorized is over
        capturePipeline.cancelUntilClear()
        tripResponder.discardParkedRetry()   // a retry never crosses a disarm (54)
        alertActive = false
        alertOwedAfterEntry = false   // the owner's PIN: a warning the pad held back is owed no more (item 167's A1)
        alertDismissTimer?.invalidate(); alertDismissTimer = nil
        noteSirenExhaustionIfAny()
        siren.stop()
        // Safe to just clear the flag: the monitors.stop() loop below stops the
        // audio monitor regardless, so no explicit resume is needed here.
        audioPausedForSiren = false
        audioPausedForCapture = false
        armingFlow.stopCountdownAndCalibration()
        tripResponder.stopRefractorySweep()
        blackoutTimer?.invalidate(); blackoutTimer = nil
        tripResponder.stopSustainedClearTimer()
        cameraStandbyTimer?.invalidate(); cameraStandbyTimer = nil
        escalation = nil
        blackoutEscalated = false
        tripResponder.resetFloodAfterDisarm()
        armingFlow.clearReview()
        for (_, m) in monitors { m.stop() }
        stopThermalSentinel()   // item 38
        clockWatch.stop()       // item 113
        camera.shutDown()
        if let armedSince {
            let end = Date()
            lastArmedDuration = end.timeIntervalSince(armedSince)
            lastArmedInterval = (start: armedSince, end: end)
            // Only log a "disarmed" record when a watch was actually running (armedSince set),
            // so cancelling the arming flow before it goes live doesn't create a spurious
            // entry. This is the auditable proof of exactly when protection stopped — written
            // (and journaled, synchronously) BEFORE the armed marker goes, so a crash between
            // the two leaves a recoverable session rather than neither the record nor the
            // marker (item 73, review 3 R11).
            logStateChange("disarmed", sessionCloudAllowed: sessionCloudAllowed)
            noteDisarmForRatingRequest(watchStartedAt: armedSince)   // a calm watch may ask for a rating (item 137)
        }
        releaseCovertScreen()
        armedSince = nil
        stopHeartbeat()   // item 52
        tripResponder.clearTriggerStateAfterDisarm()
        state = .disarmed
        resetGuidedAccessScreenHold()   // auto-lock back, or held a while under Guided Access (item 92)
    }

    /// Where a run of cancelled countdowns is kept between launches (item 169's codex-1): its record and its last cancel.
    nonisolated static let cancelRunKey = "com.malinois.arming.cancelRun"

    /// The longest quiet between two cancels of one run (item 169's codex-1).
    nonisolated static let cancelRunGap: TimeInterval = 600

    /// How long a cancel that counts on its run's record waits for the log's queued write (item 171): a clip being
    /// stored ahead of it can hold the queue for seconds, and the owner's cancel must not wait that out.
    nonisolated static let cancelWriteWait: TimeInterval = 2

}

// MARK: - Disarm-entry host (1.3 step 7)

extension MonitoringEngine: DisarmEntryHost {
    var isSessionActive: Bool { state.isActive }
    func pauseProximityForEntry() { monitors[.proximity]?.stop() }
    func resumeProximityAfterEntry() {
        // The Pro-aware set, not the raw setting: proximity is free today so these agree, but
        // restarting a monitor the engine considers disabled would be a fail-open if any future
        // gate ever touched it.
        if sensorEnabled(.proximity) { monitors[.proximity]?.start() }
    }
    func disarmPresentationChanged() {
        refreshBrightness()
        presentOwedAlertIfDue()
    }

    /// Shows the warning the PIN pad's quiet window held back (item 167's A1), once that window has ended or the pad has
    /// closed without a correct PIN, and not while the owner may still be typing, whatever repaints the screen; one
    /// already up is kept alive instead. A disarm clears what is owed.
    private func presentOwedAlertIfDue() {
        guard alertOwedAfterEntry, !disarmEntry.presentationSuppressed else { return }
        alertOwedAfterEntry = false
        switch Self.alertAction(showsMessage: settings.responseMode.showsMessage, alertActive: alertActive,
                                activeEntry: false) {
        case .present: presentAlert()
        case .extend: extendAlertWindow()
        case .none, .deferred: break
        }
    }
}

// MARK: - Capture pipeline host (1.3 step 5)

extension MonitoringEngine: CapturePipelineHost {
    /// Return the camera to cold standby only when no newer response owns it. A cadence
    /// capture may finish storage after a trigger starts in the same watch; the trigger's
    /// completion handles standby instead. Callers also reject replaced watch sessions.
    func standDownCameraIfNeeded() {
        guard !cameraShouldBeWarm, !capturePipeline.isBusy,
              !isHandlingTrigger, !isCapturingUntilClear else { return }
        cameraStandbyTimer?.invalidate(); cameraStandbyTimer = nil
        camera.shutDown()
    }

    var captureSessionIsOver: Bool { state == .disarmed }
    /// The armed screen draws a lit clip's white screen over the warning: when a warning starts during such a clip, the
    /// light ends, or nobody would see it (codex-1 on 1.8.2's step 10). The clip goes on recording, unlit from here, and
    /// a later capture is not lit while the warning is up (`mayFlashScreen`).
    func endCaptureLightForTheWarning() {
        if captureFlash { setCaptureFlash(false) }
    }
    /// Alert mode's first warning during a long Until clear clip (item 152's hardening (c)): shown once the clip has
    /// recorded as long as the default 3-second clip, not when it ends, up to two minutes later while the tampering
    /// itself keeps it recording. The clip goes on; the response's own decision after the capture extends the warning.
    /// The usual rule decides it (held back while the owner types their PIN, and shown after: item 167's A1); Stealth
    /// shows none, and Siren mode records no clip (F4).
    func untilClearClipReachedWarningTime() {
        guard state != .disarmed, settings.responseMode != .siren else { return }
        switch Self.alertAction(showsMessage: settings.responseMode.showsMessage, alertActive: alertActive,
                                activeEntry: disarmEntry.presentationSuppressed) {
        case .present: presentAlert()
        case .deferred: alertOwedAfterEntry = true   // shown once the typing stops or the pad closes (item 167's A1)
        case .extend, .none: break
        }
    }
    /// Skipped while the disarm PIN pad is up (presentation suppressed) and while the tamper
    /// alert is already on screen — the first (pre-alert) capture got the lit shot, and a
    /// re-flash would tell the thief a photo is being taken right now.
    var mayFlashScreen: Bool { !disarmEntry.presentationSuppressed && !alertActive }
    func setCaptureFlash(_ on: Bool) {
        captureFlash = on
        refreshBrightness()
    }
    func rearmTripwiresDuringCapture() {
        for (_, m) in monitors where m.isEnabled { m.rearm() }
    }
    func suppressVision(for seconds: TimeInterval) { visionMonitor?.suppress(for: seconds) }
    func captureCameraBecameAvailable() { scheduleInterruptedCaptureRetry() }

    func clearCaptureNotice(matching notice: String) {
        if cameraNotice == notice { cameraNotice = nil }
    }
    func report(cameraNotice notice: String?) {
        // A capture that finishes after the disarm must not leave a warning on the disarmed
        // Home (item 63 leg 6): only the next arm would have cleared it. Clearing (nil) always
        // passes; a new notice needs a live session, like the trip responder's session-event handlers.
        guard notice == nil || state.isActive else { return }
        cameraNotice = notice
        // A capture-failure notice replaces the interruption text and must outlive the
        // interruption's end (item 65, finding 4; ADR 0008 §4).
        tripResponder.noteCaptureNoticeReplacedInterruption()
    }
}

#if DEBUG
extension MonitoringEngine {
    /// Drives one real upload completion without cloud networking or sweep scheduling delays.
    func uploadSnapshotForTesting(_ event: Event, throughSweep: Bool) async {
        if throughSweep { _ = await sweepUpload(event, disarmSignal: false) } else { await exfiltrate(event, cloudAllowedOverride: true) }
    }

    /// Test-only (item 65, finding 1): swap one tripwire for a fake so a test can watch the
    /// engine start and stop it — the real monitors want hardware the simulator does not have.
    /// Compiled out of Release, so no shipped path can consult it.
    func replaceMonitorForTesting(_ monitor: SensorMonitor) {
        monitors[monitor.type] = monitor
        monitor.onTrip = { [weak self] type in self?.handleTrip(type) }
    }

    /// Test-only (item 144 (g)): the tripwire the engine built, so a test can check how it is wired.
    func monitorForTesting(_ type: SensorType) -> SensorMonitor? { monitors[type] }

    /// Test-only (item 77): drives the connectivity monitor by hand, so a test can take the
    /// engine offline at a chosen moment — the simulator's own path never drops. See
    /// `ConnectivityMonitor.simulateForTesting(online:)`.
    func simulateConnectivityForTesting(online: Bool) {
        connectivity.simulateForTesting(online: online)
    }

    /// Drives the real optional cadence paths without waiting for their long monitoring timers.
    func captureCadenceForTesting(blackout: Bool) async {
        if blackout {
            await captureBlackoutEvidence(for: logBlackoutRecord(), cloudAllowed: cloudAllowed)
        } else {
            await captureFloodEvidence([.motion])
        }
    }

}
#endif

/// Every duration the engine schedules against, in one place (1.3 consolidation, step 3: the
/// timing seam). `.production` is what ships and what the app passes by default; the
/// characterization tests inject a compressed copy so a full arm → trip → capture → disarm
/// cycle runs in well under a second instead of the ~6 s the real calibration and review
/// take. The values are the constants the engine has always used — moved, not changed — and
/// the comments beside their engine or component timing adapters explain why each number
/// is what it is.
struct EngineTiming: Sendable {
    var calibrationDuration: TimeInterval = 3.0
    var correlationWindow: TimeInterval = 2.0
    var refractorySweepInterval: TimeInterval = 0.5
    var autoExposureSettle: TimeInterval = 0.5
    var blackoutDebounce: TimeInterval = 30
    var stationaryWindow: TimeInterval = 10
    var cameraStandbyDelay: TimeInterval = 2
    var floodWindow: TimeInterval = 60
    var sustainedIdleClear: TimeInterval = 30
    var floodCaptureInterval: TimeInterval = 20
    var disarmEntryTimeout: TimeInterval = 30
    var disarmEntryCeiling: TimeInterval = 120
    var disarmCandidateWindow: TimeInterval = 8
    var disarmActivityGrace: TimeInterval = 20
    var alertDuration: TimeInterval = 8
    /// Item 92: disarmed under Guided Access, how long the screen stays on after Guided Access
    /// starts, a disarm or a cancelled countdown, or the app's return to the screen. Ten minutes
    /// covers setting the phone up and arming; a phone left in Guided Access still sleeps.
    var guidedAccessScreenHold: TimeInterval = 600
    /// Item 152's hardening note (b), ADR 0050's decision 8: how long "Before you arm" waits without a touch before
    /// the arm is cancelled back to Home. A minute: enough to read it, and scrolling counts as a touch.
    var firstArmBriefingTimeout: TimeInterval = 60
    /// Item 152's lead 6: how long the siren waits for the camera to release the microphone before sounding anyway
    /// (MonitoringEngine+SirenMicRelease.swift). The release is queued work that may never run (ADR 0038).
    var sirenMicReleaseWait: TimeInterval = 1.5
    /// The "calibration complete" card's dwell before the screen goes covert.
    /// The "Calibrated" card: 6 s (owner, 2026-09-05; 2 s before). The sensors are live for the
    /// whole review and a trip goes covert at once, so the only cost is a lit screen a few
    /// seconds longer after the countdown.
    var calibrationReview: TimeInterval = 6.0
    /// Exposure settle after a camera reconfigure (a lens change or a cold start).
    var reconfigureSettle: TimeInterval = 0.8
    /// Screen-flash settle before a front still.
    var flashSettle: TimeInterval = 0.35
    /// Until-clear: the quiet period that ends the clip, its ceiling, and its poll cadence.
    var untilClearIdle: TimeInterval = 5
    var untilClearMax: TimeInterval = 120
    var untilClearPoll: TimeInterval = 0.4
    /// How long an Until clear clip records before Alert mode's first warning: as long as the default 3-second clip
    /// (item 152's hardening (c)), instead of the whole clip, up to `untilClearMax`.
    var untilClearWarningAfter: TimeInterval = 3
    /// How long a camera warm-up may take before the caller stops waiting. Generous — a cold
    /// start takes ~0.5–2 s — because a false timeout costs one capture, while no bound at
    /// all is the H10 wedge shape: `AVCaptureSession.startRunning()` can block indefinitely,
    /// and an awaited warm-up hanging on the trigger path left the engine's trigger-handling
    /// flag stuck — detection dead until disarm, with nothing logged.
    var warmUpDeadline: TimeInterval = 8
    /// Whole-attempt allowance after setup/recording for light queries, capture, finalization and inspection.
    var captureFinalizationDeadline: TimeInterval = 12
    /// Item 54: how long after an interruption-class capture failure its one retry may still
    /// run once the interruption ends.
    var captureRetryWindow: TimeInterval = 120
    /// Item 54: repeats of a camera runtime error inside this window are the same storm.
    var cameraErrorDebounce: TimeInterval = 60
    /// Item 65, finding 10: how long a push that cold-launches the app waits for the
    /// entitlement check before deciding whether there is a cloud to pull from.
    var pushResolveWait: TimeInterval = 5
    /// Item 79: the pending sweep's wait between passes after a throttle or an outage — never
    /// shorter than the floor, never longer than the ceiling, whatever the server suggested.
    var sweepWaitFloor: TimeInterval = 2
    var sweepWaitCeiling: TimeInterval = 120
    /// Item 52: the heartbeat's interval while a watch is live (the owner's choice 1a, five
    /// minutes: a longer silence shows, and twelve small records an hour cost little).
    var heartbeatInterval: TimeInterval = 300

    static let production = EngineTiming()
}

// MARK: - Current watch facts and actions for cloud coordination

/// Narrow weak-host boundary. Same-file conformance can update private-set UI properties directly.
extension MonitoringEngine: MonitoringCloudHost {
    var cloudHostState: MonitoringState { state }
    var cloudHostAllowsUpload: Bool { cloudAllowed }
    var cloudHostArmedPro: Bool { armedPro }
    var cloudHostArmedSince: Date? { armedSince }
    var cloudHostHadConnectivityAtArm: Bool { hadConnectivityAtArm }
    var cloudHostIsCharging: Bool { isCharging }
    var cloudHostLiveFloodAnchorID: UUID? { liveFloodAnchorID }
    func cloudEventCountDidChange(to count: Int) { eventCount = count }
    func cloudUploadInterferenceDetected() { escalate(.blackout) }
    func cloudRefreshNotificationHealth() async { await refreshNotificationHealth() }
    func cloudRecordBackupChange(_ kind: String) { _ = logStateChange(kind) }
    func cloudWriteOwedReinstallRecord() { writeOwedReinstallRecord() }
}

// MARK: - Current watch facts and physical actions for trip coordination

extension MonitoringEngine: MonitoringTripHost {
    var tripState: MonitoringState { state }
    var tripSession: Int { armSession }
    var tripCalibrationReview: Bool { showingCalibrationReview }
    var tripDryRunActive: Bool { dryRunActive }
    var tripCaptureModeNow: CaptureMode { captureModeNow }
    var tripCameraPosition: CameraChoice { effectiveCameraPosition }
    var tripCameraShouldBeWarm: Bool { cameraShouldBeWarm }
    var tripCloudAllowed: Bool { cloudAllowed }

    /// The original dry-run path consumes a trip before motion bookkeeping or any armed-state guard.
    func tripConsumeDryRun(_ sensor: SensorType) -> Bool {
        if dryRunActive {
            dryRunTrips[sensor] = Date()
            dryRunCounts[sensor, default: 0] += 1
            monitors[sensor]?.rearm()
            return true
        }
        return false
    }
    func tripNoteMotion(at date: Date) { lastMotionTrip = date }
    func tripRecentTrace(for sensor: SensorType) -> [Double]? { monitors[sensor]?.recentTrace() }
    func tripRearmSensor(_ sensor: SensorType) { monitors[sensor]?.rearm() }
    func tripRebaselineEnabledSensors() {
        for (_, m) in monitors where m.isEnabled { m.rearmAndRebaseline() }
    }
    func tripGoCovert() { goCovert() }
    func tripEnterTriggeredState() { state = .triggered }
    func tripStampTrigger(at date: Date) { lastTriggerDate = date }
    func tripPublishEventCount(_ count: Int) { eventCount = count }
    func tripNoteCandidateEvent(_ id: UUID) { disarmEntry.noteCandidateEvent(id) }
    func tripReturnToArmedAndRecheckBlackout() {
        state = .armed
        recheckBlackoutOnReturnToArmed()
    }
    func tripExtendAlertWindow() { extendAlertWindow() }
    /// Keeps the existing flood's running warning alive without starting a new one over entry.
    func tripExtendConfiguredFloodAlert() {
        if Self.alertAction(showsMessage: settings.responseMode.showsMessage, alertActive: alertActive,
                            activeEntry: disarmEntry.presentationSuppressed) == .extend { extendAlertWindow() }
    }
    func tripEscalateFlood() { escalate(.flood) }
    /// The unchanged final response policy, after the responder has checked its session and re-armed.
    func tripFinishCapturedResponse() {
        // 6. Fire the response. If a real tamper can't be exfiltrated because a path we
        //    HAD at arm has since dropped, go loud — that's suspected jamming, and
        //    covertness is moot once the evidence can't escape. But a device armed offline
        //    to begin with (a basement/cabin dead zone) is benign, not jammed — its
        //    evidence is simply stored locally and uploads on return — so it must NOT
        //    force-siren, which would break Stealth's promise. This mirrors the canary
        //    path's `hadConnectivityAtArm` gate (V-03). Otherwise show the configured alert
        //    (unless the owner's entering the PIN).
        if Self.shouldGoLoudOnFailedExfil(jammingResponse: settings.jammingResponse,
                                          online: connectivity.isOnline,
                                          hadConnectivityAtArm: hadConnectivityAtArm,
                                          offlineFor: offlineSince.map { Date().timeIntervalSince($0) } ?? 0) {
            escalate(.blackout)
        } else {
            switch Self.alertAction(showsMessage: settings.responseMode.showsMessage,
                                    alertActive: alertActive, activeEntry: disarmEntry.presentationSuppressed) {
            case .present:  presentAlert()          // start fresh (not over the owner's typing)
            case .extend:   extendAlertWindow()     // keep a running alarm alive despite a screen touch
            case .deferred: alertOwedAfterEntry = true   // shown once the typing stops or the pad closes (item 167's A1)
            case .none:     break
            }
        }
    }
    func tripStandDownCameraIfNeeded() { standDownCameraIfNeeded() }
    func tripWarmActiveCamera() { warmActiveCamera() }
    func tripResolveAutoCamera() -> CameraChoice { resolveAutoCamera() }
    func tripSetCameraNotice(_ notice: String?) { cameraNotice = notice }
    func tripReportCaptureNotice(_ notice: String?) { report(cameraNotice: notice) }
    func tripLogCameraError() { _ = logStateChange("cameraError") }
}

// MARK: - Current watch facts and physical actions for arming

extension MonitoringEngine: MonitoringArmingHost {
    var armingState: MonitoringState { state }
    var armingEntitlementResolved: Bool { entitlements.hasResolved }
    var armingGuidedAccessEnabled: Bool { guidedAccessEnabled }
    var armingWasAutoRecovered: Bool { armWasAutoRecovered }
    var armingDryRunActive: Bool { dryRunActive }
    func armingStopDryRun() { stopDryRun() }
    func armingRefreshGuidedAccess() { refreshGuidedAccess() }
    func armingRefreshSirenVolumeWarning() { refreshSirenVolumeWarning() }
    func armingRefreshIdleTimer() { refreshIdleTimer() }
    func armingSetDevicePasscodeMissing(_ missing: Bool) { devicePasscodeMissing = missing }
    /// The original physical preparation, before the flow evaluates the first-arm lift.
    func armingPrepareWatch() {
        ratingRequestPending = false   // a rating request still waiting was for the calm watch before (codex-16)
        recordProtectionChanges()             // item 91: a change is on the record before the session starts
        armedPro = entitlements.proActive     // snapshot Pro for the whole session (trial began at launch)
        // The clip-audio decision must reach the camera on EVERY arm, not only when the
        // readiness policy pre-warms it: on battery with Auto readiness the camera cold-starts
        // at the trigger, and 1.3 (40) left the mic off there (item 69, leg 8 on 40).
        camera.clipAudio = Self.clipAudioAllowed(setting: settings.clipAudio,
                                                 micGranted: AVAudioApplication.shared.recordPermission == .granted)
        recoveredInterruptedSession = false   // dismiss the recovery note once re-arming
        reArmSkipped = false                  // and the skipped re-arm's (fable-3)
        visionTapUnavailable = false          // last session's verdict on the tap is not this session's (item 65, finding 15)
        cloudCoordinator.resetWatchNotices()   // a new watch gets fresh cloud notices, in the same order
        armWasAutoRecovered = false           // a manual arm is user-initiated (cancellable)
        refreshSirenVolumeWarning()
        refreshDeviceName()
        refreshGuidedAccess()
        cameraAskBlockedByGuidedAccess = Self.cameraAskBlocked(
            guidedAccessOn: guidedAccessEnabled,
            cameraNeeded: settings.isEnabled(.camera) || settings.isEnabled(.vision),
            undetermined: camera.videoPermission == .notDetermined)
    }
    /// The original physical setup after the lift choice, including root-owned finite cloud/health work.
    func armingPresentGuidedAccessCheck() {
        // Know the charging state so the camera-readiness policy is correct from the
        // very first pre-warm decision (and stays live via the battery observer).
        UIDevice.current.isBatteryMonitoringEnabled = true
        isCharging = Self.isChargingState(UIDevice.current.batteryState)
        state = .guidedAccessCheck
        // Remember the display brightness NOW, while the owner is holding the phone and
        // looking at it — this is the level they actually chose.
        //
        // It used to be sampled at go-live instead, by which time the phone has been lying
        // face down through the countdown and calibration. Face down covers the ambient light
        // sensor, so iOS auto-brightness has already driven the display to near-minimum, and
        // that minimum got recorded as "the user's level" and faithfully restored on disarm —
        // a phone that came back from a watch with the screen almost black.
        previousBrightness = UIScreen.main.brightness
        // Hold the device awake for the WHOLE arming flow, not just once armed.
        //
        // The owner is told to set the phone down and leave it — that is what the grace
        // countdown exists for, and face down on a desk is the ordinary gesture. There are no
        // touches then, so iOS auto-lock ran out, the device locked, the app suspended, and
        // calibration stopped partway through. Picking the phone up resumed it mid-stride.
        // The countdown itself is wall-clock driven and self-corrects, but calibration is
        // sampled continuously and cannot be: it needs the process alive.
        //
        // The failure mode is the one this app exists to avoid — the owner walks away
        // believing the watch started, and it did not. Guided Access does not prevent it: it
        // locks the app to the foreground, not the display on. (Reported on device 2026-08-26.)
        refreshIdleTimer()
        // Warm CloudKit while the user reads; sets up the cross-device push subscriptions while the
        // owner's choice, asked again after each wait, wants them (codex-21), and never removes them.
        // Cloud is a Pro feature — the free tier keeps evidence on-device, so skip it entirely.
        if armedPro {
            Task { await cloud.warmUp(alertsWanted: { [weak self] in self?.alertSubscriptionWanted ?? false }) }
        }
        // Note up front if "Both" can't use multi-cam on this device.
        cameraNotice = (effectiveCameraPosition == .both && !camera.supportsMultiCam)
            ? "This device doesn't support multi-cam - “Both” captures the front camera only."
            : nil
        audioNotice = nil
        sirenNotice = nil
        refreshPermissionNotices()
        Task { await refreshNotificationHealth() }   // 34.H7 — before the owner walks away
        guard settings.isEnabled(.camera) else { return }
        // Battery saver — and Auto while on battery — skip the pre-warm and instead
        // cold-start the camera on a trigger (see EvidenceCapturePipeline.capture). Everything else keeps
        // the session warm so the first capture is instant.
        guard cameraShouldBeWarm else { return }
        warmActiveCamera()
    }
    func armingEnterGrace() {
        state = .arming
        UserDefaults.standard.set(true, forKey: Self.armingInProgressKey)   // a kill from here to go-live leaves this behind (review 3, R3.2)
    }
    func armingEnterCalibration() { state = .calibrating }
    func armingBeginMonitorCalibration() {
        applyEnabledAndSensitivity()

        // Begin calibration on monitors that need it.
        for (_, m) in monitors where m.isEnabled && m.requiresCalibration {
            m.beginCalibration()
        }

    }
    func armingFinishMonitorCalibration() {
        for (_, m) in monitors where m.isEnabled && m.requiresCalibration {
            m.endCalibration()
        }
        lastCalibration = makeCalibrationSummary()
    }
    func armingStartWatching() { startWatching() }
    /// Runs after the flow synchronously publishes review=false, as in the original goCovert.
    func armingEnterCovertWatch() {
        state = .armed
        engageCovertScreen()
        recheckBlackoutOnReturnToArmed()   // a path lost during the review (item 65, finding 8)
    }
    func armingDisarm() { disarm() }
    @discardableResult func armingLogStateChange(_ kind: String) -> Event { logStateChange(kind) }
}
