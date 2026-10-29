//
//  AppSettings.swift
//  Malinois
//
//  User-facing configuration, persisted to UserDefaults. The MonitoringEngine
//  reads these when arming; sensors read their own slice at start().
//

import Foundation
import Combine
import AVFoundation
import UIKit

/// What the camera captures on a trigger.
enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case photo
    case clip3 = "clip"        // legacy raw value kept so old settings still load
    case clip5
    case untilClear

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .photo:      return "Single photo (low data)"
        case .clip3:      return "3-second clip"
        case .clip5:      return "5-second clip"
        case .untilClear: return "Until clear (up to 2 min)"
        }
    }

    var isClip: Bool { self != .photo }

    /// Fixed clip length in seconds, or nil for `.untilClear` (dynamic).
    var fixedDuration: Double? {
        switch self {
        case .clip3: return 3
        case .clip5: return 5
        default:     return nil
        }
    }
}

/// Which camera captures the evidence.
/// - front: sees whoever leans over a face-up phone; lit by the screen flash.
/// - rear:  for a face-down phone (screen hidden against the table) — the rear
///          camera then faces up at the room, and its LED flash provides light.
enum CameraChoice: String, Codable, CaseIterable, Identifiable {
    case front
    case rear
    case auto
    case both

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .front: return "Front (face-up)"
        case .rear:  return "Rear (face-down)"
        case .auto:  return "Auto (Rear when face down)"
        case .both:  return "Both (multi-cam)"
        }
    }

    /// Rear and Auto are for a phone that lies face down with the Vision tripwire watching the
    /// room (owner ruling 2026-09-05, ADR 0012); without Vision the front lens is the useful
    /// one, and these two are not offered.
    var needsVision: Bool { self == .rear || self == .auto }

    /// The caption under the Camera picker for Rear and Auto (item 74 line 2). Both's depends
    /// on the device and the capture mode, so the Settings screen words it; Front has none.
    var pickerCaption: String? {
        switch self {
        case .rear:
            return "Rear only, with one exception: a trigger that includes a screen touch captures from the front camera, because a screen being touched is facing whoever touches it. A touch after the capture has begun adds no front photo; Both uses the front and rear cameras at once."
        case .auto:
            return "Rear while the phone lies face down, front in every other position, decided at each event. Both uses the front and rear cameras at once, so the screen side is photographed too."
        case .front, .both:
            return nil
        }
    }

    /// The Vision tripwire's hint in Settings, shown while it is on (ADR 0012; item 74 line 2).
    static let faceDownVisionHint = "For a phone lying face down, set Capture → Camera to Auto or Rear so it watches the room, or to Both to photograph the screen side too."
}

/// How the device reacts when a tamper is detected (after capturing evidence).
enum ResponseMode: String, Codable, CaseIterable, Identifiable {
    case alert    // silent on-screen warning message (default)
    case stealth  // covert — stay black, no visible/audible response
    case siren    // loud alarm + the on-screen warning

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .alert:   return "Alert message (silent)"
        case .stealth: return "Stealth (covert)"
        case .siren:   return "Siren (loud)"
        }
    }
    var showsMessage: Bool { self != .stealth }
}

/// When to fire the capture flash / LED so evidence isn't black in low light.
enum IlluminationMode: String, Codable, CaseIterable, Identifiable {
    case off       // never — full stealth
    case auto      // only when the camera reports a dim scene
    case on        // always

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off:  return "Off"
        case .auto: return "Auto (dim light)"
        case .on:   return "Always"
        }
    }
}

/// How ready the camera is kept while armed — a battery-vs-latency trade. The warm
/// `AVCaptureSession` is the single largest continuous draw of an armed device, so
/// cold-starting it on a trigger is the main battery lever. The tamper *fact* still
/// exfiltrates immediately in every mode (it's pushed before capture); only the
/// photo/clip is delayed (~1–2s) when the camera has to spin up.
enum CameraReadiness: String, Codable, CaseIterable, Identifiable {
    case instant       // always warm — fastest capture, highest drain
    case auto          // warm while charging, cold-start on battery
    case batterySaver = "battery"  // always cold-start on trigger — biggest savings

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .instant:      return "Instant"
        case .auto:         return "Auto"
        case .batterySaver: return "Battery saver"
        }
    }
    var summary: String {
        switch self {
        case .instant:
            return "Camera stays ready for instant capture. Highest battery use - best when charging."
        case .auto:
            return "Instant while charging; on battery the camera starts on a trigger (~1–2s to the first shot). Recommended."
        case .batterySaver:
            return "Camera always starts on a trigger (~1–2s to the first shot). Lowest battery use, and no camera indicator until it fires."
        }
    }
    /// The pure decision (unit-tested): should the camera be kept warm right now,
    /// given whether the device is currently on external power?
    func keepsCameraWarm(charging: Bool) -> Bool {
        switch self {
        case .instant:      return true
        case .batterySaver: return false
        case .auto:         return charging
        }
    }
}

