# ADR 0008: A capture that produces nothing says why, and gets one bounded retry

- **Status:** accepted
- **Date:** 2026-09-02

## Context

The evidence log's honesty had been built fetch-side: a record without media said so, a
capture the storage cap discarded said so, a mirrored copy said whose device it came from.
The capture side said nothing. A capture that failed left a record with metadata and traces
and no explanation, a Home notice that outlived the event, and a log line — and on the Air
(BACKLOG 53's afternoon, 2026-09-02) the owner could not tell from the log whether the event
existed at all. `AVCaptureSession` reports *why* it interrupts a session (the app left the
foreground, another app took the camera or the microphone, iOS shed the camera under
pressure) and when the interruption ends; a session killed by a runtime error stayed down
and unlogged until the next trigger warmed it (32.R9). None of that reached the record.

The constraints: never on the trigger hot path (the fact is recorded first; a capture that
owns the camera is left alone), never an unbounded loop (interruptions and runtime errors
arrive in storms), and no new schema (the record's cloud payload is a JSON blob whose
unknown keys older builds ignore).

## Decision

1. **Every capture returns an outcome, never a bare nil.** `EvidenceCapturePipeline` yields
   the evidence or a `CaptureFailureReason`: permission denied, the camera unavailable, the
   warm-up past its deadline, the shot or clip failed, one of five interruption classes, or
   storage refused the file. The classifiers are pure. The reason rides the record
   (`Event.captureFailure`, a raw string like the other record vocabularies), the encrypted
   payload only when set, and is allow-listed on the way back in from the cloud.
2. **One bounded retry, only for an interruption.** An interruption-class failure parks one
   retry slot (the latest such event). When the camera reports the interruption ended — or
   at once, if it had already ended while the attempt was still failing, which is how a short
   interruption behaves (amended 2026-09-04, BACKLOG 65 finding 2: the engine keeps the latest
   interruption and its end, classifies an unexplained failure by an interruption that began
   during the attempt, and runs the retry immediately when that interruption is over) — the
   engine takes a single still for that event — if the session is still armed, the failure
   is recent (`captureRetryWindow`, 120 s), the event still has no media, and no other
   capture owns the camera — attaches it, and labels it in the detail view as the second
   attempt; the record keeps its reason. The slot is cleared *before* the attempt and on
   disarm: one try, whatever happens. Cadence captures (flood, blackout) record their
   reason and are not retried; they are the expendable side by ADR 0003. Every attempt
   starts with a clean interruption slate (`beginCaptureAttempt`, BACKLOG 65 finding 5): the
   latch a clip's interruption leaves belongs to that clip, never to a later still.
3. **A runtime error is an audit record.** A session killed under an armed engine logs a
   `cameraError` state record (pushed silently like the other audit kinds; a 1.3 mirror
   renders it, an older mirror drops the unknown kind by its own allow-list), surfaces a
   Home notice, and re-warms the camera per the readiness policy — at most once per
   `cameraErrorDebounce` (60 s), because a session that cannot start emits one error per
   attempt and the re-warm must not feed the storm it reports.
4. **An interruption is surfaced while it lasts.** The Home notice names the system's
   reason and clears when the interruption ends; it never overwrites a capture-failure
   notice, and it never becomes a record of its own — the failed capture, if any, is the
   record.
5. **Until-clear trips are on the record.** A trip that extends an until-clear recording is
   folded into the record's sensor list, not only into the clip's length.

## Consequences

- The record answers "why is there no photo" in the owner's words, locally and on every
  mirror, and a transient interruption often ends with a photo after all.
- Two knobs joined `EngineTiming` (`captureRetryWindow`, `cameraErrorDebounce`); the fake
  camera gained the reason and error knobs, so the whole path is pinned without a device.
- Deliberately not done: retrying non-interruption failures (nothing to wait for), more
  than one retry (a loop with extra steps), a record per interruption (noise under a call
  storm), and a new CloudKit field (the payload blob carries it with no schema deploy).
- Inducing real interruptions — a call under Guided Access, audio-session contention — is a
  device leg (BACKLOG 55). Thermal-pressure interruptions cannot be induced on demand; the
  classifier is what is unit-tested, the notification wiring is what the device leg proves.

## Amendment (2026-09-05, 1.3 (40))

A capture that fails **because the owner disarmed** while it was in flight is classified
`disarmed`: the disarm stops the camera, so the shot or clip fails, and that is not a fault.
The pipeline consults the host's `captureSessionIsOver` at every failure site (warm-up, still,
clip, both-empty) and returns `.disarmed` without the Home notice; `disarmed` is not an
interruption, so nothing is retried. The engine additionally ignores a non-nil capture notice
while no session is active (clearing always passes), so no late-finishing path can leave a
camera warning on the disarmed Home. Before this, the notice was posted after the disarm and
stayed until the next arm cleared it (item 63 leg 6 on 1.3 (39)).

## Retry eligibility correction — 2026-10-11

A busy camera postpones the existing one-shot retry rather than consuming it. The
pending slot is reconsidered after the competing capture releases the camera or a
trigger returns to the armed state. It remains bound to the original watch and event;
expiry, disarm, disabled capture or existing media discards it. New interruptions pause
it again. The slot is consumed immediately before the eligible attempt, so duplicate
end/release notifications cannot cause additional shots. A completed attempt still
preserves its evidence after disarm, but cannot stand down a replacement watch's camera.
This corrects eligibility ordering without expanding the retry budget or window.

## Extension: complete-attempt deadlines and per-file outcomes (2026-10-11)

ADR0038 adds explicit deadline/recovering outcomes and saved-file partial/unverified
reasons. Each movie uses its actual encoded duration. A refused busy-camera shot also
gets one eligible retry after actual camera release; the same watch, age, media and
one-attempt limits apply. Late media keeps its original event destination, including
independently finished Both-camera photos.
