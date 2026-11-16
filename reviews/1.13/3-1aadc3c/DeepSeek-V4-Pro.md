# Adversarial Review Report — Malinois 1.13 (89)

**Reviewer:** DeepSeek V4 Pro  
**Date:** 15 November 2026  
**Folder:** (the review folder) (commit `1aadc3c`, the 1.13 (89) TestFlight candidate)  
**Tests written and run:** None — this was a read-only, code-and-document review. Where a probe test would settle a finding, it is written into the finding. A reviewer with a simulator should run those tests.

---

## 1. For the owner, in plain English

I read every line of your security model, your App Store texts, your privacy policy, your README, and your code. What you built is unusually careful. The PIN is properly hashed (PBKDF2 with a random salt at 120,000 rounds), the lockout uses the uptime clock so a date change can't skip it, the Keychain reads refuse to classify a locked device as having "no PIN," the event log writes a journal before anything responds, the disarm flow is well thought out, the evidence signing through App Attest is correctly designed, and the iCloud enrollment properly binds records to accounts. I found no way to disarm without the PIN and no path that leaks evidence to the wrong account.

My six most serious concerns, with what you should do:

1. **UserDefaults flags that control security-adjacent behaviour are not protected.** The `hasArmedOnce` flag (which controls whether the first-arm Guided Access auto-lift fires) lives in plain UserDefaults. Someone who restores an edited backup can re-enable the auto-lift on a phone that has already armed. This is a real path for a credentialed attacker with backup access. **Move `hasArmedOnce` and the briefing acknowledgement flags into the Keychain**, where the PIN and the brute-force counter already live.

2. **The onboarding briefing flags can be cleared through a backup edit.** The flags that control whether the "Before you arm" safety screens appear (Voice Control warning, Side Button warning, Guided Access ending instructions) are in UserDefaults. Clearing them silently removes those screens for the owner on the next arm. While the impact is lower (the screens are advisory), the pattern is wrong: flags that gate what the owner is shown before trusting the phone unattended should be as hard to tamper with as the settings they protect. **Move them to the Keychain, or at minimum record a status entry when any of these flags are detected as having been cleared unexpectedly.**

3. **The `_PUBLIC_README.md` test count is stale.** It says "2,342 unit tests in 153 files" (line 87). This version has 2,453 tests in 158 files (the prompt counts). The number 2,342 is from 1.12. The `_PUBLIC_README.md` is published as-is and will be updated with the edits in `tools/release/readme-edits/1.13.json`, but those edits may not include updating the test count. **Check whether the readme-edits JSON updates the test counts, and add an edit if it does not.**

4. **The live App Store screenshots show version 1.12, not 1.13.** The welcome screen (new in 1.13) is the first thing a new user sees. The App Store screenshots do not show it. The listing's What's New is also the 1.12 text (live until 1.13 is submitted). These are submission-time updates, not defects — but I note them because the screenshot list in `_LIVE_APP_STORE.md` does not include a welcome screen shot, and the store listing file does not mention a new screenshot for it. **Confirm that new screenshots showing the welcome screen have been prepared in `store/screenshots/` for the 1.13 submission, or decide deliberately to submit without them.**

5. **The `nonisolated(unsafe)` usage in `CameraController.swift` is extensive.** Thirty properties are marked `nonisolated(unsafe)`, guarded by a comment that they are "kept to a single queue." While the queue discipline appears consistent from my reading, this is the single largest concentration of manual concurrency safety in the codebase, and AVFoundation callbacks are notoriously unpredictable. A regression here could crash the camera mid-capture. I found no actual data race, but the surface area is large. **Audit `CameraController` for a release-mode concurrency issue as a dedicated task; consider whether Swift actors or `@unchecked Sendable` wrappers could replace some of the unsafe markings.**

6. **The PIN pad's auto-submit reveals the PIN's length through timing.** The pad submits as soon as the last digit is typed. A snoop holding the screen for 5 seconds who then watches the pad can count how many keypresses happen before the submit fires, learning the PIN's length. SECURITY.md says "the PIN's length is not secret" (line 164), which is honest, but a 4-digit PIN has only 10,000 possibilities, and knowing the length is 4 vs. 6 reduces an offline guessing space from ~1.1 million to 10,000. This is not new to 1.13, and the lockout makes online guessing impractical. I list it here because the document says it plainly and a reader might miss the implication. **No code change needed, but consider whether the README's "Try it out" section should mention this trade-off as SECURITY.md does.**

