# ADR 0014: A wrong disarm PIN is a record; the right one is not

- **Status:** accepted
- **Date:** 2026-09-26
- **Amended 2026-10-27** (1.8.2, BACKLOG 168's deepseek-5): decision 3 stands for the armed
  screen's pad. On the automatic re-arm's countdown, which only the PIN stops (R-04), the right
  PIN leaves the cancelled countdown's record ("Arming cancelled before going live"), pushed on Pro
  as one: no watch went live, so no "disarmed" record says when it stopped. Wrong PINs there stay
  lockout-only (decision 5).

## Context

An armed session is a genuine credential surface left in front of whoever finds the phone:
the 5-second hold opens the PIN pad, and the pad is the one thing standing between them and
stopping the watch. Until 1.4 a wrong PIN fed only the Keychain lockout. No record, no
capture, no alert: the attempt to defeat the alarm, the clearest sign of intent the app can
see, was invisible in the log, and with the Touch tripwire off a disarm left no photograph at
all.

Two constraints shaped the answer. The cross-device alert is a CloudKit subscription that
fires a static "Tamper detected" on the creation of **every** tamper record (predicate true;
the fields are encrypted, so no predicate can tell records apart). And the lockout (five quick
failures, then 30 s doubling to an hour) already caps how fast anyone can type.

The owner's rulings (2026-09-26, both on the recommendation): "No, wrong PINs only" and
"Alert every time".

## Decision

1. **Each wrong PIN on the armed screen's pad is a tamper record** — a Touch row (the typing)
   carrying `wrongPINCount`, read as "Wrong PIN entered". It goes through the trigger response
   like any trip: the fact first, pushed and alerted at once, typos included; then one still
   from the **front** camera, whatever the capture settings say (the typist faces the screen,
   and a still lands while they are there). The photo follows the Camera tripwire; nothing
   else gates it.
2. **An attempt while a capture is running joins that record**, like any trip during a capture;
   its count rides the record, and stays on it even when the right PIN lands before the capture
   ends (the response finishes after a disarm and folds it — a PIN-holder's fumble is kept).
   One record per attempt otherwise — no coalescing rule, since the lockout already bounds the
   rate.
3. **The right PIN adds no record.** The "disarmed" audit record and the disarm alert already
   say when and where.
4. **Unchanged:** the lockout (the engine never touches it); the presentation rule, so no fresh
   alarm or flash starts over the owner's typing (A-02); attribution, so an attempt followed by
   the right PIN in the same pad session is flagged owner-attributed and kept (R-02).
5. **Armed sessions only.** The Home gate, the change-PIN gate and the other pads stay
   lockout-only: a camera capture while disarmed would widen the camera's purpose beyond
   armed evidence.
6. **The count travels in the payload** (`wrongPINCount`, bounded 1–1,000 on the way in), and a
   mirror accepts a copy of the same revision that counts more attempts, the flood count's rule.
   A build that predates the field reads the record as a Touch row.

## Consequences

- Someone trying PINs leaves a photographed record per attempt, on the device and — on Pro —
  pushed to iCloud and the owner's other devices the moment it is recorded, before the photo.
- The owner's own typos alert the other devices with the same "Tamper detected" wording. Item
  76's notification extension is where that improves: it can name the attempt ("Wrong PIN
  entered on <device>") and soften a single typo.
- A PIN-holder who disarms cleanly with Touch off still leaves the record but no photograph;
  a record per correct PIN would have put the owner's face in the log at every disarm and
  alerted the other devices each time. (Closed the same day by ADR 0015: Touch is always on,
  so the hold that opens the pad is always recorded. Correction, 2026-09-28 review (item 89):
  it is photographed only while the camera is on; the Camera switch in Settings, behind the
  PIN, turns every capture off, this one and a wrong PIN's included, and the change leaves no
  record yet.)
- Not done: a dedicated record type and subscription with its own wording ("Someone is trying
  to disarm …") — a Production schema deploy for what item 76 can do without one; withholding
  the first wrong PIN's upload to spare typos — a thief who tries once and switches the phone
  off would leave nothing in iCloud.
