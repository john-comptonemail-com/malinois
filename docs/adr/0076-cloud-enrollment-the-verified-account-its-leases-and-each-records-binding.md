# ADR 0076: Cloud enrollment: the verified account, its leases and each record's binding

- **Status:** accepted: the owner's rulings on ADR 0039 (1.5.1, 2026-10-11: option B of the reinstall recovery
  options) and on the fifteen sections added to it after its decision (1.5.1 to 1.10, 2026-10-11 to 2026-10-30), with
  ADR 0045's change to the alert extension, as they stand in 1.11 (83). It states the design those sections built one
  review at a time (BACKLOG item 186; the owner, 2026-11-01: "a, rule approved"); ADR 0039 keeps its decision as made.
  Each defect, the review that found it and the ruling: the BACKLOG items named below.
- **Date:** 2026-11-04
- **Summary:** An installation uses iCloud only after the owner verifies it with Face ID, Touch ID or the passcode; each
  record uploads only to the account it was bound to when it was made, and a restored record is held.

## Context

Deleting and reinstalling the app must not turn a new app PIN into access to the old iCloud evidence, and a phone
restored from a backup, or signed into another iCloud account, must not upload one account's evidence to another or
read another's. ADR 0039 (1.5.1) decided that the owner verifies each installation and iCloud account with iOS's
device-owner authentication, that every iCloud step needs a lease on the verified account, and that each record is
bound to an account when it is made. Fifteen sections followed, from reviews, audits and the owner's reports: the
screens' words, a temporary iCloud answer that is not an account change, the iCloud-copies check, the bindings' size
and durability, a restore that holds every restored record, the alert switch's "off", and a restored record's reads.
This record states the design they built, as it stands; ADR 0039 lists them, each with the section here that states it
now.

The design holds against someone who knows the app PIN, or sets a new one after a reinstall, but cannot pass the
device-owner check; against a restore from a device backup, which leaves the grant's file out; against a change of
iCloud account; and against a network that answers nothing or answers late. It decides which iCloud account an
installation may use: it does not say who made a record (evidence signing, from ADR 0065 on, signs this phone's
records), it revokes nothing on a server, and it does not hold against a modified client, an older build, a
compromised iOS or deletion through Apple's own controls (ADR 0039). How an upload's writes are ordered and timed,
ADR 0075 states.

## Decision

### 1. The grant

