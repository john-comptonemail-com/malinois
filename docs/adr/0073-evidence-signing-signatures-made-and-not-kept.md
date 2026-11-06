# ADR 0073: Evidence signing: signatures made and not kept

- **Status:** accepted (the owner, 2026-11-04: "ADR 0073 approved, A"; BACKLOG 188, item 192's step 1), approved
  before any code, since it changes the evidence format and bundles already shared cannot be changed back. The format
  is decision 6's A.
- **Date:** 2026-11-04
- **Summary:** A signature App Attest made and the file did not keep is named in a signed unkept statement, which a
  verifier counts as accounted for and reports as information.

## Context

App Attest counts a signature when it makes it: each assertion carries its key's counter, one past the last, unless a
forced restart took the count back (ADR 0077). The phone
keeps every signature in `evidence-signatures.jsonl` (ADR 0066), and a verifier counts each key's counters from 1
(`EvidenceVerifier.sequence`): a counter nothing in the bundle accounts for is reported missing, as a fact, not a
verdict. Retention statements account for the counters the log's limit retired (ADR 0069). Nothing accounts for a
signature App Attest made and the file never kept:

- the phone stopping between the assertion and the file's line (a crash, a forced restart, a flat battery);
- the line failing to write then (a full disk: `EvidenceSignatureFile.canAppend` checks the lock, not the space). The
  record is signed again at its next write, under a new counter, and the spent one stays a gap.

Unless the count goes back over it (ADR 0077), every later bundle of that key then reports the counter missing, for as
long as the key lives, and no statement can retire it, since retention names only kept signatures. It is most likely
during a real incident, when the phone signs
a trip's revisions. 1.10 states it in SECURITY.md and in ADR 0066's consequences.

## Decision

1. **The statement.** A sixth statement kind, `unkept`: counters of the signing key that App Attest made and the file
   did not keep, as ranges, with when it was signed and the app's version (`EvidenceForm.Unkept`). It names only
   counters of the key that signs it, each below its own counter.
2. **When the phone signs one.**
   - At a signature: when the assertion's counter is more than one past the highest the file accounts for under that
     key (its signatures, retired ones included), the counters between were made and not kept. The signature is kept
     as usual, and in the same pass the phone signs an unkept statement naming them.
   - At load: every counter of the key in use is in this phone's file, since App Attest's keys survive no restore and
     no backup brought them. A hole among them was left by a build before this one, and the phone names it once, at
     its first pass with the key.
   - Never for an earlier key: its entries came through a backup someone could have edited, so its holes stay
     missing, as today.
   - An unkept statement that is itself not kept leaves a gap the next signature names with the rest.
3. **A line that failed to write is held.** When the file refuses a signature's line after App Attest made it, the
   phone keeps the entry and writes it first at the next pass, before any new signature. A gap remains only when the
   app stops before then, and decision 2 names it.
4. **An export that reveals a gap.** The export statement must be the bundle's last signature (ADR 0067). When its own
   assertion reveals a gap, the phone signs the unkept statement after it, then a second export statement, which the
   bundle carries. The first stays in the file as a signature of its own, shown like any other.
5. **The verifier.** It counts an unkept statement's counters as accounted for only when the key itself signed it,
   and only below the statement's own counter. It reports them as information, not as a problem: counters N to M of
   the key were made by App Attest and not kept by the phone (its statement at counter K). A bundle whose only gaps are
   named so passes.
6. **The format: A** (the owner, 2026-11-04).
   - **A, taken.** A bundle that holds an unkept statement names the bundle format
     `malinois-evidence-bundle/2`; every other bundle stays `/1`. 1.10's verifier refuses a `/2` bundle as "in another
     format", meaning a newer verifier is needed, rather than "not in its fixed form", which reads like damage. Most
     bundles stay checkable with 1.10's verifier.
   - **B, not taken.** Every bundle from 1.11 on names `/2`. It is simpler to state ("1.11's bundles need 1.11's
     verifier"), but 1.10's verifier refuses every 1.11 bundle, gaps or not.
   - Not offered: the statement inside a `/1` bundle. 1.10's verifier would read it and report the bundle "not in its
     fixed form".
7. **Documents.** SECURITY.md's sentence on a signature made and not kept; ADR 0066's consequence pointing here; the
   verifier's report line; the README's "Checking an evidence bundle", which names the verifier to use for a bundle's
   format.

## Consequences

- A gap a crash leaves is named at the key's next signature, the export's own included (decision 4), so a bundle made after
  the crash passes; if that statement cannot be made then, Share leaves the ZIP out, and the next share names the gap
  first.
- Each gap costs one more signature, and an export that reveals one costs two (decision 4).
- A downgrade (TestFlight allows installing an older build over a newer one, on the owner's own devices): 1.10's app
  keeps the statement's line, since it ignores a statement it cannot read. What its own export then shows is checked
  before the release, with 1.10's code, and stated if it fails.
- Tests, red first: a kill between the assertion and the line (the key's mock counting the assertion); a full disk at
  the append, the held line written at the next pass; an export that reveals a gap; a bundle checked before and after
  the statement; an earlier key's gap never named; a statement naming a counter at or above its own refused; a hole
  at load named once; 1.10's verifier, built from the `v1.10-b82` source, refusing a `/2` bundle with its format
  message.
- Not taken: retiring the counters by a retention statement, which would claim the log's limit removed records it did
  not; naming an earlier key's gaps, which a backup could have made.
- Retention statements kept forever (BACKLOG 184) stays parked. A later statement that retires earlier statements could
  take unkept statements with it.
