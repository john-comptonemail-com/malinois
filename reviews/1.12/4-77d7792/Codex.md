# Codex — independent adversarial review of Malinois 1.12 (87)

**Reviewer:** Codex (GPT-6)  
**Date:** 2026-11-11  
**Candidate:** the supplied snapshot (the review folder); revision label `77d7792` supplied by the review prompt. I did not use Git to establish or inspect history.  
**Tests run:** none. No test summary lines exist. No simulator was created, booted, erased, or used; no release suite was repeated. A small native Swift probe was prepared in my scratch space, but its launcher failed while setting memory resource limits, before `swiftc` or target code executed (`current limit exceeds maximum limit`). Runtime containment could not be established under the security-audit skill's rule, “If every control cannot be enforced, do not execute target code.” Source findings below are distinguished from unconfirmed device behavior. The regression probes are specified below, including one test to add to the supplied test class in a disposable copy.

I read `_REVIEW_PROMPT_OPEN.md` first. `_REVIEW_PROMPT.md`, other reviewers' reports/notes, other review folders, repositories, and prior memories were not read. Within the supplied folder, my only write is this report. Focused review agents contributed to this one review; candidate findings were challenged independently before inclusion. External research was confined to Apple's public documentation.

## 1. For the owner, in plain English

**I found two definite ways the event screen can put the wrong camera name above a picture. I did not establish a way around the Malinois PIN, a way to upload evidence to the wrong account, or a way to forge a passing evidence bundle.** The two confirmed problems concern what the owner sees; they do not alter the correctly stored photo files or their signatures.

The new set-aside-log deletion work looks careful. In particular, opening the log with a face or finger does not grant deletion, backgrounding revokes the pending deletion steps, and uncertainty about other references preserves photos rather than deleting them.

My release decision is to **fix Codex-1 and Codex-2 before archiving the release candidate**, then run the focused regressions and use TestFlight to check the actual screens. I would not submit this exact candidate to the App Store with the approved claim that downloaded photos no longer appear under the wrong camera. A diagnostic TestFlight build for reproducing these issues is reasonable; that is different from approving this candidate for release. These are narrow, Medium-severity corrections, not evidence that the overall protection model is broken.

Problems and next actions, in priority order:

1. **Codex-1 — VERIFIED, Medium:** a photo still loading can finish after the screen has changed to another camera, putting the old picture back under the new camera name. Ignore results from obsolete image loads. Fix before archive.
2. **Codex-2 — VERIFIED, Medium:** for an older cloud record, downloading only its rear picture can give its existing front thumbnail a rear-camera label once the downloaded full picture is removed by the local storage limit. A thumbnail needs its own known camera identity, or a neutral label. Fix before archive.
3. **Codex-3 — SUSPECTED, Medium:** the one-minute Share escape does not cover everything that happens before the share sheet opens. In a specific recovery case, it can wait on signing first. Run the stalled-service probe; extend the deadline to that preparation step if confirmed. This is not a claim that ordinary shares hang. It can follow this release if the two confirmed display defects are fixed.
4. **Codex-4 — SUSPECTED, Medium:** a siren that started successfully may not recover when iOS stops its audio without the expected “interruption ended” message. Test a real audio interruption/reset, with no new tampering to restart it. Later work on present evidence; elevate it if a device demonstrates silent continued protection.

The deletion-to-status-entry crash window and the missing status entry for “Free up iCloud space” are already disclosed in the prompt. I did not count them as discoveries or make them new release conditions.

## 2. Findings

### Codex-1 — An obsolete image decode can replace the current camera's picture

**Medium — VERIFIED by source control flow. Before archive.** No SwiftUI runtime reproduction was run; the finding is the unchecked obsolete result assignment and its reachable update path, not a measured frequency.

**What goes wrong.** `EvidenceMediaView` starts loading whenever its URL changes. Its previous task may be canceled, but the actual decode runs in a detached task, and the old caller assigns the result without checking cancellation or whether that URL is still current. The store's new camera-slot correction therefore does not ensure that the image currently drawn belongs to the corrected slot.

