# ADR 0002: Full-media retrieval by deterministic record ID

- **Status:** accepted
- **Date:** 2026-08-26

## Context

Full-resolution captures upload to CloudKit as photo records, but every read path fetched
only metadata and state records — nothing anywhere could bring a full capture back. After
a theft or reinstall the owner held thumbnails of their own evidence, against a Pro
promise that it "survives the phone being taken" (34.B1). Two designs were considered: a
media manifest inside the meta record (typed, robust, but a new encrypted field —
requiring a Production schema deploy, which has burned this project twice), or direct
fetches of the deterministic photo-record names both generations already write
(`photo-<slot>[-v2]-<eventID>`).

## Decision

Retrieve by **deterministic record ID**. A fetch by ID needs no query, no index, and no
schema change, so it works against the Production container exactly as deployed. The
candidate list covers both generations (v2 preferred), the asset's kind is sniffed from
its leading bytes (the record carries no type field), and the store takes ownership of a
downloaded capture exactly as it does a fresh one — UUID filename, evidence-grade
protection, derived thumbnail. Retrieval is on-demand from the event's detail view, never
bulk: a restore must stay small enough to run on a push wake-up, and clips can be large.

## Consequences

- The Pro backup promise closes: what uploads can come back, including media the local
  byte cap evicted.
- No schema deploy, so nothing new can fail silently in Production.
- The name coupling becomes load-bearing: `fullMediaRecordNames` must change in lockstep
  with `exfiltrate`'s suffixes — both sides are pinned by unit tests.
- A typed media manifest in the meta record (with camera, duration, availability) remains
  the more robust 1.2 evolution; it subsumes this mechanism without invalidating it.

## Amendment (2026-10-24, 1.8.2): this iPhone's own record asks only for its own names

A download asked for all four slot names, in both generations, whenever the record carried no list of its media, and
this iPhone's own records never carry one. So a photo record that any writer of the owner's private database saved
under an event's ID could join this iPhone's own record of that event: in a slot its capture never filled, under a
camera it never used, whose label the record then took (BACKLOG 152's lead 10, from the security audit's first run).
Since the first build every capture this app stores names its camera, and the upload names each photo record after it
(`photo-front`, `photo-rear`). A download into this iPhone's own record now asks only for the cameras the record names
(`Event.downloadManifest`), and for none when it names none: such a record stored no capture, so none went up. Copies
from other devices are unchanged: the names their record lists, or every name; since Codex's codex-13 on 1.8.2 the names
are each allowed name once, whatever list a record holds (one saved before 1.8.2's limits included). What remains: a photo saved under the
name of one of this iPhone's own photos still joins the record, since the app keeps no digest of what it uploaded
(SECURITY.md says so). Tests: `Item163RecordCapsTests`.

## Amendment (2026-10-26, 1.8.2): the offer stands while a file the record names is not here

"Download full evidence from iCloud" was offered on the event's detail screen while the record held no file, and,
after a download that could not check every name, for as long as that screen stayed open (1.3's R3-3 judged a lasting
offer not owed). Codex's full review of 1.8.2 (codex-2, BACKLOG item 167's A2): another device's Both capture whose
rear had not reached iCloud yet lost the offer once a download brought the front, for good, though the rear landed
later. The screen now offers it, on every visit, while the record names a file this iPhone does not hold
(`Event.namesMediaNotHeldHere`: each name a download asks for matched to the file it stands for, a camera's in the slot
labelled with it, so another camera's file never stands in for it (Codex's codex-7 on `073e5d2`: a copy holding only its
rear, merged with a later revision listing only its front, looked whole); nothing more once both of a record's two
slots hold a file; a camera whose capture failed names none), and no longer once every file it names is here, though
its first slot is empty: a capture whose only file is its rear (Codex's codex-5 on `0920241`; `Event.mayLackAFileHere`). A
copy from a version before the list of uploaded media names none and keeps the old rule, offered while its first file
is not here. A capture that came back but could not be kept here (it failed to stage or to store) leaves the download
incomplete, so the screen says to try again for the rest. What remains: a file a record names that never reaches
iCloud keeps the offer up, and a tap then says nothing came back. Tests: `Item167ReviewTests`.

## Amendment (2026-10-27, 1.8.2): a record's list of its media names what landed, too

A record's list of its media (the payload's `media`, `Event.mediaManifest`) named the files its maker held when it
uploaded. After the storage limit removed a capture's files and a download brought part of it back, the record pushed
next listed only that part, and another device, or this iPhone reinstalled, which asks iCloud only for listed names,
could never download a file that had landed and was still there (DeepSeek's deepseek-1 on `ce4c949`; codex-7's state
came from it). The owner's ruling (2026-10-27, option 1): the list names the files held and those this phone knows
reached iCloud (`Event.uploadedMedia`, kept through the storage limit), each name once. Not taken: a separate list of
the files that landed, a new field the receiving side would have to learn; and documenting the limit instead. What
remains (DeepSeek's look at the fix, `ce4c949..c00b178`, READY, with these recorded):
- a capture uploaded before 1.8.2 has no record of what landed, so its list still names only what is held;
- a file that landed and was since removed from iCloud (an encrypted-data reset, or the retention purge, which deletes
  old photo records and keeps the record) stays named, and a tap says nothing came back, as above;
- a file that landed while its save's reply was lost has no record here (ADR 0006): if the record names another file
  that is, a download asks only for the names it lists and not for that one. Before this amendment a capture with no
  file here listed nothing, and a download asked for every name (deepseek-4; needs the lost reply and the storage limit
  taking the files before a retry);
- the list repairs a record at its next push only (nothing pushes a synced record again by itself), and a device that
  already holds a copy of the same revision keeps that copy's list: a revision does not count the list (deepseek-5;
  records with a record of what landed come only from 1.8.2, which has not shipped).

Tests: `Item167ReviewTests`.
