# ADR 0047: An "iCloud backup" switch that needs device authentication to turn off

- **Status:** accepted (the owner, 2026-10-13: item 108's decision 4, option C, "an 'iCloud backup' switch
  (needing device-owner authentication to turn off) later"; on events recorded while it is off, option a).
  For 1.7 (BACKLOG 115). **Amended 2026-10-14** after Codex's review of 1.7 (BACKLOG 116) showed the switch did
  not hold: decisions 2 to 5 now say how it is enforced, and the path inventory below lists every place it
  applies. The owner's rulings that day: kept events are also registered to no account (R3, option 1); the
  paired watch keeps its direct alerts (R8, option 1). Codex's second look the same day found eight of the
  ten fixed; its N1 (a lost sweep request) is fixed in decision 5.
- **Date:** 2026-10-13; amended 2026-10-14
- **See also:** ADR 0049 (1.8): what a settings reset does to the switch.

## Context

The 1.6 review's P-01 found that the privacy policy promised an in-app way to stop cloud use and none existed
after iCloud verification: the Cross-device alerts switch changes alerts, not uploads, and an enrolled Pro
install uploads every event. For 1.6 the policy was corrected to point at iOS's own iCloud switch for Malinois
(device-checked by the owner on 2026-10-13: uploads stop, and what was recorded meanwhile uploads once it is
back on). The owner chose to add the in-app switch later, with device authentication to turn it off so that
someone holding the unlocked phone cannot quietly stop evidence leaving it.

## Decision

1. **One switch, on by default.** `AppSettings.cloudBackup`, in Settings → iCloud (Pro). Settings saved before
   it existed read as on.
2. **Only while disarmed; off needs device authentication, on needs nothing.** Turning it off asks for Face ID,
   Touch ID or the passcode (`CloudEnrollment.deviceAuthentication`, which refuses under Guided Access, as for
   Cross-device alerts off since 1.5.1). The engine itself refuses a change unless disarmed
   (`setCloudBackup` returns false), and Settings checks its answer after the authentication too.
3. **Off is recorded before uploads stop.** The engine logs a `backupOff` status entry, then turns backup off.
   That entry is the one record allowed to upload while backup is off, and the sweep keeps retrying it, so the
   cloud log shows when it was turned off once it reaches iCloud. It is recorded and queued, not confirmed:
   an offline phone sends it later, and versions before 1.7 drop the kind when they read the cloud log.
4. **While off, nothing new uploads.** The engine's rule (`MonitoringEngine.backupAllows`) stands before every
   cloud write at its start (the evidence upload, the fast fact push, the owner-attribution re-push, the
   pending sweep's candidates and the heartbeat), and the uploader reads it again before every step, after
   each wait: `CloudExfiltrator.mayUpload` (ownership and the switch together) before the metadata, each photo
   or clip and each status record, and `save`'s `permitted` before every attempt, so a retry after off never
   goes out (R2). An upload under way when backup goes off stops at its next step; what CloudKit has already
   accepted is not recalled, and nothing is cancelled mid-transfer (that would cancel the `backupOff` entry's
   own upload too). Alerts to other devices through iCloud come from uploaded records, so this phone raises
   none while off; alerts from other devices still arrive. The paired watch's direct relay (WatchConnectivity,
   no iCloud) carries on, and the switch's text says so (R8, the owner's ruling). Retention clean-up of
   existing cloud copies keeps to its own setting.
5. **Recorded while off, kept for good, in two independent ways.** The event store marks every event added
   while backup is off (`Event.keptLocal`), and the mark survives every whole-value write-back
   (`EventStore.preservingMonotonicFields`; R1). The enrollment also registers such an event to no account
   (`CloudEnrollment.holdsNewEventsLocal`), the hold for unknown-account evidence that every version since
   1.5.1 keeps, so `authorizeUpload` refuses it here and in 1.6 or 1.5.1 installed over 1.7, which ignore the
   mark (R3). Such an event never uploads, even after backup is turned back on (option a, chosen over
   uploading it then, as iOS's switch does). The Event Log shows it among events held on this device, with the
   reason (`UploadHoldReason.backupOff`; an older version calls it an unknown account), Retry never offers it,
   and item 114's marker does not count it as a missed upload. Events recorded before backup was turned off
   upload when it is back on: turning it on logs `backupOn` and asks for a sweep that is never lost: with
   none running one starts, and with one running another is owed and starts when it ends, however long it
   runs (`sweepAfterTheRunningOne`; R4, and N1 of Codex's second look, which replaced a ten-minute wait).
6. **Nothing is deleted.** Existing iCloud copies stay; deleting them remains iOS's Manage Storage.

## Path inventory

Every cloud write, and how the switch applies (checked in the code, 2026-10-14):

| Write | Path | Switch |
| --- | --- | --- |
| Tamper metadata: the fast fact, the full record, the owner-attribution re-push | `pushFact`, `exfiltrateNow` → `pushMetaRecord` → `save` | engine gate at the start; `mayUpload` after the lease, after the queue wait and in `pushMetaRecord`; `save` before each attempt |
| Full-resolution photos and clips, each camera | `pushPhotoRecord` → `save` | `mayUpload` before each file; `save` before each attempt |
| Status records (arm, disarm, heat, clock, backup off and on, and the rest) | `pushStateChange` → `save` | `mayUpload` after the lease and after the queue wait; `save` before each attempt; `backupOff` is the exception |
| The disarm signal behind a disarm record | `pushStateChange` → `save` | `save` before each attempt |
| Heartbeat records | `pushBeat` | none created while off (`beat()`); `backupOn` after the account wait |
| Retention deletes (full media, heartbeat trails) | `purgeFullMedia`, `trimBeatTrails` | not gated: retention keeps its own setting |
| Alert subscriptions (save, delete) | `ensureSubscription`, `removeSubscription` | not gated: account-wide alert controls, not this phone's evidence |
| Paired-watch alerts (not iCloud) | `WatchAlertRelay` over WatchConnectivity | not gated: the owner's ruling |

Where an event's hold lives: `Event.keptLocal` (set in `EventStore.add`; kept by `update` through
`preservingMonotonicFields`; a first-hand event is never replaced in `merged` or unlock reconciliation; the
journal and the saved log carry it), and the account register (`CloudEnrollment.register`, an empty binding,
never rebound). Older versions: 1.6 and 1.5.1 drop `keptLocal` and `cloudBackup` when they decode, and keep
the register's hold.

## Consequences

- The privacy policy, the support page, README and SECURITY.md describe the switch; the policy's effective date
  changes when 1.7's policy is published.
- An attacker who knows the passcode can still turn backup off, but not silently once the `backupOff` entry
  reaches iCloud. One who does not cannot turn it off at all.
- A kept event can still leave the phone through the owner's own Share, or in a device backup, which
  is a separate copy mechanism (SECURITY.md).
- Going back to an older version (TestFlight testers only; the App Store offers none): 1.6 and 1.5.1 have no
  switch, so what they record uploads; kept events stay held; and their settings drop the switch, so back on
  1.7 it may read as on again: check it.
- Paths not taken: uploading kept events once backup returns (option b); a switch without authentication; a
  delete-from-iCloud action; cancelling transfers under way at off; stopping the paired watch's direct alerts
  while off (R8, option 2).
