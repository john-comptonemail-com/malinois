# Malinois 1.13 (89): independent open review

**Reviewer:** GPT-6 Astra / Codex  
**Date:** 2026-11-15  
**Snapshot:** (the review folder), supplied as commit `1aadc3c`; no Git commands used.  
**Tests run:** None. No app build, simulator, Watch, target executable, fixture-processing test, or provider request was run. All four VERIFIED findings below are verified by source inspection under the prompt's definition. Proposed probes are explicitly **UNRUN**, not claimed test results. The supplied release-gate results were treated as background, not independently reproduced.

This is a cold-start, standard-profile, risk-led review of the full supplied application and evidence system, with deeper work on authentication, durable evidence, account boundaries, exports, and alert recovery. I read `_REVIEW_PROMPT_OPEN.md` first. I did not read `_REVIEW_PROMPT.md`, other reviewers' reports or notes, earlier review folders, or prior-run findings. No strict agent budget was set. Runtime, physical-device, archive, and service limitations are stated below; this is not an exhaustive safety certification.

## 1. For the owner

**I would hold this candidate from App Store submission for four targeted changes.** I found no proven way past the PIN, no default-verifier forgery, and no evidence reaching another account in the paths examined. The remaining problems concern promises about recovery, a share disappearing while it is being used, and a Watch alert that is not retried after the owner repairs its permission.

1. **A deletion can lose its promised receipt.** Suppose you delete a set-aside log with your PIN. Malinois successfully saves the small note meant to guarantee a later deletion record. If subsequent writes of that record fail, it can still erase the note. Close the app before any later save succeeds, and the next launch has neither the deletion record nor the note needed to recreate it. Keep the note until the record is safely stored. **Fix before submission.** Storage warnings can appear; this is not a PIN bypass or a claim that every failure is invisible.
2. **Restarting does not retry every failed clip save that the documentation promises to retry.** A finished recording can be moved out of the camera's waiting folder, then fail to finish publication. Restart checks its old location and the final location, but does not recover the intermediate file. The event normally says the save failed. **Correct the recovery promise before submission.** Improving recovery of those intermediate bytes is a separate, worthwhile design change that can follow later if the limitation is stated accurately.
3. **Startup cleanup can remove a ZIP you have just asked to share.** Cleanup runs in the background. If you get to Share before it checks for old exports, your new export looks exactly like one it should delete. The original log and photos remain, so you can retry. Restrict cleanup to exports known to predate this launch. **Fix before submission.** I have not measured how often this timing occurs.
4. **Fixing Watch notification permission and opening the app can leave an old alert waiting.** If an alert was refused, its handling finished, and the Watch app remains resident, reopening it refreshes permission but does not retry the saved alert. A later launch, link wake, or repeat message can rescue it; an independent iCloud alert may also arrive. Retry waiting alerts after foreground permission becomes allowed. **Fix before submission.**
5. **One Watch summary timing question still needs a device check.** A backlog starts with an audible summary request and immediately updates the same notification silently. I cannot establish whether watchOS can replace that first request before it presents. This is **SUSPECTED**, not an observed missed tap. **Validate later; it is not a submission blocker on the evidence available.**

The two High ratings use your explicit rule that a false published claim is High. Their underlying storage-failure scenarios are uncommon and would be Medium reliability problems by themselves. I found no basis to call these Critical or to predict a near-certain App Review rejection. Correcting public claims is nevertheless a release requirement: Apple expects metadata to describe the app accurately. [App Review Guideline 2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata)

## 2. Findings

| ID | Severity / certainty | Affected promise or resource | Source-established result |
| --- | --- | --- | --- |
| gpt6-astra-1 | **High — VERIFIED** | Record of an authorized set-aside-log deletion | Saved recovery note can be retired before the deletion record is durable. |
| gpt6-astra-2 | **High — VERIFIED** | Published clip-save retry guarantee | A post-intent failure can leave only intermediate bytes that launch does not retry. |
| gpt6-astra-3 | **Medium — VERIFIED** | Current owner's derived export | Delayed startup sweep can remove the current share's ZIP. |
| gpt6-astra-4 | **Medium — VERIFIED** | Retry of a saved Watch alert | Resident foreground transition submits no retry after a completed refusal. |