/// What happens to **full-resolution** photos and clips in iCloud over time. Event facts,
/// thumbnails, and arm/disarm audit records are NEVER deleted in any mode — this governs
/// only the heavy media, which is what fills the owner's quota. Nothing newer than the
/// 30-day protection floor can be deleted in any mode, by anyone (32.R2).
enum CloudRetention: String, Codable, CaseIterable, Identifiable {
    case forever          // the app never deletes a cloud record (the pre-1.2 behaviour)
    case manual           // deletion only via the owner's explicit "free up space" action
    case months1, months3, months6, months12   // auto-delete full media older than this

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .forever:  return "Keep forever"
        case .manual:   return "Manual only"
        case .months1:  return "Auto-delete after 1 month"
        case .months3:  return "Auto-delete after 3 months"
        case .months6:  return "Auto-delete after 6 months"
        case .months12: return "Auto-delete after 12 months"
        }
    }
    /// The auto policy's age, in months — nil for the two non-automatic modes.
    var autoMonths: Int? {
        switch self {
        case .forever, .manual: return nil
        case .months1: return 1
        case .months3: return 3
        case .months6: return 6
        case .months12: return 12
        }
    }
}

final class AppSettings: ObservableObject, Codable {

    /// Which tripwires are active. Touch is always among them (item 83, ADR 0015): whatever set
    /// is assigned, the one that lands here holds Touch — a set without it is completed at once.
    @Published var enabledSensors: Set<SensorType> {
        didSet {
            if !enabledSensors.contains(.touch) { enabledSensors = AppSettings.withTouch(enabledSensors) }
        }
    }
    // Per-sensor sensitivity.
    @Published var sensitivities: [SensorType: Sensitivity]

    @Published var triggerMode: TriggerMode
    @Published var gracePeriodSeconds: Int
    @Published var captureMode: CaptureMode
    @Published var cameraPosition: CameraChoice

    /// Battery-vs-latency policy for keeping the camera warm while armed.
    @Published var cameraReadiness: CameraReadiness

    /// Optional owner-set label for this device, carried in evidence metadata and the
    /// cross-device alert. `UIDevice.name` returns a generic "iPhone" on modern iOS, so
    /// this is how "which of my devices tripped?" gets a real answer (F-24). Empty = fall
    /// back to the system device name.
    @Published var deviceLabel: String

    /// When to light a capture (screen flash for front, LED for rear) so evidence
    /// isn't black. `.auto` only fires when the camera reports a dim scene — the
    /// least visible option that still yields usable evidence.
    @Published var illumination: IlluminationMode

    /// Whether a clip session attaches the microphone (owner ruling, 2026-09-05; item 69):
    /// off by default, so a new install's clips are video only until the owner turns this on,
    /// which is also when iOS asks for microphone access. Installs from before the setting
    /// existed keep the audio they had: the migration reads the permission they already gave.
    @Published var clipAudio: Bool
    nonisolated static func migratedClipAudio(stored: Bool?, micGranted: Bool) -> Bool {
        stored ?? micGranted
    }

    /// Push an alert to the user's OTHER devices signed into the same iCloud
    /// account the moment a tamper event is recorded (via a CloudKit subscription).
    @Published var notifyOtherDevices: Bool

    /// Upload this phone's events, photos, clips, status entries and heartbeats to the owner's
    /// private iCloud (item 115). On by default. Off needs device authentication (Settings); an
    /// event recorded while it is off stays on this phone for good (`Event.keptLocal`).
    @Published var cloudBackup: Bool

    /// Retention policy for full-resolution media in iCloud (32.R2). Defaults to
    /// auto-delete after 12 months — the least destructive automatic value.
    @Published var cloudRetention: CloudRetention

    /// "Go loud" if evidence can't be exfiltrated — a total connectivity blackout
    /// on a stationary armed device that had a working path at arm is a strong
    /// jamming signal, so the covert strategy is abandoned for a siren + warning.
    @Published var jammingResponse: Bool

    /// How the device reacts on a trigger, and the message shown for alert/siren.
    @Published var responseMode: ResponseMode
    @Published var alertMessage: String

