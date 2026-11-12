# Codex independent open review — Malinois 1.12 (87)

Reviewer: **Codex (GPT-6)**  
Date: **11 November 2026**  
Reviewed snapshot: **4ae94ef**, as identified by `_REVIEW_PROMPT_OPEN.md`.

**Tests run: none.** No build, existing test suite, simulator, or target executable was run; there are no test-summary lines to report. The previously successful release gate is supplied background, not a result I independently reproduced. The focused regression probes below are **proposed, not executed**. VERIFIED means established by an unambiguous source trace, as the review prompt permits. Actual power-loss behavior remains SUSPECTED.

I read `_REVIEW_PROMPT_OPEN.md` first. I did not read `_REVIEW_PROMPT.md`, another review report or notes folder, a Git repository, or previous review history. This review used the supplied source/documents and Apple's public documentation. Parallel investigations and independent counterchecks were part of this Codex review; they had the same restrictions. Only this report was added to the reviewed folder. Source references below are relative to that folder.

## 1. For the owner, in plain English

The app has substantial, thoughtfully placed protections. I did **not** establish a way around the Malinois PIN, an unintended Guided Access bypass, a cross-account evidence leak, or a forged signature accepted by the verifier. That is a bounded source-review result, not proof that those failures are impossible.

Four issues deserve attention:

1. **The public description promises more detection than the app provides.** It says your phone will be unchanged or you will know otherwise. The project's own security document explains that someone can slowly lift a level phone by its edges without setting off a sensor. Correct the promise before App Store submission. This needs a wording change, not a claim that the sensors can be made perfect. **High, VERIFIED** under the requested severity scale.
2. **A shared signed ZIP can contain older facts than the event you selected.** If an updated event fails to sign, sharing can still succeed with its previous signed version. For example, the app can label an event as your own handling while its new ZIP still lacks that label. The signature can be authentic and the evidence misleadingly out of date. Make Share check the facts as well as the photos. **Medium, VERIFIED.** I would fix this before archiving the release candidate.
3. **The emergency event journal may lose part of its power-loss protection during cleanup.** A newer event is explicitly flushed to storage, but cleanup of an older event can replace that emergency file without flushing its replacement. The missing barrier and possible ordering are clear; I have not demonstrated lost evidence on a physical iPhone. Preserve the old journal until its remaining events are safely covered, or durably write its replacement. **Medium, SUSPECTED impact.** Resolve this before the public release.
4. **Signing history eventually outgrows the verifier's accepted file size.** Old export and retention statements accumulate even though the visible event log has a limit. The app can write an export its verifier refuses for being too large. I have not measured how long ordinary use takes to reach this point. Plan a compatible history-bounding solution and a scale test; this alone need not delay 1.12. **Medium, VERIFIED size incompatibility.**

**Release decision:** I would not use this exact snapshot as the final archive for normal TestFlight distribution and App Store submission. Fix issue 2 first. A diagnostic TestFlight build to investigate issue 3 is reasonable; resolve it before the App Store release, and correct issue 1 in the submitted listing and public README. Issue 4 can follow later. I found no additional source-proven blocker in the new set-aside log PIN/deletion flow.

## 2. Findings

### Codex-1 — The public detection guarantee contradicts an acknowledged undetectable action

**Severity: High. Status: VERIFIED.** This is a published-claim defect, not a newly discovered sensor defect.

**What goes wrong and a concrete situation.** The owner leaves an armed phone on battery with the default tripwires. Someone slowly lifts it by its edges, keeping it level, without touching the display or covering the proximity sensor. There is no cable change; Sound and Vision are off by default. Motion below the acceleration threshold with no gravity-vector tilt need not trigger anything. An unchanged-looking log cannot establish that the phone stayed where it was.

**Evidence.**

