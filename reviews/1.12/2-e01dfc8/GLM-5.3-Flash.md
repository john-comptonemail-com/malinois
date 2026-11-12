# Adversarial review — Malinois 1.12 (87) — GLM-5.3-Flash-Free

| | |
|---|---|
| **Reviewer** | GLM-5.3-Flash-Free (independent reviewer; no other reviewer's report or notes were read, per the prompt's isolation rule) |
| **Date** | 2026-11-11 |
| **Folder** | (the review folder) (commit `e01dfc8`, 2026-11-11) |
| **Tests run by this reviewer** | None of my own. The release gate already passed on this exact commit (per the prompt: full suite 2,253 tests on iOS 27.0, a second full run on iOS 18.0, strict lint, ThreadSanitizer, macOS evidence-core lane), and the prompt forbids rerunning it. I did not build a probe target and created no simulator, so there is nothing to clean up. What I ran instead, all read-only: the two reader-facing `grep` commands the public README gives its readers, byte-count checks, and targeted cross-check greps of every numeric or absolute claim in the store documents. Everything in this report is static evidence; the runtime half is the gate's, on this commit. |
| **What was read** | Both review sessions combined: every service file, the monitoring engine and all its facade/extension files, the trip responder chain, the evidence core (`MalinoisEvidence/`), the Mac verifier (`MalinoisVerifier/`), `EventStore` (key sections and the new set-aside sections), the full watch app (all 7 files), both notification-service extensions, the new-in-1.12 files (set-aside log model/views, signing-key row, event log/detail rework), all store documents, `_PUBLIC_README.md`, `_LIVE_APP_STORE.*`, `docs/adr/` (records 0048, 0055 in full; the rest by title and by the code they govern), `tools/release/README.md`, `Malinois/Support/*` (Info.plist, entitlements, privacy manifest), and a spot-check of `MalinoisTests/`. |

---

## 1. Summary for the owner (plain English)

**Verdict: clean.** I read essentially the whole app — every service, the arming and trip machinery, the evidence-signing core and the Mac verifier, the watch app, both notification extensions, the new set-aside-log feature, and every document the public can see — and I checked every number and every promise in those documents against the code. I found **no security hole, no dishonesty, and no bug worth fixing in 1.12 (87)**.

**The most serious problems I found: none.** The nearest things to "problems" are documentation bookkeeping notes (§4), none of which change the app's behavior and none of which I believe misleads an owner:

- The public README's self-description numbers (tests, decision records, lines of code) describe version 1.11, because the folder carries the 1.11-pinned copy of the public README (stated in `_SOURCES.txt`). Its claims were correct for 1.11 as far as I can re-derive them, and the release tooling recounts all of these numbers automatically at each stage, so they will be brought up to date by the pipeline, not by hand.
- The public README links `docs/adr/README.md` as the index of decision records. That file is not in this folder because it is *generated* for the public export at release time (`tools/release/lib/adr_index.py`, described in `tools/release/README.md`). The link is correct where it matters — in the public repository — it just does not exist in the private mirror this folder snapshots. I flag it only so you are not surprised it is missing here.
- One nuance worth knowing for future wording: 1.12 adds a **Delete** for a *set-aside log* (a whole sidecar file, behind a confirmation). This does not contradict the claim "no way to delete a single entry, not even with your PIN" — a set-aside log is not a log entry, and its deletion removes one retired whole file plus only the media it names. But the two statements live close together in the docs now; keep the wording careful in future What's-New texts so a reader can't misread "logs can now be deleted" as "entries can".

**Should 1.12 (87) go to TestFlight / the App Store? Yes.** I found nothing that should hold it.

- **Must fix before archiving:** nothing.
- **Must fix later:** nothing required.

The known, deliberately-accepted items stay as they are: the App Attest call that never answering holds the signer's turn until relaunch (documented in ADR 0080, BACKLOG 223) is a known limitation, disclosed, and it fails safe (no signing claim is made); it does not put evidence at risk. The siren test that fails on a lid-closed MacBook is the Mac's missing microphone, not the code.

---

## 2. The security model as I understand it (plain English)

Malinois is a *detector, not a lock*, and the design is honest about that everywhere: the promise is that you either find your device as you left it, or you find a record that someone touched it. Everything in the code serves that promise:

