# ADR 0044: The tamper warning shows how to disarm until the owner's first disarm

- **Status:** accepted (owner's ruling, 2026-10-12, "A is fine", after the options were put with
  build 60; item 107's request: "Maybe on the first arm we should also display the disarm
  instructions on the alerting screen"); in 1.6 since build 60. Narrows the rule, held since the
  first build, that the tamper warning never shows the hold that reveals the PIN pad (SECURITY.md,
  the armed screen's code). Amended for 1.6 (65) at the owner's request (2026-10-13): decision 4's
  texts say "the screen", not "the black screen", and the countdown's reminder is red. See also
  ADR 0050 (1.8): a one-time screen before a new install's first arm.
- **Date:** 2026-10-12

## Context

The armed screen is black and the hold that reveals the PIN pad is learned only from the arming
screen, where it was the first of three small steps in a lightly tinted card. The owner found the
instructions easy to miss. A new owner who picks up the armed phone to try it meets the warning
(Alert, the default) or the siren, with no word on how to stop it.

The warning left the hold out on purpose: printing it "would hand a thief the bypass". Checked in
code on 2026-10-12, the hold opens the PIN pad and nothing more. A running alarm stays up until a
correct PIN (`alertAction`); capture and upload continue; each wrong PIN is a record with a photo
(ADR 0014) and counts toward the lockout (five free tries, then waits from 30 s doubling to an
hour). While someone types on the pad, a fresh warning or flash does not start, a limit SECURITY.md
already accepts. The hold is not a secret: the README, the support page and the App Review notes
describe it. A new install's first arm also runs without Guided Access by default (item 68), when
anyone can leave the app anyway.

## Decision

1. Until the owner has disarmed once from the black screen with the PIN, the tamper warning (Alert
   and Siren) also shows "To disarm: press and hold anywhere for 5 seconds, then enter your
   Malinois PIN." and says the tip shows only until the first disarm. Stealth shows no warning and
   so no tip.
2. The tip is counted to the first disarm, not the first watch: an owner who closed the app instead
   of disarming (possible without Guided Access) has not learned the hold. A correct PIN on the
   armed screen's pad ends it.
3. The flag's starting value is written once, at launch: a new install starts with the tip; an
   install that armed before this build starts without it, so an existing owner's warning never
   shows the hold. It lives in the app's local settings, cleared with the app like the other
   onboarding flags.
4. The arming screen's disarm card leads with the hold in large type, and the countdown repeats it,
   in red (65) so that it stands out, above all under Guided Access, where the hold and the PIN are
   the only way back in. Both say "press and hold the screen" (65): on a charger the armed screen is
   dimmed, not black, and Alert mode shows the warning.
   Only the owner sees those.

## Consequences

- An intruder who trips a new install before its first disarm learns the hold and reaches the PIN
  pad. The lockout still limits guessing and every wrong PIN is recorded, but a predictable PIN is
  more exposed on that watch; ADR 0041's easy-to-guess warning is the mitigation.
- A reinstall shows the tip again until its first disarm, as a new install would.
- Not taken: a practice hold on the first arm (doing the hold once on the arming screen before the
  countdown) would teach it without the warning ever showing it, at the cost of one more step before
  the first watch, where item 68 removed steps. It remains the alternative if the tip is judged too
  revealing.
