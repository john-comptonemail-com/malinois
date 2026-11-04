# ADR 0070: Evidence signing's export bundle, its check and the Mac verifier, as they stand

- **Status:** accepted: states the design that ADR 0067 (the export bundle, with five amendments) and ADR 0068 (the Mac
  verifier, with three) built, as it stands after the full review of 1.10 (BACKLOG item 187; the owner, 2026-11-01:
  "codex-1 a, codex-2 a, deepseek-1 a, deepseek-3 a, deepseek-2 b, go on the fixes, wording approved"). Under AGENTS.md's
  rule for ADRs, a decision that would amend either again is stated here: ADRs 0067 and 0068 keep their decisions,
  each marked as superseded by this record, their amendments with them. Built on `claude/1.10`, 2026-11-01. Amended
  twice (item 187's round B; item 190's round 190A, below), the sections corrected in place to say the design as it
  stands.
- **Date:** 2026-11-01

## Context

When the owner shares a signed record (BACKLOG item 90, phases 4 and 5), someone else must be able to check it on a
Mac without the phone and without trusting the owner or Malinois's developer, only Apple's certification and the public
source: the record came from Malinois on a genuine iPhone, unchanged since it was signed, with no signature of the
export's key missing, and the rest of the log stays private. ADR 0065 sets the statements and the verifier's rules; ADR
0066 the signer and its file; ADR 0069 what the signer does about records that leave the log.

