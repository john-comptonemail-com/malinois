# ADR 0001: Go loud only on evidence of interference

- **Status:** accepted
- **Date:** 2026-08-26

## Context

The observed-failure escalation (review F3) sounds the persistent blackout siren when an
evidence push exhausts its retries while the network path still looks up — on the theory
that a hostile network is blackholing the evidence, and covertness is moot once evidence
cannot escape. But CloudKit also refuses saves for reasons that are not interference: a
full iCloud quota, an auth lapse, a schema mismatch, an encrypted-key reset's
`zoneNotFound`. Those errors are correctly classified non-retryable, which sent them down
the same path — a permanent, full-volume false alarm asserting an attack that is not
happening, in the owner's absence (BACKLOG 32.R1; two further refusal classes were found
by the fourth review, 34.H13 and 34.H9). The realistic trigger is the quota: the app
writes photo records to CloudKit forever and deletes none, so a full iCloud is eventual.

## Decision

**The tamper response escalates only on evidence of interference.** A terminal push
failure is classified: the network class — no path, a request that vanished (CKError
`networkUnavailable` / `networkFailure` / `serverResponseLost`, or a bare transport
error) — may escalate under the existing canary conditions; every other failure is a
**refusal** — Apple's servers answered — and is surfaced to the owner on Home instead.
Apple-side throttles and outages (`serviceUnavailable`, `requestRateLimited`, `zoneBusy`)
count as answers, not interference. An unclassifiable failure stays quiet: only evidence
may escalate.

## Consequences

- A full iCloud, a signed-out account, a schema regression, or a key reset can no longer
  sound the siren; each shows an owner-facing notice, and the evidence stays local and
  badged for retry.
- A genuine blackhole still escalates: it presents as the network class.
- A hostile network that answers with well-formed CloudKit refusals is misclassified as a
  refusal and stays covert — accepted: that adversary already controls the network and
  could as easily blackhole the canary; the local record and the on-return notice survive
  either way.
- The classification lives in one pure function (`failureSuggestsInterference`) and one
  pure response rule (`pushFailureResponse`), both unit-tested, so the boundary cannot
  drift silently.

## Implementation amendment (2026-10-10): record every interference escalation

The owner observed the warning/siren during an offline capture, followed by successful
sync on reconnect, without a distinct signal-loss entry. The timed canary already wrote
one, but the trigger-time and observed-network-failure paths bypassed that write.

All new blackout escalations now write the existing sensorless **Signal loss** event
before publishing the warning or starting the siren. The same escalation's duplicate
guard also prevents duplicate records. Reconnection/disarm ends that episode, allowing
a later one to be recorded. This repairs the existing evidence-before-response rule;
it does not widen the interference classification or change alarm policy.

Only the timed canary requests an additional best-effort photo. The other paths already
have a triggering event and must not take the camera again. Every record follows the
existing local persistence/Pro upload flow, with cloud authorization captured at creation.
The offline flag reports observed connectivity: terminal network errors with an online
path are recorded without falsely asserting the phone was offline. Existing schema and
record naming are unchanged; no claim of deliberate jamming is added to the log.

A Signal loss record reports an escalation already raised. Its own upload must never
originate another interference alarm: an in-flight failure may return after reconnect
or after a different watch has begun. Upload/retry and sync-state updates still run,
and explicit CloudKit refusal notices remain visible. This applies to later sweeps too,
using the existing event shape (sensorless, not a status/interruption/wrong-PIN record)
without a new persisted field. Ordinary incident upload classification is unchanged.