**Concrete situation.** The owner opens an older mirrored record that has a valid thumbnail but no camera labels—the legacy case the existing Item201 tests cover. A partial download brings only its rear photo. The receiver temporarily puts it in the first slot, labeled Rear, and begins decoding it. While that decode is outstanding, newer metadata arrives naming Front first and Rear second. The store correctly moves the rear file to the second slot. The new first-slot load clears its image because the front file is absent, or loads a front file. The older rear decode then finishes and assigns the first slot's image again. The owner can now see the rear picture under **Front camera**, until another load replaces it.

This needs neither unauthorized cloud access nor leaving the event screen. A later ordinary event on the source phone can push a refresh of recent records, including the older record currently being viewed if it remains within the fetched page. The metadata modification alone does not trigger the creation-only subscription.

**Evidence.** All paths below are relative to the supplied folder:

- `Malinois/Views/EventDetailView.swift:64`: the screen uses the live store's version of the event.
- `Malinois/Views/EventDetailView.swift:173–183`: camera labels and the primary/secondary media views are composed separately. The primary view stays in the same position across this change.
- `Malinois/Views/EventDetailView.swift:424`: `.task(id: url)` starts the load.
- `Malinois/Views/EventDetailView.swift:433–445`: a new load clears `image`; an old load awaits `Task.detached(...).value` and then unconditionally assigns `image`. There is no cancellation or request-generation check. [Apple documents that task cancellation is cooperative](https://developer.apple.com/documentation/swift/task/cancel%28%29); it does not suppress an unchecked completion.
- `Malinois/Services/EventStore.swift:418–449`: the newer metadata moves the rear file to the correct secondary slot; this part is sound.
- `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:337–348,616–625`: the unlabeled record can first adopt the rear download in its primary slot.
- `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:48–56,289–310` and `Malinois/Services/CloudExfiltrator.swift:1496–1503`: a remote push refreshes recent records and merges them, without requiring the detail screen to close.
- `MalinoisTests/Item201MirrorCameraTests.swift:testALaterRecordKeepsADownloadedFilesCamera`: the supported legacy seed has a thumbnail, so the Download affordance is reachable. Those tests check file placement, not a decode completing after placement changes.

**Smallest fix.** Await into a local result, then check `!Task.isCancelled` before publishing it. Also bind publication to a load generation/URL if the loader can be called outside the `.task(id:)` lifecycle. Do not let a canceled caller clear or overwrite a newer result. The same rule should apply if the image loader is later refactored.

**Probe to run.** In a disposable copy, give the decoder a test-only gate and host the real `EvidenceMediaView` in SwiftUI. Use visibly different valid JPEGs, not the four-byte JPEG marker used by some storage tests. Hold rear decode A after it reads its input; change the primary URL to nil, let load B finish, then release A. Assert that the primary view stays on its correct fallback/placeholder. Repeat with B loading a front photo and completing before A. Run the whole legacy-download → metadata-merge sequence once through `EventDetailView`, and check the rendered image beneath each label. A correct test must control completion order rather than hope a large image happens to decode slowly.

**Impact boundary.** Wrong presentation of surviving evidence, potentially misleading the owner's understanding of which camera saw a person. This does not show a forged signature, wrong file reassignment, or data crossing accounts.

### Codex-2 — A legacy thumbnail can acquire a camera label belonging to a different download

**Medium — VERIFIED by source control flow. Before archive.** This is a separate defect from Codex-1; preventing stale async completion does not fix it.

**Concrete situation.** An older cloud record holds the source phone's front-camera thumbnail, but its old metadata has no camera labels. Its thumbnail makes Download available. A partial download succeeds only for the rear photo. The receiver assigns that photo to the first unnamed slot and labels it Rear, while preserving the original front thumbnail. Initially the full rear photo hides the mismatch. Later the ordinary local media-size limit removes the cached full rear photo. The camera label and thumbnail remain. The event screen now displays the original **front** thumbnail under **Rear camera**. The thumbnail-only badge identifies reduced resolution, not the wrong camera identity.

**Evidence.**

- `Malinois/Models/Event.swift:235–240`: an existing thumbnail is enough to establish that a mirrored event can offer a full-media download. This scenario does not use an unreachable empty cloud record.
- `Malinois/Services/CloudExfiltrator.swift:1261–1287,1298–1332`: legacy records can decode with a thumbnail and no camera labels.
- `Malinois/Services/CloudExfiltrator.swift:1667–1683`: partial full-media results can contain the rear photo alone.
- `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:337–348,616–618`: the download adopts the first slot and sets its camera, but replaces the thumbnail only when the old thumbnail is nil. No thumbnail-camera provenance is stored.
- `Malinois/Services/EventStore.swift:1866–1873`: attaching a downloaded file schedules the byte-limit check.
- `Malinois/Services/EventStore.swift:1281–1295`: eviction clears the file references and preserves both camera labels and thumbnails.
- `Malinois/Views/EventDetailView.swift:173–177,405–419`: the primary camera label is shown above the fallback thumbnail.

**Smallest complete fix.** Label a fallback thumbnail neutrally when its camera has not been established independently of the full file. A fuller fix tracks thumbnail provenance and reconciles it when downloads and metadata change slots. Simply replacing the thumbnail during download is not sufficient on its own: later metadata can move that downloaded camera to another slot, so thumbnail inheritance must follow the same identity rules too.

**Probe test to add to `Item201MirrorCameraTests` in a scratch copy.** This uses the class's existing isolation, `mirror` helper, and engine setup pattern. `Item105ImageDecodingTests.jpeg` supplies real decodable fixtures. The final assertion expresses the existing model's required invariant; a UI fix using explicit neutral provenance should instead assert the corresponding rendered label.

```swift
func testLegacyThumbnailDoesNotBecomeAnotherCamerasFallback() async throws {
    let store = EventStore()
    store.mediaBudgetForTesting = 1
    let engine = TestIsolation.track(MonitoringEngine(
        settings: AppSettings(), eventStore: store,
        cloud: CloudExfiltrator(), camera: FakeCamera(),
        entitlements: ProEntitlements(resolvedAs: .trial),
        timing: EngineCharacterizationTests.fastTiming))

    let frontThumbnail = try Item105ImageDecodingTests.jpeg(width: 16, height: 16)
    var legacy = mirror(revision: 2)
    legacy.thumbnailData = frontThumbnail
    legacy.cloudSyncState = .synced
    XCTAssertTrue(legacy.fullCaptureMayBeInICloud)
    store.merge([legacy])

    let rear = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".jpg")
    try Item105ImageDecodingTests.jpeg(width: 32, height: 16).write(to: rear)
    defer { try? FileManager.default.removeItem(at: rear) }
    engine.fullMediaFetchForTesting = { _, _ in
        CloudExfiltrator.FullMediaFetch(media: [
            CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)
        ], complete: false)
    }
    let result = await engine.downloadFullEvidence(for: legacy.id)
    XCTAssertTrue(result.landed)
    let deadline = ContinuousClock.now + .seconds(3)
    while !store.byteCapPruneIdleForTesting, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(store.byteCapPruneIdleForTesting)
    let held = try XCTUnwrap(store.events.first { $0.id == legacy.id })
    XCTAssertNil(held.mediaFilename, "the deliberately tiny cache limit ran")
    XCTAssertFalse(held.primaryCamera == "rear" && held.thumbnailData == frontThumbnail,
                   "a front thumbnail must not be presented as rear evidence")
}
```

This test is **provided, not executed**. The expected current failure is its last assertion. A screen assertion should additionally verify the label attached to the fallback. The file eviction itself is intended behavior; the defect is the resulting mislabeling.

### Codex-3 — Share's preparation can wait before the one-minute deadline exists

**Medium — SUSPECTED user-visible hang; VERIFIED absence of a bound on this control-flow path. Later, unless the targeted probe establishes a practical release problem.**

**Concrete situation.** During initial recovery, the signature file or Keychain list cannot be read, so the signer keeps a comparison for later. Those become readable, and the owner taps Share before another path has performed that comparison. Share resumes it. The comparison needs an App Attest assertion or a replacement-key certification, which stalls. The share sheet has not opened yet, and the one-minute item deadline has not started.

**Evidence.** `EventDetailView.swift:144–151` awaits the offer before presenting the sheet. `EvidenceBundleItem.swift:93–99` awaits `exportReadiness` before creating the item. `EvidenceSigner.swift:498–500` resumes `passWhatWasKept`; `368–372` and `353–361` run the deferred pass, whose signing reaches `587,624,667` and possibly certification at `319`. The deferred state is stored at `527–530`. None of this preparation is covered by `EvidenceBundleItem.wait`'s timeout. `Item90SignerTests.swift:3287–3296` already explicitly models Share being the first successful retry of that deferred comparison.

**Counterevidence and limit.** A merely slow ordinary signing pass does not imply this problem: `passKept` may be nil and `passing` prevents duplicate passes. Foreground recovery often consumes the deferred work first. I have not observed a real App Attest stall or this timing on a phone. ADR 0080 already acknowledges that a stuck App Attest operation can hold the signer; the additional point here is that it can be awaited before the sheet's deadline exists.

**Smallest fix.** Bound readiness preparation as well, allowing ordinary sharing with `.notNow` if preparation exceeds the bound. Let any already-started signature finish under the existing accounting rules; do not manufacture a timeout by throwing away an unaccounted signature.

**Confirming probe.** With the existing `FakeKeyService` and `TestKeyList`, certify/sign event A, create a fresh signer over the same file/list, fail the list's next read, and submit a changed A so its comparison is deferred. Hold the next assertion. Start `EvidenceBundleItem.offer`; establish that the fake assertion was requested, then check whether the offer remains incomplete beyond `makingLimit + 1` seconds. Release and drain the held assertion in cleanup. Helpers already exist in `EvidenceTestSupport.swift:435–448,472–478` and `Item90SignerTests.swift:3967`. Then verify a bounded implementation opens the ordinary share without its ZIP. This isolates the missing timeout; a separate device observation would establish practical likelihood.

### Codex-4 — A successfully started siren has no general recovery path for an unpaired audio interruption/reset

**Medium — SUSPECTED. Later/device validation, not a proven PIN bypass or release blocker.**

**Situation to check.** Start the siren, then let iOS interrupt or reset its audio. Return to the app while the alarm is still owed, without another sensor trip. If iOS provides no interruption-ended message, the code may remain silent without recording the failure.

**Evidence.** `SirenPlayer.swift:89–106` observes interruption and route changes but not media-services resets. Its interruption handler restarts on `.ended` only (`478–497`). `ensureSounding` can restart a stopped player (`199–203`), but the normal foreground path does not call it (`MonitoringEngine+Screen.swift:62–123`). Renewed tampering does (`MonitoringEngine.swift:1540–1546`), so the probe must avoid that confounder. The activation-failure notice covers failed starts, not a later loss of a successfully playing object (`SirenPlayer.swift:325–342`).

Apple documents that interruption begin/end messages need not pair and that apps should reconsider activation on foreground. It also describes recreating audio objects after a media-server reset. See [Apple: Responding to Interruptions](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html).

**Confirming probe and fix.** Use a disposable physical-device installation and a sufficiently long-lived owed alarm; cause an actual interruption/reset and observe sound plus the event log before the normal alarm expiry. A synthetic notification alone is insufficient. If confirmed, reconcile owed playback on foreground and handle reset/lost-player state, retrying or reporting failure. Do not claim the app can force iOS to release audio that another system function still owns.

## 3. Wrong claims in the documents

**The approved 1.12 camera claim is too broad as implemented.** `store/APP_STORE_LISTING.md:259` says a downloaded photo “no longer shows under the wrong camera after that device updates the event.” The file reassignment now works, but Codex-1 still allows the rendered photo to be wrong after that same update. This is candidate submission copy, not a claim that the live 1.11 listing contains this sentence.

My preference is to fix the display race and keep the approved user-facing claim. If a code fix is deferred, narrower accurate wording is: **“Downloaded photo files stay attached to their cameras when another device updates an event.”** That wording still does not excuse the display defect.

I did not identify another definite false claim in the portions reviewed. In particular:

- `SECURITY.md:331–333` starts its ZIP timeout promise when a destination is picked. Codex-3 does not disprove that precise statement; it exposes an earlier wait. An additional accurate limitation would be: “Preparing the share sheet may first wait for a deferred signing comparison; that preparation is not covered by the ZIP's one-minute timeout.”
- The signing documentation discloses clock, device-identity, edited-backup, counter-reset, unsigned-note and restore limits. I did not relabel those disclosed boundaries as forged-evidence defects.
- The set-aside export's own README explicitly distinguishes it from signed evidence. The privacy policy's set-aside retention exception matches the preservation rule inspected.

## 4. Where I went, and what remains unproven

**Starting hypotheses.** I looked for authority accidentally carried from biometric reading into deletion/disarm; monitoring that silently stops across lifecycle transitions; cloud results accepted after account or event identity changes; evidence restored or exported under the wrong signature; and corruption cleanup that deletes still-referenced media. The image findings emerged from following the camera identity across the store, cache and rendered view, rather than stopping at the new merge function.

**Controls that held up in source review.**

- PIN-only disarm; verifier-owned rate limiting; biometric access limited to read surfaces; rejection of late biometric callbacks; background closure of protected navigation.
- Set-aside deletion's fresh PIN and confirmation, background revocation, restrictive stored filenames, escaped-name search, refusal of links/directories, and reference checks across memory, disk, other set-aside logs and pending attachment intents. Failure/uncertainty preserves media and produces a notice.
- Journal retirement after successful full-log sync, deferred media deletion when persistence fails, and conservative orphan sweeping when set-aside artifacts remain.
- Cloud enrollment independent of Pro/PIN recovery, event-account bindings, invalidated operation leases, and post-await checks before downloaded media joins a row. Cloud mirrors do not replace first-hand events.
- Export comparison of current supplied facts and attachment digests with the latest signed revision; verification of copied attachments; cryptographic key/statement checks; counter accounting; archive/path/extra-file checks and terminal-output escaping. I did not find a new passing-bundle forgery in these paths.
- Generic notification contents rather than private event fetches in the extensions; Watch wake limits and pairing logic. The remaining delivery limitations are documented.
- Source-level release entitlements, purpose strings and privacy manifests. I found no concrete App Review rejection condition; this was not an inspection of an archived signed binary or live container configuration.

**Rejected lead, retained here to make the evidence limit clear.** An initial theory used a completely empty sparse cloud record to start a rear download, then retain a wrong locally generated thumbnail across a richer merge. It failed a real UI guard: with no thumbnail, camera, file or manifest, `fullCaptureMayBeInICloud` is false and Download is hidden. I withdrew it. Codex-1 and Codex-2 use the supported legacy record with an existing thumbnail and do not depend on that impossible first tap.

**Review/testing blind spot.** The relevant tests establish storage identities, but not the image actually rendered after a canceled decode or the identity of the thumbnail left after cache eviction. Some integration fixtures are only JPEG marker bytes and therefore cannot expose a successfully decoded wrong image. Add at least one controlled asynchronous SwiftUI presentation test with distinguishable, valid pictures. The large passing suite is useful evidence about what it tests, not proof of this cross-layer invariant. Likewise, paired synthetic audio interruption tests cannot establish what happens when iOS omits the end notification.

**Limits.** This was a focused adversarial source review, not exhaustive coverage. No app/test execution, signed archive inspection, physical iPhone/Watch operation, real App Attest certification, account switching, CloudKit delivery, audio fault, or App Review submission occurred. The supplied gate results are background information, not runs I performed. I did not validate every sensor threshold or every release-tool path. The review left external service availability and device-dependent behavior unresolved rather than treating them as proven vulnerabilities.
