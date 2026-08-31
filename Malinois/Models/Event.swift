//
//  Event.swift
//  Malinois
//
//  A single tamper event: what tripped, when, the captured evidence, and
//  short sensor traces for the event window.
//

import Foundation

struct Event: Identifiable, Codable, Equatable, Hashable {
    // Facts fixed at the moment of the tamper.
    let id: UUID
    let startDate: Date
    // Which sensors tripped. `var` only so a coalesced "sustained activity" event can
    // accumulate the sensors seen across a flood; a normal event never mutates it.
    var triggeredSensors: [SensorType]
    // endDate is set once, after capture finishes (see MonitoringEngine.respond).
    var endDate: Date

    /// Filename (relative to the media directory) of the primary evidence —
    /// a still (.jpg) or a clip (.mov).
    var mediaFilename: String?
    /// Optional second capture (used by the "Both" camera option — e.g. the
    /// primary is the front camera and this is the rear).
    var secondaryMediaFilename: String?
    /// A few-KB JPEG thumbnail, kept inline so the log renders without disk I/O
    /// and so the "tiny" CloudKit record has something to carry. For a clip this
    /// is its first frame.
    var thumbnailData: Data?

    /// Which camera each capture used ("front"/"rear") and, for clips, how long
    /// it recorded — surfaced as "F" / "B" durations in the log.
    var primaryCamera: String?
    var primaryDuration: Double?
    var secondaryCamera: String?
    var secondaryDuration: Double?

    /// Accelerometer user-acceleration magnitude samples across the window (g).
    let motionTrace: [Double]
    /// Audio level samples across the window (dBFS, roughly -160…0).
    let audioTrace: [Double]
    /// Vision tripwire samples across the window: fraction of the camera's view that changed
    /// per frame (0…1). Lets a vision trip show WHY it fired even when the photo looks empty.
    /// Optional so events saved before this field decode fine.
    var visionTrace: [Double]?

    var cloudSyncState: CloudSyncState

    /// True if the network was in a total blackout at capture time (a strong
    /// jamming indicator for a stationary armed device). Optional so events saved
    /// before this field decode fine — treat nil as false.
    var capturedOffline: Bool?

    /// For a coalesced "sustained activity" event (sensor flooding), how many trips
    /// it represents. Nil for a normal single-trip event.
    var sustainedCount: Int?

    /// True if this was captured while the disarm PIN pad was open and a correct PIN
    /// then followed — i.e. the owner's own handling, not a tamper. Optional so events
    /// saved before this field decode fine — treat nil as false.
    var ownerAttributed: Bool?

    /// True for a "monitoring interrupted" record: the armed app was killed (force-quit,
    /// Voice Control "Close application", or an OS/OOM crash) without a clean disarm, and
    /// this was logged on the next launch by crash recovery. It carries no camera evidence
    /// (the app was gone), but the *fact* that protection stopped is itself worth recording
    /// and alerting on. Optional so older events decode fine — treat nil as false.
    var interrupted: Bool?

    /// A monitoring state change — `"armed"` or `"disarmed"` — logged so protection turning
    /// on/off is an explicit, auditable record, not something the owner has to infer from
    /// remembering their arm time. Its point is the disarm case: an attacker who knows the
    /// PIN can disarm, but the app has no delete affordance, so the "disarmed" entry stands
    /// as proof of exactly when protection stopped. `nil` for a normal event; carries no
    /// media. Optional so older events decode fine.
    var stateChange: String?

    /// Non-nil when this record was **mirrored from another device** rather than captured
    /// here — the name of the device that captured it.
    ///
    /// Deliberately explicit rather than inferred by comparing `deviceName`, because the
    /// evidence log is the most safety-critical structure in the app and a merge bug that
    /// silently interleaved foreign records with local ones would be very hard to notice.
    /// A mirrored copy is a *claim about another device*, not first-hand evidence captured
    /// here, and the UI says so. `nil` for everything captured locally, which is every event
    /// written before this shipped.
    var sourceDevice: String?

    /// Which generation of this event's cloud record this copy came from — the app's own
    /// monotonic revision, not CloudKit's change tag.
    ///
    /// One event is written to iCloud more than once: a sparse "fact" the instant a tripwire
    /// fires, then the full metadata with its thumbnail and final duration once capture
    /// finishes, then possibly again for owner attribution. Revisions order those writes, so a
    /// stalled early one cannot land last and overwrite a richer later one, and so a mirrored
    /// copy on another device can be replaced by a later revision of itself rather than being
    /// frozen at whatever arrived first. `nil` on events written before this existed.
    var cloudRevision: Int?

