# Independent review of Malinois 1.13 (88)

**Reviewer:** Codex  
**Date:** 2026-11-13  
**Snapshot:** (the review folder), as supplied.  
**Tests run:** None. No build, simulator, device test, or target code execution was attempted. The four findings below are **VERIFIED by source**, not reproduced on a running iPhone. Proposed tests are explicitly unexecuted and uncompiled. The prompt's 2,407 passing app tests and 159 earlier evidence/verifier tests are supplied history, not results of this review.

I read `_REVIEW_PROMPT_OPEN.md` first and left `_REVIEW_PROMPT.md` unread. I used this snapshot and Apple's public documentation, with fresh, scoped review agents and a final independent challenge. I did not consult earlier reviews, other reviewers' reports or notes, or Git history. This report is the only requested-folder file I wrote.

## 1. For the owner

**I would hold the 1.13 archive for the four changes below.** The strongest problem is in cloud recovery: a failed attempt can look successful, and overlapping attempts can incorrectly mark a full restore finished. I found no demonstrated way through the PIN, no wrong-account disclosure, and no way to substitute an altered Vision image while retaining a valid evidence verification result in the paths examined.

1. **Cloud recovery can quietly stop short.** A refresh that fails before reading records can leave the earlier successful result on screen. More seriously, a failed full restore can borrow the success of another, smaller refresh and stop asking for the older history automatically. Keep each attempt's result with that attempt and show its failure. **Fix before archive.**
2. **The new deletion safeguard is optional when its own save fails.** If the phone cannot save the small recovery note, it still deletes the set-aside log. If the app then stops before recording the deletion, the promised entry cannot be recovered. Require the note to be saved first, or visibly decline the deletion. **Fix before archive.**
3. **The Vision picture is described too precisely.** It is captured just after Vision sets its comparison reference; it is not necessarily the picture Vision actually compared against. The current explanation can say that more than a third changed since the displayed picture even when that comparison would show no changed pixels under the detector's threshold. Keep the useful picture but describe it as a nearby reference view. **Correct the copy before archive; changing the detector can wait.**
4. **“Nothing is deleted” teaches a guarantee the app does not offer.** Old entries are retired automatically, and someone with the PIN can delete a set-aside log. Say that individual current-log entries cannot be deleted manually, and name the exceptions. **Correct the briefing before archive.**

After those changes and their focused regression checks, I would allow **TestFlight**. I would allow **App Store submission** after the already-planned release gate passes and the Watch interruption/camera checks described below are resolved. The two device-dependent concerns below are validation gaps, not demonstrated defects. This review does not substitute for ThreadSanitizer, iOS 18.0, Release inspection, or Xcode Cloud.

## 2. Findings

### Codex-1 — High — VERIFIED: cloud failure results can retain or borrow another pull's success

**Affected resource:** the owner's displayed history and the persistent decision that a full cloud restore has finished. No remote evidence deletion or account-boundary bypass is established.

**Situation A: an ordinary failed refresh is silent.** The owner has Pro, a verified account, synced local records, and a previous successful pull. The network remains reachable, but CloudKit's identity lookup now fails temporarily, for example with `serviceUnavailable`. The owner refreshes the Event Log. Its production refresh awaits upload retry and then a pull (Malinois/Views/EventLogView.swift:261). The pull returns at its initial lease failure, before assigning its outcome (Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:295, especially lines 304 and 311). A transient identity failure deliberately preserves the known account and verification state (Malinois/Services/CloudExfiltrator.swift:942).

Consequently, `lastCloudPull` still says the previous attempt succeeded. Both screen notices derive solely from that value (Malinois/Services/MonitoringCloudCoordinator+LaunchPull.swift:78, Malinois/Views/HomeView.swift:502, Malinois/Views/EventLogView.swift:98). With the network reachable and local rows synced, the separate offline/upload banners need not appear. The owner is not told the requested read failed.

**Situation B: a full restore can be incorrectly settled.** This is a concrete permitted interleaving, not an assumption about an async function's return scheduling:

