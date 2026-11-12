# Codex — independent adversarial review

**Date:** 10 November 2026  
**Target:** Malinois 1.12 (87), supplied snapshot `7f1da10`  
**Tests run:** None. No app build, simulator, release suite, or macOS test suite was run. There are no test-summary lines to report. VERIFIED below means a complete, deterministic source path, not a reproduced device session. Proposed regression probes are explicitly marked unrun.

I read `_REVIEW_PROMPT_OPEN.md` first. I did not read `_REVIEW_PROMPT.md`, other reviewers' reports or notes, another checkout, or earlier review material. I used the supplied source and documents, plus Apple's public documentation. I did not run any git command. The only change to the supplied folder is this report. Focused analyses within this Codex review were cross-checked before consolidation.

## 1. For the owner, in plain English

The app has substantial protection against the obvious attacks. I found no proven way around its PIN, no proven upload to the wrong account, and no proven way to make the verifier accept altered signed evidence. That is a bounded review result, not a guarantee.

The most important problem is what happens when evidence comes back from iCloud only partly. The loading message disappears and the remaining log is shown without telling you that some of the history could not be retrieved. Some unreadable records are even counted internally as a completed restore. That matters if you reinstall after an incident and rely on the restored log to decide what happened.

My findings, in priority order:

1. **High, VERIFIED — a partial iCloud restore leaves no visible warning.** Keep the successfully recovered events, but leave a clear “restore incomplete” notice and a retry control. Count unreadable records separately instead of treating their omission as success. Fix before the release archive.
2. **Medium, VERIFIED — an old event's front-camera preview can be labelled “Rear camera.”** If only the rear photo downloads, then the local storage limit removes that downloaded file, the app can display the old front preview under the new rear label. Keep each preview tied to the camera that produced it. This is an edge case in older cloud records; it can follow in a maintenance release, although the fix is small enough to take now. No original photograph or signature is changed by this bug.
3. **Medium, SUSPECTED — sharing may freeze the screen while the ZIP is being prepared.** Two callbacks share a lock, and one holds it for up to a minute. The code proves what happens if they overlap; I did not establish that iOS invokes them in that order on a device. The decision record already acknowledges this uncertainty. Run a deliberately delayed Share test on a phone; fix before release if it reproduces.

**Release judgement:** I would allow a diagnostic TestFlight build to exercise these cases. I would not sign off 87 as the final App Store candidate until finding Codex-1 is fixed and the associated claim in `SECURITY.md` is accurate. Codex-2 can be tracked for a later maintenance release if explicitly accepted. Codex-3 is a device-validation item, not a demonstrated release-blocking failure. After the fix, run the targeted regression probes and the normal release gate on the changed candidate; repeating the already-passed full suites on this unchanged snapshot would add little.

## 2. Findings

### Codex-1 — Partial cloud restores are silent; decode omissions can also settle an incomplete restore

**Severity:** High. **Status:** VERIFIED by source. **Timing:** Before the release archive.

This is a recovery-status defect, not deletion of the cloud originals. The High rating reflects a normal transient-failure scenario and a published assurance that the code does not meet.

**Concrete situation:** The owner reinstalls after an incident, verifies iCloud, and waits for restoration. One query or individual record fails while other records succeed—for example, the network is available but a CloudKit operation fails. The good records enter the log. The restoration spinner stops. Neither Home nor the Event Log says that the recovered history is incomplete. The owner can mistake the visible subset for the available history.

A second route needs no CloudKit transport failure: a fetched record has a missing identifying field, or an unfamiliar status kind from another version. Rejecting that record is sensible. Silently calling the restore complete is not.

**Evidence and chain:**

