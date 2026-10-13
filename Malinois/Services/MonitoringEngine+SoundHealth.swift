//
//  MonitoringEngine+SoundHealth.swift
//  Malinois
//
//  The Sound tripwire's health records (item 105, F-09): a microphone that stops working during a
//  live watch leaves a quiet status entry, and another when it works again. Kept apart from
//  MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// The Sound tripwire's monitor, with its health reports wired to the log.
    func makeAudioMonitor() -> AudioMonitor {
        let audio = AudioMonitor()
        audio.onHealthReport = { [weak self] report in self?.handleSoundHealthReport(report) }
        return audio
    }

    /// Records a Sound outage or recovery while a watch is live. Like the heat warnings, these ride
    /// the silent audit type: never a siren or a cross-device alert, since a microphone taken by a
    /// call or another app looks the same as one taken on purpose.
    func handleSoundHealthReport(_ report: SoundHealthTracker.Report) {
        guard armedSince != nil else { return }
        logStateChange(Self.soundHealthRecordKind(report))
    }

    /// Pure: the status record each report writes.
    nonisolated static func soundHealthRecordKind(_ report: SoundHealthTracker.Report) -> String {
        switch report {
        case .unavailable: return "soundUnavailable"
        case .restored: return "soundRestored"
        }
    }
}