- **The record is written before anything else happens.** A trip first writes its record durably (write-ahead journal, fully synced before `add` returns), and only then does the alarm, camera, or upload run. If the write fails, the response still goes ahead and Home reports the failure — a tamper is never silenced by a full disk.
- **The evidence survives deception.** Someone who knows the iPhone passcode can force-restart the phone, but the handling before the restart is recorded, the next launch records "Monitoring interrupted", and the log's record-keeping (including signatures made and not kept, since 1.11) is designed so gaps are *named*, not hidden. Deleting the app destroys the local log — and that absence is itself the sign; the docs say so plainly.
- **The PIN protects the log, and cannot be reset away.** The PIN is stored only as a salted hash; a reinstall keeps the PIN, its wrong-attempt count and lockout, and the trial/membership records in the Keychain, so deleting the app cannot bypass the PIN or restart a trial. Wrong PINs are themselves events, with a photo, and rate-limited (30 s doubling to 1 h).
- **What leaves the phone goes only to you.** With Pro, uploads go to your own private iCloud database and alerts to your own devices, through Apple's CloudKit, WatchConnectivity, and push infrastructure. There is no developer server — I verified this directly by running the README's own reader commands (§6): the app's Swift contains no `URLSession` and no built URL except the three support/policy/source links it opens in Safari, and the complete import list is Apple frameworks only, with no package manager files anywhere in the tree.
- **Uploads fail closed.** iCloud access is verified with Face ID/passcode before anything uploads; a sealed (not-yet-unlocked) settings store is never taken for a fresh install (canary file, ADR 0055) and while unresolved nothing uploads, nothing deletes in iCloud, nothing is overwritten; the enrollment binds uploads to one verified account. Retention deletions in iCloud are bounded by a server-time-anchored 30-day floor, so a wrong clock or an aggressive setting cannot eat recent evidence.
- **Records you share can be checked by others.** The phone signs its records with a key in the Secure Enclave, certified once by Apple's App Attest (which receives a public key and a fingerprint of a short statement — no records). The bundle format is strictly checked (canonical JSON verified by a byte round-trip, strict DER and CBOR, bounded inputs everywhere), and the Mac verifier re-derives everything independently. The verifier's limits ("what a check shows and what it cannot") are stated rather than implied.
- **The watch and the push extensions are deliberately dumb.** The watch shows alerts and reads no event records; both notification extensions have empty entitlements, read no CloudKit records, and decide only from the push itself. Each device can only ever leak less than the phone that recorded the evidence.
- **Permissions are asked late and sparingly.** Camera on the first ARM tap (never under Guided Access, where iOS would record a refusal), microphone only when you switch on Sound or clip audio — never at launch.

The threat model is coherent across SECURITY.md, the ADRs, the code comments, and the public documents. I looked for the classic ways this kind of app lies to itself — a quiet path that deletes evidence, an upload that skips a confirmation, a "fail open" where a sealed store reads as empty, a permission requested early, a claim in the docs stronger than the code — and found none.

---

## 3. Findings

