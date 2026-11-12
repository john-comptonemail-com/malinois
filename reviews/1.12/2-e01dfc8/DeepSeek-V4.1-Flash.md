# Malinois 1.12 (87) — an independent review

**Reviewer:** DeepSeek V4.1 Flash
**Date:** 2026-11-11
**Folder:** (the review folder)

**Tests run:** none of the app's. The prompt says the full suite passed on these app files on iOS 27.0 and iOS 18.0, and I did not repeat it. Everything below is from reading the code and the documents in this folder. I ran one standalone Swift probe outside the folder (ten lines, on `FileManager`'s attribute behaviour) to check the premise of the app's link and folder protections; it confirmed that `attributesOfItem` does not follow a symbolic link, which is what those protections rely on. I did not build the app, boot a Simulator, or touch a device.

---

## 1. For the owner, in plain English

Malinois is in unusually good shape. I did not find a way past the PIN or Guided Access, a way to lose or forge evidence without the owner being told, a way to make an edited bundle pass the verifier, or anything that would make App Review reject 1.12 (87). The code around the new set-aside log is careful in exactly the places that matter: it will not follow a link or a folder put there by an edited backup, it will not delete a photo while the live log, the on-disk log, a capture being saved or another set-aside log still names it, and when it cannot tell it leaves the photos and says so.

What I did find is smaller, and mostly about what the new screens and the public documents **promise** rather than what the code does. In order of what I would fix first:

1. **A shared set-aside ZIP can leave out the very photos and clips its README says it contains.** The README inside the ZIP says it holds "the photos and clips it names". If a photo is no longer on the iPhone, the ZIP simply has no `Media` folder and no note; the owner is not told either. SECURITY.md already has the right words ("that are still on the phone"); the ZIP's README does not. A recipient could believe the ZIP is complete. *What I would do:* change the one sentence to "with the photos and clips it names that are still on this iPhone", and show a line on the set-aside screen before sharing when one or more are missing (or at least after sharing). This is a small change and the owner's approval is needed for the wording; I would do it before 1.12 (87) is archived, because the sentence travels into every set-aside ZIP the app sends.

2. **Tapping Share on a set-aside log can do nothing at all, silently.** If the ZIP cannot be made (a full disk, an unreadable log file, a photo that cannot be copied), the code swallows the error and simply returns. The spinner stops, no share sheet opens, and nothing says why. The owner may believe they have sent the evidence. *What I would do:* show a short line, "The log couldn't be prepared to share. Nothing was sent.", and allow a retry; or, as a fallback, offer the log file alone with the same README. Cheap; I would do it before archiving if it fits.

3. **A damaged set-aside log can hide readable records from its own screen.** The reader handles a record it cannot decode correctly, but if a list element is not a JSON object at all (a `null`, a number, or an early `]`), it stops and counts everything after it as one unreadable part. The screen then shows fewer records than the file actually contains, and the owner may believe the rest were lost. *What I would do:* skip to the next element at the top level and carry on, or count each element separately. This one can wait; the Share still sends the file whole, and Delete uses the file's bytes, not the screen.

4. **The public retention promises do not mention the one kind of evidence that is never pruned.** The privacy policy says local evidence is kept "up to the app's storage limits, after which the oldest items are pruned automatically", and the support page says the log "retires the oldest automatically". A set-aside log and the photos and clips it names are never pruned; the app's own SECURITY.md says no launch deletes them. An owner whose log has been set aside can therefore carry that evidence (and its storage) indefinitely without the public documents saying so, until they find the new Delete. *What I would do:* add one sentence to the privacy policy and the support page: a set-aside log is kept until you delete it in the Event Log, and the storage limits do not remove it. These are live web pages and can be updated without a new build.

5. **The new set-aside Share and Delete scan the log once for every photo name.** With the app's own maximum of 600 events and up to 1,200 media names, a large damaged log (thumbnails can make it tens of megabytes) turns Share or Delete into minutes of scanning; there is no progress and no cancel. I did not measure this on a device, so the user-visible time is SUSPECTED, but the cost is plain in the code. *What I would do:* find all the names in one pass (or stop after the media folder is exhausted), and show progress if the work can still be long. This can wait.

