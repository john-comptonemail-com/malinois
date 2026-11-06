# ADR 0066: Evidence signing's signer

- **Status:** accepted: Claude's choices within the plan the owner ruled (2026-10-30, (b)) and the owner's ruling on
  where the signatures are kept (2026-10-31, (a)). One choice departs from the plan, RULED (the owner, 2026-10-31:
  "certify at launch, yes"): the key is certified at launch. Built on `claude/1.10`, 2026-10-31. Its decision on records
  leaving the log is superseded by ADR 0069, which states the design its thirteen amendments (2026-10-31 to 2026-11-01)
  built, as it stands; the amendments are listed at the end. Corrected 2026-11-01 (BACKLOG item 187): App Attest's keys
  survive no restore from a backup, onto the same iPhone or another (Apple's documentation); a signature made and not
  kept is missing in every later bundle of its key, until the phone names it in a signed statement, which ADR 0073
  decides (1.11).
- **Date:** 2026-10-31
- **Summary:** One Secure Enclave key per install, which Apple certifies at launch, signs each of this phone's records
  at each change once its write is on disk, the signatures kept in a file of their own beside the log.

## Context

Phase 2 of evidence signing (BACKLOG item 90): the phone signs its records with a key Apple certifies once per install
(App Attest). ADR 0065 sets the format and the verifier's rules. The signer must never slow a trigger and never touch
the event log, and it must leave a file a verifier can account for in full: App Attest counts every signature, and a
verifier reads a counter with no signature in the file as a signature removed, unless a retention statement names it.

## Decision

- **The key.** One per install, made in the Secure Enclave and certified by Apple once. The app asks at launch and
  whenever it comes forward, until Apple answers; a failed try waits a minute; never on a trigger's path. Nothing is
  asked while the event log is unread (waiting for the unlock, or failed to load), so the first certification lists the
  records the log holds, and those are never signed. The key's statement names the app's version and, after App Attest
  lost a key (a restore from a backup, or a move to a new iPhone), the key it follows.
- **What is signed.** Each record first written after that first certification, this phone's own (never another
  device's copies), at each revision whose facts or attachments changed, once the write of the log that holds it is on
  disk. One pass at a time: a write that comes during a pass is taken when it ends, and an older write that arrives
  late is ignored. A photo or clip is covered by its file's hash when the file is a plain file in the media folder; a
  file no longer on the phone is left out, and one there but unreadable now makes the record wait. ADR 0069 adds a
  record's identity (section 2) and what the signer trusts in its own file (section 1).
- **Where.** In a file of their own beside the event log (`evidence-signatures.jsonl`), one entry a line, appended and
  synced, under the log's protection (`completeUnlessOpen`). A signature that cannot be made or kept leaves the record
  untouched and is tried at the next write. None is asked for while the file cannot take a line (the phone locked: the
  log is written as a new file, which that protection allows while locked; this file is appended to, which it does
  not), so no counter is spent without its signature.
- **Records leaving the log.** Retired by the log's limit: a signed retention statement names their counters, and then
  their signatures leave the file. Gone with a log the launch did not read (set aside as unreadable, or missing because
  the launch that set it aside ended before writing a new one): noted as set aside, their signatures kept, never
  retired; the note stays owed until the file takes it. **Superseded by ADR 0069** (sections 3 to 5): retention only
  for what the limit removed, and any other signed record that leaves the log named in a signed absence statement.
- **No App Attest** (the Simulator, a Mac, a device without it): nothing is signed, and the file says so once.

## Consequences

- The app contacts Apple's App Attest service once per install (and again after a restore from a backup or a move to a
  new iPhone): a new network destination for the privacy policy, the support page and the review notes, in wording the
  owner approved (2026-10-31). Apple receives the key's public half and a hash of the key's statement, never a record.
  App Store Connect's App Privacy answers stay as they are (Apple's service; nothing reaches the developer).
- A record written while the phone is locked is signed at the first write of the log after it unlocks, usually the
  disarm, and its signature carries that time. While locked, Data Protection keeps the record from being changed.
  The device check on the iPhone Air (2026-10-31) showed it: a record written while locked was signed at the first
  write after the unlock, no counter spent meanwhile.
- A signature made and then not kept (the phone stopping in the instant after it is made, a crash, a forced restart or a
  flat battery, or a write failing then, a full disk) still leaves a gap in its key's counters, which a verifier reports
  as missing in every later bundle of that key, for as long as the key lives: rare, and stated in SECURITY.md (item
  187). From 1.11 the phone names the key in use's such gaps in a signed unkept statement, which a verifier counts, and
  holds a line a full disk refuses until the next signing: ADR 0073.
- Departs from the plan: the plan certified "at setup or the first arm (lazy certification)". At the first arm, a
  record made in the second or so before Apple answers would be in the log at certification and so never signed; at
  launch the key is ready before the first arm. The cost: an install that is never armed still contacts Apple once.
  Ruled at launch (the owner, 2026-10-31: "certify at launch, yes").
- Not taken: signatures inside the records (ruled (a): signing never rewrites a record); a less protected signature
  file that could be appended to while locked (its statements carry the records' facts, which the log protects).

## Amendments, now ADR 0069

From 2026-10-31 to 2026-11-01 this record took thirteen amendments: the first for the fix of records leaving the log
(BACKLOG item 182), then one for each of Codex's twelve change reviews of it. ADR 0069 states the design they built, as
it stands; BACKLOG item 182 and `docs/verification/1.10-development.md` hold each defect, the review that found it and
the owner's ruling. The amendments, for what cites them (the code cites the fifth):

1. 2026-10-31: what leaves the log: retention only for the limit's removals, absence statements, the event log's line
   (ADR 0069, sections 3 to 5).
2. 2026-11-01: the removals' file checked and read before the journal's recovery, retention statements read back, the
   line found again (ADR 0069, sections 3 and 5).
3. 2026-11-01: a signature counts for the record it signs, a retirement drops exactly what it retired, the line against
   its iCloud copy and the limit (ADR 0069, sections 1, 3 and 5).
4. 2026-11-01: each signature checked before it is acted on, retired signatures cleaned up after a relaunch, owed lines
   held from the limit (ADR 0069, sections 1, 3 and 5).
5. 2026-11-01: every certification read before any signature, no unsigned note exempts a record, a record is what its
   live signatures signed, a revision no count can pass not signed past (ADR 0069, sections 1 and 4).
6. 2026-11-01: only the keys every bundle lists, an edited first list stops no signed record's changes, no bundle before
   the signer has compared the log (ADR 0069, sections 1 and 8).
7. 2026-11-01: a comparison counts once it has named what it found (ADR 0069, sections 4 and 8).
8. 2026-11-01: the pass's own certification names what is owed, a record keeps its identity (ADR 0069, sections 2 and
   4).
9. 2026-11-01: the limit's removal retires only the record it removed, a line written again is the line as signed (ADR
   0069, sections 3 and 5).
10. 2026-11-01: the interruption mark joins the identity (ADR 0069, section 2); the limit and the log ordered by time,
    undone by the eleventh (ADR 0069's consequences).
11. 2026-11-01: the log's own order again, only the signer's line placed by its time; an add's own row never its limit's
    (ADR 0069, section 6).
12. 2026-11-01: the order things happened on this phone on every path; journal lines owed retirement kept until retired
    (ADR 0069, sections 6 and 7).
13. 2026-11-01: the signer's lines by their time on every path; every row the limit removes owed its journal line's
    retirement (ADR 0069, sections 6 and 7).
