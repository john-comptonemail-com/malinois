//
//  MonitoringEngine+SettingsGuard.swift
//  Malinois
//
//  Item 152's lead 3 and lead 17 (item 145 step 12, ADR 0055): the launch work that reads the settings runs once they
//  are resolved, which on a launch before the first unlock after a restart is at the unlock, not at init. The
//  protection-settings baseline (item 91) lives here with it: adopted from the owner's settings, never from the
//  defaults a sealed store stands in for. Kept apart from MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// Runs the launch work that reads the settings once they are resolved (ADR 0055): at once on an unlocked launch,
    /// at the unlock on a launch before it. Called from init.
    func runLaunchWorkWhenSettingsResolve() {
        settings.whenResolved { [weak self] waited in self?.settingsDidResolve(afterWaiting: waited) }
    }

    /// The launch work itself: the first-use protection baseline and the device name. After a wait, what the launch's
    /// uploads held back for the switch's answer goes now, if backup is on (the sweep reads what is pending afresh).
    func settingsDidResolve(afterWaiting waited: Bool) {
        if settings.wasResetAtLoad { recordSettingsReset() } else { adoptProtectionSettingsIfNeeded() }
        refreshDeviceName()
        if waited, settings.cloudBackup { sweepAfterTheRunningOne() }
    }

    // MARK: - The protection-settings baseline (item 91)

    /// The protection settings as the log last recorded them (item 91), kept on this device.
    private static let recordedProtectionKey = "com.malinois.protection.recorded"

    /// Adopts the settings present at launch only when there is no readable recorded baseline.
    /// Writes no audit row: existing configuration is history, not an edit. A valid baseline
    /// must survive relaunch unchanged so an edit made before the app ended is not forgotten; one
    /// recorded before 1.8.2 only gains the seven settings it lacks, as they are now (step 22).
    private func adoptProtectionSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.recordedProtectionKey),
           let recorded = try? JSONDecoder().decode(ProtectionSettings.self, from: data) {
            let filled = recorded.fillingMissing(from: ProtectionSettings(settings))
            if filled != recorded, let data = try? JSONEncoder().encode(filled) {
                defaults.set(data, forKey: Self.recordedProtectionKey)
            }
            return
        }
        if let data = try? JSONEncoder().encode(ProtectionSettings(settings)) {
            defaults.set(data, forKey: Self.recordedProtectionKey)
        }
    }

    /// The stored settings could not be decoded and were reset to their defaults (ADR 0049), which no one chose in
    /// Settings (codex-10 on 1.8.2; the owner's ruling (a)): one record says so, and the reset settings become the
    /// baseline, so the next comparison writes no edit "in Settings" for them and those after it are real edits.
    /// Once, across the app ending first (codex-10's residual): the reset is noted until its record and baseline are
    /// written, and its record takes the note's identity, so only that record stands for it, never another device's
    /// copy or an earlier reset (codex-17); a note that holds none is given one before the record is written.
    private func recordSettingsReset() {
        let id = settings.notedResetID()
        if !eventStore.events.contains(where: { $0.id == id }) { logStateChange("settingsReset", id: id) }
        if let data = try? JSONEncoder().encode(ProtectionSettings(settings)) {
            UserDefaults.standard.set(data, forKey: Self.recordedProtectionKey)
        }
        settings.noteResetRecorded()
    }

    /// Item 91 (review 1's F3 (a); the 1.4 review's A1): compares the protection settings with the
    /// ones last recorded, writes one audit record per change, and remembers them. Called when
    /// Settings closes and at every arm, so a change is on the record before the next session
    /// whatever path it took, the app ended with Settings open included. Launch establishes a
    /// missing baseline before Settings can edit it; an unreadable baseline here is adopted
    /// without inventing history. Never while the settings wait for the unlock: the defaults are not the owner's
    /// settings, so a comparison would report changes nobody made (ADR 0055).
    func recordProtectionChanges() {
        guard !settings.awaitingUnlock else { return }
        let current = ProtectionSettings(settings)
        let defaults = UserDefaults.standard
        defer {
            if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: Self.recordedProtectionKey) }
        }
        guard let data = defaults.data(forKey: Self.recordedProtectionKey),
              let recorded = try? JSONDecoder().decode(ProtectionSettings.self, from: data) else { return }
        for kind in ProtectionSettings.changeKinds(from: recorded, to: current) { logStateChange(kind) }
    }
}
