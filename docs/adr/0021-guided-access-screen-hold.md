# ADR 0021: Disarmed under Guided Access, the screen stays on for ten minutes

- **Status:** accepted
- **Date:** 2026-09-29

## Context

Malinois holds the display awake from the ARM tap to the disarm (`keepsDeviceAwake`, item 27):
a phone that locks suspends the app, and calibration and the watch need it running. Disarmed,
it handed auto-lock back to iOS at once, because silently holding the display awake all day is
the opposite failure.

Under Guided Access, iOS can wake a phone that slept into the notification pull-down with every
dismissal gesture blocked; only the triple-click and the Guided Access passcode get out (README,
*Known iOS quirks*; device checklist C6, found by the owner 2026-08-28). Armed, it cannot
happen. Disarmed under Guided Access it can: Guided Access started on the Home screen before
ARM, a cancelled countdown, or the minutes after a disarm. The owner met it again on 2026-09-29,
with the phone stood up and unplugged, and asked whether Malinois should hold the screen on.

Three options were put to the owner:
1. hold the screen on whenever Guided Access is on;
2. hold it on for ten minutes after each moment that begins the disarmed Guided Access state,
   then let iOS sleep it as before;
3. no app change: correct the README's steps, which said to start Guided Access before ARM, and
   point to iOS's own Display Auto-Lock setting for Guided Access.

Option 1 covers every path, but a phone left in Guided Access after a disarm stays lit until
the battery runs out, and a disarmed phone stays awake on Malinois, not asleep and locked, for
as long as Guided Access is on. Ruling: option 2, with option 3's README
correction (the owner, 2026-09-29: "I agree with your recommendation").

## Decision

1. **Disarmed under Guided Access, auto-lock stays off for ten minutes**
   (`EngineTiming.guidedAccessScreenHold`) after each of: Guided Access coming on while
   disarmed; the end of a disarm, a cancelled countdown included; the app becoming active while
   disarmed under Guided Access (a wake after a sleep, or a launch into a session). Each one
   starts the ten minutes again.
2. **The hold ends on its timer or when Guided Access goes off**, whichever comes first. With
   Guided Access off nothing is held, whatever the timer says (`keepsDeviceAwake`).
3. **Every other state is unchanged.** From the ARM tap to the disarm the display is held awake
   as before, and a hold that runs out during the arming flow changes nothing.
4. **One rule sets the flag.** The disarm hands auto-lock back through `refreshIdleTimer` once
   the state is `.disarmed`, instead of writing the flag directly.

## Consequences

- The stuck screen cannot happen through auto-lock in the ten minutes after Guided Access
  starts or a disarm, which covers setting the phone up and arming. After them it can, as
  before, so the README still says to arm before setting the phone down.
- For up to ten minutes, a disarmed phone left alone under Guided Access stays awake on
  Malinois's Home screen instead of going to sleep and locking. The Guided Access passcode
  still keeps anyone inside Malinois, and the Malinois PIN still guards the Event Log, Settings
  and the sensor test; Home itself shows counts and times (the new records, the last watch),
  never the evidence. SECURITY.md says so.
- A phone forgotten in Guided Access costs ten minutes of lit screen, not the battery.
- Device evidence (2026-09-30, owner, Air / iOS 27.0, 1.4 candidate): face down stayed awake
  for more than one minute during the hold. The upright and post-disarm holds each lasted ten
  minutes; ending Guided Access restored 30-second auto-lock, with no stuck screen in any part.
  Immediate face-down sleep did not reproduce in that configuration. Other iOS versions and
  sleep paths remain unverified; the README retains the wake-trap recovery advice.
- Not taken: holding the screen on whenever Guided Access is on (option 1); dimming the screen
  after a while instead of letting it sleep, which would add to the brightness rules for the
  sake of an iOS bug.
