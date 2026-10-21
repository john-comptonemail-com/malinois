# ADR 0019: A change to the protection settings leaves a record

- **Status:** accepted
- **Date:** 2026-09-28

## Context

Settings is behind the PIN, and it is a write surface: a PIN-holder can weaken the owner's next
session without disarming anything, by switching a tripwire off (the Camera tripwire included,
which turns every capture off, the disarm hold's and a wrong PIN's too), dropping the Guided
Access requirement, silencing the other devices' alerts or turning the jamming response off.
Review 1 (2026-09-06, finding F3) found that nothing recorded such a change; SECURITY.md has said
so since 1.3.1, and the owner queued the record for 1.4. The 1.4 review (item 89, A1) met the
same gap through the Camera tripwire, and the owner ruled it built (2026-09-28).

## Decision

1. **The protection settings** are review 1's list: each switchable tripwire (Touch cannot be
   switched off, ADR 0015), Require Guided Access, alerts to the owner's other devices, and the
   jamming response. Everything else in Settings (sensitivities, the capture mode, the siren's
   ramp, the alert's words) changes how evidence looks, not whether it is taken or sent.
2. **One audit record per change,** weakening or restoring, in the words of the log ("Camera
   switched off in Settings"), carried as a state kind (`settingOff.<name>` / `settingOn.<name>`)
   in the existing audit record: no new CloudKit field, no schema deploy. A build that predates
   a kind drops it, as it drops any kind it does not know.
3. **When:** Settings closing compares the settings with the last recorded state; so does every
   arm, so a change is on the record before the next session even if the app ended with
   Settings open. A switch turned off and on again within one visit leaves nothing. The first
   launch with this feature adopts the existing settings before any Settings visit can change
   them, without adding an audit row. A valid saved baseline survives later launches unchanged;
   a missing or unreadable baseline is adopted at launch.
4. **Like the other audit records:** never counted as new on Home, never an alert, pushed to
   iCloud on Pro.

## Consequences

- A PIN-holder can still weaken the configuration, but not unseen: the change is in the log and,
  on Pro, in iCloud, where it cannot be removed from the app.
- The owner's own changes are recorded too; that is the point of an audit trail.
- The record says when the change reached the log, not the instant the switch moved: at the
  latest, the next arm.
- Not taken: photographing the disarm and wrong PINs whatever the Camera tripwire says (it would
  overrule a choice the owner may have made for privacy), and recording every setting.

## D6 correction — 2026-09-30

The first implementation adopted its baseline only when Settings closed or an arm began.
The owner's phone check found the first weakening was missing but the restoration was logged:
the first edit had already happened when it became the baseline. Engine construction now
establishes a missing or unreadable baseline before editing is possible, preserving an existing
one. This corrects the intended first-launch adoption rule above; it adds no new record kind,
CloudKit field, alert or settings permission. Regression tests fail before the fix and pass
after it, including a first-visit undo and an unreported edit across relaunch.