    /// Start the siren quiet and rise to full over ~20 s, rather than hitting maximum
    /// immediately. Gives the owner room to disarm their own device without a jolt, while
    /// anyone who doesn't disarm still gets the full alarm. Off = instant maximum volume.
    @Published var sirenRampUp: Bool

    /// Refuse to arm unless Guided Access is on. Guided Access is what makes the covert
    /// screen a real defense — it blocks app-switching and the soft power-off, routes calls
    /// to voicemail, and disables Siri — so without it a snoop can simply swipe the app away
    /// (and, found on device in item 53, even a force-restart's side-button press backgrounds
    /// the session first). **On by default since 1.3** (owner ruling, 2026-09-02): it shipped
    /// off through 1.2 so a first run could arm without configuring an iOS accessibility
    /// feature first, and the one-arm lift on the arming screen — logged and pushed as an
    /// audit record — now gives that first run the same convenience without the silent
    /// weakness. Turning it off here is the explicit, permanent choice; an App Store reviewer
    /// uses the lift (review notes say so).
    @Published var requireGuidedAccess: Bool

    /// Item 61's default flip reaches EXISTING installs too (owner ruling 2026-09-04, item 65
    /// finding 6): 1.2 always stored the switch, off, so a new default alone never touched
    /// them. A saved blob without this marker is migrated once on load — the switch turns on,
    /// and the marker is written with the next save — and from then on the stored value is the
    /// owner's own choice. Fresh installs start migrated.
    var guidedAccessDefaultMigration: Int
    nonisolated static let guidedAccessMigrationVersion = 1

    /// Pure (unit-tested; item 65, finding 6). What a loaded blob's Require Guided Access reads
    /// as: a blob from before the migration marker turns the switch ON regardless of what 1.2
    /// stored (nobody chose that off); a migrated blob keeps its stored value; no value at all
    /// means the 1.3 default, on.
    nonisolated static func migratedRequireGuidedAccess(stored: Bool?, migration: Int) -> Bool {
        migration < guidedAccessMigrationVersion ? true : (stored ?? true)
    }

    /// Pure (unit-tested). The camera choice that is allowed with the Vision tripwire in its
    /// current state (ADR 0012): Rear and Auto only while Vision is on; Front otherwise. Applied
    /// when the settings load, when Vision is switched off, and defensively at arm.
    nonisolated static func cameraChoice(_ choice: CameraChoice, visionOn: Bool) -> CameraChoice {
        (visionOn || !choice.needsVision) ? choice : .front
    }

    /// Pure (unit-tested; item 83, ADR 0015): the Touch tripwire cannot be switched off, so any
    /// set of tripwires the settings hold reads with Touch in it. Applied in three places (ADR
    /// 0012's pattern): whenever `enabledSensors` changes, when a save is loaded — so an install
    /// that switched Touch off before this rule gets it back once — and at arm (`effectiveSensors`).
    nonisolated static func withTouch(_ sensors: Set<SensorType>) -> Set<SensorType> {
        sensors.union([.touch])
    }

    /// Randomize the disarm/gate PIN pad's digit positions on each presentation, so an
    /// observer can't learn the PIN from finger positions (shoulder-surf / smudge / thermal
    /// residue). Off by default — it trades muscle-memory speed for observation resistance.
    @Published var scramblePINPad: Bool

    /// Face ID / Touch ID may open the PIN-gated READ surfaces — the Event Log, Settings,
    /// and Test Sensors (item 30, option A; owner's call 2026-08-30). Viewing is a
    /// convenience; stopping the watch is the security boundary — disarm, stop-re-arming,
    /// and the change-PIN gate never accept a face, so "can't be disarmed without your PIN"
    /// stays true word for word. Off by default: offering two doors makes a surface only as
    /// strong as the weaker one, so the owner opts into the trade.
    @Published var biometricUnlock: Bool

    // "Recording" is named explicitly (2.5.14 — indication owed "to all parties"): the person
    // handling the device is told a recording exists, not just that access was noticed.
    static let defaultAlertMessage = "Recording in progress. This device is protected. Unauthorized access has been logged."

    /// Auto-persist: any change is saved (debounced ~400 ms), so a kill while a settings
    /// screen is open loses at most the last moments of edits — not the session's worth the
    /// old comment implied. The Done button and sheet dismissal also save, so the debounce
    /// window is the only exposure (34 review).
    private var autosave: AnyCancellable?

