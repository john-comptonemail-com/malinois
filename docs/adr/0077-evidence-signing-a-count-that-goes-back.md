# ADR 0077: Evidence signing: a count that goes back

- **Status:** accepted (the owner, 2026-11-05: "a"; BACKLOG 205, from TestFlight 84's forced restart).
- **Amended 2026-11-06** (BACKLOG 206, Codex's look at 1.11 (85), the owner: "as you recommend, wording approved"): what a repeat costs a
  check, a stop that takes the count back over a signature it lost, and what was not taken. The three decisions stand.
- **Date:** 2026-11-05
- **Summary:** App Attest's count can go back after a forced restart. The phone throws away a signature on a counter its file
  already accounts for, so it keeps no counter twice, and a verifier reports two genuine signatures on one counter as information.

## Context

The evidence design took App Attest's count to rise by one at every signature, and never to go back. ADR 0066 reads a counter with no
signature as one removed, ADR 0073 names the ones a stop lost, and the verifier called two signatures on one counter a problem. Every
test's stand-in rose by one.

TestFlight 84's forced restart showed otherwise. Two signatures were made and kept, at counters 79 and 80. The restart followed within
seconds. After it, App Attest gave out 79 and 80 again, for other statements, and then went on from 81. Its count had gone back by two,
though the signatures were in the file. All four signatures hold under the key. Nothing was forged or lost, but the verifier ended that
bundle in PROBLEMS, and every later bundle of the key with it, since every bundle lists every signature. A forced restart right after
a trip is what SECURITY.md's own adversary does, so the bundle that fails is the one that matters most. 1.10 does the same.

## Decision

1. **The phone keeps no counter twice.** When App Attest's counter is at or below the highest the file accounts for under the key, the
   signature is thrown away and App Attest is asked again over the same bytes, each ask moving the count on. A counter thrown away is
   one the file already accounts for, so none goes missing, and no unkept statement is owed. At most 64 asks for one statement: past that
   the signing fails as any other does, and the record waits for a later write.
2. **A verifier reports a repeat as information.** Two signatures on one counter, each holding under its key, are shown under COUNTERS
   with what they cost a check, and they do not stop a PASS. Only the key can make either, so neither is forged; that says nothing of
   why the count went back, or of what else the bundle held at that counter. This is what brings back the bundles of a phone that
   already holds one, on 1.10 or on an earlier build of 1.11. A statement signed again at a
   later counter, a counter missing and a signature after the export stay problems.
3. **The format does not change.** A bundle with a repeat is an ordinary bundle. 1.10's verifier still ends it in PROBLEMS.

## Consequences

- From 1.11 a forced restart leaves no repeat. Repeats a phone already holds stay in its file, and each later bundle of that key shows
  them, until the size limit retires them.
- At a counter that holds a repeat, a sender can take a statement out of a bundle, or cut it down to its fingerprint, with no gap
  showing, even one the export means to show or one saying a record left the log: a check sees the counters, not how many times each
  was given out, and an export names statements by their counters. With one of the two gone nothing shows the count went back. A
  verifier says so under COUNTERS, and under THE EXPORT when a fingerprint lies beside a statement shown in full at a counter the
  export names. An earlier verifier stopped only a sender who left both lines in: taking one out whole passed it too. SECURITY.md lists
  this under what a check cannot show. It applies to those counters alone.
- A stop that loses a signature and takes the count back over it leaves no gap: the counter is given out again, so ADR 0073's statement
  has nothing to name, and nothing names the signature lost. So a pass claims every counter of the export's key, not every signature.
- Apple tells a server to refuse a counter that does not rise. A bundle cannot be signed again, so accepting a repeat here is this
  project's decision, not Apple's rule relaxed.
- Each counter thrown away costs one signature, a few after a forced restart and none on the normal path.
- A phone that kept a repeat can also have signed a record on both sides of the restart at counters that cross, or an export below its
  highest counter. Such a bundle reports revisions out of order, or signatures after its export. Those stay problems: neither can arise
  from 1.11 on, and telling them from a real fault would mean trusting the line order, which is unsigned.
- How long a count stays unsaved is not known. Here the last signature came a few seconds before the restart. The fix does not depend
  on the answer.
- Tests use a stand-in whose count can go back. TestFlight forces a restart again on a device.
- Not taken: a signed statement naming the rollback (a format change, for nothing a recipient could act on); a new key after each
  rollback (a certification needing a connection, and a chain note on every forced restart); keeping a repeat as a problem (every later
  bundle of the key would fail); refusing a repeat the export names (the owner's own bundle would fail, and a careful sender takes the
  line out anyway); binding shown statements by hash (a format change that reaches only repeats a phone already holds, and no bundle
  made on an earlier build).