The full review of 1.10 at `09d997f` found three things this record answers. A file added to a bundle on its way
passed the check unseen, since the check read only the files the index lists (Codex's codex-1). The watch around the
shared record was found by the records' times, so a clock set back during a watch took the wrong window (Codex's
codex-2: the code did not meet ADR 0067's decision, and now does). And a bundle made while no key could sign its export
statement, as after a restore, went without one, and the verifier ended it in problems (DeepSeek's deepseek-1: ADR
0067's consequence).

## Decision

### 1. The bundle's layout

One folder that iOS zips (`malinois-evidence-bundle/1`, `MalinoisEvidence/EvidenceBundle.swift`): `bundle.json` (the
index: the format, the record, the phone's certified keys in order, each attachment's file); `README.txt` beside it
(not signed, read by no check; ADR 0068's words, which a test pins); `keys/` (each key's statement and Apple's
attestation of it); `signatures.jsonl` (every signature by those keys in the phone's order: its key, its assertion,
the hash of what it signed, and whether that statement is shown); `statements/` (the statements shown, each under its
hash); `notes.jsonl` (the phone's unsigned notes: a key lost); `attachments/` (the shared record's photo or clip,
thumbnail and traces, as its latest revision signed them). The index and each line in the fixed JSON form. Nothing
else: every file in a bundle is one this layout names (section 5).

### 2. What a bundle shows

In full: the shared record's revisions; the status records of the watch around it, this phone's own, from the arm
before it to the disarm after it (to the next arm, or the log's end, without one; from the record itself when its arm
is gone), in the order things happened on this phone, the log's own (ADR 0069, section 6), never by the records'
times, which the phone's clock sets (codex-2); every retention and absence statement; and the export statement. Every
other signature only as the hash of what it signed. The export statement names every statement the bundle shows, by
key and counter (`EvidenceSigner.shownCounters`, from the exporter's own watch), so whether a statement is shown is
signed (the owner's "B", 2026-10-31).

### 3. The export statement

A fourth statement in `malinois-evidence/1`, type "export": the record shared, its latest revision, the time, the
app's version and what the bundle shows, in that fixed order. The phone signs one at each export as the bundle's last
signature and keeps it in its file naming no record, so no retirement drops it and the next bundle has no gap where it
was. No bundle goes without it: an export whose statement could not be signed (no key current, or its signing
refused or failed) makes no bundle (deepseek-1).

### 4. The phone's export, and Share

`EvidenceExporter` and `EvidenceBundleItem`, with the signer (`EvidenceSigner.export`, `canExport`):

- Share offers the bundle for a record this phone signed, once the signer has compared the log on disk in this launch
  and named every signed record it found gone (ADR 0069, section 8), and while a certified key is current to sign the
  export statement (deepseek-1). A key App Attest has lost shows only when a signature is refused: the key is noted
  lost, and that export asks Apple for a new key at once and signs its export statement with it; with Apple out of
  reach it makes no bundle (second amendment).
- The bundle is made only by the share sheet's operation for the destination the owner picks, on the sheet's thread,
  never for a destination that takes no file (Save Image or Save Video, Print, Assign to Contact, Add to Reading List,
  Books, Markup and Copy); the sheet's own asks get only a bundle already made. The signer signs in its turn: passes
  and exports one at a time, so the file keeps App Attest's counter order and a write during an export is signed after
  it. The bundle is built from the file as it then stands, with the attachments the latest revision signed, from the
  files on the phone (a photo or clip only while its name is a plain file name in the media folder,
  `EventStore.mediaFile(named:in:)`, and its file a plain file there), zipped by iOS into a folder named "Malinois
  evidence" and the record's date and time on the phone's clock; and only when the record as the share holds it, its
  attachments made as the signer makes them, is what that revision signed, so the phone's own check never reads its
  evidence as altered (second amendment), every attachment it signed found, and the copies as written hashed against
  it again (round 190B, codex-4).
- A share cancelled or left standing makes nothing and spends no signature; a bundle that cannot be made is left out
  and the rest goes as before, as it does for a record with no signature of this phone's. The bundle is removed once
  the sheet is gone; the launch clears any folder a share left behind. Nothing new is on screen.

### 5. The check

`EvidenceBundle.check`, shared by the app's tests and the Mac verifier, names what it finds as facts:

- each key's certification; every signature, over its hash when its statement is not shown (a signature that does not
  check out accounts for nothing; a statement shown that is missing or changed is named, and its signature still counts
  over its hash);
- each key's counters from its first signature, every gap retired by a retention statement or reported missing;
  retention counts only when signed by the key itself or by a key that follows it (one whose statement names it, after
  a restore, directly or through keys between);
- the bundle's last line as its export statement, with any counter of its key above it named; the shared record's
  revisions up to the one the export names, none missing and rising in the order signed; the statements the export
  names as shown that the bundle does not show, and those the bundle shows in full that the export does not name; the
  keys that are neither the export's nor one it follows (second amendment), and where the export's chain stops at a
  key the bundle does not hold certified (`Report.chainBreak`); every absence statement shown;
- the attachments' bytes against the last revision shown, and the files listed that it does not sign;
- every file and folder in the bundle against the layout (codex-1): any other is named (`Report.unlisted`), a folder
  the layout does not name as itself and never opened, a link never followed; a folder that cannot be listed is a
  problem; macOS's own `.DS_Store` files, which Finder leaves in a folder it shows, are named apart and not judged
  (`Report.ignored`).

It throws only when the index is not the phone's (another format, not in the fixed form, a key twice, a file name that
is not plain), and then judges nothing. It reads only plain files whose names come from a hash, a key ID or a plain
attachment name, never through a link, within size limits, an attachment a megabyte at a time.

### 6. The Mac verifier

`MalinoisVerifier` (`malinois-verify`):

- **Malinois by its App ID's hash**, the 32 bytes every Malinois attestation carries, so the team ID stays out of the
  source; **Apple's App Attestation root built in**, byte for byte Apple's file, or a reader's copy with `--root`.
- **The ZIP as received:** its layout first, read from its headers, then its listing (`zipinfo -l`) and its three
  readings, refused without unpacking for a ZIP not laid out as one plain run of files, readings that name different
  entries, an entry that is a link, a path from the root or with `..` in it, more than 4 GiB unpacked, or a listing it
  cannot read (corrected in place for item 187's rounds C to E, the decision unchanged); then `bsdtar` unpacks it
  into a new temporary folder, which must hold plain files and folders only, within the same limit, and is removed
  after the check. An unzipped folder is read as it is. The bundle is the folder given when it holds the index, or its
  one folder that does; anything beside that folder, in the folder or ZIP given, is a problem, `.DS_Store` files apart
  (codex-1).
- **What it prints:** each key Apple certified (when, its environment, from iOS 27 its kind of build); the signatures in
  the phone's order, as their keys and counters prove it, the oldest key first, each naming its key when there is more
  than one (those not shown counted), and after them, as the heading then says, those of keys outside the export's
  chain; each key's counters, and for a key a later key follows, that what it signed
  after its last signature here cannot be accounted for (a limit of the check, not a problem); the export, and whether
  everything it names as shown is in the bundle and everything shown in full is named by it; the shared record's
  revisions; its attachments, any an earlier revision signed that the last does not, and any the last signed under a
  name an earlier revision signed with other bytes (information); the phone's notes; and OTHER FILES, each file the
  bundle does not account for and each `.DS_Store` file. Times on the Mac's clock with their offset from UTC. Then PASS
  (exit status 0) or the problems (1): every finding of the core is a problem, every absence statement, every statement
  named and not shown or shown and not named, every key not the export's or one it follows (where the export's chain
  stops at a key the bundle does not hold certified, named as not tied to the export's key, with the key the chain
  stops at), and every other file among them; nothing passes over one. Status 2 when nothing was checked.
- **How a reader gets it:** from the public source, `swiftc -O MalinoisEvidence/*.swift MalinoisVerifier/*.swift -o
  malinois-verify` on a Mac with Xcode's command-line tools; the project has the same build as a Mac target.

## Consequences

- A recipient learns, beyond the shared record, when that watch was armed and disarmed and its lapses, how many
  signatures the phone has made, and from iOS 27 the app's version and build channel at each.
- A bundle accounts for every file: a photo or anything else added to a ZIP on its way ends its check in problems. A
  reader who opens the unzipped folder in Finder can still check it; a copy through a FAT-formatted drive or a ZIP made
  again with Finder adds files of macOS's (`._` names, `__MACOSX`) that the check reports, so the ZIP as received is the
  thing to check, as the bundle's README and the public README say. The phone's ZIPs hold exactly the layout (two from
  the iPhone Air, 2026-10-31, listed 2026-11-01).
- After a restore from a backup or a move to a new iPhone, App Attest has lost the key: the first share before anything
  else is signed learns it then, and asks Apple for a new key, which needs a network connection; it goes without its
  ZIP only when Apple cannot be reached, as every share does until a new key is certified (second amendment).
  SECURITY.md says so.
- A signature made and not kept (the phone stopping in the instant after it is made) leaves its counter missing in every
  later bundle of its key (ADR 0066's consequences; SECURITY.md); BACKLOG item 188 plans a signed statement for it.
- The index, the notes and the file names are unsigned, the phone's word: a check never takes them over a signed
  statement. A bundle is a snapshot: an older one checks out as of its export's time.
- A write that comes while an export signs is signed after it; an edit made just before Share is in the bundle once the
  log's write of it has reached the signer, and until then a change to the record's photo, clip, thumbnail or traces
  makes no bundle (second amendment). The bundle is made after the destination is picked, so a long clip opens
  there a moment later; making it when Share is tapped would spend a signature on every share cancelled. Copy carries
  the sentence and the media without the bundle. The making relies on iOS running the sheet's operation before it asks
  for the item on the main thread, as the device check showed; were iOS to ask first, that share would go without the
  bundle.
- The verifier needs nothing from the developer but the source, and nothing from the phone but the ZIP; it trusts the
  root it carries unless given Apple's file; its chain check uses macOS's trust service, so it runs as an ordinary
  program; its tests use macOS's own zip tools and run on macOS beside the core's.
- Not taken: other files named as information under a PASS (codex-1's (b)); a bundle without its export statement,
  checked up to its last signature (ADR 0067's first design); the App ID built into the verifier, or typed by the reader; a ready-to-run, notarized verifier on each
  GitHub Release (later, if readers ask); a Swift package beside the project.

## Amendment (2026-11-01, item 187's round B): plain files only, every name, and a ZIP's files against its listing

Codex's change review of `07b7134`, and Claude's checks while fixing it, found four ways a file could still pass a
check unseen (BACKLOG item 187; the owner, 2026-11-01: "go on the round, wording approved"):

- **A name on the layout counts only as a plain file** (codex-1 on `07b7134`). Section 5's inventory passed a name the
  layout lists whatever it was, and the README is read by no check, so a folder named `README.txt` with a photo in it
  passed. Anything but a plain file under a name the layout lists is now named with the files the bundle does not
  account for (`Report.unlisted`).
- **Every name in a folder** (Claude's, on `b2efa66`). Foundation's folder listings on macOS leave out every name that
  begins `._`, whatever the file holds, so the Mac's check never saw such a file in a bundle or beside its folder. The
  check and the verifier list a folder with the system's own `readdir` (`EvidenceBundle.names(in:)`).
- **`__MACOSX` entries are files** (codex-2 on `07b7134`). `bsdtar`'s ZIP reader takes a `__MACOSX/._` entry as a
  file's metadata by default and writes no file for it, so what the entry held reached no check, though this record's
  consequences said such files are reported. The verifier unpacks with that extension off (`zip:!mac-ext`): the entries
  are files, and the check beside the bundle's folder names them.
- **A ZIP unpacks to the files it lists** (Claude's, on `07b7134` and `b2efa66`). A ZIP may list two entries for one
  file (one name twice, or two names a Mac takes as one, as when they differ only in letter case): `bsdtar` writes the
  last over the first, so the first's bytes reached no check, while another unzip tool may show them. And `bsdtar`,
  whatever its options, folds a `._` entry that follows the file it names into that file as metadata, writing no file
  for it. The verifier counts its listing's file entries, every entry but a folder, and refuses a ZIP that unpacks to
  another number of plain files, nothing checked (status 2).

The consequences change with them: a ZIP made again on a Mac (with `ditto`, or Finder's Compress) from files that carry
macOS's extended attributes ends in problems for its `__MACOSX` entries, or is refused for its `._` entries; a folder
copied through a drive formatted for Windows gains `._` files that the check names. The ZIP as received, or its
unzipped folder on the Mac's own disk, is the thing to check. The verifier's tests and the evidence core's run on macOS
in the release gate from 1.10 (`tools/release/run-macos-tests.zsh`, Qwen's qwen-3), the verifier built and run as a
reader builds and runs it.

## Second amendment (2026-11-02, item 190's round 190A): every key the export's own, and a new key at the export

The full review of `aa71756` (BACKLOG item 190; the owner, 2026-11-02: "go on the fixes, A3 a, A4 a, A5 a, A6 a"):

- **Every key the export's own** (Codex's codex-1). The check certified each key the unsigned index lists on its own,
  so another phone's key, certified by Apple as every phone's is, could put its statements beside this phone's, and the
  check passed. A certified key that is neither the export statement's key nor one it follows, by the key statements'
  `follows`, is now named (`Report.unrelatedKeys`), and a verifier reports each as a problem (section 5).
- **A new key at the export** (DeepSeek's deepseek-3; deepseek-1's (b) on `09d997f`, then not taken). An export whose
  signature finds the key lost now asks Apple for a new key at once, as a pass does, and signs its export statement
  with it, so the first share after a restore keeps its ZIP when online (section 4 and the consequences).

Corrected in place with them, each meeting a decision this record states: section 5's check names a statement the
bundle shows in full that the export does not name (`Report.unnamed`; codex-1, deepseek-4), so section 2's "the export
statement names every statement the bundle shows" holds of any bundle, not only the phone's; section 4's export makes
a bundle only from the bytes the latest revision signed (deepseek-2); section 6's verifier shows the signatures in the
order their keys and counters prove, each line naming its key when there are more (codex-1), and says, as information,
when the last revision signed an attachment under a name an earlier revision signed with other bytes (codex-3). The
keys this install certified, kept where a backup cannot change them, are ADR 0071's.

Corrected in place for round 190B (BACKLOG item 190, the change reviews of `29d6501`; the owner's "codex-4 b" and
"deepseek-1 b"), each meeting a decision this record states: section 4's export checks the copies it wrote against the
bytes the latest revision signed, and makes no bundle when a photo or clip changed or went between its check and its
copy (Codex's codex-4); section 5's check says where the export's chain stops at a key the bundle does not hold, and
section 6's verifier names a key the chain cannot reach as cut off from the export's key by it, not as another phone's,
its SIGNATURES heading saying when the keys outside the export's chain come after it (DeepSeek's deepseek-1 and
deepseek-6). And for round 190C (the change reviews of `b7702f5`; the owner's "deepseek-2 a"): section 6's words for
such a key are true of any key the chain cannot reach, a stranger's among them, and of a stop at a key the bundle holds
uncertified: "cannot be tied to the export's key; the export's chain stops at key …, which this bundle does not hold
certified". And for round 190D (DeepSeek's note on `424d8ce`): section 5 says where the export's chain stops at a key
the bundle does not hold certified, as the check means it.

## Where ADRs 0067's and 0068's amendments stand

- ADR 0067: absence statements in full and the export naming what the bundle shows (sections 2 and 5); the check in one
  pass (section 5); no note of records set aside (sections 1 and 5); the keys' rule shared with the signer, and Share
  after the comparison (section 4); Share once nothing found gone is owed its name (section 4).
- ADR 0068: two more problems (section 6); a key a later key follows (section 6); an earlier revision's attachments, and
  what a ZIP unpacked to (section 6).