1. Full restore A passes its coordinator account check. Its inner `fetchRecentEvents` resets shared `lastFetchComplete`, `lastFetchFailed`, and `lastFetchUnreadable`, then suspends on another identity lookup (Malinois/Services/CloudExfiltrator.swift:1492, lines 1493–1501).
2. Ordinary push pull B runs meanwhile and finishes successfully, setting those shared fields to its result (lines 1511–1513).
3. A's suspended identity lookup returns a **transient** failure. A returns an empty array at line 1501 without resetting the fields B just set. The earlier account lease remains current.
4. A's coordinator reads the shared fields as if they described A (Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:320, particularly line 328). It publishes success and the launch restore calls `completeRestore()` (line 36).
5. That clears the restore marker (Malinois/Services/EventStore.swift:620). If B populated recent rows, later launches ask for only a page rather than the full restore allowance (Malinois/Services/MonitoringCloudCoordinator+LaunchPull.swift:25). Older cloud history can remain absent until the owner manually requests a full refresh.

The launch flag prevents another launch restore, but does not serialize ordinary `syncFromCloud`/push pulls; the push path directly calls `syncFromCloud` (Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:48). A genuinely different account invalidates the outer lease and is rejected; that control does not repair the transient-failure case.

**Smallest sound fix:** make the fetch return one per-call value containing its events, completion, failure status, and unreadable count, including on every early exit. Use that value for the screen, push completion, and restore settlement. Publish an incomplete result when an attempted Pro pull cannot obtain its initial lease. Preserve account-generation checks so a discarded old-account operation cannot replace a newer account's result.

**Probe:** the initial-failure test in section 4 exercises the real lease gate. For the overlap, hold A at the inner identity lookup with a throwing continuation, let B finish, then resume A with `CKError(.serviceUnavailable)`. Require A to remain incomplete and `restoreOwedSince` to remain set. Source establishes the wrong state transition; the schedule has not been executed here. **Fix before archive.**

### Codex-2 — Medium — VERIFIED: deletion proceeds even when its recovery note was not saved

**Situation:** an owner, or someone who knows the PIN, confirms deletion of a set-aside log on a nearly full phone. Creating the note fails, for example with insufficient space. Removing the old log succeeds. The app is stopped during the subsequent media cleanup, before the engine creates the deletion entry. On relaunch there is neither a recovery note nor a deletion entry to recover.

The code conclusively permits that sequence:

- `oweSetAsideDeleteEntry` always returns a note object; it provides no successful-write acknowledgement (Malinois/Services/EventStore.swift:3313).
- The queued save catches the failure and only writes to the diagnostic log. Its comment explicitly says deletion goes on (Malinois/Services/EventStore.swift:3327).
- The engine proceeds directly to the store deletion, creating the audit event only after that asynchronous operation returns (Malinois/Services/MonitoringEngine+AuditRecords.swift:39).
- The store removes the log first, then scans and removes its media (Malinois/Services/EventStore.swift:3104). Thus there is a real interruption interval after destruction and before the audit birth.
- Recovery needs a readable note; an absent one produces no recovered entry (Malinois/Services/EventStore.swift:3350).

**This is a judgement against the explicit best-effort behavior, not an undisclosed PIN bypass.** The deletion itself is authorized. The defect is the missing promised record of it. ADR 0083 accepts unreadable existing notes being lost, but separately asserts that the note is on disk before deletion and that a deletion leaves its entry whatever stops the app (docs/adr/0083-a-set-aside-logs-delete-writes-a-note-first-so-its-entry-is-never-lost.md:17, lines 19–20 and 34–35). Failed note creation is not protected by queue ordering. An OS diagnostic message is not the promised Event Log notice.

**Smallest fix:** await successful note persistence before permitting the destructive step. On failure leave the log intact and show that the deletion could not be safely recorded. The cost is that this Delete may be unavailable when the disk is completely full; that is preferable to silently abandoning its audit guarantee. Retiring an intent should also depend on an acknowledged durable audit write, rather than merely calling a function that returns an event object.

**Probe:** inject a failure for the note file only, keeping the log removable. The production engine should refuse deletion visibly. Separately use the same post-delete/pre-entry checkpoint as the existing recovery test, with the failed note save, and reconstruct the store. Section 4 provides that checkpoint probe. Actual ENOSPC timing and a real process kill were not exercised. I did not infer loss from `loadFailed` or a journal failure alone: a successful journal or metadata write can preserve the entry. **Fix before archive.**

### Codex-3 — Medium — VERIFIED: the Vision caption identifies an approximate view as the actual reference

