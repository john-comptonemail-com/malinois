# ADR 0071: Evidence signing: the keys this install certified, kept where a backup cannot change them

- **Status:** accepted: the owner's ruling of 2026-11-02, "go on the fixes, A3 a, A4 a, A5 a, A6 a" (BACKLOG item 190,
  A3, on DeepSeek's deepseek-1 in the full review of `aa71756`). It adds to ADR 0069, the signer as it stands, whose
  decisions are unchanged. Built on `claude/1.10` (round 190A), 2026-11-02. Corrected in place the same day, before it
  shipped, for round 190B (BACKLOG item 190, the change reviews of `29d6501`; the owner's "codex-1 a, codex-2 a,
  codex-3 a" and "deepseek-1 b"): which of the file's keys join the list, the list read with the file or neither, the
  log the launch read deciding the line, and what a bundle says when its chain stops at a key it lacks. Corrected in
  place again the same day, still before it shipped, for round 190C (the change reviews of `b7702f5`; the owner's
  "codex-1 a, codex-2 a, codex-3 a" and "deepseek-2 a, deepseek-3 a, deepseek-5 a"): a key from the file joins the list
  only when this install made it; the store hands the signer the log it read; a list the Keychain refused is written
  again, and one that cannot be decoded is taken as none. Corrected in place once more, the same day and still before it
  shipped, for round 190D (the change reviews of `424d8ce`; the owner's "deepseek-2 a"): a list written before the note
  of the keys made decodes, and a key it lacks stays off it; the round's other fixes (the owner's "codex-1 a, codex-2 a,
  codex-3 a" and "deepseek-1 a") meet decisions this record already states. And for round 190E (DeepSeek's note on
  `63e77b0`): point 3 says the list's last certified key, as the code has it.
- **Date:** 2026-11-02

## Context

The signer keeps everything it knows in the signature file beside the event log (ADR 0069): the keys it made and
Apple's certification of each, every signature, the statements. That file is in the phone's backups, as the log is.
A signature a backup's editor takes out shows as a missing counter in every later bundle of its key, but a key's
certification taken out, or the whole file, did not show at all: the phone, finding no certified key, made a new one
whose statement followed none, took the records the log held as its unsigned list (never signed again), and every later
bundle began with that key, the earlier key's signatures and statements, the statements that signed records left the
log among them, gone from it with nothing said. A line damaged in the file's middle would do the same. The limit's list
of the records it removed (ADR 0069, section 3) has had a key kept in the Keychain for this device only since item 182,
so that an edited backup cannot add to it; the signature file had no such anchor.

## Decision

1. **The list.** The signer keeps the IDs of the keys this install certified, in the order Apple certified them, in the
   Keychain (`KeychainService.evidenceKeyList`, item `com.malinois.evidence.keys`): for this device only, readable after
   the first unlock, never synced. No backup restores it onto another iPhone, and none hands it to whoever edits the
   backup; a backup restored to the same iPhone brings it back as it was when the backup was made. With it, the IDs of
   the keys the file was found to have lost and that were dealt with, and of each key this install made, noted before
   Apple is asked to certify it: no key goes to Apple while the Keychain will not take that note (round 190C, codex-1).
   A list written before that note existed (round 190A's and 190B's builds, development installs alone, none of them
   distributed) decodes with no key noted as made, so a key the file lists that such a list lacks stays off it (round
   190D, deepseek-2: a limit). A write the Keychain refuses is tried again at the next pass (deepseek-5).
2. **Read with the file, or not at all.** A list that cannot be read now (before the phone's first unlock since it
   started, or a Keychain error) is never taken as none: the file is not taken as read until the list is, so no key is
   made without it (codex-2). One the Keychain returns but that cannot be decoded is taken as none, since it cannot be
   read back, and the file rebuilds it (deepseek-5). A key the file lists and the list lacks joins the list when this
   install made it, the list having noted it (the app stopped between the file's line and the Keychain), so the list
   never lags the file; any other stays off it, whatever the key statement beside it says, so a key made elsewhere,
   another iPhone's key that genuinely follows this phone's among them, is never the one the next key follows, and
   every later bundle reports it as a problem (round 190C, codex-1 and deepseek-1). A list with no key at all, made or
   certified (the first launch over 1.10 (81)), takes the file's keys from one that follows none, in a chain, as every
   file the app writes holds them. A key the list names that the file no longer lists, and not dealt with yet, is
   missing.
3. **A new key follows the list's last certified key.** A new key's statement follows the last key the list names as
   certified, or none while it names none, where it used to follow the file's: when the file has lost a key, the new key
   still names it, and every later bundle says so (the verifier's existing "a later key follows it" line, for a key the
   bundle's index leaves out too). A key Apple certified that the Keychain did not take (its write failed) is still the
   last this install certified: the next key follows it, and the list is written again at the next pass.
4. **The event log says so, once.** The store keeps this phone's own records in the log as it first read it, at launch
   or, when the phone was locked then, at the unlock, and hands them to the signer (round 190C, codex-2 and
   deepseek-3). The missing keys are dealt with as soon as both the file and that log are known, whichever comes second:
   when that log held a record of this phone's, the edit shows (the log kept, the file's history gone), judged by that
   log alone, never by the records' times, which the phone's clock sets (codex-3), nor by what a later write still
   holds; the event log is then owed one line, written as soon as the signer has heard a write of the log,
   "Signatures this iPhone made earlier are missing: its earlier events can no longer be shared signed" (status kind
   `signaturesMissing`), red as the absence line is, kept in the file (`historyMissing`) until a write of the log holds
   it, under an ID made from the keys; when it held none (a reinstall, which empties the app's files and keeps the
   Keychain), nothing is said. Either way the list then counts the keys dealt with.
5. **Damage is judged by the list.** A line in the file's middle that does not decode is not damage of itself: the
   file starts a new line after one a stop cut short, so such a line can be an honest stop's. A damaged key line is
   caught by the list (point 2); a damaged signature line shows as a missing counter in every later bundle of its key,
   as a signature made and not kept does (SECURITY.md).

## Consequences

- An edited backup restored to the same iPhone can no longer take the signing history away unseen: the phone says so
  in its log, and every later bundle names the earlier key it follows. What the earlier key signed is still gone from
  the phone; the bundles already shared keep it.
- Where the edit keeps the earlier keys' lines and takes out only the last key's, the bundle's chain stops at the key
  taken out, which it does not hold: the check says so (`Report.chainBreak`), and the verifier reports each earlier key
  as cut off from the export's key by it, a problem, the history having been cut (DeepSeek's deepseek-1, the owner's
  "b"). With the whole file taken out the bundle holds no earlier key, and only the note on the key it follows remains.
- On another iPhone the list is not there (it never leaves the phone), nor after a backup made before 1.10 is restored:
  a backup edited and restored there leaves no trace, as a restore that takes the newest records off the phone does,
  and a key of another install put in its file can be the one the next key follows (SECURITY.md's limits).
- A reinstall keeps the list, so its first key follows the reinstalled app's last: bundles made after a reinstall say an
  earlier key's signatures are not there, which is true, and the log says nothing, holding nothing from before.
- Not taken: the file's own hash or count kept in the Keychain (every append would write the Keychain, and a signature
  line taken out already shows as a missing counter); a signed "history lost" statement (the `follows` line already
  tells a recipient, and a signed statement for signatures made and not kept is item 188's); refusing to sign until
  the owner is told (signing must go on).