“VERIFIED” establishes the conditional behavior from the complete source path. It does not mean that a fault was injected or an on-device occurrence observed. Actual incidence, physical persistence behavior, and native notification presentation remain untested. The separate timing lead follows the confirmed findings.

### gpt6-astra-1 — Retiring the deletion note does not wait for durable recording

**High — VERIFIED by source. Fix before submission.**

**Concrete situation.** The PIN-holder deletes one set-aside log. The note file is successfully written and the old log is removed. The deletion record's journal append leaves no valid recoverable line, and every full-log snapshot containing that record fails before the process ends. Removing the small note file succeeds. The app then ends. On the next launch there is no deletion record and no remaining note from which to reconstruct one.

Use backup off for the minimal case, a readable current log, and no retention pressure. This is deliberately stronger than “one write failed”: **any later successful snapshot can rescue the record**, including the snapshot caused by recording its local-only cloud state. That snapshot must also fail or remain unfinished when the process ends. An uploaded copy is another possible rescue; none is assumed in this scenario. The combination's frequency on real storage is unknown.

**Evidence and preventing controls.**

- SetAsideLogView.swift:94–107 requires confirmation and the PIN. This is an audit-reliability defect after authorized deletion.
- MonitoringEngine+AuditRecords.swift:40–47 writes the note, awaits deletion, calls `logStateChange`, then retires the note without a durability result.
- MonitoringEngine.swift:797 sends the status event through `EventStore.add`. EventStore.swift:311 does not return journal success to this caller; the journal failure path at 1742 reports trouble but allows progress. Snapshot failure at 2946 is caught rather than acknowledged as a failed birth to the retirement caller.
- EventStore.swift:3365–3380 removes the owed ID and, for the last note, unlinks its file. Replay at 3421–3422 makes the same log-call-then-retire assumption. Launch handover at 3397–3406 can only recover notes still present.
- MonitoringCloudCoordinator+Transfers.swift:141 and EventStore.swift:2048–2057 create the additional snapshot opportunity even with backup off. HomeView.swift:556 and 587 surface storage/journal trouble. I therefore do not claim a universally silent failure.

**Why it matters.** The mechanism discards a successfully saved obligation before fulfilling it. That contradicts the stated exception boundary, which permits loss when the initial note cannot be written. This finding starts **after that note has succeeded**. The original deletion was authorized; the lost resource is its promised audit trail, not an unauthorized deletion capability.

**Smallest fix.** Retire the matching owed ID only after its audit entry is acknowledged durable: a successful journal write and sync, or a later successfully written and synced snapshot containing it. Apply the same rule to live deletion and launch replay, retaining the ID to prevent duplicate entries. Do not assume a callback named `onDurableWrite` already provides the needed sync contract; its current position follows the metadata write before the journal checkpoint's full sync. Preserve the agreed behavior when the initial note itself cannot be written.

**Probe.** Probe A below exercises both live deletion and replay with actual append failure and persistent snapshot failure. A full-sync-only failure after complete bytes have already reached the journal is not sufficient to prove this scenario. No such probe was run.

### gpt6-astra-2 — The launch-retry sentence promises more than the implementation

**High — VERIFIED by source. Correct the documentation before submission; improved staging recovery can be later.**

**Concrete situation.** A first-hand event has an empty eligible camera slot and a completed, nonempty clip in `PendingCameraEvidence`. The attachment intent is saved. Moving the clip into attachment staging succeeds, consuming the original filename. Rewriting the intent or moving the staged file into its final location then fails. The storage call returns failure. Restart with healthy storage: the original file is gone, the final file was never published, and neither recovery path uses the complete staged file. It remains unattached and can be removed by a clean checkpoint after the 30-day expiry.

**Evidence and preventing controls.**