**No findings.** Nothing I read met the bar for a finding: a concrete defect with evidence, in code or documents, that a fix should address. The bar I applied excludes style, hypotheticals without a concrete failure, deliberately-accepted and documented design decisions (ADR 0048's storage trade-offs, ADR 0080's App Attest stall), and environment facts (the Mac's missing microphone).

| ID | Severity | Status | Area | Evidence | Smallest fix | Probe test | Before archiving? |
|---|---|---|---|---|---|---|---|
| — | — | — | (no findings) | — | — | — | — |

---

## 4. Document claims that do not match the code

**None of the claims I could check turned out wrong.** Every claim in `store/PRIVACY_POLICY.md`, `store/privacy-policy.html`, `store/support.html`, `store/APP_STORE_LISTING.md`, `store/APP_REVIEW_NOTES.md`, `store/APP_REVIEW_NOTES_FIELD.md`, `_PUBLIC_README.md`, and the live-store snapshot that was checkable against this tree checked out; the positive evidence is in §6. Per the prompt's format, the rows below are the claims I could **not** check from this folder, or that read as stronger/older than this tree, with what I found:

| Verdict | Quote | Where | What I found | Proposed wording |
|---|---|---|---|---|
| Not checkable | "2,171 unit tests in 147 files, 54,676 lines of tests." and "272 of them" (pure functions) and "68 design decisions are written up as records in `docs/adr`" | `_PUBLIC_README.md:73-75` | This is the v1.11-pinned public README (`_SOURCES.txt:5`), so these numbers describe the 1.11 tree, which is not in the folder. The current tree is consistent with growth since then (2,318 raw `func test` lines in 151 files; 2,253 gate-counted tests; 71 ADR records), and the stage step recounts these numbers automatically from the staged tree (`tools/release/README.md:246-248,284`), so the 1.12 export will carry fresh numbers. | None needed. |
| Not checkable | "the index (`docs/adr/README.md`) lists them" | `_PUBLIC_README.md:131-132` | `docs/adr/README.md` does not exist in this snapshot, although `_SOURCES.txt:9` includes `docs/adr` in full. The index is generated for the public export only (`tools/release/lib/adr_index.py`, `tools/release/README.md:288-290`), which is why it is absent from the private mirror. The link should be correct in the public repository; I cannot see that repository. | None needed; if the owner ever wants the mirror self-contained, the index would have to be committed there. |
| Not checkable | "App Store Connect's field still holds the text of the app's initial approval" | `store/APP_REVIEW_NOTES_FIELD.md:5-8` | An external state (the ASC field's current contents) is not visible from the folder. The document itself is internally consistent and its byte-count claim is exact (§6). | None needed. |
| Not checkable | "This is an iOS 26 bug, not Malinois" (Guided Access "unavailable") | `store/support.html:203-206` | A claim about iOS 26's own behavior; not checkable from source. It is framed as an observation ("It seems to happen more often…"), which is appropriately hedged. | None needed. |
| Not checkable | The live store description beyond its first ~2,000 characters | `_LIVE_APP_STORE.json` (truncated in my read) | The visible portion matches the code (tripwire list, "no way to delete a single entry", signed evidence, upload-before-photo). The read-back claims I could compare were byte-checked against the repo listing by `check-live-store.zsh` at 1.11's approval, per `tools/release/README.md:262-269`. | None needed. |

One **known, disclosed** limitation I deliberately do *not* report as a finding: an App Attest call that never answers holds the signer's turn until relaunch (ADR 0080; BACKLOG 223). It is documented in the folder, fails safe, and was accepted before this review.

---

## 5. Tests

**The gate on this commit.** Per the prompt, the full suite already passed on `e01dfc8` and was not rerun. I did verify the arithmetic that the gate's expected count rests on, because the release README documents exactly how the count is derived (`tools/release/README.md:112-114`):

- Raw `func test` lines in `MalinoisTests/`: **2,318** (my grep).
- Minus the two macOS-only classes: `Item90VerifierTests.swift` (59) and `Item188VerifierReportTests.swift` (6) = **2,253**.
- 2,318 − 65 = **2,253** — exactly the gate's expected count for this commit. The counting method and the number agree.

**Spot-checks of coverage (not exhaustive):**

- `Item122SetAsideLogTests.swift` (new in 1.12): covers record-by-record reading of a set-aside log — whole log, one unreadable record (a value a newer build wrote), damaged bytes inside one record, a log cut off mid-record, escaped quotes inside strings — plus delete/share outcomes. The header records that the tests were written *before* the code and were red against compile-only stubs.
- `KeychainServiceTests.swift`: covers the seal-vs-absence rule (a Keychain that cannot be read is never "no PIN") and the lockout contract.
- `Item144LockoutValueTests.swift`: pins the lockout's stored-value well-formedness and damage handling.
- The macOS lane classes exist and are correctly excluded from the simulator count (`tools/release/README.md:92-99,113-114,297-299`).

**Probe tests: none built, deliberately.** Everything I checked was verifiable statically (grep-able constants, pure functions with unit tests already pinning them, document byte-counts). Nothing I found left a question that only a simulator run could answer, so a probe target would have tested code I already believed correct. The runtime side of this review is therefore the gate's evidence on this commit (2,253 tests on iOS 27.0, the iOS 18.0 run, ThreadSanitizer, strict lint, and the macOS lane), not my own runs. Known environment caveat unchanged: the siren audio test fails on a lid-closed MacBook (no microphone) — the Mac, not the code.

---

## 6. What I checked and found sound

These are the checks behind §1's verdict, each with its evidence:

**The public README's self-check commands, run verbatim.**

- `grep -rnE 'URLSession|URLComponents|URL\(string|https?://' …` prints **only** lines from `Malinois/Support/Brand.swift` (the three Settings links, built with `URLComponents` and opened in Safari) — exactly as the README promises (`_PUBLIC_README.md:36-42`).
- `grep -rlE '^import (CloudKit|StoreKit|WatchConnectivity|DeviceCheck|Network)$' …` lists 11 files whose usage matches the README's description precisely (CloudKit: uploads, alert relay, watch account/subscription check, the alert extension's push reading; StoreKit: the purchase and the rating request; WatchConnectivity: the iPhone→watch relay; DeviceCheck: App Attest; Network: connectivity watching only).
- The complete unique import list across all six code folders is Apple frameworks only (AVFoundation, AVKit, CloudKit, Combine, CommonCrypto, CoreGraphics, CoreMotion, CoreNFC, CryptoKit, CryptoTokenKit, Darwin, DeviceCheck, Foundation, ImageIO, LocalAuthentication, Network, os, OSLog, Security, StoreKit, SwiftUI, Synchronization, UIKit, UserNotifications, WatchConnectivity, WatchKit). No `Package.swift`, `Package.resolved`, `Podfile`, `Cartfile`, or podspec exists anywhere in the tree. "No third-party SDKs / no third-party code" holds.

**Every numeric claim in the support page and privacy policy, against code:**

| Claim | Where the code says the same thing |
|---|---|
| 5 wrong PINs → 30 s, doubling, capped at 1 h | `KeychainService.swift:474-481` (`min(30.0 * pow(2.0, extra), maxLockoutDelay)`, `maxLockoutDelay = 3600`) |
| ARM asks for the PIN after 14 days without one | `MonitoringEngine+ArmPINCheck.swift:17` (`armPINCheckInterval = 14 * 86_400`) |
| 15-second countdown (default) | `AppSettings.swift:328` (`gracePeriodSeconds = 15`; the value is an owner setting, applied at `MonitoringArmingFlow+Transitions.swift:110-112`) |
| Press and hold 5 seconds for the PIN pad | `DisarmEntryCoordinator.swift` ("a logged 5 s hold to enter", the 5 s attribution window) |
| "Before you arm" cancelled after a minute untouched | `MonitoringEngine.swift:1995` (`firstArmBriefingTimeout = 60`) |
| Siren starts quiet 10 s, rises over the next 10 | `SirenPlayer.swift:216-218` (`rampHoldSeconds = 10`, `rampFadeSeconds = 10`) |
| Signal loss after ~30 s; Motion not tripped in the last 10 s | `MonitoringEngine.swift:1978-1979` (`blackoutDebounce = 30`, `stationaryWindow = 10`) |
| Heartbeat every five minutes | `CloudExfiltrator.swift:1794` ("a year of beats five minutes apart") + ADR 0020 |
| Retention never deletes anything newer than 30 days | `CloudExfiltrator.swift:2111` (`retentionFloorDays = 30`, anchored to server time at 2127/2135) |
| Re-arm loop: closed again within 90 seconds → stays disarmed | `MonitoringEngine.swift:705` |
| Alerts more than an hour old arrive as one summary | `WatchRelayInbox.swift:296` (`startsAgainAfter = 3600`) + ADR 0051 |
| Pro trial 30 days; membership syncs via iCloud Keychain | `ProEntitlements.swift:43` (`trialDays = 30`) and `:13` (synchronizable Keychain item); `earlyAccessProgramOpen = true` is fixed in the build |
| iOS 18+ / watchOS 10+ minimums | Live listing `minimumOsVersion: 18.0`; archive verification pins `phone_minimum_os` 18.0 and `watch_minimum_os` 10.0 (`tools/release/README.md:181-184`) |

**Deletion claims (the load-bearing kind for this app).**

- No per-event delete control exists anywhere: `EventStore`'s only user-facing delete is the whole set-aside log (`EventStore.swift:2921` `deleteSetAsideLog`), behind a confirmation dialog (`SetAsideLogView.swift:83-91`), and Event Log rows carry no delete affordance. The Event Log's remaining removals are the size limits, which the log *reports* (the set-aside log and the reports-owed machinery, `EventStore.swift:1093-1095`).
- "Free up iCloud space…" states its own rule in the dialog, matching the privacy policy verbatim: "Event facts, thumbnails, and arm/disarm records are kept. Nothing newer than 30 days can be deleted." (`SettingsView.swift:592-602`).
- "If most are gone, it says so on Home and uploads again what it recorded and still holds": the launch-pull machinery exists as described (`MonitoringCloudCoordinator+Transfers.swift:22-33`, `EventStore.swift:530-620` `restoreOwed`).

**Permission timing.** The microphone prompt is requested only from the two toggles that need it (`SettingsView.swift:381` clip audio, `:780` the Sound tripwire) through `CameraController.requestMicrophoneAccessIfUndetermined` (`CameraController.swift:495-502`) — never at launch, exactly as the privacy policy and review notes say. The camera prompt is asked before the arming screen and skipped under Guided Access, where iOS would record a refusal (`CameraController.swift:465-482`, ADR 0011).

**Keychain continuity (the "delete the app changes nothing" claims).** PIN fields (length, wrong-attempt count, lockout, last correct entry), trial start, Early-Access membership (synchronizable), Face ID enrollment marker, and the two signing records (signing-key IDs and the marker that guards the log's record of limit removals) all match the code I read: `KeychainService.swift` in full, `ProEntitlements.swift:13`, the bookkeeping markers at `KeychainService.swift:169-227`, and `EventStore.swift:1093-1095`.

**The watch app and both notification extensions.** The watch cannot arm, disarm, or write anything (`MalinoisWatchApp.swift:6-7`, one status screen, `ContentView.swift`); its iCloud reads are the account status and the subscription listing only, each under a deadline (`WatchAppDelegate.swift:208-226`, `WatchAlertStatus.swift:171-209`). Both extensions have empty entitlement dicts (checked in the earlier pass) and read no CloudKit records — the iPhone extension decides from the push's subscription ID alone (`NotificationService.swift:9-16,66-68`), and the watch extension from the push plus the delivered-notifications list (`WatchNotificationService.swift`). Tamper alerts are Time Sensitive and disarm alerts are not, exactly as the support page says (`NotificationService.swift:62-68`). The burst-quieting and pairing rules match ADR 0061/0052 in both extensions and the inbox. The watch hands its background wakes back within 10 s, inside watchOS's 15 s (`WatchLinkWakes.swift`, item 212).

**The 1.12 feature claims.** Set-aside logs listed in the Event Log and the Home reminder while kept (`HomeView.swift:492-500`); signing-key row shows the first 8 hex characters with a Copy of the full 64-character ID (`SigningKeyRow.swift`); the share-without-ZIP reason on the event screen (`EventDetailView.swift:44-72`); the photo-downloaded-under-wrong-camera fix (`MonitoringCloudCoordinator+Transfers.swift:337-355`); the once-per-watch "removed to make room" note (`MonitoringEngine+Retention.swift:63-71`).

**Documents' own consistency.** `APP_REVIEW_NOTES_FIELD.md`'s byte-count claim is exact: the text between the two markers is **3,899 bytes**, as stated. `privacy-policy.html` and `PRIVACY_POLICY.md` carry the same claims and the same effective date; the live 1.11 description's visible claims match the repo text; the 1.12 What's New text in the listing matches what the code does.

**Infrastructure.** `tools/release/` is fail-closed throughout (STOP on surprises, no overwrites, fast-forward-only pushes, sweeps that stop rather than pass, tested tooling replaying real historical inputs) — this is the machinery that will recount the README numbers and byte-check the live store text for 1.12, so the counts flagged in §4 self-correct at stage time. ADR 0048 and ADR 0055 document exactly the trade-offs and fail-closed guards I saw in the code, including the set-aside log's deliberate "kept, unbounded, costs storage not evidence" rule and the settings canary.

---

## 7. What I could not review or verify

- **Live external state:** the current contents of the App Store Connect reviewer-notes field, the live GitHub Pages pages, and the live store listing beyond the checked-in 1.11 snapshot. The release tooling byte-compares these at approval day (`check-live-store.zsh`), which is the right place for it.
- **The shipped binary.** As the public README itself states, iOS has no reproducible builds; this folder cannot prove the App Store binary was compiled from this tree. Everything here is about the source and the documents.
- **Device-only behaviors:** Guided Access interplay, App Attest's network behavior in the field (including the known, documented never-answering-call stall, ADR 0080), physical NFC/PIV hardware keys (ADR 0007), real CloudKit server behavior, siren audio on hardware. The gate covers what a simulator can; the rest rests on the owner's two-iPhone/one-watch testing.
- **The v1.11-pinned public README's self-description counts** (tests, pure functions, ADR records, lines): correct-or-not for the 1.11 tree cannot be re-derived from this folder; the current tree's equivalents are consistent with normal growth, and the pipeline recounts them for the 1.12 export.
- **The full test suite.** Spot-checked, not exhaustively read (151 test files), and not rerun — per the prompt, the gate's passing run on this commit stands.
- **The GitHub history and the private findings ledger:** deliberately excluded from the folder (`_SOURCES.txt:10`), so I could not check that every historical fix is in the ledger. I judged the code on what is here.
- **Other reviewers' reports and notes** (`_REVIEW_REPORT_Codex.md`, any `_REVIEW_NOTES_*`): not read, per the isolation rule.

**Folder integrity:** after writing this report, I re-verified `_MANIFEST.sha256` against the folder: every listed file matches its recorded SHA-256, so nothing in the folder changed except files added after the manifest was built (the reviewers' reports). No simulator was created for this review, so none needs deleting.
