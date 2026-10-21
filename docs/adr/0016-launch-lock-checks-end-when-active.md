# ADR 0016: A launch-time "locked" answer only waits, until the unlock or the app becoming active

- **Status:** accepted
- **Date:** 2026-09-26

## Context

1.3.2 made the launch recovery (the "Monitoring interrupted" record and the automatic re-arm
after an armed session ended without a clean disarm) wait for the unlock when
`UIApplication.isProtectedDataAvailable` reads false (item 65, finding 18). A push can launch
the app while the phone is locked. A record written then goes into an event log that cannot be
saved until the unlock, and is lost if iOS ends the app first.

The engine is built inside `MalinoisApp.init`, and there UIKit answers false even on an
unlocked phone. An unlocked phone sends no unlock notice, so the recovery waited for the next
lock and unlock with the app open. Item 84's test-isolation work found it: in the simulator,
the test app's own engine sat waiting for an unlock notice. The owner confirmed it on a phone
with the App Store 1.3.2 on 2026-09-26: reopening Malinois after it was killed while armed
started no countdown, and a lock and unlock then did. With Guided Access, the way the app is
meant to be used, a crash while armed brought the app back disarmed with no record, and after
a force-restart the "restarted while armed" record and the re-arm waited.

Three options were put to the owner:
1. end the wait when the app becomes active;
2. also let the event log answer at startup, since it can read its file only when the phone is
   unlocked;
3. go back to 1.3.1's recovery at startup.

The owner ruled that arming without Guided Access is not proper use. The options were
therefore compared on Guided Access cases, where they differ in only one case: a notification
waking the app in the background after the owner unlocks a restarted phone, before opening
Malinois. Ruling: option 1 ("Check when on screen").

## Decision

1. **A "locked" answer at launch only defers.** Launch-time work that reads
   `isProtectedDataAvailable` as false waits until whichever comes first:
   - the unlock notice, after which the answer is checked again;
   - the app becoming active (`UIApplication.didBecomeActiveNotification`). An app on screen
     means an unlocked phone, so UIKit is not asked again.
2. **It runs once.** The first of the two notices removes both observers. A second run of the
   recovery would find the recovery countdown's own marker and record it as a new interruption.
3. **The same rule applies to any other launch-time lock check.** The event log has one: a
   damaged log at launch is taken for a locked phone. That is item 86, for 1.4. Applied
   2026-09-28 (item 86), then revised the same day after review: the log does NOT take the
   active app to mean unlocked. A lock-screen notification tap can make the app active an
   instant before Data Protection's keys arrive (the app's own record in KeychainService and
   RootView, found live 2026-08-30), and setting a still-sealed, healthy log aside there would
   strand it (V-01). The log tells the cases apart by what can be read instead: bytes that
   read but do not decode are damaged whatever the lock state and are set aside at once;
   bytes that cannot be read wait, and the unlock notice and the app becoming active both
   only try again, setting the file aside once UIKit says the phone is unlocked. The
   engine's recovery keeps this decision's rule: a record it writes in that instant is
   queued by the store, which is still waiting, and saved once the log can be read.

## Consequences

- Opening Malinois after a crash, a kill or a restart recovers straight away, as in 1.3.1. A
  notification that wakes the app while the phone is locked still leaves the recovery waiting
  for the unlock, so finding 18's protection stays.
- One gap is accepted. When a notification wakes the app in the background on an unlocked
  phone, the record waits until the app is opened or the phone is next unlocked. 1.3.1 wrote it
  at once and, on Pro, alerted the owner's other devices.
- Not taken:
  - option 2, which closes that gap at the cost of a little more change;
  - option 3, which reopens finding 18.
- The test app's own engine now runs its recovery when the test app becomes active at launch,
  so it no longer waits for, and races, the unlock notice that item 77's locked-launch test
  sends. Item 84 removes the test app's engine from test runs altogether.
- Found by the 2026-09-28 review (item 88): once the recovery could wait, two paths that act on
  the same persisted flags could run before it, both written when it always ran inside `init`.
  The entitlement hook re-armed an owed session first, and the recovery then read that
  countdown's own marker as a killed countdown and recorded a false interruption; the foreground
  pass cleared the "lapse already logged" flag first, and the recovery then recorded the same
  lapse twice. The foreground pass now runs a still-waiting recovery first, and the entitlement
  hook leaves an owed re-arm to it.
