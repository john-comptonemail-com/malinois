# ADR 0063: 1.9 hardening and engine components, in separately verified stages

- **Status:** accepted; stages 1 to 4 implemented and their simulator checks passed on the candidate `42791a33`, and
  again on the candidate `de9a0045` (`docs/verification/1.9-development.md`); stage 5: the Xcode Cloud Test action run
  on `de9a0045`'s files on 2026-10-30 (the gate's 1,683 tests; its 43 failures all from the test machine, which has
  neither the project's files nor a working audio device for the speaker setting; both gaps accepted by the owner), and
  TestFlight 80, archived from `de9a0045`, passed every step on the owner's devices on 2026-10-30, live iCloud alerts
  included; the device checks it could not walk stay unobserved (`store/DEVICE_TEST_CHECKLIST.md`)
- **Date:** 2026-10-29

## Authority and base

The owner said, "Let's proceed with 1.9 on top of this", after the 1.8.2 repair passed all 1,603 tests on
iOS 18.0 and iOS 26.5. Development therefore starts on `codex/1.9` from repair documentation commit
`8051aecf28057d0642b8ccd11a49d1a203bf4b3d` (tested source `aef95dad`). This supersedes the earlier wait
for approval day for development. It does not authorize a merge, archive, publication, submission change or
public push. The submitted 1.8.2 build remains unchanged. Codex's ledger updates stayed local at the owner's request;
they came to `main` when 1.9 returned to Claude (the owner: only Codex had been asked to keep them local).

The scope and architectural decisions are the existing rulings in items 158, 160, 173, 175 and 178, read from
`origin/main` at `0ce553eaa689c5378f9d3d12acfa64b87be49360`. No evidence signing or camera app ships here.

## Sequence

1. Temporary upload-thumbnail cleanup, then the four cloud/recovery hardening fixes. Each bug starts with failing
   regression tests, followed by its fix, undo checks and review of every same-shaped path.
2. Extract an actual cloud coordinator, then trip responder, then arming flow. Each component owns its work and
   state; the engine remains the existing UI-facing facade. Each stage preserves behavior and passes the full suite,
   strict lint, ThreadSanitizer and an independent review before the next stage. Compare moved lines with their
   original bodies and separately review the new connecting code.
3. Raise the iOS minimum to 18, remove BiometricBinding's iOS 17 branch, update supported-version claims, and keep
   watchOS 10. Prepare 1.9 (80), without archiving.
4. Add and test the release gate requiring a full iOS 18.0 run on the exact candidate commit and gate test count.
   Zero failures are required; any unavailable-feature skips must name the tests and reasons. This is once per
   candidate, not every intermediate gate. Run the final full suites on 18.0 and the current runtime.
5. Verify the private Xcode Cloud Test action and count. Device walks and live iCloud checks remain explicit
   evidence requirements; simulator results do not substitute for them. Release actions wait for the owner.

## Temporary thumbnail path inventory

Shape: a temporary upload asset survives process termination before its normal `defer` cleanup.
`CloudExfiltrator.pushMetaRecord` is the writer: `writeTemp` stages thumbnail bytes for a CKAsset, the save awaits
CloudKit, and the defer removes the file on success, error or cancellation. Event-store originals and capture
clips have separate ownership and cleanup rules and must not be touched.

New files receive an exact `malinois-upload-thumbnail-<UUID>.jpg` name. A launch sweep in `makeServices` removes
only regular files with that exact owned name, never directories, symlinks or arbitrary JPEGs. Bare UUID JPEGs
from older builds remain untouched because their ownership cannot be proved. All in-process active thumbnail
URLs are protected across suspended saves, including repeated service creation. The MainActor serializes the
sweep and active-file registration. The temp directory is injectable only for tests. Tests drive real service
construction and real metadata saves, holding multiple saves open to exercise the cleanup race.

## Cloud hardening path inventory

Shape: a partial success is treated as complete, or a merge ignores newly available data at the same revision.
Every `pushMetaRecord` caller must distinguish a record landing from a thumbnail landing: normal exfiltration,
record-only facts, sustained-event updates/final flushes and owner-attribution repushes. Failed fact completion
runs inside the uploader's event queue using the actual queued snapshot. It reopens only a matching first-hand
row, allowing local cache filenames and the outstanding discard-check flag to change during the save. That
exception changes only the current row's sync state; the next upload uses current files, manifest and revision.
Full-upload completion remains strict. A later capture, attribution, receipt generation, mirror or queued success
must not be demoted. Lease lookup refusal still owes retry when backup policy allowed the fact; a deliberate backup
block does not. A failed thumbnail stage still allows the sparse record to reach
iCloud, leaves the event pending, and does not classify local staging failure as hostile interference. A retry
stages the thumbnail again. `EventStore.mergeFromCloud` must accept thumbnail enrichment at equal revision while
preserving its monotonic fields and refusing a downgrade. No new persisted field or CloudKit schema is required;
older builds continue reading the existing sparse and enriched records.

