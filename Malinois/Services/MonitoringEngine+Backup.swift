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

    /// Home's notice when the launch check finds this phone's iCloud copies gone and queues them again (item 87). With
    /// iCloud backup off they upload only once it is turned back on; the notice said "uploading" (claude-1, found while
    /// checking Fable's fable-5 on 75). Pure (unit-tested).
    nonisolated static func cloudReuploadNotice(requeued: Int, backupOn: Bool) -> String {
        let found = "iCloud no longer held this phone's records, as happens when iCloud data is deleted in iOS Settings. "
        return backupOn ? found + "This phone is uploading \(requeued) of them again."
            : found + "\(requeued) of them will upload again when iCloud backup is turned back on."
    }

    /// Whether iCloud backup lets this record upload. While backup is off nothing does, except the
    /// entry recording that it was turned off, so the cloud log shows it even when its first upload
    /// fails. An event recorded while backup was off never uploads, even once it is back on (the
    /// owner's ruling); the store marks it when it is added. While the settings wait for the unlock
    /// (ADR 0055) nothing uploads either: the switch is not known yet, and the pending sweep reads
    /// the answer again once it is.
    func backupAllows(_ event: Event) -> Bool {
        guard !settings.awaitingUnlock else { return false }   // the upload waits with the settings
        guard settings.cloudBackup else { return event.stateChange == Event.backupOffKind }
        if event.keptLocal == true { return false }
        return eventStore.events.first { $0.id == event.id }?.keptLocal != true
    }

    /// Turns iCloud backup on or off, only while disarmed and only once the settings are the owner's
    /// (ADR 0055); returns whether it did. The Settings switch asks for device authentication before
    /// turning it off; this records the change. Off is recorded before uploads stop, in the one
    /// entry that still uploads; on is recorded after, and a pending sweep then carries up what
    /// waited while backup was off (events recorded before it was turned off), once any sweep
    /// already running has ended (item 116, R4).
    @discardableResult
    func setCloudBackup(_ on: Bool) -> Bool {
        guard state == .disarmed, !settings.awaitingUnlock else { return false }   // the screen's rule, kept here too (item 116)
        guard on != settings.cloudBackup else { return true }
        if !on { logStateChange(Event.backupOffKind) }
        settings.cloudBackup = on
        settings.save()
        refreshCloudReuploadNotice()   // the launch check's notice, in the words for the switch now (codex-1 on 76)
        guard on else { return true }
        logStateChange(Event.backupOnKind)
        sweepAfterTheRunningOne()
        return true
    }

    /// Wires the switch into the three places that apply it (at init): the store marks an event
    /// recorded while backup is off; the enrollment registers it to no account, which older
    /// versions honour too (item 116, R3); and the uploader reads the rule before every step
    /// (R2). Each reads the switch as known (`cloudBackupKnownOff`, `cloudBackupKnownOn`): while the
    /// settings wait for the unlock nothing is marked, held or sent on the strength of a default (ADR 0055).
    func watchBackupSetting() {
        eventStore.keepsNewEventsLocal = { [weak self] in self?.settings.cloudBackupKnownOff == true }
        cloud.enrollment.holdsNewEventsLocal = { [weak self] in self?.settings.cloudBackupKnownOff == true }
        cloud.backupPermits = { [weak self] event in self?.backupAllows(event) ?? false }
        cloud.backupOn = { [weak self] in self?.settings.cloudBackupKnownOn ?? false }
    }
}
