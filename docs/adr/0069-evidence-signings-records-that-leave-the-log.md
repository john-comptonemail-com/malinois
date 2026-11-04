# ADR 0069: Evidence signing: records that leave the log

- **Status:** accepted: the owner's rulings of 2026-10-31 and 2026-11-01 (BACKLOG item 182), as they stand in 1.10
  (81). It replaces ADR 0066's thirteen amendments, which built this design one review at a time (the owner,
  2026-11-01: "a, with the next round's documents"); ADR 0066 keeps its decision. Each defect, the review that found it
  and the ruling: BACKLOG item 182 and `docs/verification/1.10-development.md`.
- **Date:** 2026-11-01

## Context

ADR 0066 decided the signer: one key per install, certified by App Attest at launch; each record of this phone's
written after that, signed at each revision once its write is on disk; the signatures in a file of their own beside
the event log. A verifier reads a counter with no signature in that file as a signature removed, unless a signed
statement accounts for it. For records leaving the log, ADR 0066 had the phone sign a retention statement for every
signed record missing from a log it read, and note, unsigned, those gone with a log it could not read. Built that way,
a record that left any other way (an app fault, an edited device backup restored, a jailbroken phone) read as routine
retention, signed by the phone.

The design below answers that. It holds against someone who can restore an edited device backup (the event log, the
signature file and the list of the limit's removals are theirs to edit; the Secure Enclave's key and the keychain's
keys kept for this device only are not), and against a phone that crashes, is killed or runs out of disk at any point.

## Decision

### 1. What the signer trusts in its own file

- It reads every key's certification first, then checks each signature against its key's public point from that
  certification, with the verifier's own functions from the shared core
  (`EvidenceVerifier.publicKey(ofAttestation:keyID:)`, `signs(_:formHash:publicKey:)`), before it acts on the
  signature. It judges no certificate chain and no time: a bundle's check does. A signature that fails counts for no
  record, is never retired, and stays in the file, where a bundle's check shows it.
- It acts only on the keys every bundle lists (`EvidenceSignatureFile.listedKeys`: each key certified after a key
  statement of its own, the latest before it), so a key the phone acts on is one every bundle shows.
- It files each signature under the record its signed statement names, never under the entry's unsigned `record`
  field, and keeps each signature's key, counter, revision, start, kind, interruption mark and content. A record is
  what its highest signature not retired signed, wherever the file puts it.
- The list of the records held at the first certification, which are never signed, is the phone's own and unsigned: a
  record the file's signatures show was signed is signed at each change, whatever the list says.
- A revision at the highest a 64-bit count holds is not signed past: that change stays unsigned.

### 2. A record's identity

A record is its ID together with its start, its kind (an incident, or which status entry) and whether it is an
interruption record: facts the app sets when it makes a record and never changes (`RecordIdentity`, kept with each
signature). A row under a signed record's ID with another identity is another record: the signed record counts as
gone (section 4), and the row is never signed as its revision. A record found gone and not yet named stays owed when
its ID comes back as another record.

### 3. The limit's removals, and retention statements

- The store keeps the records of this phone's that the log's size limit removes, each with its identity
  (`EventStore.limitRemovalsAsRemoved`), in `limit-removals.json`, written on its file queue before the log write that
  drops them. The file holds them with an HMAC-SHA256 under a 32-byte key that the keychain keeps for this device only,
  readable after the first unlock and never synced (`KeychainService.limitRemovalsKey`); the HMAC's input names the
  file's form ("malinois limit removals 3") and covers each removal's ID, start, kind and interruption mark. No backup
  restores the key onto another iPhone, and none hands it to whoever edits the backup. Without the key, the removals
  are not written.
- The file is read at launch and after the unlock, before the journal's recovery. A file that cannot be read or does
  not check (edited, of an earlier form, or made with a key the phone does not have, as after a restore onto another
  iPhone) is set aside, and its records count as gone (section 4). A removal whose record the log still holds is
  dropped; an iCloud copy under its ID does not count as the record.
- The signer hears the removals with each write. It retires a record only when a removal's identity is the record's as
  signed: a signed retention statement names the record's counters, and its signatures leave the file. The removal of
  another row under the record's ID leaves the record gone.
- Retention statements are read back with the rest of the file: a record each of whose signatures one names stays
  retired. A retirement drops exactly the signatures it retired, by key, counter and statement, never another under the
  same key and counter. Retired signatures a failed rewrite kept are dropped at a later pass, after a relaunch too, and
  an export cleans them up first.
- The store forgets a removal once the signer has accounted for it (retired; never signed here; or named gone before
  it came back) and its journal line no longer needs retiring (section 7), never while the write the signer is hearing
  still holds its record.

### 4. Every other departure: absence statements

- Any other signed record that leaves the log (only this phone's own records count as present, never an iCloud copy
  under its ID), one gone with a log the launch could not read included, is named in a signed absence statement (ADR
  0065): its ID, the revision last signed and its start. Its signatures stay in the file, and it is never named again.
  No unsigned note exempts a record.
