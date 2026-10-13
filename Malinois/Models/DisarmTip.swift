//
//  DisarmTip.swift
//  Malinois
//
//  How the owner learns the way back in (item 107, ADR 0044). The armed screen is dark, so the
//  5-second hold has to be learned before it is needed: the arming screen's disarm card leads
//  with it, the countdown repeats it, and until the owner has disarmed once from the black
//  screen the tamper warning shows it too. After that first disarm the warning never shows it,
//  so a later intruder is not told how to reach the PIN pad. The hold opens the pad and nothing
//  more: a running alarm stays up until a correct PIN, and every wrong PIN is recorded and
//  counted toward the lockout.
//

import Foundation

/// The disarm hold, in the words used wherever the owner is told about it (item 107).
enum DisarmTip {
    /// The arming screen card's headline. "The screen", not "the black screen" (owner, 2026-10-13):
    /// on a charger the armed screen is dimmed, not black, and Alert mode shows the warning.
    static let holdHeadline = "Press and hold the screen for 5 seconds"
    /// Under the countdown, in red: the last thing the owner reads before the screen goes dark.
    static let countdownReminder = "To disarm later: press and hold the screen for 5 seconds, then enter your PIN."
    /// Under the tamper warning until the owner's first disarm. Alert-screen text: no em-dash (B16).
    static let alertTipText = "To disarm: press and hold anywhere for 5 seconds, then enter your Malinois PIN."
    /// Below the tip, so its disappearance after the first disarm is expected.
    static let alertTipFootnote = "This tip shows only until you first disarm."

    /// Pure (unit-tested). The tip the tamper warning carries: the hold until the owner has
    /// disarmed once from the black screen, then nothing, so a later intruder is not shown it.
    /// Stealth shows no warning, so it never shows the tip either.
    static func alertTip(hasDisarmedOnce: Bool) -> String? {
        hasDisarmedOnce ? nil : alertTipText
    }

    /// Pure (unit-tested). The starting value of `OnboardingState.hasDisarmedOnce`, written once
    /// when this build first runs. A stored value always wins, so a new install's first watch
    /// going live does not end the tip. Without one, an install that has armed before has been
    /// through the black screen and starts without the tip, so an existing owner's warning never
    /// shows the hold; only a new install starts with it.
    static func initialHasDisarmedOnce(stored: Bool?, hasArmedOnce: Bool) -> Bool {
        stored ?? hasArmedOnce
    }
}
