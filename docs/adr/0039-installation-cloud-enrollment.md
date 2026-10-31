# ADR 0039: Device-owner verification before cloud enrollment

- **Status:** accepted; shipped in 1.5.1 (58), released 2026-10-12. Build 56 phone checks passed; switching iCloud accounts on
  hardware is untested (owner-accepted limitation) and initial enrollment cancellation was waived. Amended by ADR 0045
  (1.6): the extension shows tamper alerts Time Sensitive, decided from the push's subscription without reading a record.
- **Date:** 2026-10-11

## Context

Deleting and reinstalling an app must not turn a new app PIN into access to old iCloud evidence.
A surviving PIN must be preserved, but that alone cannot protect a new phone or an installation
whose Keychain history is absent. UI-only checks miss background restores, notification reads,
and account-wide subscription changes.

## Decision

The owner selected option B in `docs/design/reinstall-recovery-options.md`: preserve surviving
PINs and use iOS device-owner authentication (Face ID, Touch ID, or device passcode) to enroll
each installation and iCloud account. Existing cloud users verify once after migration. Local
monitoring and ordinary PIN-only disarm remain available without cloud enrollment.

The cloud service resolves account identity before each entry point and requires an enrollment
lease. Queued work, retries, and returned results retain that account/generation; account changes
invalidate leases and cancel tracked operations. Identity failure is never proof of permission.
Enrollment and explicit account-wide alert removal are foreground actions. The latter always
requires fresh authentication and changes the saved toggle only after CloudKit reports success.

The grant lives in an atomic, protected file in the app container, excluded from backups. A
surviving Keychain item cannot silently recreate a grant after reinstall. Failed persistence,
corrupt state, cancellation, and unavailable authentication remain local-only. No background
callback displays an authentication prompt.

Each local event and watch has a durable account binding established at capture time. Migration
uses the previous release's remembered account only when known; unknown old records stay local
(superseded in 1.8.2: the rebuild holds every record; see the restore amendment below).
Offline captures retain their verified owner until a different account is positively observed.
That observation places subsequent captures on a durable hold, including across offline relaunch.
Resolving the original identity or explicitly enrolling the new account allows future captures
to bind; already-held evidence is never adopted automatically. Changing accounts never adopts
old evidence automatically. Returned mirrors retain their source
account binding; stale results cannot merge into the log or attach downloaded media.

The owner selected generic notifications for this maintenance update. The notification extension
returns the subscription's content immediately and never fetches private records. Device/sensor
wording and Vision-only quieting are deferred until a shared authorization design is separately
reviewed and tested across reinstalls. Generic alerts retain the sound and interruption level
sent by the subscription. No shared-storage or signing capability is added.

## Consequences

- Existing users temporarily lose cloud backup/restore until verification completes. Local
  evidence remains on the phone and monitoring/disarm remain available.
- A device without a passcode cannot enroll. Canceling or failing authentication changes nothing.
- People who can satisfy device-owner authentication can authorize recovery and cloud access.
  This is not record signing, producer authentication, server-side revocation, or protection
  against modified clients, older builds, iOS compromise, or deletion through Apple's controls.
- Unknown-account evidence is deliberately held. No records are deleted to simplify migration.
- Already accepted server requests cannot be recalled; cancellation and generation checks stop
  later work and reject stale results, without promising a transaction across Apple account changes.
- Reinstall, account switching, OS authentication, and background delivery need physical-device
  checks in addition to regression tests. Submitted 1.5 (55) is unchanged.

## Event Log presentation (2026-10-11)

Held records are counted separately from eligible local uploads. Retry is shown only for
eligible uploads; event details distinguish unknown ownership, a different account,
verification needed, and unavailable enrollment storage. The read-only presentation uses
known ownership/grant state; it does not prompt, resolve an account, or grant upload access.
Same-account offline captures remain retryable using their durable grant, while the actual
upload still obtains and validates a current lease. No ownership/adoption policy changed.

## Settings under Guided Access (2026-10-19, 1.8 (73))