- `Malinois/Services/CloudExfiltrator.swift:1544–1579`: `fetch` retains successful partial results. Transport/per-record failures affect `ok`, but at lines 1565–1568 a successful `CKRecord` whose decoder returns nil is simply omitted. That omission does not affect `sawRecordFailure` or the returned success at line 1574.
- `CloudExfiltrator.swift:1261–1265` rejects missing UUID/date data. Lines 1432–1455 reject unrecognized status kinds. These are accepted fetch results that can take the silent-omission path; the problem is not the rejection itself.
- `CloudExfiltrator.swift:1504–1505` derives `lastFetchComplete` solely from those fetch success flags.
- `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:300–322` returns and merges the valid subset with its completeness flag. Lines 25–36 stop the in-progress state unconditionally and clear an owed restore when that flag is true. Thus decode omissions can wrongly retire the restore obligation, whereas a transport failure correctly retains it.
- `Malinois/Views/HomeView.swift:433–441` displays restoration status only while `cloudRestoreInProgress` is true. `Malinois/Views/EventLogView.swift:216–225` ends refresh without presenting its pull result. Inspection of all production uses of `lastFetchFailed`, `lastFetchComplete`, and `cloudRestoreInProgress` found no persistent owner-visible partial-restore outcome. The offline banner concerns uploads and does not cover a CloudKit failure while the network remains online.
- `Malinois/Services/MonitoringCloudCoordinator+LaunchPull.swift:25–31`: once the obligation is cleared and the log is nonempty, routine launches ask for the smaller page limit. An older omitted record that later becomes readable need not be reached by that routine pull.
- `SECURITY.md:1400–1403` promises that retrieval and restore disclose incomplete checks and offer a retry rather than presenting a partial result as the whole story. Full-media download has more explicit outcome handling; the event-log restore does not.

**Smallest effective fix:** Carry an explicit restore outcome through the coordinator to Home/Event Log: completed, partial due to failures, and partial due to unreadable/unrecognized records. Retain the valid events. Keep an incomplete notice until a successful retry or an explicit acknowledgement, and distinguish “retry” from “update the app” where appropriate. Do not clear the owed restore merely because every CloudKit callback was a success. A skipped-record counter or retained unresolved record IDs would avoid silently losing the obligation. Do not turn unknown status kinds into fabricated events.

**Regression probes to add — not run:**

1. Through `readSubmitForTesting`, answer a metadata query with one valid record and one `.success(CKRecord)` containing a valid `eventID` but no `startDate`. Answer the remaining record-type queries successfully with no records. Assert the valid event remains, the result reports one unreadable record, and `lastFetchComplete` is false. Repeat with a valid UUID/date but an unknown status `kind`.
2. On a store with `restoreOwedSince != nil`, drive the above result through `restoreFromCloudAtLaunch`. Assert that the restore obligation remains after completion.
3. Independently use the existing `cloudFetchForTesting` seam to return one valid mirror and `complete: false`. Complete restoration and render Home and the Event Log. Assert an incomplete-restore notice and retry action remain after the loading indicator ends. Repeat with a real per-record CloudKit failure in the read seam. The current implementation has no such visible outcome.

### Codex-2 — Downloading a rear-only legacy capture can relabel a front thumbnail

**Severity:** Medium. **Status:** VERIFIED by source. **Timing:** May follow in a maintenance release; preferable to fix now.

**Concrete situation:** The receiving phone holds an older Both-camera event. It has a valid thumbnail from the front camera, but no camera labels or downloaded files—the legacy shape the decoder and existing tests support. The owner taps Download. Only the rear photo comes back because the front fetch fails. Later, or immediately on a full cache, the 2 GB local-media limit evicts that downloaded rear file. The detail screen now shows the old front thumbnail underneath “Rear camera.”

**Evidence and chain:**

- `Malinois/Models/Event.swift:223–237` makes the legacy event eligible for download because its thumbnail proves that a capture exists. This starting state is reachable through the UI; it is not the thumbnail-free empty stub that the UI refuses to download.
- `Malinois/Services/CloudExfiltrator.swift:1343–1348` supports legacy metadata with a thumbnail and absent camera labels. Its full-media retrieval probes known camera record names when no manifest is available (`1609–1612`) and can return the successful rear asset alongside a failed front fetch (`1666–1682`).
- `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:341–347` places the known rear camera in an unnamed primary slot. At lines 616–618, the download assigns its filename and rear label but replaces the thumbnail only if the old thumbnail is nil. The existing front preview therefore survives.
- The download is subject to immediate cache pruning (`MonitoringCloudCoordinator+Transfers.swift:483–485`). `Malinois/Services/EventStore.swift:1276–1279` clears the evicted media filenames, leaving the camera label and thumbnail in place.
- `Malinois/Views/EventDetailView.swift:173–177` prints the primary camera label and supplies that thumbnail as its fallback. At lines 403–417, with no primary file, the valid front thumbnail is rendered. The “thumbnail only” overlay describes its resolution, not its incorrect camera label.

