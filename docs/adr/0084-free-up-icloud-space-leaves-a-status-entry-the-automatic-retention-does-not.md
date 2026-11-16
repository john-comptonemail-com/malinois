# ADR 0084: "Free up iCloud space..." leaves a status entry; the automatic retention does not

- **Status:** accepted. BACKLOG item 235's A10, in 1.13 (item 240's list); the design `docs/design/1.13-fixes.md`, part
  3b, APPROVED 2026-11-12 (the owner: "as you recommend, wording approved": D4 (a), W4). Amended 2026-11-14 (item
  242; below): when the entry is written, and a setting changed and taken back unrecorded.
- **Date:** 2026-11-12

## Context

Settings' "Free up iCloud space..." (the Manual retention mode, Pro) deletes iCloud's full photos and clips of the
events older than a period the owner chooses (1, 3, 6 or 12 months; never newer than 30 days, by iCloud's own clock).
It removes evidence behind the PIN, as a set-aside log's Delete does, and wrote no entry in the Event Log, where a
Delete, a PIN change and a settings change each leave one (item 234's A10, from round ten's inventories).

## Decision

1. **The purge goes through the engine** (`MonitoringEngine.freeUpICloudSpace`), which writes a quiet status entry once
   the purge has sent its deletions: the period chosen and how many events' full media iCloud was asked to delete, with
   "some couldn't be deleted" when part of it failed. Its kind is `iCloudMediaPurged.<months>.<events>.<failed>`, read only
   as written; its words (the owner's W4): "Full photos and clips of 37 events older than 6 months were deleted from
   iCloud" ("1 event", "1 month"). Like the other status entries: signed with the log, uploaded on Pro, no alert; its
   row shows the whole sentence, with the bin icon a Delete's entry has.
2. **It counts events, not files:** the purge asks iCloud to delete every name an old event's photos could have, and a
   name with nothing under it counts as deleted, so how many files went is not known.
3. **The daily automatic retention writes no entry** (the owner's D4): it follows a setting, and every change of that
   setting is already in the log.

## Consequences

- The Event Log shows when someone with the PIN cleared iCloud's full media, and how far back.
- A purge that found no event old enough, or sent nothing, writes none; Settings' own line says what it did, as before.
- An older version leaves out a kind it does not know, as it does for the others.
- Tests: `Item235PurgeEntryTests`, with Settings laid out and its button and dialog pressed.

## Amendment (2026-11-14, item 242): when the entry is written, and a setting taken back unrecorded

The second full review of 1.13 (BACKLOG item 242's A8 and A4) read two sentences above against the code. Neither
decision changes; what they say does.

- **Decision 1:** the entry is written when the purge returns, and only when iCloud confirmed at least one deletion
  (`MonitoringEngine+AuditRecords.swift`), not "once the purge has sent its deletions". So a purge the app ended part
  way leaves no entry, and neither does one whose deletions iCloud may have made without its answer arriving. A note
  written before the first batch, as a set-aside log's Delete writes one (ADR 0083), and an entry whenever a batch went,
  are for 1.14 (item 242's A8).
- **Decision 3:** its reason does not hold for a change made and taken back in one visit to Settings. The picker writes
  the setting at once; a return to the screen with Settings still open (Notification Centre pulled down, a Face ID
  sheet) runs the daily retention on it; and the change is recorded only when Settings closes or at an arm. So a pass
  can delete on a value the log never shows. A pass that acts only on a recorded value is for 1.14 (item 242's A4).