**Would I let 1.12 (87) go to TestFlight now?** Yes. Nothing here is a reason to hold a build: the code paths that protect evidence and the PIN are sound, and the existing suite covers the new feature well.

**Would I let it go to the App Store?** Yes, after items 1 and 4 are fixed; both are words, not mechanisms, and both are seen by people outside the app (a recipient of a ZIP, a reader of the privacy policy). Item 2 is worth fixing in the same pass. Items 3 and 5 can be 1.12.1. If the owner prefers to ship without touching the approved ZIP wording, I would still ship; I would not call any of this a blocker.

---

## 2. Findings, most severe first

### DS-1 — The set-aside ZIP's README says it contains the photos and clips the log names, but the ZIP can contain none of them, with no note — **Medium** — VERIFIED

**What is wrong.** `SetAsideLogWords.readme` (Malinois/Models/SetAsideLog.swift:268-269) says:

> "This ZIP contains an event log Malinois set aside because it couldn't be read, with the photos and clips it names. It is not signed evidence: it is the file as the phone kept it. Malinois's verifier does not check it."

The first sentence is not always true. `SetAsideLogShare.folder` (SetAsideLog.swift:300-321) copies a media file only when (a) it is still in the media folder (`onPhone`, lines 307-308), (b) its name is one the store gives (line 311), and (c) it is a plain file (line 312). If none qualify, line 314 returns the folder with the README and the log and **no `Media` folder at all**. The Share screen (Malinois/Views/SetAsideLogView.swift:112-123) opens the sheet with whatever ZIP came back, and says nothing about what was left out.

**A concrete situation.** The owner restores an iCloud or computer backup after the event log was damaged. The backup brings the set-aside log, but not all of its photos (a partial restore, or the media was never in that backup). The log names twelve photos; seven are on the phone. The owner opens the set-aside log, taps Share, and sends the ZIP to building security or the police. The ZIP holds the log and seven photos, and a README saying it contains "the photos and clips it names". The recipient has no way to know five are missing; the owner saw no warning. The same happens if the media folder is a link or a folder (only an edited backup puts that there) or if a named file is a folder rather than a file: the app deliberately leaves the media out (correctly) but still says it included them.

**Evidence.** SetAsideLog.swift:268-269 (the words), 300-321 (the copy rules), especially 307-314; the existing test `testShareTakesNothingThroughALinkedMediaFolder` (MalinoisTests/Item122SetAsideLogTests.swift:1083-1097) proves the ZIP can be "README.txt and the log" with no Media; the test `testShareCarriesTheFileAsKeptItsMediaAndAReadme` (same file, 302-323) proves the README is the fixed string even when media are present. SECURITY.md:1852-1853 already says "with the photos and clips it names that are still on the phone", so the app's own security document and the ZIP's README disagree.

**Smallest fix.** Change the first sentence to "with the photos and clips it names that are still on this iPhone" (or "that are still on the phone"), and update the test that pins the string. A second, optional sentence ("Photos or clips no longer on the iPhone are not in this ZIP.") would make the recipient's reading unambiguous; the app's verifier refuses the ZIP anyway, so the README is the only place the recipient is told.

**Probe.** A unit test that makes a set-aside log naming `X.jpg`, does not create `X.jpg`, and asserts the README's text; or a UI/unit test that the screen shows a line when the number of named files on the phone is less than the number the log names. Today the first is not covered: the existing tests have the media present or the folder linked.

**When.** Before 1.12 (87) is archived, if the owner approves the wording. It is a string and a test; the feature's behavior is unchanged.

---

### DS-2 — Share of a set-aside log fails silently when the ZIP cannot be made — **Medium** — VERIFIED