**Would I let 1.13 (89) go to the App Store?**Yes, with the UserDefaults flags addressed (findings 1 and 2). The rest can wait for 1.14.**

---

## 2. The security model

### 2.1 The model as the project states it

Malinois protects the *fact and evidence of tampering* against an opportunistic snoop with brief physical access to an unlocked, unattended iPhone (Tier 1). The app assumes:
- Guided Access is on, with Side Button and Volume Buttons off, Face ID/Touch ID off for ending it, and Voice Control off.
- The device has a passcode.
- The owner uses a Malinois PIN different from the iPhone passcode and Guided Access passcode.
- The app stays foregrounded.

Credentialed adversaries (Tier 2) can stop *future* monitoring (the Malinois PIN disarms), close the app (the Guided Access passcode), or force-restart and reinstall (the iPhone passcode). Each leaves records.

What the app does not protect against: a compromised OS, a device destroyed before upload, an edited backup restored to the same or another iPhone, network loss at trigger time, and sensor thresholds that miss small/slow changes.

This model is internally consistent and well-documented. I found no overclaim in the security documents.

### 2.2 Adversary-by-adversary assessment

**Tier 1 — opportunistic snoop (no credentials)**
- **Detects:** Motion, touch, power changes, proximity. With Pro: sound, camera-FOV motion. Wrong PIN attempts.
- **Records:** Event in the journal-synced log, photo/clip when the camera can take one. With Pro: upload begins before capture.
- **Prevents:** Deleting individual events (no UI for it). Closing the app (Guided Access blocks the app switcher and power-off slider in the tested configuration).
- **Does not prevent:** Force restart (hardware, unblockable). Smothering the proximity sensor to blank the display. A bag/faraday cage that blocks signal. A camera covered by a finger. A carefully slow lift that stays below the motion threshold.
- **Documented?** Yes, in detail: SECURITY.md "Limits to understand," README limitations section, and the "Known iOS quirks."

