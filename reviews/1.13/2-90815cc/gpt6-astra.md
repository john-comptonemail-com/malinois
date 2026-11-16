# gpt6-astra — independent adversarial review

**Date:** 13 November 2026  
**Target:** Malinois 1.13 (88), supplied snapshot `90815cc`  
**Method:** Cold, focused source review, with separate investigations of authentication, storage/cloud, and evidence verification, followed by independent validation of the findings. Only this snapshot and Apple's public documentation supplied product evidence. `_REVIEW_PROMPT.md`, other reviewers' reports/notes, repository history and external memories were not read. No git operation was performed.

**Tests run:** No application tests, Swift builds, simulator tests or physical-device tests. The already-passed suites were not rerun. No simulator was created or used. VERIFIED below means an unambiguous source trace, not a claim of device reproduction. One independent Python calculation reproduced the compact JSON layout of a dummy export; it did not execute the app or its verifier. Its output was:

```text
65535 separate shown ranges: 974728 JSON bytes; reader limit 1048576; exceeds=False
70000 separate shown ranges: 1046168 JSON bytes; reader limit 1048576; exceeds=False
75000 separate shown ranges: 1126168 JSON bytes; reader limit 1048576; exceeds=True
```

The unexecuted Swift and device probes below distinguish what source proves from what still needs observation. No claim here relies on running an existing test merely because its source was inspected.

## 1. For the owner, in plain English

**I found no verified Critical or High defect in the paths reviewed.** In particular, I did not find a way around the PIN, a way to send evidence to a different iCloud account, or a way to edit a shared photograph or event and still obtain a clean authenticity result. This is a limited source review, not proof that no such flaw exists.

Three issues merit attention:

1. **The record of old signatures can eventually become too large for Malinois's own evidence checker. — Medium, VERIFIED.** The visible Event Log is bounded, but the signed explanations of earlier cleanup keep accumulating. Eventually the app can make an evidence package that its own checker refuses. This does not prove forged evidence or deleted photographs. Add a specific size-limit warning and plan a durable solution for long-lived installations. I would handle the underlying format work after this release; I have not established a near-term failure rate.
2. **The actual iOS sharing sequence still needs a real-device check. — Medium, SUSPECTED.** Under particular callback orders, sharing can hold the screen waiting for the ZIP, or complete without requesting the ZIP and without telling the owner. The code and existing tests demonstrate those conditional behaviors, but do not demonstrate that iOS takes those paths in a real completed share. Use the planned TestFlight diagnostics and inspect the files actually saved, not just a log saying the ZIP was made.
3. **One Settings sentence promises too much from Guided Access. — Medium, VERIFIED misleading wording.** It says Guided Access stops someone powering off the phone. The app's more accurate instructions say it prevents using the power-off slider, while a forced restart still ends the armed session. Make those statements consistent.

**Release judgement:** I would allow 1.13 (88) into TestFlight. No verified functional finding here requires a core-code fix before that archive. I recommend correcting the small Settings sentence before archiving; it is not grounds for withholding a diagnostic TestFlight build. Before App Store approval, I would require the share-sheet checks in finding 2 to establish responsive operation and actual ZIP receipt. If they reproduce either problem, fix it before submission. The eventual distribution archive also needs its existing signing/environment verification; this unarchived source snapshot cannot establish those properties. The long-term history issue can follow later with an explicit tracked boundary test.

## 2. Findings

### gpt6-astra-1 — Accumulated signing history can outgrow the app's own export readers

**Severity:** Medium. **Status:** VERIFIED by source. **Timing:** Later endurance fix; not a demonstrated blocker to 1.13 TestFlight.

**Situation.** An owner uses one installation long enough for many separate count-limit cleanup passes. Each pass leaves a signed retention statement explaining the old signatures it removed. Those statements survive subsequent cleanup and accompany later shares. A current, genuine event can therefore acquire an export history too large for the supported format, despite the visible log still holding only its bounded number of events.

**Evidence and complete path:**