- CameraController.swift:1499 handles the final movie callback; MonitoringTripResponder+Responses.swift:128 stores the result. This can concern a finished recording, not merely a movie interrupted before finalization.
- EventStore.swift:2556 saves the initial intent. 2570–2587 flushes and protects the original, moves it into `.pending`, then performs fallible manifest replacement and final publication. The catch returns `nil` with no move back.
- Launch retry at 2645 requires the original source to exist. Final-file recovery at 2669 requires the published file. Cleanup at 2738–2746 permits expiry of nonrecoverable staging.
- EventStore.swift:2822 supplies the existing `killBeforeReplacingForTesting` seam for a bounded replacement-failure probe. The ordinary throwing write/rename checks immediately after it are real failure paths, independent of the debug seam.
- MonitoringTripResponder+Responses.swift:602–608 records a storage-failure reason; the caller also raises a camera notice. The event survives. This is not proof of silently losing an already committed attachment.
- The accepted **ADR 0037** makes final publication the commit point. EventTests.swift:279 deliberately keeps uncommitted staging unattached. Item152LockedSaveTests.swift:148 tests a different refusal, before the move consumes the source. These are meaningful controls and tests, but they do not make the broader retry sentence true.

**Why it matters.** SECURITY.md:1133–1135 promises retry whenever save is refused after the intent is written. A returned error after the move is a counterexample. The accepted commit-point design itself is not being relabeled a bug. My separate design judgment is that retaining a finished source until publication would avoid losing access to usable footage; it must preserve the existing defenses against partial, ambiguous, incorrectly owned, or already-filled attachments.

**Smallest fix.** Narrow the published promise to failures that leave the original in `PendingCameraEvidence`, and explain that intermediate `.pending` files are not automatically attached or retried. Wording is supplied below. If changing recovery later, retain the original until publication succeeds or introduce an explicit, validated staging-retry state. Do not attach every `.pending` file indiscriminately.

**Probe.** Probe B below uses the existing replacement-failure seam. The runtime result and real-device incidence remain untested; the mismatch between the promise and the source is verified.

### gpt6-astra-3 — Background startup cleanup can remove an active export

**Medium — VERIFIED by source. Fix before submission.**

**Concrete ordering.** Launch schedules its background sweep. The owner unlocks the Event Log and shares a readable set-aside log, or a signed event eligible for export. A new `MalinoisExport-<UUID>` folder and its ZIP finish creation. The delayed sweep now enumerates the temporary directory, recognizes the new folder as an export, and removes it before the share consumer opens the returned URL. Share has a URL to a file that no longer exists.

**Evidence.** MalinoisApp.swift:78–84 launches cleanup in an unawaited background task; 121–123 returns usable services independently. EvidenceExporter.swift:193–202 enumerates at execution time and deletes every folder matching the common prefix and canonical UUID. It has no session or ownership check. The signed exporter uses that exact naming rule at 44–54; the set-aside exporter uses it at SetAsideLog.swift:421–431. The latter is reached from SetAsideLogView.swift:133–150. Per-share ownership in EvidenceBundleItem.swift:206–218 does not coordinate with this global sweep.

**Impact and limits.** The derived ZIP can disappear or share preparation can fail. The original log and media are untouched, so another share can succeed. I do not claim that a recipient actually received an incomplete message, or that ordinary startup often loses this race. The source establishes a permitted ordering and its result, not its frequency.

**Smallest fix.** Capture the exact abandoned-export folder names synchronously at startup, before any current export can be created, and give only that set to the background deletion task. Alternatively separate exports by process/session and sweep only ended sessions. Keep normal cleanup under the current share's owner. A delay or age threshold alone does not establish ownership.

**Probe.** Probe C gives a small proposed regression test of the real cleanup helper, plus the constructor-level follow-up. It is uncompiled and unrun.

### gpt6-astra-4 — Resident Watch foregrounding does not retry a completed refusal

**Medium — VERIFIED by source. Fix before submission.**

**Concrete situation.** The paired iPhone hands the Watch a valid alert. The Watch saves it as owed, but notification submission fails while authorization is unavailable. That handling task completes; the saved entry has one refusal and remains below the three-refusal limit. The owner restores authorization and opens the still-resident Watch app. No process launch, new link wake, repeat message, or independent iCloud copy occurs. Opening the app refreshes permission but never tries this saved alert again.

**Evidence and alternate recovery paths.**

- WatchAppDelegate.swift:278 receives the queued payload and records it before handling. WatchRelayInbox.swift:194–199 retains a failed post for retry until its refusal limit.
- WatchAppDelegate.swift:159–166 reconciles delivered copies, refreshes the displayed last alert, refreshes permission, and checks cloud status. None of those steps drains the owed list. 220–223 only updates permission state.
- Launch at 85 and a link background wake at 120 do hand over owed alerts. A repeated message can retry its own event. These are real safeguards; the finding explicitly excludes them during the affected transition.
- Apple defines a notification-submission error for unavailable authorization. This supports a recoverable refusal condition; it does not establish a particular device's later presentation. [UNError.notificationsNotAllowed](https://developer.apple.com/documentation/usernotifications/unerror/notificationsnotallowed)

