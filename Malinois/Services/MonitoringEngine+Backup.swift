//
//  MonitoringEngine+Backup.swift
//  Malinois
//
//  Item 115 (item 108's decision 4, option C; P-01): the "iCloud backup" switch. Kept apart from
//  MonitoringEngine.swift, which sits at the lint size limits. ADR 0047.
//

import Foundation

extension MonitoringEngine {
    /// Said on Home and on the arming and countdown screens while iCloud backup is off on Pro
    /// (item 120, F1): Home's row said "iCloud ready" and the arming screens said nothing.
    static let backupOffNotice = "iCloud backup is off: new events stay on this iPhone."

    /// Whether iCloud backup lets this record upload. While backup is off nothing does, except the
    /// entry recording that it was turned off, so the cloud log shows it even when its first upload
    /// fails. An event recorded while backup was off never uploads, even once it is back on (the
    /// owner's ruling); the store marks it when it is added.
    func backupAllows(_ event: Event) -> Bool {
        guard settings.cloudBackup else { return event.stateChange == Event.backupOffKind }
        if event.keptLocal == true { return false }
        return eventStore.events.first { $0.id == event.id }?.keptLocal != true
    }

    /// Turns iCloud backup on or off, only while disarmed; returns whether it did. The Settings
    /// switch asks for device authentication before turning it off; this records the change. Off
    /// is recorded before uploads stop, in the one entry that still uploads; on is recorded after,
    /// and a pending sweep then carries up what waited while backup was off (events recorded
    /// before it was turned off), once any sweep already running has ended (item 116, R4).
    @discardableResult
    func setCloudBackup(_ on: Bool) -> Bool {
        guard state == .disarmed else { return false }   // the screen's rule, kept here too (item 116)
        guard on != settings.cloudBackup else { return true }
        if !on { logStateChange(Event.backupOffKind) }
        settings.cloudBackup = on
        settings.save()
        guard on else { return true }
        logStateChange(Event.backupOnKind)
        sweepAfterTheRunningOne()
        return true
    }

    /// Wires the switch into the three places that apply it (at init): the store marks an event
    /// recorded while backup is off; the enrollment registers it to no account, which older
    /// versions honour too (item 116, R3); and the uploader reads the rule before every step
    /// (R2).
    func watchBackupSetting() {
        eventStore.keepsNewEventsLocal = { [weak self] in self?.settings.cloudBackup == false }
        cloud.enrollment.holdsNewEventsLocal = { [weak self] in self?.settings.cloudBackup == false }
        cloud.backupPermits = { [weak self] event in self?.backupAllows(event) ?? false }
        cloud.backupOn = { [weak self] in self?.settings.cloudBackup ?? false }
    }
}
