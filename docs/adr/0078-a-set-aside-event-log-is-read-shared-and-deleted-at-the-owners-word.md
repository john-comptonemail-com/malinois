# ADR 0078: A set-aside event log is read, shared and deleted at the owner's word

- **Status:** accepted (the owner, 2026-11-07: "as you recommend, wording approved": decisions 1 (a), 2 (a), 3 (a) and 4 (a) of
  `docs/design/set-aside-log.md`, BACKLOG item 122). Extends ADR 0048, whose three decisions stand. Decision 3 as ruled the same day
  (the owner: "as you recommend, wording approved", Claude's (a)): the photos and clips only the log names go with it, at once.
  Decision 5 added 2026-11-09 and decision 6 on 2026-11-10 (the owner: "2", BACKLOG item 227), both before this record's
  first release. Decision 3 says which names a set-aside log names since 2026-11-11 (the owner: "a, wording approved",
  BACKLOG item 231; it takes the place of item 230's clause of the same day, which claimed more than held), also before it.
  Decision 3 puts the Malinois PIN in front of Delete, and decision 2's README says which photos and clips the ZIP has,
  since the same day (the owner: "as you recommend, wording approved", BACKLOG item 232, the second full review), also
  before it. Decision 7, the status entry a Delete leaves, added the same day (the owner: "1", "wording approved
  also", BACKLOG item 234, the third full review), also before it.
- **Date:** 2026-11-07
- **Summary:** A set-aside event log is read record by record and listed at the top of the Event Log, on a screen of its own that
  shows what could be read, read only. Nothing read from it goes back into the log. Share sends the file as the phone kept it, with
  the photos and clips it names that are still on the phone. Only the owner deletes one, behind the Malinois PIN, with the photos
  and clips only it names, and the Delete leaves a status entry in the Event Log. Home says so while any is kept.

## Context

When `events.json` does not decode at launch, `EventStore` renames it `events.corrupt-<seconds>.json` and starts a fresh log. Since
1.7 (70) nothing deletes one, nor the photos and clips it names (ADR 0048), but nothing read one either: one record an older build
does not know put the whole log out of sight for good, and Home said so at that launch only.

Since 1.10 the phone signs its records, and when a signed record leaves the log other than by its size limit, the signer names it in a
signed statement and the event log says "A signed record from Oct 14, 9:03 PM is no longer in the log" (items 182 and 190). The records
of a set-aside log are such records: that statement stays true only if they stay out of the log.

## Decision

1. **The records a set-aside log can read are shown on a screen of their own, never put back into the log.** The log is read record
   by record: a record this build cannot read, or damaged bytes inside one, cost that record only, and where the list breaks off the
   rest counts as one unreadable part, as do bytes after the list's end, white space aside (decision 5). The Event Log lists each set-aside log at its top, also over an empty log, with when it was
   set aside and how many records it could and could not read. Its screen shows the records newest first; each opens read only, as
   the log has it, with no Share of its own, no download and nothing asked of iCloud; a record the event log also has (from the
   journal, or a pull from iCloud) is marked so. The screen reads the file and never writes it.
2. **Share sends one ZIP**: the file as the phone kept it, byte for byte; each photo and clip on the phone that the file names
   (decision 3 says by which names);
   and a README saying that the ZIP has the photos and clips the file names "that were still on the iPhone when it was
   shared" (since item 232, DeepSeek's DS-1: it said "the photos and clips it names", which a file no longer on the phone
   made untrue), that it is not signed evidence and that Malinois's verifier does not check it. It is made in a folder of its own
   under the temporary folder, as the evidence ZIP is, and removed once the share is over.
3. **Only the owner deletes a set-aside log**, from its screen: Delete asks for the Malinois PIN, every time and however the
   Event Log was opened, and then for a confirmation (its words are in decision 6). The Event Log opens with a face or finger
   where the owner turned that on, as one of the two read surfaces (ADR 0056), and a face or finger deletes no set-aside
   log there, as it changes no setting (what else it can do there is BACKLOG item 233): the pad is titled "Enter PIN to
   delete this log" and takes the PIN only; a pad the owner cancels
   opens nothing; one entry of the PIN opens one confirmation; and when Malinois goes to the background the pad and the
   confirmation close, as the Event Log itself does (added 2026-11-11, before this record's first release: BACKLOG item 232,
   Codex 1 of the second full review; until then Delete asked for the confirmation alone). The file
   goes, and at once each photo and clip it names that nothing else names: not the event log, in memory or on disk; not
   another set-aside log; not a capture still being saved. **A set-aside log names a photo or clip only by a name the store
   gives one**: a UUID in capitals and `.jpg` or `.mov`, as every build has written them. The log does not decode as a
   whole, so its bytes are searched for a name, while its screen decodes its records, and the two must agree on what it
   names. For a name of that form in a photo's field they do: JSON writes each of its characters as itself or as a
   `\u` escape, and the search reads both. The search does not know fields, though: a name of that form elsewhere in
   the file (only an edited backup writes one there) counts too, so Delete removes that file when nothing else names
   it, where the screen shows no photo for it (BACKLOG item 236's A6, for later; once no set-aside log is kept, the
   launch's sweep takes such a file anyway). For a wider name they did not (a quote's two escapes, an accented
   letter's two forms), so the screen, Share and Delete take no file under one: it stays where it is, with nothing to
   tell (once no set-aside log
   is kept, the launch's sweep takes it if it has a UUID before its last dot and no record names it). When the log on
   disk or a capture's record cannot be read, the photos and clips stay, and a log whose bytes cannot be read
   goes alone: the launch's media sweep takes what nothing names once no set-aside log is left. The photos and clips stay too
   when another set-aside log, the media folder or the store's own folder cannot be read. No launch and no limit deletes a
   set-aside log or its media (ADR 0048, unchanged).
4. **Home says so while any set-aside log is kept**, pointing to the Event Log, not only at the launch that set it aside.
5. **A set-aside log is a plain file, and so is each photo or clip it names** (added 2026-11-09, before this record's first
   release: BACKLOG item 218, Codex's look at all of 1.12). The list, the screen's reading, Share and Delete take neither a
   folder nor a link under a set-aside log's name or a photo's, and nothing through a media folder that is a link; the search
   for the photos a set-aside log may name opens plain files only. Only an edited backup restored to the phone can put such
   things there. A folder or a link named like a set-aside log is not listed and has no notice; its name still holds the
   media sweep and the removals behind the limits, so that nothing is deleted on its account. Bytes after the list's end
   count as one unreadable part.
6. **Its screens say what the file recorded of iCloud, never what iCloud has now, and Delete tells the owner what it did** (added
   2026-11-10, before this record's first release: BACKLOG item 227, the full review of 1.12 by other agents; the owner: "2"). A
   record backed up before its log was set aside reads "Synced when set aside", in grey, where it read "iCloud synced", in green,
   and the screen's explanation ends "A badge shows whether a record was backed up to iCloud when the log was set aside; Malinois
   doesn't check again." It said that the records backed up "are still there": nothing checks that, and the retention setting
   removes old full photos and clips from iCloud as a matter of course, while a set-aside log's stay on the phone until its
   Delete. The confirmation reads "Delete this set-aside log? The photos and clips only it names are deleted from this iPhone too,
   whether or not iCloud has full copies of them. After the last set-aside log is deleted, Malinois also clears photos and clips
   that no record names. This can't be undone." Its second sentence is decision 3's sweep, which nothing had told the owner.
   Delete answers what it did (`SetAsideLogDeletion`): where it had to leave the photos and clips (decision 3's cases, and a
   removal that fails), or deleted nothing, the Event Log, where its screen leaves for, says so in a row at its top, each kind
   once, until the owner dismisses it there or Malinois is closed (the answers are kept in memory, not in a file: BACKLOG
   item 234's DVF-6): not by leaving the Event Log, and a later whole delete takes nothing away. A Delete
   of a log already gone answers that it is gone. Asking iCloud about a set-aside record is still not done.
7. **A Delete leaves a status entry in the Event Log** (added 2026-11-11, before this record's first release: BACKLOG item
   234, the third full review's Claude-1; the owner: "1", "wording approved also"). A Delete removes records and photos
   from the phone, behind the PIN, and it left no record of itself, where a disarm, a settings change and a PIN change
   each leave a status entry that someone who has learned the PIN cannot remove. The app's Delete is the engine's
   (`MonitoringEngine.deleteSetAsideLog`): the store's delete and the entry are one step, as a PIN change and its
   record are, and no screen deletes through the store. The entry is written when that call removed the log's file:
   none where nothing was deleted, and none for a log already gone. It reads "A set-aside log from Nov 7, 1:25 PM was
   deleted: 37 records, 4 photos and clips", or, where its photos and clips were left, "... was deleted: 37 records;
   its photos and clips were left on this iPhone" (the owner's approved words): the time in the log's name, which its
   row showed; the records its screen could read; and the photos and clips that went with it. For what those two do
   not cover the words are Claude's, approved too: "..., 2 photos and clips; others were left on this iPhone"
   where a removal failed part of the way; no count of records for a log whose bytes could not be read; "A set-aside
   log was deleted: ..." for a name without a time. Its row in the Event Log shows the whole sentence, where a status
   entry's row has one line: its numbers are at the sentence's end. It is a status entry like the others: signed with the log,
   uploaded on Pro, shown on the owner's other devices from this version on (an older version drops a kind it does
   not know), and removed in time by the log's limit for status entries. Its numbers ride in its kind
   (`setAsideDeleted.` and four parts), which is read only as written. It says that a log went and how much went
   with it, not which records or photos. Two limits, found by the second inventory. The entry is written once the
   store's delete has returned: if Malinois is stopped between the file's removal and the entry's write, the time
   the store takes to find and remove the log's photos (well under a second for an ordinary log, longer for a very
   large one), the log is gone and no entry is written; closing that takes a note kept before the delete and an
   entry owed at the next launch, which is BACKLOG item 234's A11, for the owner's ruling. And photos a Delete left
   that no record names are cleared by the launch's sweep once no set-aside log is kept, as the confirmation says,
   with no entry of their own.

## Path inventory

`docs/design/set-aside-log.md` lists every path that can delete a set-aside log or its media, or send it off the phone. The only new
ones are the owner's Share and the owner's Delete (`MonitoringEngine.deleteSetAsideLog`, the one caller in the app of the store's
delete, which deletes the photos and clips only the log names itself, by decision 3, rather than leaving them to the sweep, as
the design first had it, and answers what it did for the status entry of decision 7). The byte limit, the other files the
app keeps apart, the uploads and the signer are unchanged; the media sweep and the removal behind the limits changed only to take
plain files in a real media folder (decision 5).

## Consequences

- An owner can read and share a log that went out of sight, on any tier, without iCloud.
- What the phone signed about those records stays true. A signed evidence ZIP for one of them is not offered: that would need a
  design of its own.
- A set-aside log and its media keep their space until the owner deletes the log.
- An owner who deletes a set-aside log is told when its photos and clips may have stayed, or when nothing was deleted; no
  screen of a set-aside log says what iCloud has now.
- A Delete leaves a record that it happened and how much went with it: in the Event Log, signed with it, and on Pro in
  iCloud. Someone who has learned the PIN can still delete a set-aside log, and leaves that record, unless Malinois is
  stopped in the moment between the delete and the entry (decision 7; to be closed in the release after 1.12, BACKLOG
  item 235). The record stays until the log's limit for status entries removes it.
