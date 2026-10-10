//
//  ProtectionSettings.swift
//  Malinois
//
//  The settings a PIN-holder could weaken before the owner's next session (item 91; review 1's
//  F3): every switchable tripwire (the Camera tripwire included; Touch cannot be switched off,
//  item 83), Require Guided Access, alerts to the owner's other devices, and the jamming
//  response. A change to any of them leaves an audit record.
//

import Foundation

/// A snapshot of the protection settings, compared with the last one the log recorded.
struct ProtectionSettings: Codable, Equatable {
    /// The switchable tripwires that are on. Touch is never in it: it cannot be switched off.
    var tripwires: Set<SensorType>
    var requireGuidedAccess: Bool
    var otherDeviceAlerts: Bool
    var jammingResponse: Bool

    init(tripwires: Set<SensorType>, requireGuidedAccess: Bool, otherDeviceAlerts: Bool, jammingResponse: Bool) {
        self.tripwires = tripwires.subtracting([.touch])
        self.requireGuidedAccess = requireGuidedAccess
        self.otherDeviceAlerts = otherDeviceAlerts
        self.jammingResponse = jammingResponse
    }

    /// The owner's settings as they stand.
    init(_ settings: AppSettings) {
        self.init(tripwires: settings.enabledSensors, requireGuidedAccess: settings.requireGuidedAccess,
                  otherDeviceAlerts: settings.notifyOtherDevices, jammingResponse: settings.jammingResponse)
    }

    /// The switchable tripwires in the app's own order. Touch is not one: it cannot be switched off.
    static let switchableTripwires: [SensorType] = SensorType.allCases.filter { $0 != .touch }

    /// Pure (unit-tested): the audit kinds for what changed between two snapshots, one per setting
    /// that changed, weakening or restoring, in a fixed order: the tripwires in the app's own
    /// order, then Guided Access, the other devices' alerts, the jamming response.
    static func changeKinds(from old: ProtectionSettings, to new: ProtectionSettings) -> [String] {
        var kinds: [String] = []
        for tripwire in switchableTripwires where old.tripwires.contains(tripwire) != new.tripwires.contains(tripwire) {
            kinds.append(Event.protectionChangeKind(tripwire.rawValue, on: new.tripwires.contains(tripwire)))
        }
        let named: [(String, Bool, Bool)] = [
            ("requireGuidedAccess", old.requireGuidedAccess, new.requireGuidedAccess),
            ("otherDeviceAlerts", old.otherDeviceAlerts, new.otherDeviceAlerts),
            ("jammingResponse", old.jammingResponse, new.jammingResponse),
        ]
        for (name, before, after) in named where before != after {
            kinds.append(Event.protectionChangeKind(name, on: after))
        }
        return kinds
    }
}
