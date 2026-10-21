# ADR 0006: Store writes preserve monotonic fields; mirrors are copies, not custody

- **Status:** accepted
- **Date:** 2026-08-30

## Context

Three findings from the sixth and eighth external reviews were one disease in three limbs:
a **value copy of an event, held across an async gap, written back whole** over a stored
copy that had learned something in the meantime.

- `respond()` holds a pre-capture copy for the duration of the capture (up to 120 s).
  A disarm meanwhile marks the STORED copy owner-attributed (R-02) and re-pushes it.
  The capture's completion then wrote the stale copy back — attribution erased locally,
  and the rich push built from the same stale copy wrote `ownerAttributed = 0` to the
  cloud at an equal revision, where `.allKeys` overwrites (sixth review, F2).
- The same write-back bypassed the `setSyncState` monotonic guard: a `.synced` event
  walked back to `.pending` because `update()` replaced the whole value.
- On a second device, a mirror the owner had downloaded full evidence onto was
  wholesale-replaced by a later-revision cloud copy — whose `mediaFilename` is nil **by
  construction** (the decoder pins it; the file is not on that device). The reference
  vanished and the orphan sweep deleted the downloaded file (eighth review, M3).

A fourth finding completed the picture from the other direction: the encrypted-data-reset
recovery requeued **mirrors** for re-upload, stamping this device's name on another
device's evidence and racing the capturing device's richer re-upload under `.allKeys`
(eighth review, M4).

## Decision

1. **`EventStore.update` merges, it does not replace.** Every whole-value update passes
   through `preservingMonotonicFields`: owner attribution, once true, stays true; sync
   state moves only where `mayTransitionSyncState` allows — the same rule `setSyncState`
   enforces, now unbypassable. Callers keep their natural shape (mutate a copy, write it
   back); the store guarantees the invariants.
2. **A superseding mirror inherits local enrichment it cannot carry itself**
   (`inheritingLocalEnrichment`): `mediaFilename`, `secondaryMediaFilename`, and a
   thumbnail the incoming copy lacks. Everything the cloud copy actually carries wins,
   as before; only locally-born facts survive the replacement.
3. **Mirrors are copies, not custody.** The reset recovery requeues first-hand events
   only. A mirror is never re-published by this device: wrong provenance
   (`makeMetaRecord` stamps the local device name), and a stale sparse copy can regress
   the capturing device's richer record. Accepted residue, recorded: if the capturing
   device is gone, its mirrored copies stay local after an encrypted-data reset.
4. After an update, upload paths **re-read the stored copy** and push that — never the
   local value they happen to hold.

## Consequences

- The R-02 flagship timing (touch trip at the disarm hold, clip rolling, PIN typed
  mid-clip) keeps its attribution end to end; `.synced` cannot regress through any
  write path; Download full evidence survives refreshes on mirrors.
- Monotonicity lives in ONE choke point, so every current and future caller is covered —
  the flood coalescer's stale `sustainedEvent` anchor included.
- Not taken: making callers re-read-modify-write under a lock discipline. The store is
  MainActor-confined already; the hazard was never concurrency but **stale value copies**,
  which a merge at the write boundary cures without changing any call site's shape.
- Not taken: field-level cloud writes (`.changedKeys`) to protect the cloud copy from
  stale pushes. The per-event chain (ADR 0003) already serializes writes, and the
  re-read-before-push rule makes the pushed value current; `.changedKeys` would reopen
  the partial-record questions ADR 0004 settled.
- The theft edge case in (3) — capturing device gone, reset wipes the cloud, mirrors
  hold the only copies locally — is accepted and documented rather than solved with
  provenance-preserving mirror re-publish; revisit only if it ever bites.

## Amendment (2026-08-30, fourth pass R3-4): copies-not-custody extends to eviction

The count cap's eviction order treated mirrors and first-hand events as one population,
so bulk-inserted future-dated mirrors at a full log could evict first-hand events and
their local media — iCloud credentials reaching on-device evidence, which tier 2 rules
out. Two completions of this ADR's principle:

- **Mirrors evict first.** `countEvictionOrder` gains a mirror class ahead of every
  first-hand pass: a mirror is a copy — the capturing device and the cloud still hold
  it, and a re-fetch restores it — so shedding one loses nothing this device owns.
  *(Amended 2026-08-31, post-1.2 external review #1: the newest-event exemption
  (39.R1.6) now applies to first-hand passes only. Its rationale — the just-added
  record of an incident in progress must not self-evict — never described a mirror,
  and shielding a newest mirror let one merged record per sync slip past the mirror
  pass and evict first-hand evidence instead, bypassing this amendment at exactly the
  one-newest-mirror boundary. The mirror pass now includes the newest row; a newest
  mirror evicting itself means "the cloud row didn't fit", and a re-fetch re-attempts.)*
- **Cloud timestamps are bounded.** A record's `startDate` is believed at most a day
  past its own server-stamped `creationDate` ("now" for a record that never got one).
  The field that decided sort order — and therefore eviction age — was the one scalar
  the decoder's clamp suite missed.
