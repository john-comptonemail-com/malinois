# ADR 0002: Full-media retrieval by deterministic record ID

- **Status:** accepted
- **Date:** 2026-08-26

## Context

Full-resolution captures upload to CloudKit as photo records, but every read path fetched
only metadata and state records — nothing anywhere could bring a full capture back. After
a theft or reinstall the owner held thumbnails of their own evidence, against a Pro
promise that it "survives the phone being taken" (34.B1). Two designs were considered: a
media manifest inside the meta record (typed, robust, but a new encrypted field —
requiring a Production schema deploy, which has burned this project twice), or direct
fetches of the deterministic photo-record names both generations already write
(`photo-<slot>[-v2]-<eventID>`).

## Decision

Retrieve by **deterministic record ID**. A fetch by ID needs no query, no index, and no
schema change, so it works against the Production container exactly as deployed. The
candidate list covers both generations (v2 preferred), the asset's kind is sniffed from
its leading bytes (the record carries no type field), and the store takes ownership of a
downloaded capture exactly as it does a fresh one — UUID filename, evidence-grade
protection, derived thumbnail. Retrieval is on-demand from the event's detail view, never
bulk: a restore must stay small enough to run on a push wake-up, and clips can be large.

## Consequences

- The Pro backup promise closes: what uploads can come back, including media the local
  byte cap evicted.
- No schema deploy, so nothing new can fail silently in Production.
- The name coupling becomes load-bearing: `fullMediaRecordNames` must change in lockstep
  with `exfiltrate`'s suffixes — both sides are pinned by unit tests.
- A typed media manifest in the meta record (with camera, duration, availability) remains
  the more robust 1.2 evolution; it subsumes this mechanism without invalidating it.