- `store/APP_STORE_LISTING.md:141`: “your iPhone will either be in the same state you left it, or you'll know it wasn't.” The supplied live listing repeats this at `_LIVE_APP_STORE.md:9`.
- `_PUBLIC_README.md:14` says that movement, handling or approach causes a logged event; its table at line 22 similarly gives an unconditional event outcome.
- `SECURITY.md:1274–1277` expressly acknowledges a slow, level lift below both Motion thresholds. `README.md:965–969` also correctly limits detection.
- `Malinois/Monitors/MotionMonitor.swift:328–338` evaluates gravity-vector tilt and acceleration thresholds. It does not measure displacement. `ProximityMonitor.swift:86–88` requires a transition into near; `PowerMonitor.swift:91–95` requires a power-state change. `Malinois/Models/AppSettings.swift:323–336` supplies the relevant defaults.

**Strongest counterargument.** “Built for one outcome” can describe an aspiration, and the public README later acknowledges thresholds. However, the sentence then says “will,” and the immediate movement-to-event statements are unconditional. The internal security document is clearer than the prominent consumer promise.

**Smallest fix.** Replace the guarantee with: “Malinois helps you discover handling of your unattended iPhone. Enabled tripwires record changes that cross their thresholds while iOS lets the app run. Some handling, including a slow level lift, can go undetected.” Change the README's table condition to “triggers an enabled tripwire,” and its opening behavior statement to the same conditional scope.

**Probe.** A synthetic Motion sample with unchanged gravity and acceleration below the configured threshold must not trip. An optional controlled physical slow-lift exercise demonstrates the limitation, but no new device experiment is needed to establish that the public statement contradicts the source and its own security documentation.

**When:** correct before App Store submission/publication. This issue alone does not require a new binary or block a diagnostic TestFlight build.

### Codex-2 — A failed metadata revision can be silently replaced by older signed facts during Share

**Severity: Medium. Status: VERIFIED by source.** The signature is not forged; the current event and the exported signed snapshot disagree without a warning.

**Concrete situation.** An incident is signed. The owner subsequently enters the correct PIN, and Malinois marks the incident as owner-attributed. The last signing pass containing that update fails, and no later pass successfully signs it before Share. The signing service then recovers sufficiently to sign the export statement. Share sends a ZIP of the older revision, still showing `ownerAttributed: false`, although the selected event is owner-attributed. No new attachment is needed for this discrepancy. Other signed facts, such as wrong-PIN counts or capture-failure explanations, have the same omission in the export check.

Disarming and cloud work can generate multiple writes: **one failure is not guaranteed to survive all of them**. The prerequisite is that the final relevant revision is still unsigned at export time. The proposed probe models exactly that state.

**Evidence and trace.**

1. `Malinois/Services/MonitoringEngine.swift:1739–1755` attributes the disarm-entry events after the correct PIN; `EventStore.swift:2075–2082` changes `ownerAttributed` and persists it.
2. `Malinois/Models/Event+Evidence.swift:47–66`, especially line 57, includes these facts in the signed record. Changing attribution does not change its attachment hashes.
3. `Malinois/Services/EvidenceSigner.swift:572–599` tries the changed revision. On failure, the old revision remains; the comment and control flow defer another attempt to a later write. `exportReadiness` at lines 498–505 does not check whether the current facts are signed.
4. `EvidenceSigner.swift:387–411` accepts a record UUID and signs an export naming the revision already in `records`. It does not refresh the selected event's facts.
5. `Malinois/Services/EvidenceExporter.swift:127–145` compares the selected event's attachments with the latest signed attachments, but never compares `record.evidenceFacts` with `latest.facts`. It then exports that older signed record.
6. `Malinois/Views/EvidenceBundleItem.swift:94–99` captures the event for export. Its `ShareNote.line` at lines 216–223 has no stale-facts outcome: successfully making a ZIP suppresses the failed-ZIP warning.

**Why this matters.** A recipient gets a newly exported, cryptographically valid account that omits a factual correction already made by the app. The event's visible owner-attribution mark and the signed record can tell different stories about whether the handling was the owner's. Verification cannot discover the newer unsigned facts because the bundle contains no comparison with them.