**Situation:** a lamp or scene contrast changes immediately after calibration, then changes a little more. The saved reference picture and the trip picture can look almost identical, yet the explanation says over a third of the view changed since the saved picture.

The initial detector reference is the per-pixel mean of calibration frames (Malinois/Monitors/VisionDetector.swift:141). After setting a reference, the monitor requests a still (Malinois/Monitors/VisionMonitor.swift:163), and the camera supplies a later sampled frame. ADR 0081 deliberately chooses that next-frame approximation (docs/adr/0081-a-slow-vision-trip-saves-the-view-it-compared-against.md:19). Nevertheless, the caption says “which Vision compared against,” and the explanation says “over a third of the view had changed since then” (Malinois/Views/EventDetailView.swift:183, lines 187 and 203–204).

A counterexample follows directly from the detector's arithmetic. Use 768-pixel frames, each split into equal halves:

| Frame | First half | Second half | Role |
|---|---:|---:|---|
| A | 128 | 128 | Calibration reference |
| B | 139 | 117 | Next sampled frame; its JPEG is saved |
| C | 140 | 116 | Next sample |
| D | 141 | 115 | Slow-trip sample |

Calibration gives a pixel threshold of 12. The quick comparison's maximum differences at B, C and D are 11, 11.45 and 11.8775, so none counts as changed. At D, every pixel differs from reference A by 13, so the slow check trips. The monitor attaches B's still (Malinois/Monitors/VisionDetector.swift:173, Malinois/Monitors/VisionMonitor.swift:145). Comparing displayed B with D instead yields a difference of only 2 at every pixel: **zero** pixels changed under the same threshold. Thus the quantitative explanation about the displayed view is false even when the still and its timestamp are authentic.

**Smallest fix:** preserve the approved sampling design but say “A view captured just after Vision set its reference” and “Vision tripped on a slow change from its reference.” Keep the capture time. Correct matching document claims. Producing an exact reference image would be a separate design choice, particularly because calibration averages multiple frames; this finding does not require changing the detector.

**Probe:** section 4 gives the four-frame monitor test. Existing tests supply the same scene for calibration and the subsequent still-associated frame (MalinoisTests/Item239ReferenceStillTests.swift:309), so they miss this distinction. Signing the authentic JPEG is sound; this is not a signature forgery claim. **Correct wording before archive; exact-image redesign can wait.**

### Codex-4 — Medium — VERIFIED: the new briefing promises undeletable history without its exceptions

**Situation:** a new owner reads “Nothing is deleted” and “no one can delete an entry, not even with your PIN,” then relies on the phone to retain an older incident or believes a PIN-holder cannot remove the contents of a set-aside log.

Those are the exact new strings (Malinois/Models/FirstArmBriefing.swift:34), displayed without qualification (Malinois/Views/FirstArmBriefingView.swift:33). Actual behavior has independent limits of 500 incidents and 100 audit records (Malinois/Services/EventStore.swift:106) and removes victims from the log (Malinois/Services/EventStore.swift:678). The set-aside screen also offers whole-log deletion after the PIN and confirmation (Malinois/Views/SetAsideLogView.swift:86, Malinois/Views/SetAsideLogView.swift:151).

The narrower statement that the current Event Log has no single-entry delete control is true. The broader heading and unqualified text are misleading. The support page and privacy policy already accurately describe both retention and the set-aside exception (store/support.html:285, store/PRIVACY_POLICY.md:135). I am not proposing removal of those deliberate features.

**Smallest fix:** heading “Your activity is recorded.” Body: “Every arm, disarm and trip goes in the Event Log. Individual entries in the current log cannot be deleted by hand. It keeps recent events and retires the oldest automatically; a set-aside log can be deleted with your PIN. To try the sensors without recording anything, use Test sensors on Home.”

**Probe:** render the first-arm briefing and check the corrected qualification; retain the existing count-cap and PIN-deletion behavior tests. Update the exact-copy assertion at MalinoisTests/Item240OnboardingTests.swift:220. This needs a copy regression, not a new retention mechanism. **Fix before archive.**

## 3. Wrong claims in the documents and app