**What is wrong.** `SetAsideLogView.startShare` (Malinois/Views/SetAsideLogView.swift:112-123) runs `try? SetAsideLogShare.zip(...)` and, when the result is nil, returns without changing anything but `preparing = false`. The owner sees the spinner stop and no sheet. There is no error line, no retry prompt, and no fallback to sharing the log file by itself. `SetAsideLogShare.folder` returns nil for a log that is not a plain file or cannot be read (SetAsideLog.swift:301), and `zip` throws (and is swallowed by `try?`) when a media copy or the ZIP itself fails (SetAsideLog.swift:326-344).

**A concrete situation.** The iPhone is nearly full (the app itself keeps up to 2 GB of media). The owner opens a set-aside log with a 600 MB clip, taps Share; copying the clip into the temporary folder fails with "no space"; the throw is discarded; the sheet never opens. The owner taps Share again; the same. Nothing in the app records the failure or tells them; the event's screen and the set-aside screen both look as if the tap did nothing.

**Evidence.** SetAsideLogView.swift:117 (`try?` and the nil guard), 119-121 (`guard let zip else { return }`); SetAsideLog.swift:326-344 (the throwing zip); the existing tests do not cover the screen's failure path (they test `SetAsideLogShare.folder` and `zip` directly, not the view's handling).

**Smallest fix.** Keep the error (do not use `try?` in the view), and show a line on the screen: "The log couldn't be prepared to share. Nothing was sent. Try again, or free some space." A fallback that shares the log file alone is acceptable only if it carries the same README and the log's bytes; but the error line is the smallest change.

**Probe.** A unit test of the view's action is awkward in SwiftUI; a small extracted state machine (preparing / ready / failed) would let the test call the action with a throwing stub and assert the failure line. Manual: `chmod 000` the log file (or fill the disk) and tap Share; today nothing happens.

**When.** Before archiving if it fits; otherwise 1.12.1. It is an interaction failure, not a data failure: the log and media stay on the phone.

---

### DS-3 — The set-aside screen stops reading at the first list element that is not an object, hiding every readable record after it — **Low** — VERIFIED

**What is wrong.** `SetAsideLog.reading` walks the JSON list element by element, but at SetAsideLog.swift:147-150 it requires the next byte to be `{`; anything else (a `null`, a number, a string, an array, or a `]` where a record should be) increments `unreadable` and **breaks out of the loop**. Everything after that element is counted as one unreadable part and never shown. The reader's own doc (lines 110-114) says "a record this build cannot read ... cost that record only", and the What's New says the screen shows "the records it could read". For an element that is a non-object, both are untrue.

**A concrete situation.** A log picks up one damaged element (a byte flip that turns the `{` of a record into `n`, a file edited by another tool, or a stray `]`). The screen shows the records before it and "1 unreadable"; the dozens of intact records after it are missing from the screen. The owner believes the rest of the log was lost; if they delete the log on that basis, the file and its photos are deleted (the app's Delete is honest about deleting the whole log, but the owner's decision was made on an incomplete screen). The Share still sends the whole file, so a recipient can parse the rest, but the owner cannot see it.

**Evidence.** SetAsideLog.swift:115-158, especially 147-150; the test `testBytesAfterTheListsEndCountAsOneUnreadablePart` (Item122SetAsideLogTests.swift:105-121) confirms the early-`]` case is treated as a break (it expects one unreadable and the first record only). The non-object-element case has no test at all.

**Smallest fix.** In the loop, when the byte is not `{` and `objectEnd` returns nil, skip forward to the next top-level `,` or `]` (tracking strings and nesting, which `objectEnd` already does) and count one unreadable part, then continue; or parse each element with a small element-end scanner and decode the element if it is an object. Keep the current one-part count for a real cut-off (no `,` or `]` before the end).

**Probe.** Add to `Item122SetAsideLogTests`:
```swift
let data = Data("[null,\(String(data: try JSONEncoder().encode(event(1)), encoding: .utf8)!)]".utf8)
let reading = SetAsideLog.reading(data)
XCTAssertEqual(reading.records.map(\.id), [event(1).id])
XCTAssertEqual(reading.unreadable, 1)
```
Today the `records` array is empty and the intact record is lost from the screen.