Shape: deletion callbacks contain per-ID outcomes that disagree with an overall operation result.
`deleteSubscriptions` must count per-ID `unknownItem` as already absent, matching record deletion's existing
reducer. Other per-ID failures stay failures; an absent callback is not invented as a successful deletion. Tests
cover partial failures, known success and unknown IDs through the operation callback seam. The installed Swift
bridge normalizes the tested partial failures to overall success, so the observed defect is false success for
failed or unconfirmed IDs; positive unknown-item cases already passed. A separate pure reducer test covers an
operation-level partial failure directly. ADR 0004 records the probe's exact scope and SDK; no live server result
is inferred.

Shape: a receipt becomes invalid after local bytes have already been pruned. Requeue already advances the upload
epoch and voids receipts. It must also owe the existing bounded cloud-loss check for affected captures. Follow the
event through local pruning, requeue, record-only upload, cloud absence, durable loss marking and relaunch; the
actual detail-view download condition must not offer media that is gone everywhere. Do not alter media retention,
clear monotonic loss fields, or introduce a per-camera loss label.

## Recovery-marker path inventory

Shape: a predecessor recovery marker is removed before its successor is installed. At launch, keep the armed or
interrupted-recovery marker through the interruption log and the owed re-arm write, then retire it. When an owed
re-arm starts, install recovery-in-progress before retiring the owed flag. A declined crash-loop attempt still
consumes the owed attempt; entitlement, PIN recovery and locked-settings deferrals leave it owed. An ordinary interrupted countdown also keeps its marker until its interruption is recorded (or an already
logged lapse is recognized), while preserving its no-auto-rearm rule. Check the
foreground, entitlement-resolution and unlock paths, all of which converge on the same recovery methods, plus
go-live and clean-disarm marker cleanup. Preserve existing duplicate-lapse suppression and crash-loop timing.
Tests observe the real transitions, not a helper invoked solely by the test. This reorders existing UserDefaults
writes; it does not claim a multi-key disk transaction or exactly-once logging after arbitrary process death.

## Component boundaries

`MonitoringCloudCoordinator` owns cloud single-flight/rerun state, binding-use counts, reset/restore notices and
guards, heartbeat session/sequence/timer and cloud test seams. Its extensions contain the existing backup, transfer,
launch-pull, cloud-copy, retention, sweep, fact-push and late-evidence work. `CloudExfiltrator`, `CloudEnrollment` and
`EventStore` keep their transport, account-policy and storage responsibilities.

`MonitoringCloudHost` is a weak, class-bound MainActor protocol. Seven getters read current watch state, upload
permission, armed entitlement, arm time, connection-at-arm, charging and live flood anchor. Five actions update the
log count, escalate upload interference, refresh notification health, log a backup change or write the owed reinstall
record. The protocol exposes no engine reference. Post-await accesses continue to read current facts rather than a
cached watch snapshot.

The engine owns the coordinator and retains its existing six published cloud properties, including their projected
publishers. In the engine's source file, initialization installs six weak synchronous callbacks before
`watchBackupSetting` or settings resolution can publish. Each coordinator will-set callback immediately assigns the engine
property, including equal values; there is no initial replay, deduplication or extra task. The engine's publishers
retain their existing will-set semantics. Existing entry points, constants, nested types and test seams forward
through a compatibility extension.

Each finite async facade call holds its host through completion. Every finite task created by moved code takes a
strong lifetime token synchronously before scheduling and releases it after existing cleanup defers, preserving the
engine ownership the original task captured. This includes queued uploads, notification-health continuation,
heartbeat send, reset recovery, cloud-copy retry, delayed sweep and the owed rerun. The repeating timer retains its
weak capture; uploader/store hooks and publisher callbacks remain weak, so idle ownership has no cycle. UIKit
background assertions, account/binding pins and media leases keep their original start/end boundaries.

The move audit inventories all 80 function/type bodies. It compares exact body text only in the coordinator files;
the ten finite-task additions and the two host/helper receiver changes are reviewed separately (11 changed bodies
because the heartbeat body has both). New tests exercise two independent components, synchronous publisher order,
queued and awaited upload ownership, delayed sweep/rerun lifetime, weak idle hooks and fresh watch facts after waits.
These contracts do not prove live iCloud, lock-time Data Protection or device capture behavior; the stage's red/green,
undo, full-suite, lint, ThreadSanitizer and independent-review results must be recorded separately before completion.