**Design qualification.** `docs/adr/0070-evidence-signings-export-bundle-check-and-verifier.md:160–162` deliberately allows a snapshot while signing catches up. This finding targets a **failed final signing pass**, rather than merely a concurrent edit: the write has reached the signer, failed, and Share can continue exporting the old facts without retrying or warning. Requiring current facts to match is my recommendation about the cost of that design; it does not imply that the verifier authenticates anything other than the older statement it actually received.

**Smallest fix.** In `EvidenceExporter.assembled`, require both `latest.facts == record.evidenceFacts` and matching attachments. On mismatch, return no bundle so the existing unsuccessful-ZIP notice is used. A later improvement can request a retry of the current revision; it must not sign arbitrary UI state without the normal durable-log path.

**Proposed regression, not run.** Add inside `Item90ExportTests`, using its existing helpers and local fake key service:

```swift
func testShareDoesNotExportStaleFactsAfterSigningFailure() async throws {
    let (signer, keys, _) = try makeSigner()
    await signer.certifyIfNeeded(records: [])
    var record = trip(1)
    await signer.logWritten(generation: 1, events: [record])

    record.ownerAttributed = true
    await keys.failNextAssertions([DCError(.unknownSystemFailure)])
    await signer.logWritten(generation: 2, events: [record])

    let made = try await exporter(signer).folder(
        of: record, log: [record], in: out
    )
    XCTAssertNil(made, "Do not share old signed facts as the current event")
}
```

Current source should return a URL and fail that final assertion. For a diagnostic version of the test, inspect the returned bundle using the existing test `check` helper and compare its latest record's `ownerAttributed` fact with the selected event. Then add a successful subsequent signing pass and verify that export becomes available with the corrected fact. `Item90ExportTests.swift:480–498` currently tests changed attachments, not this metadata-only failure.

**When:** fix before the release archive and normal TestFlight distribution.

### Codex-3 — Journal cleanup replaces still-needed, flushed events without a replacement durability barrier

**Severity: Medium. Status: SUSPECTED evidence-loss impact.** The missing barrier and reachable ordering are verified by code; actual loss following power failure is not demonstrated.

**Concrete situation.** Event A's full log write has reached disk, so its journal entry may retire. Before A's retirement runs, event B is born and its journal append is fully synced. B's full log write is still pending or in progress. A's retirement sees B as a survivor and atomically rewrites the journal to contain B alone. That replacement is not explicitly synced. A sudden loss of power at this point may therefore find neither a durable full-log B nor the durable journal copy that originally protected B.

**Evidence and ordering.**

- `Malinois/Services/EventStore.swift:281–295`: birth append precedes queued persistence.
- Lines 1624–1657 and 1681–1691: append uses `F_FULLFSYNC` before proceeding.
- Lines 1806–1837: checkpoint sync runs on the file queue, then posts retirement separately to the main actor. B can be appended while A's sync runs; B's queued write and A's main-actor retirement can then proceed independently.
- Lines 1845–1862, particularly 1857–1860: nonempty survivors are written using `[.atomic, .completeFileProtectionUnlessOpen]`. There is no subsequent full-sync, and the original journal has been replaced.
- Lines 2794–2813: the full snapshot for B is encoded and written asynchronously; nothing in retirement waits for B's write.

