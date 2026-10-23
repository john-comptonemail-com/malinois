//
//  MonitoringEngine+ArmPINCheck.swift
//  Malinois
//
//  The PIN check at ARM (BACKLOG 144 (c), ADR 0054, item 145 step 8): Home's ARM tap asks for the PIN first when it has
//  not been entered correctly for a while. Kept apart from MonitoringEngine.swift, which sits at the lint size limit.
//

import Foundation

extension MonitoringEngine {
    /// How long the PIN may go without a correct entry before the ARM tap asks for it (ADR 0054; the owner's ruling,
    /// 2026-10-22: 14 days).
    nonisolated static let armPINCheckInterval: TimeInterval = 14 * 86_400

    /// Pure (unit-tested; ADR 0054's decision 4): whether the ARM tap asks for the PIN first. Due with no correct entry
    /// on record (an install updating to 1.8.1 is asked once: option A), once the interval has passed since the last
    /// one, or when the stored time lies ahead of the clock (it went back: ask rather than trust). A clock moved
    /// forward only brings the ask sooner, and one moved back can only postpone it, which costs nothing: arming is the
    /// safe direction.
    nonisolated static func armPINCheckDue(lastEntry: Date?, now: Date, interval: TimeInterval = armPINCheckInterval) -> Bool {
        guard let lastEntry else { return true }
        return lastEntry > now || now.timeIntervalSince(lastEntry) >= interval
    }

    /// Whether Home's ARM tap asks for the PIN first now, from the time `KeychainService` keeps beside the PIN. Only the
    /// arm the owner starts consults it: the automatic re-arm after a crash calls the countdown directly.
    var armPINCheckIsDue: Bool {
        Self.armPINCheckDue(lastEntry: KeychainService.lastCorrectEntry, now: Date())
    }
}