**Impact and limits.** This establishes the absence of a retry attempt, not that watchOS would necessarily display a successful retry. A suspended unfinished task may resume normally, so the scenario requires the first failed task to have **finished**. An independent iCloud copy can still alert the owner. Evidence on the phone remains intact. The accepted capacity and three-refusal limits are not findings.

**Smallest fix.** Once the foreground permission refresh reports allowed, invoke `handOwedAlerts`, before cloud checks. Keep the inbox's in-hand deduplication and serialized handling; do not spend another refusal on every refresh while authorization is denied.

**Probe.** Probe D retains the same delegate/inbox through failed post, restored authorization, and foreground transition. Existing later-wake retry coverage does not substitute for that callback-level regression. No Watch runtime was exercised.

### NEEDS VALIDATION: gpt6-astra-5 — Could a silent summary update replace its first audible request?

**SUSPECTED — provisional Medium if confirmed. Later validation; not a proven release blocker.** This is a risk-priority label requested by the review prompt, not a confirmed severity.

| Source-grounded possibility | Decisive missing fact | Bounded next step |
| --- | --- | --- |
| Two distinct relayed alerts more than one hour old start a summary and immediately update its same notification identifier. Count 1 asks for sound and active interruption; count 2 is passive and silent. | Can a native watchOS nil-trigger request still be pending after its awaited `add` returns, through the intervening commits/list read, so the second request replaces it before presentation? | Compare one old alert with a two-alert backlog on an isolated owner-controlled test Watch; observe native ordering as specified in Probe E. A simulated pending queue can show only the conditional consequence. |

**Trace.** WatchRelayInbox.swift:109–122 drains saved messages serially. 163–205 joins old alerts into the summary, awaits posting, and commits the count only after success. The actual post awaits `UNUserNotificationCenter.add` at WatchAppDelegate.swift:69. WatchRelayInbox.swift:353–360 keeps the identifier when growing a current summary; 382–392 changes later requests to passive/no sound. Both use `trigger: nil`.

**Why this remains suspected.** Awaiting each add and requesting immediate delivery are strong safeguards. Apple's scheduling and identifier contracts do not resolve the exact pending-to-delivered ordering here. Same-identifier pending replacement is documented, but source does not prove that the necessary pending interval exists for these immediate requests. The delivered-list read is for pairing iCloud copies, not an acknowledgement that the summary was presented, and its shared budget can be exhausted at 228. [Scheduling local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app), [request identifiers](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier)

Item134WatchSummaryTests.swift:256–274 verifies requested content and presentation options, not native presentation. SECURITY.md:1524–1526 already reserves actual taps and sounds to watchOS and settings. I am therefore **not** reporting a proven false unconditional delivery promise or a demonstrated missed tap.

**Conditional fix if confirmed.** Avoid downgrading the first still-pending active request to a passive update: coalesce the initial backlog into one active summary or explicitly preserve that first request until native delivery is established. The repair needs its own lifecycle tests; it is not justified to make every update audible on speculation.

### Proposed probes — all UNRUN

These are tests I would add only to a disposable source copy in an isolated environment. A and D require additional narrow fault/delegate seams. B has an existing seam. The plans below state exact arrange/act/assert conditions; they are not test-run transcripts. Device incidence and native effects they would settle remain **SUSPECTED/untested**, even where the conditional source behavior above is VERIFIED.

**A. `testDeleteNoteSurvivesFailedAuditPersistence` and replay variant.** Use the existing deletion-owed fixtures with one tiny dummy log, readable current metadata, an established journal, no media, backup off, and no retention pressure. Allow the initial note write to succeed. Then force the audit append to leave no valid line and force **all** snapshots containing its ID to fail; allow unlink operations. Invoke the engine's real deletion, wait for its cloud-state/local-only follow-up and drain I/O under the same faults. Assert that the log was removed and the record is only in memory. Dispose of the store without a healthy save, then recreate it over the same fixture with healthy storage. Current source predicts the note and record are both absent. The fixed regression should instead require the note to survive failed persistence, recover one record under its original ID, and retire only after a successful durable write. Repeat starting with a valid note from an interrupted earlier deletion. Include a control where a later successful snapshot rescues the record.