| Claim and location | Why it is wrong | Replacement |
|---|---|---|
| “if Malinois can't read all of your event log from iCloud, Home and the Event Log now say so” — store/APP_STORE_LISTING.md:270 | Codex-1: failed initial lookups and overlapping pulls escape or corrupt outcome reporting. This is prepared 1.13 copy, not an assertion about what is already live. | Prefer fixing the implementation and keeping the promise. If not fixed: “Home and the Event Log report incomplete record queries and records this version cannot read. Some failures before a query starts are not reported there.” |
| “A Delete leaves its entry whatever stops Malinois” — docs/adr/0083-a-set-aside-logs-delete-writes-a-note-first-so-its-entry-is-never-lost.md:34; the related next-launch guarantee at SECURITY.md:1880 | Codex-2: the app does not require a successful note save. | With current behavior: “When its recovery note can be saved and read, the next launch records a deletion interrupted before its entry.” With the recommended fix: “If Malinois cannot save the recovery note, it leaves the log intact and tells you; otherwise an interrupted deletion is recorded at the next launch.” Keep the existing damaged-note limitation explicit. |
| “the view it compared against” — store/APP_STORE_LISTING.md:268; “the event also saves that frame” — store/APP_REVIEW_NOTES.md:75 | Codex-3: it saves a subsequent frame, not necessarily the detector's comparison input. | “When Vision trips on a slow change, the event shows a view captured just after Vision set its reference, to help you judge what changed.” |
| “the frame the slow check compares against” — README.md:178, SECURITY.md:1282; “the frame it was comparing against” — store/PRIVACY_POLICY.md:36 | Same exact-reference mismatch. The cloud-exclusion and explicit-share disclosures are supported. | Describe “a nearby view captured just after the slow-check reference was set, kept in memory and saved with an event only when that check trips.” Preserve the existing phone-only/app-upload and sharing qualifications. Update the corresponding public-page/public-README publication text consistently. |
| “Nothing is deleted”; “no one can delete an entry, not even with your PIN” — Malinois/Models/FirstArmBriefing.swift:34 | Codex-4: omits automatic retirement and whole set-aside-log deletion. | Use the qualified replacement in Codex-4. The support/privacy retention explanations need no corresponding weakening. |

I did not flag the deliberately pending version lines or privacy effective date, the README joke, or documented platform limits as defects.

## 4. Where I went, what held, and what remains unvalidated

### Scope and controls that held under source review

- **Welcome, reinstall and authentication:** unresolved Keychain state and recovery precede welcome; surviving credentials and prior-data indicators prevent a false fresh-install path. Reset/biometric callbacks are revoked on lifecycle changes, biometric use is opt-in for read gates, and disarm/recovery cancellation do not opt in. The first-disarm card enters the existing log gate. Starting arming stops a dry run and invalidates delayed calibration. Relevant paths: Malinois/Views/RootView.swift:16, Malinois/Services/KeychainService.swift:189, Malinois/Views/PINViews.swift:269, Malinois/Views/HomeView.swift:80, Malinois/Services/MonitoringArmingFlow+Transitions.swift:14. I found no new bypass in these paths.
- **Vision attachment integrity and privacy:** generation checks reject stale stills; the reference filename/time are present at event birth; pruning is not undone by a late response; attachment hashes and facts are checked on export and by the generic verifier. Cloud metadata and upload slots omit the reference image and time. Relevant paths: Malinois/Monitors/VisionMonitor.swift:115, Malinois/Services/EventStore.swift:1970, Malinois/Models/Event+Evidence.swift:72, Malinois/Services/EvidenceExporter.swift:130, Malinois/Models/Event.swift:399. No demonstrated bypass or unintended app upload was found. Phone backups remain a separately disclosed channel.
- **Downloads and retention:** download admission includes all current-log media names, including in-flight uploads, retries changed measurements, and makes the placement/update without an intervening suspension after accepting the measurement (Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:609, Malinois/Services/EventStore.swift:1377). I rejected the proposed admission/attachment race. Set-aside files are outside that current-log cap by design. Unknown retention values and whole-settings recovery choose Keep forever (Malinois/Models/AppSettings.swift:423, Malinois/Models/AppSettings.swift:742).
- **Cloud authorization:** fresh leases, account-generation invalidation, and original event-account binding reject wrong-account work. The problems in Codex-1 concern result bookkeeping, not evidence disclosure to a new account. Manual purge logging records the result after the purge; I did not establish a separate new defect there.
- **Watch:** handoff ordering, serialized inbox processing, deduplication, replay at launch/wake, and the bounded wake deadline are present. Capacity, corrupt-list reset and retry limits are documented design choices, not findings merely because they drop some work.