`MonitoringTripResponder` owns correlation/latch state, sensor and aggregate flood windows, the live flood anchor,
its flush/capture cadence and timers, per-session sensor/PIN fold buckets, one shared cadence claim, interruption
history and the parked retry. The same `EvidenceCapturePipeline`, `EventStore` and cloud coordinator are injected;
there is no second camera, event ledger, binding counter or upload policy. The engine remains the pipeline host.

Its weak `MonitoringTripHost` supplies eight current watch facts and narrow actions for sensor traces/rebaseline,
published state/count/time, camera notices and physical response. Root still owns dry-run publication, motion time,
covert-screen transition, disarm attribution and alert/siren policy. Host calls occur synchronously where those
operations originally ran: handling becomes true before `.triggered` publishes; event registration and journal add
precede count publication; rebaseline precedes clearing the responder's handling state and publishing `.armed`.
There are no trip property mirrors or duplicate observable state. Existing engine entries and static helpers forward.

Four finite response/flood/PIN spawns retain root before scheduling. Awaited facade entries retain it through
completion. Interrupted retry deliberately stays weak before admission; only after the queued callback finds the
live host and matching current session/slot does it hold root through capture, file storage and cloud handoff.
Both trip timers keep weak admission and require a live host when firing. The cloud coordinator takes ownership of
its queued upload before the response releases its binding use. Disarm invalidates timers and resets their state at
the original sequence points, retaining older in-flight responses' per-session fold buckets.

The trip inventory covers 30 function/type bodies: 18 are byte-for-byte copies, including initial capture storage,
the complete retry body and blackout capture; 12 have explicitly reviewed host/receiver/lifetime edits. Retained root
methods change only their start/disarm reset fragments and notice-owner reset; initialization connects the component
before camera or settings callbacks. `EngineTiming` defaults are unchanged. Seven new contracts exercise independent
fold buckets, synchronous publication order, queued response and admitted retry lifetimes, weak pre-admission retry,
shared flood/blackout admission and weak idle timer/camera routes. Full-suite and ThreadSanitizer results, undo
witnesses and independent review remain separate evidence; generic compilation alone is not completion.

`MonitoringArmingFlow` owns grace remaining/deadline/timer, calibration progress/run/timer, review state, the one-arm
Guided Access lift and its consumed-log latch, and the briefing timeout/touch date. Four synchronous will-set callbacks
mirror its exclusive values onto the existing engine publishers, installed before startup callbacks can arm. An
observer receives the proposed value while both stored getters still return the prior value; equal assignments still
publish. The flow reads current host facts, with no cached watch or entitlement snapshot and no generic engine reference.

The engine's writable `firstArmBriefing` remains the single binding authority; its existing didSet forwards timeout
and idle-timer work synchronously. `lastCalibration` stays on root because Test Sensors also writes it. The root also
keeps its passcode query/UI state, hardware/monitor operations and every recovery marker transition. The same-file
passcode bridge preserves the DEBUG query override without exposing its private implementation to other files.

The original preparation and presentation fragments remain on root around the first-arm lift decision. Entering
countdown publishes state and plants its marker before remaining-time publication. Calibration publishes its state
and zero progress before beginning the monitors. Finishing calibration publishes the shared summary, starts the
physical watch, then publishes review. Go-covert clears review before publishing armed state. Disarm invalidates the
real grace/calibration timers at their original position; review clears at its separate later position. No extra
scheduling hop, second recovery service or new cancellation rule is introduced.

The finite camera-permission task retains root before scheduling and through its answer and preparation. Grace,
calibration and briefing timers and the review delay keep weak admission, require a live host when their queued work
runs and then hold it through that synchronous work. Root-owned cloud warm-up and health tasks remain root-owned.
Recovery still bypasses the ordinary PIN/briefing/Guided Access coaching and enters its existing ungated countdown;
its pending/successor/retirement ordering is unchanged.

The arming inventory contains 25 function/type bodies: 16 are verbatim, nine have reviewed host/lifetime edits. Five
physical root fragments and EngineTiming defaults are unchanged. Four new contracts exercise lift publication and
equal assignments, real countdown/calibration/review boundaries, writable briefing timer replacement and finite
permission ownership. The existing calibration-timer regressions now inspect the actual flow timer, including
synchronous invalidation at disarm. Red/green, undo, full-suite, lint, ThreadSanitizer and independent-review evidence
are recorded separately; source preservation and generic compilation alone do not complete the stage.

The future camera app can provide a separate room flow through shared source files, as camera-app design D1 rules;
no package, framework, second target, room behavior or new entitlement is introduced here.

## Evidence and limits

Use a dedicated 1.9 simulator. Never modify the checkout during a test run. Retain red, green, undo, suite, lint,
ThreadSanitizer and independent-review evidence per stage. Device-only behavior (locked-device Data Protection,
camera, motion, speaker routing and live iCloud) is listed as owed until actually checked. Local files and private
branch commits make progress reviewable without changing the live release.
