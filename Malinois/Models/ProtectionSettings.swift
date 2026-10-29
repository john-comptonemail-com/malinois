//
//  ProtectionSettings.swift
//  Malinois
//
//  The settings a PIN-holder could weaken before the owner's next session (item 91; review 1's
//  F3): every switchable tripwire (the Camera tripwire included; Touch cannot be switched off,
//  item 83), Require Guided Access, alerts to the owner's other devices, and the jamming
//  response. A change to any of them leaves an audit record. Since 1.8.2 (item 153's MAL-09) seven
//  more, set to a value or switched: the response mode, sensitivity, the grace period, the camera's
//  battery mode, illumination, Face ID unlock and iCloud storage's retention.
//

import Foundation

/// A snapshot of the protection settings, compared with the last one the log recorded.
struct ProtectionSettings: Codable, Equatable {
    /// The switchable tripwires that are on. Touch is never in it: it cannot be switched off.
    var tripwires: Set<SensorType>
    var requireGuidedAccess: Bool
    var otherDeviceAlerts: Bool
    var jammingResponse: Bool
    // Since 1.8.2 (item 153's MAL-09). Optional, so a baseline recorded before them still reads: a setting it lacks is
    // never compared with it, and launch fills it in without a record (`fillingMissing`).
    var sensitivities: [SensorType: Sensitivity]?
    var gracePeriodSeconds: Int?
    var responseMode: ResponseMode?
    var cameraReadiness: CameraReadiness?
    var illumination: IlluminationMode?
    var biometricUnlock: Bool?
    var cloudRetention: CloudRetention?

    init(tripwires: Set<SensorType>, requireGuidedAccess: Bool, otherDeviceAlerts: Bool, jammingResponse: Bool,
         sensitivities: [SensorType: Sensitivity]? = nil, gracePeriodSeconds: Int? = nil, responseMode: ResponseMode? = nil,
         cameraReadiness: CameraReadiness? = nil, illumination: IlluminationMode? = nil, biometricUnlock: Bool? = nil,
         cloudRetention: CloudRetention? = nil) {
        self.tripwires = tripwires.subtracting([.touch])
        self.requireGuidedAccess = requireGuidedAccess
        self.otherDeviceAlerts = otherDeviceAlerts
        self.jammingResponse = jammingResponse
        self.sensitivities = sensitivities
        self.gracePeriodSeconds = gracePeriodSeconds
        self.responseMode = responseMode
        self.cameraReadiness = cameraReadiness
        self.illumination = illumination
        self.biometricUnlock = biometricUnlock
        self.cloudRetention = cloudRetention
    }

    /// The owner's settings as they stand.
    init(_ settings: AppSettings) {
        self.init(tripwires: settings.enabledSensors, requireGuidedAccess: settings.requireGuidedAccess,
                  otherDeviceAlerts: settings.notifyOtherDevices, jammingResponse: settings.jammingResponse,
                  sensitivities: settings.sensitivities, gracePeriodSeconds: settings.gracePeriodSeconds,
                  responseMode: settings.responseMode, cameraReadiness: settings.cameraReadiness,
                  illumination: settings.illumination, biometricUnlock: settings.biometricUnlock,
                  cloudRetention: settings.cloudRetention)
    }

    /// This snapshot with each of the seven it lacks taken from `current`: a baseline recorded before 1.8.2 adopts them
    /// at launch without a record (ADR 0019's first look), so the first change after the update is compared with them.
    func fillingMissing(from current: ProtectionSettings) -> ProtectionSettings {
        var filled = self
        filled.sensitivities = sensitivities ?? current.sensitivities
        filled.gracePeriodSeconds = gracePeriodSeconds ?? current.gracePeriodSeconds
        filled.responseMode = responseMode ?? current.responseMode
        filled.cameraReadiness = cameraReadiness ?? current.cameraReadiness
        filled.illumination = illumination ?? current.illumination
        filled.biometricUnlock = biometricUnlock ?? current.biometricUnlock
        filled.cloudRetention = cloudRetention ?? current.cloudRetention
        return filled
    }

    /// The switchable tripwires in the app's own order. Touch is not one: it cannot be switched off.
    static let switchableTripwires: [SensorType] = SensorType.allCases.filter { $0 != .touch }

    /// Pure (unit-tested): the audit kinds for what changed between two snapshots, one per setting
    /// that changed, weakening or restoring, in a fixed order: the tripwires in the app's own
    /// order, then Guided Access, the other devices' alerts, the jamming response, then the seven
    /// since 1.8.2 in the order of the Settings screen.
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
        return kinds + valueChangeKinds(from: old, to: new)
    }

    /// The seven since 1.8.2 (item 153's MAL-09), in the order of the Settings screen: the response mode, sensitivity
    /// (only where Settings offers it), the grace period, the battery mode, illumination, Face ID unlock, retention. A
    /// setting either snapshot lacks is not compared.
    private static func valueChangeKinds(from old: ProtectionSettings, to new: ProtectionSettings) -> [String] {
        var kinds: [String] = []
        func compare(_ name: String, _ before: String?, _ after: String?) {
            if let before, let after, before != after { kinds.append(Event.settingValueKind(name, after)) }
        }
        compare("responseMode", old.responseMode?.rawValue, new.responseMode?.rawValue)
        for tripwire in SensorType.sensitivityTripwires {
            compare("sensitivity." + tripwire.rawValue, old.sensitivities?[tripwire]?.rawValue,
                    new.sensitivities?[tripwire]?.rawValue)
        }
        compare("gracePeriod", old.gracePeriodSeconds.map(String.init), new.gracePeriodSeconds.map(String.init))
        compare("cameraReadiness", old.cameraReadiness?.rawValue, new.cameraReadiness?.rawValue)
        compare("illumination", old.illumination?.rawValue, new.illumination?.rawValue)
        if let before = old.biometricUnlock, let after = new.biometricUnlock, before != after {
            kinds.append(Event.protectionChangeKind("biometricUnlock", on: after))
        }
        compare("cloudRetention", old.cloudRetention?.rawValue, new.cloudRetention?.rawValue)
        return kinds
    }
}
