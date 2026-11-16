# ADR 0083: A set-aside log's Delete writes a note first, so its status entry is never lost

- **Status:** accepted. BACKLOG item 235's A11, in 1.13 (item 240's list); the design `docs/design/1.13-fixes.md`, part
  3a, APPROVED 2026-11-12 (the owner: "as you recommend, wording approved", W3). Supersedes in part ADR 0078 (decision
  7's first limit, and the consequence naming item 235), which has had three amendments; its decision 7 otherwise stands.
- **Date:** 2026-11-12

## Context

Since 1.12 a set-aside log's Delete leaves a status entry: when the log was set aside, how many records it had, how many
photos and clips went with it or that they were left (ADR 0078's decision 7, item 234). The entry is written once the
store's delete has returned. Malinois stopped in between, while the store finds and removes the log's photos, left the
log gone and no entry: the one way a Delete could leave no record.

## Decision

1. **Before the store's delete, the engine has the store write a note** beside the log
   (`EventStore.oweSetAsideDeleteEntry`, file `set-aside-deletes-owed.json`): the log's name, when it was set aside, the
   moment of the Delete, and the ID the Delete's entry is written under. It is written on the store's queue, so on disk
   before the delete's own turn there.
2. **The entry is written under the note's ID, and the note retired after it** (`MonitoringEngine.deleteSetAsideLog`).
   The note is retired also when nothing was deleted, or the log was gone already.
3. **At each launch, and after the unlock's reload, once the set-aside logs are listed and the journal recovered,** the
   store reads the notes (`loadSetAsideDeletesOwed`): one whose log is still listed deleted nothing, and goes; one whose
   entry is in the log (the shared ID; the journal may have brought it back) was done, and goes; each of the others is
   handed to the engine, which writes its entry at the moment of the Delete, under the note's ID, placed by its time,
   with no counts, and the note goes. Its words (the owner's W3): "A set-aside log from Nov 7, 1:25 PM was deleted;
   Malinois was stopped before it could count what went with it", or without a time "A set-aside log was deleted; ...".
4. **The kind carries counts not known** as "-" in all three together (`setAsideDeleted.<when>.-.-.-`), and is read only
   so; 1.12 and older leave out a kind they cannot read, as they do now.

## Consequences

- A Delete leaves its entry whatever stops Malinois, at once or at the next launch, if its note could be written. On
  storage too full for the note, the Delete still goes ahead, and a stop in that moment leaves no entry (the owner's
  ruling after 1.13's full review, item 241's A2, 2026-11-13).
- A note file that cannot be read is removed with a log line, and its entries are lost, as every such entry was before.
- An edited backup restored to the phone could add a note, and so an entry saying that a log was deleted. It can never
  take an entry away; such an entry only makes the owner look.
- Not changed: what the entry says when the Delete finished (ADR 0078's decision 7), the photos a Delete left, which the
  launch's sweep clears with no entry of its own once no set-aside log is kept.
- Tests: `Item235DeleteOwedEntryTests`, through the engine's own Delete and a store made again over the same folder, as at
  a launch.
