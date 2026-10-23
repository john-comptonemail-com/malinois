# ADR 0057: The log records a PIN change and Guided Access ending during a watch

- **Status:** accepted
- **Date:** 2026-10-22

## Context

The log is the owner's record of what happened to the phone, and its quiet status entries (the
silent audit type of BACKLOG 8: "armed", "disarmed", "gaLifted", the protection changes of ADR
0019, "reinstalled") are what the holder of one credential cannot do without leaving a trace. Two
things left none. Settings' Change PIN verified the current PIN and stored the new one with nothing
written, so a PIN-holder could lock the owner out, and the owner's recovery, a reinstall, removed
the log that would have shown when (the second independent audit's MAL-03, BACKLOG 153). And Guided
Access ending while the watch was live, which under Guided Access takes its passcode, only reset
the screen-awake hold: the earliest sign of a passcode-holder, given while the phone is still
online, before the Airplane Mode, the backgrounding and the app deletion such a person goes on to
(MAL-05). The later backgrounding is recorded, as SECURITY.md says, but cannot upload offline.

## Decision

1. Settings' Change PIN writes one "pinChanged" status entry when the new PIN is saved, after the
   current PIN was entered (`MonitoringEngine.notePINChanged`, called by `ChangePINView` before it
   dismisses). The recovery flows keep their own record ("reinstalled", ADR 0040's recognised
   reinstall) or none (a damaged credential).
2. Guided Access going from on to off while the watch is live (armed, triggered, or the calibration
   review, when the sensors already watch; not while disarmed, not during the countdown, which is
   the owner's) writes one "guidedAccessEnded" status
   entry (`noteGuidedAccessChange`, from `guidedAccessEnabled`'s observer), at iOS's notice or at
   the resume re-sample when the change happened while the app was suspended. The watch keeps
   running. Off to on writes nothing; a re-sample with the same value writes nothing; each ending
   writes once.
3. Both ride the silent audit type like "disarmed": allow-listed in the cloud decoder, with their
   log sentences and icons, uploaded on Pro with iCloud backup on, so the owner's other devices
   hold them at their next pull; no alert from iCloud, nothing relayed to the watch.

## Consequences

- A PIN-holder who changes the PIN leaves the time of it in the log and, on Pro, on the owner's
  other devices. The owner's reinstall route is unchanged: a "Forgot PIN?" at Home behind device
  authentication was not taken, because it would let an iPhone-passcode holder replace the PIN
  without destroying the log they then open, the boundary ADR 0040 keeps.
- Whoever ends Guided Access during a watch leaves a record, written while the phone is online.
  The record does not name the credential: Guided Access can be ended with Face ID or Touch ID
  when its settings allow it, and the app sees only the flag (the fresh review of 1.8.1, BACKLOG
  155's A7; the sentence first said "with its passcode"). Not taken for now: an alert-bearing form (a signal with its
  own wording, like the disarm signal); the record is quiet, for 1.8.2's consideration.
- Not recorded: Guided Access ending during the countdown (the owner setting up), or an ending the
  app never sees (a force restart kills it; the launch recovery records that interruption).
- The decoder's allow-list, the log's sentence and icon tables and the fuzz test's written kinds
  each gain two rows. A build older than 1.8.1 drops both kinds unread, as it drops any kind it
  does not know.

Amended 2026-10-23 (1.8.1, BACKLOG 155's A6 and A7): the record covers the calibration review, the
six seconds after calibration when the sensors already watch and the arm cannot be cancelled; it used
to need the armed or triggered state, so an ending during the review left nothing. And its sentence
is "Guided Access ended while armed; the watch kept running": the credential is not known.
