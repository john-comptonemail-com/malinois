# ADR 0048: A set-aside event log and its media are kept

- **Status:** accepted (the owner, 2026-10-15: item 120's F5, "all as recommended": the stopgap in 1.7 (70), the
  full design in 1.8, item 122). A stopgap: item 122's design will replace or extend it. **Amended the same day**
  after Codex's look at build 70 (V1): the inventory had missed that the current log can share a file with a
  set-aside log; decision 3 now covers it.
- **Date:** 2026-10-15

## Context

When `events.json` does not decode at launch, `EventStore` renames it `events.corrupt-<seconds>.json` and starts a
fresh log; Home says so until the next clean launch (F-11, item 73's R2.2). Since the seventh review (#6) a launch
that read the fresh log cleanly then deleted any set-aside log older than 30 days, and all but the newest three,
before its media sweep; the sweep, which deletes nothing while a set-aside log exists, then deleted every photo and
clip no current event referred to, which is every file only the set-aside log knew. The top-down review of 1.7 (69)
(F5) found this worse than recorded: one record an older build cannot decode (a TestFlight tester going back a build)
sets aside the whole log, the owner may miss the one-launch notice, and a month later the evidence is deleted. On the
free tier there is no other copy. Nothing in the app reads a set-aside log or lets the owner export it.

## Decision

1. **No launch deletes a set-aside event log**, whatever its age or how many there are. The settings stashes
   (`AppSettings`, `com.malinois.settings.corrupt-*`) keep their own limit (the newest three, for a month): they
   hold settings, not evidence.
2. **The media sweep stays held while any set-aside log exists** (unchanged), and also when the store's folder
   cannot be listed, so a set-aside log's photos and clips are kept with it.
3. **No limit or eviction deletes a file a set-aside log may refer to.** `EventStore.deleteMediaNames`, through
   which every limit deletes, keeps any name whose bytes appear in a set-aside log, and keeps all of them when the
   folder or a set-aside log cannot be read (the log does not decode, so its bytes are searched; the names are
   UUIDs).
4. Home's notice no longer says the backup is kept for 30 days.

## Path inventory: what can delete a set-aside log or its media

- `EventStore.sweepOrphanedMedia`, at launch: deleted aged set-aside logs (removed by this decision), then swept
  unreferenced media (held while one exists, decision 2).
- `EventStore.deleteMediaNames` (count caps, the byte cap, restores, evictions): deletes only names that events in
  the current log refer to. Those can include a set-aside log's: the journal and an attachment intent can bring an
  event back, with its photo, after its log was set aside (Codex's V1, reproduced by a test), so decision 3 keeps
  them. A file so kept leaves the current log's byte count.
- The attachment checkpoint (`checkpointAttachments`): removes intent files, never media; a failed save removes
  only the file it was writing.
- `CameraController.sweepOrphanedPendingClips` and `sweepOrphanedClips`: the pending-clip folder and `tmp/`, never
  the media folder.
- iCloud clean-up: iCloud records only. Deleting the app: everything, as before.

## Consequences

- A set-aside log and its media stay on the phone until the app is deleted. Nothing reads them yet, and there is no
  way to export them: item 122 (1.8) proposes reading the log record by record, a notice that lasts until the owner
  acts, and Share on a set-aside log.
- While one exists, true leaks (a file whose event was evicted before its update landed, a deletion that failed)
  are no longer reclaimed, files the limits keep for it no longer count toward the byte limit, and repeated
  corruption adds a set-aside log each time, with no limit. All were rare before this decision and cost storage,
  not evidence. A deletion while a set-aside log cannot be read (the phone locked) keeps its files for good.
- An older build installed over 1.7 (70) still deletes set-aside logs after 30 days, as before.