**When.** Later; it is display-only, and Share/Delete use the file itself.

---

### DS-4 — The privacy policy and the support page say evidence is pruned at the storage limits; a set-aside log and its media never are — **Medium (documentation)** — VERIFIED

**What is wrong.** `store/PRIVACY_POLICY.md:131-133` says "Evidence is retained locally up to the app's storage limits, after which the oldest items are pruned automatically." `store/support.html:285-287` says "It keeps your recent events and retires the oldest automatically." Both statements are false for a set-aside event log: `EventStore.sweepOrphanedMedia` refuses to sweep while any `events.corrupt-…` name exists (EventStore.swift:1481, 1568-1577), `SetAsideLog.all` lists them until the owner deletes one, and SECURITY.md:1844-1847 says "no launch deletes the backup or the photos and clips it refers to". The new 1.12 Delete is the only way they go while the app stays installed; the public pages do not mention it.

**A concrete situation.** An owner has a 64 GB iPhone with a full event log of clips. A crash leaves a damaged log; the app sets it aside and starts fresh. The owner never opens the Event Log's set-aside screen (or does not know it is there). The set-aside log and up to 2 GB of its media stay forever; the storage limits do not touch them. The owner reads the privacy policy, believes the "oldest items" are being pruned, and is surprised when the phone runs out of space; they might delete the app (and the evidence) to reclaim it, which the policy's next sentence allows but does not connect to the set-aside log.

**Evidence.** Privacy policy:131-133; support page:285-287; SECURITY.md:1844-1857; EventStore.swift:1453-1503 (the sweep), 1481 (`corruptBackupPresent`), 1568-1577 (`orphanedMediaNames` returns `[]` while a backup exists); SetAsideLog.swift:30-35 (every set-aside log is listed, none is reaped). The app's own Settings/Event Log copy tells the owner the log is kept, but the public retention pages do not.

**Smallest fix.** Add to the privacy policy's retention section: "A copy of the event log Malinois set aside because it could not be read is kept until you delete it, with the photos and clips it names; the storage limits do not remove it. You can delete it in the Event Log." Add one sentence to the support page's "Can evidence be deleted?" answer: "A set-aside log is the one exception: the Event Log lists it and lets you delete it, with the photos and clips only it names." The privacy policy and support page are live web pages and do not need a build.

**Probe.** A document check: grep the two pages for "set aside"/"set-aside"; today neither mentions it. Compare with the app's `SetAsideLogWords.home` and the Event Log's Delete; the app's behavior is right, the pages are not.

**When.** Before 1.12 (87) is submitted, since both pages are public and the feature is new; no app build needed.

---

### DS-5 — Share and Delete scan the whole set-aside log once for every photo or clip name — **Low** — VERIFIED (cost) / SUSPECTED (the time on a device)

**What is wrong.** `SetAsideLogShare.folder` (SetAsideLog.swift:307-313) takes the media folder's listing and, for each name, calls `SetAsideLog.names(name, in: forms)`, which does `Data.range(of:)` over the whole log (lines 96-98). `deleteSetAsideLogOnQueue` does the same at EventStore.swift:2994, and `mediaNamesSetAsideLogsReference` does it for each name against each set-aside log (EventStore.swift:1420-1433). The log's size is bounded by the event count and thumbnails, but the number of media names is up to 1,200, so the work is `names × log bytes`; a 40 MB log and 1,200 names is tens of gigabytes of scanning. The Share is on a detached task with a spinner and no cancel; the Delete is on the store's I/O queue behind a disabled button. The app's own media cap allows 2 GB, so the media folder can be at the top of this range.

**A concrete situation.** A user with a long-running log (600 events, many thumbnails) has one corruption, then another weeks later, then a third; each set-aside log is kept. They open the oldest and tap Share to send everything to the police. The screen shows a spinner for a long time (I did not measure it on a phone; on the Simulator it will be faster) with no progress and no way to cancel; the same on Delete. It still finishes, and the result is correct, but it reads as a hang, and a user may force-quit a share that was working.