    init() {
        // Audio is off by default (it's the most false-positive-prone tripwire).
        enabledSensors = [.motion, .power, .proximity, .camera, .touch]
        sensitivities = Dictionary(uniqueKeysWithValues:
            SensorType.allCases.map { ($0, .medium) })
        triggerMode = .any
        gracePeriodSeconds = 15
        captureMode = .clip3   // video default: 90 frames beat 1 for catching a face
        // Front (owner ruling 2026-09-05, ADR 0012): the lens facing whoever handles the phone.
        // Rear and Auto exist for the Vision tripwire's watching-the-room setup and are offered
        // only while Vision is on. Auto was the default from 1.2 to 1.3 (40) so a face-down
        // phone did not photograph the desk; with the default 3-second clip the front lens
        // sweeps up to the face as the phone is flipped, so Front is not worse in the common case.
        cameraPosition = .front
        cameraReadiness = .auto   // instant while charging, cold-start on battery
        deviceLabel = ""
        illumination = .auto
        clipAudio = false   // video only until the owner adds sound (item 69)
        notifyOtherDevices = true
        cloudBackup = true   // item 115
        cloudRetention = .months12
        jammingResponse = true
        responseMode = .alert
        alertMessage = AppSettings.defaultAlertMessage
        requireGuidedAccess = true
        guidedAccessDefaultMigration = AppSettings.guidedAccessMigrationVersion
        sirenRampUp = true
        scramblePINPad = false
        biometricUnlock = false
        setupAutosave()
    }

    /// objectWillChange fires just before a mutation; the debounce lets the new
    /// value settle before we encode, and coalesces rapid edits (e.g. typing).
    private func setupAutosave() {
        autosave = objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
    }

    func sensitivity(for sensor: SensorType) -> Sensitivity {
        sensitivities[sensor] ?? .medium
    }

    func isEnabled(_ sensor: SensorType) -> Bool {
        enabledSensors.contains(sensor)
    }

    /// Whether at least one *tripwire* is enabled. With none, arming is inert — nothing
    /// can ever fire — so the UI warns before letting the owner arm into a false sense
    /// of security (F-23). The camera is a capture path, not a tripwire, so it doesn't count.
    /// Since item 83 Touch is always on, so this is always true; the warning stays as a guard.
    var hasActiveTripwire: Bool {
        SensorType.tripwires.contains { enabledSensors.contains($0) }
    }

    // MARK: - Codable (Published needs manual coding)