**B. `testPostMoveManifestFailureDoesNotLoseRetryability`.** In a scratch-only store, create a valid first-hand event and a finalized dummy movie with the correct UUID filename in the overridden pending folder. Set `EventStore.killBeforeReplacingForTesting = true`; restore it with `defer`. The new initial intent is allowed because its destination does not exist; replacement after moving the clip fails. Assert a nil storage result, an initial intent, absent original, intact staged bytes, and absent published file. Clear the seam, recreate the store, drain launch recovery, and inspect the event. Current source predicts no attachment. If only the documentation changes, keep this as a documented limitation test; if recovery changes, require successful validated retry. Separately test expiry after 30 days and a clean checkpoint. Retain negative cases for partial files, links, conflicting intents, wrong identity, and an occupied slot. A responder-level test should check the visible storage-failure reason.

**C. `testDelayedStartupSweepKeepsCurrentExport`.** Proposed Swift test of the deletion predicate, **not compiled or run**. Configure the test process's temporary directory to its own sandbox scratch. The `.zip` contents below are a harmless sentinel because cleanup never parses the archive. Calling the helper after creating the current folder models the delayed enumeration; it does not measure startup scheduling frequency.

```swift
import Foundation
import XCTest
@testable import Malinois

final class ReviewExportCleanupTests: XCTestCase {
    func testDelayedStartupSweepKeepsCurrentExport() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ReviewExport-" + UUID().uuidString,
                                    isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = root.appendingPathComponent("source-log.json")
        let sourceBytes = Data("[]".utf8)
        try sourceBytes.write(to: source)

        let old = root.appendingPathComponent(
            EvidenceExporter.folderPrefix + UUID().uuidString,
            isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)

        // Startup has scheduled cleanup but not yet enumerated this root.
        let current = root.appendingPathComponent(
            EvidenceExporter.folderPrefix + UUID().uuidString,
            isDirectory: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        let zip = current.appendingPathComponent("current.zip")
        try Data("current export sentinel".utf8).write(to: zip)

        EvidenceExporter.removeLeftovers(in: root)

        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: zip.path),
                      "Startup cleanup must not delete the current share")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
}
```

The current implementation is expected to fail the `zip` assertion. For the fix, capture the old candidate set before creating `current`, then run deletion using that captured set. Add constructor-level variants that return a real set-aside ZIP and a locally signed evidence ZIP; hold the startup sweep until creation finishes, then verify each returned URL remains readable. Use a fake local signer for the latter, with no App Attest or other provider calls and no external share destination.

**D. `testResidentForegroundRetriesCompletedPermissionRefusal`.** Create one delegate/inbox with a private defaults suite and injected notification/cloud interfaces. Deliver a recent valid `WatchAlertMessage` using dummy ID `00000000-0000-4000-8000-000000000219`. Make its first `add` throw `UNError.notificationsNotAllowed`; await completion and require one refusal, an owed entry, and no shown/summed entry. Change authorization to granted and future adds to success. Invoke only `applicationDidBecomeActive` on the **same** delegate. Current source predicts the add count remains one. The fixed test should require exactly one retry and removal from owed only after success. Test a repeated foreground while the retry is in hand, denied permission, a genuinely suspended first post, launch recovery, link-wake recovery, and duplicate delivery separately. Keep the existing refusal/capacity policy unchanged.

**E. `observeFirstSummaryDeliveryBeforePassiveReplacement`.** On an isolated owner-controlled Watch, with notification permission and haptics enabled and Focus effects controlled, establish a one-old-alert baseline. Then drain two distinct dummy alerts older than one hour with no pre-existing summary or independent iCloud copies. Record monotonic add start/completion times, identifiers, interruption levels, delegate presentation callbacks where available, and native pending/delivered snapshots alongside screen/haptic observation. Exercise both foreground and background, and separately a controlled delivered-list callback timeout using the existing two-second budget. Do not artificially stall native notification delivery. Confirmation requires evidence that the first active request remained pending after add completion, was replaced before presentation, and lost its first alert relative to the matched control. Merely seeing the final passive content, not feeling a tap, or finding no entry in the delivered list is insufficient. If native ordering or an authoritative platform guarantee rules this interval out, reject the candidate.