**Evidence.** SetAsideLog.swift:96-98 and 307-313; EventStore.swift:2994; 1420-1433. The tests use tiny logs and a handful of names (Item122SetAsideLogTests), so the cost is not measured. The app's own media cap is `EventStore.maxMediaBytes = 2_000_000_000` (EventStore.swift:102), and the log's count cap is 600 events.

**Smallest fix.** Scan the log once for all candidate names: since the names the app gives are 40-byte UUID-plus-extension strings, extract the 40-byte candidates from the log's bytes (and their `\u`-read form) into a set in one pass, then intersect with the media folder's listing. This keeps the current semantics (the search finds every spelling of a name the store gives) and removes the multiplication. A second, independent improvement is a progress/cancel state in the Share.

**Probe.** A performance test with a synthetic log of 600 records (thumbnails of 64 KB) and 1,200 media names, measuring `SetAsideLogShare.folder` and `deleteSetAsideLogOnQueue`; mark the actual duration SUSPECTED until run on a device. A correctness test for the one-pass finder should reuse the existing escape tests (`testANameWrittenWithAnEscapeIsFound`, etc.).

**When.** Later (1.12.1); it is a responsiveness issue, not a correctness one.

---

## 3. Wrong claims in the documents

I checked the documents as a user would. The ones below are wrong or, in two cases, a wording question for the owner; the rest of the set-aside and signing text matched the code.

1. **The set-aside ZIP's README.** "This ZIP contains an event log ... with the photos and clips it names." (SetAsideLog.swift:268-269.) Wrong when any named photo or clip is no longer on the phone, or is a link or a folder (the ZIP then has no `Media` or fewer files). SECURITY.md:1852-1853 has the correct form: "with the photos and clips it names that are still on the phone." **Wording I would use:** "This ZIP contains an event log Malinois set aside because it couldn't be read, with the photos and clips it names that are still on this iPhone. It is not signed evidence: it is the file as the phone kept it. Malinois's verifier does not check it."

2. **The App Store What's New line, 1.12.** "share it as your iPhone kept it (not as signed evidence) with the photos and clips it names" (store/APP_STORE_LISTING.md:256). The owner approved this line, and it is a summary; it has the same overbreadth as the ZIP's README. If the owner wants the listing to match the ZIP, the smallest change is "with the photos and clips it names that are still on it"; it adds 21 characters, so the line count changes from 1,078 and the owner should approve and re-count. I would not hold the submission for this one; the ZIP's README is the document a recipient reads.

3. **The privacy policy's retention sentence.** "Evidence is retained locally up to the app's storage limits, after which the oldest items are pruned automatically." (store/PRIVACY_POLICY.md:131-133.) False for a set-aside log and its media, which are never pruned (SECURITY.md:1844-1847; EventStore.swift:1481, 1568-1577). **Wording:** add "A copy of the event log Malinois set aside because it could not be read is kept until you delete it, with the photos and clips it names; the storage limits do not remove it. You can delete it in the Event Log."

4. **The support page's answer to "Can evidence be deleted?"** "It keeps your recent events and retires the oldest automatically." (store/support.html:285-287.) The set-aside log is not retired, and the new Delete is not mentioned. **Wording:** "It keeps your recent events and retires the oldest automatically, except a log Malinois set aside because it could not be read: the Event Log lists it, and you can delete it there, with the photos and clips only it names."

5. **The in-app Delete confirmation.** "The photos and clips only it names are deleted from this iPhone too..." (SetAsideLogWords.deleteMessage, SetAsideLog.swift:241-243.) The app deliberately deletes only files under a name the store gives (a capital UUID and `.jpg` or `.mov`); a file the log names under another name (only an edited backup) is left, and the Delete can still report a whole delete with no notice (SetAsideLog.swift:2994; the test `testDeleteRemovesNoFileUnderANameTheStoreNeverGives`, Item122SetAsideLogTests.swift:1679). SECURITY.md:1857-1860 explains the rule; the in-app confirmation does not. **Wording:** "The photos and clips Malinois named (a UUID and .jpg or .mov) that only it names are deleted from this iPhone too..." or a second sentence: "A file under any other name is not Malinois's and stays." This is a wording question; the behavior is deliberate and correct for an edited backup.