    enum CodingKeys: String, CodingKey {
        case enabledSensors, sensitivities, triggerMode
        case gracePeriodSeconds, captureMode, cameraPosition, cameraReadiness
        case deviceLabel
        case illumination, notifyOtherDevices, cloudRetention, jammingResponse, clipAudio, cloudBackup
        case responseMode, alertMessage, scramblePINPad, requireGuidedAccess, sirenRampUp
        case biometricUnlock, guidedAccessDefaultMigration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sensors = try c.decode(Set<SensorType>.self, forKey: .enabledSensors)
        // A save from a build that let Touch be switched off loads with it on (item 83). The
        // assignment here is initialization, so the property observer does not run: apply it.
        enabledSensors = AppSettings.withTouch(sensors)
        sensitivities = try c.decode([SensorType: Sensitivity].self, forKey: .sensitivities)
        // Lenient on purpose. `decodeIfPresent` is NOT enough here: a key that's *present*
        // with a raw value this build no longer knows (e.g. the removed "motionCorroborated")
        // still throws, which would fail the whole AppSettings decode — and `load()`'s `try?`
        // would then silently reset EVERY setting, not just this one. `try?` absorbs both a
        // missing key and a retired value, falling back to the only remaining mode.
        triggerMode = (try? c.decode(TriggerMode.self, forKey: .triggerMode)) ?? .any
        gracePeriodSeconds = try c.decode(Int.self, forKey: .gracePeriodSeconds)
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .photo
        // Defaults for settings saved before these options existed.
        // Front is the default (ADR 0012); a stored Rear/Auto from before the gate is kept only
        // while the Vision tripwire is on, because that is the only setup they serve.
        cameraPosition = AppSettings.cameraChoice(
            try c.decodeIfPresent(CameraChoice.self, forKey: .cameraPosition) ?? .front,
            visionOn: sensors.contains(.vision))
        cameraReadiness = try c.decodeIfPresent(CameraReadiness.self, forKey: .cameraReadiness) ?? .auto
        deviceLabel = try c.decodeIfPresent(String.self, forKey: .deviceLabel) ?? ""
        // Default Auto when unset (also for anyone upgrading from the old bool).
        illumination = try c.decodeIfPresent(IlluminationMode.self, forKey: .illumination) ?? .auto
        clipAudio = AppSettings.migratedClipAudio(
            stored: try c.decodeIfPresent(Bool.self, forKey: .clipAudio),
            micGranted: AVAudioApplication.shared.recordPermission == .granted)
        notifyOtherDevices = try c.decodeIfPresent(Bool.self, forKey: .notifyOtherDevices) ?? true
        cloudBackup = try c.decodeIfPresent(Bool.self, forKey: .cloudBackup) ?? true   // item 115; older settings keep uploading
        // `try?`, like triggerMode: a future build retiring a case must not reset every setting.
        cloudRetention = (try? c.decodeIfPresent(CloudRetention.self, forKey: .cloudRetention)) ?? .months12
        jammingResponse = try c.decodeIfPresent(Bool.self, forKey: .jammingResponse) ?? true
        responseMode = try c.decodeIfPresent(ResponseMode.self, forKey: .responseMode) ?? .alert
        alertMessage = try c.decodeIfPresent(String.self, forKey: .alertMessage) ?? AppSettings.defaultAlertMessage
        scramblePINPad = try c.decodeIfPresent(Bool.self, forKey: .scramblePINPad) ?? false
        biometricUnlock = try c.decodeIfPresent(Bool.self, forKey: .biometricUnlock) ?? false
        let storedRequirement = try c.decodeIfPresent(Bool.self, forKey: .requireGuidedAccess)
        let migration = try c.decodeIfPresent(Int.self, forKey: .guidedAccessDefaultMigration) ?? 0
        requireGuidedAccess = AppSettings.migratedRequireGuidedAccess(stored: storedRequirement, migration: migration)
        guidedAccessDefaultMigration = AppSettings.guidedAccessMigrationVersion
        sirenRampUp = try c.decodeIfPresent(Bool.self, forKey: .sirenRampUp) ?? true
        setupAutosave()   // begin after decode so loading doesn't trigger a save
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledSensors, forKey: .enabledSensors)
        try c.encode(sensitivities, forKey: .sensitivities)
        try c.encode(triggerMode, forKey: .triggerMode)
        try c.encode(gracePeriodSeconds, forKey: .gracePeriodSeconds)
        try c.encode(captureMode, forKey: .captureMode)
        try c.encode(cameraPosition, forKey: .cameraPosition)
        try c.encode(cameraReadiness, forKey: .cameraReadiness)
        try c.encode(deviceLabel, forKey: .deviceLabel)
        try c.encode(illumination, forKey: .illumination)
        try c.encode(clipAudio, forKey: .clipAudio)
        try c.encode(notifyOtherDevices, forKey: .notifyOtherDevices)
        try c.encode(cloudBackup, forKey: .cloudBackup)
        try c.encode(cloudRetention, forKey: .cloudRetention)
        try c.encode(jammingResponse, forKey: .jammingResponse)
        try c.encode(responseMode, forKey: .responseMode)
        try c.encode(alertMessage, forKey: .alertMessage)
        try c.encode(scramblePINPad, forKey: .scramblePINPad)
        try c.encode(biometricUnlock, forKey: .biometricUnlock)
        try c.encode(requireGuidedAccess, forKey: .requireGuidedAccess)
        try c.encode(guidedAccessDefaultMigration, forKey: .guidedAccessDefaultMigration)
        try c.encode(sirenRampUp, forKey: .sirenRampUp)
    }

    // MARK: - The settings guard (item 152's lead 3, ADR 0055)

    /// What the canary file says about the preferences store (ADR 0055): absent, readable, or there but unreadable.
    enum CanaryState { case missing, readable, unreadable }

    /// What the launch found: nothing stored (a fresh install), the stored settings, or a store sealed until the first
    /// unlock after a restart, which reads as nothing stored.
    enum StoreReading: Equatable { case fresh, sealed, stored(Data) }

    /// Pure (unit-tested): the canary tells a sealed store from a fresh install. The canary is written after every
    /// launch that read the settings, with first-unlock protection, so it exists on every install that has launched
    /// unlocked: there but unreadable, the keys are not available yet, and the store's empty answer means nothing.
    /// Missing (a fresh install, or an install from before the canary) or readable, the store's answer stands.
    nonisolated static func storeReading(canary: CanaryState, stored: Data?) -> StoreReading {
        if canary == .unreadable { return .sealed }
        if let stored { return .stored(stored) }
        return .fresh
    }

    /// True while the stored settings could not be read yet: a launch before the first unlock after a restart (a
    /// silent push, iOS's prewarming), when the preferences store reads as empty (ADR 0055). The values in memory are
    /// the defaults, not the owner's choices, so until the unlock nothing saves them (`save`), the launch seeds and
    /// the protection baseline wait (`whenResolved`), the retention pass does not run, and uploads wait without
    /// marking anything kept-local (`cloudBackupKnownOff`, `cloudBackupKnownOn`). Cleared by `resolveIfReadable`.
    @Published private(set) var awaitingUnlock = false

    /// Work owed once the settings are resolved (`whenResolved`), run in order at the unlock.
    private var deferredWork: [@MainActor (Bool) -> Void] = []
    /// The unlock notice and the app becoming active, watched while the store is sealed.
    private var unlockWatch: AnyCancellable?
    /// Whether the device's protected data can be read; UIKit's answer unless a test injects one. Asked only when the
    /// canary still cannot be read at a notice: true then means the canary is broken, not sealed.
    private var protectedDataAvailable: @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }

    /// Runs `work` once the settings are resolved: now when they are, else at the unlock; `waited` says which.
    @MainActor func whenResolved(_ work: @escaping @MainActor (_ waited: Bool) -> Void) {
        if awaitingUnlock { deferredWork.append(work) } else { work(false) }
    }

    /// Marks a launch's settings as waiting for the unlock, and watches for the unlock notice and the app becoming
    /// active (the two signals the event log waits for, ADR 0016).
    @MainActor private func waitForUnlock() {
        awaitingUnlock = true
        unlockWatch = Publishers.Merge(
            NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification),
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resolveIfReadable() }
    }

    /// Tries the deferred load again: at the unlock notice, or when the app becomes active. A canary that reads now
    /// ends the wait: the stored settings load into this object (or a damaged store resets, as at launch), the flag
    /// clears, the canary is written again and the deferred work runs. One still unreadable keeps the wait, unless
    /// UIKit says the phone is unlocked: then it is broken, not sealed, and is replaced (ADR 0016's rule for the
    /// log, mirrored).
    @MainActor func resolveIfReadable() {
        guard awaitingUnlock else { return }
        var canary = Self.canaryState()
        if canary == .unreadable, protectedDataAvailable() {
            Log.store.error("The settings canary cannot be read on an unlocked phone; replacing it")
            try? FileManager.default.removeItem(at: Self.canaryURL)
            canary = .missing
        }
        let loaded: AppSettings
        switch Self.storeReading(canary: canary, stored: UserDefaults.standard.data(forKey: Self.storeKey)) {
        case .sealed: return   // still before the unlock: the next notice tries again
        case .fresh: loaded = AppSettings()
        case .stored(let data): loaded = Self.decodeOrReset(data)
        }
        adopt(loaded)
        awaitingUnlock = false
        unlockWatch = nil
        Self.finishLoad()
        let work = deferredWork
        deferredWork = []
        for item in work { item(true) }
        Log.store.info("Settings loaded at the unlock")
    }

    /// Takes every stored value from `loaded` into this object, the one the app shares: the deferred load's end.
    private func adopt(_ loaded: AppSettings) {
        wasResetAtLoad = loaded.wasResetAtLoad   // a store reset at the unlock is a reset too (codex-10)
        enabledSensors = loaded.enabledSensors
        sensitivities = loaded.sensitivities
        triggerMode = loaded.triggerMode
        gracePeriodSeconds = loaded.gracePeriodSeconds
        captureMode = loaded.captureMode
        cameraPosition = loaded.cameraPosition
        cameraReadiness = loaded.cameraReadiness
        deviceLabel = loaded.deviceLabel
        illumination = loaded.illumination
        clipAudio = loaded.clipAudio
        notifyOtherDevices = loaded.notifyOtherDevices
        cloudBackup = loaded.cloudBackup
        cloudRetention = loaded.cloudRetention
        jammingResponse = loaded.jammingResponse
        responseMode = loaded.responseMode
        alertMessage = loaded.alertMessage
        scramblePINPad = loaded.scramblePINPad
        biometricUnlock = loaded.biometricUnlock
        requireGuidedAccess = loaded.requireGuidedAccess
        guidedAccessDefaultMigration = loaded.guidedAccessDefaultMigration
        sirenRampUp = loaded.sirenRampUp
    }

    /// Whether iCloud backup is known to be off: the switch read off from the stored settings (ADR 0047). False while
    /// the settings wait for the unlock: an event recorded then is neither marked kept-local nor held to no account
    /// by the switch, since the owner may have backup on (ADR 0055).
    var cloudBackupKnownOff: Bool { !awaitingUnlock && !cloudBackup }
    /// Whether iCloud backup is known to be on. False while the settings wait for the unlock: no heartbeat goes out
    /// on the strength of the default (ADR 0055).
    var cloudBackupKnownOn: Bool { !awaitingUnlock && cloudBackup }

    /// Where the canary lives: Application Support, this installation only.
    nonisolated static var canaryURL: URL {
        #if DEBUG
        if let override = canaryURLOverrideForTesting { return override }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SettingsGuard/canary")
    }

    #if DEBUG
    /// A test's own canary file.
    nonisolated(unsafe) static var canaryURLOverrideForTesting: URL?
    /// A test's answer to "is protected data available", in place of UIKit's.
    func useProtectedDataAnswerForTesting(_ answer: @escaping @MainActor () -> Bool) { protectedDataAvailable = answer }
    #endif

    /// The canary as it stands: missing, readable, or there but unreadable (a metadata check, then a read: a file
    /// with first-unlock protection exists before the unlock but its bytes cannot be read).
    nonisolated static func canaryState() -> CanaryState {
        let url = canaryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return (try? Data(contentsOf: url)) == nil ? .unreadable : .readable
    }

    /// Writes the canary after a launch that read the settings: a file with first-unlock protection, so a launch
    /// before the unlock finds it there and unreadable. A write that fails is logged; the next launch tries again,
    /// and a launch before the unlock reads as a fresh install meanwhile, as before 1.8.1.
    nonisolated static func writeCanary() {
        let url = canaryURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try Data("1".utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.store.error("The settings canary could not be written: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
        }
    }

    // MARK: - Persistence

    private static let storeKey = "com.malinois.settings"

    func save() {
        guard !awaitingUnlock else { return }   // the defaults are not the owner's choices (ADR 0055)
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// Set when stored settings existed but could not be decoded, so the app is running on
    /// defaults the owner never chose. Surfaced rather than silently accepted: the defaults
    /// include PIN-pad scrambling **off** and the Sound and Vision tripwires **off** (Guided
    /// Access enforcement is on by default since 1.3), so a silent reset can quietly reduce protection — the one thing
    /// this app's settings must never do without saying so. Written only by the load, at launch
    /// before any screen reads it, or at the unlock a sealed store waits for (ADR 0055; item 97: Swift 6 asks for the
    /// promise in words).
    nonisolated(unsafe) static private(set) var loadWasReset = false

    /// Whether these settings are the defaults a damaged store was reset to at their load (codex-10 on 1.8.2; the owner's
    /// ruling (a)): the engine records the reset as such, once, and re-adopts the protection baseline from them, so the
    /// defaults are not taken for edits in Settings. Per object, unlike `loadWasReset`, which the process keeps.
    private(set) var wasResetAtLoad = false

    /// The reset whose record is still owed (codex-10's residual on 1.8.2): noted as a reset saves the defaults, before
    /// they are saved, and cleared once the engine has written the record and the new baseline
    /// (`noteResetRecorded`), so the app ending in between leaves the next launch owing them, not reading the saved
    /// defaults as the owner's. The note holds the record's identity (codex-17 on 1.8.2): only that record stands for
    /// the reset, never another device's copy or an earlier reset.
    static let resetPendingKey = "com.malinois.settings.resetPending"

    /// The identity of the record the owed reset is to have.
    var pendingResetID: UUID? {
        (UserDefaults.standard.string(forKey: Self.resetPendingKey)).flatMap(UUID.init(uuidString:))
    }

    /// The owed reset's identity, saved in the note first when the note holds none (a timestamp, as development builds
    /// of 1.8.2 wrote it, or damage), so the record a retry looks for is the one this attempt writes (codex-17's
    /// residual on 1.8.2).
    func notedResetID() -> UUID {
        if let id = pendingResetID { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: Self.resetPendingKey)
        return id
    }

    /// The reset's record and baseline are written: nothing is owed.
    func noteResetRecorded() {
        UserDefaults.standard.removeObject(forKey: Self.resetPendingKey)
    }

    /// The settings at launch: the stored ones, the defaults for a fresh install, or, before the first unlock after a
    /// restart, the defaults flagged as waiting (`awaitingUnlock`, ADR 0055) and loaded for real at the unlock.
    @MainActor static func load() -> AppSettings {
        let stored = UserDefaults.standard.data(forKey: storeKey)
        switch storeReading(canary: canaryState(), stored: stored) {
        case .sealed:
            // Before the first unlock after a restart (a silent push, iOS's prewarming): the store reads as empty,
            // and the empty read is not a fresh install. The defaults stand in, flagged, until the unlock.
            Log.store.info("Settings unreadable before the first unlock; deferring the load")
            let waiting = AppSettings()
            waiting.waitForUnlock()
            return waiting
        case .fresh:
            finishLoad()
            return AppSettings()
        case .stored(let data):
            let loaded = decodeOrReset(data)
            finishLoad()
            return loaded
        }
    }

    /// After a launch that read the settings: the canary written, the stale corrupt-settings stashes reaped.
    private static func finishLoad() {
        writeCanary()
        reapStaleCorruptStashes()
    }

    /// The stored settings decoded, or, when they cannot be, set aside and reset (announced on Home).
    private static func decodeOrReset(_ data: Data) -> AppSettings {
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            // The saved defaults of a reset whose record is still owed: the app ended first (codex-10's residual).
            if UserDefaults.standard.object(forKey: resetPendingKey) != nil { decoded.wasResetAtLoad = true }
            return decoded
        } catch {
            // Individually-missing fields already decode to their defaults (`decodeIfPresent`),
            // so reaching here means the blob is corrupt or a field has the wrong *type* — one
            // bad value, and every unrelated setting reverts with it.
            //
            // Preserved rather than overwritten, on the same reasoning as a corrupt `events.json`
            // (F-11): the bytes may be recoverable by hand, and nothing can recover them once the
            // next save lands on top.
            let stash = "\(storeKey).corrupt-\(Int(Date().timeIntervalSince1970))"
            UserDefaults.standard.set(data, forKey: stash)
            loadWasReset = true
            Log.store.fault("Settings could not be decoded; preserved as \(stash, privacy: .public) and reset to defaults: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            // The owner's iCloud choices survive where the damaged settings still show them; where
            // backup's cannot be read it is off, failing closed for privacy (item 124's F12, the
            // owner's option B, ADR 0049). Home's backup-off notice says so.
            let reset = AppSettings()
            reset.wasResetAtLoad = true   // the log says so, not "in Settings" (codex-10)
            let kept = Self.readableICloudChoices(in: data)
            reset.cloudBackup = kept.backup ?? false
            if let alerts = kept.alerts { reset.notifyOtherDevices = alerts }
            // Retention falls back to Keep forever, not the 12-month default: nothing in iCloud is deleted on the
            // strength of a setting the owner never chose (item 152's hardening note (a), ADR 0055).
            reset.cloudRetention = .forever
            // Stored at once over the damaged settings (set aside above), not left to the 0.4-second autosave:
            // the damaged settings used to be removed first, so a relaunch inside that window found none and
            // started from the defaults, iCloud backup on (Codex's V1, BACKLOG 128). The reset is noted first, so
            // its record is owed until written (codex-10's residual on 1.8.2).
            UserDefaults.standard.set(UUID().uuidString, forKey: resetPendingKey)
            reset.save()
            return reset
        }
    }

    /// Pure (unit-tested; item 124's F12): the iCloud backup and cross-device alerts switches in
    /// settings that failed to decode, each where it is still a JSON boolean, nil otherwise (the data
    /// is not JSON, the key is missing, or the value is a number or text).
    static func readableICloudChoices(in data: Data) -> (backup: Bool?, alerts: Bool?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        func boolean(_ key: CodingKeys) -> Bool? {
            guard let value = object[key.rawValue] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                return nil
            }
            return value.boolValue
        }
        return (boolean(.cloudBackup), boolean(.notifyOtherDevices))
    }

    /// Seventh-review #6: every corrupt load writes a preservation stash, and nothing ever
    /// reaped them — an unbounded, invisible accumulation. The newest three survive a month
    /// (EventStore's rule). A set-aside event log no longer ages out: it holds evidence, and it
    /// and its media are kept (item 120, F5).
    private static func reapStaleCorruptStashes(now: Date = Date()) {
        let defaults = UserDefaults.standard
        let prefix = storeKey + ".corrupt-"
        let stamps: [(name: String, date: Date)] = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .compactMap { key in EventStore.corruptArtifactDate(key).map { (key, $0) } }
        for key in EventStore.reapableCorruptArtifacts(stamps: stamps, now: now) {
            defaults.removeObject(forKey: key)
            Log.store.info("Reaped stale corrupt-settings stash \(key, privacy: .public)")
        }
    }
}