## 3. Wrong claims in the documents

These are two documentation problems corresponding to findings 1 and 2, not extra findings. The public README's planned 1.13 edits change first-run wording and “armed session”; they do not amend the deletion invariant below.

### Deletion is promised a surviving status entry

**Where and claim.** _PUBLIC_README.md:161: “An event log Malinois had to set aside can be deleted whole, with the PIN, and that leaves a status entry.” SECURITY.md:1880–1885 says “A Delete leaves a status entry” and describes next-launch recovery, except when storage cannot hold the initial note. ADR 0083:34–36 is explicit: “A Delete leaves its entry whatever stops Malinois, at once or at the next launch, if its note could be written.”

**Why wrong.** A successfully saved note is currently retired after an attempted write, even if no recoverable journal entry or snapshot survives. The accepted initial-note-write exception does not cover that later failure.

**Accurate wording for current behavior, if code remains unchanged:**

> Deleting a set-aside log requires the PIN. Malinois attempts to record the deletion and first saves a recovery note. If storage cannot save the note, deletion can leave no record after the app stops. A record can also be lost if the note is saved but later audit writes fail and the app stops after retiring the note, before any successful save.

That is an undesirable guarantee for this feature; I recommend repairing the acknowledgement before release. **After the fix is tested**, use:

> Deleting a set-aside log requires the PIN and leaves a status entry. Malinois saves a recovery note first and keeps it until that entry is safely stored, so a later launch can finish recording the deletion. If storage cannot save the initial note, deletion still proceeds and an interruption may leave no entry.

### All post-intent clip refusals are promised a next-launch retry

**Where and claim.** SECURITY.md:1133–1135: “a clip's save is refused after the store has written its intent … the save is tried again the next time the app starts”.

**Why wrong.** The original-to-staging move can succeed before a later storage error. Recovery then finds neither the required original nor a published final file. ADR 0037's deliberate commit boundary does not make this broader sentence accurate.

**Replacement:**

> If the store has saved an attachment intent and the original clip still remains in PendingCameraEvidence, Malinois tries the save again at the next launch. If the original has already moved into attachment staging and final publication fails, the clip is not automatically retried or attached. Such uncommitted staging can be removed after 30 days by a successful clean checkpoint. A clip refused before an intent is saved is not automatically attached later.

I did not retain the proposed Guided Access listing objection: the full passage already discloses forced restart ending monitoring and describes detection rather than a lock. I also did not call the summary's tap wording a proven false claim; the surrounding notification caveat matters.

## 4. Where I went, what held up, and what remains unknown

**Method and depth.** The initial hypotheses concerned sealed-state authentication, pre-PIN Test sensors crossing into real monitoring, stale authorization after suspension, evidence commitments and deletion recovery, account changes during asynchronous transfers, edited export bundles, silent alert failure, and cleanup ownership. Independent source passes followed those boundaries; follow-up work specifically traced set-aside sharing and blackout/reconnect behavior. Candidate review discarded one documentary objection and retained four confirmed findings plus one native-ordering lead. Separate fresh reviewers checked each retained final record. The final coverage critic found no additional unassigned source-review unit within the declared plan; that is a workflow result, not a claim that the app has no other defects.

**Controls that looked sound in the paths examined:**

- **Authentication and lifecycle:** unreadable/sealed PIN storage is distinguished from absence and fails closed; setup/recovery does not simply turn a read failure into a fresh PIN. PIN-entry rate limiting is shared, live disarm stays PIN-controlled, biometric access is bound to the enrollment/request, and protected navigation is revoked on backgrounding. Crash recovery, Test sensors, and calibration paths have state/generation guards. I found no reachable no-PIN disarm in these paths.
- **Cloud identity and delayed work:** event birth ownership and current account/generation leases are checked across upload, pull, staging, download, and attachment. Identity changes invalidate work rather than relabeling old records. Stale completions are checked; cloud mirrors cannot freely overwrite first-hand records. I found no source-proven wrong-account transfer through these paths.
- **Evidence and the Mac verifier:** the default trust path pins Apple's root and checks app/key/nonce binding; canonical record bytes, attachments, counters, key lineage, signed export closure, and inventory are checked. ZIP path/link/header checks and explicit limitations constrain the interpretation of an export. I found no demonstrated default-path edited-bundle forgery. Choosing a custom `--root` is an explicit trust-anchor override, not proof that the default verifier trusts arbitrary roots.
- **Retention and sharing:** failed metadata persistence defers destructive media cleanup; current, set-aside, and pending references participate in exclusion. Set-aside Share checks current and in-flight attachment names. I did not establish disclosure of current evidence through that older-log share path. The active-export cleanup race in finding 3 is a different boundary.
- **Capture, alarms, and relaying:** capture results retain their original event/generation; late or refused camera work has bounded handling; alarm audio release and activation retries have limits and notices. Watch payloads are typed event metadata, not remote arming commands, and queued relay handling is serialized with duplicate suppression. These controls do not resolve the specific recovery gaps above.

