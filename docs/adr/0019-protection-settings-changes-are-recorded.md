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

## Amendment (2026-10-24, 1.8.2): seven more settings leave a record

Decision 1 left out settings that change whether the next session catches or tells anything: a quieter response mode,
a lower sensitivity, a longer grace period, the camera cold on battery, no illumination, Face ID unlock and a shorter
iCloud retention (BACKLOG 153's MAL-09, item 155's A15; SECURITY.md said so). The owner took all seven (item 163's
step 22). Each change now leaves one record the same way (decisions 2 to 4), in the order of the Settings screen:
switched on or off for Face ID unlock (`settingOn.biometricUnlock`; its "off" does not say "in Settings", since it also
switches off by itself when the enrolled faces or fingers change, ADR 0056), and set to a value for the others
(`settingSet.<name>.<value>`: "Response mode set to Stealth (covert) in Settings"), sensitivity per tripwire where
Settings offers one. The iCloud decoder admits a value kind only with a value this build knows (a grace period as whole
seconds up to an hour), by the rule that gives the log its words. A baseline recorded before 1.8.2 lacks the seven:
none is compared with it, and launch fills them in as they are, without a record, so the first visit after the update
is still caught (decision 3's first look). The rest of Settings (the capture mode and lens, clip audio, the siren's
ramp, the alert's words, the PIN pad's scramble, the device's label) leaves no record. Tests:
`Item153SettingsRecordsTests`.

## Amendment (2026-10-24, 1.8.2): a settings reset is its own record

When the stored settings cannot be decoded, the launch resets them to their defaults (ADR 0049), and the next arm
compared those defaults with the surviving baseline: each difference became a record "in Settings" ("Arming grace
period set to 15 s in Settings"), an edit nobody made (Codex's codex-10). The owner ruled (2026-10-24, option (a)) that
the reset leaves its own record instead, "Settings couldn't be read and were reset to their defaults", once, when the
settings resolve (`AppSettings.wasResetAtLoad`, per loaded object), and that the reset settings become the baseline
then, so the records after it show only real edits. The record is a quiet status entry like the others: uploaded on
Pro, no alert, read back by the owner's other devices. With iCloud backup off it stays on the phone for good, as every
record made then does: the engine installs the backup-off rules before the settings can resolve, since a launch's
resolution writes this record at once (Codex's codex-12 found it written first, bound to the account and sent once
backup was on). The reset is noted as it saves the defaults, before they are saved (`AppSettings.resetPendingKey`), and
the note goes once the record and the baseline are written: the app ending in between leaves the next launch owing
them rather than reading the saved defaults as the owner's (Codex's residual of codex-10). The note holds the record's
identity, which the record takes: only that record stands for the reset, so one written before the app ended is not
written again, while another device's copy of its own reset, or an earlier reset dated ahead, never stands in (Codex's
codex-17 found a date check taking them). A note that holds no identity (a timestamp, as development builds of 1.8.2
wrote it, or damage) is given one before the record is written, so a retry finds that record too (codex-17's
residual). Tests: `Item163SettingsResetTests`.