    /// True when the storage byte cap had to discard this event's media **before it ever
    /// uploaded** (34.H5, 1.2). Pruning *synced* media is silent — the cloud still holds it
    /// and it can be re-downloaded — but a pending capture that had to go is a real
    /// evidentiary loss, and a later meta-only retry must not read as "everything made it".
    var mediaDiscarded: Bool?

    /// For a MIRRORED event: which camera tokens the capturing device says it uploaded
    /// full-media records under (the payload's manifest, 34's metadataJSON item + B1's
    /// robustness note). Retrieval then fetches exactly what exists instead of probing every
    /// slot blindly. `nil` on local events and on mirrors of records from before the
    /// manifest existed — the blind probe remains the fallback. Optional so older saved
    /// events decode fine.
    var cloudMediaManifest: [String]?

    /// Whether this event came from another device via iCloud rather than this device's own
    /// sensors. Only ever true for merged copies.
    var isMirrored: Bool { sourceDevice != nil }

    init(id: UUID = UUID(),
         startDate: Date,
         endDate: Date,
         triggeredSensors: [SensorType],
         mediaFilename: String? = nil,
         secondaryMediaFilename: String? = nil,
         thumbnailData: Data? = nil,
         primaryCamera: String? = nil,
         primaryDuration: Double? = nil,
         secondaryCamera: String? = nil,
         secondaryDuration: Double? = nil,
         motionTrace: [Double] = [],
         audioTrace: [Double] = [],
         visionTrace: [Double]? = nil,
         cloudSyncState: CloudSyncState = .pending,
         capturedOffline: Bool? = nil,
         sustainedCount: Int? = nil,
         ownerAttributed: Bool? = nil,
         interrupted: Bool? = nil,
         stateChange: String? = nil,
         sourceDevice: String? = nil,
         cloudRevision: Int? = nil,
         mediaDiscarded: Bool? = nil,
         cloudMediaManifest: [String]? = nil) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.triggeredSensors = triggeredSensors
        self.mediaFilename = mediaFilename
        self.secondaryMediaFilename = secondaryMediaFilename
        self.thumbnailData = thumbnailData
        self.primaryCamera = primaryCamera
        self.primaryDuration = primaryDuration
        self.secondaryCamera = secondaryCamera
        self.secondaryDuration = secondaryDuration
        self.motionTrace = motionTrace
        self.audioTrace = audioTrace
        self.visionTrace = visionTrace
        self.cloudSyncState = cloudSyncState
        self.capturedOffline = capturedOffline
        self.sustainedCount = sustainedCount
        self.ownerAttributed = ownerAttributed
        self.interrupted = interrupted
        self.stateChange = stateChange
        self.sourceDevice = sourceDevice
        self.cloudRevision = cloudRevision
        self.mediaDiscarded = mediaDiscarded
        self.cloudMediaManifest = cloudMediaManifest
    }

    /// The camera token each full-media upload names its record with — "front"/"rear", with
    /// "primary"/"secondary" as the uploader's fallback when no camera was recorded. Shared
    /// between the exfiltrator's record names and the payload's manifest so the two can
    /// never disagree (the one-value-two-readers lesson this codebase keeps re-learning).
    var primaryMediaToken: String { primaryCamera ?? "primary" }
    var secondaryMediaToken: String { secondaryCamera ?? "secondary" }

    /// Which full-media records this event's exfiltration uploads — the payload's manifest
    /// (34's metadataJSON item + B1's robustness note). Empty when the event carries none.
    var mediaManifest: [String] {
        var tokens: [String] = []
        if mediaFilename != nil { tokens.append(primaryMediaToken) }
        if secondaryMediaFilename != nil { tokens.append(secondaryMediaToken) }
        return tokens
    }

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    /// Recording duration(s) labeled by camera — "F 5.0s", "B 5.0s", or both for
    /// the "Both" option. Empty for stills (no meaningful clip length).
    var durationSummary: String {
        func label(_ camera: String?) -> String { camera == "rear" ? "B" : "F" }
        var parts: [String] = []
        if let d = primaryDuration { parts.append("\(label(primaryCamera)) \(String(format: "%.1fs", d))") }
        if let d = secondaryDuration { parts.append("\(label(secondaryCamera)) \(String(format: "%.1fs", d))") }
        return parts.joined(separator: " · ")
    }

    /// A monitoring state-change record (armed / disarmed) carries no sensor evidence and is
    /// rendered differently in the log (no media, no sync badge).
    var isStateChange: Bool { stateChange != nil }

    var sensorSummary: String {
        switch stateChange {
        case "armed":    return "Monitoring armed"
        case "disarmed": return "Monitoring disarmed"
        case "gaLifted": return "Guided Access requirement lifted for one arm"
        default:         break
        }
        if interrupted == true { return "Monitoring interrupted — the app closed before a clean disarm" }
        // A sensorless event is a connectivity-blackout ("possible jamming") capture.
        let base = triggeredSensors.isEmpty ? "Signal loss"
            : triggeredSensors.map { $0.displayName }.joined(separator: ", ")
        if let n = sustainedCount, n > 1 { return "\(base) — sustained ×\(n)" }
        return base
    }

    /// Compact metadata dictionary pushed as JSON in the first (tiny) CloudKit
    /// record so the essential facts land before the full photo uploads.
    ///
    /// Payload v2 (34's metadataJSON item): the fields a mirror used to LOSE — the
    /// sustained-flood count, which camera(s) captured, clip durations, the pre-upload
    /// discard marker — plus the media manifest (B1's robustness note: which full-media
    /// records exist, so retrieval fetches exactly those). All conditional, so the
    /// pre-capture fact stays as tiny as ever; absent keys are how v1 records read too, and
    /// the decoder tolerates both directions by construction.
    var metadataJSON: Data? {
        var payload: [String: Any] = [
            "v": 2,
            "id": id.uuidString,
            "startDate": ISO8601DateFormatter().string(from: startDate),
            "endDate": ISO8601DateFormatter().string(from: endDate),
            "durationSeconds": duration,
            "triggeredSensors": triggeredSensors.map { $0.rawValue },
            "motionPeak": motionTrace.max() ?? 0,
            "audioPeak": audioTrace.max() ?? -160,
            "visionPeak": visionTrace?.max() ?? 0,
            "deviceName": DeviceInfo.name,
            "capturedOffline": capturedOffline ?? false,
            "ownerAttributed": ownerAttributed ?? false,
            "interrupted": interrupted ?? false
        ]
        if let n = sustainedCount { payload["sustainedCount"] = n }
        if let camera = primaryCamera { payload["primaryCamera"] = camera }
        if let d = primaryDuration { payload["primaryDuration"] = d }
        if let camera = secondaryCamera { payload["secondaryCamera"] = camera }
        if let d = secondaryDuration { payload["secondaryDuration"] = d }
        if mediaDiscarded == true { payload["mediaDiscarded"] = true }
        let manifest = mediaManifest
        if !manifest.isEmpty { payload["media"] = manifest }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

enum DeviceInfo {
    /// Read once; avoids importing UIKit into the model layer everywhere.
    static var name: String = "Unknown Device"

    /// The hardware model identifier ("iPhone18,4") from the kernel — or, in the Simulator,
    /// from the environment the simulator sets. Empty when unavailable.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = systemInfo.machine
        return withUnsafeBytes(of: machine) { raw in
            // Failable on purpose (lint's optional_data_string_conversion): a mangled
            // C-string degrades to "" → `marketingName` → plain "iPhone", never garbage.
            String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        }
    }

    /// Marketing name for a model identifier — the device-label FALLBACK (owner's call,
    /// 2026-08-30): iOS reports a generic "iPhone" to apps, so an unlabeled device's mirrors
    /// were anonymous; the model name is clearer, and two same-model devices in one log is
    /// less confusing than two called "iPhone". Pure (unit-tested). Unknown identifiers pass
    /// through unchanged — "iPhone19,2" is honest where a guessed name would be wrong — and
    /// an empty identifier falls back to plain "iPhone". The table is generated from the
    /// SDK's own device-type registry (`xcrun simctl list devicetypes`), not memory; extend
    /// it per new hardware generation.
    static func marketingName(forIdentifier id: String) -> String {
        guard !id.isEmpty else { return "iPhone" }
        return modelNames[id] ?? id
    }

    private static let modelNames: [String: String] = [
        "iPhone11,2": "iPhone XS",        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",    "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",   "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",    "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",    "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",   "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",    "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",    "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",    "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",    "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",        "iPhone18,4": "iPhone Air",
        "iPhone18,5": "iPhone 17e"
    ]
}
