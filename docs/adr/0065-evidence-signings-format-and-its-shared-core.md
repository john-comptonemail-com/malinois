# ADR 0065: Evidence signing's format and its shared core

- **Status:** accepted (the design: the owner, 2026-09-28, refined 2026-10-21 and 2026-10-30; the shared folder: the
  owner, 2026-10-30). Phase 1 built on `claude/1.10`: the format and the verifier's rules. Phase 2, the signer, built
  there 2026-10-31 (ADR 0066). Amended by ADR 0067 (2026-10-31, phase 4): a fourth statement, the export statement;
  and a retention statement retires a key's counters only when signed by the key itself or a key that follows it.
  Amended by ADR 0068 (2026-10-31, phase 5): the verifier's rules take the App ID's SHA-256, as every attestation
  carries it. Amended 2026-10-31 (item 182; below): a fifth statement, the absence statement, and the export statement
  names the statements its bundle shows. A sixth statement, the unkept statement (1.11), is ADR 0073's, which states it
  rather than amending this record again; this record's statements are as it says.
- **Date:** 2026-10-30
- **Summary:** The fixed form the phone signs, its statements and the verifier's rules live in one folder of shared
  code, `MalinoisEvidence/`, which the app and the Mac verifier both build from.

## Context

Evidence signing (BACKLOG item 90) has the phone sign each record seconds after it is written, with a key Apple
certifies once per install (App Attest), so that someone given an exported record can check, without trusting the owner
or the developer, that it came from Malinois on a genuine iPhone, unchanged since it was signed, with nothing removed
from the middle of the sequence. The phone signs a hash, so the bytes it hashes must have exactly one spelling, and a
verifier outside the phone must read them the same way the phone wrote them. Phase 0 (item 78, the owner's iPhone Air,
iOS 27.0.1) showed three things Apple's documents do not: the certificate Apple issues lives three days; every signature
on iOS 27 sets the "credential follows" flag with no credential after it; and iOS 27's build channel is four bytes,
little-endian.

## Decision

- **One folder, `MalinoisEvidence/`, holds the shared code:** the fixed form, the statements, the readers of Apple's
  formats and the verifier's rules. The app compiles it; the Mac verifier is built from the same files (phase 5, ADR
  0068), and the release tools' tests build both for macOS. The app never runs the verifier's rules on its own records (the
  verifier judges, outside the phone).
- **Format `malinois-evidence/1`, three statements, each a JSON object in one fixed spelling:** members in a fixed order,
  every member always present (null for no value), whole numbers only, only the escapes JSON requires, no whitespace,
  hashes and key IDs in lowercase hex, times in milliseconds since 1970 by the phone's clock (stated as the phone's).
  A reader takes a statement only when writing what it read gives the same bytes, and names a newer format rather than
  guessing at it.
  - A record's revision: its ID, its revision number, when and by which build it was signed, its facts (each stored
    field of a record is a fact or is named as not evidence, with the reason, and a test holds the lists to the type),
    and its attachments (each photo or clip file, the thumbnail and each sensor trace, by SHA-256 and length).
  - A retention statement: the counters, per key, that the log's limit retired with their records.
  - A key statement: the statement Apple's certification of a key covers, naming the key, and the key the log was
    signed with before a restore from a backup, if any.
- **The verifier's rules:** Apple's chain is judged a third of the way into the key certificate's own life, which is
  when Apple certified the key under its practice seen on the Air (valid from a day before to two days after), so a
  record checked years later still checks out; the certificate must carry the hash of the key statement, name the same
  key as the key ID and the attestation's credential, belong to Malinois's App ID, start the counter at zero and come
  from one of Apple's two environments. A signature must be the key's over the statement's hash. A signature's data is
  never read as carrying a credential, whatever its flags say. A gap in a key's counters is "retired" when a retention
  statement names it (a key's own only for counters before it; a later key's for an earlier key's, since ADR 0067
  only a key that follows it), and otherwise "missing", a fact, never an accusation.

## Consequences

- A statement once signed is readable by every later verifier: format 1 is fixed from 1.10's release, and a change is a
  new format beside it.
- The repository's tests carry the Air's ten real signatures and the key's public half; Apple's certificate and receipt
  from the same run name the team ID and stay out, so the chain rules are tested on chains the tests make at run time,
  and the Air's real chain is checked by the Mac verifier outside the repository (phase 5: PASSED on the Air's bundle,
  ADR 0068).
- Not taken: a verifier with its own copy of the rules (two copies drift, and drift reads as a false failure), and
  JSONEncoder's output as the signed form (its spelling is not promised across OS versions).
- Left for later phases: where the published verifier gets Malinois's App ID and Apple's root certificate (phase 5;
  answered: the App ID's hash and Apple's root, both built in, ADR 0068);
  whether a later key's retention statement must come from a key whose statement follows the earlier one (when exports
  carry several keys, phase 4; answered yes: ADR 0067); the records the log holds when the key's certification is
  asked for are listed in it and never signed (phase 2, built: ADR 0066).

## Amendment (2026-10-31, item 182): an absence statement, and the export names what its bundle shows

Two changes to `malinois-evidence/1` before its first release (the owner, 2026-10-31: "a" and "b" in a side session,
then "1 - a, 2 - a, 3 - wording approved" and "B"):

- A fifth statement, `absence`: format, type, signedAt, app, records (`[{id, revision, startDate}]`, the IDs in
  ascending order, each once; the revision last signed; the record's start, or null). The phone's signed word that
  these signed records left its log other than by its limit (ADR 0069). A verifier reports it.
- The export statement gains `shown` (`[{key, counters}]`, as a retention statement's `retired`): per key, the counters
  of every statement its bundle shows in full (ADR 0067's amendment).

A key's counters as ranges are one type, `KeyCounters` (`Retired` names it), with one writer and one strict reader for
both statements.
