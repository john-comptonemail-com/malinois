//
//  MonitoringCloudCoordinator+SweepOrder.swift
//  Malinois
//
//  The pending sweep's order (BACKLOG 148, a reviewer's Tier 2 point, 2026-10-21): incidents before status entries, so
//  that after an outage the evidence goes up before the bookkeeping. The cloud coordinator owns the sweep.
//

import Foundation

extension MonitoringCloudCoordinator {
    /// Pure (unit-tested): the order the pending sweep hands records out in: incidents (anything that is not a status
    /// entry, interruption records included) before status entries, each group in the order given (newest first).
    nonisolated static func sweepOrder(_ pending: [Event]) -> [Event] {
        pending.filter { !$0.isStateChange } + pending.filter { $0.isStateChange }
    }
}
