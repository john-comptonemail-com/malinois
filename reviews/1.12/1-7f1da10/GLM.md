# Adversarial review — Malinois 1.12 (87) — GLM

Reviewed by: GLM (flash), 2026-11-10, per `_REVIEW_PROMPT.md` etiquette (prompt itself not read).
Review folder: (the review folder). All work happened in an agent-owned copy at
(a temporary folder) and on an agent-owned simulator
(`GLM-review-sim`, created and deleted by the agent; no pre-existing simulator touched).
Nothing was sent anywhere. The review folder was not modified except this report.

---

## Summary for the owner (plain English)

I spent this review trying to **break** the promises the App Store listing makes, by reading the
1.12 code specifically where those promises are enforced, and by writing my own attack tests
(14 of them) against the tricky seams, run on my own simulator. The headline guarantees I probed
**held up**:

- **"No way to delete a single entry, not even with your PIN"** — true in 1.12: there is no
  per-event delete anywhere in the interface, and the only whole-log deletion is the documented
  owner feature behind the PIN for a *damaged* log set aside by the app. Records leave the log
  only through the published size caps, and when they do, the phone signs a retention statement
  naming what went.
- **PIN-locked disarm, brute-force lockout**, **forced-restart recording on next open**, and
  **"evidence upload starts before the capture"** all check out in code and in the targeted
  tests I re-ran.

The review did surface three things worth your attention, none of them a broken promise but all
of them real behavior of 1.12 you should hear about, most serious first:

1. **Another device's event row on your phone can be frozen stale by a forged "revision" from
   iCloud.** If anything hostile can *write* into your iCloud (for example someone who has your
   Apple Account, not merely your iPhone passcode), it can push a copy of another phone's event
   that claims a higher revision while carrying less information — your other phones will then
   display that starved copy and refuse later honest updates for it. Your own phone's local
   evidence is not touched; the effect is on the mirrored rows in the Event Log on your other
   devices. Demonstrated in my test `testHostileHigherClaimedRevisionFreezesTheMirror`.
2. **After someone force-restarts your phone, they can make the log say "the app was ended"
   instead of "the device restarted"** — if they know the device passcode, can wait out
   ~15 minutes and then wind the clock back before opening Malinois. The interruption is still
   recorded either way (that promise keeps), but the record mislabels a restart as an ordinary
   app end. Demonstrated at the classifier level in
   `testRollbackAfterAForcedRestartCanReadAsTerminated`.
3. **The 100-entry status cap can retire a disarm record that was never yet uploaded** (by the
   published "oldest first" rule) when you accumulate 100+ arm/disarm/settings/interruption
   records while offline. The removal is signed and a quiet log line notes the batch once per
   watch, but the record itself is then gone with no iCloud copy. This is documented in
   SECURITY.md and consistent with the caps' wording ("recent status entries"), and I verified
   the order holds (`testStatusBudgetDiscardsOldestFirstHandAndSparesInFlight`).

Everything else I attacked — the fast-fact ordering versus captures, the journal write-ahead
durability, the merge rule protecting first-hand evidence, the byte cap's loss marking, the
download-side digest check, the lockout, the export bundle, the signers' absence statements —
resisted the probes. Details and the exact tests below.

---

## How this review worked

- **Guarantee source:** the App Store listing content (`_LIVE_APP_STORE.md`) plus the guarantee
  structure of README.md/SECURITY.md (the review-folder claims; the files themselves were read
  only for their claims list, per the review rules).
- **Static reading:** the parts of the core path not covered by earlier rounds' comments, with
  the focus on cross-subsystem seams: `CloudExfiltrator` (revision ladder, `mayWrite`, the fact
  push and the pending sweep's payload choice), `EventStore` (merge/supersedes, caps, journal,
  unlock reconciliation), `MonitoringEngine` (launch recovery, settings guard, retention,
  reinstall), `MonitoringCloudCoordinator` extensions (pending sweep, transfers/`mayFill`),
  `EventStore.countEvictionOrder`, `WatchAlertRelay`/`WatchLinkOutbox`, the notification
  extension (`AlertRewrite`), `BootStamp`, `EvidenceSignatureFile`.
- **Dynamic:** my own adversarial XCTest file (`GLMAdversarialTests`, 14 tests, code quoted
  below) against the pure rules, plus targeted re-runs of the neighbors' pinned tests: 
  `Item162UploadOrderTests`, `Item163RecordCapsTests`, `Item87CloudWipeTests`,
  `Item90EvidenceVerifierTests`, `KeychainServiceTests`, `Item106PINAutoSubmitTests`.
