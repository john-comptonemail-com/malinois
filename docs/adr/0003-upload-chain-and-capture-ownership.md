# ADR 0003: Per-event upload serialization and single capture ownership

- **Status:** accepted. Its upload decision is stated as it stands in 1.11, with the design its twelve amendments
  built (2026-09-20 to 2026-10-30, 1.3.2 to 1.10), by ADR 0075 (BACKLOG item 186); the amendments are listed at the
  end. Its capture decision stands here.
- **Date:** 2026-08-27

## Context

One event's evidence is written to CloudKit several times (the fast fact, the rich
post-capture record, owner attribution, retries), from several triggers (trigger time,
reconnect, foreground, log-open). The revision ladder orders *payloads* but could not
order *writes*: two writes could both pass the local preflight before either landed, so a
stale earlier write could finish last and win under `.allKeys` (review B2's residual).
Separately, the camera pipeline had three independent capture initiators — trigger
responses, blackout evidence, flood cadence — whose overlap could reconfigure a session
mid-recording or cross-wire a recording's stop (34.H10).

## Decision

**Uploads:** every CloudKit write for one event runs through a per-event chain
(`CloudExfiltrator.enqueue`) — each write starts only after the previous write for that
event has finished. Chains for different events stay concurrent, preserving
`retryPendingSync`'s bounded parallelism; that sweep is additionally single-flight, since
its three callers routinely fire within a second of each other.

**Captures:** the trigger response owns the pipeline outright; cadence captures (blackout,
flood) yield to it *and* to each other, are stills by construction (a photo answers their
purpose and stills cannot contend for the movie output), and a recording accepts exactly
one stop.

## Consequences

- The stale-overwrites-rich race is structurally impossible within a process; across
  launches the revision ladder still governs, as before.
- A slow clip upload for one event cannot delay another event's fact push.
- Cadence evidence can be skipped under contention (logged); the trigger's capture — the
  product — is never the one that yields.
- The chain is in-memory: it orders writes from this process only, which is the scope the
  race ever had.

## Amendments, now ADR 0075

From 2026-09-20 to 2026-10-30 this record took twelve amendments, from the owner's report on 1.3.2, the security
audits of 1.8 and the reviews from 1.8.1 to 1.9. ADR 0075 states the design they built, as it stands; the BACKLOG
items named hold each defect, the review that found it and the owner's ruling. The amendments, for what cites them (the
code and its tests cite the second and the third):

1. 2026-09-20, 1.3.2: the pending sweep finishes what it starts: it says it is running, a save that gives up says why,
   a throttle or an outage closes the pass's door, and the sweep makes follow-up passes by itself (item 79; ADR 0075,
   sections 2 and 5).
2. 2026-10-22, 1.8.1: a stall deadline for a record carrying a file (item 152's lead 2; ADR 0075, section 3).
3. 2026-10-22, 1.8.1: the background-task assertion covers a push from its first step (item 153's MAL-01; ADR 0075,
   section 4).
4. 2026-10-22, 1.8.1: a sweep during a capture is not the event's last word (item 155's A1; ADR 0075, section 6).
5. 2026-10-23, 1.8.1: the attachment and its reopen are one write (item 155's S1; ADR 0075, section 6).
6. 2026-10-23, after 1.8.1's submission: two limits the full review found, which the next two fixed (item 162's A10
   and A11).
7. 2026-10-24, 1.8.2: the stall deadline on a clock no setting moves (item 162's A11; ADR 0075, section 3).
8. 2026-10-24, 1.8.2: one order per incident (item 162's A10; ADR 0075, section 1).
9. 2026-10-26, 1.8.2: the files an upload sends, and the discard check's wait (item 166's codex-27, codex-28 and
   codex-30; ADR 0075, sections 5 and 7).
10. 2026-10-29, 1.9: a thumbnail that could not be staged stays owed, and a failed fact reopens its row (item 175;
    ADR 0075, section 6).
11. 2026-10-29, 1.9: the reads have deadlines too (item 180's A2, codex-4 and deepseek-3; ADR 0075, section 3).
12. 2026-10-30, 1.10: the watch's two reads have deadlines too (item 180's codex-5; ADR 0075, section 3).
