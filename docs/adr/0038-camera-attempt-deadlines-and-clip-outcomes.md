# ADR 0038: Bound the camera caller and preserve each movie's actual outcome

- **Status:** accepted; shipped in 1.5.1 (58), released 2026-10-12. Build 56 phone checks passed; a forced permanent camera
  stall, a forced old-callback overlap and an actual partial clip's duration were not demonstrated
  on hardware. Amended for 1.6 (65) after the 1.6 reviews (BACKLOG 108, CE-01 and F8): late
  output asks for an upload pass; unclaimed movies 30 days old are removed at launch; the torch
  waits for admission.
- Date: 2026-10-11
- Decision: authorized by the owner after the deadline/label investigation
- Extends ADR0008 (capture failure honesty), ADR0025 (microphone handoff), and ADR0037 (recoverable attachments)

## Problem

The warm-up clock did not cover light probes, interruption queries or finalization.
Timers queued beside blocked camera work could not bound the waiting capture.
The label measured routine elapsed time rather than footage: a real 0.4-second
movie was labeled roughly 3 seconds. Both lenses shared one elapsed value.

## Decision

Each pipeline attempt holds one lease until its actual worker drains. Independent
monotonic timers bound warm-up and the whole caller. The whole budget includes
warm-up, exposure/flash settling, selected fixed recording length or until-clear
ceiling, and 12 seconds for capture queries/finalization/inspection. Tests inject short
budgets. A camera timeout becomes an explicit event reason and camera notice.

Expiry immediately quarantines the controller using a lock independent of its
session queue, invalidates queued starts by generation, requests shutdown, and
releases the waiting response. New captures fail as recovering until the old worker
returns and a queued shutdown actually completes. A refused busy-camera incident keeps
one bounded retry slot, checked again on actual lease release; it never starts a
second physical capture while the first is draining. Cancellation does not establish
that hardware stopped. Disarm invalidates the attempt even if a new session is
already armed when the old await answers. Flash/audio cleanup happens once; a stale
worker cannot rearm sensors or resume another watch's microphone ownership. The worker
checks its lease before its first Vision, Sound or camera action, not only after warm-up.
Sound remains paused until shutdown is actually confirmed; a timeout notice names
that reduced coverage when Sound yielded its microphone. A disarm/rearm invalidates
any late Sound resume. Only this attempt's matching notice is cleared on recovery.

The movie delegate publishes each finished file to the handler registered for that
exact URL before recording began, independently of the session queue. Both-camera
files are handled separately, so a blocked rear delegate cannot hide finished front
footage. Both photos likewise publish each finished lens before awaiting its sibling.
Completed results are retained before awaiting shutdown, so expiry during shutdown
can preserve a still that has already arrived. Delegate waiters remain associated with their exact photo ID or movie URL. They
are not discarded by a timer on the blocked queue. A callback that never returns
leaves the controller quarantined and at most the current capture's waiters held;
it does not leave the response waiting. Relaunch may be needed to recover from a
permanent framework stall. This deliberately favors ownership over retrying an
unconfirmed hardware operation.

Each production call passes its original event/store destination before suspension.
Late output joins that event through the existing recoverable attachment path,
re-reading the current record, reopens completed sync state, and asks the engine for an upload
pass (65): nothing else started one, so late output waited for the next launch, foreground or
reconnect. The engine waits out a pending sweep already running, which chose its records before
this one was pending, then runs its ordinary sweep.
It never attaches to whichever event happens to be current. Upload completion also checks
that the submitted event still matches the stored evidence; an older success cannot hide
a newly attached file from subsequent upload, and an older failure cannot overwrite a newer
successful verdict. Occupied, removed,
mirrored or discarded records retain the source file rather than overwrite evidence.
The destination is checked again after storage publication, so a concurrent discard
or newer attachment cannot be undone. The late-save path introduces no cloud request or
authorization of its own: the pass it asks for is that sweep, with its own lease and enrollment checks. The engine also rechecks watch identity after asynchronous
storage and refuses standby while another capture owns the camera, including within
the same watch.

Movie files are created at unique, not-yet-existing paths in the app's protected
Application Support/PendingCameraEvidence directory, outside the temporary-file
sweeper. Storage moves accepted files out. Unclaimed files are not automatically guessed
into an event after relaunch, and nothing reads the folder otherwise, so one still there after
30 days can never be attached: the launch removes such files (65), since enough of them refused
every new recording through the allowance below. The torch lights only once a recording is
admitted (65); it used to light first, and stay lit over a refused recording. Termination before
the delegate/attachment intent is still not a guarantee of recovered playable media.
Admission refuses an unreadable/linked pending folder, more than 1,200 retained/potential
files, or exhausted 2 GB logical-byte allowance. Each output receives a maximum recording
file size from the remaining allowance. Both outputs reserve from one snapshot before
either starts. This is a separate pending-media allowance from the event-log limit;
AVFoundation's file-size stopping behavior is not an exact disk-reservation guarantee.
Existing evidence is never deleted to admit another movie.

Inspect each returned movie independently with a two-second bound: encoded duration,
video track, and AVFoundation playability. Unknown duration is nil, never elapsed
waiting time. Usable partial files are kept. Missing thumbnails do not invalidate
movies. The recording delegate's successful-finish flag is honored even when an
error exists; incomplete, early, disarmed, expired or unverified output is labeled
using per-camera issue metadata, including attachment recovery and cloud metadata.
The file itself is retained when verification fails; no claim is made it will play.

## Verification and remaining limits

The initial three failing regressions are committed before the implementation.
Additional coverage exercises a blocked finalizer, stale completion after re-arm,
late attachment to the original event, camera quarantine, unequal Both durations,
short footage, opaque bytes, and the delegate's successful-finish flag.
See `docs/verification/camera-deadline-labels.md` for actual run results.

Simulator gates reproduce dependencies, not an actual AVFoundation deadlock. Phone
checks must exercise charging/unplugged audio, early disarm, supported Both mode,
and an actual interruption where reproducible. This does not bound every unrelated
engine operation (for example cloud work), nor force-stop a blocked Apple API.
Submitted 1.5 (55), release metadata and cloud enrollment policy are unchanged.
