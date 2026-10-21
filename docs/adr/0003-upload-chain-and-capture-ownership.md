# ADR 0003: Per-event upload serialization and single capture ownership

- **Status:** accepted
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

## Amendment (2026-09-20, 1.3.2): the pending sweep finishes what it starts

Owner report, with a large backlog of arm/disarm records: the Event Log's spinner stopped
while the sync carried on, and only part of the backlog seemed to go up per pull-to-refresh.
The sweep as decided above explains the first outright and could explain the second (see
the device check below). It was single-flight but told nobody it was
running, so a screen whose request was turned away showed nothing; and it was ONE pass, in
which every save gives up after three attempts whose waits are capped at 4 s. That cap is
right at trigger time, where a push races a power-off. It is wrong for a sweep: when iCloud
answers a long backlog with "slow down", every record after the first failure spent its own
attempts against the same answer, and the rest waited for the next trigger.

The sweep keeps its single-flight guard and its bounded parallelism, and gains four rules,
each a pure function the tests pin:

- **It says it is running.** `pendingSweepActive` is published for the sweep's whole life,
  whoever started it, and `pendingSweepWaiting` while it waits between passes. The log's
  banner follows both (`bannerShowsSpinner`, `bannerCaption`).
- **A save that gives up says why.** `CloudExfiltrator.transientFailure(from:)` uses the same
  transient set as `retryDelay`, by construction, and carries the server's Retry-After
  UNCAPPED. When several saves give up in one pass the longest wait stands.
- **A pass stops handing out records when the door is closed** (`sweepDoorClosed`): at once
  when the server named a wait, because that answer is about the device and not the record;
  after three failures in a row when it named none, which is what an outage looks like. One
  record that cannot get through (a large clip stalling on a slow link fails the same way a
  lost path does) holds nobody back. Refusals never close the door.
- **The sweep makes follow-up passes by itself** (`sweepFollowUpDelay`): only for a transient
  failure, with records left and a network path up; after the server's own wait, else 2 s
  doubling per pass that landed nothing, clamped to 2–120 s; at most 20 passes, at most 3 in
  a row that land nothing. A refusal is an answer the next trigger can re-ask; an offline
  device has the reconnect trigger.

`retryPendingSync()` still returns after the FIRST pass, because the Event Log and the launch
both follow it with a pull that must not sit behind a wait. Follow-up passes run on a task
the engine owns: a screen's task is cancelled when the screen closes, and a cancelled wait
is no wait at all. The trigger-time path is unchanged.

Not taken, deliberately: batching many state records into one CloudKit operation. It is the
real fix for very large backlogs (one operation per record is what would invite a throttle)
and it changes the per-event chain above, so it is its own decision for 1.4.

**Device check (2026-09-25).** A seeded backlog of several hundred records on the owner's
Debug build went up in one pass, with the spinner up throughout and no pull needed. No pass
was logged, so iCloud never asked the app to slow down (the development environment;
production was not measured). The owner's second symptom is therefore better explained by
the first: the upload ran on after the spinner stopped, so each pull showed more rows
green. The follow-up passes stay as the guard for a throttle when one happens (Apple
documents `requestRateLimited` with a Retry-After, which the 4 s cap ignored), but they are
pinned by unit tests and have not yet been seen working on a device.
