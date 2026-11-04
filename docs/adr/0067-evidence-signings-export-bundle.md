# ADR 0067: Evidence signing's export bundle

- **Status:** accepted: the owner's rulings of 2026-10-31 ("1 - a, 2 - a, 3 - a"; "4 - yes, 5 - yes") and Claude's
  choices noted in `docs/design/evidence-signing.md`. The export statement and the bundle's format and check built on
  `claude/1.10`, 2026-10-31 (phase 4's steps 1 and 2), then the phone's export (step 3) and Share (step 4), Share
  corrected after its device check on the iPhone Air (`48507788`). Amended 2026-10-31 (item 182; below): absence
  statements in full, and the export statement names what the bundle shows. Amended again 2026-11-01 (Codex's change
  review; below): the check of what the export names in one pass; and a third time 2026-11-01 (item 182; below): no note
  of records set aside; and a fourth time 2026-11-01 (item 182; below): the keys' rule shared with the signer, and Share
  only after the signer's comparison; and a fifth time 2026-11-01 (item 182; below): and only once nothing it found gone
  is owed its name. Amends ADR 0065's rule on retention statements. **Superseded by ADR 0070** (2026-11-01, BACKLOG item
  187), which states the export bundle, its check and the Mac verifier as they stand; this record keeps its decision and
  its amendments.
- **Date:** 2026-10-31

## Context

Phase 4 of evidence signing (BACKLOG item 90): when the owner shares a signed record, the recipient must be able to
check it without the phone and without trusting the owner or the developer: the record came from Malinois on a genuine
iPhone, unchanged since it was signed, with no signature missing, and the rest of the log must stay private. A share
sheet can re-encode a loose file and break its signature, so the evidence travels as one archive. The Mac verifier
(phase 5) and the app's tests must read it with the same code. ADR 0065 sets the statements and the verifier's rules;
ADR 0066 the signer and its file.

## Decision

- **The export statement.** A fourth statement in `malinois-evidence/1`, type "export": the record shared, its latest
  revision, the time and the app's version, in that fixed order. The phone signs one at each export as the bundle's
  last signature and keeps it in its file like any signature, so the next bundle has no gap where it was.