- `Malinois/Services/EvidenceSigner.swift:774–805` signs a retention statement and removes the retired records' exact signatures. It does not remove the earlier retention statements. Export and relaunch cleanup have the same scope (`:392`, `:1075–1086`).
- `Malinois/Services/EvidenceSignatureFile.swift:111–122,137–176` reads/appends the history and rewrites only the entries selected for removal. There is no corresponding lifetime bound.
- `Malinois/Services/EvidenceSigner.swift:417–434` includes all retention/absence/unkept counters in an export's `shown` declaration. `:685–698` serializes and signs that declaration without a statement-size check. Export readiness (`:498–504`) also has no size check.
- `MalinoisEvidence/EvidenceJSON.swift:35–51` accepts at most **1,048,576 bytes** when reading a statement, but its writer has no matching bound. `MalinoisEvidence/EvidenceForm.swift:237–269` writes every shown-counter range into the export.
- `Malinois/Services/EvidenceExporter.swift:104–125` reparses statements to decide which to show. An oversized export fails that parse and remains `shown == false`; its signature is still added. Provided package creation completes, the ZIP can therefore go out without the readable export statement that the verifier requires (`MalinoisEvidence/EvidenceBundle.swift:339–344`; `MalinoisVerifier/MalinoisVerifier.swift:465`).
- A separate limit arrives through file count: every shown statement becomes its own hash-named file (`MalinoisEvidence/EvidenceBundle.swift:264–269`), while the CLI rejects ZIP64 and the 65,535-entry sentinel (`MalinoisVerifier/MalinoisVerifier.swift:811–815`). A package with 65,535 distinct retention-statement files alone cannot fit that accepted ZIP format; other files lower the threshold. The signatures file has another 64 MiB reader limit (`MalinoisEvidence/EvidenceBundle.swift:513,734–751`).
- A successfully created URL counts as a made ZIP; the sharing notice checks creation failure, not verifier compatibility (`Malinois/Views/EvidenceBundleItem.swift:215–218,268–275`).

The independent size calculation above uses one dummy 32-byte key, singleton ranges `[3,3], [6,6], …`, a dummy UUID, revision 1, `signedAt: 0`, and `app: "1.13 (88)"`. Separated retention counters interleaved with other signed statements cannot collapse into one contiguous range. At 75,000 such ranges, the compact export is 1,126,168 bytes. This demonstrates the serialization boundary; it is **not** a measured user workload or a device-generated signed bundle.

**Important limits.** Count retention statements, not events: one statement can retire several records. No elapsed-time estimate is established. iOS might fail or time out while creating a large ZIP, in which case the existing generic missing-ZIP notice applies. An extracted folder bypasses the ZIP64 rejection, but not the statement-size or signatures-file limits. I am not claiming signature forgery, silent destruction of original evidence, or that every installation will encounter this soon. ADR 0067:123–126 acknowledges growing lists; the narrower defect is their incompatibility with finite readers.

**Smallest fix.** Share the producer/reader limits, preflight before signing and packaging, and return a specific history-size reason instead of successfully sharing an incompatible ZIP. Preserve the signing history. Maintaining exports indefinitely requires a reviewed format change or authenticated compaction; simply deleting retention statements would break the evidence accounting. Raising only one limit leaves the others.

**Narrow probe to run in scratch, not run here:**

```swift
func testExportWriterCanOutgrowItsReader() throws {
    let ranges: [ClosedRange<UInt32>] = (1...75_000).map {
        let n = UInt32($0 * 3)
        return n...n
    }
    let form = EvidenceForm.Export(
        record: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        revision: 1, signedAt: 0, app: "1.13 (88)",
        shown: [.init(keyID: Data(repeating: 0, count: 32), counters: ranges)])
    let bytes = EvidenceForm.bytes(.export(form))
    XCTAssertGreaterThan(bytes.count, EvidenceJSON.maximumBytes)
    XCTAssertThrowsError(try EvidenceForm.read(bytes))
}
```

That characterizes the present incompatibility, not the eventual desired behavior. Follow it with a dummy-key export fixture showing that an oversized export becomes hash-only and is rejected as having no export statement. A separate boundary fixture should distinguish the actual iOS ZIP writer's behavior from verification of an extracted folder. The final regression should require either a supported, verifiable package or an explicit refusal before sharing.

### gpt6-astra-2 — Sharing depends on callback ordering that has not been validated end to end

**Severity:** Medium if reproduced. **Status:** SUSPECTED as a real UIKit integration failure; the conditional source behavior is verified. **Timing:** TestFlight validation, resolved before App Store sign-off.

**Situation A: a long wait on the screen.** The background provider operation starts preparing a ZIP. If iOS asks for the item on the main thread before preparation finishes, that callback takes the same mutex held throughout preparation and waits for it, potentially nearly the 60-second limit.

**Situation B: an unnoticed omitted ZIP.** A signed, export-ready event is shared to a destination that may take files. If the activity completes without requesting the provider operation, no ZIP is made and the event screen gives no missing-ZIP notice. An early callback returning nil alone does **not** prove this happens: UIKit could subsequently run the operation or ask again.

**Evidence:**

