# ADR 0015: The Touch tripwire is always on

- **Status:** accepted
- **Date:** 2026-09-26

## Context

Every tripwire was a switch in Settings, Touch included. Touch is the one that fires on the act
of trying to use the phone: the armed screen is black, under Guided Access, and the only way
to reach the disarm pad is a 5-second hold on it. Nothing benign touches that screen — a touch
is a person — so switching Touch off never reduced false alarms; it only removed protection.

It also left a gap the 2026-09-06 review named (item 73, R5): someone who knows the PIN could
switch Touch off in Settings — a change no record shows until the planned settings-change
record — and later disarm without being photographed, because the hold that opens the pad is
photographed only as a touch trip. ADR 0014 made every wrong PIN a photographed record, but
the right PIN adds none (the owner's ruling), so the gap stayed open whenever Touch was off.

The owner, 2026-09-26: "I don't think we should be designing for scenarios where touch is
disabled as a tripwire, and am not sure it even makes sense to allow touch to be disabled
since it is the most critical of the tripwires." Three options were put to the owner — always
on; keep the switch and call "off" unsupported; keep it behind a warning — and the ruling was
"go with option 1".

## Decision

1. **Touch has no switch.** Settings shows it as "Always on" with one line saying why.
2. **The rule is one pure function**, `AppSettings.withTouch(_:)`, which adds Touch to any set of
   tripwires and changes nothing else. It holds in three places (ADR 0012's pattern): whenever
   `enabledSensors` changes, so the stored set always holds Touch; when a save is loaded, so an
   install that switched Touch off before this build gets it back once, at the update, with
   every other choice kept; and at arm (`effectiveSensors`), with or without Pro.
3. **Nothing asks the setting any more:** the armed screen reports every press-down as a touch
   trip, and Test Sensors counts every tap on its pad.

## Consequences

- The hold that opens the disarm pad is always a touch trip, so whoever disarms is always
  recorded, photographed while the camera is on (a 3-second front clip by default), and the
  right PIN attributes it to the owner (R-02). ADR 0014's Touch-off residual is gone. Correction,
  2026-09-28 review (item 89): item 73's R5 is narrowed, not closed. The Camera switch in
  Settings, behind the PIN and not recorded, still turns the photograph off: the same gap the
  Touch switch left, now through the Camera switch. Whether the disarm-hold and wrong-PIN stills should ignore it,
  or turning it off should leave a record, is the owner's call (item 89, A1).
- The free tier can no longer be inert: `hasActiveTripwire` is always true, and the Home
  warning for "no tripwire on" (F-23) cannot show. It stays in the code as a guard.
- A setup that produces false touches has no way out. None has been reported, and no common
  cause is known on a black screen; a report would reopen this.
- Not done: a warning in front of the switch, or an "unsupported" note — both leave the gap
  open for anyone who turns Touch off.
