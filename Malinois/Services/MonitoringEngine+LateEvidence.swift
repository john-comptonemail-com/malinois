//
//  MonitoringEngine+LateEvidence.swift
//  Malinois
//
//  Item 108, CE-01 (the 1.6 reviews, 2026-10-13): camera evidence that finishes after the
//  capture deadline is stored on its event by the capture pipeline, which reopens the event for
//  upload. Nothing started that upload: the evidence waited for the next launch, foreground or
//  reconnect, which for a phone left armed could be hours.
//

import Foundation

extension MonitoringEngine {
    /// How long late evidence waits for a running sweep to end before asking for its own. Asking
    /// sooner would be turned away by the single-flight guard; a sweep still running after this
    /// is making follow-up passes, and each pass reads what is pending afresh, so it takes the
    /// evidence itself.
    nonisolated static let lateEvidenceSweepWait: TimeInterval = 600

    /// Uploads camera evidence the pipeline stored after the response's own upload had run
    /// (`CapturePipelineHost`). A sweep already running chose its records before this one was
    /// pending and may end without another pass, so this waits for it to end, then starts one.
    /// Free users have no cloud upload: `retryPendingSync` returns at once for them.
    func captureEvidenceStoredLate() {
        let deadline = Date().addingTimeInterval(Self.lateEvidenceSweepWait)
        Task { @MainActor [weak self] in
            while self?.pendingSweepActive == true, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await self?.retryPendingSync()
        }
    }
}
