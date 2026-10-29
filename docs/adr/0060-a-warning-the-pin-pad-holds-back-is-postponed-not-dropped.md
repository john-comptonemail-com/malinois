# ADR 0060: A warning the PIN pad holds back is postponed, not dropped

- **Status:** accepted (the owner's ruling, 2026-10-26, "yes, all as recommended, A1 as (a)", on BACKLOG item 167's
  A1, from Codex's full review of 1.8.2 (79) at `b7221cb`); in 1.8.2 (79). Changes the rule SECURITY.md states for
  PIN entry (A-02/H1, F1): a fresh warning held back while the owner types is postponed, no longer dropped. Amended
  the same day (decision 5): a warning that is up while the pad is open shows above the pad (Codex's codex-4 on
  `0920241`; the owner's ruling, option 1, "as long as armed for isn't removed").
- **Date:** 2026-10-26

## Context

While the disarm PIN pad is open and a key was pressed in the last 20 s (opening the pad, a deliberate 5-second hold,
counts as the first keypress), a fresh tamper warning does not start and the capture flash does not fire: both would
fight the raised pad brightness while the owner types (A-02; narrowed to actual typing by F1). The rule
(`MonitoringEngine.alertAction`) was applied once, when a trip's capture ended, and a warning it held back was never
shown: closing the pad without a PIN (Cancel, or its 30 s timeout) restored the screen and proximity only. The hold
that opens the pad is itself a Touch trip, so in Alert mode with a fixed clip, whose capture ends a few seconds after
the pad opens, the incident that began with the hold never warned unless a later trip did; in Siren mode, a capture
that ended inside the window held the siren back the same way. Codex found it (codex-1 on `b7221cb`); Claude rated it
Medium: one incident's warning or siren, in one sequence; detection, capture, uploads and the other devices' alerts
were unaffected.

The options put to the owner: (a) show it when the quiet window ends or the pad closes without a correct PIN,
whichever is first; (b) only when the pad closes without a correct PIN; (c) keep the rule, and document that a warning
held back while the pad is in use is dropped.

## Decision

1. Where the rule held a fresh warning back over the owner's typing, it now answers "deferred"
   (`AlertAction.deferred`), and the engine remembers the warning as owed (`alertOwedAfterEntry`): at a capture's end,
   and for Alert mode's early warning during an Until clear clip.
2. The owed warning is shown when the quiet window ends with the pad still open, or when the pad closes without a
   correct PIN (Cancel or its timeout), whichever is first: option (a). The quiet window has no event of its own, so
   the PIN entry's coordinator marks its end with a timer, started when the pad opens and again at each keypress
   (`DisarmEntryCoordinator.scheduleQuietEnd`); the engine shows the warning only when no keypress is recent
   (`presentOwedAlertIfDue`).
3. A correct PIN clears it with the rest of the watch. A warning already up when it comes due is kept alive instead,
   by the rule's "extend". Stealth owes none.
4. Unchanged: the capture flash is still skipped while the owner types and is not made up later (a later flash would
   tell whoever holds the phone that a photo is being taken); capture and uploads never wait; a running alarm is
   always kept alive; a sensor flood still only extends an alarm already up.
5. **While the pad is open, a warning that is up shows above it** (amended 2026-10-26, Codex's codex-4 on `0920241`;
   the owner's ruling: "1 as long as armed for isn't removed"). The armed screen draws the full-screen warning only
   while the pad is closed, so the keys are never covered. The warning decision 2 brings up when the quiet window ends
   came up under an open pad, ran out there (8 s in Alert mode), and the pad's own timeout then found nothing owed;
   a new trip's warning on a pad nobody was typing on (A-02's idle pad) was hidden the same way, before this record.
   Now a row between the armed time, which stays, and the pad shows a red shield and the warning's message (the
   owner's, or an escalation's), the keys clear (`ArmedView.padWarning`). Its text stops growing where the full-screen
   warning's does; a long message of the owner's own shrinks, then stops at four lines. The full-screen warning, with
   the whole message, returns if the pad closes while the warning is still up. A warning already up when the pad
   opens (the one from the owner's own hold) shows in that row too, for the rest of its time. The options not taken:
   the pad gives way (a warning that comes due closes the pad, 10 s before its own timeout), and a warning's time
   starting once it can be seen (shown only when the pad closes).

## Consequences

- Whoever opens the pad and does not enter the correct PIN gets the warning (in Siren mode, the siren) for an incident
  that ended while the pad was in use: 20 s after the last keypress at most, or when the pad closes. Someone tapping
  keys can still hold it back for as long as they keep tapping, up to the pad's lifetime (about 150 s), and gets it
  when the pad closes.
- An owner who stops typing for 20 s mid-entry sees the warning come up above the pad (decision 5), as a new trip's
  warning now does on an idle open pad.
- Not taken: (b), which shows nothing to someone who opened the pad and put the phone down until the pad's own
  timeout, 10 s after (a) (with either, someone who keeps tapping keys holds the warning back until the pad closes;
  when the options were put, that cost was wrongly given to (b) alone); (c), which left the Alert caption ("then a
  warning appears on screen") untrue in this sequence.
- SECURITY.md's paragraph on PIN entry gains a sentence (public wording: the owner approves it).
- Tests: `Item167ReviewTests` (the pad closing without a PIN, the window ending, a keypress moving its end, a repaint
  while the owner may be typing, Until clear's early warning; controls: a correct PIN and the next watch, Stealth);
  `MonitoringEngineTests`'s rule test; item 152's control that no warning starts over the owner's typing keeps its pad
  open past its check. Decision 5: `Item167ReviewTests` drives the real armed screen, live through the sequence (the
  quiet window's end with the pad open, then the warning running out and the pad closing itself; a new trip on an
  idle open pad) and lays it out at the largest text size on the short screens (the message whole, every row above
  the pad's title, a 300-character message kept to four lines). Not covered: a phone's own timing (the tests compress
  the 20 s and 30 s windows), and the look on a phone: the tests check where the rows lie, not how they read.
