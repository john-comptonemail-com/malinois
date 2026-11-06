//
//  FirstArmBriefing.swift
//  Malinois
//
//  The one-time screen before the first arm (BACKLOG 131, the owner's idea and word, 2026-10-18): how to disarm,
//  and, when Guided Access is on for the arm, how to end it, each acknowledged once.
//

import Foundation

/// The texts and rules of the one-time screen before the first arm (item 131), in the owner's approved wording
/// (2026-10-18; the Voice Control part, item 144 (e), 2026-10-21; the Side Button part, item 153, 2026-11-04). The
/// arming screen's card, the countdown's reminder and the tamper warning's tip stay as they are.
enum FirstArmBriefing {
    static let title = "Before you arm"
    static let disarmHeading = "How to disarm"
    static let disarmText = "Press and hold anywhere on the screen for 5 seconds, then enter your Malinois PIN. This works even while Guided Access is on."
    static let guidedAccessHeading = "How to end Guided Access"
    static let guidedAccessText = "After you disarm, triple-click the side (or Home) button, enter your Guided Access passcode, and tap End."
    static let forgotPasscodeText = "Forgot that passcode? After you disarm, a forced restart ends Guided Access."
    /// The owner's words of 2026-11-05 (item 204, "yes"), in place of item 131's "The arming screen keeps these steps."
    static let footnote = "You can find these steps on the arming screen too."
    /// Part 3 (item 144 (e), the owner's approved wording, 2026-10-21): the one accessibility feature Guided Access
    /// leaves running, and one that can close Malinois.
    static let voiceControlHeading = "Voice Control"
    static let voiceControlText = "If you use Voice Control, turn it OFF before you arm (Settings → Accessibility → Voice Control). It keeps working under Guided Access and can be told to close Malinois. Malinois can't see whether it is on, so this is up to you."
    /// Part 4 (item 153, the owner's approved wording, 2026-11-04, "approved, b"): Guided Access's own option, with
    /// which one press of the side button locks the screen and nothing is watched until the owner unlocks.
    static let sideButtonHeading = "Side Button"
    static let sideButtonText = "In Guided Access's Options, turn Side Button OFF (Sleep/Wake Button on older phones). If it is on, one press locks the screen, and nothing is watched until you unlock. Malinois can't see this setting, so this is up to you."
    static let button = "I understand"

    /// Which parts the screen shows: how to disarm, how to end Guided Access, turning Voice Control off, and turning
    /// Guided Access's Side Button off.
    struct Parts: Equatable, Identifiable {
        var disarm: Bool
        var guidedAccess: Bool
        /// Part 3, turning Voice Control off (item 144 (e)); false unless named, so a two-part value reads as before.
        var voiceControl: Bool = false
        /// Part 4, turning Guided Access's Side Button off (BACKLOG 153); false unless named.
        var sideButton: Bool = false
        var isEmpty: Bool { !disarm && !guidedAccess && !voiceControl && !sideButton }
        var id: String { "\(disarm)-\(guidedAccess)-\(voiceControl)-\(sideButton)" }
    }

    /// Pure (unit-tested): the parts due when the owner taps Start countdown. None for an arm the owner did not
    /// start: the automatic re-arm after a crash runs with nobody watching and must not wait for a tap. The disarm
    /// part until it is acknowledged; the Guided Access part only when Guided Access is on for this arm, until it is
    /// acknowledged; the Voice Control part until it is acknowledged, with or without Guided Access (item 144 (e): it
    /// is set before arming); the Side Button part only when Guided Access is on for this arm, until it is
    /// acknowledged (item 153: the option is Guided Access's own). A first arm under Guided Access shows all four on
    /// the one screen.
    static func partsDue(ownerStarted: Bool, guidedAccessOn: Bool,
                         disarmAcknowledged: Bool, guidedAccessAcknowledged: Bool,
                         voiceControlAcknowledged: Bool, sideButtonAcknowledged: Bool) -> Parts {
        guard ownerStarted else { return Parts(disarm: false, guidedAccess: false) }
        return Parts(disarm: !disarmAcknowledged, guidedAccess: guidedAccessOn && !guidedAccessAcknowledged,
                     voiceControl: !voiceControlAcknowledged, sideButton: guidedAccessOn && !sideButtonAcknowledged)
    }

    /// Pure (unit-tested): an acknowledgment's starting value, written once when this build first runs. The owner's
    /// choice (2026-10-18): new installs only, as the disarm tip (item 107). A stored value always wins; without one,
    /// an install that has armed before starts acknowledged, so an existing owner never sees the screen.
    static func initialAcknowledged(stored: Bool?, hasArmedOnce: Bool) -> Bool {
        stored ?? hasArmedOnce
    }
}