6. **The Settings signing-key footer (optional).** "Each evidence ZIP you share is signed with this key..." (SigningKeyRow.swift:28-30.) The export statement is signed with the current key, but an older event's record inside the ZIP can carry an earlier key of the same iPhone (the footer's own next sentence says a new key is made after a reinstall, a new iPhone, or a lost key). A recipient comparing the record's key with the given ID sees a different key and may read it as another phone's. The SECURITY.md wording is careful ("the export's key the check names"). **Wording:** "Each evidence ZIP you share is signed with the key in use when you share it; an older event's record may carry an earlier key of this iPhone, which the check shows." The owner approved the current wording, so this is a judgement for the owner, not a defect.

7. **The support page's "Deleting Malinois deletes everything stored on the iPhone."** (store/support.html:286-287.) The privacy policy lists what survives in the Keychain (the PIN, the signing-key list, the limit-removals key, the trial/membership markers). The support page's sentence is about evidence, but "everything" is broader than the truth. **Wording:** "Deleting Malinois deletes everything it stored in the app's files on the iPhone; the privacy policy lists the few Keychain items that stay."

---

## 4. Where I went

I read the open prompt first and did not open `_REVIEW_PROMPT.md` or any other report. I changed nothing in the folder but this file. I did not open the repository or any other review folder.

**What I read, and found sound:**

