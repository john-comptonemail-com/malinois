//
//  MonitoringEngine.swift
//  Malinois
//
//  The coordinator / primary view-model. Drives the state machine, owns the
//  sensor monitors, the camera, the cloud exfiltrator and the event store, and
//  turns individual sensor trips into captured-and-exfiltrated tamper events.
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
    case none      // nothing (no message mode, or the owner's own disarm — stay quiet)
    case present   // start a fresh alert/siren
    case extend    // an alert/siren is already up — keep it alive (re-extend its window)
}

@MainActor
final class MonitoringEngine: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: MonitoringState = .disarmed {
        didSet {
            // The app-switcher cover shows the emblem when there is something to hide, and
            // plain black while a watch is live — where a logo would advertise the app that
            // covert mode exists to conceal.
            PrivacyCover.shared.isCovert = state.isActive
        }
    }
    @Published private(set) var guidedAccessEnabled: Bool = UIAccessibility.isGuidedAccessEnabled

    /// Guided Access was on when you last disarmed and is off now. Surfaced on the arming
    /// screen, which already warns that GA is off — this adds the part that carries meaning,
    /// that it was on when you walked away.
    @Published private(set) var guidedAccessOffSinceDisarm = false
    @Published private(set) var graceRemaining: Int = 0
    @Published private(set) var calibrationProgress: Double = 0   // 0…1
    @Published private(set) var lastTriggerDate: Date?
    @Published private(set) var eventCount: Int = 0

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
        sirenNotice = "The siren couldn't sound during the last alert — the audio output was held (a call or another app). The alert and evidence capture ran normally."
    }

    /// Cross-device alerts can be silently impossible on THIS device — Notifications denied
    /// for the app, or APNs registration failed — while Home still says "iCloud ready"
    /// (34.H7). Surfaced beside the camera/mic notices; nil when healthy or when the
    /// feature isn't in play.
    @Published private(set) var notificationNotice: String?

    /// iCloud's encrypted data was reset (34.H13): Apple purged the cloud copies, and this
    /// device is re-uploading what it still holds. Surfaced until the next arm.
    @Published private(set) var cloudResetNotice: String?
    private var encryptedResetHandled = false

    /// iCloud REFUSED an evidence upload (quota, auth, schema, key reset) — the server
    /// answered, so it is not interference and must not siren (32.R1); it IS an owner
    /// problem, so Home says so. Cleared when a push succeeds or on the next arm.
    @Published private(set) var cloudPushRefused = false

    /// Set at launch when a prior armed session didn't end cleanly (force-quit /
    /// crash): we recovered the screen brightness and kicked off a re-sync. Shown
    /// on Home; cleared on the next arm.
    @Published private(set) var recoveredInterruptedSession = false
    /// True while the CURRENT arming flow was started automatically after a crash/force-
    /// quit recovery (not by the owner). Cancelling it requires the PIN (R-04).
    @Published private(set) var armWasAutoRecovered = false
    /// Set at arm when Siren response is selected but the device's media volume is low —
    /// the siren plays at system volume and can't override the hardware buttons, so warn
    /// the owner while they can still turn it up (F-13). Surfaced on the arming screen.
    @Published private(set) var sirenVolumeLow = false

    /// True while the on-screen tamper warning is showing (alert / siren modes).
    /// ArmedView renders the warning message when this is set.
    @Published private(set) var alertActive = false

    /// Active "go loud" escalation (jamming blackout or a tamper flood), or nil.
    /// ArmedView shows the reason's warning; the siren behaviour depends on it.
    @Published private(set) var escalation: Escalation?
    /// Live network reachability (mirrors the connectivity monitor) — surfaced on
    /// Home as a "you're offline, evidence can't upload" warning.
    @Published private(set) var isOnline = true

    /// Result of the most recent calibration — shown as a brief "calibration
    /// complete" review before going covert, and in the Test Sensors view.
    @Published private(set) var lastCalibration: CalibrationSummary?
    /// True during the brief post-calibration review on the arming screen.
    @Published private(set) var showingCalibrationReview = false

    /// Live "Test Sensors" (dry-run) state — sensors run and report readings, but
    /// nothing is recorded and the screen never goes covert.
    @Published private(set) var dryRunActive = false
    @Published private(set) var dryRunReadings: [SensorType: SensorReading] = [:]
    /// Last "would-trip" time per sensor, so the test view can flash it.
    @Published private(set) var dryRunTrips: [SensorType: Date] = [:]
    /// Cumulative would-trip count per sensor — a persistent tally that survives
    /// proximity blanking the screen, so the user can confirm it fired even though
    /// the display was off while covered.
    @Published private(set) var dryRunCounts: [SensorType: Int] = [:]
    /// Seconds until dry-run calibration begins — a visible "set the phone down" settle window,
    /// so the motion noise floor isn't learned from the hand that just tapped "Test sensors".
    /// The arming flow gets this for free from its grace period; the dry run used to skip
    /// straight to calibrating and learn garbage (BACKLOG 12). Nil once calibrating/running.
    @Published private(set) var dryRunCountdown: Int?
    nonisolated static let dryRunSettleSeconds = 3
    private var dryRunSettleTimer: Timer?

    // MARK: - Collaborators

    let settings: AppSettings
    let eventStore: EventStore
    let cloud: CloudExfiltrator
    let camera: CameraController
    let entitlements: ProEntitlements

    private var monitors: [SensorType: SensorMonitor] = [:]

    // MARK: - Internal timing

    private let calibrationDuration: TimeInterval = 3.0
    private let correlationWindow: TimeInterval = 2.0
    /// How often, while armed, to free latched-but-uncorroborated sensors.
    private let refractorySweepInterval: TimeInterval = 0.5
    /// Before the Auto illumination check, give the camera this long to re-meter
    /// the scene the device is *now* in — a resting phone often faces a dark
    /// surface, which would otherwise flash a shot that's actually in a lit room.
    private let autoExposureSettle: TimeInterval = 0.5
    /// How long a total connectivity loss must persist before it's treated as
    /// suspected jamming (rides out brief registration flaps / fades).
    private let blackoutDebounce: TimeInterval = 30
    /// A motion trip within this window means the device isn't stationary — the
    /// blackout is then the "tamper carried away" case, not pre-emptive jamming.
    private let stationaryWindow: TimeInterval = 10

    private var graceTimer: Timer?
    private var graceEndsAt: Date?
    private var calibrationTimer: Timer?
    private var refractoryTimer: Timer?
    private var dryRunTimer: Timer?
    private var blackoutTimer: Timer?
    private var guidedAccessObserver: NSObjectProtocol?

    // MARK: - Camera battery-readiness
    /// Whether the device is on external power. Drives the Auto readiness policy
    /// (warm while charging, cold-start on battery). Assume true until measured.
    private var isCharging = true
    private var batteryStateObserver: NSObjectProtocol?
    /// Deferred camera teardown when Auto flips to battery, so an unplug that also
    /// fires a trigger still captures from the warm session before it stands down.
    private var cameraStandbyTimer: Timer?
    private let cameraStandbyDelay: TimeInterval = 2

    // MARK: - Jamming / connectivity
    private let connectivity = ConnectivityMonitor()
    /// Whether a usable network path existed at arm — the canary baseline. Only a
    /// *loss* of a path we demonstrably had is treated as suspicious.
    private var hadConnectivityAtArm = false
    private var blackoutEscalated = false
    /// Last time the motion sensor tripped, for the stationary check.
    private var lastMotionTrip: Date?
    /// When the current total connectivity loss began (nil while online). Feeds the
    /// trigger-time go-loud's blip filter: a WiFi↔cellular handoff can read as a sub-second
    /// unsatisfied path, and a trigger landing inside that instant must not sound the
    /// blackout siren on a coincidence (39.R2.2).
    private var offlineSince: Date?

    // MARK: - Flood coalescing
    /// More than this many trips from one sensor within the window is a "flood"
    /// (someone attacking the sensor to overflow the log), not a real tamper. Set well
    /// above a plausible human tamper rate (~6/min) so ordinary sustained handling — an
    /// actual burglary — isn't misclassified as a synthetic attack.
    nonisolated static let floodTripThreshold = 10
    /// Pure (unit-tested): is a per-sensor recent trip count high enough to be a flood?
    nonisolated static func isFloodCount(_ count: Int) -> Bool { count > floodTripThreshold }
    private let floodWindow: TimeInterval = 60
    /// A flood is considered over once its sensor is quiet this long.
    private let sustainedIdleClear: TimeInterval = 30
    /// Even during a flood, keep capturing on this cadence (photo-only) so a real tamper
    /// that merely looks like a flood is never left un-photographed. Coalescing then
    /// suppresses log spam and upload volume, not the evidence itself.
    private let floodCaptureInterval: TimeInterval = 20
    private var lastFloodCapture: Date?
    /// Last time the coalesced counter was flushed to disk (F2) — the write, not the count,
    /// is throttled; in-memory stays current and the clear timer flushes the final value.
    private var lastFloodPersist: Date?
    private var sensorTripTimes: [SensorType: [Date]] = [:]
    /// The current coalesced "sustained activity" event, while flooding.
    private var sustainedEvent: Event?
    private var sustainedClearTimer: Timer?

    /// Recent trips awaiting the combination check: sensor → timestamp.
    private var recentTrips: [SensorType: Date] = [:]
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
    private var latchedSensors: Set<SensorType> = []
    private var isHandlingTrigger = false
    /// Trips that arrived while a capture was already running (`.triggered`, photo or fixed
    /// clip). Folded into the in-flight event when its capture finishes (34-review M1): a
    /// grab-then-unplug whose cable pull landed inside the ~1–5 s capture window used to be
    /// recorded as "Device motion" only — the second step's trip was dropped with no record
    /// anywhere. Until-clear clips were the only mode that handled the window.
    private var tripsDuringCapture: Set<SensorType> = []

    /// True while the disarm PIN pad is open. Suppresses only the *presentation* — the
    /// capture flash and the alert overlay, so they don't fight the raised PIN-pad
    /// brightness — while detection and capture keep running underneath (see handleTrip).
    /// Published so the PIN pad follows it and the inactivity timeout can dismiss it.
    @Published private(set) var disarmEntryActive = false
    private var disarmEntryTimer: Timer?
    /// Inactivity window: return to covert after this long with no keypress, so the
    /// raised brightness / presentation-suppression can't be held open indefinitely.
    /// Reset on each digit (see noteDisarmActivity), bounded by disarmEntryCeiling.
    private let disarmEntryTimeout: TimeInterval = 30
    private let disarmEntryCeiling: TimeInterval = 120
    private var disarmEntryStartedAt: Date?
    /// Events captured while the pad was open. If a correct PIN then lands they were the
    /// owner's own handling → marked owner-attributed; otherwise they stand as evidence.
    private var disarmEntryEventIDs: Set<UUID> = []
    /// When the owner's disarm HOLD began (press-down), before the pad opens 5 s later.
    /// The attribution window opens here, not at `beginDisarmEntry` — otherwise the very
    /// touch that starts a legitimate disarm is logged as an un-attributed tamper and
    /// pushed to the owner's other devices (R-02).
    private var disarmCandidateSince: Date?
    private let disarmCandidateWindow: TimeInterval = 8
    private var isDisarmCandidateActive: Bool {
        disarmCandidateSince.map { Date().timeIntervalSince($0) < disarmCandidateWindow } ?? false
    }
    /// Whether owner-disarm handling *might* be in progress — the pad is open, or a hold
    /// that might open it just began. Used ONLY to mark captured events as owner-attribution
    /// candidates (R-02).
    ///
    /// Deliberately NOT used to decide whether an alert may start, NOR whether the capture
    /// flash may fire. `noteDisarmCandidate()` runs on any touch-down, so gating presentation
    /// on this let a mere *touch* — the defining act of a snoop — hold the response off for
    /// the whole 8 s window, and longer by re-touching. Attribution and suppression are
    /// separate concerns (F1, A-02).
    private var inDisarmFlow: Bool { disarmEntryActive || isDisarmCandidateActive }

    /// Last keypress on the open disarm pad — the evidence that someone is *actually entering
    /// a PIN*, rather than merely holding the pad open. See `presentationSuppressed`.
    private var lastDisarmKeypress: Date?
    /// How long after a keypress the owner is still considered mid-entry. Long enough to read
    /// a dim screen and find the next digit; far short of the pad's 30–150 s open window.
    private let disarmActivityGrace: TimeInterval = 20

    /// Whether the owner appears to be *actively* entering their PIN right now.
    private var disarmEntryInProgress: Bool {
        disarmEntryActive && Self.entryIsActive(lastKeypress: lastDisarmKeypress, now: Date(),
                                                grace: disarmActivityGrace)
    }

    /// Pure (unit-tested). Opening the pad is not the same as using it: the pad stays up for
    /// 30 s of inactivity (up to a 120 s ceiling), so gating on mere openness handed anyone
    /// willing to do the 5-second hold 30–150 s of guaranteed silence, renewable indefinitely
    /// by re-holding. Requiring a *recent keypress* keeps F1's actual purpose — don't fight the
    /// owner while they're typing — while an idle open pad alerts normally (A-02).
    nonisolated static func entryIsActive(lastKeypress: Date?, now: Date,
                                          grace: TimeInterval) -> Bool {
        guard let lastKeypress else { return false }
        return now.timeIntervalSince(lastKeypress) < grace
    }

    /// Whether a *fresh* alert must stay quiet, and whether the capture flash must be held
    /// back. Both fight the raised PIN-pad brightness, and both are owner-facing annoyances
    /// only while the owner is genuinely mid-entry — so both use the same narrow condition.
    ///
    /// H1: the flash used to gate on `inDisarmFlow`, so a snoop could tap once and then move
    /// the device within the 8 s candidate window to get an unlit (often useless) front-camera
    /// shot in a dim room. A bare touch raises no brightness, so there was never a conflict to
    /// avoid there.
    private var presentationSuppressed: Bool { disarmEntryInProgress }

    /// True while an "until clear" clip is recording; sensor trips refresh
    /// `lastCaptureActivity` (which decides when to stop) instead of firing a new
    /// event.
    private var isCapturingUntilClear = false
    private var lastCaptureActivity: Date?

    /// Tamper-alert display (alert / siren response modes).
    private let siren = SirenPlayer()
    private var alertDismissTimer: Timer?
    private let alertDuration: TimeInterval = 8      // extends on each new trigger
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
    private var armSession = 0

    private var previousBrightness: CGFloat = UIScreen.main.brightness

    /// Persisted while armed (value = the pre-arm brightness) and cleared on a clean
    /// disarm. If it's still present at launch, the last armed session ended
    /// abnormally — see `recoverInterruptedSessionIfNeeded`.
    private static let armedMarkerKey = "com.malinois.armedSession.brightness"
    /// Timestamp of the last interrupted-session re-arm *attempt*, to detect a crash loop
    /// and avoid auto-re-arming straight back into it.
    private static let recoveryTimeKey = "com.malinois.recovery.lastAt"
    /// Persisted "a crash-recovery re-arm is owed." Set when an interruption is detected and
    /// cleared only when the re-arm actually runs. Persisting it (rather than only an
    /// in-memory flag) is what lets a re-arm deferred on a background launch survive iOS
    /// terminating that launch before the owner foregrounds it — otherwise the marker was
    /// consumed and the re-arm silently lost (M4).
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    /// Set while a recovery re-arm's countdown is running (F1): the window between
    /// consuming the owed flag and re-engaging covert used to hold NO persistent marker, so
    /// a second kill during grace/calibration left the next launch blind — no log entry, no
    /// re-arm. Cleared when covert engages (armedMarker takes over) or on a clean disarm.
    private static let recoveryInProgressKey = "com.malinois.recovery.inProgress"

    /// Guided Access state as of the last disarm, so the next arm can say whether it changed
    /// while nobody was watching (BACKLOG 24b). Deliberately narrow: the app cannot observe
    /// GA changes while suspended at all — the notification only reaches a running process,
    /// and GA locks the device to a *single* app, so while Malinois is backgrounded any GA
    /// session belongs to something else. Comparing across a disarm is the one question the
    /// code can actually answer, and it is the one that means something: it only fires when
    /// the current state contradicts the owner's own last configuration.
    private static let guidedAccessAtDisarmKey = "com.malinois.guidedAccess.atLastDisarm"

    // MARK: - Init

    init(settings: AppSettings,
         eventStore: EventStore,
         cloud: CloudExfiltrator,
         camera: CameraController,
         entitlements: ProEntitlements) {
        self.settings = settings
        self.eventStore = eventStore
        self.cloud = cloud
        self.camera = camera
        self.entitlements = entitlements
        self.eventCount = eventStore.events.count

        refreshDeviceName()
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
        recordingIndicatorSub = camera.$isRecordingActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBrightness() }
        recoverInterruptedSessionIfNeeded()
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
    private func recoverInterruptedSessionIfNeeded() {
        let defaults = UserDefaults.standard
        let markerPresent = defaults.object(forKey: Self.armedMarkerKey) != nil
        // A re-arm can be owed even with the marker gone: a prior launch detected the
        // interruption (consuming the marker), deferred the re-arm because it came up in the
        // background, then got terminated before foreground. The persisted flag carries that
        // owed re-arm across the cold launch (M4).
        let reArmOwed = defaults.bool(forKey: Self.pendingReArmKey)
        let recoveryInterrupted = defaults.bool(forKey: Self.recoveryInProgressKey)
        guard markerPresent || reArmOwed || recoveryInterrupted else { return }
        if recoveryInterrupted { defaults.removeObject(forKey: Self.recoveryInProgressKey) }

        if markerPresent {
            // Fresh interruption — run the one-time side effects exactly once (guarded by the
            // marker, which we consume now so a later M4 cold-launch recovery doesn't repeat
            // them). Un-strand the display: restore the pre-arm level, never below a floor.
            let savedBrightness = defaults.double(forKey: Self.armedMarkerKey)
            defaults.removeObject(forKey: Self.armedMarkerKey)
            UIScreen.main.brightness = max(CGFloat(savedBrightness), 0.4)
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
            // this launch is the tail of that same interruption rather than a new one. The
            // re-arm below still runs; only the duplicate record is suppressed.
            let alreadyLogged = defaults.bool(forKey: Self.backgroundLapseLoggedKey)
            defaults.removeObject(forKey: Self.backgroundLapseLoggedKey)
            if !alreadyLogged { logInterruptedSession() }
            // A re-arm is now owed; persist it so it survives a background launch that iOS
            // terminates before the owner foregrounds it (M4).
            defaults.set(true, forKey: Self.pendingReArmKey)
        } else if recoveryInterrupted {
            // The recovery countdown ITSELF was killed (F1). Log this interruption too and
            // owe a fresh re-arm; the attempt-timed crash-loop guard still breaks kill loops.
            logInterruptedSession()
            defaults.set(true, forKey: Self.pendingReArmKey)
        }

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
        if state == .disarmed,
           UserDefaults.standard.bool(forKey: Self.pendingReArmKey),
           UIApplication.shared.applicationState != .background {
            performRecoveryReArm()
        }
        Task { await retryPendingSync() }
    }

    /// Executes an owed crash-recovery re-arm, applying the crash-loop guard. Consumes the
    /// owed flag up front — even a declined attempt must not be retried forever — and times
    /// against actual *attempts* (not mere detections), so a re-arm that was only deferred
    /// never counts toward the loop. Called from the foreground: directly on a foreground
    /// launch, from `handleEntitlementResolved` the moment the 31.F2 gate first opens, or
    /// from `handleScenePhase` when a deferred re-arm comes due.
    private func performRecoveryReArm() {
        // Same reasoning as the manual path, with the deferral mechanism that already exists:
        // leave the owed re-arm flagged and let the next foreground pass retry it, rather than
        // re-protecting the device with a session that has lost its Pro tripwires.
        guard !armingBlockedByEntitlementCheck else {
            Log.engine.info("Recovery re-arm deferred until the entitlement check completes")
            return
        }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingReArmKey)
        // Re-protect automatically (F-12), but if two re-arm attempts land within the window
        // the armed state itself is crashing the app — stop, so we don't loop; better to
        // stay put (the interruption was logged) so the owner can intervene.
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: Self.recoveryTimeKey)
        defaults.set(now, forKey: Self.recoveryTimeKey)
        guard !Self.isCrashLoop(lastAttempt: last, now: now) else { return }
        // Cover the countdown window (F1): from here until covert engages there is otherwise
        // no persistent marker, so a kill during grace/calibration would vanish silently.
        defaults.set(true, forKey: Self.recoveryInProgressKey)
        reArmAfterRecovery()
    }

    /// Pure (unit-tested): two re-arm attempts inside the window mean arming is crash-looping.
    nonisolated static func isCrashLoop(lastAttempt: TimeInterval, now: TimeInterval,
                                        window: TimeInterval = 90) -> Bool {
        lastAttempt > 0 && (now - lastAttempt) < window
    }

    /// Records that the armed app was killed without a clean disarm, so the interruption
    /// leaves a log entry and a cross-device alert instead of vanishing silently. Even when
    /// the crash-loop guard then declines to re-arm — e.g. someone repeatedly issuing Voice
    /// Control "Close application" — the owner still learns their device is being closed.
    /// Set when a background lapse has already been logged for the *current* armed session, so
    /// crash recovery doesn't log the same lapse a second time at next launch. Cleared on
    /// returning to the foreground, because a kill after that is a genuinely separate
    /// interruption and does deserve its own record.
    private static let backgroundLapseLoggedKey = "com.malinois.armed.backgroundLapseLogged"

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
        UserDefaults.standard.set(true, forKey: Self.backgroundLapseLoggedKey)
        Log.engine.warning("Armed session sent to the background; monitoring has stopped")
        logInterruptedSession()
    }

    private func logInterruptedSession() {
        let event = Event(startDate: Date(), endDate: Date(),
                          triggeredSensors: [], cloudSyncState: .pending, interrupted: true)
        eventStore.add(event)
        eventCount = eventStore.events.count
        pushFactIfCloud(event)   // cross-device alert (Pro); free tier keeps it in the local log
    }

    /// Logs an explicit "armed" / "disarmed" record so the timeline of when protection was
    /// on or off is auditable — the point being the disarm case: an attacker who knows the
    /// PIN can turn monitoring off, but there's no delete affordance, so the "disarmed" entry
    /// stands as proof of exactly when it happened (rather than the owner having to infer it
    /// from a re-armed session's start time). Kept **local-only**: it is deliberately NOT
    /// exfiltrated (see `exfiltrate`), because the cross-device subscription fires a static
    /// "Tamper detected" alert that would be wrong and noisy for a routine arm/disarm.
    /// Durable cloud logging of state changes (with a correct notification) is a backlog item.
    private func logStateChange(_ kind: String, sessionCloudAllowed: Bool? = nil) {
        // `.pending` rather than `.localOnly`: these now DO leave the device (BACKLOG 8),
        // via the silent `TamperEventState` type. `exfiltrate` resolves the state — and
        // marks it `.localOnly` for a genuinely free user, so the badge stays honest.
        let event = Event(startDate: Date(), endDate: Date(),
                          triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
        eventStore.add(event)
        eventCount = eventStore.events.count
        let record = event
        // Authorization decided NOW, when the record is created — the task runs after the
        // caller returns, and by then the session snapshot may already be cleared (34 review).
        let allowed = sessionCloudAllowed ?? cloudAllowed
        Task { await exfiltrate(record, cloudAllowedOverride: allowed) }
    }

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
        let motion = MotionMonitor()
        // The monitor has already restarted itself; record that the primary tripwire went
        // quiet while armed (BACKLOG 5). Surfacing it in UI is future work.
        motion.onStall = { count in
            Log.engine.warning("Motion stream stalled while watching (#\(count)); restarted")
        }
        let power = PowerMonitor()
        let proximity = ProximityMonitor()
        let audio = AudioMonitor()
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

    /// Handles a subscription push end to end and reports **what actually happened**.
    ///
    /// The AppDelegate used to post a notification and call the completion handler with
    /// `.newData` in the same breath, while the fetch had not started. That reported success for
    /// work that might fail, and — worse — told iOS the background work was finished while it
    /// was still running, so the system was free to suspend the app mid-copy. The push exists
    /// precisely so the evidence reaches a second device; being suspended halfway defeats it.
    func handleRemotePush() async -> UIBackgroundFetchResult {
        let added = await syncFromCloud()
        return Self.pushResult(pro: entitlements.proActive,
                               fetchFailed: cloud.lastFetchFailed, added: added)
    }

    /// Pure (unit-tested). `.failed` is reported only for a query that genuinely failed — a
    /// free-tier device that never pulls, and a pull that found nothing new, are both `.noData`.
    nonisolated static func pushResult(pro: Bool, fetchFailed: Bool, added: Int) -> UIBackgroundFetchResult {
        guard pro else { return .noData }        // the free tier has no cloud to pull from
        if fetchFailed { return .failed }
        return added > 0 ? .newData : .noData
    }

    private func observeGuidedAccess() {
        guidedAccessObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.guidedAccessEnabled = UIAccessibility.isGuidedAccessEnabled
                }
            }
    }

    func refreshGuidedAccess() {
        guidedAccessEnabled = UIAccessibility.isGuidedAccessEnabled
        guidedAccessOffSinceDisarm = Self.guidedAccessWentOffWhileDisarmed(
            atLastDisarm: storedGuidedAccessAtDisarm, now: guidedAccessEnabled)
    }

    /// True when Guided Access was on at the last disarm and is off now — someone, at some
    /// point in between, turned it off. Only that direction is reported: OFF→ON is the owner
    /// setting up protection, and a nil prior state (first run, or a disarm from before this
    /// shipped) is not evidence of anything.
    nonisolated static func guidedAccessWentOffWhileDisarmed(atLastDisarm: Bool?, now: Bool) -> Bool {
        atLastDisarm == true && !now
    }

    /// `nil` when no disarm has been recorded yet — distinct from "was off", which is why
    /// this reads `object(forKey:)` rather than `bool(forKey:)` (the latter turns a missing
    /// key into `false` and would make every first arm look like a change).
    private var storedGuidedAccessAtDisarm: Bool? {
        UserDefaults.standard.object(forKey: Self.guidedAccessAtDisarmKey) as? Bool
    }

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
        cameraStandbyTimer = Timer.scheduledTimer(withTimeInterval: cameraStandbyDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.standByCameraIfIdle() }
        }
    }

    private func standByCameraIfIdle() {
        cameraStandbyTimer = nil
        guard state == .armed, !cameraShouldBeWarm, !isHandlingTrigger, !isCapturingUntilClear else { return }
        camera.shutDown()
    }

    /// Return the camera to cold standby if the readiness policy says it shouldn't be
    /// warm — called right after a capture (the reason the session was up).
    private func standDownCameraIfNeeded() {
        guard !cameraShouldBeWarm else { return }
        cameraStandbyTimer?.invalidate(); cameraStandbyTimer = nil
        camera.shutDown()
    }

    // MARK: - Arming flow

    /// Step 1: user tapped Arm → show the Guided Access coaching screen.
    /// Evidence metadata's device name: the owner's label if set, else the (generic on
    /// modern iOS) system name. Refreshed each arm so a Settings edit takes effect (F-24).
    private func refreshDeviceName() {
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

    // MARK: - Pro gating (snapshot at arm; "store intent, clamp at use")

    /// Pro entitlement captured at arm and held for the whole armed session, so an
    /// entitlement change mid-watch never *downgrades* a live session (paywall spec §5).
    private(set) var armedPro = false
    private var effectiveSensors: Set<SensorType> { settings.effectiveEnabledSensors(pro: armedPro) }
    private func sensorEnabled(_ t: SensorType) -> Bool { effectiveSensors.contains(t) }
    private var effectiveCameraPosition: CameraChoice { settings.effectiveCameraPosition(pro: armedPro) }
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
    private var cloudAllowed: Bool { armedPro || entitlements.proActive }

    private func pushFactIfCloud(_ event: Event) {
        guard cloudAllowed else { return }
        Task {
            await cloud.pushFact(event)   // enqueue awaits the chained work, so this returns post-attempt
            handleEncryptedDataResetIfNeeded()   // R3-2: fact pushes consume the reset flag too
        }
    }

    func beginArming() {
        guard state == .disarmed else { return }
        // Never snapshot `armedPro` from an unresolved entitlement — that arms a session
        // permanently degraded for no reason the owner can see. The UI disables the control
        // while this is true; the guard is here so no other caller can route around it.
        guard !armingBlockedByEntitlementCheck else { return }
        // Defensive: `handleTrip` checks `dryRunActive` BEFORE the armed guard, so a dry run
        // that somehow outlived its sheet would silently swallow every tamper. The sheet's
        // `onDisappear` is what normally ends it — this makes the engine's own invariant
        // ("never armed while dry-running") hold without relying on UI modality.
        if dryRunActive { stopDryRun() }
        armedPro = entitlements.proActive     // snapshot Pro for the whole session (trial began at launch)
        recoveredInterruptedSession = false   // dismiss the recovery note once re-arming
        cloudPushRefused = false              // a new watch gets a fresh verdict (32.R1)
        cloudResetNotice = nil                // the pending badges carry the story from here
        armWasAutoRecovered = false           // a manual arm is user-initiated (cancellable)
        refreshSirenVolumeWarning()
        refreshDeviceName()
        refreshGuidedAccess()
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
        // Warm CloudKit while the user reads; sets up (or tears down) the cross-device push
        // subscription per the user's preference. Cloud is a Pro feature — the free tier
        // keeps evidence on-device, so skip it entirely (evidence still saves locally).
        if armedPro {
            Task { await cloud.warmUp(notifyOtherDevices: settings.notifyOtherDevicesEffective(pro: armedPro)) }
        }
        // Note up front if "Both" can't use multi-cam on this device.
        cameraNotice = (effectiveCameraPosition == .both && !CameraController.supportsMultiCam)
            ? "This device doesn't support multi-cam — “Both” captures the front camera only."
            : nil
        audioNotice = nil
        sirenNotice = nil
        refreshPermissionNotices()
        Task { await refreshNotificationHealth() }   // 34.H7 — before the owner walks away
        guard settings.isEnabled(.camera) else { return }
        // Battery saver — and Auto while on battery — skip the pre-warm and instead
        // cold-start the camera on a trigger (see captureFrom). Everything else keeps
        // the session warm so the first capture is instant.
        guard cameraShouldBeWarm else { return }
        warmActiveCamera()
    }

    /// Whether the camera session should be kept warm right now, per the user's
    /// battery-readiness setting and the current charging state.
    private var cameraShouldBeWarm: Bool {
        settings.isEnabled(.camera) && settings.cameraReadiness.keepsCameraWarm(charging: isCharging)
    }

    // MARK: - Bounded camera warm-up (34's warmUp hardening)

    /// How long a camera warm-up may take before the caller stops waiting. Generous — a
    /// cold start takes ~0.5–2 s — because a false timeout costs one capture, while no
    /// bound at all is the H10 wedge shape: `AVCaptureSession.startRunning()` can block
    /// indefinitely, and an awaited warm-up hanging on the trigger path leaves
    /// `isHandlingTrigger` stuck — detection dead until disarm, with nothing logged.
    nonisolated static let warmUpDeadline: TimeInterval = 8

    /// First-resume-wins latch for racing an un-cancellable operation against its deadline
    /// (the `PerRecordResults` pattern: a class because two unstructured tasks share it).
    private final class DeadlineLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Races an un-cancellable operation against a wall-clock deadline. Deliberately NOT a
    /// task group: a group awaits every child before returning, and session-queue work
    /// ignores cancellation — so a group-shaped timeout would still hang exactly as long as
    /// the thing it exists to cut short. The loser is abandoned instead: on timeout the
    /// operation keeps running unstructured, which is why callers guard late side-effects
    /// with `cameraWarmGeneration` — a stale completion must not join a newer warm intent.
    nonisolated static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let latch = DeadlineLatch()
            Task {
                do { let value = try await operation(); if latch.claim() { cont.resume(returning: value) } }
                catch { if latch.claim() { cont.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if latch.claim() { cont.resume(throwing: CameraController.CameraError.timedOut) }
            }
        }
    }

    /// Bumped on every new warm intent. A warm-up that outlived its deadline still finishes
    /// eventually on the session queue; comparing against the generation it was started
    /// under keeps its state writes (vision-tap status, warm-up-failure notices) from
    /// clobbering whatever a NEWER warm has since established.
    private var cameraWarmGeneration = 0

    /// Brings up the session for whichever camera(s) the settings select — used both
    /// for the pre-arm warm and when Auto flips back to warm (device plugged in).
    private func warmActiveCamera() {
        guard settings.isEnabled(.camera) else { return }
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
        cameraWarmGeneration += 1
        let generation = cameraWarmGeneration
        if effectiveCameraPosition == .both && CameraController.supportsMultiCam {
            Task { [camera] in
                do { try await Self.withDeadline(Self.warmUpDeadline) { try await camera.warmUpMultiCam(forClips: forClips) } }
                catch { if generation == cameraWarmGeneration { reportCameraWarmupFailure(error) } }
                guard generation == cameraWarmGeneration else { return }   // a newer warm owns the state now
                visionMonitor?.tapActive = camera.visionTapActive
                visionTapUnavailable = (camera.visionTapActive == false)
            }
        } else {
            let warmCamera: CameraChoice
            switch effectiveCameraPosition {
            case .rear: warmCamera = .rear
            case .auto: warmCamera = resolveAutoCamera()
            default:    warmCamera = .front   // front, both-unsupported
            }
            Task { [camera] in
                do { try await Self.withDeadline(Self.warmUpDeadline) { try await camera.warmUp(forClips: forClips, camera: warmCamera) } }
                catch { if generation == cameraWarmGeneration { reportCameraWarmupFailure(error) } }
                guard generation == cameraWarmGeneration else { return }   // a newer warm owns the state now
                visionMonitor?.tapActive = camera.visionTapActive
                visionTapUnavailable = (camera.visionTapActive == false)
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
        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        if settings.isEnabled(.camera), cam == .denied || cam == .restricted {
            cameraNotice = "Camera access is denied — no photo or video evidence can be captured. Allow Camera in iOS Settings → Privacy."
        }
        // Clips need the mic as much as the Sound tripwire does (34.H12): with Sound off
        // and clip capture on, a denied microphone meant every clip recorded SILENTLY with
        // no warning anywhere — discovered only on playback, after the incident.
        if Self.micPermissionMatters(audioSensorOn: sensorEnabled(.audio),
                                     cameraOn: settings.isEnabled(.camera),
                                     captureIsClip: effectiveCaptureMode.isClip,
                                     multiCam: effectiveCameraPosition == .both
                                        && CameraController.supportsMultiCam),
           AVAudioApplication.shared.recordPermission == .denied {
            audioNotice = "Microphone access is denied — the Sound tripwire won't run and video clips will have no audio. Allow Microphone in iOS Settings → Privacy."
        }
    }

    /// Pure (unit-tested). Whether a denied microphone deserves a warning at arm time: the
    /// Sound tripwire needs it, and so does clip capture — a clip session without a mic
    /// records silently (34.H12).
    nonisolated static func micPermissionMatters(audioSensorOn: Bool, cameraOn: Bool,
                                                 captureIsClip: Bool, multiCam: Bool = false) -> Bool {
        // In multi-cam ("Both") mode the clip half is moot: those clips carry no audio track
        // by design (31.F10, disclosed) — a GRANTED mic records nothing either, so a denied
        // one is not the reason and the warning would mislead (eighth review, L9). The Sound
        // tripwire's claim on the mic stands in every mode.
        audioSensorOn || (cameraOn && captureIsClip && !multiCam)
    }

    /// Surfaces a camera warm-up failure so the user isn't left "armed but blind".
    private func reportCameraWarmupFailure(_ error: Error) {
        let reason = (error as NSError).localizedDescription
        cameraNotice = "Camera unavailable — evidence capture may fail. Check camera permission. (\(reason))"
        Log.engine.error("Camera warm-up failed at arming: \(String(describing: error), privacy: .public)")
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
            return "Notifications are off for Malinois — tamper alerts from your other devices won't be shown on this device. Allow Notifications in iOS Settings."
        }
        if registrationFailed {
            return "Push registration failed — this device can't receive cross-device tamper alerts right now."
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
    }

    /// Whether a user-initiated arm is currently blocked for want of Guided Access.
    /// Drives the arming screen, which offers both remedies (turn GA on, or lift the
    /// requirement for this arm) rather than dead-ending.
    var armingBlockedByGuidedAccess: Bool {
        Self.armingBlocked(requireGuidedAccess: settings.requireGuidedAccess,
                           guidedAccessOn: guidedAccessEnabled,
                           liftedThisArm: guidedAccessLiftedThisArm)
    }

    /// Pure (unit-tested). Arming is blocked only when the owner asked for the requirement
    /// *and* Guided Access is off *and* the requirement wasn't lifted for this one arm.
    /// Deliberately not consulted by crash recovery — see `reArmAfterRecovery`.
    nonisolated static func armingBlocked(requireGuidedAccess: Bool, guidedAccessOn: Bool,
                                          liftedThisArm: Bool = false) -> Bool {
        requireGuidedAccess && !liftedThisArm && !guidedAccessOn
    }

    /// One-shot lift of the Guided Access requirement (eighth review, M2 — option A). The
    /// arming screen's escape button used to flip the STORED setting: an unauthenticated,
    /// unlogged, PERMANENT downgrade available to anyone holding the unlocked phone (arming
    /// is deliberately ungated; disarming is the guarded door). Now the stored setting never
    /// changes from the arming screen: the lift covers the current arming flow only, is
    /// logged and pushed as an audit record (`gaLifted`), and expires when the arming screen
    /// closes or the session ends — the owner's future arms re-assert the requirement.
    @Published private(set) var guidedAccessLiftedThisArm = false

    func liftGuidedAccessRequirementForThisArm() {
        guard armingBlockedByGuidedAccess else { return }
        guidedAccessLiftedThisArm = true
        logStateChange("gaLifted")
    }

    /// Expires an unused lift — called when the arming screen goes away and at disarm.
    func clearGuidedAccessLift() {
        guidedAccessLiftedThisArm = false
    }

    /// Whether arming must wait for the entitlement check to finish.
    ///
    /// `beginArming` snapshots `armedPro` for the whole session, and `status` starts `.free`
    /// while StoreKit resolves. Arming inside that window silently produced a session with no
    /// Sound, no Vision, no multi-cam and short clips — for its entire duration, even though
    /// entitlement resolved milliseconds later. Nothing said so; the owner had paid for
    /// features that simply did not run.
    ///
    /// Pure so the rule is pinned rather than implied by a view modifier. The wait is short and
    /// bounded by a local cache read (see `ProEntitlements.refresh`), and it is *visible* — Home
    /// says "Checking Pro status…" throughout — which is the difference between a delay and a
    /// silent downgrade.
    nonisolated static func armingBlockedByEntitlementCheck(entitlementResolved: Bool) -> Bool {
        !entitlementResolved
    }

    /// Drives the ARM control. Published so the button can disable itself and say why.
    var armingBlockedByEntitlementCheck: Bool {
        Self.armingBlockedByEntitlementCheck(entitlementResolved: entitlements.hasResolved)
    }

    /// Step 2: the user confirmed the Guided Access coaching and wants to proceed to the
    /// grace countdown. Guided Access is recommended by default; if the owner has turned on
    /// "Require Guided Access", arming refuses while it's off.
    func confirmGuidedAccessAndStartGrace() {
        refreshGuidedAccess()
        guard !armingBlockedByGuidedAccess else { return }
        beginGraceCountdown()
    }

    /// The grace countdown itself, with no Guided Access gate. Crash recovery uses this
    /// directly: if the app died and Guided Access ended with it, refusing to re-arm would
    /// leave the device silently **unprotected** — the exact failure F-12 exists to prevent.
    /// Re-protecting on a weaker footing beats not re-protecting at all; the arming screen
    /// still shows that Guided Access is off.
    private func beginGraceCountdown() {
        // Re-sample the siren volume here, entering the grace step — this is the screen
        // that actually renders the low-volume warning, and it comes right after the
        // coaching that tells the user to turn the volume up, so the warning reflects the
        // volume as of *now* rather than back at beginArming (V-06).
        refreshSirenVolumeWarning()
        startGraceCountdown()
    }

    private func startGraceCountdown() {
        state = .arming
        let total = max(0, settings.gracePeriodSeconds)
        graceRemaining = total
        graceEndsAt = Date().addingTimeInterval(Double(total))
        graceTimer?.invalidate()
        // Wall-clock driven, and scheduled in `.common` run-loop modes. The old version
        // decremented once per tick in `.default` mode — so a single missed tick (a
        // first-run main-thread hitch, or the run loop entering an animation/tracking mode
        // where `.default` timers pause) FROZE the number, the "stalls at N for ~10s" bug.
        // Deriving the number from real elapsed time makes a delayed tick self-correct, and
        // `.common` mode keeps it firing through UI animation. Ticks faster (0.2s) so it
        // recovers promptly. (Calibration was already wall-clock based, so it never stalled.)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let endsAt = self.graceEndsAt else { return }
                let remaining = endsAt.timeIntervalSinceNow
                self.graceRemaining = max(0, Int(remaining.rounded(.up)))
                if remaining <= 0 {
                    self.graceTimer?.invalidate(); self.graceTimer = nil
                    self.graceEndsAt = nil
                    self.startCalibration()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    private func startCalibration() {
        state = .calibrating
        calibrationProgress = 0
        applyEnabledAndSensitivity()

        // Begin calibration on monitors that need it.
        for (_, m) in monitors where m.isEnabled && m.requiresCalibration {
            m.beginCalibration()
        }

        let start = Date()
        calibrationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.calibrationProgress = min(1, elapsed / self.calibrationDuration)
                if elapsed >= self.calibrationDuration {
                    self.calibrationTimer?.invalidate(); self.calibrationTimer = nil
                    self.finishCalibrationAndArm()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keep progress advancing through UI animation
        calibrationTimer = timer
    }

    private func finishCalibrationAndArm() {
        for (_, m) in monitors where m.isEnabled && m.requiresCalibration {
            m.endCalibration()
        }
        lastCalibration = makeCalibrationSummary()
        // Start watching NOW, before the review — the "calibration complete" screen
        // is for the owner's benefit and must not be an unprotected gap. The sensors
        // run during the review; a tamper is handled (handleTrip allows it, and
        // fireTrigger goes covert first — see below). With no tamper, the screen goes
        // covert after ~2s. The review card shows no Cancel button, so the covert step
        // isn't user-cancellable — but the guard below (still in the review + still
        // .calibrating) makes it a no-op if a disarm arrives from any path meanwhile.
        startWatching()
        showingCalibrationReview = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.showingCalibrationReview, self.state == .calibrating else { return }
            self.goCovert()
        }
    }

    /// Turns the raw calibration numbers into plain-language quality labels.
    private func makeCalibrationSummary() -> CalibrationSummary {
        var motionQ: String?, motionD: String?, audioQ: String?, audioD: String?
        if settings.isEnabled(.motion), let m = monitors[.motion] as? MotionMonitor {
            let n = m.calibratedNoiseFloor
            motionQ = n < 0.008 ? "Very stable" : n < 0.02 ? "Stable" : "Unsteady — may false-trip"
            motionD = String(format: "resting noise %.3f g", n)
        }
        if sensorEnabled(.audio), let a = monitors[.audio] as? AudioMonitor {
            if !a.healthy {
                // F7: a dead recorder reports the -160 floor, which the thresholds below
                // would praise as "Very quiet" — a failure dressed as excellence.
                audioQ = "Microphone unavailable"
                audioD = "check mic permission"
            } else {
                let db = a.calibratedBaselineDB
                audioQ = db < -55 ? "Very quiet" : db < -42 ? "Quiet" : db < -30 ? "Moderate" : "Noisy — may false-trip"
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
        recentTrips.removeAll()
        latchedSensors.removeAll()
        sensorTripTimes.removeAll()
        recentTriggerTimes.removeAll()   // F8: don't inherit a prior session's aggregate-flood count
        // Canary baseline: only a *loss* of a path we had at arm is suspicious.
        hadConnectivityAtArm = connectivity.isOnline
        blackoutEscalated = false
        lastMotionTrip = nil
        for (_, m) in monitors where m.isEnabled { m.start() }
        startRefractorySweep()
        if armedSince == nil {
            armedSince = Date()          // start of the watch
            logStateChange("armed")      // explicit audit entry (only once per continuous watch)
        }
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
    private func goCovert() {
        showingCalibrationReview = false
        state = .armed
        engageCovertScreen()
    }

    private func applyEnabledAndSensitivity() {
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
    private func syncVisionTap() {
        camera.setVisionTapEnabled(visionTapWanted)
    }

    /// The engine-side truth `syncVisionTap` hands the camera — also consulted directly
    /// where the engine used to read the camera's own flag back from the main actor
    /// (seventh review, #4: that read was half of the cross-queue race).
    private var visionTapWanted: Bool {
        sensorEnabled(.vision) && settings.isEnabled(.camera)
    }

    // MARK: - Screen brightness

    /// Sets the display brightness from the current state — highest priority first:
    /// capture flash → disarm PIN entry → tamper alert → recording → covert black.
    private func refreshBrightness() {
        // Covert enforcement belongs to the covert screen only. While disarmed, never force
        // brightness (don't black out Home) — and during grace/calibration the normal arming
        // UI is on screen: the countdown is the owner's cancel window (V-04), and blacking it
        // out defeats it. Found on device 2026-08-29, the first time the recovery countdown
        // appeared at cold launch: this used to gate on `state.isActive`, which includes
        // `.arming`, so the scene-activation refresh landed mid-countdown and applied the
        // ladder's black to the one screen the owner is supposed to read and cancel.
        guard Self.enforcesCovertBrightness(state) else { return }
        UIScreen.main.brightness = Self.brightnessLevel(captureFlash: captureFlash,
                                                        padOpen: disarmEntryActive,
                                                        alertActive: alertActive,
                                                        recording: camera.isRecordingActive,
                                                        previous: previousBrightness)
    }

    /// Pure (unit-tested): which states the covert brightness ladder applies to — exactly the
    /// ones that render the covert screen. Everything else (Home, the arming flow) shows the
    /// normal UI at the owner's own brightness. Deliberately narrower than `isActive`, which
    /// exists for the app-switcher cover and answers a different question.
    nonisolated static func enforcesCovertBrightness(_ state: MonitoringState) -> Bool {
        state == .armed || state == .triggered
    }

    /// Pure (unit-tested). The covert screen's brightness ladder. The `recording` rung is
    /// the 2.5.14 requirement: while any capture session is live the screen must never be
    /// fully dark, or the REC indicator would be invisible and the app "blank during
    /// recording". Only with the camera genuinely off does covert drop to true black.
    nonisolated static func brightnessLevel(captureFlash: Bool, padOpen: Bool,
                                            alertActive: Bool, recording: Bool,
                                            previous: CGFloat) -> CGFloat {
        if captureFlash { return 1.0 }
        if padOpen { return max(previous, 0.6) }
        if alertActive { return alertScreenBrightness }
        if recording { return recordingScreenBrightness }
        return 0
    }

    /// Restores/re-applies covert brightness across app backgrounding, so a
    /// backgrounded-while-armed device isn't left globally dimmed (or, on return,
    /// bright). Called from RootView on scene-phase changes.
    func handleScenePhase(_ active: Bool) {
        if active {
            // Run an owed crash-recovery re-arm now that the owner is actually looking, so
            // the grace countdown's cancel window is visible (V-04). Reads the persisted flag
            // so a re-arm deferred on a background launch — even across a terminate — is
            // honored on the first foreground (M4). `performRecoveryReArm` re-checks and
            // clears the flag, so this is idempotent if the phase fires more than once.
            if state == .disarmed, UserDefaults.standard.bool(forKey: Self.pendingReArmKey) {
                performRecoveryReArm()
            }
            // Flush anything still pending. A background-task expiration mid-upload leaves an
            // event `.pending`, and the other retry paths are reconnect, crash recovery, and
            // opening the Event Log — so a benign expiration on the owner's own device sat
            // unsynced until they happened to browse the log (M3). No-op off Pro, and cheap
            // when nothing is pending.
            Task { await retryPendingSync() }
            // Re-sample Guided Access (BACKLOG 24). `guidedAccessStatusDidChangeNotification`
            // is only delivered to a running process, so a toggle made while the app was
            // suspended is missed entirely and never replayed on resume. Without this, Home's
            // "Guided Access ready / off" row kept showing the pre-background value until the
            // owner happened to enter the arming flow, which is the one place that re-sampled.
            // A security app showing a stale security indicator is the wrong kind of wrong.
            refreshGuidedAccess()
            // Enforce the automatic cloud-retention policy, at most daily (32.R2).
            Task { await enforceCloudRetentionIfDue() }
            // Notification permission may have changed in iOS Settings while suspended (34.H7).
            Task { await refreshNotificationHealth() }
            // Back in the foreground: any logged lapse has ended, so a kill from here is a
            // separate interruption and must be recorded as one.
            UserDefaults.standard.removeObject(forKey: Self.backgroundLapseLoggedKey)
            refreshBrightness()                       // re-apply covert/alert
        } else if state.isActive {
            UIScreen.main.brightness = previousBrightness   // don't leave system dimmed
        }
    }

    /// Auto-lock is disabled for every state except `.disarmed` — see `keepsDeviceAwake`.
    /// Centralised so the flag can't be set in one path and forgotten in another.
    private func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = Self.keepsDeviceAwake(state)
    }

    /// Pure (unit-tested). Which states must keep the display from sleeping.
    ///
    /// `.arming` and `.calibrating` are the ones worth stating outright: they were missing,
    /// and their absence meant a phone set face down could lock and suspend the app before the
    /// watch ever started.
    nonisolated static func keepsDeviceAwake(_ state: MonitoringState) -> Bool {
        state != .disarmed
    }

    private func engageCovertScreen() {
        // `previousBrightness` was captured at `beginArming` — deliberately not re-sampled
        // here, where the display has already been dimmed by the ambient sensor.
        // Mark the session armed (storing the pre-arm brightness) so a force-quit or
        // crash can be detected and recovered at next launch.
        UserDefaults.standard.set(Double(previousBrightness), forKey: Self.armedMarkerKey)
        // The recovered watch is now protected; the armed marker covers it from here (F1).
        UserDefaults.standard.removeObject(forKey: Self.recoveryInProgressKey)
        refreshIdleTimer()
        refreshBrightness()
    }

    private func releaseCovertScreen() {
        UIApplication.shared.isIdleTimerDisabled = false   // state is (or is becoming) .disarmed
        UIScreen.main.brightness = previousBrightness   // restore the user's level
        UserDefaults.standard.removeObject(forKey: Self.armedMarkerKey)   // clean exit
        UserDefaults.standard.removeObject(forKey: Self.recoveryInProgressKey)   // and no owed recovery (F1)
    }

    /// Raise the screen so the hidden disarm PIN pad is actually visible.
    /// NOTE: this does NOT stop the siren — only a verified PIN (disarm) does,
    /// otherwise anyone could silence the alarm just by holding the screen.
    /// The alert *message* is hidden during PIN entry by ArmedView's showPINPad.
    /// Called on the disarm HOLD press-down (before the pad opens). Opens the owner-
    /// attribution candidate window so the touch that starts the hold — and anything
    /// captured during the 5 s hold — is attributed to the owner if a correct PIN follows.
    func noteDisarmCandidate() { disarmCandidateSince = Date() }

    /// The hold was released before the pad opened (a tap, not a disarm). Close the
    /// candidate window; those events stand as evidence. No-op once the pad is open.
    func cancelDisarmCandidate() {
        guard !disarmEntryActive else { return }
        disarmCandidateSince = nil
        disarmEntryEventIDs.removeAll()
    }

    func beginDisarmEntry() {
        disarmEntryActive = true
        // Seed the activity clock so the owner gets the same grace while reaching for the first
        // key as they do between keys — the pad opening is itself a deliberate 5-second act.
        // NOTE (external review, 2026-08-23): this is a deliberate, BOUNDED re-widening of
        // A-02, not the pad-openness gating A-02 removed — it grants one 20 s window, costs a
        // logged 5 s hold to enter, is not renewable without another hold, and suppresses only
        // the flash + a fresh alert start. Evidence capture/push is never suppressed.
        lastDisarmKeypress = Date()
        // Proximity monitoring blanks the display when the sensor is covered, which
        // would hide the PIN pad — pause just that one sensor while entering the PIN.
        // (Motion, power and audio keep detecting — see handleTrip. The touch surface itself
        // is replaced by the pad while it is open, but the 5-second hold that opened it was
        // already logged as a touch trip on press-down; 32.R7.)
        monitors[.proximity]?.stop()
        refreshBrightness()
        disarmEntryStartedAt = Date()
        scheduleDisarmEntryTimeout()
    }

    private func scheduleDisarmEntryTimeout() {
        disarmEntryTimer?.invalidate()
        disarmEntryTimer = Timer.scheduledTimer(withTimeInterval: disarmEntryTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endDisarmEntry() }
        }
    }

    /// Called by the PIN pad on each digit: reset the inactivity timer so a slow owner
    /// (reading a dim screen, mistyping) isn't dropped mid-entry (R-09) — but never past
    /// an absolute ceiling, so the pad still can't be held open forever.
    func noteDisarmActivity() {
        guard disarmEntryActive else { return }
        // Records that entry is genuinely in progress, which is what suppresses the alert and
        // the capture flash (A-02). Deliberately updated even past the ceiling below: it only
        // ever reflects "a key was just pressed", and the ceiling governs the pad's lifetime,
        // not whether the owner is typing.
        lastDisarmKeypress = Date()
        if let start = disarmEntryStartedAt, Date().timeIntervalSince(start) > disarmEntryCeiling { return }
        scheduleDisarmEntryTimeout()
    }

    /// Return to covert (or alert) state if PIN entry is dismissed without disarm.
    func endDisarmEntry() {
        disarmEntryTimer?.invalidate(); disarmEntryTimer = nil
        disarmEntryStartedAt = nil
        disarmEntryActive = false
        lastDisarmKeypress = nil
        disarmCandidateSince = nil
        // No successful PIN: whatever was captured while the pad was open stands as
        // evidence (an attacker who opened the pad but couldn't disarm).
        disarmEntryEventIDs.removeAll()
        guard state.isActive else { return }
        // The Pro-aware set, not the raw setting: proximity is free today so these agree, but
        // restarting a monitor the engine considers disabled would be a fail-open if any future
        // gate ever touched it.
        if sensorEnabled(.proximity) { monitors[.proximity]?.start() }
        refreshBrightness()
    }

    /// Light the scene for a front-camera capture by flashing the screen white.
    /// Skipped while the tamper alert is already on screen — the first (pre-alert)
    /// capture got the lit shot, and a re-flash would tell the thief a photo is
    /// being taken right now.
    private func illuminateForCapture() async {
        guard !presentationSuppressed, !alertActive else { return }
        captureFlash = true
        refreshBrightness()
        try? await Task.sleep(nanoseconds: 350_000_000)   // ~0.35s to light + settle
    }

    private func endIllumination() {
        captureFlash = false
        refreshBrightness()
    }

    // MARK: - Tamper response (alert / siren)

    /// Pure (unit-tested). A *running* alert/siren is ALWAYS kept alive (`.extend`), so a
    /// screen touch can't starve its dismiss timer into silence — only a verified PIN stops
    /// the alarm, never a hold (N-01).
    ///
    /// Starting a *fresh* alert is gated on `activeEntry` — the owner appears to be TYPING
    /// their PIN right now (the pad is up AND a key was pressed within the last 20 s; see
    /// `presentationSuppressed`, A-02) — so a legitimate disarm isn't spammed with alerts
    /// fighting the raised pad brightness. Mere pad *openness* is deliberately not enough:
    /// the pad stays up for 30–150 s of inactivity, so gating on openness handed anyone
    /// willing to do the 5-second hold that much guaranteed silence. Nor is the broader
    /// "disarm candidate" window: that opens on any touch-down, and gating there let a snoop
    /// hold the alarm off indefinitely just by keeping a finger on the glass (F1).
    /// (33-review L3: the prose and parameter here were one revision behind the code.)
    nonisolated static func alertAction(showsMessage: Bool, alertActive: Bool,
                                        activeEntry: Bool) -> AlertAction {
        guard showsMessage else { return .none }
        if alertActive { return .extend }
        return activeEntry ? .none : .present
    }

    /// Shows the on-screen warning (and starts the siren in siren mode). Called
    /// after capture. Re-triggers / ongoing tamper extend the display window.
    private func presentAlert() {
        alertActive = true
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
    private func extendAlertWindow() {
        guard alertActive else { return }
        // Continued tampering is fresh evidence the incident is live: if siren activation
        // exhausted its retries against a held audio session, re-arm the attempt budget
        // instead of extending a silent alarm (eighth-review M5).
        siren.ensureSounding()
        scheduleAlertDismiss()
    }

    private func scheduleAlertDismiss() {
        alertDismissTimer?.invalidate()
        let interval = Self.alertDismissInterval(
            base: alertDuration,
            sirenRamping: settings.responseMode == .siren && settings.sirenRampUp,
            rampHold: SirenPlayer.rampHoldSeconds, rampFade: SirenPlayer.rampFadeSeconds)
        alertDismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
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
    /// fires.
    private func soundSiren(fullVolume: Bool) {
        if sensorEnabled(.audio) { monitors[.audio]?.stop() }
        audioPausedForSiren = true
        let mustReleaseMic = effectiveCaptureMode.isClip && settings.isEnabled(.camera)
        Task { @MainActor in
            // Release the microphone, not the camera (BACKLOG 17). The conflict is over the
            // audio session, which only the mic input holds — so the video pipeline can keep
            // running, and the vision tripwire keeps watching through the alarm instead of
            // going blind for its whole duration.
            if mustReleaseMic { await camera.dropMicAndWait() }
            // The owner may have disarmed during the wait — don't resurrect the alarm.
            guard alertActive else { return }
            if fullVolume { siren.goFullVolume() } else { siren.start(rampUp: settings.sirenRampUp) }
        }
    }

    /// Resume the Audio tripwire once the siren has released the audio session.
    private func resumeAudioAfterSiren() {
        guard audioPausedForSiren else { return }
        audioPausedForSiren = false
        guard state == .armed else { return }
        if sensorEnabled(.audio) { monitors[.audio]?.start() }
        if cameraShouldBeWarm { warmActiveCamera() }   // undo the release above
    }

    /// Stop the Audio tripwire while a clip records (F-14): the capture session takes
    /// over the mic, which otherwise silently interrupts our metering recorder. Making
    /// the contention deliberate (rather than incidental) means the recorder isn't left
    /// stalled after the clip. Not needed while the siren already owns the session.
    private func pauseAudioForCapture() {
        guard sensorEnabled(.audio), !audioPausedForCapture, !audioPausedForSiren else { return }
        monitors[.audio]?.stop()
        audioPausedForCapture = true
    }

    private func resumeAudioAfterCapture() {
        guard audioPausedForCapture else { return }
        audioPausedForCapture = false
        // Don't restart under the siren (it owns the session); resumeAudioAfterSiren will.
        if state == .armed, sensorEnabled(.audio), !audioPausedForSiren {
            monitors[.audio]?.start()
        }
    }

    // MARK: - Jamming response (connectivity blackout)

    private func handleConnectivityChange(_ online: Bool) {
        isOnline = online
        if online {
            offlineSince = nil
            blackoutTimer?.invalidate(); blackoutTimer = nil
            standDownBlackout()                 // benign outage resolved / jam lifted
            Task { await retryPendingSync() }   // auto-flush the instant a path returns
            // Recover the cross-device push subscription if it failed to set up at
            // arm (network briefly down then) — otherwise the owner's other devices
            // get no alert for the whole session. Idempotent; no-op if already set.
            // `cloudAllowed` so a mid-session upgrade also gets the subscription (P-01).
            if cloudAllowed && settings.notifyOtherDevices {
                Task { await cloud.refreshSubscription(notifyOtherDevices: true) }
            }
        } else {
            if offlineSince == nil { offlineSince = Date() }   // the transition, not a re-report
            guard state == .armed, hadConnectivityAtArm, settings.jammingResponse else { return }
            // Debounce a total loss before treating it as suspected jamming.
            blackoutTimer?.invalidate()
            blackoutTimer = Timer.scheduledTimer(withTimeInterval: blackoutDebounce, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.evaluateBlackout() }
            }
        }
    }

    private func evaluateBlackout() {
        guard Self.shouldEscalateBlackout(armed: state == .armed,
                                          enabled: settings.jammingResponse,
                                          online: connectivity.isOnline,
                                          hadConnectivityAtArm: hadConnectivityAtArm,
                                          stationary: isStationary,
                                          alreadyEscalated: blackoutEscalated) else { return }
        escalate(.blackout)
        // A jammer setting up is likely nearby — grab a frame while we're loud.
        Task { await captureBlackoutEvidence() }
    }

    /// Pure decision (unit-tested): a stationary armed device that had a path at arm
    /// and has now totally lost it — feature on, not already escalated.
    static func shouldEscalateBlackout(armed: Bool, enabled: Bool, online: Bool,
                                       hadConnectivityAtArm: Bool, stationary: Bool,
                                       alreadyEscalated: Bool) -> Bool {
        armed && enabled && !online && hadConnectivityAtArm && stationary && !alreadyEscalated
    }

    /// The path must have been down at least this long before the trigger-time go-loud
    /// trusts the instantaneous offline reading (39.R2.2): a WiFi↔cellular handoff can leave
    /// the path unsatisfied for well under a second, and a genuine jam-then-grab timeline
    /// runs seconds to minutes — a 2 s floor filters the coincidence while barely delaying
    /// the deterrent. The 30 s blackout canary and the observed-failure path stand behind it.
    nonisolated static let offlineBlipFilter: TimeInterval = 2

    /// Pure decision (unit-tested): at trigger time, a real tamper whose evidence can't be
    /// exfiltrated should abandon covertness and go loud — but ONLY when a path we HAD at
    /// arm has since dropped (suspected jamming), and only once it has been down past the
    /// blip filter, so a sub-second handoff flap plus a coincidental trigger can't sound the
    /// siren (39.R2.2 — `jammingResponse` defaults ON, so the opt-in is soft). A device
    /// armed offline in a benign dead zone must not force-siren; its evidence is simply
    /// stored locally and uploads later. Mirrors `shouldEscalateBlackout`'s
    /// `hadConnectivityAtArm` gate (V-03).
    static func shouldGoLoudOnFailedExfil(jammingResponse: Bool, online: Bool,
                                          hadConnectivityAtArm: Bool,
                                          offlineFor: TimeInterval) -> Bool {
        jammingResponse && !online && hadConnectivityAtArm && offlineFor >= offlineBlipFilter
    }

    private var isStationary: Bool {
        lastMotionTrip.map { Date().timeIntervalSince($0) > stationaryWindow } ?? true
    }

    /// Abandon covertness. Blackout (jamming) sirens and persists until the PIN;
    /// flood shows a visible warning (siren only in siren mode) that fades like a
    /// normal alert but re-extends while the flood continues.
    private func escalate(_ reason: Escalation) {
        if escalation == .blackout { return }        // strongest state; don't downgrade
        if escalation == reason {
            if !reason.persists { scheduleAlertDismiss() }   // extend the flood window
            return
        }
        if reason == .blackout { blackoutEscalated = true }
        escalation = reason
        alertActive = true
        refreshBrightness()
        if reason.forcesSiren || settings.responseMode == .siren {
            // No ramp on an escalation: suspected jamming means the evidence may never
            // escape, and a flood is an active attack — both need to be loud NOW.
            // goFullVolume() handles every prior state (not started, mid-ramp, or
            // interrupted by a call), so it overtakes a ramping siren or (re)starts a
            // stopped one at full volume.
            soundSiren(fullVolume: true)
        }
        if !reason.persists { scheduleAlertDismiss() }
    }

    /// Stand down a *blackout* escalation when connectivity returns (a benign outage
    /// resolved, or the jam lifted after doing its deterrent job). disarm() clears
    /// everything separately; a flood fades on its own dismiss timer.
    private func standDownBlackout() {
        guard escalation == .blackout else { return }
        escalation = nil
        // Re-arm the escalation for the NEXT blackout. Without this the one-shot is
        // spent for the whole session, so an attacker can burn it with a brief jam,
        // let the path return (we stand down), then jam for real — silently.
        blackoutEscalated = false
        alertActive = false
        siren.stop()
        resumeAudioAfterSiren()
        refreshBrightness()
    }

    /// Captures a still on a suspected-jamming blackout and logs it (sensorless,
    /// flagged offline) so there's evidence and a record even with no sensor trip.
    private func captureBlackoutEvidence() async {
        // Always LOG the blackout (a suspected-jamming record), even with the camera
        // OFF — the *fact* of the interference matters more than the photo, and the
        // whole point is that it survives (F-16). Only the frame grab is camera-gated.
        // Carry the sensor traces (as the flood path does). For a suspected jamming record the
        // motion trace is the most probative thing available: it evidences that the device was
        // sitting still while every network path vanished, which is the whole basis for calling
        // it jamming rather than a device carried out of coverage.
        var event = Event(startDate: Date(), endDate: Date(),
                          triggeredSensors: [],
                          motionTrace: monitors[.motion]?.recentTrace() ?? [],
                          audioTrace: monitors[.audio]?.recentTrace() ?? [],
                          visionTrace: monitors[.vision]?.recentTrace(),
                          cloudSyncState: .pending,
                          capturedOffline: true)
        eventStore.add(event)
        eventCount = eventStore.events.count
        let fact = event
        pushFactIfCloud(fact)   // get the fact out immediately (Pro only)
        // The session's cloud authorization, decided WITH the record (sixth-review F3):
        // sampled before the capture below, so a disarm or trial expiry mid-capture can't
        // split this event across tiers (P-01's live-session no-downgrade).
        let sessionAllowed = cloudAllowed

        if settings.isEnabled(.camera),
           Self.mayRunCadenceCapture(handlingTrigger: isHandlingTrigger,
                                     capturingUntilClear: isCapturingUntilClear,
                                     cadenceBusy: cadenceCaptureBusy) {
            cadenceCaptureBusy = true
            defer { cadenceCaptureBusy = false }
            let cam: CameraChoice
            switch effectiveCameraPosition {
            case .rear: cam = .rear
            case .auto: cam = resolveAutoCamera()
            default:    cam = .front   // front / both → a single grab is enough here
            }
            // A still by construction (ADR 0003): a frame answers this record's purpose, and
            // a still cannot contend for the movie output. In practice the blackout already
            // forces stills via the escalation (F4); this makes it structural, not incidental.
            if let cap = await captureFrom(cam, forcePhoto: true), let stored = await eventStore.store(cap.source, ext: cap.ext) {
                event.mediaFilename = stored.filename
                event.primaryCamera = cam.rawValue
                event.thumbnailData = stored.thumbnail
                event.endDate = Date()
                eventStore.update(event)
            }
            // On battery with no path; return to cold standby if the readiness policy
            // wants it (this grab is why the session came up).
            standDownCameraIfNeeded()
        } else if settings.isEnabled(.camera) {
            // A trigger capture owns the camera (34.H10) — the blackout RECORD above stands
            // either way; only the frame grab yields.
            Log.engine.info("Blackout frame skipped — a trigger capture owns the camera")
        }
        // Re-read the stored copy (monotonic-field preservation, sixth-review F2) and push
        // under the authorization decided at creation.
        let ev = eventStore.events.first { $0.id == event.id } ?? event
        Task { await exfiltrate(ev, cloudAllowedOverride: sessionAllowed) }   // .localOnly now; retried on reconnect
    }

    /// Whether to light the current capture, honouring the illumination mode
    /// (Auto only fires when the active camera reports a dim scene).
    private func shouldIlluminate() async -> Bool {
        switch settings.illumination {
        case .off:  return false
        case .on:   return true
        case .auto: return await camera.isLowLight()
        }
    }

    /// Resolves the "Auto (by orientation)" camera: rear when the phone is
    /// face-down (screen hidden, rear lens up), front otherwise.
    private func resolveAutoCamera() -> CameraChoice {
        UIDevice.current.orientation == .faceDown ? .rear : .front
    }

    // MARK: - Trip handling

    /// Called by sensor monitors and by the touch overlay.
    func handleTrip(_ sensor: SensorType) {
        // Test Sensors mode: record the would-trip for the UI to flash and re-arm
        // the monitor so it can fire again — never create an event.
        if dryRunActive {
            dryRunTrips[sensor] = Date()
            dryRunCounts[sensor, default: 0] += 1
            monitors[sensor]?.rearm()
            return
        }
        if sensor == .motion { lastMotionTrip = Date() }   // movement → not stationary
        // During an "until clear" recording, trips just refresh the activity
        // clock — and keep any alert/siren alive while tampering continues.
        if isCapturingUntilClear {
            lastCaptureActivity = Date()
            extendAlertWindow()
            return
        }
        // A trip while a photo or fixed clip is already being captured (34-review M1):
        // record it for the in-flight event instead of dropping it, and keep a running
        // alert alive — exactly what until-clear trips do above. The capture already running
        // IS the response; the record must still show every sensor that fired.
        if state == .triggered {
            tripsDuringCapture.insert(sensor)
            extendAlertWindow()
            return
        }
        // Handle trips while armed, and also during the brief calibration review —
        // the sensors are live then (see startWatching), so a tamper in that window
        // must still fire (fireTrigger ends the review and goes covert first).
        // NOTE: detection deliberately does NOT stop during disarm PIN entry — only the
        // presentation (flash/alert) is suppressed (see illuminateForCapture / respond).
        // Suppressing detection here would make a hold on the screen a kill switch.
        guard state == .armed || (state == .calibrating && showingCalibrationReview) else { return }
        recentTrips[sensor] = Date()
        latchedSensors.insert(sensor)
        recordFloodTrip(sensor)
        pruneStaleTrips()
        if shouldTrigger() { fireTrigger() }
    }

    /// The full-screen black overlay calls this on any touch.
    func reportTouch() { handleTrip(.touch) }

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

    /// True while a blackout or flood-cadence capture is using the camera (ADR 0003).
    private var cadenceCaptureBusy = false

    // MARK: - Test Sensors (dry run)

    /// Starts a live sensor test: calibrate, run the enabled monitors, and publish
    /// their readings — but create no events and never engage the covert screen, so
    /// the user can tune sensitivity and confirm placement without polluting the log.
    func startDryRun() {
        guard state == .disarmed, !dryRunActive else { return }
        // Snapshot Pro for the dry run, exactly as beginArming does — otherwise `armedPro`
        // is still false from launch and `effectiveSensors` would silently disable the
        // (Pro) audio monitor for an in-trial user testing their sensors (P-03).
        armedPro = entitlements.proActive
        dryRunActive = true
        dryRunReadings = [:]
        dryRunTrips = [:]
        dryRunCounts = [:]
        lastCalibration = nil
        applyEnabledAndSensitivity()
        // The vision row needs frames: warm the camera for the test if vision is effective.
        syncVisionTap()
        if visionTapWanted { warmActiveCamera() }
        // Settle window first (BACKLOG 12): count down visibly, THEN calibrate — the user is
        // still holding the phone from tapping the button, and that handling is exactly the
        // noise the calibration must not learn.
        startDryRunSettle()
    }

    /// Re-learns the baselines without ending the test.
    ///
    /// Placement testing is iterative — set the phone down, read the numbers, move it, read
    /// again — and every move invalidates the baseline those numbers are measured against.
    /// Vision is the clearest case: its baseline *is* the scene, so after a move the row
    /// reports a large permanent change that means nothing at all. The only way to re-baseline
    /// used to be closing the sheet and reopening it, which also discarded the trip tally the
    /// owner was watching.
    ///
    /// Trip counts are kept on purpose; the settle countdown runs again because tapping the
    /// button is itself handling, and that is exactly the noise calibration must not learn.
    func recalibrateDryRun() {
        guard dryRunActive, dryRunCountdown == nil else { return }
        for (_, m) in monitors { m.stop() }
        dryRunTimer?.invalidate(); dryRunTimer = nil
        dryRunTrips = [:]
        lastCalibration = nil
        startDryRunSettle()
    }

    /// The settle countdown, then calibration. Shared by the initial start and by a
    /// re-calibration so the two can never drift apart.
    private func startDryRunSettle() {
        dryRunCountdown = Self.dryRunSettleSeconds
        dryRunSettleTimer?.invalidate()
        dryRunSettleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dryRunActive, let remaining = self.dryRunCountdown else { return }
                if remaining > 1 {
                    self.dryRunCountdown = remaining - 1
                } else {
                    self.dryRunSettleTimer?.invalidate(); self.dryRunSettleTimer = nil
                    self.dryRunCountdown = nil
                    self.beginDryRunCalibration()
                }
            }
        }
    }

    /// The calibrate-then-watch half of the dry run, after the settle countdown has elapsed.
    private func beginDryRunCalibration() {
        for (_, m) in monitors where m.isEnabled && m.requiresCalibration { m.beginCalibration() }
        DispatchQueue.main.asyncAfter(deadline: .now() + calibrationDuration) { [weak self] in
            guard let self, self.dryRunActive else { return }
            for (_, m) in self.monitors where m.isEnabled && m.requiresCalibration { m.endCalibration() }
            self.lastCalibration = self.makeCalibrationSummary()
            for (_, m) in self.monitors where m.isEnabled { m.start() }
            self.dryRunTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleDryRun() }
            }
        }
    }

    private func sampleDryRun() {
        guard dryRunActive else { return }
        var readings: [SensorType: SensorReading] = [:]
        for type in SensorType.tripwires {
            if let m = monitors[type], m.isEnabled, let r = m.liveReading() { readings[type] = r }
        }
        dryRunReadings = readings
    }

    func stopDryRun() {
        dryRunActive = false
        dryRunTimer?.invalidate(); dryRunTimer = nil
        dryRunSettleTimer?.invalidate(); dryRunSettleTimer = nil
        dryRunCountdown = nil
        camera.shutDown()   // the dry run may have warmed it for the vision row
        for (_, m) in monitors { m.stop() }
        dryRunReadings = [:]
        dryRunTrips = [:]
        dryRunCounts = [:]
        // Release the dry run's Pro snapshot (32.R3). A dry run requires being disarmed, so
        // no disarm() follows to clear it — and left set, `cloudAllowed` stayed true after a
        // trial lapsed, letting a connectivity flap re-establish the push subscription for a
        // now-free user: the same leak the disarm path already closed (P-01), reintroduced
        // through the side door. Arming re-snapshots, so nothing else reads this stale.
        armedPro = false
    }

    /// The test view's touch pad reports here.
    func dryRunReportTouch() {
        guard dryRunActive, settings.isEnabled(.touch) else { return }
        dryRunTrips[.touch] = Date()
        dryRunCounts[.touch, default: 0] += 1
    }

    private func pruneStaleTrips() {
        let cutoff = Date().addingTimeInterval(-correlationWindow)
        recentTrips = recentTrips.filter { $0.value >= cutoff }
    }

    // MARK: - Refractory re-arm

    private func startRefractorySweep() {
        refractoryTimer?.invalidate()
        refractoryTimer = Timer.scheduledTimer(withTimeInterval: refractorySweepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refractorySweep() }
        }
    }

    /// Re-arms any sensor whose trip has aged past the correlation window without firing, so
    /// a one-shot monitor can't stay latched forever and go silently deaf. Still required
    /// after the corroborated mode's removal: a trip arriving while `isHandlingTrigger` is
    /// true, or one absorbed by the flood path, latches but never reaches `reArm()` — this
    /// sweep is the only thing that frees it (see `latchedSensors`, F-15).
    private func refractorySweep() {
        guard state == .armed else { return }   // never during capture / until-clear
        let due = Self.refractoryDueSensors(latched: latchedSensors,
                                            trips: recentTrips,
                                            now: Date(),
                                            window: correlationWindow)
        for sensor in due {
            monitors[sensor]?.rearm()
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

    // MARK: - Trigger response

    /// A captured piece of evidence tagged with its camera + recorded length.
    private typealias Capture = (source: EventStore.MediaSource, ext: String, duration: Double, camera: CameraChoice)

    /// Captures front AND rear simultaneously via the multi-cam session. Front is
    /// lit by the screen flash, rear by its LED / torch. Falls back to a front-only
    /// single capture if the multi-cam session can't be brought up.
    private func captureBoth() async -> (Capture?, Capture?) {
        let mode = captureModeNow
        visionMonitor?.suppress(for: 4)
        do {
            let coldStarted = try await Self.withDeadline(Self.warmUpDeadline) { [camera] in
                try await camera.warmUpMultiCam(forClips: mode.isClip)
            }
            cameraNotice = nil   // multi-cam is working
            // Cold start (battery saver / Auto on battery): let exposure ramp before capture.
            if coldStarted { try? await Task.sleep(nanoseconds: 800_000_000) }
        } catch {
            cameraNotice = "Multi-cam capture unavailable — recorded the front camera only. (\((error as NSError).localizedDescription))"
            Log.engine.error("Multi-cam warm-up failed, falling back to front only: \(String(describing: error), privacy: .public)")
            let cap = await captureFrom(.front)
            return (cap.map { ($0.source, $0.ext, $0.duration, .front) }, nil)
        }

        // Decide illumination per camera (Auto reads each lens' light level).
        let screenFlash: Bool
        let rearLight: Bool
        switch settings.illumination {
        case .off:  screenFlash = false;                     rearLight = false
        case .on:   screenFlash = true;                      rearLight = true
        case .auto:
            // Let auto-exposure re-meter the current scene before the light check.
            try? await Task.sleep(nanoseconds: UInt64(autoExposureSettle * 1_000_000_000))
            screenFlash = await camera.isLowLightFront()
            rearLight = await camera.isLowLightRear()
        }

        if screenFlash { await illuminateForCapture() }
        defer { if screenFlash { endIllumination() } }

        if mode.isClip {
            let start = Date()
            pauseAudioForCapture()                       // free the mic for the clip (F-14)
            defer { resumeAudioAfterCapture() }
            camera.beginBothClips(rearTorch: rearLight)
            await recordClipDuration(mode)
            let urls = try? await camera.endBothClips()
            let elapsed = Date().timeIntervalSince(start)
            // Carry the clip files by URL — `store` MOVES them off-main; we never
            // read a (potentially huge) clip into memory here.
            return (urls?.front.map { (EventStore.MediaSource.clip($0), "mov", elapsed, .front) },
                    urls?.rear.map  { (EventStore.MediaSource.clip($0), "mov", elapsed, .rear) })
        } else {
            let both = try? await camera.captureBothStills(rearHardwareFlash: rearLight)
            return (both?.front.map { (EventStore.MediaSource.still($0), "jpg", 0, .front) },
                    both?.rear.map  { (EventStore.MediaSource.still($0), "jpg", 0, .rear) })
        }
    }

    /// Captures one still or clip from a concrete camera (`.front` or `.rear`),
    /// handling illumination — screen flash for front, LED flash/torch for rear.
    private func captureFrom(_ position: CameraChoice, forcePhoto: Bool = false) async -> (source: EventStore.MediaSource, ext: String, duration: Double)? {
        // `forcePhoto` overrides the capture mode with a single still — used by the
        // rate-limited flood capture, where a clip per cadence would be too costly.
        let mode: CaptureMode = forcePhoto ? .photo : captureModeNow
        // The vision tripwire must not judge the scene being recorded, the screen flash, or a
        // camera reconfigure; it re-anchors when the window lapses.
        syncVisionTap()
        visionMonitor?.suppress(for: 4)

        // Point the session at the requested camera. If that fails, return nil —
        // never silently capture from whatever camera happened to be configured
        // (that produced duplicate/wrong-camera "old" captures).
        let reconfigured: Bool
        do {
            // Bounded (34's warmUp hardening): this await sits on the trigger path, where a
            // blocked `startRunning()` used to wedge `respond()` with `isHandlingTrigger`
            // stuck — detection dead until disarm. On timeout the capture fails cleanly and
            // the event stands with its metadata, traces, and fact push, like any capture
            // failure; the stale warm-up finishing later is harmless here (the response is
            // over) and `standDownCameraIfNeeded` still runs after it.
            reconfigured = try await Self.withDeadline(Self.warmUpDeadline) { [camera] in
                try await camera.warmUp(forClips: mode.isClip, camera: position)
            }
        } catch {
            Log.engine.error("Camera warm-up failed (\(position.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            // F7: the cold-start path (Auto-on-battery / Battery saver) was the one place a
            // dead camera stayed invisible — surfaced only in the log, never to the owner.
            cameraNotice = "Camera unavailable — an evidence capture failed. Check camera permission in iOS Settings."
            return nil
        }
        // After switching cameras, wait for the new sensor to deliver a fresh,
        // exposed frame — otherwise the first capture can be stale or black. A
        // reconfigure already gives auto-exposure time to settle; a warm camera
        // gets a shorter settle so the Auto light check reflects the current scene
        // (the device may have been resting face-down to a dark surface) rather
        // than the stale resting reading.
        if reconfigured {
            try? await Task.sleep(nanoseconds: 800_000_000)
        } else if settings.illumination == .auto {
            try? await Task.sleep(nanoseconds: UInt64(autoExposureSettle * 1_000_000_000))
        }

        let illuminate = await shouldIlluminate()   // read AFTER settle, BEFORE flashing
        let useScreenFlash = illuminate && position == .front
        let useHardwareLight = illuminate && position == .rear
        if useScreenFlash { await illuminateForCapture() }
        defer { if useScreenFlash { endIllumination() } }

        if mode.isClip {
            let recordStart = Date()
            pauseAudioForCapture()                       // free the mic for the clip (F-14)
            defer { resumeAudioAfterCapture() }
            camera.beginClip(torch: useHardwareLight)
            await recordClipDuration(mode)
            do {
                let url = try await camera.endClip()
                let elapsed = Date().timeIntervalSince(recordStart)
                // Hand the clip file to `store` by URL — no in-memory read here.
                return (.clip(url), "mov", elapsed)
            } catch {
                Log.engine.error("Clip capture failed (\(position.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
                // A capture that fails on a session that warmed up fine used to be console-only
                // (42.H1) — the owner learned about missing evidence from the event row, if ever.
                cameraNotice = "A camera capture failed — an event may be missing its photo or clip."
                return nil
            }
        } else {
            // captureStill is internally bounded (see CameraController) so a
            // stalled photo delegate can never hang the pipeline or leak.
            let data = try? await camera.captureStill(hardwareFlash: useHardwareLight)
            if data == nil {
                Log.engine.error("Still capture failed or timed out (\(position.rawValue, privacy: .public))")
                cameraNotice = "A camera capture failed — an event may be missing its photo or clip."
            }
            return data.map { (.still($0), "jpg", 0) }   // stills have no clip length
        }
    }

    /// Holds the clip open for the configured length: a fixed number of seconds,
    /// or — for "until clear" — until no tamper activity for 5 s (capped at 120 s).
    private func recordClipDuration(_ mode: CaptureMode) async {
        if let fixed = mode.fixedDuration {
            try? await Task.sleep(nanoseconds: UInt64(fixed * 1_000_000_000))
            return
        }
        // Until-clear: sensor trips during recording refresh the activity clock.
        isCapturingUntilClear = true
        lastCaptureActivity = Date()
        let start = Date()
        let idleThreshold: TimeInterval = 5
        let maxDuration: TimeInterval = 120
        while state != .disarmed {
            try? await Task.sleep(nanoseconds: 400_000_000)
            // If the app was backgrounded, the capture session is interrupted and
            // the recording already stopped — finalize now (keeping the partial)
            // instead of waiting up to 120 s on a dead session.
            if await camera.clipWasInterrupted() { break }
            // Re-arm the tripwires so continued tampering keeps registering.
            for (_, m) in monitors where m.isEnabled { m.rearm() }
            let idle = Date().timeIntervalSince(lastCaptureActivity ?? start)
            if idle >= idleThreshold || Date().timeIntervalSince(start) >= maxDuration { break }
        }
        isCapturingUntilClear = false
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
        state = .triggered
        tripsDuringCapture.removeAll()   // fresh window for this capture (M1)
        let startDate = recentTrips.values.min() ?? Date()
        lastTriggerDate = Date()
        let session = armSession

        Task { await respond(triggeredSensors: triggered, startDate: startDate, session: session) }
    }

    // MARK: - Flood coalescing

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

    /// Trigger timestamps inside the flood window, for the aggregate check above.
    private var recentTriggerTimes: [Date] = []

    /// Pure (unit-tested). Sustained *triggers* per minute across all sensors. Set well
    /// above the ~6/min a human tamperer produces so ordinary — even frantic — handling is
    /// never coalesced, while a synthetic multi-source flood is.
    nonisolated static let aggregateFloodThreshold = 15
    nonisolated static func isAggregateFlood(_ triggerCount: Int) -> Bool {
        triggerCount > aggregateFloodThreshold
    }

    private func handleFloodTrigger(_ sensors: [SensorType]) {
        if settings.jammingResponse { escalate(.flood) }   // abandon stealth — it's an attack
        if var ev = sustainedEvent {
            // Coalesce log spam, NOT evidence. Extend the one counter event, and still
            // capture on a bounded cadence so sustained real tampering keeps being shot.
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
                Task { await captureFloodEvidence(sensors) }   // photo-only, rate-limited
            }
            reArm()
        } else {
            // Flood onset: full capture for the record, mark it as the sustained event.
            isHandlingTrigger = true
            state = .triggered
            tripsDuringCapture.removeAll()   // fresh window for this capture (M1)
            let startDate = recentTrips.values.min() ?? Date()
            lastTriggerDate = Date()
            let session = armSession
            lastFloodCapture = Date()   // onset capture resets the cadence clock
            scheduleSustainedClear()
            Task { await respond(triggeredSensors: sensors, startDate: startDate, session: session, sustained: true) }
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

    private func captureFloodEvidence(_ sensors: [SensorType]) async {
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
            motionTrace: monitors[.motion]?.recentTrace() ?? [],
            audioTrace: monitors[.audio]?.recentTrace() ?? [],
            visionTrace: monitors[.vision]?.recentTrace(),
            offline: !connectivity.isOnline)
        eventStore.add(event)
        eventCount = eventStore.events.count
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
        if let cap = await captureFrom(cam, forcePhoto: true),
           let stored = await eventStore.store(cap.source, ext: cap.ext) {
            event.mediaFilename = stored.filename
            event.primaryCamera = cam.rawValue
            event.thumbnailData = stored.thumbnail
            event.endDate = Date()
            eventStore.update(event)
        }
        // Re-read the stored copy (sixth-review F2) and push under the creation-time
        // authorization (sixth-review F3).
        let ev = eventStore.events.first { $0.id == event.id } ?? event
        Task { await exfiltrate(ev, cloudAllowedOverride: sessionAllowed) }
        standDownCameraIfNeeded()
    }

    private func scheduleSustainedClear() {
        sustainedClearTimer?.invalidate()
        sustainedClearTimer = Timer.scheduledTimer(withTimeInterval: sustainedIdleClear, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.eventStore.flush()   // capture the final coalesced count on disk (F2)
                // The cloud only heard every 10th count (and the post-capture rich push
                // carries the onset-time snapshot), so without this the record — and every
                // mirror — ended at the last multiple of ten, or at 1 for a short flood,
                // while this device showed the true ×n (the build-25 pair finding). One
                // final push seals the coalesced state; the supersede rule's equal-revision
                // higher-count arm is what lets an already-fetched mirror accept it.
                if let final = self?.sustainedEvent { self?.pushFactIfCloud(final) }
                self?.sustainedEvent = nil
                self?.lastFloodCapture = nil
                self?.lastFloodPersist = nil
            }
        }
    }

    private func respond(triggeredSensors: [SensorType], startDate: Date, session: Int,
                         sustained: Bool = false) async {
        // 1. Record the event IMMEDIATELY (metadata + traces), before touching the
        //    camera — so a tamper is always logged even if capture is slow or fails.
        var event = Event(
            startDate: startDate,
            endDate: Date(),
            triggeredSensors: triggeredSensors.sorted { $0.rawValue < $1.rawValue },
            motionTrace: monitors[.motion]?.recentTrace() ?? [],
            audioTrace: monitors[.audio]?.recentTrace() ?? [],
            visionTrace: monitors[.vision]?.recentTrace(),
            cloudSyncState: .pending,
            capturedOffline: !connectivity.isOnline,
            sustainedCount: sustained ? 1 : nil)
        eventStore.add(event)
        eventCount = eventStore.events.count
        // Captured during the owner's disarm flow (from the hold press-down through PIN
        // entry): remember it, so a successful PIN can retroactively attribute it to the
        // owner instead of leaving self-disarm spam (R-02).
        if inDisarmFlow { disarmEntryEventIDs.insert(event.id) }

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

        // 2. Capture evidence. Single-camera captures are bounded (see below) so
        //    they can't hang the pipeline. "Both" uses multi-cam when supported.
        var primary: Capture?
        var secondary: Capture?
        func tag(_ c: (source: EventStore.MediaSource, ext: String, duration: Double)?, _ cam: CameraChoice) -> Capture? {
            c.map { ($0.source, $0.ext, $0.duration, cam) }
        }
        if settings.isEnabled(.camera) {
            switch effectiveCameraPosition {
            case .front: primary = tag(await captureFrom(.front), .front)
            case .rear:  primary = tag(await captureFrom(.rear), .rear)
            case .auto:  let cam = resolveAutoCamera(); primary = tag(await captureFrom(cam), cam)
            case .both:
                if CameraController.supportsMultiCam {
                    (primary, secondary) = await captureBoth()
                } else {
                    primary = tag(await captureFrom(.front), .front)   // fallback: front only
                }
            }
        }

        // 3. Persist captured media (+ thumbnail) OFF the main actor, then attach
        //    the filename/camera/duration to the saved event. If the write fails,
        //    the event keeps its metadata + traces rather than referencing a file
        //    that isn't there.
        if let primary, let stored = await eventStore.store(primary.source, ext: primary.ext) {
            event.mediaFilename = stored.filename
            event.primaryCamera = primary.camera.rawValue
            event.thumbnailData = stored.thumbnail
            if primary.ext == "mov" { event.primaryDuration = primary.duration }
        }
        if let secondary, let stored = await eventStore.store(secondary.source, ext: secondary.ext) {
            event.secondaryMediaFilename = stored.filename
            event.secondaryCamera = secondary.camera.rawValue
            if secondary.ext == "mov" { event.secondaryDuration = secondary.duration }
        }
        // Trips that landed during this capture join the record (34-review M1) — the
        // flood coalescer's precedent: coalesce log spam, never evidence. Folded before the
        // final persist and the full cloud push, so both carry the complete sensor list.
        if !tripsDuringCapture.isEmpty {
            event.triggeredSensors = Self.foldedSensors(event.triggeredSensors,
                                                        adding: tripsDuringCapture)
            tripsDuringCapture.removeAll()
        }
        event.endDate = Date()   // now reflects when capture actually finished
        eventStore.update(event)
        // Re-read the stored copy: `update` preserves monotonic fields written while the
        // capture ran (owner attribution at disarm — sixth-review F2), and the upload below
        // must carry them, or the rich push regresses the cloud record to unattributed.
        let merged = eventStore.events.first { $0.id == event.id } ?? event
        // Flood onset: this becomes the coalescing anchor — subsequent flood trips
        // extend it instead of creating new events.
        if sustained { sustainedEvent = merged }

        // 4. Exfiltrate in the background — ALWAYS, even if the owner disarmed
        //    mid-capture (e.g. they grabbed the phone back from a tamperer). The
        //    evidence must reach iCloud regardless; the media is already on disk,
        //    so this doesn't depend on the (possibly shut-down) camera. Only the
        //    re-arm/alert below are gated on the session still being live.
        let ev = merged
        Task { await exfiltrate(ev, cloudAllowedOverride: sessionAllowed) }

        // If the user disarmed while we were capturing, stop here: don't re-arm or alert.
        guard session == armSession else { return }

        // 5. Re-arm the sensors NOW so the next tamper is caught immediately.
        reArm()

        // 5a. Return the camera to cold standby if the readiness policy says so
        //     (Battery saver, or Auto on battery) — this capture is the reason it was
        //     up. This is also the warm→cold handoff after an unplug trigger.
        standDownCameraIfNeeded()

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
                                    alertActive: alertActive, activeEntry: presentationSuppressed) {
            case .present: presentAlert()          // start fresh (not during a disarm)
            case .extend:  extendAlertWindow()     // keep a running alarm alive despite a screen touch
            case .none:    break
            }
        }
    }

    /// Background upload of a single event's evidence. Always completes (even if
    /// the user disarms meanwhile) — captured evidence should reach the cloud.
    /// `cloudAllowedOverride` carries the session's authorization as decided when the record
    /// was CREATED (34 review): these tasks run after their caller returns, and `disarm()`
    /// clears `armedPro` before they get to run — so reading `cloudAllowed` at execution
    /// time downgraded records spawned by a session that armed as Pro. Retry paths pass
    /// nothing and stay on the strict live entitlement, as before.
    private func exfiltrate(_ event: Event, cloudAllowedOverride: Bool? = nil) async {
        let allowed = cloudAllowedOverride ?? cloudAllowed
        // A monitoring state-change (armed/disarmed) never becomes a *meta* record: the
        // cross-device subscription fires a static "Tamper detected" alert on any pushed
        // meta record, which would be wrong and noisy for a routine arm. It goes to its own
        // unsubscribed record type instead (BACKLOG 8), so the audit trail survives an
        // attacker who knows the PIN and deletes the app — taking the local log with it —
        // while staying completely silent on the owner's other devices.
        if event.isStateChange {
            guard allowed else {
                eventStore.setSyncState(.localOnly, for: event.id)
                return
            }
            let pushed = await cloud.pushStateChange(event)
            eventStore.setSyncState(Self.stateChangeSyncState(pushed: pushed), for: event.id)
            // R3-2: a reset first seen on a STATE push must be acted on, not just detected —
            // this branch used to return before the handler, so an arm/disarm-only session
            // detected the reset and then ignored it: no requeue, cloud silently empty.
            handleEncryptedDataResetIfNeeded()
            return
        }
        // Cloud backup is Pro. On the free tier the evidence stays on-device — mark it
        // local-only (the default is `.pending`, which would otherwise read as "Syncing…").
        // `cloudAllowed` (not bare `armedPro`) so the non-session retry paths — crash
        // recovery, reconnect, event-log open — upload a Pro user's pending evidence that
        // was captured before this launch's first arm (P-01). Genuinely free users fall
        // through to `.localOnly`; `retryPendingSync`'s own `proActive` guard has already
        // turned lapsed users away before they reach here.
        guard allowed else {
            eventStore.setSyncState(.localOnly, for: event.id)
            return
        }
        let mediaURL = event.mediaFilename.map { eventStore.mediaDirectory.appendingPathComponent($0) }
        let secondaryURL = event.secondaryMediaFilename.map { eventStore.mediaDirectory.appendingPathComponent($0) }
        let outcome = await cloud.exfiltrate(event, fullMediaURL: mediaURL, secondaryMediaURL: secondaryURL)
        eventStore.setSyncState(outcome.syncState, for: event.id)
        handleEncryptedDataResetIfNeeded()
        if outcome.syncState == .synced { cloudPushRefused = false }
        // F3, refined by 32.R1: the trigger-time go-loud decision sees only network-path
        // reachability, so the OBSERVED failure escalates instead — but only when the failure
        // class is consistent with interference. iCloud refusing a record (full quota, auth,
        // schema, an encrypted-key reset) is an ANSWER: the server was reached, nothing is
        // jammed, and a siren would be a permanent false alarm in the owner's absence. A
        // refusal is surfaced on Home; only the network class may go loud. See ADR 0001.
        switch Self.pushFailureResponse(syncState: outcome.syncState,
                                        isStateChange: event.isStateChange,
                                        interference: outcome.metaFailureWasInterference,
                                        jammingResponse: settings.jammingResponse,
                                        hadConnectivityAtArm: hadConnectivityAtArm,
                                        online: connectivity.isOnline,
                                        watching: state == .armed || state == .triggered) {
        case .goLoud:
            Log.engine.error("Evidence push failed while the network path looks up — going loud")
            escalate(.blackout)
        case .surfaceRefusal:
            Log.engine.error("Evidence push was REFUSED by iCloud — keeping covert, surfacing it")
            cloudPushRefused = true
        case .stayQuiet:
            break
        }
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
    private func reExfiltrateOwnerAttributed(_ ids: Set<UUID>) {
        let updated = eventStore.events.filter { ids.contains($0.id) }
        for ev in updated { pushFactIfCloud(ev) }
    }

    /// Retries CloudKit upload for any events not yet synced. Called when the user
    /// opens the event log, so stuck/offline events catch up once iCloud is ready.
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
    func syncFromCloud(limit: Int = CloudExfiltrator.fetchPageSize) async -> Int {
        guard entitlements.proActive else { return 0 }
        let fetched = await cloud.fetchRecentEvents(limit: limit)
        guard !fetched.isEmpty else { return 0 }
        let added = eventStore.merge(fetched)
        if added > 0 { eventCount = eventStore.events.count }
        return added
    }

    /// Downloads an event's full-resolution capture(s) from iCloud into the local store
    /// (BACKLOG 34.B1) — the retrieval half of the Pro backup promise, Pro-gated like every
    /// cloud path. The store takes ownership exactly as it does for a fresh capture: UUID
    /// filename, evidence-grade protection, derived thumbnail. Returns true when at least
    /// one capture landed. Also recovers media the byte cap evicted locally — the cloud
    /// copy outlives the local eviction by design.
    func downloadFullEvidence(for id: UUID) async -> Bool {
        guard entitlements.proActive else { return false }
        guard let event = eventStore.events.first(where: { $0.id == id }) else { return false }
        guard let fetched = await cloud.fetchFullMedia(for: id, manifest: event.cloudMediaManifest),
              !fetched.isEmpty else { return false }
        var updated = event
        var landed = false
        for item in fetched {
            guard updated.mediaFilename == nil || updated.secondaryMediaFilename == nil else { break }
            guard let staged = await Self.stageDownloadedAsset(at: item.fileURL) else { continue }
            guard let stored = await eventStore.store(staged.media, ext: staged.ext) else { continue }
            if updated.mediaFilename == nil {
                updated.mediaFilename = stored.filename
                if updated.primaryCamera == nil { updated.primaryCamera = item.camera }
                if updated.thumbnailData == nil { updated.thumbnailData = stored.thumbnail }
            } else {
                updated.secondaryMediaFilename = stored.filename
                if updated.secondaryCamera == nil { updated.secondaryCamera = item.camera }
            }
            landed = true
        }
        if landed { eventStore.update(updated) }
        return landed
    }

    /// Classifies a downloaded asset from its leading bytes and stages it for the store:
    /// stills as Data, movies copied to a temp file the store may consume by move (CloudKit
    /// owns the asset's own cache file; it is never moved directly). Off the main actor —
    /// a clip can be large.
    /// Byte caps for downloaded evidence (sixth review, F6): both far above anything this
    /// app produces (stills are single-digit MB; a 120 s clip is a few hundred), but bounded,
    /// so a corrupt or hand-crafted record can't drive memory or disk pressure.
    nonisolated static let maxDownloadedStillBytes = 25 * 1024 * 1024
    nonisolated static let maxDownloadedMovieBytes = 600 * 1024 * 1024

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
    private func handleEncryptedDataResetIfNeeded() {
        guard cloud.encryptedDataResetDetected, !encryptedResetHandled else { return }
        encryptedResetHandled = true
        cloud.acknowledgeEncryptedDataReset()
        let requeued = eventStore.requeueAllForReupload()
        cloudResetNotice = "iCloud's protected data was reset, which cleared the cloud copies. This device is re-uploading \(requeued) event(s)."
        Log.engine.warning("Encrypted-data reset detected; requeued \(requeued, privacy: .public) event(s) for re-upload")
        Task { await retryPendingSync() }
    }

    // MARK: - Cloud retention (32.R2)

    private static let cloudRetentionLastRunKey = "com.malinois.cloudRetention.lastRun"

    /// Pure (unit-tested): the automatic purge runs at most about daily.
    nonisolated static func autoPurgeDue(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= 20 * 3600
    }

    /// Enforces the automatic cloud-retention policy (32.R2), quietly and at most daily.
    /// Only the auto modes delete anything here — Manual deletes solely through the owner's
    /// explicit Settings action, and Keep-forever never deletes at all. Pro-gated like every
    /// cloud path; the 30-day protection floor is enforced inside `purgeCutoff`.
    func enforceCloudRetentionIfDue() async {
        guard entitlements.proActive, let months = settings.cloudRetention.autoMonths else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.cloudRetentionLastRunKey) as? Date
        guard Self.autoPurgeDue(lastRun: last, now: Date()) else { return }
        defaults.set(Date(), forKey: Self.cloudRetentionLastRunKey)
        _ = await cloud.purgeFullMedia(
            olderThan: CloudExfiltrator.purgeCutoff(monthsOld: months, now: Date()))
    }

    /// Single-flight guard for `retryPendingSync` (1.2 coordinator): foreground, reconnect
    /// and log-open can all fire it within a second of each other, and overlapping sweeps
    /// re-uploaded the same pending events. A caller arriving mid-sweep is served by the
    /// running one; an event added mid-sweep is caught by the next trigger's own push or
    /// the next sweep.
    private var retryingSync = false

    func retryPendingSync() async {
        guard entitlements.proActive else { return }   // cloud backup is Pro
        guard !retryingSync else { return }
        retryingSync = true
        defer { retryingSync = false }
        await cloud.refreshAccountState()
        guard cloud.accountState.isReady else { return }
        // Bounded concurrency: a day's worth of offline events, each doing up to a
        // few retries, would take tens of seconds run strictly serially (and hang
        // pull-to-refresh). Run a few at a time so badges clear quickly without
        // flooding CloudKit.
        let pending = eventStore.events.filter { $0.cloudSyncState != .synced }
        let maxConcurrent = 3
        await withTaskGroup(of: Void.self) { group in
            var next = pending.makeIterator()
            for _ in 0..<maxConcurrent {
                if let event = next.next() { group.addTask { await self.exfiltrate(event) } }
            }
            while await group.next() != nil {
                if let event = next.next() { group.addTask { await self.exfiltrate(event) } }
            }
        }
        // R3-2 backstop: a sweep whose only traffic was state records (their branch consumes
        // now, but belt-and-braces) — and any flag raised between checks — is acted on at
        // the tail, so no process ends holding a detected-but-ignored reset.
        handleEncryptedDataResetIfNeeded()
    }

    private func reArm() {
        // Post-TRIGGER re-arm: clear each latch and let motion adopt the new resting
        // pose (a device left in a new spot shouldn't trip forever), without a
        // stop()/start() gap. The refractory sweep uses plain rearm() instead — see F-15.
        for (_, m) in monitors where m.isEnabled { m.rearmAndRebaseline() }
        recentTrips.removeAll()
        latchedSensors.removeAll()
        isHandlingTrigger = false
        state = .armed
    }

    // MARK: - Disarm (PIN-gated by caller)

    /// The UI must verify the PIN before calling this.
    func disarm() {
        armSession &+= 1   // invalidate any in-flight trigger response
        disarmEntryTimer?.invalidate(); disarmEntryTimer = nil
        // A correct PIN means the owner: anything captured while the pad was open was
        // their own handling, so attribute it rather than spamming the log with it.
        if !disarmEntryEventIDs.isEmpty {
            eventStore.markOwnerAttributed(disarmEntryEventIDs)
            reExfiltrateOwnerAttributed(disarmEntryEventIDs)   // update the cloud copy too (R-06)
            disarmEntryEventIDs.removeAll()
        }
        disarmCandidateSince = nil
        disarmEntryActive = false
        lastDisarmKeypress = nil
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
        // Remember the Guided Access state the owner is walking away from, so the next arm
        // can tell them if it changed in between (BACKLOG 24b). Recorded at disarm rather
        // than at arm because the disarm is the last moment the owner is demonstrably present.
        UserDefaults.standard.set(UIAccessibility.isGuidedAccessEnabled,
                                  forKey: Self.guidedAccessAtDisarmKey)
        armWasAutoRecovered = false
        clearGuidedAccessLift()   // a lift covers one arm; the session it authorized is over
        isCapturingUntilClear = false
        alertActive = false
        alertDismissTimer?.invalidate(); alertDismissTimer = nil
        noteSirenExhaustionIfAny()
        siren.stop()
        // Safe to just clear the flag: the monitors.stop() loop below stops the
        // audio monitor regardless, so no explicit resume is needed here.
        audioPausedForSiren = false
        audioPausedForCapture = false
        graceTimer?.invalidate(); graceTimer = nil; graceEndsAt = nil
        calibrationTimer?.invalidate(); calibrationTimer = nil
        refractoryTimer?.invalidate(); refractoryTimer = nil
        blackoutTimer?.invalidate(); blackoutTimer = nil
        sustainedClearTimer?.invalidate(); sustainedClearTimer = nil
        cameraStandbyTimer?.invalidate(); cameraStandbyTimer = nil
        escalation = nil
        blackoutEscalated = false
        sustainedEvent = nil
        lastFloodCapture = nil
        lastFloodPersist = nil
        sensorTripTimes.removeAll()
        recentTriggerTimes.removeAll()
        showingCalibrationReview = false
        for (_, m) in monitors { m.stop() }
        camera.shutDown()
        releaseCovertScreen()
        if let armedSince {
            let end = Date()
            lastArmedDuration = end.timeIntervalSince(armedSince)
            lastArmedInterval = (start: armedSince, end: end)
            // Only log a "disarmed" record when a watch was actually running (armedSince set),
            // so cancelling the arming flow before it goes live doesn't create a spurious
            // entry. This is the auditable proof of exactly when protection stopped.
            logStateChange("disarmed", sessionCloudAllowed: sessionCloudAllowed)
        }
        armedSince = nil
        recentTrips.removeAll()
        latchedSensors.removeAll()
        tripsDuringCapture.removeAll()
        isHandlingTrigger = false
        state = .disarmed
    }

    /// Abort the arming flow (before Armed) without needing the PIN.
    func cancelArming() {
        guard state == .guidedAccessCheck || state == .arming || state == .calibrating else { return }
        // A crash-recovery re-arm is NOT user-initiated: cancelling it must require the
        // PIN, or a thief who caused the crash just taps "Cancel" to undo the auto
        // re-protection (R-04). The UI routes the cancel through PINEntryView → disarm().
        guard !armWasAutoRecovered else { return }
        disarm()
    }
}
