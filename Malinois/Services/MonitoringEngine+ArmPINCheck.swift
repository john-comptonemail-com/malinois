//
//  MonitoringEngine+ArmPINCheck.swift
//  Malinois
//
//  The root's ARM PIN interval/policy facade and device-passcode query. MonitoringArmingFlow+PIN owns
//  the tap's decision and permission work; HomeView still opens only the pad the facade's answer names.
//  The private LA query and its DEBUG override stay beside the narrow arming-host bridge.
//

import AVFoundation
import Foundation
import LocalAuthentication

extension MonitoringEngine {
    /// How long the PIN may go without a correct entry before the ARM tap asks for it (ADR 0054; the owner's ruling,
    /// 2026-10-22: 14 days).
    nonisolated static let armPINCheckInterval: TimeInterval = 14 * 86_400

    /// Whether Home's ARM tap asks for the PIN first now, from the time `KeychainService` keeps beside the PIN. Only the
    /// arm the owner starts consults it: the automatic re-arm after a crash calls the countdown directly.
    var armPINCheckIsDue: Bool {
        armingFlow.armPINCheckIsDue
    }

    // MARK: - A phone without a passcode (1.8.2's step 34, item 155's F3)

    /// Same-file bridge to the root-owned LA query and its DEBUG override.
    var armingDevicePasscodeMissingNow: Bool { devicePasscodeMissingNow }

    /// iOS's answer, or, under the test seam, the test's. The check asks the owner for nothing and shows nothing.
    private var devicePasscodeMissingNow: Bool {
        #if DEBUG
        if let missing = devicePasscodeMissingForTesting { return missing }
        #endif
        var error: NSError?
        let canEvaluate = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return Self.passcodeMissing(canEvaluate: canEvaluate, error: error)
    }

}