The Vision still is deliberately subject to media pruning even though it has no app-created cloud copy. Its old signed digest does not preserve the image bytes. ADR 0081 explicitly chooses this; I have not reclassified it as an unexpected loss defect.

### Execution limits and review blind spots

This was a targeted source review, not exhaustive coverage of the entire app, verifier, release tooling or App Review compliance. No native Guided Access/LocalAuthentication lifecycle, real CloudKit transition, physical camera, or Watch execution was observed. I did not rerun the supplied passing suite or perform the pending release gate.

The applicable security-audit skill requires an OS-enforced sandbox isolating target execution from external network, host credentials/shared services and non-scratch writes, with explicit resource limits: “If every control cannot be enforced, do not execute target code.” I did not establish those controls for a simulator and its service-launched processes, so dynamic execution was not attempted. This is a validation limitation, not an Xcode or simulator failure. No existing simulator was booted, erased, or used. The following probes belong in a disposable copy on a reviewer-created simulator with the required isolation; no permissions are needed for the synthetic app tests.

Two **SUSPECTED, unconfirmed runtime concerns** deserve focused checks; neither is counted among the four verified findings:

- **Watch persistence across actual process death:** the queued handoff calls `WatchRelayOwed.note` before returning (MalinoisWatch/WatchAppDelegate.swift:278), but storage is `UserDefaults.set` (MalinoisWatch/WatchRelayInbox.swift:527). Apple documents immediate in-memory updates and asynchronous disk writes ([UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults)). The existing “next run” test creates a second inbox over the same defaults object (MalinoisTests/Item219WatchOwedAlertsTests.swift:228, MalinoisTests/Item219WatchOwedAlertsTests.swift:355). That establishes logical replay, not a completed disk write. On a dedicated test Watch, stop the process immediately after the note returns but before delivery, cold-launch, and require the same alert to replay; also test the wake cutoff and storage-pressure path. Actual alert loss remains unproven. Do not treat adding `synchronize()` as a proven remedy.
- **Reference-image orientation in clip mode:** clip sessions exclude photo outputs, but the still's orientation reads their connections (Malinois/Services/CameraController.swift:854, line 947); a missing connection becomes zero rotation/unmirrored (line 981). Movie and frame-tap connections can encode rotation differently ([Apple videoRotationAngle](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)). Compare an asymmetric chart with readable text in front/rear/Both clip modes against the saved JPEG, recording actual connection rotation/mirroring. The pure-angle/uniform-color tests do not establish hardware agreement. If it differs, derive orientation from the output actually used. A visible mismatch remains unproven.

The main test blind spot is that successful helper calls, same-process “relaunches,” and exact wording assertions are treated as evidence for stronger lifecycle or semantic promises. These tests are useful, but need a few hostile boundaries: failed intent creation, independently suspended cloud requests, different calibration/next-frame content, and actual Watch process termination.

### Proposed regression probes — not executed or compiled

**Cloud initial failure.** Add inside MalinoisTests/Item227RestoreNoticeTests.swift:21, using its existing fixture helpers. The assertions describe the required behavior and should expose the current stale-success path:

```swift
func testInitialIdentityFailurePublishesIncompletePull() async throws {
    let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
    let enrollment = CloudEnrollment(
        file: root.appendingPathComponent("grant/state.json"),
        authenticate: { _ in true })
    let enrolled = await enrollment.enroll(
        account: "account-a", resolve: { "account-a" })
    XCTAssertTrue(enrolled)
    CloudEnrollment.sharedForTesting = enrollment
    let cloud = CloudExfiltrator(enrollment: enrollment)
    cloud.accountIdentityForTesting = { "account-a" }
    let rig = makeRig(cloud: cloud)
    rig.engine.requiresCloudLeaseForTesting = true
    rig.engine.cloudFetchForTesting = { _ in ([], true) }
    try await launch(rig)
    XCTAssertEqual(rig.engine.lastCloudPull,
                   CloudPullOutcome(complete: true, unreadable: 0))

    cloud.accountIdentityForTesting = { throw CKError(.serviceUnavailable) }
    await rig.engine.retryPendingSync()
    _ = await rig.engine.syncFromCloud(limit: EventStore.maxEvents)
    XCTAssertTrue(enrollment.verified)
    XCTAssertEqual(rig.engine.lastCloudPull,
                   CloudPullOutcome(complete: false, unreadable: 0))
    XCTAssertTrue(try home(rig).contains(CloudPullOutcome.homeIncomplete))
}
```