- **The new set-aside log, end to end.** `Malinois/Models/SetAsideLog.swift`, `Malinois/Views/SetAsideLogView.swift`, `Malinois/Views/EventLogView.swift`, `Malinois/Views/HomeView.swift`, and the set-aside parts of `Malinois/Services/EventStore.swift` (creation in `setAside`, the listing, the delete, the media protections, the launch sweep). I traced the Delete's decision in detail: the log is deleted first; the media folder must be a real folder; only plain files under a store name go; the event log in memory and on disk, the capture intents and the other set-aside logs are all consulted; when any of them cannot be read, nothing more is deleted and the Event Log says so. I believe this is correct, and the tests in `MalinoisTests/Item122SetAsideLogTests.swift` (roughly 100 cases) cover the link/folder/escape cases well. The one behaviour I would call a judgement, not a defect, is the live event's media path (`EventStore.mediaURL(for:)`) still reading through a linked media folder, while the set-aside path does not; the code says this is the owner's ruling of 2026-11-10, and the two paths are clearly marked.
- **The evidence bundle and the Mac verifier.** `MalinoisEvidence/EvidenceBundle.swift`, `EvidenceVerifier.swift`, `EvidenceForm.swift`, `EvidenceJSON.swift`, `EvidenceAuthenticatorData.swift`, `MalinoisVerifier/MalinoisVerifier.swift`, `MalinoisVerifier/main.swift`, and `Malinois/Services/EvidenceExporter.swift`, `EvidenceSigner.swift`, `EvidenceSignatureFile.swift`. I looked for a way a tampered bundle could pass: a re-signed record at the same revision (the revision order check catches it), a removed signature line (the counter gaps catch it), an unrelated key (the export lineage and `unnamed`/`unrelatedKeys` catch it), a missing export (a problem), a ZIP with a second index or a `._` entry (the layout and count checks catch it), a link or a path outside the bundle (refused), a report line that a sender could forge (the text is escaped). The exporter requires every attachment the latest revision signed, or it makes no bundle, so the signed bundle's README's claim about its media is backed; the verifier reports `notInBundle` as a problem, so a check cannot pass with a missing one.
- **The PIN, the lockout, biometrics, Guided Access.** `KeychainService.swift` (PBKDF2, per-item accessibility, the monotonic-uptime lockout, the in-process mirror, the "sealed" reads), `PINViews.swift`, `BiometricBinding.swift`, `MonitoringArmingFlow+Transitions.swift`, `MonitoringEngine+ArmPINCheck.swift`, `RootView`/`HomeView`'s gates. The log and Settings gates use biometrics without a passcode fallback; disarm and the PIN change are PIN-only; a device passcode is used only for PIN recovery and cloud verification, which is the documented model. Arming is refused while the Pro check resolves, Guided Access is required by default with the first-arm lift, and the crash-recovery re-arm deliberately skips the check to avoid leaving the phone unprotected.
- **The watch and the alerts.** `MalinoisWatch/WatchAppDelegate.swift`, `WatchLinkWakes.swift`, `WatchRelayInbox.swift`, `WatchAlertStatus.swift`, `MalinoisNotificationService/NotificationService.swift`, `AlertBurst.swift`, `Malinois/Services/WatchAlertRelay.swift`, `WatchAlertMessage.swift`. The 10-second wake deadline, the in-flight count and the session state gate are consistent; a wake is given back once, by the deadline, the expiration handler or the all-clear; the relay inbox handles each event once and does not count an old alert twice. I did not find a lost-alert path beyond the documented deadline trade-off.
- **The cloud account binding.** `CloudEnrollment.swift`, the lease/generation checks, the per-record owners in the event store, the "different account" and "backup off" holds, and the subscription removal needing fresh device authentication. The `holdsNewEventsLocal` and restore-hold paths are consistent; an unknown or different account is not silently adopted.
- **The storage and journal.** The count caps, the byte cap (which nils the media names before it deletes the files), the attachment intents and their 30-day cleanup, the journal's append-before-persist and `F_FULLFSYNC`, the deferred load at first unlock, and the orphan sweep's refusal while a set-aside log exists. The media deletion's protection for a set-aside log's names (`removeMediaOnQueue` -> `mediaNamesSetAsideLogsMayReference`) is one of the more carefully reasoned pieces I read.
- **The privacy manifests and the store texts.** The manifests declare UserDefaults (CA92.1) in all four; the iPhone app's also declares boot time (35F9.1) and file timestamps (C617.1); the app uses no disk-space, keyboard or tracking API that I could find, and no network endpoint beyond CloudKit, App Attest and WatchConnectivity. The 1.12 What's New is 1,078 characters with the line breaks counted once, as the listing says; the description is 3,994, as it says.

**What I could not check, and why:**

- **No build, no Simulator, no device.** The prompt says the suite passed on these app files, and I did not repeat it; I did not create a Simulator or run a single test. The findings above are all code/static, which is enough for their claims except DS-5's user-visible time, which I marked SUSPECTED.
- **No CloudKit, no App Attest, no real push.** I cannot exercise the account switching, the subscriptions, the alert extensions on a real watch, or Apple's certification. I read the code and the documentation; the cloud paths are the least dynamically verified part of this review.
- **No App Review.** My judgement on rejection risk is from the guidelines and the texts, not from a reviewer.
- **No physical-device timing.** The O(names × log) cost in DS-5 is certain from the code; how long it takes on an iPhone is not measured, and the Simulator would not be representative.
- **The prompt's counts.** I did not re-run the suite (2,253) or the ThreadSanitizer and macOS runs; I took the prompt's figures as given. My static count of `func test` declarations is 2,316, of which 65 are inside `#if os(macOS)` blocks, leaving 2,251 in my parse; the 2-test difference is likely my parser (a nested `#else`/`#endif` or a test in a helper class), not evidence against the gate. I did not turn it into a finding.

**A note on the way this app is built, tested and reviewed.** The set-aside feature has a very large test surface (about 100 tests for the one feature), and the code comments trace earlier review findings one by one. That is a strength. The blind spot I would name is the **documentation of the new feature**: the code and tests are careful about links, escapes, names and deletion, but the words the owner and a recipient read (the ZIP's README, the privacy policy, the support page) were not brought along with the same care. The two most useful fixes in this report are therefore words, not code.