**Design judgments kept separate from defects.** Final publication as the media commitment point is deliberate, as is pruning the never-uploaded Vision reference with an eligible event's other local media. A different policy could preserve more uniquely local evidence, but this review did not count those accepted policies as implementation defects. Reconnect standing down the blackout warning is documented; I did not invent a separate warning-deadline guarantee. The Watch's bounded owed list and refusal limit are also accepted behavior. The open prompt's already-planned later fixes were not recycled as new findings.

**A testing blind spot.** The read tests meaningfully cover happy paths and several failure paths, but some assertions stop one boundary short of the user promise: creation of notification content is not observation of a tap; putting an entry in memory is not retaining it across failed persistence; retry before a destructive move does not establish retry after it; and a correct cleanup predicate for old folders does not establish that every folder it sees is old. The narrow proposed regressions target those boundaries. The Watch suite does include a same-inbox later-wake retry test; the missing case here is specifically the resident foreground callback after a completed failure.

**Coverage accounting.** The ledger contains nine source-review units: four covered without a retained finding, four with independently disposed candidates, and one explicitly deferred runtime-resource unit; zero blocked units and zero unassigned candidate decisions. The candidate dispositions are four confirmed, one needs validation, and one rejected. The checked-path union is 93 repository files; it does not imply every line in those files was audited. No prior-run ledger was used because this prompt expressly requires a cold start. No app subsystem was declared safe merely because an adjacent path was reviewed.

**Could not check:**

- **Target execution.** I could not establish the complete isolated environment required by the security-audit skill: no external network, an empty allowlisted environment, read-only target/toolchain, scratch-only target writes, and enforced low resource/time limits together. Its rule is: “If every control cannot be enforced, do not execute target code”. Therefore I did not create or touch any simulator, build or run the target, use a device, or exercise live accounts. This is an execution limit, not a failed app test. The probes above are supplied for that reason.
- **Native and physical behavior.** Real storage-failure timing and durability, actual Watch scheduling/haptics, device-specific Guided Access and restart behavior, siren audibility and audio interruptions, proximity/cover behavior, camera orientation/mirroring on physical devices, and consent/recording indicators were not observed. Source checks cannot replace those observations.
- **Archive and services.** I did not independently verify the signed release archive, distribution entitlements, TestFlight installation, App Attest service responses, StoreKit receipt behavior, CloudKit deployment/account behavior, notification delivery, or Apple's review outcome. The relevant recording-consent and indication rule still needs the real product flow to satisfy it; I found no source-only basis to declare a violation or predict rejection. [App Review Guideline 2.5.14](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
- **Deferred hostile-input resource checks.** Bounded runtime measurement of CBOR duplicate-key/map work, ZIP extraction cost, and verifier CPU/memory/disk limits was deferred because the execution sandbox was unavailable. Source concerns about cost were not promoted into denial-of-service findings without the required result.

The prompt reports 2,453 iOS 27.0 tests plus strict lint passing, a clean ThreadSanitizer run over 47 classes, 159 evidence/verifier tests passing on macOS, 2,453 iOS 18.0 tests passing, and Xcode Cloud's run with 54 source-file-reading tests failing because source files were absent on its test host. I did not rerun those suites or treat their reported success as evidence that these newly identified boundaries were tested. Trusted review-artifact checks passed (`PASS: 6 findings valid`; `PASS: 9 coverage units valid`); those check report structure and bookkeeping, not the app.
