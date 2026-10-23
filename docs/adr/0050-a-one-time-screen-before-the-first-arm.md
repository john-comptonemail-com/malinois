# ADR 0050: A one-time screen before the first arm explains disarming and ending Guided Access

- **Status:** accepted (the owner's idea and word, 2026-10-18, item 131: "Add the first-arm screens to 1.8 as you
  described (one screen before the countdown, never on automatic re-arms, scrolling at large text)"; the wording
  approved as drafted, with the choices "1 b 2 include it"); in 1.8 (72). See also ADR 0044. Amended for 1.8.1
  (BACKLOG 144 (e), the owner's "approved", 2026-10-21): part 3, Voice Control, shown once to every install
  (decision 7). Amended 2026-10-23 (BACKLOG 162's F9, the owner's approval): the context's "the Guided Access passcode
  the only way out of the app" holds with Face ID and Touch ID off for ending Guided Access, which the setup now
  advises; with them allowed, an enrolled face or finger ends it too (ADR 0057).
- **Date:** 2026-10-18

## Context

How to disarm is on the arming screen's card at every arm, in the countdown's red reminder, and on the tamper
warning until the first disarm (ADR 0044). How to end Guided Access is the card's third step. Nothing makes a new
owner read them. Under Guided Access the hold and the PIN are the only way to disarm, and the Guided Access passcode
the only way out of the app short of a forced restart. The owner asked for a screen to acknowledge before the first
arm, and before the first arm under Guided Access, both on one screen when they coincide.

## Decision

1. When the owner taps Start countdown on the Guided Access step and a part is due, one screen comes first ("Before
   you arm"). Its one button, "I understand", acknowledges what it showed and starts the countdown through the same
   gate as Start countdown ("Require Guided Access" still holds).
2. Part 1, how to disarm, until acknowledged. Part 2, how to end Guided Access, with the line that a forced restart
   ends it if the passcode is forgotten (after disarming), only when Guided Access is on for that arm, until
   acknowledged. A first arm under Guided Access shows both.
3. Never in front of an arm the owner did not start: the automatic re-arm after a crash calls the countdown
   directly, with nobody watching, and never reaches the screen.
4. New installs only (the owner's choice; as ADR 0044): the two acknowledgments' starting values are written once,
   at launch, before anything can arm. An install that armed before this build starts with both acknowledged and
   never sees those two parts (part 3 is decision 7's). They live in the app's local settings with the other
   onboarding flags: a reinstall shows the screen again; an older build ignores them.
5. The screen scrolls at any text size with its button kept in view, and shows the REC badge while a camera runs
   (guideline 2.5.14), as the arming screens do.
6. The arming card, the countdown's reminder and the warning's tip stay as they are.
7. Part 3 (1.8.1): turning Voice Control off, the one accessibility feature Guided Access leaves running, which can
   be told to close Malinois. Due at every arm the owner starts until acknowledged, with or without Guided Access,
   since it is set before arming. Its acknowledgment is never seeded at launch, so every install sees it once,
   installs updating from 1.8 included; one that acknowledged parts 1 and 2 sees it alone. The title, the button and
   the footnote stay: the arming card keeps its Voice Control line.
8. The screen holds nothing open (1.8.1; the security audit's hardening note (b), BACKLOG 152, the owner's option A).
   While it shows, the arming flow does not hold auto-lock: the phone may sleep as on Home (under Guided Access item
   92's screen hold applies, as on Home). A minute without a touch on the screen cancels the arm back to Home,
   disarmed, with the parts still due and no record (the countdown never started); any touch, a scroll included,
   starts the minute afresh, and "I understand" ends it with the countdown. The screen comes again at the next arm.

## Consequences

- A new owner meets the hold, the PIN and the way out of Guided Access once, with a tap to confirm, before the first
  watch: one more step before the first countdown, where item 68 removed steps.
- Owners updating to 1.8 do not see it, the Guided Access part included; the arming card keeps the same steps.
- The screen says a forced restart ends Guided Access. Only the owner sees it, before the countdown; the fact is
  Apple's public advice and already in SECURITY.md.
- The acknowledgments are local: nothing about them leaves the phone.
- From 1.8.1 every owner meets the Voice Control part once, updates included (the owner's choice for this part,
  unlike parts 1 and 2): one more tap before the first countdown on 1.8.1. Malinois cannot read whether Voice Control
  is on, so the part asks rather than checks.
- Not taken: showing parts 1 and 2 once to everyone, updates included (the owner chose new installs only); an alert
  instead of a screen (an alert cannot scroll at the largest text sizes).
- From 1.8.1 a phone set down on the screen is not left awake, unlocked and unarmed: it sleeps as on Home, and the
  arm is cancelled after a minute untouched. A slow reader who does not scroll for a minute meets the cancel and
  taps ARM again; the minute is a timing constant (`EngineTiming.firstArmBriefingTimeout`). Not taken (option B):
  keeping the hold and only timing out, which would leave the phone lit for the minute.
- The arming screen itself (the Guided Access step with Start countdown, before this screen) keeps auto-lock off with
  no time limit, as before 1.8.1: the owner is expected to be holding the phone there. Weighed for the next release and
  kept as it is (the owner's ruling, 2026-10-23, BACKLOG 157); SECURITY.md (Covert operation) and the README's arming
  steps say so.
