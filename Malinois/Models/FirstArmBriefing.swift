//
//  FirstArmBriefing.swift
//  Malinois
//
//  The one-time screen before the first arm (BACKLOG 131, the owner's idea and word, 2026-10-18): how to disarm,
//  and, when Guided Access is on for the arm, how to end it, each acknowledged once.
//

import Foundation

/// The texts and rules of the one-time screen before the first arm (item 131), in the owner's approved wording
/// (2026-10-18; the Voice Control part, item 144 (e), 2026-10-21). The arming screen's card, the countdown's reminder and the tamper warning's tip stay as they are.
enum FirstArmBriefing {
    static let title = "Before you arm"
    static let disarmHeading = "How to disarm"
    static let disarmText = "Press and hold anywhere on the screen for 5 seconds, then enter your Malinois PIN. This works even while Guided Access is on."
    static let guidedAccessHeading = "How to end Guided Access"
    static let guidedAccessText = "After you disarm, triple-click the side (or Home) button, enter your Guided Access passcode, and tap End."
    static let forgotPasscodeText = "Forgot that passcode? After you disarm, a forced restart ends Guided Access."
    static let footnote = "The arming screen keeps these steps."
    /// Part 3 (item 144 (e), the owner's approved wording, 2026-10-21): the one accessibility feature Guided Access
    /// leaves running, and one that can close Malinois.
    static let voiceControlHeading = "Voice Control"
    static let voiceControlText = "If you use Voice Control, turn it OFF before you arm (Settings → Accessibility → Voice Control). It keeps working under Guided Access and can be told to close Malinois. Malinois can't see whether it is on, so this is up to you."
    static let button = "I understand"

    /// Which parts the screen shows: how to disarm, how to end Guided Access, and turning Voice Control off.
    struct Parts: Equatable, Identifiable {
        var disarm: Bool
        var guidedAccess: Bool
        /// Part 3, turning Voice Control off (item 144 (e)); false unless named, so a two-part value reads as before.
        var voiceControl: Bool = false
        var isEmpty: Bool { !disarm && !guidedAccess && !voiceControl }
        var id: String { "\(disarm)-\(guidedAccess)-\(voiceControl)" }
    }

    /// Pure (unit-tested): the parts due when the owner taps Start countdown. None for an arm the owner did not
    /// start: the automatic re-arm after a crash runs with nobody watching and must not wait for a tap. The disarm
    /// part until it is acknowledged; the Guided Access part only when Guided Access is on for this arm, until it is
    /// acknowledged; the Voice Control part until it is acknowledged, with or without Guided Access (item 144 (e): it
    /// is set before arming). A first arm under Guided Access shows all three on the one screen.
    static func partsDue(ownerStarted: Bool, guidedAccessOn: Bool,
                         disarmAcknowledged: Bool, guidedAccessAcknowledged: Bool,
                         voiceControlAcknowledged: Bool) -> Parts {
        guard ownerStarted else { return Parts(disarm: false, guidedAccess: false) }
        return Parts(disarm: !disarmAcknowledged, guidedAccess: guidedAccessOn && !guidedAccessAcknowledged,
                     voiceControl: !voiceControlAcknowledged)
    }

    /// Pure (unit-tested): an acknowledgment's starting value, written once when this build first runs. The owner's
    /// choice (2026-10-18): new installs only, as the disarm tip (item 107). A stored value always wins; without one,
    /// an install that has armed before starts acknowledged, so an existing owner never sees the screen.
    static func initialAcknowledged(stored: Bool?, hasArmedOnce: Bool) -> Bool {
        stored ?? hasArmedOnce
    }
}