- What a comparison finds gone and cannot name at once (no key current, or the signing failed) stays owed
  (`EvidenceSigner`'s `unnamedGone`): a pass that certifies a new key names it at once; otherwise a certification that
  succeeds, or the app coming forward with a key (`certifyIfNeeded`, at launch and at each return to the foreground),
  names it; and an export names it first, in its own signing turn, or is refused.

### 5. The line in the event log

- Each absence statement gets one line in the event log, through the engine's `logStateChange`, in the words the owner
  approved: "A signed record from Oct 14, 9:03 PM is no longer in the log", or "3 signed records, from Oct 14, 9:03 PM
  to Oct 15, 8:10 AM, are no longer in the log" (the times as the watch's alerts show them; without known times, "A
  signed record is no longer in the log"). Its kind is `signedRecordsGone.<count>.<first>.<last>` (whole seconds since
  1970). It stands out, at the owner's request: a red warning sign on a red tile, its words in red, semibold and in
  full. It is the first thing evidence signing puts on screen.
- The line's ID is a version 8 UUID made from its statement's SHA-256, and its time and words come from the statement:
  the moment the phone signed it, and the count and starts of the records it names. So a relaunch finds the line in
  the log, or writes it again as it was signed.
- The engine writes a line only when its own log does not hold it (`MonitoringEngine.logSignerLine`); a row of this
  phone's takes the place of an iCloud copy under its ID.
- The file notes the line written (`absenceLogged`) once a write of the log on disk holds it. From the moment the
  signer has read its file, the store's limit takes no line still owed its note (`EventStore.holdLinesForTheSigner`);
  one the limit removed before then, at launch, was in the log on disk, so its removal is that proof, and the store
  keeps the removal until the note is written.
- The line is itself a record of this phone's, so it is signed.

### 6. The log's order

The log keeps the order things happened on this phone, and the limit takes each pool's rows by their place in the log,
never by their times, so the phone's clock chooses nothing the limit takes:

- Every new row goes first, whatever its time, and the row an add puts in is never the one its own limit takes.
- The signer's line goes below every row newer than its statement (`EventStore.add`'s `placedByItsTime`), so it takes
  no newer row's place.
- `EventStore.merged`, which the merge with iCloud, the journal's recovery and the unlock use, keeps the rows it holds
  in place, puts this phone's rows it did not hold first, as given, the newest first, and places another device's
  copies and this phone's signer lines by their time, below every row newer than them. A merge that changes nothing
  leaves the log as it was.

### 7. The journal

Every row the limit removes, whichever path asked (`EventStore.pruneToCountCap`), owes its journal line's retirement.
The store keeps those lines owed (`journalRetirementsOwed`), hands them to every write, and drops each only once a
checkpoint has retired its line, or no journal is left to retire it from; a failed write or sync keeps them. The
journal's recovery skips the rows in the limit's removals and retires their lines, as the unlock's reconciliation does
with what a locked launch's recovery queued.

### 8. Exports wait for the comparison

The store hands the signer the log as it read it, at launch and at the unlock, when no write follows to tell it. Share
offers the bundle, and the signer signs an export, only once the signer has compared the log on disk in this launch
and named everything it found gone (`EvidenceSigner.canExport`). A log that failed to load is never compared: Share
leaves the bundle out, and Home says the log could not be read.

## Consequences

- A working phone never signs that the limit removed a record it did not remove. A signed record that vanishes, by a
  fault or by someone's hand, shows on the phone as a red line and in every later bundle, which a verifier reports as a
  problem. A crash, a full disk or a kill at any point names no record gone that the limit removed, except one whose
  removal never reached the disk (named gone, never the reverse), and writes no line twice or never.
- After a restore onto another iPhone, a record the limit removed while the phone was locked before the backup, and
  not yet retired, is named gone: the removals' key stays with the old phone. Accepted with the ruling.
- A signer's line older than a full log's every entry is the one the limit takes once it is noted; its absence
  statement stays in every bundle.
- What the design cannot show, stated in SECURITY.md in the owner's approved words: someone who can restore an edited
  backup can fill the log with made-up records until the limit removes the one they want, with every older one; once
  the log is full, they can also move a record to the end of the log, or mark an incident as part of a flood or as
  backed up to iCloud, so that the limit removes it before older ones; and someone who can restore edited backups more
  than once can reuse an old list of what the limit removed, for a record the limit had removed before and that came
  back. Whoever can restore an edited backup can also take a record's signatures out of the file with the record: the
  phone, which then never knew it signed it, names nothing gone, and a bundle's check finds the gap in the counters
  unless the record was an earlier key's last (ADR 0068). A key whose certification is itself forged passes the
  phone's own check, which judges no chain; the phone acts on it only where every bundle shows it failing.
- Every retention statement stays in the file and in every bundle (BACKLOG item 184).
- Tried and undone: ordering the log and the limit by the records' times. It made the phone's clock a lever: with the
  clock set back before a full pool's oldest row, each new row of that pool went in its own add, never signed (the
  owner, 2026-11-01: "clock a").
- Not taken: the full check of each key's certification at load (Apple's chain at the time of its statement, and the
  App ID). It would close only the forged-key way, which every bundle already shows.
