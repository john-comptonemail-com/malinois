# ADR 0035: Separate incident and status retention budgets

- **Status:** accepted; supersedes the prior shared 500-row count policy. Amended for 1.7 (BACKLOG 114):
  a row whose upload is running is never taken, and on Pro a removal of evidence meant for iCloud leaves
  a status entry (Consequences). Amended again 2026-10-14 (BACKLOG 116, Codex's review): status entries'
  uploads are protected too, and the launch trims, the media clean-up and the entry's daily limit hold.
  Amended 2026-10-26 (BACKLOG 166's A1): the report a removal owes is kept on disk until it has run.
- **Date:** 2026-10-10

## Context

B21 on the 1.5 candidate exposed a pre-existing retention defect also present in
1.4: the shared 500-row cap evicted all incident classes before status rows. A log
with 499 statuses kept only one incident; each later incident replaced it, and a
disarm could evict the last incident. Tamper warnings still appeared because
detection and capture ran, while the log silently removed their records and media.
A synthetic regression reproduced the five-incidents-to-one loss and disarm loss.

The owner approved 500 incidents plus 100 recent status entries, retaining the
existing 2,000,000,000-byte media budget. Cloud copies must not erase first-hand
evidence; sustained floods and pending captures retain their existing priorities.

## Decision

1. The local count limits are 500 incidents and 100 status entries. Status includes
   state changes and interruption rows. Neither pool borrows unused capacity.
2. Each pool first discards mirrored copies. Incidents then discard flood records,
   synced incidents and finally pending incidents, oldest first within each class.
   Status entries discard oldest owned entries after mirrors, regardless of sync.
3. Protect the newest first-hand row in each pool, including an in-flight incident.
   A newest mirror is expendable. Production limits are positive; the pure policy
   retains one owned row even if a caller supplies a zero cap.
4. Apply count limits on addition, cloud merge, journal recovery and successful
   launch/unlock loading. Persist the new snapshot before queued media cleanup.
   Journal lines for migration-evicted rows retire only after a successful snapshot
   and the existing full-sync checkpoint. Failed or locked loads stay protected.
5. Keep the shared media-byte policy unchanged. Count eviction removes local media
   attached to evicted rows; byte eviction can remove media while retaining its row.
6. Use 600 as the bounded cloud restore request size per record type. Fetching that
   prefix does not guarantee 500 incidents and 100 statuses will be found; this is a
   local capacity policy, not a complete-history restoration promise.
7. The debug backlog seeder uses free status slots and mirrored status slots only.
   Incident slots or incident copies cannot fund synthetic status records.

## Consequences

- Routine status accumulation cannot erase incident history. An incident flood
  cannot erase the status pool. Both remain bounded; pending evidence can still be
  evicted when its own pool fills, and old unsynced statuses can leave at 100.
- From 1.7 (BACKLOG 114, 116): a row whose upload is running (an incident's evidence or a
  status entry's record) is never taken and no newer row goes in its place; it counts as
  going, and the store applies the budget again when the upload ends, by when it is usually
  synced. The media byte cap does the same for its media, and looks again at once when the
  upload it waited for ended while it measured the files. On Pro, when the incident budget
  removes evidence this phone was meant to upload and had not fully uploaded, the log keeps
  one status entry saying so per watch (per day while disarmed, kept across relaunches; a
  clock moved back makes it due). Removals made while the log loads at launch are kept by the
  store (every removal the entry could count, an unsynced first-hand incident, without its
  thumbnail; nothing else, and none dropped: a bound lost the very loss to report, BACKLOG 116's
  P1 and Q1) and reported once the engine listens, after the Pro check answers (normally within
  seconds; StoreKit is not forced to answer, and until it does the copies stay in memory); an app
  ended before then loses that report. Each removal carries the watch it was made in,
  read when it was made, so a disarm before its report runs leaves it a loss of that watch
  (BACKLOG 116, N2 of Codex's second look).
- On upgrade, older status rows beyond the new budget leave the local log. This
  does not delete their CloudKit records or recreate evidence already evicted.
- Stored media, the journal format and settings format do not change. No reset or
  reinstall is needed. Simulator checks cannot establish physical capture quality.
- The store and engine share the existing heartbeat registry. Before pruning a log
  read successfully from disk, seed all its owned arm IDs/start times once, including
  journal recovery and unlock reconciliation. The keys and stored representation
  stay unchanged; a sealed or fresh log does not complete this migration. Arm rows
  already evicted before upgrade still cannot be discovered locally (ADR 0022).
- This correction is prepared for 1.5 on its own branch. It must also be carried
  into 2.0 before that release; no release/main merge is implied by the fix.

## Amendment (2026-10-26, 1.8.2): the report owed is kept on disk

The entry's report of a removal ran on a later turn of the main actor and was owed only in memory,
while the file queue wrote the log without the removed events and deleted their media. A kill in
between left neither the events nor the entry (BACKLOG 166's A1, Codex's codex-1, shown by its probe
at the incident limit); the launch trims' report was lost the same way when the app ended before the
Pro check answered, the consequence accepted above. Now every removal the entry could count is
written beside the log (`reports-owed.json`: the light copies and the watch) on the file queue
before the log that drops it, read back at the next launch and after the unlock reload (less any
event the journal brought back), handed to the report like the launch trims, and retired once its
report has run: the entry it adds is journaled before then. The file is written only when the log
is, never while it waits for the first unlock. Older versions ignore the file; the entry's daily
limit still decides whether a replayed report writes one. Tests: `Item166ReviewTests`.

Codex's look at that change (codex-22): the journal's recovery at launch trims the log too, and it wrote the file before
the launch had read it, so a crash after its log write lost the reports a launch before owed; and a failed write of the
file was only logged while the log that drops the events was written and their media deleted. Now the file is read
before the journal's recovery (and at the unlock reload before the recovery and the reconciliation), every log write
first makes sure the reports owed are on disk, writing them again if the last write failed, and fails (Home's banner,
the media kept) while it cannot; a file that cannot be read is set aside (`reports-owed.corrupt-<time>.json`), never
written over, and if it cannot be moved no log that drops an event whose report is owed is written.
The reports read at an unlock are handed to a report already listening only after the recovery, less the
incidents it brought back (codex-26: one handed over first went out for an incident the log held again).