- `Malinois/Views/EvidenceBundleItem.swift:78–83,162–170,188–193,206–221,236–247`: the main-thread item-source callback reads through the mutex held across the timed preparation wait.
- `Malinois/Views/EvidenceBundleItem.swift:268–275`: `.ready` shows the warning only when `made == false`, leaving `nil` silent. `Malinois/Views/EventDetailView.swift:102–109` supplies the completed share's creation outcome to that function.
- `MalinoisTests/Item223ShareDiagnosticTests.swift:138–155` directly stages the overlapping callback; `:161–166` directly supplies completion without creation. Its sheet has an empty activity-items array (`:244`). These are state-machine/diagnostic tests, not demonstrations of UIKit's scheduling or destination receipt. `Item200ShareNoteTests.swift:57–65` expressly expects no notice for `made: nil`.
- ADR 0080:52–54 already calls the main-thread timing unknown; ADR 0067:97–99 acknowledges the ordering dependency. The new diagnostics are a sensible way to investigate this known design risk.

Apple documents item-source methods as main-thread callbacks and provider `item` generation as work on a secondary thread. Those contracts support the conditional blocking analysis, but do not establish the actual ordering in this app. [UIActivityItemSource](https://developer.apple.com/documentation/uikit/uiactivityitemsource), [UIActivityItemProvider.item](https://developer.apple.com/documentation/uikit/uiactivityitemprovider/item).

**Smallest fix and tradeoff.** Within the existing completed/local/file-eligible guards, make `.ready` report a missing ZIP when `made != true`, and update the nil-outcome test. This repairs the missing explanation, not delivery. For the blocking case, do not hold a mutex needed by the main-thread callback throughout preparation. A straightforward complete design prepares the ZIP asynchronously after the explicit Share tap, then opens the sheet with a concrete URL. That spends an export signature even if the later sheet is cancelled, changing the current deliberate tradeoff. Merely returning nil during preparation can exchange the wait for an omission.

**What would confirm it.** On a dedicated device with synthetic evidence, complete actual **Save to Files → On My iPhone** shares, including a deliberately delayed maker, normal creation, failure, cancellation, and successive shares. Correlate the existing diagnostics with UI responsiveness and the saved output. A main-thread ask overlapping preparation with a visible stall confirms A. A completed share with no creation request and no saved ZIP confirms B. A line saying “the ZIP was made” alone proves neither delivery nor absence of a stall. No real messages need be sent.

For a small scratch regression, call `ShareNote.line(readiness: .ready, completed: true, destination: .airDrop, made: nil, mirrored: false)` and require the missing-ZIP note. A short-limit controlled maker plus a main-loop heartbeat can characterize the mutex wait. Neither substitute settles real UIKit reachability. Original evidence is not shown to be deleted or corrupted by this issue.

### gpt6-astra-3 — Settings overstates what Guided Access prevents

**Severity:** Medium, misleading security claim. **Status:** VERIFIED. **Timing:** Recommend correcting before archive; a small wording fix, not a newly discovered protection bypass.

**Situation.** An owner reads the Security footer and understands it to mean someone holding the phone cannot stop protection using its hardware controls.

**Evidence.** `Malinois/Views/SettingsView.swift:482` says Guided Access “stops a snoop from switching away or powering off.” The same screen's toggle caption is narrower (`:25–28`), and `Malinois/Views/ArmingView.swift:14–15` and `SECURITY.md:650` explicitly say a forced restart still ends the armed session. The problem is the overbroad assurance, not an undocumented new shutdown technique. The accurate nearby coaching limits its severity.

**Smallest fix:** “Guided Access (single-app mode) is strongly recommended while armed — it stops a snoop from switching apps or using the power-off slider. A forced restart still ends the armed session. Malinois coaches you through it on the arming screen.”

**Probe:** Inspect the rendered Security footer, including the long-text layout, and confirm that the slider restriction and forced-restart exception both appear. A source assertion for the toggle caption alone does not check this footer.

## 3. Wrong claims in the documents

The confirmed wording problem is the in-app Settings claim in finding 3; the replacement wording is given there. The principal README and SECURITY explanations of forced restart are more accurate. I did not establish another materially false document claim within the passages reviewed.

I did not count acknowledged limits as newly discovered defects: editable cloud mirrors, old-export replay, inability to identify a particular physical phone or owner from a certificate, App Attest counter rollback limits, conditional cloud delivery, retention under storage pressure, and shutdown are substantially disclosed. Nor did I treat the prompt's planned publication edits or the two explicitly deferred UI explanations as missing work in this candidate.

## 4. Where I went

My initial hypotheses concerned stale authorization, interrupted evidence writes, cloud account changes, edited shared bundles, and protection that looks active while sensors or alerts have stopped. The review followed source paths rather than the unread checklist.

**Authentication and lifecycle.** Reviewed `RootView`, `HomeView`, `PINViews`, `KeychainService`, biometric binding, arming transitions, disarm entry, reinstall/recovery and Test sensors. Unreadable credentials are distinguished from absent ones; surviving credentials/recovery evidence do not simply open fresh setup. PIN checking owns rate limiting. Biometric/recovery completions have request identity and lifecycle invalidation. Both manual and recovery arming stop lingering dry-run state. A proposed indefinitely renewed disarm-pad suppression bypass did not survive tracing its time bounds and continued capture. A proposed missing first-Siren Volume Buttons instruction was rejected because Settings supplies it at the mode-change control.

**Storage and cloud.** Traced EventStore birth journaling, media attachment intents, count/media retention, set-aside share/delete, CloudEnrollment, CloudExfiltrator and transfer/backup/retention coordinators. Examined account-generation checks, capture-time ownership and checks around asynchronous completion; local first-hand rows are protected from mirror replacement. The download path remeasures storage and chooses/attaches slots without another suspension. Set-aside sharing excludes current log references and pending attachment intents; deletion checks current, pending and other set-aside references. These controls defeated the concrete hypotheses examined. No production account or CloudKit schema was inspected.

**Evidence authenticity.** Reviewed the signer/key/signature-file/export paths, canonical forms and JSON, bundle verification, assertion/counter handling and CLI archive checks. No demonstrated path was found for altered attachments, ordinary index/key grafting or hiding a shown statement to retain a clean PASS. The new Vision reference's later response save supplies another signing opportunity after its file is queued. This was source analysis, not cryptographic fuzzing or real App Attest execution.

**Monitoring and alerts.** Inspected selected trip-response, audio-health, Vision, siren-routing/interruption and iPhone-to-Watch relay/inbox paths. The code distinguishes several expected pauses and failures and preserves continued capture during PIN entry. No physical microphone, camera, Bluetooth, haptic, speaker-volume, Guided Access or watch background-wake behavior was tested.

**Late-camera ownership.** A final focused pass traced `EvidenceCapturePipeline`, `CameraController`, the original response, recoverable storage and the late-upload coordinator. Per-file callbacks retain their original capture attempt; exact URL checks protect recording continuations; quarantine keeps the old attempt leased until its worker drains; storage rechecks the original event/slot; and late uploads owe another sweep when one is already running. No cross-event attachment or new-session corruption was established.

One **SUSPECTED test lead**, not promoted to a numbered release defect, remains: if late attachment finishes before the original timed-out response's final write, that older value could clear its media fields (`EvidenceCapturePipeline.swift:316–340`; `MonitoringTripResponder+Responses.swift:650`; `EventStore.swift:1953–1976,2074–2080`). The decisive scheduler ordering was not established. In the timeout path, the two nil-capture storage helpers return without actually suspending, so inserting a new test-only wait there would demonstrate a conditional stale merge, not production reachability. A useful follow-up is to instrument existing deadline, delegate, I/O and response-resumption boundaries and vary their timing without adding a new response suspension. The inspected engine test releases late evidence only after the original response settles (`MalinoisTests/EngineCharacterizationTests.swift:809–817`), so it does not settle the opposite ordering. This lead does not change my release judgement.

**Review and test blind spots.** The strongest remaining integration gap is the real sharing lifecycle: callbacks invoked directly by a test cannot establish the OS's ordering or a recipient's received files. The history-size mismatch shows a second gap: small valid bundles and malformed-input tests do not establish that the producer remains inside its consumer's limits after long use. Add accumulated-history fixtures at the supported boundaries. These observations do not negate the reported 2,424 tests or the existing release checks.

**Limits of this review.** This is focused, partial source coverage; large files were traced selectively, not every line audited. No archived binary exists in this snapshot. Actual entitlements/provisioning, production APNs/CloudKit environments and archive contents must be checked on the eventual archive with the existing release verification, not inferred from Debug tests. Physical power-loss durability, Apple services, biometric/Keychain behavior on devices, notification delivery and App Review's eventual decision remain unverified. No blanket App Review approval or rejection prediction is warranted.

The source-only execution choice also respected the security-audit skill's requirement: “If every control cannot be enforced, do not execute target code.” Its required isolated environment and resource controls were not established for a simulator here, so I did not launch one or claim an attempted simulator run failed. Skill used. The runnable probes above are the remaining validation work; no broad suite rerun is requested.