Apple describes atomic Data writing as writing an auxiliary file and replacing the original; it describes buffered writes and explicit synchronization separately. Atomic replacement alone is not the explicit persistence barrier used on the birth path. See [Apple's NSData writing options](https://developer.apple.com/documentation/foundation/nsdata/writingoptions) and [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes). Apple also says even full-sync is a best-effort expectation, so this report does **not** claim a fix can guarantee survival of every power failure.

**Why this is not yet a verified loss finding.** Actual post-reboot contents depend on filesystem behavior, timing and failure mode. A process kill followed by reading the file from the same running OS cannot prove power-loss persistence. The existing general warning about abrupt power loss is appropriate, but does not explain why cleanup weakens the specific birth-write barrier the app just paid for.

**Smallest conservative fix.** Leave the original journal untouched when unretired survivors remain; retire it later when a durable snapshot covers them all. If compaction during a continuous stream is needed, use a protected temporary journal, fully sync its survivor bytes before publication, and preserve the original on failure. Review rename/directory durability separately rather than treating `.atomic` as a disk flush.

**Proposed probe, not run.** In a scratch test copy, add explicit hooks around A's completed full-log sync and B's queued full-log write. Pause A before it schedules main-actor retirement; append and full-sync B; release A while holding B before its full-log write. Let A's retirement run. Trace writes/syncs/replacements and assert that B's only flushed journal copy is not replaced by unflushed bytes. Then test failure of the replacement sync and require that the old journal remains usable. This deterministically tests the ordering invariant. Confirming actual loss additionally requires a controlled physical-device power-loss experiment with dummy events; no such experiment was performed.

`MalinoisTests/StoredJSONTests.swift:90–108` proves an unpersisted survivor is readable after compaction, and `EventTests.swift:1544–1563` checks sync counts around appends and eventual deletion. Neither proves durability of the replacement containing that survivor.

**When:** resolve before App Store release. A diagnostic TestFlight build is suitable for validation. A conservative preservation change is preferable to claiming an unrun power-loss test passed.

### Codex-4 — Unbounded signing history eventually produces bundles the verifier refuses

**Severity: Medium. Status: VERIFIED size-contract incompatibility; practical onset unmeasured.**

**Concrete situation.** An installation accumulates enough exports and retention statements over its lifetime. The owner shares a recent event. Even though the local event log stays within 500 incidents and 100 status entries, the export carries the retained lifetime signature history. Once `signatures.jsonl` exceeds 67,108,864 bytes, the verifier rejects it as too large. A successful ZIP creation does not warn the owner about this recipient-side failure.

**Evidence.**

- `Malinois/Services/EvidenceSigner.swift:684–691`: every export statement is retained with `record: nil`, expressly so record retirement cannot remove it.
- Lines 773–805: retiring records adds a retention statement and drops the selected records' signatures, not the accumulating statements.
- `MalinoisTests/Item90ExportTests.swift:107–123` explicitly checks that previous export statements are kept.
- `Malinois/Services/EvidenceExporter.swift:90–122`: every remaining signature enters each bundle; representing old exports by hashes still writes a signature line for each.
- `MalinoisEvidence/EvidenceBundle.swift:264–271`: the writer appends the entire signature list without a corresponding file-size guard.
- Lines 513 and 734–750: the reader's limit is `1 << 26`; larger files are refused.

**Counterweight.** This needs a large accumulated history. I did not measure line-size distributions, export latency, memory use, event rates, or time to onset. It is not evidence that a typical present installation is near the limit, and it is not a reason to remove the verifier's defensive size bound blindly.

**Smallest immediate fix and durable solution.** Share should detect that its bundle would exceed the reader's supported limits and provide an accurate failure explanation. Restoring long-term functionality needs either compatible bounded/streaming verification or a signed checkpoint/compaction scheme that explains the history it omits. Simply deleting historical signatures creates unexplained counter gaps; merely raising the cap postpones the problem.

**Proposed probe, not run.** Use the local fake-key fixtures to construct a consistent export history with a small current event set and enough retained export/retention statements to cross the exact byte limit. Pass it through the real bundle writer and checker. Assert that the writer either refuses with an owner-visible reason or produces a bundle the checker accepts. Test immediately below and above the limit, and measure resource use. No Apple service or real evidence is needed.

**When:** later, with an explicit lifetime-scale regression; no independent 1.12 archive blocker without evidence of near-term onset.

## 3. Wrong claims in the documents

**Consumer detection promise — Codex-1.** Correct `store/APP_STORE_LISTING.md:141`, `_PUBLIC_README.md:14` and its line-22 table result. Use the conditional wording in that finding. The supplied live snapshot confirms that the stronger listing claim is public; I did not modify or publish any text.

**A write reaching the signer is not enough to guarantee its edit appears in the bundle — Codex-2.** `docs/adr/0070-evidence-signings-export-bundle-check-and-verifier.md:160–162` says an edit is in the bundle once its log write reaches the signer. That omits signing failure. Until the implementation is fixed, accurate wording is: “The bundle contains the latest successfully signed revision. If signing an updated record fails, its ZIP can contain older facts than the selected event.” With the recommended guard, use: “A ZIP is sent only when the selected record's facts and attachments match its latest signed revision; otherwise Share says that it could not make the signed ZIP.”

I do not treat the documented limitations of Guided Access, sensor thresholds, notification delivery, an altered backup before signing, key lineage without prior knowledge, or power-loss guarantees as undisclosed defects. In particular, `docs/adr/0080-share-says-when-it-went-without-the-signed-zip-and-waits-a-minute-for-it.md` candidly explains that the share deadline does not free a stalled signer, and that a main-thread callback might wait on the making lock. Those remain device-validation concerns; I did not establish a new hang from source alone.

## 4. Where I went

The starting hypotheses were lifecycle/PIN bypass, account-switch leakage, misleading or forgeable exports, and destructive cleanup of partially readable logs. Follow-up work concentrated on state transitions between durable storage, signing and sharing rather than repeating the successful suite.

**Controls that looked sound in the paths examined:**

- PIN verification fails closed on unavailable credentials; guessing limits live in the service. Biometrics are restricted to the intended read/test screens, bound to enrolled biometrics and to the outstanding request. Backgrounding closes authenticated areas. Recovery cancellation and set-aside deletion remain PIN-only.
- Set-aside deletion asks for a new PIN, waits for that pad to close before confirmation, clears authorization on background, and does not take a previous Event Log unlock as deletion authority. Its file work distinguishes regular files, absent paths and inspection failures; it checks current memory, disk, capture intents and other set-aside logs before removing media. The strict UUID media-name rule and JSON escape search address the screen/search mismatch directly. I found no new bypass in those paths.
- Cloud work uses the private database, installation enrollment and per-event account bindings, and invalidates leases across account changes. New events recorded with backup off are held locally. First-hand records are not replaced by cloud mirrors. Full-media downloads check the signed bytes under the signing turn. Retention uses conservative time and age checks.
- The evidence verifier checks App Attest bindings and cryptographic signatures, strict forms, counters, disclosed statements, attachment hashes, file inventory and archive structure. I found no new way to make edited signed bytes pass those checks. Its declared inability to establish that a photographed scene or pre-signing local record is true is a different issue.
- The notification extensions avoid fetching private evidence. The watch relay sends generic event identifiers/kinds/times, not photos. The bounded wake handoff and notification-list budget are visible in source.

**Tests inspected, not rerun:** PIN/biometric and engine characterization tests; new `Item122SetAsideLogTests`; event/journal and `StoredJSONTests`; account/enrollment/transfer tests; export/signature/bundle/verifier fixtures; and watch wake tests. The supplied suite is substantial and includes integration and hosted SwiftUI views. It would be inaccurate to dismiss it as only pure-function tests.

**Specific blind spots:** the export currentness regression changes attachments but not facts after a failed signing pass; journal tests read replacement bytes back without establishing their durability. The new deletion tests host the actual PIN view, but invoke the confirmation action through Debug instrumentation (`OnScreenText.swift:48–55,139–148`; `Item122SetAsideLogTests.swift:2152–2177`). They do not replace a Release-device exercise of native confirmation dismissal and background ordering.

**Not established here:** physical Guided Access/biometric behavior, an actual sudden-power-loss result, real App Attest failure/recovery timing, production CloudKit schema and account-change behavior, real push/watch delivery, runtime behavior of hostile archives at scale, and App Review's decision. No new simulator was created and no existing simulator was touched. The test probes are intentionally disclosed as unrun; no claimed PASS rests on them. This was a focused independent source review, not exhaustive coverage or a reproduction of the release gate.
