//
//  BiometricBinding.swift
//  Malinois
//
//  Item 152's lead 4 (item 145 step 13, ADR 0056): Face ID or Touch ID unlock is bound to the faces or fingers enrolled
//  on the iPhone when the owner turned it on. iOS reports the enrolled set as an opaque state (`domainState.biometry
//  .stateHash` on iOS 18 and later, `evaluatedPolicyDomainState` before) that changes when a face or finger is added or
//  removed; the state at opt-in is kept in the Keychain, this device only, and the pad offers the biometric only while
//  the current state matches. Nothing here leaves the phone.
//

import Foundation
import LocalAuthentication

enum BiometricBinding {
    /// Whether the unlock may be offered: bound (the enrolled set is the one at opt-in), unbound (nothing on record),
    /// or changed (a face or finger was added or removed, or iOS reports none).
    enum Verdict: Equatable { case bound, unbound, changed }

    /// Pure (unit-tested): the state at opt-in against the state iOS reports now. Nothing on record is unbound (an
    /// install updating with the unlock on, or a binding whose write was refused); a different state, or none now, is
    /// changed. Either way the pad falls back to the PIN and never blocks it.
    nonisolated static func verdict(stored: Data?, current: Data?) -> Verdict {
        guard let stored, !stored.isEmpty else { return .unbound }
        guard let current, !current.isEmpty, current == stored else { return .changed }
        return .bound
    }

    /// The enrolled biometrics' state as `context` reports it after a successful `canEvaluatePolicy` for a biometric
    /// policy; nil when no biometric is enrolled.
    nonisolated static func state(of context: LAContext) -> Data? {
        #if DEBUG
        if let injected = stateForTesting { return injected() }
        #endif
        if #available(iOS 18, *) { return context.domainState.biometry.stateHash }
        return context.evaluatedPolicyDomainState
    }

    /// Whether a biometric can be evaluated now (enrolled, available, not locked out).
    nonisolated static func canEvaluateBiometrics(_ context: LAContext) -> Bool {
        #if DEBUG
        if let injected = canEvaluateForTesting { return injected }
        #endif
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// The state now, from a fresh context; nil when no biometric can be evaluated.
    nonisolated static func currentState() -> Data? {
        let context = LAContext()
        guard canEvaluateBiometrics(context) else { return nil }
        return state(of: context)
    }

    #if DEBUG
    /// A test's enrolled state, in place of iOS's (the simulator enrolls nothing).
    nonisolated(unsafe) static var stateForTesting: (() -> Data?)?
    /// A test's answer to whether a biometric can be evaluated.
    nonisolated(unsafe) static var canEvaluateForTesting: Bool?
    #endif

    /// Settings' toggle (behind the PIN): on binds the unlock to the biometrics enrolled now; off clears the binding.
    /// With no state to read (nothing enrolled), or a Keychain write refused, the unlock turns on unbound, and the pad's
    /// first offer turns it off again with its caption: the safe direction.
    @MainActor static func setUnlock(_ on: Bool, settings: AppSettings) {
        if on, let state = currentState(), !state.isEmpty {
            KeychainService.recordEnrolledBiometricState(state)
        } else {
            KeychainService.clearEnrolledBiometricState()
        }
        settings.biometricUnlock = on
    }

    /// The pad's check before an offer, after `canEvaluateBiometrics` succeeded on `context`: bound, or the unlock
    /// turns off and the binding clears, with the verdict for the pad's caption. Off stays off until Settings, behind
    /// the PIN, turns it on again and binds it afresh.
    @MainActor static func checkBeforeOffer(context: LAContext, settings: AppSettings) -> Verdict {
        let verdict = verdict(stored: KeychainService.enrolledBiometricState, current: state(of: context))
        if verdict != .bound {
            settings.biometricUnlock = false   // off until Settings turns it on again (ADR 0056)
            KeychainService.clearEnrolledBiometricState()
        }
        return verdict
    }
}
