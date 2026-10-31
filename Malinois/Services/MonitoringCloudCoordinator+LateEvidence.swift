//
//  MonitoringCloudCoordinator+LateEvidence.swift
//  Malinois
//
//  Item 108, CE-01 (the 1.6 reviews, 2026-10-13): camera evidence that finishes after the
//  capture deadline is stored on its event by the capture pipeline, which reopens the event for
//  upload. Nothing started that upload: the evidence waited for the next launch, foreground or
//  reconnect, which for a phone left armed could be hours.
//

import Foundation

extension MonitoringCloudCoordinator {
    /// Uploads camera evidence the pipeline stored after the response's own upload had run
    /// (`CapturePipelineHost`). Free users have no cloud upload: `retryPendingSync` returns at
    /// once for them.
    func captureEvidenceStoredLate() { sweepAfterTheRunningOne() }

    /// Asks for a pending sweep that must not be lost. With none running, one starts now. With one
    /// running, which chose its records before the caller's became pending and may end without
    /// another pass, another is owed, and `endPendingSweep` starts it when that sweep ends, however
    /// long it runs and whatever the clock does (item 116, N1: a ten-minute wait used to give up and
    /// ask anyway, and the single-flight guard turned it away). Used for late evidence (item 108,
    /// CE-01) and for iCloud backup turned back on (item 116, R4).
    func sweepAfterTheRunningOne() {
        if pendingSweepActive {
            sweepRerunOwed = true
        } else {
            let lifetime = retainHostForFiniteWork()
            Task { defer { lifetime.keepAlive() }; await retryPendingSync() }   // a sweep that starts first reads what is pending afresh
        }
    }
}