**Impact and limits:** This misidentifies the camera used for displayed evidence. It does not alter the original file on the capturing phone, forge a signature, or establish that the specific 1.12 “after that device updates the event” fix is broken. The necessary combination is an older unlabeled record, a partial download, and local cache eviction.

**Smallest effective fix:** Separate the thumbnail's camera identity from the downloaded file's camera identity. When a primary download assigns a previously unknown camera label (`.primary(setLabel: true)`), do not assign that label to the preexisting thumbnail. A legacy thumbnail whose camera was never recorded should remain available with an unknown-camera label; a preview generated from the downloaded rear file can carry the rear label. Simply replacing or clearing the old thumbnail prevents the wrong label but could discard the only locally retained front image, so preserve that evidence. Apply the same identity rule during merge remapping (`EventStore.swift:397–403`).

**Regression probe to add — not run:** Extend the integration setup in `Item201MirrorCameraTests.testARearDownloadThenTheLaterRecordThenTheFront`:

1. Generate two valid, visibly different JPEGs (for example, red for front and blue for rear). Start with an unlabeled legacy mirror containing the front thumbnail and no local files. Assert `fullCaptureMayBeInICloud` is true.
2. Make `fullMediaFetchForTesting` return only the rear JPEG, with `complete: false`. Assert the file lands and its camera is rear.
3. Use `mediaBudgetForTesting` below that file's size, then wait for `byteCapPruneIdleForTesting`. Assert the local filename is gone. Require that a fallback labelled rear is the rear preview; if the old front preview remains, its label must reflect its unknown legacy camera identity. Also assert that correcting the label did not destroy that original preview.
4. Render the detail view to check the label and preview together. Add a subsequent camera-remapping merge case so that fixing download assignment does not introduce a mismatch in inheritance.

The existing helper at `MalinoisTests/Item201MirrorCameraTests.swift:223–226` writes only `FF D8 FF D9`. Those bytes are not a decodable picture. The existing tests establish filename placement but cannot establish preview identity. Real image fixtures are necessary for this regression.

### Codex-3 — A Share callback may block the main thread behind ZIP generation

**Severity:** Medium. **Status:** SUSPECTED as a device-visible failure. **Timing:** Device probe before sign-off; fix before release if reproduced.

**Concrete situation to confirm:** The owner shares a signed event. ZIP generation or signing is slow. While the background provider is generating the item, UIKit asks the item-source callback for it on the main thread. The callback waits for the generation lock; the screen cannot respond for the remaining wait, potentially close to a minute.

**Evidence:** `Malinois/Views/EvidenceBundleItem.swift:156–169` holds `state`'s mutex throughout `wait(for:atMost:)`; lines 184–195 perform the semaphore wait. The item-source callback at lines 118–120 calls `keptBundle`, which acquires the same mutex at lines 138–143. Apple documents the [item-source callbacks as main-thread work](https://developer.apple.com/documentation/uikit/uiactivityitemsource) and [provider item generation as secondary-thread work](https://developer.apple.com/documentation/uikit/uiactivityitemprovider/item). The lock dependence is certain. The real callback overlap, and any watchdog termination, were not observed.

This is already acknowledged in `docs/adr/0080-share-says-when-it-went-without-the-signed-zip-and-waits-a-minute-for-it.md`, under Consequences. I am identifying an unresolved validation gap, not presenting it as a newly discovered certainty. The same record notes that timing out the sheet does not free a hung signer; I did not count that as a separate finding.

**Smallest effective fix if confirmed:** Hold the state lock only to inspect or change state. Keep generation/waiting outside it, with an explicit in-progress state and one producer. The main-thread callback must return without waiting for background generation. Check real destinations to ensure the revised callback behavior still delivers the ZIP.

**Probe to add — not run:** Use a maker controlled by a test latch, a short injected limit, and a background call to `madeBundle`. Once the maker signals that it has started, call `activityViewController(_:itemForActivityType:)` on the main actor and require a prompt return before releasing the maker. Then use a phone diagnostic with delayed generation and exercise Mail, AirDrop, and Save to Files, recording callback order and main-thread stalls. Existing `Item90ShareTests.swift:109–120,143–153` asks the item-source callback before or after generation, not during it. A deterministic callback-overlap test proves the blocking behavior; the phone diagnostic establishes normal UIKit reachability.