Extend it to render Event Log and assert `CloudPullOutcome.logIncomplete`. For **overlapping requests**, use the real `fetchRecentEvents`, with `readSubmitForTesting` completing each query through `queryResultBlock?(.success(nil))`. Hold A's inner account lookup in a throwing continuation, return account A for B's lookups, await B's completion, then resume A with `serviceUnavailable`. Assert A's result is incomplete. Through `restoreFromCloudAtLaunch`, additionally assert that `restoreOwedSince` survives and the next launch still requests the full allowance. Use explicit continuation barriers, not sleeps. The current shared-result API itself needs changing before a test can assert completion directly on each returned fetch result.

**Deletion checkpoint after failed note creation.** Add inside MalinoisTests/Item235DeleteOwedEntryTests.swift:20, using its helpers. A nonempty directory at the note-file path forces that write to fail without filling the disk. This models the same interruption checkpoint as the existing recovery test; it is not a real process-kill test:

```swift
func testFailedNoteCannotRecoverInterruptedDeletion() async throws {
    let (store, log) = try storeWithASetAsideLog()
    let blocked = try root().appendingPathComponent(
        EventStore.setAsideDeletesOwedFileName)
    try FileManager.default.createDirectory(at: blocked,
                                            withIntermediateDirectories: true)
    try Data([1]).write(to: blocked.appendingPathComponent("fixture"))
    let owed = store.oweSetAsideDeleteEntry(for: SetAsideLog(url: log))
    let removed = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
    XCTAssertTrue(removed.removedLog)
    store.drainIOForTesting()
    XCTAssertNil(Self.notes(in: try root()))

    // Checkpoint: no engine audit call occurred before the simulated stop.
    let reopened = EventStore()
    _ = engine(on: reopened)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(reopened.events.contains { $0.id == owed.id })
}
```

That is a characterization of the missing recovery information. The desired **post-fix engine test** uses the same failed-write fixture, calls `engine.deleteSetAsideLog`, and requires `.notDeleted`, the original log still present, and a visible failure notice. Add a scratch-only hook immediately after file removal if an actual process-boundary version is used; never kill a shared app or simulator.

**Vision reference mismatch.** A monitor-level characterization using existing seams; marker bytes test selection, not JPEG decoding. An image-level extension should encode B's actual pixel buffer:

```swift
@MainActor
func testSavedStillCanDifferFromSlowComparisonReference() throws {
    let count = VisionFrame.width * VisionFrame.height
    func frame(_ delta: Int) -> VisionFrame {
        VisionFrame(luma: (0..<count).map {
            UInt8(128 + ($0 < count / 2 ? delta : -delta))
        })
    }
    let vision = VisionMonitor()
    vision.uptimeForTesting = { 1_000 }
    var generation: Int?
    var trips = 0
    vision.onReferenceStillWanted = { generation = $0 }
    vision.onTrip = { _ in trips += 1 }
    vision.beginCalibration()
    vision.ingest(frame(0))
    vision.endCalibration()
    vision.start()
    let stillB = VisionStill(generation: try XCTUnwrap(generation),
                            jpeg: Data("frame-B".utf8),
                            takenAt: Date(timeIntervalSince1970: 1_800_000_000))
    vision.ingest(frame(11), still: stillB)
    vision.ingest(frame(12))
    XCTAssertEqual(trips, 0)
    vision.ingest(frame(13))
    XCTAssertEqual(trips, 1)
    XCTAssertEqual(vision.takeTripStill(), stillB)
    XCTAssertEqual(VisionDetector.changedFraction(
        VisionDetector.normalized(frame(13)),
        against: VisionDetector.normalized(frame(11)), threshold: 12), 0)
}
```

After correcting the wording, require the rendered detail to describe a nearby view without asserting that the displayed image was the exact comparison input. For Codex-4, change the existing briefing copy/render assertion to require the retention and set-aside qualifications; the underlying deletion and retention behavior is intentional.
