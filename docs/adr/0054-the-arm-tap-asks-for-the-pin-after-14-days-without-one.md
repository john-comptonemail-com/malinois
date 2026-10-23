# ADR 0054: The ARM tap asks for the PIN when it has not been entered correctly for 14 days

- **Status:** accepted (the owner's ruling, 2026-10-22: "options as recommended": 14 days, and option A). BACKLOG
  144: the owner's idea of 2026-10-21 and the ruling "agree": a PIN check at ARM when the PIN has not been entered
  correctly for a while, no Face ID. In 1.8.1 (78), BACKLOG 145 step 8. Decision 6 amended 2026-10-23 (BACKLOG
  162's F1, from TestFlight 78's step 2): a correct PIN entered after the update records a time first.
- **Date:** 2026-10-21

## Context

A forgotten Malinois PIN has one remedy: delete and reinstall the app, which deletes the evidence on the phone. That
is deliberate: an in-app reset behind the device passcode would hand the PIN to anyone who knows that passcode, and
ADR 0040 keeps a PIN across a reinstall only where it can still be verified. Nothing asks for the PIN between one
disarm and the next, so an owner who arms after weeks without using Malinois locks the phone under Guided Access
behind a PIN they may no longer remember, and finds out at the disarm pad. The owner asked for a PIN, or Face ID,
check before arming, "both for security and to ensure the user recalls the pin", and named the cost: a PIN typed at
arm time is typed in front of whoever the phone is about to be left with.

Constraints: arming is the safe direction, so the check buys little security and must not cost the habit of arming;
Face ID proves nothing about recall, and iOS holds its prompts under Guided Access; the automatic re-arm after a crash
runs with nobody watching; the lockout (SECURITY.md, "Brute-force lockout") binds every pad; and the check must open
no way to see the PIN or to arm without it.

## Decision

1. Home's ARM tap asks for the PIN first when the PIN has not been entered correctly for 14 days or more, or when no
   entry is on record. A correct PIN continues as the tap does today (the camera permission's ask, then the arming
   screen); Cancel leaves the phone disarmed on Home. Otherwise the tap opens the arming screen at once, so most arms
   stay one tap.
2. The pad is PIN-only (the owner's word: no Face ID), under the same lockout as every pad: five wrong entries lock
   it, and a locked pad means no arm until the wait passes. A wrong entry here is not a log record: the phone is
   disarmed and in the owner's hands, so the armed pad's rule (ADR 0014) does not apply.
3. "Entered correctly" is every successful check by `KeychainService.verify` (the disarm pad, Home's gates when they
   are opened with the PIN, Settings' pads, the recovery pad) and every PIN set or changed. The time is written
   beside the PIN hash in the Keychain (this device only, readable when the phone is unlocked), as the lockout's
   deadline is. A Face ID or Touch ID open of a Home gate does not count: it proves nothing about recall.
4. The rule is pure and tested: due when no time is stored, when 14 days have passed, or when the stored time is in
   the future (the clock went back: ask rather than trust). A date moved forward only brings the ask sooner; a date
   moved back can postpone it, which costs nothing, since arming is the safe direction.
5. Never in front of an arm the owner did not start: the automatic re-arm after a crash calls the countdown directly
   (ADR 0050, decision 3) and never meets the pad.
6. An install updating to this build has no time on record, so its first ARM tap asks once (option A), unless you have
   entered your PIN in the app since updating, which records a time (decision 3); this is also how a TestFlight build
   shows the pad without a test seam. A new install set its PIN minutes before its first arm
   and is not asked.

## Consequences

- An owner who has not typed the PIN in two weeks learns whether they still know it before the phone is locked under
  Guided Access. A forgotten PIN still ends in a reinstall, but found before the watch, not at the disarm pad.
- One more pad, at most once a fortnight for an owner who arms and disarms regularly: every disarm is a correct entry.
- The PIN is typed where someone may watch, at most once a fortnight. The concealed digits and the "scramble the PIN
  pad" setting apply as on every pad. The owner accepted this cost for a rare ask.
- Nothing about the stored time leaves the phone. Like the PIN, it survives a reinstall (ADR 0040), and the recovery
  writes it afresh: entering the existing PIN, or the new PIN chosen after "Forgot PIN?".
- Not taken: asking at every arm (the observation cost at every arm, for a recall check that needs only an occasional
  ask); Face ID (no recall value, and held under Guided Access); a setting to turn the check off (the owner who would
  turn it off is the one it is for); seeding the time at the update's first launch (option B: no ask for 14 days after
  the update, and no TestFlight check of the pad for 14 days).
- Ruled 2026-10-22: the interval is 14 days (7 and 30 were the alternatives), and option A: an updated install is
  asked once at its first arm.
