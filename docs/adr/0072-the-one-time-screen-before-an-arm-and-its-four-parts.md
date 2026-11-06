# ADR 0072: The one-time screen before an arm, and its four parts

- **Status:** accepted: the owner's word for each part (BACKLOG 131, 2026-10-18; item 144 (e), 2026-10-21; item 153,
  2026-11-04: "approved, b") and for the screen's minute (item 152's hardening note (b), the owner's option A). It
  states ADR 0050's design with that record's three amendments and the Side Button part (item 153, item 192's step
  5), as it stands in 1.11; ADR 0050 keeps its decision. Built on `claude/1.11` (red `aca8c5ed`, `14223498`).
- **Date:** 2026-11-04

## Context

How to disarm is on the arming screen's card at every arm, in the countdown's red reminder, and on the tamper warning
until the first disarm (ADR 0044). How to end Guided Access is the card's third step, turning Voice Control off a line
of the card, and turning Guided Access's Side Button option off the card's step 7. Nothing makes an owner read them.
Under Guided Access the hold and the PIN are the only way to disarm, and the Guided Access passcode the only way out of
the app short of a forced restart, with Face ID and Touch ID off for ending Guided Access, as the setup advises (with
them allowed, an enrolled face or finger ends it too, ADR 0057). Two settings Malinois cannot read decide how far
Guided Access holds: Voice Control keeps working under Guided Access and can be told to close Malinois, and with the
Side Button option on, one press locks the screen and the watch stops until the owner unlocks (recorded as a lock;
nothing is watched meanwhile). The owner asked for a screen to acknowledge before the first arm, and then for these
two settings on it.

## Decision

1. When the owner taps Start countdown on the Guided Access step and a part is due, one screen comes first ("Before
   you arm"). Its one button, "I understand", acknowledges every part it showed and starts the countdown through the
   same gate as Start countdown ("Require Guided Access" still holds).
2. Its parts, in the screen's order: how to disarm, until acknowledged; how to end Guided Access, with the line that a
   forced restart ends it if the passcode is forgotten (after disarming), only when Guided Access is on for that arm,
   until acknowledged; turning Guided Access's Side Button option off, only when Guided Access is on for that arm
   (the option is Guided Access's own), until acknowledged; turning Voice Control off, with or without Guided Access
   (it is set before arming), until acknowledged. Every part due is on the one screen.
3. Never in front of an arm the owner did not start: the automatic re-arm after a crash calls the countdown directly,
   with nobody watching, and never reaches the screen.
4. Who sees which part. How to disarm and how to end Guided Access: new installs only (the owner's choice, as ADR
   0044); their acknowledgments' starting values are written once, at launch, before anything can arm, and an install
   that armed before starts with both acknowledged. Voice Control (from 1.8.1) and the Side Button (from 1.11): never
   seeded, so every install sees each once, updated ones included; the Side Button part at its first arm under Guided
   Access. The acknowledgments live in the app's local settings with the other onboarding flags: a reinstall shows the
   screen again; an older build ignores them.
5. The screen scrolls at any text size with its button kept in view, and shows the REC badge while a camera runs
   (guideline 2.5.14), as the arming screens do.
6. The arming card, the countdown's reminder and the warning's tip stay as they are; the card keeps its Voice Control
   line and its Side Button step.
7. The screen holds nothing open. While it shows, the arming flow does not hold auto-lock: the phone may sleep as on
   Home (under Guided Access item 92's screen hold applies, as on Home). A minute without a touch on the screen cancels
   the arm back to Home, disarmed, with the parts still due and no record (the countdown never started); any touch, a
   scroll included, starts the minute afresh, and "I understand" ends it with the countdown. The screen comes again at
   the next arm.
8. The words are the owner's approved ones (`FirstArmBriefing`): the first two parts' of 2026-10-18, Voice Control's
   of 2026-10-21, the Side Button's of 2026-11-04.

## Consequences

- A new owner meets the hold, the PIN, the way out of Guided Access and the two settings Malinois cannot read once,
  with a tap to confirm, before the first watch: one more step before the first countdown, where item 68 removed steps.
- An updated owner sees the Voice Control part once (from 1.8.1) and the Side Button part once, at the first arm under
  Guided Access on 1.11: one more tap each. The first two parts they never see; the arming card keeps the same steps.
- Malinois cannot read whether Voice Control or the Side Button option is on, so those parts ask rather than check.
- The screen says a forced restart ends Guided Access. Only the owner sees it, before the countdown; the fact is
  Apple's public advice and already in SECURITY.md.
- The acknowledgments are local: nothing about them leaves the phone.
- A phone set down on the screen is not left awake, unlocked and unarmed: it sleeps as on Home, and the arm is
  cancelled after a minute untouched. A slow reader who does not scroll for a minute meets the cancel and taps ARM
  again; the minute is a timing constant (`EngineTiming.firstArmBriefingTimeout`).
- The arming screen itself (the Guided Access step with Start countdown, before this screen) keeps auto-lock off with
  no time limit: the owner is expected to be holding the phone there (the owner's ruling, 2026-10-23, BACKLOG 157);
  SECURITY.md (Covert operation) and the README's arming steps say so.
- Not taken: the first two parts once to everyone, updates included (the owner chose new installs only); an alert
  instead of a screen (an alert cannot scroll at the largest text sizes); keeping the screen's hold on auto-lock with
  only a timeout (option B, 2026-10-23); the Side Button line inside the Guided Access part, for new installs only
  (option (a), 2026-11-04).
