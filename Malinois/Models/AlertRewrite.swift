//
//  AlertRewrite.swift
//  Malinois
//
//  How a cross-device alert would be worded from its record (item 76, ADR 0017): the words come
//  from the Event Log's own (`Event.sensorSummary`), so an alert and the log never disagree. Since
//  1.5.1 the alert extension reads no record and shows the push's own text (ADR 0039), and since 1.8
//  it compiles only its own file: this stays in the app for a Debug-only preview, where the tests
//  pin it. Foundation only.
//

import Foundation

/// What the receiving iPhone shows for one cross-device push (item 76).
struct AlertRewrite: Equatable {
    let title: String
    let body: String
    /// The default sound, or none (a Vision-only trip: a banner without sound).
    let playsSound: Bool
    /// Time Sensitive (it breaks through a Focus unless the owner turns that off for Malinois),
    /// or the ordinary level.
    let timeSensitive: Bool

    /// What a push is about, from the type of the record it names.
    enum PushedRecord: Equatable { case tamper, disarm }

    /// The record types the app writes and subscribes to (`CloudExfiltrator.metaRecordTypeV2` and
    /// `.disarmSignalRecordTypeV2`; a test pins them equal). Spelled out here because the
    /// extension does not compile the uploader.
    static let tamperRecordType = "TamperEventMetaV2"
    static let disarmRecordType = "TamperEventDisarmV2"

    /// The longest device name a title carries: the log's own cap on a mirrored device's name.
    static let maxDeviceNameLength = 64

    /// Pure (unit-tested): the alert for a tamper record captured on another device. A trip seen
    /// only by the camera (a shadow, a cat) is a banner without sound at the ordinary level; every
    /// other tamper alert, an interruption and a wrong PIN included, keeps its sound and is Time
    /// Sensitive (the owner's rulings, 2026-09-28).
    static func forTamper(_ event: Event, deviceName: String?) -> AlertRewrite {
        let title = title(deviceName: deviceName)
        let wrongPIN = (event.wrongPINCount ?? 0) > 0
        if event.triggeredSensors == [.vision], event.interrupted != true, !wrongPIN {
            return AlertRewrite(title: title, body: "The camera saw movement.", playsSound: false, timeSensitive: false)
        }
        // An interruption or a wrong PIN already reads as a sentence in the log; a trip reads as
        // the tripwires that fired.
        let summary = event.sensorSummary
        let body = event.interrupted == true || wrongPIN ? summary + "." : "Tamper detected: \(summary)."
        return AlertRewrite(title: title, body: body, playsSound: true, timeSensitive: true)
    }

    /// Pure (unit-tested): the alert for a disarm, or a cancelled countdown, on another device. The
    /// title names the device, so the body says it once, "Malinois was disarmed." (the owner's
    /// ruling, 2026-09-28); without a usable name the body keeps the sentence the push was sent
    /// with. Its sound and its ordinary level stay as they were.
    static func forDisarm(deviceName: String?) -> AlertRewrite {
        let body = usableName(deviceName) == nil ? "Malinois was disarmed on one of your devices." : "Malinois was disarmed."
        return AlertRewrite(title: title(deviceName: deviceName), body: body, playsSound: true, timeSensitive: false)
    }

    /// "Malinois: <device>", or "Malinois" without a usable name.
    static func title(deviceName: String?) -> String {
        usableName(deviceName).map { "Malinois: \($0)" } ?? "Malinois"
    }

    /// The name as one line of ordinary characters, cut to `maxDeviceNameLength`, or nil when
    /// nothing is left. It is the only text an alert takes from the record, and the record is
    /// cloud input: a line break, a tab or any other control character becomes one space, and the
    /// characters that turn text around are dropped, so a written name cannot add a line to the
    /// alert or disguise its words. Joiners stay, so an emoji sequence stays whole.
    private static func usableName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var line = String.UnicodeScalarView()
        var gap = false
        for scalar in raw.unicodeScalars {
            if directionControls.contains(scalar.value) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.properties.generalCategory == .control {
                gap = true
                continue
            }
            if gap, !line.isEmpty { line.append(" ") }
            gap = false
            line.append(scalar)
        }
        guard !line.isEmpty else { return nil }
        return String(String(line).prefix(maxDeviceNameLength))
    }

    /// The characters that change the direction text is shown in (the Unicode bidirectional
    /// marks, embeddings, overrides and isolates).
    private static let directionControls: Set<UInt32> = [0x061C, 0x200E, 0x200F,
                                                         0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                         0x2066, 0x2067, 0x2068, 0x2069]

    /// Pure (unit-tested): the fields of a tamper record that an alert shows, as an `Event`: the
    /// tripwires (unknown ones dropped and the rest sorted, as the log's decoder does) and, from
    /// the metadata, an interruption and its cause, a wrong-PIN count and a flood count. Cloud
    /// input, so each is allow-listed or bounded; anything else is left out.
    static func tamperEvent(sensorsField: String?, metadataJSON: String?, startDate: Date?) -> Event {
        let sensors = (sensorsField ?? "").split(separator: ",")
            .compactMap { SensorType(rawValue: String($0)) }
            .sorted { $0.rawValue < $1.rawValue }
        var interrupted: Bool?, cause: String?, wrongPINs: Int?, sustained: Int?
        if let data = metadataJSON?.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            interrupted = obj["interrupted"] as? Bool
            cause = (obj["interruptionCause"] as? String).flatMap { InterruptionCause(rawValue: $0)?.rawValue }
            wrongPINs = bounded(obj["wrongPINCount"] as? Int, max: 1_000)
            sustained = bounded(obj["sustainedCount"] as? Int, max: 100_000)
        }
        let at = startDate ?? Date()
        return Event(startDate: at, endDate: at, triggeredSensors: sensors, cloudSyncState: .synced,
                     sustainedCount: sustained, interrupted: interrupted, interruptionCause: cause,
                     wrongPINCount: wrongPINs)
    }

    /// A count worth showing: at least one and within the cap the log's decoder applies.
    private static func bounded(_ n: Int?, max: Int) -> Int? {
        n.flatMap { (1...max).contains($0) ? $0 : nil }
    }

    /// Pure (unit-tested): the kind of alert a pushed record raises, from its type; nil for any
    /// other type (an audit record raises none).
    static func pushedRecord(ofType recordType: String) -> PushedRecord? {
        switch recordType {
        case tamperRecordType: return .tamper
        case disarmRecordType: return .disarm
        default:               return nil
        }
    }

    /// Pure (unit-tested): the app's iCloud container, which the extension reads from. The
    /// extension's bundle id is the app's plus one part (".NotificationService"), and the app's
    /// container is "iCloud." plus the app's bundle id, as `CloudExfiltrator` names it.
    static func appContainerIdentifier(extensionBundleID: String?) -> String? {
        guard let id = extensionBundleID, let dot = id.lastIndex(of: ".") else { return nil }
        return "iCloud." + id[..<dot]
    }
}
