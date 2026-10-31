# ADR 0003: Per-event upload serialization and single capture ownership

- **Status:** accepted
- **Date:** 2026-08-27

## Context

One event's evidence is written to CloudKit several times (the fast fact, the rich
post-capture record, owner attribution, retries), from several triggers (trigger time,
reconnect, foreground, log-open). The revision ladder orders *payloads* but could not
order *writes*: two writes could both pass the local preflight before either landed, so a
stale earlier write could finish last and win under `.allKeys` (review B2's residual).
Separately, the camera pipeline had three independent capture initiators — trigger
responses, blackout evidence, flood cadence — whose overlap could reconfigure a session
mid-recording or cross-wire a recording's stop (34.H10).

## Decision

**Uploads:** every CloudKit write for one event runs through a per-event chain
(`CloudExfiltrator.enqueue`) — each write starts only after the previous write for that
event has finished. Chains for different events stay concurrent, preserving
`retryPendingSync`'s bounded parallelism; that sweep is additionally single-flight, since
its three callers routinely fire within a second of each other.

**Captures:** the trigger response owns the pipeline outright; cadence captures (blackout,
flood) yield to it *and* to each other, are stills by construction (a photo answers their
purpose and stills cannot contend for the movie output), and a recording accepts exactly
one stop.

## Consequences

- The stale-overwrites-rich race is structurally impossible within a process; across
  launches the revision ladder still governs, as before.
- A slow clip upload for one event cannot delay another event's fact push.
- Cadence evidence can be skipped under contention (logged); the trigger's capture — the
  product — is never the one that yields.
- The chain is in-memory: it orders writes from this process only, which is the scope the
  race ever had.

## Amendment (2026-09-20, 1.3.2): the pending sweep finishes what it starts

Owner report, with a large backlog of arm/disarm records: the Event Log's spinner stopped
while the sync carried on, and only part of the backlog seemed to go up per pull-to-refresh.
The sweep as decided above explains the first outright and could explain the second (see
the device check below). It was single-flight but told nobody it was
running, so a screen whose request was turned away showed nothing; and it was ONE pass, in
which every save gives up after three attempts whose waits are capped at 4 s. That cap is
right at trigger time, where a push races a power-off. It is wrong for a sweep: when iCloud
answers a long backlog with "slow down", every record after the first failure spent its own
attempts against the same answer, and the rest waited for the next trigger.

The sweep keeps its single-flight guard and its bounded parallelism, and gains four rules,
each a pure function the tests pin:

- **It says it is running.** `pendingSweepActive` is published for the sweep's whole life,
  whoever started it, and `pendingSweepWaiting` while it waits between passes. The log's
  banner follows both (`bannerShowsSpinner`, `bannerCaption`).
- **A save that gives up says why.** `CloudExfiltrator.transientFailure(from:)` uses the same
  transient set as `retryDelay`, by construction, and carries the server's Retry-After
  UNCAPPED. When several saves give up in one pass the longest wait stands.
- **A pass stops handing out records when the door is closed** (`sweepDoorClosed`): at once
  when the server named a wait, because that answer is about the device and not the record;
  after three failures in a row when it named none, which is what an outage looks like. One
  record that cannot get through (a large clip stalling on a slow link fails the same way a
  lost path does) holds nobody back. Refusals never close the door.
- **The sweep makes follow-up passes by itself** (`sweepFollowUpDelay`): only for a transient
  failure, with records left and a network path up; after the server's own wait, else 2 s
  doubling per pass that landed nothing, clamped to 2–120 s; at most 20 passes, at most 3 in
  a row that land nothing. A refusal is an answer the next trigger can re-ask; an offline
  device has the reconnect trigger.

`retryPendingSync()` still returns after the FIRST pass, because the Event Log and the launch
both follow it with a pull that must not sit behind a wait. Follow-up passes run on a task
the engine owns: a screen's task is cancelled when the screen closes, and a cancelled wait
is no wait at all. The trigger-time path is unchanged.

Not taken, deliberately: batching many state records into one CloudKit operation. It is the
real fix for very large backlogs (one operation per record is what would invite a throttle)
and it changes the per-event chain above, so it is its own decision for 1.4.

**Device check (2026-09-25).** A seeded backlog of several hundred records on the owner's
Debug build went up in one pass, with the spinner up throughout and no pull needed. No pass
was logged, so iCloud never asked the app to slow down (the development environment;
production was not measured). The owner's second symptom is therefore better explained by
the first: the upload ran on after the spinner stopped, so each pull showed more rows
green. The follow-up passes stay as the guard for a throttle when one happens (Apple
documents `requestRateLimited` with a Retry-After, which the 4 s cap ignored), but they are
pinned by unit tests and have not yet been seen working on a device.

## Amendment (2026-10-22, 1.8.1): a stall deadline for a record carrying an asset

Every save attempt raced a fixed 20 s deadline (`saveAttemptDeadline`), the clip's `CKAsset`
included, with no progress observed, so a clip that needs more than 20 s to send was cut off on
every attempt and every pass, and only its meta record and thumbnail reached iCloud (the security
audit's lead 2, BACKLOG 152: a 30 s Until clear clip at the high preset is tens of MB, and a
10 Mbps uplink moves about 1.25 MB/s). A record carrying an asset (`carriesAsset`, pure: a photo, a
clip, a thumbnail) now races a stall deadline (`awaitWithStallDeadline`): the 20 s restart whenever
CloudKit's per-record progress block reports movement, within an overall cap of `assetSaveCap`,
ten minutes. Silence past the stall still cancels the attempt as a network-class failure, with the
same retries, the same count for the sweep and the same escalation classification; the cap cuts
off a transfer that never ends. A record without an asset keeps the fixed 20 s. The chain, the
sweep and their rules above are unchanged: a clip that keeps moving simply takes its time on its
own chain, and a stalled one fails as it did. Device check: a 60 s Until clear clip on a slowed
uplink (Network Link Conditioner, a 3G profile) lands in iCloud in one attempt where it was cut
off before.

## Amendment (2026-10-22, 1.8.1): the background-task assertion covers a push from its first step

Every push held its background-task assertion only inside its per-event queue, after the identity
lookup (`fetchUserRecordID`, under a 10 s deadline) and the queue wait, and the engine spawned its
push tasks with none, so the lapse record written as the phone was locked, and a trip's fact pushed
just before a lock or a kill, ran unprotected through their first step: milliseconds with a warm
CloudKit cache, up to the lookup's deadline cold or offline, against the few seconds iOS allows an
app after its scene leaves the foreground (the second independent audit's MAL-01, BACKLOG 153). Now
`pushFact`, `exfiltrate` and `pushStateChange` begin their assertion (`BackgroundAssertion`) before
the lookup and end it on every return, a declined or denied lease included, and the engine holds
one from before it spawns a push task (`pushFactIfCloud`, `logStateChange`), so a lock or a kill in
the same instant finds it held; UIKit allows the two at once. The expiry handler ends an assertion
once, and the event stays pending for the next sweep, as before. The chain, its deadlines and the
sweep are unchanged. Not taken: caching the account identity to skip the lookup (ADR 0039 resolves
it fresh and invalidates through the generation). Device check (TestFlight 78): armed on Pro with
Guided Access's Side Button on, one press; the "locked" record and its alert reach the second
device.

## Amendment (2026-10-22, 1.8.1): a sweep during a capture is not the event's last word

The fresh review of 1.8.1 (BACKLOG 155, Codex's codex-1) reproduced an ordering the chain did not cover. The
retry sweep hands out every record not yet synced, a capture still running included; the sparse upload of an
event without media lands as synced; the completion applies because the stored event still equals its snapshot
before the attachment; and synced is terminal by the monotonic rule above, so the media push that follows the
capture cannot reopen it, the sweep never retries it, and the byte cap evicts synced media first without the loss
mark it keeps for pending media. Two conditions had to meet: a sweep pass started between the trip and the
attachment (a reconnect, a foreground, the log opened, a verification), and a later failed media upload; when
they did, the log showed green over a lost photo. Now every attachment site, the trigger response, the blackout
still and the flood capture, reopens the event for upload (`reopenForReupload`, the late-evidence path's own
tool) after storing the media and before its push, so a sparse upload that landed during the capture is not the
event's final word: the media push's outcome applies, a failed one is retried by the sweep, and the cap treats
the media as pending. A sparse completion that lands after the attachment is still rejected by the snapshot
rule, and mirrored media is never reopened. The monotonic rule itself is unchanged: late duplicates' failures
still cannot walk a synced event back.

## Amendment (2026-10-23, 1.8.1): the attachment and its reopen are one write

Codex's second look at the amendment above (BACKLOG 155, codex-1 of the second look) found the ordering right
while the process lives and the disk one write behind it: `update` persisted the event with its media attached
and the state still synced, then `reopenForReupload` persisted it again as pending, two queued writes on the
store's serial I/O queue. A kill between them left the first on disk, media beside the synced state, which the
sweep skips and the byte cap deletes as a cloud-backed copy without the loss mark; the same pair stood at the
interrupted retry and the late capture, which had used it since item 65. Now every attachment site, the trigger
response, the blackout still, the flood capture, the interrupted retry and the late capture, calls
`updateAndReopenForReupload`, which merges the final state under the monotonic rule, walks synced back to pending
and persists once, so the first snapshot that carries the media already carries the upload obligation: a kill
after any write leaves an event the sweep retries and the cap marks. Pinned by a test that keeps that first
snapshot with its media, its intents and its journal, and opens them as a new store. `update` and
`reopenForReupload` stay for their other callers; mirrored downloads are never reopened.

## Amendment (2026-10-23, after 1.8.1's submission): two limits the full review found, for the next update

The full review of 1.8.1 (BACKLOG 162's A10 and A11) found two limits of this record's guarantees; SECURITY.md states
them until their fixes ship:

- Each push resolves the iCloud identity before it joins the event's chain, so the chain orders writes by when their
  lookups finish, not by when they started. For an event without a photo or clip, the first record and the fuller one
  carry the same revision, which `mayWrite` lets through, so the first can land last and replace, in the iCloud copy,
  the details added after the trip. The first Consequence ("structurally impossible within a process") holds only for
  writes that join the chain in the order they started. The fix resolves the identity inside the chain and writes the
  event as stored when its turn comes.
- The stall deadline of the 2026-10-22 amendment is timed with `Date()`, and since that amendment every save waits
  through it, so a clock change during a stalled save moves it: set back, the wait lengthens by up to the change; set
  forward, the save is cut short. The fix times both instants on a monotonic clock.

## Amendment (2026-10-24, 1.8.2): the stall deadline on a clock no setting moves

The second limit of the 2026-10-23 amendment is fixed (BACKLOG 162's A11; item 163's step 13): `StallClock` times
the start of a save's wait and each progress report on `ContinuousClock`, which no setting moves, so a clock changed
during a stalled save neither lengthens its wait nor cuts it short. Codex's four cases from the full review of 1.8.1
are its tests (`Item162SaveDeadlineClockTests`, on a clock the test moves). The first limit stands until its own fix
(A10; step 14).

## Amendment (2026-10-24, 1.8.2): one order per incident

The first limit of the 2026-10-23 amendment is fixed (BACKLOG 162's A10; item 163's step 14). A push joins its event's
chain before its identity lookup, which it makes when its turn comes, so the chain orders the writes by when they were
asked for; and at its turn each writes the event as the engine's log holds it then (`storedEvent`, wired at the
engine's init), so an older copy, the pending sweep's (read at its pass's start) included, cannot land after a fuller
one. The first Consequence ("structurally impossible within a process") holds again. The background-task assertion of
the 2026-10-22 amendment still covers each push from its first step, now the queue wait. Tests:
`Item162UploadOrderTests` (Codex's probe A, an older copy, the engine's wiring).

## Amendment (2026-10-26, 1.8.2): the files an upload sends, and the discard check's wait

Codex's look at codex-24's fix (BACKLOG 166's codex-27): an upload is handed a copy of its event and takes its pin
(`EventStore.beginUpload`, which the limits respect) only when its task runs; it sent the files that copy named. The
byte limit could discard the capture in between, and while the log's write fails the dropped files stay on disk (item
165's A1), so a photo could land after the discard, and after iCloud, asked, had been found to hold none of it. An
upload now sends the files the log's copy names once its pin holds; a row gone from the log keeps its copy's files, as
before. Tests: `Item166ReviewTests`.

Codex's codex-28: the discard check (`checkDiscardedCaptures`, ADR 0006's codex-24 amendment) asks iCloud before the
pass's uploads, and its fetch turned every failure into "no answer", so a throttle that named a wait went unrecorded
and the pass handed out its uploads at once. A transient failure of the presence fetch now goes on record as a save's
does, a wait iCloud named closes the pass's door before any upload (`sweepDoorClosed`), and a check still owed for a
capture bound to the verified account counts toward the follow-up as a record still to upload does. Codex's codex-30:
the fetch's results were read only up to the first failure, so one met first (a permanent failure, or a shorter
wait) hid a throttle or a longer wait behind it; every result is read now, and every failure a partial one nests, and
the longest wait stands (`transientFailures(in:)`). Any failure other than "no such record" still makes the answer
inconclusive.


## Amendment (2026-10-29, 1.9): a locally unstaged thumbnail stays owed

A metadata save distinguishes a failed save from a saved sparse record whose thumbnail could not be staged.
The latter still permits the full-media uploads and leaves the event pending without an interference verdict.
The next ordinary retry stages the thumbnail and sends the same metadata revision. No new stored field or schema
is needed: the local thumbnail and pending sync state retain the work.

A fact may also update an already-synced sustained event or owner attribution. Its failure is reconciled inside
the existing per-event write queue through `factFailed`, with the actual snapshot selected at that queue turn.
The engine reopens only a matching current first-hand row, ignoring sync state and newly landed receipt contents.
Only failed facts additionally ignore the primary and secondary local cache filenames and the outstanding
discard-check flag. A fact holds its account binding but does not pin the full-media cache: the byte cap can
remove those filenames during the save, a download can refill the same camera slots, and an independent presence
answer can settle the check. None establishes a newer successful queued fact. These local references can affect
the derived media manifest or revision; the retry changes only the current row's sync state, and the next queued
upload reads its current files and derives its current record.

Thumbnail bytes, camera identity and duration, capture failures, counts, attribution, durable loss,
account-policy/provenance fields, receipt epoch and every other event field remain compared. Future stored fields
remain strict by default. Ordinary full-upload completion keeps its original comparison and does not receive the
three-field exception. No later queued success can finish before the failed-fact hook. Identity/account/cancellation
refusals still retain an owed retry; a deliberate backup-policy block before the attempt does not create one. Work
already allowed may stay pending while backup is switched off, and normal policy gates keep it local until allowed
again.

Regression cases: `Item175ThumbnailRetryTests`. Simulator injection covers disk-write failure and callback ordering;
live CloudKit propagation and phone behavior remain device verification.

## Amendment (2026-10-29, 1.9): the reads have deadlines too

The saves raced their deadlines; the reads raced none, and CloudKit's own resource timeout is measured in days. A read
on a path that looks online but passes nothing never answered, and held its caller for the session: the presence check
(`presenceResults`, BACKLOG 166) held the pending sweep's single-flight flag, so no pending upload was retried again
until the app was next launched, and the alert subscriptions' listing held an automatic setup open (BACKLOG 180's A2,
claude-fable-2). Now a read that carries no file (the presence check, the subscription listing, a beat's read, the
arm's warm-up query) runs on a CloudKit operation of its own and races `saveAttemptDeadline` (`operationRead`): past it
the operation is cancelled and the read fails as a network-class failure, for each caller's existing failure rule. A
read that carries files (a restore's query pages and the media-age walk's, with their thumbnails; the full download,
with its captures) races the stall deadline of the 1.8.1 amendment instead (`queryPage`, `fetchMediaRecords`): the 20 s
restart as records arrive and CloudKit reports progress, within `assetSaveCap`. Each of these reads is held in
`activeOperations`, so an account change cancels it, and is cancelled when its caller is, which then goes on at once.
The retention purge's two reads (`fetchBeats`, `newestServerCreationDate`), on operations since before 1.9, keep their
deadline and the account-change cancel; nothing cancels their tasks (codex-1 on `91acaed`).
Operations, not CloudKit's async calls: before iOS 27, `allSubscriptions()` and `record(for:)` wrap the callback calls
with no cancellation, so a read past its deadline was released but went on (the review of the fixes: codex-4 and
deepseek-3 on `ee565c2`). The chain, the sweep and their rules are unchanged.

Regression cases: `Item166ReviewTests.testACheckWhoseReadNeverAnswersEndsAtTheDeadline` and
`Item152SettingsGuardTests.testAListingThatNeverAnswersEndsTheRefreshAtTheDeadline` (the callers); and, each read's
operation held unanswered through a test hook in place of the database, `Item166ReviewTests`' check, latest-beat and
full-download cases (the download's stall and its caller's cancel) and `Item152SettingsGuardTests`' listing and warm-up
cases. The Simulator has no iCloud container: a live CloudKit answer, progress and partial failure stay unexercised.