- **Integrity:** `_MANIFEST.sha256` verifies clean over the review folder (452/452 OK).
- **No secrets found** in Info.plist, entitlements, or any Swift file I read: the only network
  surface is the app's iCloud container (`iCloud.<bundle-id>`) and APNs; no keys, tokens or
  accounts in code. (`aps-environment` is `production` in Release entitlements, as expected.)
- **Simulator discipline:** built and tested only against `GLM-review-sim`
  (its ID taken out; created, used and deleted by this review), in the
  copy's own DerivedData path; `CODE_SIGNING_ALLOWED=NO`. Whole-suite runs were avoided;
  only `-only-testing:` subsets ran.

---

## Findings (most serious first)

### F1 — A hostile iCloud write can freeze a mirrored event row at starved content
**RESIDUAL (logic demonstrated in unit conditions; end-to-end CloudKit write not demonstrated).**

**The seam.** `EventStore.supersedes(incoming:existing:)` is the rule deciding whether a copy of
an event fetched from iCloud may replace the copy already held in the log. For *mirrored* rows it
specifically admits an incoming copy whose claimed revision (`cloudRevision`, an encrypted field
the capturing device itself wrote into the record) is **strictly higher** — the content behind it
is then trusted to be at least as rich. The equal-revision arms of the rule are fine-grained and
monotonic (counts may grow, a failure reason may appear, a thumbnail may arrive); it is only the
higher-revision arm that is unconditional.

**The attack.** Anyone able to write into the owner's **private** CloudKit database (the iCloud
account holder; a corrupted/older device; a rogue device added to that account) can publish, for
an event another phone already recorded, a copy that claims revision N+1 while dropping the
fields that make it informative (thumbnail, failure reason, counts). The receiving phones accept
it; thereafter every honest copy of the same revision is refused and the mirror never repairs —
in my demonstration the forged revision 9 row stayed while a later revision-3 copy with a bigger
count and a thumbnail was refused:

```swift
// GLMAdversarialTests — the accepted copy and the frozen-after state
var real = mirror(withPrimary(sampleEvent(), thumbnail: true))
real.cloudRevision = 3
real.sustainedCount = 5
let forged = mirror(attributed(sampleEvent(id: real.id)), revision: 9)   // thinner, higher claim
XCTAssertTrue(EventStore.supersedes(incoming: forged, existing: real))
var honest = mirror(withPrimary(sampleEvent(id: real.id), thumbnail: true))
honest.cloudRevision = 3
honest.sustainedCount = 6
let merged = EventStore.merged(local: [forged], incoming: [honest])
XCTAssertEqual(merged.first!.cloudRevision, 9)   // the honest update can no longer land
```

**Why this is not a broken promise.** It is out of the listing's threat model ("someone who
knows your **iPhone passcode**"): writing to the private database requires the Apple Account
itself, and the first-hand copy on the capturing phone is untouched (I verified separately that
*a mirror can never replace a first-hand row, at any revision*: `testFirstHandRowIsNeverReplacedByAnyMirror`,
and that equal-revision replays need one of the genuinely monotonic growths:
`testEqualRevisionMirrorWithoutGrowthIsRefused`). The damage is a stale, thinner **display copy**
on the other phones for that one event. The signed evidence chain (the export, the absence
statements, the retention statements) signs *this device's* records and is not fed by the forged
row.

**Suggested hardening.** Bound the trust: when an incoming copy's claimed revision rises over the
held copy's while its informative content (thumbnail/counts/reasons) goes *backwards*, treat it
like the equal-revision case (refuse the shrink, or fold per-field maxima as the count arms
already do). Small change along the existing `supersedes` structure.

### F2 — A post-restart clock rollback can downgrade "the device restarted" to "the app ended"
**VERIFIED at the classifier level (pure logic, exact stamps); end-to-end restart not staged on hardware.**

**The seam.** `BootStamp.classify` distinguishes a device restart from an app kill with two
checks, each with a 30-second tolerance: the kernel boot time must jump forward, or the arming
stamp's uptime must exceed the new session's uptime.

**The attack.** Both checks assume the attacker cannot control the clock. A person with the
**device passcode** (the listing's named actor) can, *after* the forced restart (when Guided
Access is gone and Malinois is not yet open):

1. wait until the new session's uptime reaches the armed session's (so the uptime delta stays
   inside the tolerance) — the same phone beeps nothing meanwhile since nothing is watching; and