iOS holds the device-owner authentication sheet while Guided Access is on (BACKLOG 44), so
`deviceAuthentication` refuses at once rather than leave a request waiting. Settings' Verify
iCloud access did nothing visible then (BACKLOG 135, the owner's report). It is now greyed out
while Guided Access is on, its caption saying why, and comes back when Guided Access ends. A
verification that still fails with Guided Access on (started during the attempt; read when it
fails) says so, instead of the generic "retry while disarmed". No grant, lease or ownership rule
changed.

## Home presentation (2026-10-19, 1.8 (74))

Home said "iCloud verification needed" and "events recorded before then stay on this iPhone"
whenever access was not current (BACKLOG 140, Codex's codex-1). A verified installation offline,
or relaunched before iCloud answers, binds new events to its granted account, and they upload
once iCloud names that account again. `CloudEnrollment.newEventsBindToVerifiedAccount` reports
that, by the very rule `register` binds with; Home's row then says "Waiting for iCloud" and the
orange line stays away. The line shows only while new events are tied to no account (never
verified, another account seen), and not with iCloud backup off, whose own line says new events
stay on this iPhone. No grant, lease or ownership rule changed. Since 1.8.2 both lines say what Malinois does, not
where the events stay (BACKLOG 168): the orange line "Malinois won't upload events recorded before then", the
backup-off line "Malinois won't upload new events".

## A transient identity failure is not an account change (2026-10-22, 1.8.1)

Every database entry point resolves the account's identity first (`fetchUserRecordID`, under a
10 s deadline). One lookup that failed for any reason was treated as an account change for the
whole process: every lease in flight voided, every save under way cancelled and demoted to
local-only, the pending sweep's record of transient failures erased, the verified state cleared
(the security audit's lead 1, BACKLOG 152). Nothing was lost, but on a phone left armed the next
sweep could be hours away, and under a network that passes nothing the lookup's deadline cancelled
the saves before their own deadline could give the interference verdict ADR 0001 escalates on.

The lookup now tells three answers apart (`CloudExfiltrator.identityLookup`, pure): a name
resolves the account, a different name invalidating first; iCloud's answer that there is no
account (`.notAuthenticated`, or no record) invalidates, as before, and so does anything
unclassified; a transient failure (the network class `retryDelay` names, a bare transport error,
or the deadline) denies only the caller's own request, records a network-class transient failure
for the pending sweep's follow-up, and leaves every lease in flight, every save under way and the
verified state as they are. The account-changed notice still invalidates. An evidence push denied
by a transient lookup reports the network-class verdict (`metaFailureWasInterference: true`), so
the escalation's rule sees it as it would a save that lost the network; a hold is still no
verdict. The pending sweep, whose lookup fails transiently, follows up as it does after a save's
transient failure instead of ending with records left. Path inventory: every lease taker (the
fact, meta, photo and state pushes, heartbeats, the sweep's own leases, the fetches and the
retention pass) goes through the same resolution; only the evidence push reports a verdict, and
only the sweep follows up. Device check: Network Link Conditioner at 100% loss with the path up,
the escalation fires on the lookup's failure as it did on a save's.

## Amendment (2026-10-22, 1.8.1): the other entry point, and a throttle is an answer

The fresh review of 1.8.1 (BACKLOG 155, Codex's codex-4 and codex-5) found the rule above applied
to the identity lookup only. Home's and Settings' account-status refresh (`refreshAccountState`)
still invalidated the resolution, every lease in flight and every save under way on a temporary
answer: iOS's "temporarily unavailable" or "could not determine", an error, or the status call's
own deadline. Now one rule applies at both entry points (`applyAccountStatus`): iCloud's answer that
the account is not there to use, no account or restricted, invalidates as the lookup's "no account"
does; any other answer that is not ready goes on record as a transient failure for the sweep's
follow-up and changes nothing else. And the lookup's transient result now carries its class and the
server's wait: the network class and a bare transport error are interference, as `failureSuggests
Interference` already rules for saves; Apple's throttles and outages (`requestRateLimited`,
`serviceUnavailable`, `zoneBusy`) are answers, so an evidence push they deny reports a refusal
verdict, which the engine surfaces on Home instead of sounding the jamming siren, and their
retry-after reaches the pending sweep instead of being dropped. Path inventory: the two entry
points; every lease taker through `leaseAttempt`, which hands the class to the evidence push's
verdict; the sweep's follow-up, which reads the recorded wait.

## Amendment (2026-10-23, 1.8.1): an account not ready yet, and the sweep's first lookup

Codex's second look (BACKLOG 155, codex-2 and codex-3 of the second look) found two gaps in the amendment
above. The identity lookup classified iCloud's `accountTemporarilyUnavailable`, an account that is there but not
ready, as no account, because the transient set it consulted is the save path's: the resolution, every lease in
flight and the verified state were revoked for an answer Apple documents as temporary, while the same answer from
the status check (`temporarilyUnavailable`) already revoked nothing. Now the lookup classifies it as a transient
answer, not interference and with no wait named: it denies its caller, goes on record for the sweep's follow-up
and changes nothing else; it stays out of the save path's retry set, because a save is not retried within
milliseconds for it. And the pending sweep made a preflight lookup before its first pass, whose throttle wait the
pass cleared before looking up again at once, so a second lookup that succeeded uploaded before the wait the
server had named. The preflight is gone: the first pass makes the sweep's first lookup itself; a throttle on it
hands nothing out and its wait reaches the follow-up, as a lookup that failed for want of a network has since
item 152's lead 1; no account still ends the sweep at once. One lookup per pass instead of two.

## Amendment (2026-10-24, 1.8.2): the iCloud-copies check follows the enrollment

Item 87's launch check, which notices copies deleted in iOS Settings and puts them back, decided by an account it
remembered once, at the first check that found the copies in place. That missed copies deleted before any check had
found them, and every copy after a deliberate change of account (BACKLOG 152's lead 13); and an older account's
records, absent from a new account by design, read there as a deletion. The check now looks only for the records bound
to the account this installation is verified for (`isBound`, the binding made at capture), and puts back only those,
only while the phone is signed into that account (`enrolledAccount`); under another account it reports and uploads
nothing, as before. Nothing is checked before the first verification: nothing has gone up from such an installation.
The remembered account stayed, for the legacy ownership seeding only, until the restore amendment below removed it.
Tests: `Item87CloudWipeTests` (the lead's four).

## Amendment (2026-10-24, 1.8.2): the bindings of records gone from the log are pruned

The bindings (`owners`, `remoteOwners`) gained one entry per record for ever, and the file is rewritten whole at every
new record, before the journal append (BACKLOG 153's MAL-08). Once the complete log has been read (at launch, and when
the app comes back to the foreground), the bindings no record needs any longer are pruned: kept are the log's records
(its own and copies), uploads under way, the bindings work still uses (fact pushes waiting their turn, and a response,
a flood still or a blackout frame from its record's registration until its upload ends, since a full log can drop
the row while the capture runs), the live flood's record (the engine still pushes it after its row has left a full
log; Codex's codex-6 found the fact pushes and the live flood missing, and its second look the capture's window), the
event limit's removals whose unsynced-removal marker (item 114) has not read them yet (the first gate on the change
found the launch trim's marker lost without them), the Pro watches whose heartbeat trails iCloud may still hold, and
the live watch. These keep the binding, not the row: the event limit chooses as before. A log not read from disk
reads as empty, so nothing is pruned from it. The hold rule stands for every record the
log holds: a held record keeps its empty binding, so a copy from iCloud under its ID is still refused. A record gone
from the log that comes back from iCloud comes back as a copy, bound to the account that supplies it, as the mirrors of
the Decision are. The file stays close to the log's size (the log holds at most 600 records, about 80 bytes an entry
each; the watches, the live flood and the work under way add a few more). Tests: `Item153BindingPruneTests`.

## Amendment (2026-10-24, 1.8.2): the binding reaches the medium before the journal line

Each event's binding (`registerLocalEvent`) is written before its journal line on every path, but only the journal's
append was synced to the storage medium (ADR 0005); the enrollment's atomic write could sit in the OS's caches, so a
forced restart within seconds of a trip could keep the line and lose the binding, the recovered event then held as
unknown account (BACKLOG 153's MAL-07). `CloudEnrollment.write` now ends with `F_FULLFSYNC`, as the journal's append
does: one flush more per event on the trigger path (the journal's costs about 4 ms; the file stays small since the
pruning above). A failed sync is logged; the state written still survives a kill. The Simulator cannot cut power: the
reviewer's T7 checks it on a device (a trip, then a forced restart within seconds, repeated). Tests:
`Item153BindingFlushTests`.

## Amendment (2026-10-24, 1.8.2): a fetch that brings nothing new writes nothing

Every fetch bound the copies it brought (`registerRemoteEvents`) and rewrote the file whole, even when no copy was new
to this phone. Since the amendment above, each write reaches the storage medium, so every push from iCloud, and every
fetch at launch or on pull-to-refresh, cost a flush on the main actor for nothing (BACKLOG 152's lead 20, the part the
pruning left). The file is now written only when a copy is new. Tests: `Item163RecordCapsTests`.

## Amendment (2026-10-24, 1.8.2): a restore holds every restored record

The grant and the bindings share a file excluded from backups, so a phone restored from its backup has neither, and
the engine's one-time rebuild (the migration's seeding) gave every restored record to the account the launch check
remembered: after a deliberate change of account (A, then B), B's records went to A, B's re-upload of deleted copies
skipped them, and A, verified again, could upload them (Codex's codex-7, inherited from 1.5.1's migration; confirmed by
a red test). The owner ruled to hold rather than guess (2026-10-24, option (a)). A first fix kept a note, where the
backup keeps it, of a second verified account, and held only then; Codex's look at it found the note no proof (a 1.8.1
backup restored straight into 1.8.2 carries none, and a record held to no account lost its hold to the rebuild), and
the owner ruled again (a): every restored first-hand record is held (`CloudEnrollment.holdRestoredEvents`), whatever
the history, each explained as having no verified iCloud account (Share still saves a copy elsewhere), none uploaded to
any account; other devices' copies are left unbound, and the next fetch from the verified account binds the ones it
holds, as any fetched copy is. Records captured after the restore bind as always. The cost is the owner's: with one
account only, a restored record that had not reached iCloud before the backup never uploads, and a copy later deleted
from iCloud is not put back for a restored record. An update from before 1.5.1 runs the same rebuild and is held the
same way. The note, and the account the launch check remembered (it had no other reader), are gone; with them goes
Codex's codex-11 (a raw identity lookup writing the remembered account). The Decision's sentence on migration is
superseded by this one. The Simulator cannot restore a backup: the tests drop the grant's file and launch a new engine
on the same log and settings, and the real pending sweep sends no restored record. Tests:
`Item163SecondAccountRestoreTests`.

## Amendment (2026-10-26, 1.8.2): an "off" supersedes the automatic setups

The switch saves the owner's choice only after CloudKit reports success, so it reads the old choice while an "off"
waits on its account lookup, on Face ID or the passcode, and on the removal. The automatic setups of the alert
subscriptions, the arm's warm-up and a reconnect's refresh, never remove (H6); they carried the choice read when
they began through their waits, so an "off" made meanwhile was undone by the saves that followed (BACKLOG 165's A3
residuals, Codex's codex-19 and codex-21). Now each asks the owner's choice as it is (Pro, the switch on, the stored
settings loaded) after the account lookup, after the listing and before each save, and a change made with the
switch, begun or ended since the setup began or under way when it reaches a step, supersedes it: it saves nothing
more (`automaticSetupWanted`). A save already sent to CloudKit when the owner turns alerts off can still land after
the removal; that residual is accepted. Tests: `Item152SettingsGuardTests` (the arm held in its lookup, its
listing and between its saves; an arm and a reconnect reaching their saves while an "off" waits on Face ID).

## Amendment (2026-10-26, 1.8.2): a restored record's upload history is unknown

Codex's look at codex-24's fix (BACKLOG 166's codex-29): the byte limit marked at once, "discarded by the storage cap
before it could upload", every capture with no account behind it, which is right for one recorded while the
installation was not uploading; but the rebuild above ties every restored first-hand record to no account too, and a
restored capture part of which had reached the original account's iCloud then read as never uploaded. The owner chose
(2026-10-26, option (a)) to note it: the rebuild notes each record it holds as restored, its upload history unknown
(`restoredHolds` in the grant's file, `uploadHistoryUnknown(for:)`), in the same write as its binding. A first fix
noted it on the event in the log, written after the grant's file: a kill between the two writes, or a failed log
write and then a kill, left the rebuild done and the note gone for good (Codex's codex-31). The limit never marks
such a capture lost at once; its check stays owed, this installation unable to run it (ADR 0006's codex-24
amendment). The bindings' prune keeps a note while its binding stays. A record with no binding at all counts as
unknown too, as a restored record is until the rebuild runs: the rebuild waits for a readable log, and after a launch
before the first unlock the byte limit could run first and mark such a capture at once (Codex's codex-32); every
record this app makes is bound at birth. A record that the seeding of 1.8.1 or earlier
tied to no account, the account unknown then, carries no note and is marked as before: a known limit, which
SECURITY.md states. Tests: `Item166ReviewTests`.


## Implementation note (2026-10-29, 1.9)

The historical “before it could upload” sentence quoted above is replaced by a general statement that the storage
cap removed the local full capture and no copy is available in iCloud. A cloud copy can have uploaded and then been
deleted after local pruning (ADR 0006's 1.9 amendment). The restored-record rule above is unchanged: a restore explicitly noted in `restoredHolds` remains unchecked, and
this installation does not adopt an unknown original account. The documented legacy exception also remains:
a first-hand record bound to no account by 1.8.1 or earlier has no such history note and may still be marked.