- One file, `Application Support/CloudEnrollment/state.json`, holds the account this installation is verified for,
  each record's account binding (section 4) and the restore's notes (section 6). It is written atomically, protected
  until the first unlock after a restart, excluded from device backups, and synced to the storage medium before the
  write returns (`F_FULLFSYNC`; item 153's MAL-07); a sync that fails is logged, and the state written then survives a
  kill, not a power cut. It goes with the app when the app is deleted, and nothing in the Keychain recreates it.
- A file that cannot be read (before the first unlock after a restart, corrupt, or of a later version) grants nothing
  and is never overwritten: it is read again at its next use. A write that fails grants nothing and invalidates the
  account in use.
- The owner verifies with Settings' Verify iCloud access, while disarmed and with the app active: Face ID, Touch ID or
  the passcode (`deviceOwnerAuthentication`), then a second lookup that must name the same account under the same
  generation (`CloudEnrollment.enroll`). A device without a passcode cannot verify, and cancelling or failing changes
  nothing. Under Guided Access iOS holds that sheet until Guided Access ends, so the check refuses at once: Settings
  greys the button out and says why, and a verification that fails with Guided Access on says so (item 135).
- No background path shows an authentication prompt.

### 2. Leases

- Every iCloud entry point first resolves the account's identity (`fetchUserRecordID`, within 10 s) and takes a lease
  (`acquireCloudLease`): the account and the current generation (`CloudEnrollment.Lease`), given only for the account
  this installation is verified for. Queued work, retries and returned results keep the lease they began with, and
  every step after a wait checks that it is still current (`isCurrent`).
- A lookup that names another account than the one resolved before, iCloud's answer that there is no account, and
  iOS's account-changed notice invalidate: a new generation, every lease in flight void and every operation under way
  cancelled (`invalidateAccountResolution`). Section 3 says what a temporary answer does.
- An identity failure is never permission: no lease is given on it.
- Another account named while this installation is verified for one is noted in the file (`observedDifferentAccount`):
  records made from then on are held (section 4), until the verified account is named again or the new one is
  verified. Verifying the new account adopts no record already held.
- Turning cross-device alerts off, which removes them for the whole account, always needs a new device-owner check,
  even on a verified installation, and the same account before and after it; the saved choice changes only once
  CloudKit reports the change (`authorizeAccountControl`, `setCrossDeviceAlerts`). The automatic setups, at the arm
  and when a network path comes back, only create. A change made with the switch, begun or ended since a setup began
  or under way when it reaches a step, supersedes the setup: it saves nothing more (`automaticSetupWanted`; item 165's
  A3). A subscription save already sent when the owner turns alerts off can still land after the removal.

### 3. A temporary answer is not an account change

- The identity lookup tells its answers apart (`CloudExfiltrator.identityLookup`). A name resolves the account.
  iCloud's answer that there is none (`.notAuthenticated`, or no name) invalidates, and so does anything unclassified.
  A transient failure denies only its caller's request and goes on record for the pending sweep, with the server's wait
  when it named one, leaving every lease, every save under way and the verified state as they are. Transient: the
  network class, a bare transport error, the 10 s deadline, Apple's throttles and outages, and an account that is
  there but not ready yet (`accountTemporarilyUnavailable`) (item 152's lead 1, item 155's A3 and S2).
- iOS's account status, which Home and Settings refresh, follows the same rule (`applyAccountStatus`): no account or
  restricted invalidates; any other answer that is not ready (temporarily unavailable, could not determine, an error,
  its own 10 s deadline) only goes on record for the sweep (item 155's A2).
- An evidence push denied by a transient lookup gives the escalation (ADR 0001) that failure's class: the network
  class reads as interference; a throttle, an outage or an account not ready yet as a refusal, which Home shows and
  which never sounds the jamming siren. A push held by its record's binding gives no verdict. The pending sweep's own
  lookup: ADR 0075, section 5.

### 4. Each record's binding

- Each record this phone makes, and each watch's heartbeat session, is bound to an account when it is made
  (`registerLocalEvent`, `registerSession`), before its journal line and before any capture or upload: to the verified
  account; or to none, an empty binding that holds it for good, before the first verification, after another account
  was seen (section 2) or while iCloud backup is off (ADR 0047). Nothing binds a record later, at an upload.
- A record uploads only to the account it is bound to, under a current lease (`authorizeUpload`); a copy from another
  device never uploads.
- A verified installation that is offline, or relaunched before iCloud answers, binds new records to its verified
  account, and they upload once iCloud names that account again (`newEventsBindToVerifiedAccount`, the rule binding
  follows).
- Each copy a fetch brings is bound to the account that supplied it (`registerRemoteEvents`), and the file is written
  only when a copy is new (item 152's lead 20). A fetch's results count only under a lease still current, and only for
  records the lease's account may read (section 5).
- Once the complete log has been read, at launch and when the app comes back to the foreground, the bindings no record
  needs any longer are pruned (`pruneBindings`; item 153's MAL-08). Kept: the log's records (its own and copies),
  uploads under way, the bindings work still uses (fact pushes waiting their turn, and a capture from its record's
  registration until its upload ends), the live flood's record, the event limit's removals that the unsynced-removal
  marker has not read yet (item 114), the Pro watches whose heartbeat trails iCloud may still hold, and the live watch.
  A log not read from disk prunes nothing. A held record the log still holds keeps its empty binding; a record gone
  from the log that comes back from iCloud comes back as a copy, bound to the account that supplies it.

### 5. Reads

- Every read goes to the verified account's own iCloud, under its lease. A record this phone made is read only by the
  account it is bound to, and another device's copy by the account that supplied it (`authorizeRecord`), so a record
  held because nothing could upload when it was made refuses a copy under its ID. A restored record is section 6's.
- The alert extensions read no record and hold no entitlement for the container (ADR 0017's decision 5 ended in 1.8):
  they cannot check this installation's grant. The iPhone's shows the subscription's alert as sent, with two changes,
  each decided from the push alone: a tamper alert is Time Sensitive (ADR 0045), and one of a burst arrives quietly,
  in words that say so (ADR 0061). The watch's does the same for iCloud's alerts (ADR 0052). Device and sensor wording
  waits for a shared authorization design (ADR 0039); the app shares no storage with its extensions.

### 6. A restore, and records older than 1.5.1

- The grant's file is excluded from device backups, so a phone restored from its backup has neither the grant nor the
  bindings. Once a complete log is readable, a one-time rebuild holds every first-hand record the log holds, tied to
  no account, whatever its history, and notes each as restored, its upload history unknown, in the same write as its
  binding (`holdRestoredEvents`, `restoredHolds`; item 163's codex-7, item 166's codex-29 and codex-31; the owner's
  rulings (a), hold rather than guess). Other devices' copies are left unbound, for the next fetch from the verified
  account to bind. An update from before 1.5.1 runs the same rebuild. A binding already there is never relabelled.
- A restored record never uploads to any account; Share still saves a copy elsewhere. The byte limit never marks such
  a capture lost at once (ADR 0006's codex-24 amendment), nor one with no binding at all, as a restored record has
  until the rebuild runs (`uploadHistoryUnknown`; item 166's codex-32). A record that the seeding of 1.8.1 or earlier
  tied to no account carries no note and can be marked: a known limit, which SECURITY.md states.
- A restored record makes no claim of its own for a read: as for a record another device made, the account that
  supplied a copy under its ID reads it, and before any copy was seen there is nothing to read (item 180's A6; the
  owner's ruling (a), 2026-10-30).
- Records made after the restore bind as section 4 says. The cost is the owner's: with one account only, a restored
  record that had not reached iCloud before the backup never uploads, and a copy later deleted from iCloud is not put
  back for a restored record.

### 7. The iCloud-copies check

- After the launch's pull, and after Verify iCloud access, the phone looks for its 20 newest synced records bound to
  the verified account, under every name each can have in iCloud (item 87). Most of them gone, never a single one,
  reads as deleted: the phone puts back only the records bound to that account, and only while it is signed into
  that account; under another account it reports and uploads nothing, and with either account unknown it only
  reports. An answer that is not conclusive changes nothing. Nothing is checked before the first verification:
  nothing has gone up from such an installation (item 152's lead 13).

### 8. The screens

- While a verified installation waits for iCloud, Home's iCloud row says "Waiting for iCloud". Its orange line, "iCloud
  is paused. Verify iCloud access in Settings to back up new events; Malinois won't upload events recorded before
  then.", shows only while new records bind to no account (never verified, or another account seen), and not while
  iCloud backup is off, whose own line says "iCloud backup is off: Malinois won't upload new events." (item 140's
  codex-1, item 168).
- The Event Log counts held records apart from the uploads still to go and offers Retry only for those; each held
  record says why it is held: no verified account, a different account, verification needed, the grant's file
  unreadable, or recorded while backup was off (`UploadHoldReason`). The screens read the state already known: they
  never prompt, look up the account or grant anything.

## Consequences

- A new app PIN after a reinstall, or a phone restored from its backup, opens no iCloud evidence until the owner
  passes the device-owner check; whoever can pass it can authorize recovery and cloud access.
- A temporary iCloud answer, a throttle or a lookup past its deadline revokes nothing: the sweep tries again, and on a
  phone left armed under a network that passes nothing the escalation still gets its verdict.
- Evidence of an unknown account or of another account is held: never deleted, and never adopted.
- What the server has already accepted cannot be recalled: cancellation and the generation stop later work and refuse
  stale results, with no transaction across a change of Apple account.
- One flush more per record on the trigger path, for its binding.
- Reinstalls, account changes, iOS's authentication and background delivery need checks on a device beyond the tests:
  switching iCloud accounts on hardware is untested, an accepted limit, and the Simulator cannot restore a backup or
  cut power.
- Not taken: the account identity cached to skip the lookup (ADR 0075); record reads in the alert extensions, which
  cannot check this installation's grant.