2. set the displayed clock back; iOS moves `kern.boottime` by the same amount (this device
   behavior is what `CloudExfiltrator`/`BootStamp`'s own comments lean on), pulling the reported
   boot time back near the armed stamp's.

Both deltas then read as drift and the classifier answers `.terminated`:

```swift
// GLMAdversarialTests — armed at boot 0, stamp at 900 s uptimed; attacker restarted (true boot
// 1060), waited ≥870 s, then set the displayed clock so kern.boottime reports 20.
let armed       = BootStamp(bootTime: 0,   takenAt: 900)
let manipulated = BootStamp(bootTime: 20,  takenAt: 930)
XCTAssertEqual(BootStamp.classify(armed: armed, current: manipulated), .terminated)
```

**What does not break.** The record is still written on next open either way —
`recoverInterruptedSessionIfNeeded` classifies and then **always** logs the interruption for
marker-present launches (`shouldLogRelaunchInterruption` returns true for an unlogged lapse even
when the cause is `.terminated`), and the automatic re-arm still runs, so "a forced restart ... is
recorded when Malinois next opens" holds. The mislabel only matters because "interrupted: the app
ended" reads less alarming than "interrupted: **restart**" in the log ("sensorSummary") and to a
cross-device reader — exactly the distinction the stamp exists to make. Practical cost for the
attacker: they need the device passcode, roughly the armed session's length of patience, and a
clock change of more than 30 s. Guided Access (required to arm by default) blocks both the
Guided-Access-exit and clock change *while armed* — the gap is the post-restart window.

**Suggested hardening.** Also compare the boot stamps' *pair* against a server-signed anchor if
Pro is on (e.g. piggyback the stamp on the heartbeat, so a later device can surface "boot time
moved backwards"), or record `.terminated`-vs-`.rebooted` only when the drift direction is
consistent; at minimum a SECURITY.md paragraph should state the rollback precondition.

### F3 — The status cap can retire a not-yet-uploaded disarm record (documented, verified as published)
**VERIFIED (behavior as documented in SECURITY.md; not a hidden loss path).**

`countEvictionOrder`'s status pool discards, after mirror copies, the **oldest first-hand** status
entries without regard to whether they have uploaded, and protects only the newest first-hand row
(each pool) and any row whose upload is running (nothing newer taken in its place: I verified
both). At the 100-entry cap an old disarm record that never reached iCloud leaves the log; the
event log then gets one quiet `unsyncedRemoved` line per watch (per day while disarmed), and the
signer writes a **retention statement** naming the retired signatures — so the removal is
accounted for, but the audit row itself is gone where no cloud copy exists. This matches
SECURITY.md's "Status entries discard the oldest first-hand entries after copies" and the listing
term "recent status entries". I verified the exact ordering:

```swift
// GLMAdversarialTests — 5 status rows, cap 3, one in-flight: the oldest unsynced row goes,
// the in-flight row and everything newer of it stays.
XCTAssertEqual(EventStore.countEvictionOrder(events: rows([
    (newest,    audit: true), (inFlight, audit: true, inFlight: true), (spare, audit: true),
    (target,    audit: true), (oldest,   audit: true),
]), incidentCap: 1000, auditCap: 3), [oldest])
```

No action needed unless you want the once-per-watch marker to name *how many* and *which* records
went (SECURITY.md explicitly says it does not — that wording is your ruling, so this is a
reminder rather than a defect).

### F4 — The revision ladder's documented equal-revision window is narrow and double-gated
**VERIFIED (as the source itself describes; no loss found).**

`metaRevision(for:)` derives the revision from the record's own content; `mayWrite` refuses a
strictly older write but allows equal ones "as an ordinary retry of the same payload". Two
things keep an equal-revision retry from clobbering richer content:

- **In-process:** every push for an event runs through the per-event `enqueue` chain, and each
  push re-reads the log's copy at its turn (`storedEvent(event.id) ?? event`), so a queued sparse
  fact pushes the *current* (richer) content, never a stale snapshot;
- **Across processes:** the in-memory `submittedMetaRevisions` gate dies with the process, but a
  relaunch-time retry rebuilds its payloads from the log's current copies (the pending sweep
  re-reads `eventStore.events` at pass time), which carry the richer content, so the derived
  revision is the rich one.

I verified the ladder never *decreases* across the content states one capture passes through
(fact → thumbnail staged → file stored → attribution → byte-cap eviction mark → secondary camera
late evidence): `testMetaRevisionNeverDecreasesAcrossOneCapturesProgression`. For a camera-off
event the record sits at revision 1 until attribution lifts it to 2
(`testCameraOffEventStaysAtRevisionOneUntilAttribution`); there is no richer capture content in
that case, so the documented equal-revision window has no differing payload to overwrite.

Residual worth knowing: the gate is content-derived, so it is sound as long as the *log's* copy is
the richest state known. The one place a staler copy can exist in-hand is an event the push chain
holds while the count cap evicts it from the log (`storedEvent` falls back to the in-hand copy) —
in-process, `submittedMetaRevisions` still refuses the older write; across restarts an evicted
event is not in the sweep's candidates at all. Probed, no break found.

### F5 — Targeted re-runs of neighbors' pins (all green)
Ran on my own simulator, tiny subsets only: `Item162UploadOrderTests` (3/3), `Item163RecordCapsTests`
(16/16), `Item87CloudWipeTests` (14/14), `Item90EvidenceVerifierTests` (20/20), `KeychainServiceTests`
+ `Item106PINAutoSubmitTests` (passed; earlier in this review). Combined with my 14 adversarial
tests. No failures.

---

## Guarantees re-verified to hold (with the probes)

| Guarantee (App Store wording) | What I probed | Result |
|---|---|---|
| "no way to delete a single entry, not even with your PIN" | UI surfaces (Event Log, event detail, set-aside log screen — prior reading); count caps and their signed statements | Holds; removals only by published caps, each removal signed (retention/absence statements) |
| "a forced restart ... is recorded when Malinois next opens" | `recoverInterruptedSessionIfNeeded` ordering: marker retained until record + owed re-arm installed; marker present even for background launches; crash-loop guard still records | Holds (see F2 for the wording nuance after clock rollback) |
| armed duration/timestamp on every session; gaps visible | `logStateChange` records, heartbeat session anchoring, `BeatSessionRegistry` | Holds |
| "event upload starts before photo capture" (`pushFactIfCloud` step 1a) | Fact pushed under the same lease as the trip's push, one bounded retry, per-event queue ordering re-checked | Holds |
| Pen-signed evidence verifiable on the Mac | `Item90EvidenceVerifierTests` (20/20) re-run; export/signature chain read; keys listed from certified statements only | Holds (sim can't exercise the real App Attest; recorded as a limit) |
| "PRIVATE BY DESIGN" (no account/hosting/analytics) | Grepped Info.plist, entitlements, all Swift for URLs/keys | Holds; only the iCloud container string and APNs |
| Count caps retire oldest; 500 incidents / 100 status | Constants (`maxIncidentEvents` 500, `maxAuditEvents` 100) and `countEvictionOrder` class order; F3's test; Item163's 16 tests | Holds as published |

Selected adversarial probes that were **refused by the code** (each pinned by one of my tests):
mirror copying over first-hand evidence (any revision) — refused; equal-revision mirror without a
monotonic growth — refused; a torn journal tail breaking the log decoder — skipped, never fatal;
the newest first-hand row of each budget evicted by its own overflow (even at a zero cap) —
never taken; an in-flight row taken with a newer row in its place — never.

---

## What was not demonstrated (limits)

- Real App Attest (hardware-bound key, Apple's production chain) and CloudKit record
  transport cannot run in a Simulator; I exercised their *pure decision logic* and re-ran the
  pinned tests that use the DEBUG stand-ins.
- F1 and F2 are demonstrated at the decision layer. Staging the end-to-end attack (an actual
  CloudKit private-DB write; an actual post-restart clock change on hardware) was out of scope
  for a simulator-only review and would need devices and an account; both attacks' preconditions
  are spelled out above.
- The Watch app, CameraController capture mechanics and the export ZIP format were read but not
  dynamically probed (they have their own pinned test classes; area for a hardware round).

---

## Reproduction

All commands ran from the copy (a temporary folder):

```
xcodebuild build-for-testing -project Malinois.xcodeproj -scheme Malinois \
  -destination 'platform=iOS Simulator,id=(the simulator's ID)' \
  -derivedDataPath (a temporary folder) CODE_SIGNING_ALLOWED=NO -quiet

xcodebuild test-without-building ... -only-testing:MalinoisTests/GLMAdversarialTests \
  -only-testing:MalinoisTests/Item162UploadOrderTests -only-testing:MalinoisTests/Item163RecordCapsTests \
  -only-testing:MalinoisTests/Item87CloudWipeTests -only-testing:MalinoisTests/Item90EvidenceVerifierTests
```

The adversarial test file is `MalinoisTests/GLMAdversarialTests.swift` in that copy
(14 tests, all passing in ~0.02 s; pure code, no network, no CloudKit). The key test bodies are
quoted inline in F1, F2, F3 and F4 above so the findings stand on their own even if the temp
copy is gone. The copy also carries the one-line project registration that adds the file to the
test target's Sources phase.

No pre-existing simulator was booted, stopped or deleted by this review; `GLM-review-sim`
was created for it and deleted after testing.
