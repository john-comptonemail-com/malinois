# ADR 0074: Full-media retrieval by record name, checked against what the phone signed

- **Status:** accepted (the owner, 2026-11-04: "a, approved"; BACKLOG item 190's A4, its download half, item 192's
  step 2). Supersedes ADR 0002, whose decision and three amendments it restates with the check decision 5 adds (the
  owner's rule of 2026-11-01: a further change to a record amended three times is a new record).
- **Date:** 2026-11-04

## Context

Full-resolution captures upload to CloudKit as photo records named after their event and slot
(`photo-<slot>[-v2]-<eventID>`), and "Download full evidence from iCloud" on an event's detail screen brings them back
by those names (ADR 0002, 2026-08-26; the Pro promise that evidence survives the phone). Since 1.10 the phone signs each
of its records at each revision, its photos' and clips' digests included (ADR 0066), and the Mac verifier says when a
signed photo's bytes changed between a record's revisions. But a photo saved in iCloud under the name of one of this
iPhone's own photos still joined that record at the next download, and the phone signed the record again with it: anyone
able to write the owner's private iCloud records could put other bytes in a signed record, which the phone itself then
vouched for (BACKLOG item 190's A4, codex-3 on 1.10 (81); the owner's ruling of 2026-11-02, "A4 a": the verifier's half
in 1.10, the download's later).

## Decision

1. **Retrieval by deterministic record ID** (ADR 0002): no query, no index and no schema change, so it works against the
   Production container as deployed. Both generations, v2 preferred; the asset's kind from its leading bytes; the store
   takes a downloaded capture as it takes a fresh one (a UUID file name, evidence-grade protection, a derived
   thumbnail); on demand from the event's detail screen, never in bulk.
2. **The names a download asks for** (ADR 0002's amendment of 2026-10-24): this iPhone's own record asks only for the
   cameras it names (`Event.downloadManifest`), and for none when it names none; a copy from another device asks for the
   names its record lists, each allowed name once, or every name when it lists none.
3. **The offer** (the amendment of 2026-10-26): on every visit while the record names a file this iPhone does not hold
   (`Event.namesMediaNotHeldHere`, `Event.mayLackAFileHere`); a capture that came back but could not be kept here leaves
   the download incomplete, and the screen says to try again for the rest.
4. **A record's list of its media** (the amendment of 2026-10-27): the files held and those this phone knows reached
   iCloud (`Event.uploadedMedia`), each name once.
5. **A capture of a record this phone signed joins it only as signed** (new, 1.11). Before a downloaded photo or clip
   fills its slot, its bytes are compared with the digest the latest revision naming that slot signed
   (`EvidenceSigner.whileSigningHeld(mediaOf:_:)`, from the signatures this phone made or its file's read checked under
   their key; `MonitoringCloudCoordinator.mayFill`). The comparison and the attachment fall in one turn of the signer's,
   as a pass or a share signs alone: a signature in progress is finished first, the lines the file refused are written
   first and one it still refuses counts, and no signature is made between the comparison and the attachment (item 194's
   codex-1). One that differs is not added and iCloud's copy is left as it is; the event's screen says, in the owner's
   words: "A capture in iCloud differs from the one this iPhone recorded, so it wasn't added - iCloud's copy is
   unchanged." A slot no revision of this phone's names (a copy from another device, a record from before 1.10, or one
   signed without it) takes the capture as before. While the signer cannot read its file, a capture is never added
   unchecked: it waits, and the download is left to try again.

## Consequences

- From ADR 0002: what uploads can come back, media the local byte cap removed included; no schema deploy, so nothing new
  can fail silently in Production; the record names are load-bearing, `fullMediaRecordNames` in step with `exfiltrate`'s
  suffixes, both pinned by tests.
- The swap ADR 0002's first amendment left open is closed for every capture this phone signed: a photo saved under the
  name of one of its own no longer joins unless it is the one signed, so the phone never signs it into the record. It
  stays open where no signature covers the slot, as stated above.
- Nothing is written about a refusal: the record and its signatures stay as signed, and the screen's line is shown at
  the download only (the owner's ruling, option a). Not taken: a note the event keeps on this phone (b), and a statement
  in the record's next signed revision (c), a second change to the evidence format in 1.11 that 1.10's verifier would
  refuse.
- The comparison sits where the capture is placed in its slot, after the store has written its file, so a capture is
  compared with the slot it fills; a file the download stored that does not join its record (refused, its slot filled
  meanwhile, the record gone or the account changed) is removed at once, after a check that no record names it, so
  refused captures never pile up outside the storage limit (item 194's codex-2).
- The latest revision naming the slot is the reference (Claude's choice, noted to the owner): a file that changed in
  place and was signed again is compared with its later bytes, and an earlier revision's photo is refused.
- What ADR 0002's amendments left stands: a file a record names that never reaches iCloud, or was since removed from it,
  keeps the offer up, and a tap says nothing came back; a capture uploaded before 1.8.2 has no record of what landed;
  the list repairs a record at its next push only.

Tests: `Item190DownloadCheckTests` (decision 5, through the engine's own download, the signer's own file and the screen
laid out for real), `Item163RecordCapsTests` and `Item167ReviewTests` (decisions 2 to 4).
