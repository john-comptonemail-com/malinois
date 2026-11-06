# ADR 0068: The Mac verifier

- **Status:** accepted: the owner's rulings of 2026-10-31 ("1 - a, 2 - a, 3 - a"). Built on `claude/1.10`, 2026-10-31
  (phase 5's steps 1 and 2), then the bundle's README and SECURITY.md's section (step 3; the owner: "wording approved").
  Amended 2026-10-31 (item 182; below): two more problems; and 2026-11-01 (Codex's change review; below): what a key a
  later key follows may have signed; and again 2026-11-01 (item 185; below): an earlier revision's attachments, and what
  a ZIP unpacked to. Amends ADR 0065: the core takes the App ID's hash; and ADR 0067: the README in the layout.
  **Superseded by ADR 0070** (2026-11-01, BACKLOG item 187), which states the Mac verifier, with the export bundle and
  its check, as they stand; this record keeps its decision and its amendments. Corrected then: App Attest's keys survive
  no restore from a backup, onto the same iPhone or another.
- **Date:** 2026-10-31
- **Summary:** A command-line verifier, built on a Mac from the public source, checks a bundle against Apple's
  certificates and Malinois's App ID and prints what it checked.

## Context

Phase 5 of evidence signing (BACKLOG item 90): someone who receives a bundle must be able to check it on their own
computer, trusting neither the phone, nor its owner, nor Malinois's developer, only Apple's certification and the
public source. The check exists (`EvidenceBundle.check`, ADR 0067); the verifier needs the two inputs its rules take,
Malinois's App ID and Apple's root certificate, and a way for a reader to get it. The public mirror never holds the
team ID: the export strips it from the project and stops if it appears anywhere. A ZIP that someone sends is input
from a stranger.

## Decision

- **The core takes the App ID's hash.** `EvidenceVerifier.certify` and `EvidenceBundle.check` take the SHA-256 of the
  App ID, as Apple writes it into every attestation; the forms that take the App ID hash it and call them.
- **The verifier knows Malinois by that hash** (the owner's ruling 1 (a)): `MalinoisVerifier.appIDHash`, the 32 bytes
  every Malinois attestation carries, so nothing new is published and the team ID stays out of the source. A test ties
  it to the hash in the iPhone Air's attestation (the Phase 0 fixture).
- **Apple's root is built in** (ruling 2 (a)): Apple's App Attestation Root CA, byte for byte the file Apple publishes
  (valid to 2045-03-15; a test checks its SHA-256). `--root FILE` (PEM or DER) checks against the reader's copy instead.
- **It reads the ZIP as received.** Its listing first (`zipinfo -l`): refused, unpacked not at all, for an entry that
  is a link, a path from the root or with `..` in it, more than 4 GiB unpacked (the phone keeps about 2 GB of media),
  or a listing it cannot read. Then `ditto` unpacks it into a new temporary folder, removed after the check. An
  unzipped folder is read as it is.
- **What it prints.** Each key Apple certified (when, its environment, its build), the signatures whose statements are
  shown in the phone's order (the others counted), each key's counters, the export, the shared record's revisions, its
  attachments and the phone's unsigned notes; times on the Mac's clock with their offset from UTC. Then PASS (exit
  status 0) or the problems (1): every finding of the core is a problem, and nothing passes over one. Status 2 when
  nothing was checked (the arguments, the root or the bundle could not be read).
- **How a reader gets it** (ruling 3 (a)): from the public source, one command on a Mac with Xcode's command-line
  tools: `swiftc -O MalinoisEvidence/*.swift MalinoisVerifier/*.swift -o malinois-verify`. The project has the same
  build as a Mac command-line target, `MalinoisVerifier` (product `malinois-verify`), signed to run locally, with no
  version, build or team settings of its own. The release tools export, compare and sweep `MalinoisVerifier/` from its
  first commit (`ed1fb332`), and their tests build it with the reader's command.

- **The bundle's README** (`README.txt`, beside the index; `EvidenceBundle.readme`), in the owner's approved words:
  what the archive is, where the verifier's source is and how to run it, that the README is not signed and that the
  verifier does not read it. A test pins the words; a change to them is a change for the owner. SECURITY.md's
  "Evidence someone else can check" says what the signatures are, what a bundle holds, and what a passing check shows
  and cannot; the public README's "Checking an evidence bundle" waits in `tools/release/readme-edits/1.10.json` for
  1.10's stage.

## Consequences

- A reader needs nothing from the developer but the source, and nothing from the phone but the ZIP.
- The verifier trusts the root it carries; a reader who would rather trust Apple's website passes Apple's file.
- The chain check uses macOS's trust service: the verifier runs as an ordinary program, not inside a sandbox.
- Its tests use other programs (`zipinfo`, `ditto`, `zip`), which iOS lacks: they run on macOS beside the core's, and
  their file is empty on the simulator.
- Not taken: the App ID built in (the team ID would become public, and the export's rule would need an exception); the
  reader typing the App ID (they would have to find Malinois's team ID somewhere they trust); a ready-to-run, notarized
  program on each GitHub Release (a Developer ID certificate and Apple's notarization at every release; later, if
  readers ask); a Swift package beside the project (phase 1's ruling put the shared code in a folder both build).

## Amendment (2026-10-31, item 182): two more problems

The verifier lists each absence statement's records among the signatures ("SIGNED RECORDS NO LONGER IN THE PHONE'S
LOG", each with its revision and start) and reports them ("the phone signed that a record left its log other than by
its limit: ..."). Under THE EXPORT it says whether the statements the export names as shown are all in the bundle, and
reports any that are not ("the export names statements the bundle does not show: ..."). A bundle with either ends in
PROBLEMS, status 1.

## Amendment (2026-11-01, item 182): a key a later key follows

A restore from a backup brings a new key (App Attest's keys survive no restore, onto the same iPhone or another), whose
statement names the key it follows but not where that key ended. The verifier finds missing counters only below the
highest it is shown, so the old key's last signatures, an absence statement among them, can go without a trace when
the restored backup was edited, or simply older (Codex's codex-2 on `73441cbe`). Nothing kept on the phone alone can
show where the old key ended: the restored files are all it has. The owner chose to say so (2026-10-31: "2 - a"): under
COUNTERS, for each key a later certified key follows, the report says that any signatures it made after its last one
in the bundle cannot be accounted for; for a key the bundle's unsigned index leaves out too, with none of its counters
at hand (Codex's codex-2 on `417158fe`). A limit of the check, not a problem: such a bundle can still pass. SECURITY.md
narrows its two claims to the export's own key.

## Amendment (2026-11-01, item 185): an earlier revision's attachments, and what a ZIP unpacked to

The full review of 1.10 found two things the verifier should do (BACKLOG item 185; the owner: "yes"):

- **Attachments an earlier revision signed** (ds4agent-3). The phone's storage limit can remove a photo or clip it had
  uploaded, and the record's next revision is signed without it; the verifier checked attachments against the last
  revision only, so it said nothing of the photo. It now names, under ATTACHMENTS, each attachment an earlier revision
  signed that the last does not, as information rather than a problem.
- **What a ZIP unpacked to** (ds4agent-4). The verifier read a ZIP's own listing (no link, no path outside it, its
  size), then unpacked it with `ditto` and never looked at what came out. It now unpacks with macOS's `bsdtar`, which
  refuses a path from the root or outside the folder and never writes through a link, and then checks what it unpacked
  to: plain files and folders only, within the same byte limit.