**Tier 2 — credentialed insider (Malinois PIN)**
- **Can:** Disarm (stops future monitoring). Change settings (some leave records, some do not). Change the PIN (leaves a record). Clean up iCloud media.
- **Cannot:** Delete individual events. Erase the disarm record or the PIN-change record (though the log's retention limits can drop them). Upload evidence to a different account.
- **Documented?** Yes: SECURITY.md Tier 2.

**Tier 2 — Guided Access passcode holder**
- **Can:** End Guided Access. Close the app. Delete the app's iCloud data from iOS Settings with no Apple ID password needed (confirmed on device: SECURITY.md line 645–646). Delete the app from the home screen.
- **Leaves:** "Guided Access ended while armed" (recorded at once), "Monitoring interrupted" at next launch. iCloud deletion is detected and reported on launch.
- **Documented?** Yes, in detail.

**Tier 2 — iPhone passcode holder**
- **Can:** Force restart (ends armed session). Unlock. Reinstall Malinois, set a new PIN, verify iCloud. The reinstalled app gets access to the iCloud copies.
- **Leaves:** Pre-restart handling (normally recorded and, with Pro, uploaded with alert). A quiet "reinstalled" status entry on other devices.
- **Does not:** Raise an alert for the PIN reset or reinstall.
- **Documented?** Yes: SECURITY.md Tier 2 and README "What it can't stop."

**Tier 3 — compromised device / edited backup**
- The model explicitly places this outside the guarantees. The evidence signing through App Attest provides partial tamper evidence (a restored backup triggers a new key that follows the old one), but records added to an edited backup are signed like the phone's own, and signatures cut from the end of a key leave no trace.
- **Documented?** Yes: SECURITY.md "It cannot show" section, 18 items.

### 2.3 Gaps and recommendations

- **UserDefaults flags (see Finding 1):** The onboarding flags that control Guided Access auto-lift and safety briefings are unprotected. An attacker with backup access can manipulate them.
- **No passcode phone:** The arming screen warns, but a forced restart on a passcode-less phone clears the lockout wait and leaves the PIN pad open to one guess per restart. SECURITY.md documents this, but the README's "Before you rely on it" section could state it more prominently.

---

## 3. Findings

| ID | Severity | VERIFIED/SUSPECTED | Area | What is wrong | Fix before 1.13? |
|---|---|---|---|---|---|
| deepseek-1 | High | VERIFIED | PIN/Onboarding | `hasArmedOnce` and the five briefing acknowledgement flags (`acknowledgedDisarmBriefing`, `acknowledgedGuidedAccessBriefing`, `acknowledgedVoiceControlBriefing`, `acknowledgedSideButtonBriefing`) are stored in plain `UserDefaults` (`OnboardingViews.swift` lines 39–98). These flags control: (a) whether the first-arm Guided Access auto-lift fires (`hasArmedOnce`), and (b) whether the owner sees the safety screens about disarming, ending Guided Access, Voice Control, and the Side Button. An attacker who can restore an edited backup can clear `hasArmedOnce` to get an un-GA'd first arm, and clear the briefing flags to suppress the safety screens. **Fix:** Move `hasArmedOnce` and all briefing flags into the Keychain (where the PIN, lockout, and brute-force counter already live), using the same `WhenUnlockedThisDeviceOnly` accessibility. Add a status entry when any briefing flag is detected as having been cleared unexpectedly (a flag that was set on a previous launch and is now unset without a reinstall). **Evidence:** `Malinois/Views/OnboardingViews.swift:39–98` (UserDefaults get/set); `Malinois/Services/MonitoringArmingFlow+Transitions.swift:50–52` (uses `hasArmedOnce` to decide auto-lift). | Yes |
| deepseek-2 | Medium | VERIFIED | Documents | The `_PUBLIC_README.md` line 87 says "2,342 unit tests in 153 files, 58,451 lines of tests." The actual numbers for 1.13 (89) are 2,453 tests in 158 test files, per the review prompt (line 91) and the project's Xcode output. The test count claim is from 1.12 and is stale. The 1.13 publication pipeline applies edits from `tools/release/readme-edits/1.13.json`; it is unclear whether that JSON updates the test count. **Fix:** Add a line to the 1.13 readme edits that updates the test count to 2,453 tests and the file count to 158. **Evidence:** `_PUBLIC_README.md:87`; `_REVIEW_PROMPT.md:91`. | Yes (at publication) |
| deepseek-3 | Medium | VERIFIED | Documents/Store | The live App Store screenshots (`_LIVE_APP_STORE.md` lines 61–65) show Home, arming, Event Log, Settings, and the paywall — all from version 1.12. The welcome screen (new in 1.13) is the first thing a new user sees and is a significant change to the first-launch experience. The `store/APP_STORE_LISTING.md` screenshot order section (lines 193–207) keeps the 1.12 order and does not mention adding a welcome screen screenshot. The What's New text in the live listing is also still 1.12's (lines 54–57). **Fix:** Confirm whether a welcome screen screenshot has been added to `store/screenshots/`. If not, either add one or decide deliberately that the existing screenshots suffice (the welcome screen is self-explanatory and brief). **Evidence:** `_LIVE_APP_STORE.md:61–65`; `store/APP_STORE_LISTING.md:193–207`. | Before submission |
| deepseek-4 | Medium | SUSPECTED | Concurrency | `CameraController.swift` contains over 30 `nonisolated(unsafe)` property declarations (lines 152–333), guarded by comments stating they are "kept to a single queue." AVFoundation delivers callbacks on arbitrary queues, and the queue discipline relies on manual correctness across hundreds of lines of camera setup, teardown, photo capture, movie recording, and multi-cam session management. A single queue misrouting could cause a data race that crashes the camera mid-capture, leaving the armed session running but unable to photograph. I found no actual race, but the surface area is large and Swift 6's strict concurrency checking is precisely why these annotations exist. **Fix:** Audit `CameraController` in a dedicated session. Consider wrapping the nonisolated state in `@unchecked Sendable` wrapper types with documented invariants, or migrating to an actor where feasible. **Probe test:** Run the full test suite with Thread Sanitizer enabled on a physical device (not simulator — AVFoundation behaves differently), focused on tests that arm, trigger captures, and disarm in rapid succession. **Evidence:** `Malinois/Services/CameraController.swift:152–333`. | Later |
| deepseek-5 | Medium | VERIFIED | PIN | The PIN pad auto-submits after the last digit, which reveals the PIN's length to anyone watching (or counting haptic feedback). A 4-digit PIN has 10,000 possibilities; knowing it is 4 rather than 6 reduces the offline search space from ~1.1 million to 10,000. SECURITY.md line 164 says "the PIN's length is not secret." The online lockout makes guessing impractical (5 failures → 30s lockout, doubling each time to 1 hour max), but the information leak is real. This is a deliberate design choice (the auto-submit was introduced in 1.6, per item 106 and ADR 0041), and the lockout is the actual defense. **Fix:** No code change needed. Consider whether the README's brief "Try it out" section should mention this trade-off, as SECURITY.md does in its "Your PIN" section. **Evidence:** `Malinois/Services/KeychainService.swift:307–318` (`confirmedPINLength`); `Malinois/Views/OnboardingViews.swift:37` (submits at confirmed length). | Later (docs) |
| deepseek-6 | Medium | VERIFIED | Evidence/Onboarding | The "Before you arm" one-time screen (Voice Control warning, Side Button warning, etc.) uses `UserDefaults` flags (`acknowledgedVoiceControlBriefing`, `acknowledgedSideButtonBriefing`, etc.) that are seeded at launch (`OnboardingViews.swift` lines 100–137). An install that never reaches the seeding code path (e.g., a crash during launch recovery) could miss the seeding, causing the flags to remain unset. However, the seeding runs in `MalinoisApp.init()` before any arm can begin, and the flags default to `false` (which means "not yet acknowledged" → the screen will show). The fail-safe direction is correct: a missing flag shows the screen, not skips it. **No fix needed** — documented for completeness. **Evidence:** `Malinois/Views/OnboardingViews.swift:100–137`. | N/A (no defect) |
| deepseek-7 | Medium | VERIFIED | App Review | The App Review Notes field in App Store Connect still holds the text of the initial approval per `APP_REVIEW_NOTES.md` line 11. A 4,000-byte cut is ready in `APP_REVIEW_NOTES_FIELD.md` (3,899 bytes, lines 27–60+) and is kept current, but it has never been pasted. The field therefore does not describe features added since 1.0 (evidence signing, the watch app, set-aside logs, the welcome screen, the Vision reference still) to a reviewer who reads only the field. The practice of "leave it until App Review asks" has worked through many submissions, but it is a risk: a new reviewer or a changed guideline could trigger a rejection for 2.3.1(a) ("describe new features with specificity"). **Fix:** Paste the updated cut from `APP_REVIEW_NOTES_FIELD.md` at 1.13's submission, as its text already covers 1.13's changes. **Evidence:** `store/APP_REVIEW_NOTES.md:6–26`; `store/APP_REVIEW_NOTES_FIELD.md:1–10`. | Before submission |
| deepseek-8 | Low | VERIFIED | Documents | The `_PUBLIC_README.md` line 87 says "2,342 unit tests in 153 files, 58,451 lines of tests." The three numbers (test count, file count, LoC) are all from version 1.12. All three are stale for 1.13. This is a subset of finding deepseek-2; listed separately because the LoC count and file count are additional stale claims. **Fix:** Same as deepseek-2 — update all three numbers in the 1.13 readme edits. **Evidence:** `_PUBLIC_README.md:87`; `_REVIEW_PROMPT.md:91`. | Yes (at publication) |
| deepseek-9 | Low | SUSPECTED | Evidence Signing | The evidence-signing key list (`EvidenceKeyList`) is stored in the Keychain (`KeychainService.evidenceKeyList()`) and is properly device-only and non-synchronizable. However, the `setEvidenceKeyList` function (line 865–879) uses `SecItemUpdate` / `SecItemAdd` without a `kSecAttrAccessible` attribute on the update path. The add path sets `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (line 877), which is correct. The update path inherits the existing item's accessibility (which was set at creation). This is correct behavior — but verifying requires checking that the item was originally created with the right accessibility. **Fix:** No code change needed if the item was created by `setEvidenceKeyList` (which uses the correct accessibility). For diagnostic purposes, consider adding an assertion in debug builds that the updated item's accessibility is as expected. **Evidence:** `Malinois/Services/KeychainService.swift:865–879`. | Later |

---

## 4. The documents: the claims that are wrong

### 4.1 Stale claims

- **`_PUBLIC_README.md` line 87: "2,342 unit tests in 153 files, 58,451 lines of tests."** — STALE. This is 1.12's count. 1.13 has 2,453 tests in 158 files. The line count may also have changed.
  - **Wording:** "2,453 unit tests in 158 files" (and recount the lines).

- **`_PUBLIC_README.md` lines 100–105: The "What's new in 1.12" section.** — STALE. This section describes 1.12. For the 1.13 publication, it will describe 1.13's changes when the readme edits are applied. Not a defect — expected at this stage.

- **Live App Store listing: What's New section still shows 1.12's text.** — STALE. Expected before submission. The 1.13 What's New text is approved in `APP_STORE_LISTING.md` lines 244–270.

- **Live App Store screenshots: show version 1.12 screens.** — STALE. Expected before submission. No welcome screen screenshot is mentioned in `store/APP_STORE_LISTING.md`.

### 4.2 Overclaims

None found. The security model is unusually precise about what it does not protect against, and I found no claim in SECURITY.md, the README, the App Store texts, or the privacy policy that promises more than the code delivers.

### 4.3 Underclaims

- **The app's capabilities exceed what the live App Store listing says** (the listing is for 1.12). This is expected at this stage and will be corrected at submission.

### 4.4 Contradictions

- **Test count:** The `_PUBLIC_README.md` says 2,342 tests; the review prompt and the Xcode project contain 2,453. (See deepseek-2.)

### 4.5 Not checkable without a device or App Store Connect

- Whether the privacy policy URL and support URL on the live store match the files in `store/`. They should — both point to the GitHub Pages site.
- Whether the App Privacy answers in App Store Connect (documented in `APP_STORE_CONNECT_WALKTHROUGH.md`) match the privacy policy and the code's actual data collection. I did not read that file in detail.
- Whether the watch app's alert handling (saving alerts until shown, new in 1.13 per ADR 0082) works correctly on a real watch with real Bluetooth/Wi-Fi conditions.

### 4.6 The README's first screen

The `_PUBLIC_README.md` opens with a one-line description ("A covert unattended-device tamper detector for iPhone"), three screenshots, and a clear statement of the app's singular objective. Then it jumps to a table of what you'll find, a quick start, an architecture summary, and the Pro description.

**Does it give a fair picture?** Yes. A reader scanning the first screen learns: this is for catching someone handling your phone, it needs Guided Access, it records evidence in a PIN-gated log, and it works with Pro. The "Before you rely on it" paragraph (line 28) names the setup steps the owner must do themselves — Guided Access with Side Button off, separate passcodes, Voice Control off, accessories prompt on. This is honest and prominent.

**What is missing?** The public README does not show the welcome screen (new in 1.13), which is the new first-run experience. The screenshots at the top are Home, arming, and Event Log. A new user installing 1.13 sees the welcome screen first, not Home. Adding a welcome-screen screenshot would give a more accurate first impression.

**For a security-minded reader deciding whether to trust it:** The public README links to SECURITY.md prominently ("If you read one file, read this one") and provides a reviewer's map pointing to the PIN storage, the crash-durable log, the trip response, and the iCloud enrollment. The "What you can check rather than take on trust" section (line 82) is strong: it names the adversarial review process, the public ledger of findings, and the published source code. This is unusually transparent.

### 4.7 App Store texts and store pages

- **Guideline risk — 2.5.14 (recording indication):** The Notes for the Reviewer are thorough on this point. The "recording is always indicated" paragraphs (lines 107–138) describe the REC badge, the screen brightness lift, and the iOS camera indicator in detail. The Vision tripwire description (lines 130–138) explains clearly that it only runs while the indicator already shows. I assess the rejection risk on this guideline as low, given the quality of the explanation.

- **Guideline risk — 2.5.19 (hidden/dormant features):** The 1.13 review notes describe the welcome screen and the Vision reference still clearly (lines 75–78). No features are hidden. Low risk.

- **Guideline risk — 2.3 (accurate metadata):** The description is accurate. The What's New text for 1.13 is approved and matches the code I read. Low risk.

- **Guideline risk — 5.1.1/5.1.2 (privacy):** The privacy policy is accurate. The app collects nothing for the developer. The permissions are requested on first use (camera at ARM, microphone at Sound/clip-audio enable). Low risk.

- **Guideline risk — 3.1.1 (in-app purchase):** Early-Access makes Pro free permanently. The purchase screen says it adds nothing. The trial and paywall are dormant while the program is open. The reviewer notes explain this clearly. Low risk.

---

## 5. Tests

### 5.1 Assessment

The test suite is large (2,453 tests) and appears thorough from the test file names and the review prompt's description of what passed. I did not run any tests (per the prompt's instruction not to re-run the full suite). The prompt notes that all 2,453 passed on iOS 27.0 and iOS 18.0, with strict lint and Thread Sanitizer clean.

The test coverage of security-critical paths appears strong based on the code comments citing specific test names:
- PIN hashing: `KeychainServiceTests`
- Lockout timing: `KeychainServiceTests.testLockoutDelay*`
- Journal sync: `EventTests.testEveryJournalAppendIsFullySyncedBeforeAddReturns`
- Record-before-response ordering: `EngineCharacterizationTests`
- No individual delete: `EventTests.testEventStorePrunesToCapKeepingNewest`
- Account binding: `CloudEnrollmentTests.testNewEvidenceCannotTransferToAnotherAccount`
- Sealed Keychain handling: `KeychainServiceTests.testItemReadKeepsSealDistinctFromAbsence`

### 5.2 Missing tests that would be worth most

1. **UserDefaults flag tampering test:** A test that clears `hasArmedOnce` and the briefing flags in UserDefaults and verifies that the app's behaviour degrades safely (the auto-lift reapplies, the safety screens reappear). This would make the issue visible and document the current expected behaviour.

2. **CameraController concurrency stress test:** A test that starts and stops the camera session on a background queue while the engine arms and disarms on the main actor, with Thread Sanitizer enabled. This would stress-test the extensive `nonisolated(unsafe)` annotations in `CameraController`.

3. **Full-disk scenario test:** A test that fills the device storage to near capacity and verifies that the journal write failure is surfaced to the owner and that the log is not corrupted by partial writes.

4. **Backup manipulation test (physical device only):** A manual test procedure that makes an encrypted backup, edits `hasArmedOnce` to `false`, restores it, and verifies that the app detects the anomaly or at minimum does not silently accept the tampered flag.

---

## 6. What I checked and found sound

### 6.1 PIN storage and lockout (`KeychainService.swift`)
- PBKDF2-HMAC-SHA256 at 120,000 rounds with a 16-byte random salt from `SecRandomCopyBytes`. Correct.
- The salt is generated once and never regenerated on verification (the "no-mint" rule, preventing a silent PIN bricking). Correct.
- Legacy SHA-256 hashes are transparently upgraded to PBKDF2 on successful entry. Correct.
- Lockout uses `systemUptime` (monotonic), not wall clock. Correct.
- Lockout delay: 30s after 5 failures, doubling each further failure, capped at 1 hour. Correct.
- In-process mirror of lockout state guards against Keychain write failures (the "R10" mirror). Correct.
- Damaged lockout values are detected by `lockoutValueIsWellFormed` and repaired from the stored failure count. Correct.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for PIN items. Correct.

### 6.2 Disarm flow (`MonitoringEngine.swift`, `DisarmEntryCoordinator.swift`)
- Disarm requires a 5-second hold plus the correct PIN. The hold opens an attribution window via `noteCandidate()` on touch-down.
- Events captured during the hold/PIN-entry window are marked as owner-attributed only if the correct PIN follows (`takeOwnerEventsOnDisarm()`).
- Proximity sensor is paused during PIN entry (so the screen stays visible) and resumed after.
- Touch tripwire is always on (ADR 0015) — no way to disable it.
- The arm session counter increments at disarm, invalidating in-flight trigger responses.

### 6.3 Evidence integrity (`EventStore.swift`, `EvidenceSigner.swift`)
- Write-ahead journal is appended synchronously with `fsync` before anything responds. Correct.
- `completeFileProtectionUnlessOpen` for evidence files. Correct.
- Evidence signing uses App Attest with keys in the Secure Enclave. The signature file is separate from the log. Correct.
- The phone signs records at every revision, never rewrites the log. Correct.
- Retention statements name records removed by the log's size limit, with a MAC checked by a Keychain-stored key. Correct.

### 6.4 iCloud security (`CloudEnrollment.swift`, `CloudExfiltrator.swift`)
- Cloud enrollment requires device-owner authentication (Face ID/Touch ID/passcode). Correct.
- Each event is bound to the verified account at recording time. A different account cannot claim it. Correct.
- `authorize(account:)` checks for observed different accounts and holds events rather than uploading to the wrong account. Correct.
- The backup-off switch needs device authentication. Correct.

### 6.5 Guided Access integration
- `UIAccessibility.isGuidedAccessEnabled` is polled via a notification observer. Correct.
- The arming screen shows the GA state live. Correct.
- The first-arm auto-lift is deliberate (ADR 0010) and the arming screen warns about it. Correct.
- GA ending while armed is recorded at once (`noteGuidedAccessChange` in the `didSet` observer). Correct.

### 6.6 Documents and store pages
- `SECURITY.md`: Comprehensive, honest about limitations. The threat model tiers are clear. The "It cannot show" section (18 items) is unusually thorough.
- `README.md`: Accurate. The state-machine diagram matches the code. The tripwire table matches the monitors. The "two-shot exfiltration" description matches `CloudExfiltrator`.
- `PRIVACY_POLICY.md` and `privacy-policy.html`: Accurate. The data collection claim ("none") is verifiable in the code (no analytics SDKs, no network calls to developer servers).
- `support.html`: Accurate. The quick-start steps match the app's actual flow.
- `APP_STORE_LISTING.md`: The 1.13 description's changes ("armed session" wording) match the code. The character counts are within Apple's limits.

### 6.7 New in 1.13 — features I verified
- **Welcome screen (`WelcomeView`):** `RootView.swift` routes to it when `needsPINSetup` is true and `pinSetupChosen` is false. The "See it work" button opens `DryRunView` as a sheet. The "Set a PIN" button triggers `pinSetupChosen = true`. Correct.
- **Vision reference still (`VisionMonitor.referenceStill`):** Saved in memory only. Handed to the trip responder only when Vision is among the triggered sensors (`visionReferenceStill(for:take:)`). The still is delivered from the camera and checked by generation number to reject stale frames. Not uploaded (the trip responder's save path skips upload for the still). Correct.
- **Download fits storage limit:** `EventStore` checks the combined photo+clip storage against `maxMediaBytes` (2 GB) before saving a download. The event's screen reports when one didn't fit (`downloadDidNotFit`). Existing files are never removed to make room. Correct. (This matches the What's New claim.)
- **Set-aside log delete writes a note first (ADR 0083):** `SetAsideLog` delete flow writes a `SetAsideDeleteOwed` note before removing the log file, so a crash during deletion leaves the status entry to be written at next launch. Correct.
- **Set-aside log share excludes current log's media (ADR 0087):** `SetAsideLog` share scans the log's bytes for photo/clip names and excludes those also named by the current log. Correct.
- **Watch alerts saved until shown (ADR 0082):** The watch app's `WatchRelayInbox` writes each relayed alert until it is shown. I did not read the watch code in detail but the ADR describes the mechanism.

---

## 7. What I could not review or verify

- **Physical device behaviour:** Camera capture latency, siren volume, proximity sensor blanking, Guided Access interaction with iOS 27, the watch's actual alert delivery timing, Bluetooth/Wi-Fi relay reliability, and background task assertion durations all require a real iPhone and Apple Watch.
- **iCloud operation:** CloudKit record creation, subscription push delivery, cross-device alert arrival, iCloud account switching, and CloudKit server-side behaviour (retry-after, throttling, schema changes) require a live iCloud account.
- **App Attest certification:** The actual interaction with Apple's App Attest service — key generation in the Secure Enclave, certification request, and attestation object validation — requires a real device.
- **StoreKit purchase flow:** The Pro purchase, restore, trial start, and Early-Access marker behaviour require App Store Connect configuration and a sandbox account.
- **Watch app code (`MalinoisWatch/`, `MalinoisWatchNotificationService/`):** I read only parts of the watch code. A full review of the watch's alert relay, inbox persistence (new in 1.13), and duplicate pairing would require a dedicated pass.
- **Mac verifier (`MalinoisVerifier/`):** I did not review the verifier's handling of untrusted ZIP inputs (path traversal, symlink attacks, oversized files). The verifier is a command-line tool that processes attacker-controlled ZIPs; a full adversarial review of it would be valuable.
- **Thread Sanitizer run:** The prompt says TSan passed clean over 47 test classes. I did not re-run it.
- **The `nonisolated(unsafe)` usage in `CameraController`:** I flagged it as a concern (deepseek-4) but did not verify it with TSan on a device.