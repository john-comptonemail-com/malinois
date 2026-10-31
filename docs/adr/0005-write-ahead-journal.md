# ADR 0005: A write-ahead journal makes detection durable before response

- **Status:** accepted
- **Date:** 2026-08-30

## Context

`EventStore.add` inserted in memory and dispatched the full-log write to a serial queue —
a priority ordering, not a durability guarantee (31.F3 / 33.M2 / 34.H4). A process kill
between detection and that write erased the event entirely. Pro is mostly covered by the
sub-second cloud fact push; the free tier had nothing — and "the record exists before
anything else happens" is this app's foundational promise. The README had to be softened
to admit the gap; three reviews independently ranked closing it the highest-value
hardening left.

## Decision

Every first-hand `add` appends the event's JSON as one line to `events.journal`
**synchronously, on the main actor, before proceeding**. The next launch — and the
post-unlock reload — folds journaled events the log lost back in via `merged`: by id, so
entries the log already holds are no-ops and first-hand rows are never displaced. A
journal line is retired only when a subsequent full-log write reports SUCCESS (the
checkpoint hops the persisted snapshot's ids back to the main actor, coalesced behind a
short debounce); entries born after that snapshot keep their lines. The journal has
exactly one writer — everything runs on the main actor — so nothing races.

*(Amended 2026-08-31, post-1.2 external review #3: "the newest snapshot supersedes every
earlier one, and retiring late is always safe" turned out false once EVICTION entered the
picture — an event persisted, then evicted by the count cap, is deliberately absent from
every later snapshot, so replacing the pending checkpoint set with the newest snapshot
orphaned its line and each launch resurrected the evicted event, evicting another row and
leaving the line standing: churn forever and an unbounded journal. Two completions: the
coalesced checkpoint now takes the UNION of the burst's successfully-persisted ids — an
id enters that set only via a persist that succeeded, so retiring its line is safe either
way — and a recovery whose resurrected event the cap immediately re-evicts retires that
line through the success path of the persist that durably records the absence. A failed
persist still retires nothing: the journal keeps its net.)*

**Implementation note, 2026-10-29 (1.8.2 repair):** persisted UTF-8 JSON now passes through `StoredJSON` string
validation before typed decoding. On iOS 18.0, malformed keys could otherwise trap inside Foundation before an
error reached the journal's skip-line policy. Both startup recovery and checkpoint retirement use this guard;
healthy rows remain unchanged. The existing durability, retirement and corruption policies above are unchanged.

Deliberate bounds:

- **The append is full-synced before the caller proceeds.** *(Amended 2026-09-02, BACKLOG
  53. The original bound was "no fsync": a completed `write` survives process death —
  force-quit, Voice Control "Close application", OOM: the kills this app actually meets —
  and a hard power cut in the same instant was the cloud fact push's race to win, not worth
  10–100 ms of `F_FULLFSYNC` on the trigger path. Two things were missing from that
  argument. The completed write sits in OS caches until the kernel flushes, and that
  interval is undocumented and can be tens of seconds — the power-loss window was a stretch,
  not an instant. And the free tier has no cloud race to fall back on. The first cut of the
  fix put the sync on a background lane, coalesced, so the trigger path paid nothing; the
  device reading then came in at **4.17 ms** for the sync, landing 0.0 ms after the append
  (iPhone Air, 2026-09-02), so the barrier moved onto the append itself and the lane, its
  lock, and its coalescing went away. The record is now on the medium before anything else
  proceeds, for about 4 ms on the trigger path; the cost is logged per event so it can be
  re-read. The guarantee cannot leak through retirement either: a checkpoint pass first
  full-syncs the log that supersedes the lines — one flush per pass, one pass per burst, on
  `ioQueue` — and retires them only when that sync landed; a sync that fails keeps the
  lines, the same safe direction as a failed persist.)*
- **Births in this journal.** Coalesced flood counts and `endDate` keep the async update
  path. First-hand media attachments now have a separate recovery intent (ADR 0037,
  2026-10-11): a completed file can rejoin its existing event after interruption before
  the filename update. `flush()` still requests persistence rather than acting as a
  synchronous barrier.
- **Tolerant recovery.** A torn final line — the kill arriving mid-append, the file's
  whole reason to exist — or any garbage line is skipped, never fatal; a checkpoint
  rewrite sheds it, self-healing the file. *(Amended 2026-10-18, 1.7.1, item 129's F1,
  from Codex's full review of 1.7: until that checkpoint, the next append was written
  straight after the torn fragment, so neither line decoded, and a launch that found
  nothing to recover left the fragment in place. The event appended then rested on the
  asynchronous log write alone, and a second interruption a moment later lost it, with no
  warning, since the append itself had succeeded. Every append now starts on a line of its
  own: when the file does not end in a newline, it writes one first.)*
- **Degrades to the old behavior.** An append that cannot write (a locked launch and its
  protected file) logs once and falls back to in-memory + async persist; the unlock
  reconcile path already owns those events, and the post-unlock reload re-reads the
  journal.

## Consequences

- A detected event can no longer be erased by killing the process, on any tier. The
  README and SECURITY.md durability claims return to full strength. *(Until 1.7.1, not
  an event appended after a torn line; see "Tolerant recovery".)*
- Mirrors are not journaled (`merge` is re-fetchable by construction), and eviction
  cannot resurrect: lines retire against persisted snapshots, which contain every
  survivor.
- The kill-timing itself is not locally testable (recorded per the testing rule); the
  line codec, torn-line tolerance, and fold-by-id rules are pure and pinned. The full sync
  is likewise not observable from a test; that one *completes* before every `add` returns
  is pinned (`journalFullSyncsForTesting`), and its cost was read on a device (BACKLOG 53's
  afternoon: 4.17 ms).
- Item 35's forward-secure sealing hooks the journal append — the single write-ahead
  chokepoint this ADR creates — rather than the path it replaces.
