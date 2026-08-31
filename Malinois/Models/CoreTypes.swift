//
//  CoreTypes.swift
//  Malinois
//
//  Shared enumerations used across the monitoring engine, sensors, and UI.
//

import Foundation

/// The identities of every sensor tripwire the engine can arm.
enum SensorType: String, Codable, CaseIterable, Identifiable {
    case motion
    case power
    case proximity
    case audio
    case vision
    case camera
    case touch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .motion:    return "Device motion"
        case .power:     return "Power / Cable"
        case .proximity: return "Proximity"
        // "Sound", not "Audio": the paywall, onboarding, the listing and the support page all
        // said Sound already — only Settings and Test Sensors disagreed, so this is the odd one
        // out being brought into line rather than a new name. The raw value stays `audio`, as
        // `motion`'s did when it became "Device motion" — renaming a raw value would orphan
        // every saved event.
        case .audio:     return "Sound"
        case .vision:    return "Vision"
        case .camera:    return "Camera"
        case .touch:     return "Touch"
        }
    }

    /// One line under the Settings toggle: what the sensor actually watches. Exists because
    /// "Motion" beside "Vision" reads as camera motion detection — it isn't; the phone itself
    /// moving is the trigger, and the caption says so without relying on the label.
    var summary: String {
        switch self {
        case .motion:    return "The phone itself is moved, tilted or bumped."
        case .power:     return "The charging cable is pulled or plugged in."
        case .proximity: return "Something comes close to the front of the phone."
        case .audio:     return "Footsteps or handling noise nearby."
        case .vision:    return "Movement seen by the camera — only while the camera is warm (plugged in on Auto, or Instant)."
        case .camera:    return "Capture photo or video evidence when a tripwire fires."
        case .touch:     return "The screen is tapped or swiped."
        }
    }

    var iconName: String {
        switch self {
        case .motion:    return "move.3d"
        case .power:     return "powerplug"
        case .proximity: return "hand.raised"
        case .audio:     return "waveform"
        case .vision:    return "eye"
        case .camera:    return "camera"
        case .touch:     return "hand.tap"
        }
    }

    /// How to trigger this sensor, for the Test Sensors view.
    var testHint: String {
        switch self {
        case .motion:    return "Bump or lift the phone, or tilt it."
        case .power:     return "Plug in or unplug the charging cable."
        case .proximity: return "Cover the top of the phone near the front camera. The screen turns off while it's covered — that IS the sensor working; you'll see the count go up when you uncover."
        case .audio:     return "Clap or speak close to the phone."
        case .vision:    return "Wave a hand in front of the camera. Needs the camera warm — plug in (Auto) or use Instant mode; on battery it shows \"No frames\"."
        case .camera:    return "Captures evidence on any trigger."
        case .touch:     return "Tap the pad below."
        }
    }

    /// Camera is the evidence-capture device, not itself a tripwire the user
    /// selects to "trip on". These are the sensors that can start an event.
    static var tripwires: [SensorType] {
        [.motion, .power, .proximity, .audio, .vision, .touch]
    }

    /// The tripwires gated behind Pro. Defined once here because the set is consulted from
    /// three unrelated places — the entitlement clamp (`AppSettings.effectiveSensors`), the
    /// Settings row, and the Test Sensors row — and they must never disagree: a UI that
    /// forgets a sensor is Pro shows a toggle that silently does nothing at arm time.
    static var proTripwires: Set<SensorType> { [.audio, .vision] }

    /// Whether this sensor is enabled in name only — switched on, but clamped off at use
    /// because the owner isn't entitled. The Settings and Test Sensors rows both surface
    /// this, so "the paywall never silently reduces protection" holds per-row and not only
    /// in the all-tripwires-locked case that `hasActiveTripwire(pro:)` catches.
    func isInertWithoutPro(enabled: Bool, pro: Bool) -> Bool {
        enabled && !pro && Self.proTripwires.contains(self)
    }
}

/// Per-sensor coarse sensitivity. Each monitor maps this to concrete thresholds.
enum Sensitivity: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}

/// How individual sensor trips combine into an actual trigger.
/// How individual sensor trips combine into a trigger.
///
/// Only one mode ships today: any enabled tripwire fires on its own. A second mode
/// ("Motion-confirmed" — motion had to be corroborated by audio/proximity within the
/// correlation window) was removed: it was a setting almost nobody changed, and its
/// correlation logic was the source of a real deafness bug (a lone uncorroborated trip
/// could latch a one-shot monitor — the fix is the refractory sweep, which is retained
/// because the flood path and re-entrant triggers can still latch a sensor). Kept as an
/// enum rather than inlined so re-introducing it is a purely additive change — see
/// BACKLOG "Motion-confirmed trigger mode".
enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    /// Any single enabled sensor tripping fires the alarm.
    case any

    var id: String { rawValue }

    /// Whether the set of tripped sensors should fire a trigger under this mode.
    /// Pure — the single source of truth for trigger correlation (unit-tested).
    func shouldFire(for sensors: Set<SensorType>) -> Bool {
        switch self {
        case .any:
            return !sensors.isEmpty
        }
    }
}

/// High-level state machine for the whole app. (Exfiltration is not a state —
/// it runs in the background after re-arming, so the app returns straight to
/// `.armed` once evidence is captured.)
enum MonitoringState: Equatable {
    case disarmed
    case guidedAccessCheck
    case arming              // grace countdown before calibration
    case calibrating         // learning resting gravity + noise floor
    case armed               // watching
    case triggered           // event detected, capturing

    var isActive: Bool {
        switch self {
        case .disarmed, .guidedAccessCheck: return false
        default: return true
        }
    }
}

extension TimeInterval {
    /// Human clock string: "H:MM:SS" past an hour, otherwise "M:SS".
    var clockString: String {
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Whether an event's evidence has reached iCloud.
enum CloudSyncState: String, Codable {
    case pending    // not yet pushed
    case synced     // full-res record confirmed in CloudKit
    case localOnly  // exhausted retries / no account — only on disk

    var displayName: String {
        switch self {
        case .pending:   return "Syncing…"
        case .synced:    return "iCloud synced"
        case .localOnly: return "Local only"
        }
    }
}
