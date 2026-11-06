# ADR 0075: Uploads: the chain per event, the pending sweep and their deadlines

- **Status:** accepted: the owner's rulings on ADR 0003 (1.2, 2026-08-27) and on its twelve amendments (1.3.2 to
  1.10, 2026-09-20 to 2026-10-30), as they stand in 1.11 (83), with the pending sweep's rules from other items. It
  states the upload design those amendments built one review at a time (BACKLOG item 186; the owner, 2026-11-01: "a,
  rule approved"); ADR 0003 keeps its decision, and its capture decision is stated there only. Each defect, the review
  that found it and the ruling: the BACKLOG items named below.
- **Date:** 2026-11-04
- **Summary:** Each event's iCloud writes go one at a time, in the order they were asked for; every iCloud wait has a
  deadline; and the pending sweep retries what is left, waiting as long as iCloud asks, up to two minutes.

## Context

ADR 0003 put every iCloud write for one event in a chain of its own, each write starting only after the one before it
had finished, so that a stale write could no longer land after a richer one; it made the pending sweep single-flight;
and it gave the trigger's capture the camera outright. Twelve amendments followed, each from a review, an audit or the
owner's report: the sweep's waits and follow-up passes, a stall deadline for a save that carries a file, a
background-task assertion from a push's first step, attachments that reopen the upload, one order for the pushes of
one incident, the files an upload sends, a thumbnail still owed, and deadlines on every read, the watch's included.
This record states the design they built, as it stands; ADR 0003 lists them, each with the section here that states it
now.

The design holds against a network that passes nothing while it looks connected, Apple's servers throttling or out of
service, the phone locked or the app killed in the middle of a push, and the clock changed during a save. Its scope is
one process: the chains and the record of what each push sent are in memory, and after a relaunch each write sends the
event as the log holds it. Which account an upload may go to, and what an identity lookup's answers do, ADR 0076
states.

## Decision

### 1. One chain per event

- Every iCloud write for one event runs in that event's chain (`CloudExfiltrator.enqueue`): it starts only after the
  write before it for that event has finished or timed out. Different events' chains run at the same time.
- A fact push (`pushFact`) and an evidence push (`exfiltrate`) join the chain first and make their identity lookup
  when their turn comes, and at their turn each writes the event as the engine's log holds it then (`storedEvent`,
  wired at the engine's start), never the copy it was handed. The writes for one incident go out in the order they
  were asked for, and an older copy, such as the pending sweep's, read at its pass's start, cannot land after a fuller
  one (item 162's A10).
- A status entry's push (`pushStateChangeReportingAlert`) and the late disarms' alert (`pushDisarmSignal`) make their
  lookup first, then join their event's chain under that lease (`enqueueAuthorized`).
- A metadata write whose revision (`metaRevision`) is lower than one this process has already saved for the event is
  not sent, and counts as landed: a richer record is already in iCloud (`mayWrite`). An equal revision is an ordinary
  retry.
- An upload's result applies to the log only while the log's copy still matches the copy it sent, apart from the sync
  state and the receipts of files that landed during it (`applyUploadCompletion`), so a late result never changes a
  newer row.

### 2. A push's steps

- The identity lookup (`fetchUserRecordID`) races 10 s (`accountStatusDeadline`). Before every step the push checks
  that its lease is still current, that the event is bound to the lease's account and that iCloud backup allows it
  (`mayUpload`), and before every save attempt the lease and the backup switch again (`requireCurrent`; ADR 0047):
  turning backup off stops anything new from starting, a retry included.
- An evidence push sends the metadata record first, with its thumbnail, then each capture's file as a record of its
  own, and notes on the event each file that lands (`mediaLanded`). The event is synced once the metadata, its
  thumbnail and every file have landed, pending while any is owed, and local only when the metadata failed, with that
  failure's verdict for the escalation (ADR 0001).
- A save makes at most three attempts. It retries only a transient failure (`retryDelay`: no network, a lost
  response, Apple's throttles and outages), after the server's wait or a doubling one, capped at 4 s each, since a
  push at trigger time races a power-off. A record too large is never retried. A save succeeds only on each record's
  own confirmation (`saveError`; ADR 0004).
- A save that gives up on a transient failure leaves it on record for the pending sweep (`transientFailure(from:)`,
  `noteTransientFailure`), with the server's wait uncapped; when several give up, the longest wait stands (item 79).

### 3. Deadlines on every wait

- A save without a file races 20 s (`saveAttemptDeadline`). A save that carries one (a photo, a clip, a thumbnail;
  `carriesAsset`) races a stall deadline instead (`awaitWithStallDeadline`): 20 s that restart whenever CloudKit
  reports progress, within ten minutes in all (`assetSaveCap`). Past either, the operation is cancelled and the
  attempt fails as a network-class failure: the same retries, the same record for the sweep and the same verdict for
  the escalation as a lost connection (item 152's lead 2).
- The stall deadline is timed on `ContinuousClock` (`StallClock`), which no clock setting moves, so a clock changed
  during a stalled save neither lengthens its wait nor cuts it short (item 162's A11).
- A read that carries no file (the presence check, the alert subscriptions' listing, a beat's read, the arm's warm-up
  query) runs on a CloudKit operation of its own within 20 s (`operationRead`). A read that carries files (a restore's
  query pages and the media-age walk's, with their thumbnails; the full download, with its captures) races the stall
  deadline (`queryPage`, `fetchMediaRecords`). Each is held in `activeOperations`, so an account change cancels it,
  and is cancelled when its caller is, which then goes on at once. Past its deadline a read fails as a network-class
  failure, for its caller's own failure rule (item 180's A2). Operations, not CloudKit's async calls: before iOS 27
  those cannot be cancelled (item 180's codex-4 and deepseek-3).
- The retention pass's two reads (`fetchBeats`, `newestServerCreationDate`) and its deletions run on operations within
  20 s, which an account change cancels; their caller's cancellation does not.
- The watch app's two reads, its account check and the alert subscription's listing, race 20 s each
  (`WatchCloudCheck`): past it the account reads as not known and the subscription as not checked, with the reason
  "The check took longer than 20 seconds." They use CloudKit's async calls, which a deadline cannot stop: a read past
  its deadline runs on, and its answer is dropped (item 180's codex-5).

### 4. Background-task assertions

- Every push (`pushFact`, `exfiltrate`, `pushStateChangeReportingAlert`, `pushDisarmSignal`) begins a background-task
  assertion (`BackgroundAssertion`) before its first step, the queue wait or the lookup, and ends it on every return.
  The engine also holds one from before it spawns a fact push's task (`pushFactIfCloud`) and a status entry's
  (`logStateChange`). A lock or a kill in the same instant finds iOS's extra time already asked for; UIKit allows
  several at once. An assertion iOS expires ends once, and its event stays pending for the sweep (item 153's MAL-01).

### 5. The pending sweep

- It uploads whatever this phone has not yet got into iCloud, on Pro only. It starts at launch, at each return to the
  foreground, when a network path comes back, from the Event Log (opening it, pull-to-refresh, Retry), after Verify
  iCloud access, after an encrypted-data reset or the iCloud-copies check has requeued records, for late evidence and
  iCloud backup turned back on, and, after a launch before the first unlock, once the settings are read with backup on
  (ADR 0055).
- One runs at a time: a request while one runs is turned away, except the last three, which are owed a sweep that
  starts when the running one ends (`sweepAfterTheRunningOne`; item 116's N1). `pendingSweepActive` is published for
  the sweep's whole life and `pendingSweepWaiting` while it waits between passes; the Event Log's banner follows both
  (`bannerShowsSpinner`, `bannerCaption`).
- Each pass first makes its own identity lookup (item 155's S3). No account, or one this installation is not verified
  for, ends the sweep; a transient failure hands nothing out, and its wait goes to the follow-up.
- Under the pass's lease it then asks iCloud about up to 20 captures the byte limit discarded unchecked, bound to that
  account, the oldest first (`checkDiscardedCaptures`; ADR 0006's codex-24 amendment). A transient failure of that
  question goes on record as a save's does, each failure a partial one nests included and the longest wait standing
  (`transientFailures(in:)`), and a wait iCloud names there closes the pass's door before any upload (item 166's
  codex-28 and codex-30).
- It hands out, three at a time, the records not yet synced that the backup rules allow and the pass's lease may
  upload, incidents before status entries (`sweepOrder`; item 148). Each upload makes its own lookup at its turn in
  its event's chain.
- A pass stops handing out records when its door closes (`sweepDoorClosed`): at once when the server named a wait,
  which is about this device, not one record; when it named none, after three failures in a row with none landing
  between, which is what an outage looks like. A refusal never closes it.
- Follow-up passes (`sweepFollowUpDelay`) come only after a transient failure, with records left (discard checks
  still owed included) and a network path up: after the server's wait, else 2 s doubling per pass that landed
  nothing, either one clamped to 2 to 120 s; at most 20 passes, at most 3 in a row that land nothing. A refusal is
  an answer the next trigger can ask again, and an offline phone has the reconnect. `retryPendingSync()` returns
  after the first pass, since the Event Log and the launch follow it with a pull; the follow-ups run on a task the
  engine owns, which no screen's closing cancels (item 79).
- A backlog of late disarms raises one "disarmed" alert: a disarm or a cancelled countdown sent more than ten minutes
  after it happened is late, and of a pass's late ones only the newest alerts; when its alert did not go out, the
  newest whose record landed carries it (`lateDisarmAlertStandIn`; item 74's line 9, item 162's ds4f1-1017-6, item
  187's deepseek-5).

### 6. Attachments reopen the upload

- Synced is final for every other write (`EventStore.mayTransitionSyncState`; ADR 0006): a late duplicate's failure
  cannot walk a synced event back.
- Every site that attaches a capture to its event (the trigger response, the blackout still, the flood still, the
  interrupted capture's retry, a capture that finishes late) writes the event's final state with
  `updateAndReopenForReupload`: one write that merges it under the monotonic rule and walks synced back to pending. A
  sparse upload that landed during the capture is then not the event's last word, and a kill after any write leaves an
  event the sweep retries and the byte limit does not count as in iCloud (item 155's A1 and S1). A mirrored copy is
  never reopened. A sparse result that lands after the attachment is refused by section 1's rule.
- A fact that fails, a thumbnail still owed included, reopens its row inside the event's chain, before the next write
  starts (`factFailed`, `reopenAfterFailedFact`): this phone's own row only, and only while it still matches what the
  fact sent, apart from the sync state, the receipts, the two cached media file names and the discard check still
  owed, which the byte limit, a download or a presence answer can change meanwhile (item 175).
- A metadata save that lands while its thumbnail could not be staged still lets the full captures go up, and leaves
  the event pending with no interference verdict; the next retry stages the thumbnail and sends the same revision.

### 7. The files an upload sends

- An upload pins its event (`EventStore.beginUpload`), so that the limits leave it and its files alone until the
  upload ends, and only then reads the files the log's copy names: the byte limit may have discarded those of the copy
  the upload was handed (item 166's codex-27). A row gone from the log keeps its copy's files, and a name that is not a
  plain file name sends no file (item 187).

## Consequences

- Within a process no write for an event starts before the one ahead of it has finished or timed out, and none carries an
  older copy of the event than the log held at its turn. A save that times out is cancelled, not recalled: whether iCloud
  can still apply one it had received is out of the app's sight, and saves do not depend on iCloud's copy, so an older save
  landing last is not ruled out, which is as far as ADR 0003's first consequence holds. After a relaunch the chains start
  empty, and each write sends the log's copy.
- A slow upload on one event's chain delays no other event's. A clip that keeps moving takes its time; one that stops
  fails at the stall, as a lost path does, and the sweep goes on with the other records.
- No iCloud wait on the iPhone holds its caller past its deadline. The watch's two reads run on past theirs, their
  answers dropped; the retention pass's reads and deletions end at their deadline, not when their caller is cancelled.
- What CloudKit has already accepted stays: an account change cancels the operations under way, and a lapsed lease or
  the backup switch stops what has not started.
- The Simulator has no iCloud container, so a live CloudKit answer, its progress and its partial failures are
  exercised only on devices: a seeded backlog of several hundred records went up in one pass with no request to slow
  down (2026-09-25, the development environment; production not measured); a 60 s clip on a slowed uplink landed in
  one attempt (1.8.1); with Guided Access's Side Button on, one press, the "locked" record and its alert reached the
  second device (TestFlight 78). The follow-up passes after a throttle are pinned by unit tests.
- Not taken: status records batched into one operation (item 74's line 8, ruled not needed on 2026-09-28, to reopen if
  a throttle is ever seen); the account identity cached to skip the lookup (ADR 0076 resolves it fresh, and an account
  change invalidates through the generation).