## 3. Wrong claims in the documents

**VERIFIED — `SECURITY.md:1400–1403`, incomplete retrieval and restore.** The text says a fetch that cannot check everything tells the owner and offers retry. That describes the full-media download handling more accurately than event-log restoration. Restoration exposes an in-progress label, but no persistent partial-result notice; rejected decoded records can additionally count as a completed restore. See Codex-1.

Until the implementation is fixed, replace the combined claim with:

> Full photo and video downloads distinguish an incomplete fetch from confirmed absence and offer a retry. Event-log restoration keeps the records it could read, but currently has no persistent notice when a query fails or a record is unreadable. Pull to refresh to try again; a completed refresh does not prove that every cloud record was understood.

After fixing Codex-1, document the actual partial-restore notice and the distinction between retryable failures and records that need a newer app version.

I found no other sufficiently demonstrated false claim to list. In particular, Codex-2 is not evidence against the narrower 1.12 release-note claim about a photo's placement after a later source-device update. I also did not turn expressly documented signing, Guided Access, suspension, or slow-motion limits into undisclosed vulnerabilities.

## 4. Where I went

I began with three hypotheses: protection might fail between arming and sensor startup; evidence might be lost or reassigned between storage and cloud updates; and the signed bundle might prove less than recipients are told. The review followed those paths rather than another reviewer's checklist.

**Controls that appeared sound in the paths inspected:**

- PIN verification and lockout, sealed-Keychain recovery, ordinary disarm and interruption recovery; continued trip handling during PIN entry; session checks that prevent old capture completions from changing a newer watch.
- Guided Access guidance, motion/audio health reporting, camera failure/deadline handling, and siren microphone handoff. Forced restart, suspension, slow level movement, and Guided Access configuration remain disclosed platform/design limits.
- EventStore's journal/write ordering, conservative deletion after persistence, set-aside log enumeration/read/share/delete, media-reference checks, attachment recovery, collision numbering, and set-aside UI. I did not find a demonstrated deletion of another live record's evidence in those inspected paths.
- Cloud enrollment and account leases, invalidation of stale operations, priority of first-hand records over mirrors, signed-media digest checks on downloads, and retention based on server dates. No demonstrated cross-account upload was found.
- Watch relay/pairing, notification paths, and wake deadlines. ADR 0079 explicitly describes a durability limit around pending watch work; I did not claim that the deadline alone guarantees alert delivery.
- Evidence statement parsing, certificate/key/nonce binding, signature and attachment checking, export scope/counter accounting, key continuity, and verifier ZIP/path defenses. No accepted-forgery path was established. The signing section of `SECURITY.md` states meaningful limits, including identity, device compromise, backup history, and what a signature cannot establish about an event's physical truth.
- Relevant README/public README, security text, listing, privacy policy, and decision records were checked against these implementation paths. This was not a claim-by-claim audit of every document or every screenshot.

**Blind spots in the existing validation:** Tests of individual values can miss disagreement between those values as displayed. Codex-2 combines a correct filename, a correct new label, and a stale thumbnail; assertions on just the first two pass. Codex-1 similarly distinguishes an internal failure flag from a notice the owner can actually see. The Share tests omit the concurrent callback order identified in ADR 0080. None of these observations negates the reported release-suite results; they identify cases those results do not settle.

**Limits of this review:** No physical iPhone/Watch, real CloudKit account, App Attest transaction, StoreKit purchase, signed archive, or App Review session was exercised. No live service or other person's data was probed. I did not independently rerun the supplied release-gate results. A preliminary sandbox capability check returned `sandbox-exec: sandbox_apply: Operation not permitted`; runtime isolation for additional target-code probes was not established, so the proposed tests above remain unexecuted. No simulator was created or touched. The two VERIFIED findings rest on the cited source chains; actual device callback ordering remains SUSPECTED.

I rejected a broader thumbnail hypothesis after checking the UI: a mirror with no thumbnail, camera labels, files, or manifest cannot offer Download, so a test that directly invokes the download method from that state is not proof of a user-reachable failure. Codex-2 uses a valid preexisting thumbnail and the supported legacy path instead. I also did not promote a stale arming-cancel action or an alert-timer scheduling hypothesis to findings without showing a user-reachable race.