- **The layout** (`malinois-evidence-bundle/1`, in `MalinoisEvidence/EvidenceBundle.swift`), one folder that iOS zips:
  `bundle.json` (the index: the format, the record, the phone's certified keys in order, each attachment's file);
  `keys/` (each key's statement and Apple's attestation); `signatures.jsonl` (every signature by those keys in the
  phone's order: its key, its assertion, the hash of what it signed, and whether that statement is shown);
  `statements/` (the statements shown, each under its hash); `notes.jsonl` (the phone's unsigned notes: a key lost;
  until the third amendment, how many records were set aside); `attachments/` (the shared record's photo or clip, thumbnail and traces). The index
  and each line are in the fixed JSON form. Since phase 5, `README.txt` beside the index (ADR 0068): not signed, and
  read by no check.
- **What is shown.** In full: the shared record's revisions, the watch around it (from the arm before it to the disarm
  after it), retention statements and the export statement. Every other signature only as the hash of what it signed
  (the owner's rulings).
- **The phone's export** (`Malinois/Services/EvidenceExporter.swift`). For a record this phone signed, the signer, in
  its turn (passes and exports sign one at a time, so the file keeps App Attest's counter order and a write during an
  export is signed after it), signs the export statement naming the record's latest signed revision and keeps it
  naming no record, so no retirement drops it. The bundle is built from the file as it then stands: the keys in the
  order certified, every signature in the file's order, the phone's notes, and the attachments the latest revision
  signed, from the files on the phone (a photo or clip only while it is a plain file in the media folder, the signer's
  own rule, named for its attachment with its own extension). The watch around the record: this phone's state changes
  and interruptions from the arm before it to the disarm after it (to the next arm or the log's end without one; from
  the record itself when its arm is gone). iOS zips the folder, named "Malinois evidence" and the record's date and
  time on the phone's clock, in a folder of its own in the app's temporary folder. A record with no signature of this
  phone's has no bundle and spends no signature; a bundle that cannot be made leaves nothing behind.
- **Share** (`Malinois/Views/EvidenceBundleItem.swift`, the event's screen). For a record this phone signed, the sheet
  opens at once with today's sentence and the photos or clips still on the phone, and the bundle as one more item;
  Share hands the sheet these items as it opens it. The bundle is made only by the sheet's operation for the
  destination the owner picks, on the sheet's own thread and at its priority, and never for a destination that takes
  no file (Save Image or Save Video, Print, Assign to Contact, Add to Reading List, Books, Markup and Copy). The sheet's
  own asks get only a bundle already made, or nothing: iOS asks for the items for Copy as soon as a sheet opens, on
  the main thread, before anything is picked. The bundle is kept for that share and removed once the sheet is gone,
  after which none is made. A share cancelled or left standing makes nothing and spends no signature. A bundle that
  cannot be made is left out and the rest goes as before; a record with no signature of this phone's shares as
  before. The launch clears any folder a share left behind (the app ended with its sheet open). Nothing new is on
  screen. The device check on the iPhone Air (2026-10-31) found two defects in the first build of this: iOS's early
  ask for Copy made the bundle, signing an export statement for every sheet left standing; and the first sheet a
  screen opened never carried the bundle, as SwiftUI built it from the screen as first drawn. Both fixed in
  `48507788` and checked again on the Air.
- **The check.** Each key's certification; every signature, over its hash when its statement is not shown; each key's
  counters from its first signature, every gap retired or reported missing; the bundle's last line as its export
  statement, with any counter of its key above it named; the shared record's revisions up to the one the export names,
  none missing and rising in the order signed; the attachments' bytes against the last revision shown. A signature
  that does not check out accounts for nothing; a statement shown that is missing or changed is named, and its
  signature still counts over its hash. The export statement, signed, names the record; the index only without it.
- **Retention statements** retire a key's counters only when signed by the key itself (for counters before its own) or
  by a key that follows it: one whose statement names it as the key it follows after a restore, directly or through
  keys in between. This answers the question ADR 0065 left to phase 4 (there, any later key's statement counted).
- **Reading.** The check throws only when the index is not the phone's (another format, not in the fixed form, a key
  twice, a file name that is not plain): then it judges nothing. Anything else it cannot read it names, item by item.
  It reads only plain files, whose names come from a hash, a key ID or a plain attachment name; never a link or a file
  in a linked folder; within size limits, and an attachment a megabyte at a time.

## Consequences

- Beyond the shared record, a recipient learns when that watch was armed and disarmed and its lapses, how many
  signatures the phone has made, the app's version and build channel at each, and (until the third amendment) how many
  records were set aside.
- A bundle whose export statement could not be signed (no key at that moment) checks up to its last signature, and the
  verifier says its end is unaccounted for. A bundle is a snapshot: an older one checks out as of its export's time.
- The index, the notes and the file names are unsigned, the phone's word: a check never takes them over a signed
  statement.
- A write that comes while an export signs waits a moment and is signed after it. An edit made just before Share is in
  the bundle once the log's write of it has reached the signer; one still on its way is in the next bundle.
- The bundle is made after the owner picks where to send it, so for a long clip the destination opens a moment later
  (the clip copied and zipped). Making it when Share is tapped instead would spend a signature on every share cancelled.
- Copy carries the sentence and the media without the bundle: a ZIP on the clipboard is of little use, and iOS asks for
  Copy's items before anything is picked. AirDrop, Mail, Messages, Save to Files and other apps get it.
- The bundle's making relies on iOS running the sheet's operation for a destination before it asks for the item on the
  main thread, as the device check's diagnostic showed for Save Video, Copy and Save to Files. Were iOS ever to ask
  first, that share would go without the bundle rather than spend a signature at the sheet's opening.
- Not taken: Apple Archive (other systems do not open it); one JSON file with the media inside (a third larger, and a
  long clip held in memory); every statement in full (the recipient would learn every arm, disarm and trip with its
  time); the record's own signatures alone (no claim that nothing is missing).
- The Mac verifier that reads a bundle with this code, the bundle's README and SECURITY.md's section: phase 5 (ADR
  0068), the wording the owner's (2026-10-31: "wording approved").

## Amendment (2026-10-31, item 182): absence statements, and what the export names

Whether a bundle shows a statement in full was not signed: whoever passed a bundle on could send a shown statement as
its hash alone, delete its text, and the check still passed, since its counter was still accounted for. That would hide
a status record of the watch around the event, or the new absence statement; a revision of the shared record or a
retention statement could not be hidden so (a revision missing, or counters missing). The owner chose (b), 2026-10-31
("B"), over (a), the export naming only the absence statements, and (c), neither:

- The export statement names every statement the bundle shows (`shown`): the shared record's revisions, the watch
  around it, the retention statements and the absence statements, by key and counter (`EvidenceSigner.shownCounters`,
  from the same watch the exporter computes).
- The check reports the counters the export names that the bundle does not show in full (`Report.unshown`: sent as a
  hash alone, or missing), walking only what is present however wide a named range; and every absence statement shown
  (`Report.absences`). Every absence statement is shown in full, whichever record is shared.

## Amendment (2026-11-01, item 182): the check in one pass

The check of what the export names as shown compared each named range with every counter shown, a cost that grew with
the product of the two lists (Codex's codex-6 on `73441cbe`). It now takes one pass through both, the ranges as the
readers take them (ascending and apart). The lists themselves grow with every retention statement the phone keeps:
BACKLOG item 184.

## Amendment (2026-11-01, item 182): no note of records set aside

ADR 0069, section 4 (the owner, 2026-11-01: "go on the fixes, codex-2 a"): the phone no longer notes, unsigned,
that signed records went with a log it could not read; it names them gone in a signed absence statement, which a bundle
shows in full. A bundle's notes are now a key lost only: the export carries no other, the check reads a note of records
set aside as a line that is not a note (a problem, named), and the Mac verifier has no words for one.

## Amendment (2026-11-01, item 182): the keys' rule shared, and Share after the comparison

ADR 0069, sections 1 and 8 (the owner, 2026-11-01: "go on the fixes, codex-1 a, codex-3 a"): the keys a bundle lists
come from one rule the signer shares (`EvidenceSignatureFile.listedKeys`), the export's own, unchanged; and Share offers
the bundle only once the signer has compared the log on disk in this launch (`EvidenceSigner.canExport`), the export
refused before, so none is made while the log failed to load.

## Amendment (2026-11-01, item 182): Share once nothing found gone is owed its name

ADR 0069, sections 4 and 8 (the owner, 2026-11-01: "1 a"): Share offers the bundle only once the signer has named
every signed record its comparison found gone, and an export names any still owed first, or is refused. SECURITY.md
says Share adds the ZIP once the phone has checked its signatures against the event log it read (the owner's approved
words, 2026-11-01: "wording approved").
