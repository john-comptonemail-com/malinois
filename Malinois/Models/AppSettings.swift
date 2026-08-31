//
//  AppSettings.swift
//  Malinois
//
//  User-facing configuration, persisted to UserDefaults. The MonitoringEngine
//  reads these when arming; sensors read their own slice at start().
//

import Foundation
import Combine

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
        case .auto:  return "Auto (by orientation)"
        case .both:  return "Both (multi-cam)"
        }
    }
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
            return "Camera stays ready for instant capture. Highest battery use — best when charging."
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

    // Which tripwires are active.
    @Published var enabledSensors: Set<SensorType>
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

    /// Push an alert to the user's OTHER devices signed into the same iCloud
    /// account the moment a tamper event is recorded (via a CloudKit subscription).
    @Published var notifyOtherDevices: Bool

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
    /// to voicemail, and disables Siri — so without it a snoop can simply swipe the app away.
    /// **Off by default** so that a first run can arm without the owner having to configure
    /// an iOS accessibility feature before seeing the app work at all — the arming screen
    /// coaches Guided Access either way. (It also lets an App Store reviewer exercise the app
    /// without that setup, which is a consequence of the default, not the reason for it.)
    /// Turning it on trades that first-run convenience for a hard guarantee.
    @Published var requireGuidedAccess: Bool

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
    static let defaultAlertMessage = "Recording in progress. This device is protected — unauthorized access has been logged."

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
        // Auto, not Front: it resolves face-down → rear and everything else → front, and is
        // re-resolved at every capture. Front-as-default meant a phone placed face down — a
        // natural covert placement, screen hidden — pointed its camera at the desk, so captures
        // came back black and the vision tripwire saw nothing, with no indication either way.
        // Auto is never worse: face up it picks front regardless.
        cameraPosition = .auto
        cameraReadiness = .auto   // instant while charging, cold-start on battery
        deviceLabel = ""
        illumination = .auto
        notifyOtherDevices = true
        cloudRetention = .months12
        jammingResponse = true
        responseMode = .alert
        alertMessage = AppSettings.defaultAlertMessage
        requireGuidedAccess = false
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
    var hasActiveTripwire: Bool {
        SensorType.tripwires.contains { enabledSensors.contains($0) }
    }

    // MARK: - Codable (Published needs manual coding)

    enum CodingKeys: String, CodingKey {
        case enabledSensors, sensitivities, triggerMode
        case gracePeriodSeconds, captureMode, cameraPosition, cameraReadiness
        case deviceLabel
        case illumination, notifyOtherDevices, cloudRetention, jammingResponse
        case responseMode, alertMessage, scramblePINPad, requireGuidedAccess, sirenRampUp
        case biometricUnlock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledSensors = try c.decode(Set<SensorType>.self, forKey: .enabledSensors)
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
        cameraPosition = try c.decodeIfPresent(CameraChoice.self, forKey: .cameraPosition) ?? .auto
        cameraReadiness = try c.decodeIfPresent(CameraReadiness.self, forKey: .cameraReadiness) ?? .auto
        deviceLabel = try c.decodeIfPresent(String.self, forKey: .deviceLabel) ?? ""
        // Default Auto when unset (also for anyone upgrading from the old bool).
        illumination = try c.decodeIfPresent(IlluminationMode.self, forKey: .illumination) ?? .auto
        notifyOtherDevices = try c.decodeIfPresent(Bool.self, forKey: .notifyOtherDevices) ?? true
        // `try?`, like triggerMode: a future build retiring a case must not reset every setting.
        cloudRetention = (try? c.decodeIfPresent(CloudRetention.self, forKey: .cloudRetention)) ?? .months12
        jammingResponse = try c.decodeIfPresent(Bool.self, forKey: .jammingResponse) ?? true
        responseMode = try c.decodeIfPresent(ResponseMode.self, forKey: .responseMode) ?? .alert
        alertMessage = try c.decodeIfPresent(String.self, forKey: .alertMessage) ?? AppSettings.defaultAlertMessage
        scramblePINPad = try c.decodeIfPresent(Bool.self, forKey: .scramblePINPad) ?? false
        biometricUnlock = try c.decodeIfPresent(Bool.self, forKey: .biometricUnlock) ?? false
        requireGuidedAccess = try c.decodeIfPresent(Bool.self, forKey: .requireGuidedAccess) ?? false
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
        try c.encode(notifyOtherDevices, forKey: .notifyOtherDevices)
        try c.encode(cloudRetention, forKey: .cloudRetention)
        try c.encode(jammingResponse, forKey: .jammingResponse)
        try c.encode(responseMode, forKey: .responseMode)
        try c.encode(alertMessage, forKey: .alertMessage)
        try c.encode(scramblePINPad, forKey: .scramblePINPad)
        try c.encode(biometricUnlock, forKey: .biometricUnlock)
        try c.encode(requireGuidedAccess, forKey: .requireGuidedAccess)
        try c.encode(sirenRampUp, forKey: .sirenRampUp)
    }

    // MARK: - Persistence

    private static let storeKey = "com.malinois.settings"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// Set when stored settings existed but could not be decoded, so the app is running on
    /// defaults the owner never chose. Surfaced rather than silently accepted: the defaults
    /// include Guided Access enforcement **off**, PIN-pad scrambling **off** and the Sound and
    /// Vision tripwires **off**, so a silent reset quietly reduces protection — the one thing
    /// this app's settings must never do without saying so.
    static private(set) var loadWasReset = false

    static func load() -> AppSettings {
        reapStaleCorruptStashes()
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
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
            UserDefaults.standard.removeObject(forKey: storeKey)
            loadWasReset = true
            Log.store.fault("Settings could not be decoded; preserved as \(stash, privacy: .public) and reset to defaults: \(String(describing: error), privacy: .public)")
            return AppSettings()
        }
    }

    /// Seventh-review #6: every corrupt load writes a preservation stash, and nothing ever
    /// reaped them — an unbounded, invisible accumulation. Same time-bounding as the
    /// event-log tombstones: the newest three survive a month; the rule is EventStore's,
    /// shared, so both artifact families age identically.
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
