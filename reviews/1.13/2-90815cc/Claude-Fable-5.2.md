# Open review of Malinois 1.13 (88) at `90815cc`

**Reviewer:** Claude Fable 5.2 (Anthropic), running in OpenCode. The file name `gpt6-astra` is the one the owner asked for; the finding IDs follow it.
**Date:** 2026-11-13
**How I worked:** from `_REVIEW_PROMPT_OPEN.md` only. I did not open `_REVIEW_PROMPT.md` or any other reviewer's report or notes. I read the code myself and ran three read-only sub-sessions of my own in parallel (storage, PIN paths, cloud and watch). Everything from them that I report here I re-read in the code myself, and the findings that matter most I also ran.

**Tests I ran** (scratch copy, my own simulator `Malinois-Review-gpt6-astra`, iPhone 17 Pro, iOS 27.0, no permissions granted, deleted afterwards). The probes are written so that a pass means the problem is present.

| Run | What | Summary line |
|---|---|---|
| 1 | `AstraProbeLaunchFilesTests` (1 test) and `AstraProbeShareSentenceTests` (2 tests) | `Executed 3 tests, with 0 failures (0 unexpected) in 0.125 (0.129) seconds` then `** TEST SUCCEEDED **` |
| 2 | `Item235PurgeEntryTests/testProbeARetentionSetAndSetBackInOneSettingsVisitPurgesWithNoEntry` | `Executed 1 test, with 0 failures (0 unexpected) in 0.787 (0.789) seconds` then `** TEST SUCCEEDED **` |
| 3 | The real Debug app, installed fresh and launched twice with no touch in between | First launch: the welcome screen. Second launch: "PIN unavailable". Screenshots in the notes folder. |

I did not re-run the suite. Nothing was run on an iPhone or an Apple Watch.

The probe source, the two run logs and the two screenshots are in `_REVIEW_NOTES_gpt6-astra/`. Apart from that folder and this report, the folder still matches `_MANIFEST.sha256`.

---

## 1. For the owner, in plain English

### Overall judgement

The core of the app held up. I found no way to disarm, open Settings or open the Event Log without the PIN, no way to bring an owner's phone back to the welcome screen, no path that sends evidence to the wrong iCloud account, and no way to make an edited evidence ZIP pass the Mac verifier.

What I found is a different kind of problem: **a feature added in one release quietly broke a promise made in an earlier one, and no test noticed because each feature is tested on its own.** The clearest case is the headline feature of 1.13 itself.

### The problems that matter, most serious first

**1. The welcome screen only appears once. Open the app a second time before setting a PIN and you get a "PIN unavailable" lock screen instead.** (gpt6-astra-1)

- A new user installs Malinois, sees the welcome screen, perhaps taps "See it work", and leaves without setting a PIN.
- The next time they open it, the screen says "PIN unavailable. Your Malinois PIN can't be read on this device", and asks for Face ID, Touch ID or the iPhone passcode. They never had a PIN.
- On an iPhone with no passcode they cannot get past it at all, short of setting a passcode or deleting the app.
- The cause: since 1.10 the app writes its signing file into the event log's folder within moments of the first launch, and the launch check reads any file there as "an earlier install's evidence".
- I ran this on the simulator with the real app: first launch welcome, second launch "PIN unavailable".
- An Apple reviewer who opens the app twice meets the same screen, on a build whose notes say "On the welcome screen tap Set a PIN".
- What I would do: tell the launch check that the signing file alone is not earlier evidence, and add one test that builds the launch's real services and checks the folder still reads as new. This is a small change.

**2. The "Malinois was reinstalled" entry is never written any more.** (gpt6-astra-2)

- SECURITY.md promises that when someone who knows your iPhone passcode deletes and reinstalls Malinois, the new log and your other devices get a quiet "reinstalled" entry. It says so in several places.
- The entry is only written when the folder holds no earlier evidence. By the time the PIN has been typed, the signing file from problem 1 is already there, so the app decides the entry is not owed.
- Same cause as problem 1, same fix. My test shows the mechanism; a real reinstall on an iPhone would confirm it.

**3. While armed, an upload that fails at the moment of the trip is not tried again until something else happens.** (gpt6-astra-3)

- A thief trips the phone during a one-minute iCloud hiccup (the Wi-Fi is up but the internet behind it is not, or Apple's servers are briefly busy).
- The app tries three times within a few seconds and stops. The event stays on the phone.
- Two minutes later iCloud is fine again. Nothing retries, because retries start only at launch, when the app comes back to the screen, when the network goes fully off and on, or when you open the Event Log. Under Guided Access none of those happen.
- Heartbeats resume, so your other devices show the phone as recently heard from, with no alert and no event.
- This is not new in 1.13. What I would do: let the five-minute heartbeat also start a retry when something is waiting.

**4. A storage setting changed and changed back in one visit to Settings can delete old photos and clips from iCloud with no entry in the log.** (gpt6-astra-4)

- Your setting is Keep forever or Manual. In Settings you pick "Auto-delete after 1 month", by mistake or not.
- Before you close Settings, the screen goes inactive and comes back (pulling Notification Centre down, a Face ID sheet).
- The automatic clean-up runs on the new value at once and deletes full photos and clips older than a month, from all your devices' events.
- You set it back and close Settings. Nothing is recorded, because the setting is the same as before and the automatic clean-up never writes an entry.
- 1.13 added a log entry for "Free up iCloud space…" for exactly this kind of deletion; this is a way round it. My test shows it.

**5. Share calls an event "tampering" even when the app itself has marked it as you disarming.** (gpt6-astra-5)

- An event captured while you held the screen and typed the right PIN is marked "You (disarm)" in the Event Log.
- Share still sends "Malinois detected tampering on … - Device motion, Touch triggered." The event's own screen does not show the mark either.
- The signed ZIP passes the Mac verifier, and the verifier's report never prints what the record says: not its time, not what tripped, not the owner mark.
- So someone can be handed a photo, the sentence "detected tampering" and a PASS, for an event the phone itself recorded as the owner's handling.
- A signal-loss entry is shared the same way ("detected tampering … Signal loss triggered"), though the privacy policy says an ordinary outage can cause one.

**6. If iCloud accepts an event's small record but refuses its photo or clip (a full iCloud is the likely case), nothing ever says so.** (gpt6-astra-6)

- The event shows "Syncing…" for good, Retry fails at once each time, and Home's "iCloud refused" notice never appears, because it is wired only to the small record.
- Your other devices show the thumbnail and offer a download that ends in "Nothing came back".

**7. New in 1.13: "Malinois couldn't read all of your event log from iCloud" can disappear while most of the log is still missing.** (gpt6-astra-7)

- A big first restore on a second device fails part-way and Home says so.
- Any later small pull (a tamper alert arriving) that reads its first page cleanly is counted as "ran to the end" and clears the notice.

### Would I let 1.13 (88) go out?

- **To TestFlight: after fixing problems 1 and 2.** They share one small cause, the welcome screen is the first line of What's New, and testers who install fresh will hit it on their second launch.
- **To the App Store: the same two, plus the document corrections in section 3** if the reinstall entry is not fixed.
- **Later, in the next release:** problems 3 to 7 and the lower findings. None is new damage in 1.13 except 7, and 7 only hides a notice.

### A blind spot in how this app is built and reviewed

- **Features are tested alone; launches are not tested whole.** `testFreshStoreBookkeepingDoesNotRequireRecovery` plants two files by hand and passes. No test builds what a launch really builds and then asks the launch's own question. Problems 1 and 2 have been there since the signer arrived in 1.10.
- **Screen routing is tested by reading source text.** `Item240OnboardingTests` checks that `RootView.swift` contains a certain line. There is no UI test target, so no test ever launches the app twice.
- **The record of a real reinstall was a one-time TestFlight check in 1.8.1**, as the test file's own header says. Nothing repeats it.
- **Most review so far reads code against a checklist.** That finds faults inside a function. It does not find two correct functions that disagree.

---

## 2. Findings

### gpt6-astra-1: a new install relaunched before its PIN is set opens on "PIN unavailable", not the welcome screen

- **Severity:** High. **VERIFIED** on the simulator with the real app and by a test. On an iPhone the file is written by a different line of the same function; that half is from the code.
- **What is wrong.** `KeychainService.hasPriorLocalEvidence` treats every plain file in `Documents/MalinoisEvents/` as an earlier install's evidence, except `seen.json` and `restore-owed.json`. The evidence signer, built at launch before any PIN exists, writes `evidence-signatures.jsonl` there.
- **Situation.**
  1. A new user installs 1.13 and opens it. The welcome screen shows.
  2. Within moments the signer appends a line: `unsupported` on the simulator, `keyPending` on an iPhone as soon as App Attest has made the key, before any network call.
  3. The user leaves without setting a PIN and later opens the app again.
  4. PIN absent, plus "prior evidence", gives `.lostHash`. The screen is `PINRecoveryView`: "PIN unavailable. Your Malinois PIN can't be read on this device. Authenticate with Face ID, Touch ID, or your device passcode to set a new one."
  5. With no device passcode, recovery fails closed and the user cannot set a PIN at all.
- **Evidence.**
  - `Malinois/Services/KeychainService.swift:200-219`, the skip list at `:208`; `:192` (`.absent` with prior events gives `.lostHash`); `:222-225`.
  - `Malinois/Services/EventStore.swift:138-141` and `:234` (the signature file sits in the store's root).
  - `Malinois/Services/EvidenceSigner.swift:1284-1288` (certification asked at init), `:309-311`, `:920-931` (`keyPending` appended after `generateKey`), `:947-949` (`unsupported`).
  - `Malinois/Views/RootView.swift:16-20`, `Malinois/Views/OnboardingViews.swift:180-186`.
  - Simulator: after the first launch the folder held `evidence-signatures.jsonl` (44 bytes, `{"at":…,"kind":"unsupported"}`), `restore-owed.json` and `seen.json`.
  - Screenshots: `_REVIEW_NOTES_gpt6-astra/first-launch-welcome.png` and `second-launch-pin-unavailable.png`.
  - Coverage gap: `MalinoisTests/KeychainServiceTests.swift:432-439` plants only the two bookkeeping files.
- **Smallest fix.** In `hasPriorLocalEvidence`, do not count `EvidenceSignatureFile.name` when it holds no `signature` line (or skip it by name). Add a test that calls `MalinoisApp.makeServices()` on a temporary root, waits for the signer, and asserts the folder is not prior evidence.
- **Probe.** `AstraProbeLaunchFilesTests.testProbeTheSignersLaunchFileReadsAsPriorEvidence`; and the two-launch check: `simctl install`, `launch`, `terminate`, `launch`, screenshot.
- **When.** Before 1.13 (88) is archived.
- **Note.** The same routing has probably applied since 1.10 to anyone who quit at "Create a PIN". 1.13 makes leaving before a PIN the invited path.

### gpt6-astra-2: the "reinstalled" status entry is never owed, because the signer's file is there by the time recovery finishes

- **Severity:** High (a published claim is false, and the trace of a delete-and-reinstall is lost). **VERIFIED** as a mechanism by test; a real reinstall on an iPhone would confirm the end result.
- **What is wrong.** `reinstallRecordOwed` needs `recovery == .lostSetupFlag && !priorLocalEvidence`. `noteRecoveryFinished` reads `EventStore.containerHasPriorEvents` when the PIN has been entered, seconds after launch. The signer's file exists by then, so the answer is always "prior evidence".
- **Situation.**
  1. Someone who knows the iPhone passcode forces a restart, unlocks, deletes Malinois and reinstalls it.
  2. Launch shows "Your Malinois PIN was kept". They tap Forgot PIN?, authenticate with the passcode and choose a new PIN.
  3. `finishRecovery` calls `noteRecoveryFinished(.lostSetupFlag)`. The folder holds `evidence-signatures.jsonl`. No record is owed.
  4. They verify iCloud access. No "reinstalled" entry is written or uploaded. The owner's other devices show nothing.
- **Evidence.**
  - `Malinois/Services/MonitoringEngine+Reinstall.swift:23-25`, `:46-50`; `Malinois/Views/RootView.swift:134-141`.
  - The probe asserts `reinstallRecordOwed(recovery: .lostSetupFlag, priorLocalEvidence: <the folder after the launch's signer>) == false`.
  - `MalinoisTests/Item148ReinstallRecordTests.swift:13-15`: "a real reinstall needs the real Keychain (a TestFlight check)". Every test passes `priorLocalEvidence` by hand.
- **Smallest fix.** The fix for gpt6-astra-1 covers it. Sturdier: read the folder once at launch, before the services write, and pass that answer to `noteRecoveryFinished`.
- **Probe.** Same test as gpt6-astra-1. On a device: set a PIN, delete the app, reinstall, enter the PIN, arm once; look for "Malinois was reinstalled on this iPhone".
- **When.** Before archive, with gpt6-astra-1. If not fixed, correct SECURITY.md (section 3).

### gpt6-astra-3: no retry of a failed trigger-time upload while the armed session goes on

- **Severity:** Medium to High. This is a judgement on likelihood; the behaviour is **VERIFIED** by reading. Not new in 1.13.
- **What is wrong.** A trigger-time save makes three attempts with waits capped at 4 s. The pending sweep starts only at launch, on a foreground, on an offline-to-online flip, on an encrypted-data reset, on late evidence, on backup turned on, and from the Event Log. No timer starts it during an armed session.
- **Situation.** As in section 1, problem 3. The "go loud" rule may sound the siren on the phone, but the event still does not leave it once iCloud is back.
- **Evidence.**
  - `Malinois/Services/CloudExfiltrator.swift:2802-2819` (`maxAttempts = 3`); its own comment: "a stolen device never reaches `retryPendingSync`".
  - `Malinois/Services/MonitoringCloudCoordinator+PendingSweep.swift:154-163` lists the sweep's starts.
  - `Malinois/Services/ConnectivityMonitor.swift:69`: `guard self.isOnline != online else { return }`.
  - `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:84`, `:99-109`: the heartbeat sends a beat and nothing else.
  - Callers of `retryPendingSync`: `MonitoringEngine.swift:615`, `+Screen.swift:84`, `+Jamming.swift:25`, `EventLogView.swift:267`, `+CloudCopies.swift:83`, `+LaunchPull.swift:21`, `+Transfers.swift:446`.
  - SECURITY.md:998-1011 states the triggers correctly, but not that an armed phone has none of them.
- **Smallest fix.** In `beat()`, call `sweepAfterTheRunningOne()` when a retryable record is not synced. Optionally schedule one retry after a trigger-time transient failure, honouring `lastTransientFailure.retryAfter`.
- **Probe.** On a device: arm on Wi-Fi under Guided Access, cut the router's internet, trip, restore it, wait ten minutes, check iCloud from another device.
- **When.** Later, but soon. It is the Pro promise.

### gpt6-astra-4: the automatic iCloud clean-up acts on a retention value that is never recorded

- **Severity:** Medium. **VERIFIED** by test at the engine; the screen going inactive and active under an open sheet is ordinary iOS behaviour I did not run.
- **What is wrong.** The picker writes the live setting. `handleScenePhase(true)` runs `enforceCloudRetentionIfDue()` on the live value with Settings still open. `recordProtectionChanges()` compares values only when Settings closes or at an arm.
- **Situation.** As in section 1, problem 4. It needs the clean-up to be due: always so when the earlier setting was Keep forever or Manual (no stamp is ever written), or after a failed pass.
- **Evidence.**
  - `Malinois/Views/SettingsView.swift:589-592`; `Malinois/Services/MonitoringEngine+Screen.swift:114`.
  - `Malinois/Services/MonitoringCloudCoordinator+CloudRetention.swift:153-155`.
  - `Malinois/Services/MonitoringEngine+SettingsGuard.swift:74-84`; `Malinois/Views/HomeView.swift:192`, `:207-213`.
  - Probe output: `deletions asked of iCloud: 16; entries added to the log: []`.
- **Smallest fix.** At the top of `enforceCloudRetentionIfDue`, call `recordProtectionChanges()` when the live retention differs from the recorded one; or act only on the recorded value.
- **Probe.** `testProbeARetentionSetAndSetBackInOneSettingsVisitPurgesWithNoEntry`.
- **When.** Later.

### gpt6-astra-5: Share's sentence, the event's screen and the verifier's report leave out what the record says about itself

- **Severity:** Medium. **VERIFIED** by test (the sentence) and by reading (the screen and the verifier).
- **What is wrong.**
  - `Event.shareSentence` has two cases: a status or interruption entry, and "Malinois detected tampering". It never looks at `ownerAttributed` or `isSignalLoss`.
  - `EventDetailView`'s metadata shows time, duration, "Triggered by", temperature and sync. The "You (disarm)" label exists only in the list row.
  - `MalinoisVerifier` reads one fact, `stateChange`. Its report never prints `startDate`, `triggeredSensors`, `ownerAttributed`, `captureFailure` or `mediaDiscarded`.
- **Situation.** An owner asks a colleague to disarm the phone and gives them the PIN. The pick-up trips Motion and photographs the colleague; the right PIN marks the event owner-attributed. The owner shares it. The recipient gets the photo, "Malinois detected tampering on Nov 13, 2026 at 2:15 PM - Device motion, Touch triggered." and a ZIP that passes.
- **Evidence.**
  - `Malinois/Models/Event.swift:264-271`, `:494-503`, `:920-922`.
  - `Malinois/Views/EventLogView.swift:302-304`, `:332`; `Malinois/Views/EventDetailView.swift:354-384`.
  - `MalinoisVerifier/MalinoisVerifier.swift:539-544` (the only read of `facts`).
  - `Malinois/Models/Event+Evidence.swift:61` (the fact is signed, so the verifier has it).
  - Probe output: the two sentences quoted in section 1.
- **Smallest fix.** A third sentence for an owner-attributed event and a fourth for signal loss; the label on the event's screen; and in the verifier, under THE RECORD'S REVISIONS, the last revision's start, tripwires and owner mark.
- **Probe.** `AstraProbeShareSentenceTests`.
- **When.** Later. The verifier's words need the owner's approval.

### gpt6-astra-6: a photo or clip iCloud refuses is never reported as refused

- **Severity:** Medium. **VERIFIED** in the app's logic by reading; that CloudKit accepts the small record while refusing the asset was not tested against the service.
- **What is wrong.** `pushPhotoRecord` logs the error and returns `false`. `exfiltrateNow` returns `.pending` with no failure class. `pushFailureResponse` ignores everything but `.localOnly`.
- **Evidence.** `Malinois/Services/CloudExfiltrator.swift:1072-1080`, `:676-682`; `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:229`; `Malinois/Models/CoreTypes.swift:188`.
- **Smallest fix.** Carry the photo's error in `ExfilOutcome` and set `cloudPushRefused` when it is not transient.
- **Probe.** A test with `saveAttemptForTesting` throwing `quotaExceeded` for asset records only; assert Home's refusal notice.
- **When.** Later.

### gpt6-astra-7: a pull that stops at its limit counts as run to the end and clears the "couldn't read all" notice

- **Severity:** Medium to Low. New logic in 1.13. **VERIFIED** by reading.
- **What is wrong.** The fetch loop ends on `out.count < limit` with a cursor in hand and returns "complete". Every pull overwrites `lastCloudPull`. The count of unreadable records moves with the size of the last pull.
- **Evidence.** `Malinois/Services/CloudExfiltrator.swift:1601-1605`; `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:311`.
- **Smallest fix.** Let `fetch` say whether it stopped with a cursor; a limited pull neither clears an earlier incomplete outcome nor lowers the unreadable count.
- **Probe.** A test answering the query with a cursor after a failed restore; assert the notice stays.
- **When.** Soon after 1.13; What's New line 5 describes this notice.

### gpt6-astra-8: "Free up iCloud space…" leaves its entry only after iCloud confirms a deletion

- **Severity:** Low to Medium. The gating is **VERIFIED** by reading. Whether iCloud applied a deletion whose reply was lost is **SUSPECTED**; a `serverResponseLost` answer through `retentionAccessForTesting` would show the missing entry.
- **What is wrong.** The entry is written after the whole purge returns, and only `if result.recordsDeleted > 0`. A force-quit mid-purge, or a lost reply, leaves deletions with no entry. ADR 0084 says "once the purge has sent its deletions".
- **Evidence.** `Malinois/Services/MonitoringEngine+AuditRecords.swift:68-74`; `docs/adr/0084…md:16-17`.
- **Smallest fix.** A note before the first batch, as ADR 0083 does for Delete, and an entry whenever a batch was sent.
- **When.** Later.

### gpt6-astra-9: the "disarmed" alert is lost for good if its signal fails after the audit record lands

- **Severity:** Low to Medium. **VERIFIED** as a code path by reading; likelihood is low.
- **What is wrong.** The row is marked synced, so no sweep touches it again; the sweep's stand-in covers only late disarms. The comment at `CloudExfiltrator.swift:1126-1127` says the sweep stands in.
- **Evidence.** `Malinois/Services/CloudExfiltrator.swift:1122-1137`; `Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:153-154`.
- **Smallest fix.** Keep a small "signal owed" list and let the stand-in cover it.
- **When.** Later.

### gpt6-astra-10: wrong PINs typed while disarmed leave no trace, and the owner's next correct PIN wipes the count

- **Severity:** Medium, and a judgement: this is a deliberate choice (SECURITY.md:173-174, "the phone is disarmed and in the owner's hands"). **VERIFIED** by reading.
- **What it costs.** The person the app names, someone who knows the iPhone passcode, can open Malinois while it is disarmed and try four PINs at the Event Log gate for free, on every visit, for good. Nothing records it and the owner's next disarm resets the count.
- **Evidence.** `Malinois/Views/HomeView.swift:185-190` (no `onFailure`); `Malinois/Views/ArmedView.swift:49` (the only pad that records); `Malinois/Services/KeychainService.swift:385`, `:474-478`, `:491-496`.
- **Smallest change.** Count wrong entries since the last correct one, and at the next correct entry write one status entry ("3 wrong PINs were entered while disarmed"). No camera.
- **When.** Later; the owner's ruling.

### gpt6-astra-11: lower findings, each VERIFIED by reading unless marked

- **A Delete's note can be removed unread.** On a launch while the phone is locked, with no `events.json`, the store does not know it is sealed; the note of a set-aside log's Delete is read as damaged and removed (`Malinois/Services/EventStore.swift:2958`, `:3384-3391`). The entry ADR 0083 promises is then never written. Narrow. The simulator has no Data Protection, so no test can see it.
- **A clip can be stranded in staging.** If the save fails after the clip moved to `MediaAttachments/<id>.pending`, nothing finishes it and it is deleted after 30 days (`EventStore.swift:2559-2570`, `:2716-2735`). The owner is told the capture failed.
- **`stopDryRun()` has no guard.** `DryRunView.onDisappear` calls it whatever the engine's state (`Malinois/Services/MonitoringEngine+TestSensors.swift:111-131`). I found no reachable path in this build. `guard dryRunActive else { return }` closes it.
- **A share can complete without the ZIP and say nothing.** `ShareNote.line` returns nil when the ZIP's making was never asked for; the app's own diagnostic words it "the share went without it and the screen said nothing" (`Malinois/Views/EvidenceBundleItem.swift:275`, `:316-317`). Known, and awaiting the TestFlight diagnostic.
- **"Fail closed" on a phone with no passcode.** SUSPECTED. Recovery refuses without a device passcode, then tells whoever holds the phone to set one and try again (`Malinois/Views/PINViews.swift:399-406`, `:447-455`). Confirm on a passcode-less iPhone that setting a passcode needs no Apple Account password.
- **The setup flag after a launch before first unlock.** SUSPECTED. ADR 0055 says preferences may read as empty then; `hasCompletedSetup` is read from them the moment the Keychain answers (`RootView.swift:123-130`). If it reads false with the PIN and the log intact, the launch offers Forgot PIN? over an existing log. Confirm: launch by a push before first unlock, unlock, read the flag in that process.

---

## 3. Wrong claims in the documents

| Claim | Where | Why it is wrong | Wording I would use |
|---|---|---|---|
| "Since 1.8.1 a recognised reinstall leaves a status entry in the new log" | SECURITY.md:181-182, :535-536, :648, :652, :804-809 | gpt6-astra-2: not written since the signer's file | Fix the code. Failing that: "A reinstall leaves no entry in the new log." |
| "a new install opens on a welcome screen" | What's New 1.13 line 1; APP_REVIEW_NOTES.md 1.13 line and step 1; `tools/release/readme-edits/1.13.json` | gpt6-astra-1: only at its first launch | Fix the code; the words then hold. |
| "it follows a setting, and every change of that setting is already in the log" | ADR 0084 decision 3; `MonitoringEngine+AuditRecords.swift:66` | gpt6-astra-4 | "…acts only on a setting already recorded", once the code does. |
| the entry is written "once the purge has sent its deletions" | ADR 0084 decision 1 | gpt6-astra-8: after iCloud confirms at least one | "…once iCloud has confirmed a deletion; a purge stopped before then leaves none." |
| "Malinois detected tampering on …" for an owner-attributed or signal-loss event | the app's Share sentence | gpt6-astra-5 | "Malinois recorded its owner disarming on …" and "Malinois recorded a loss of signal on …" |
| "the pending sweep stands in for it" | `CloudExfiltrator.swift:1126-1127` (published source) | gpt6-astra-9: only for late disarms | "…for a late disarm only." |
| "the threat model excludes an attacker who has that passcode" | `KeychainService.swift:439-440` (published source) | The app's first sentence names that person as the one it is for | "…someone with the passcode gets one more guess per restart, as SECURITY.md says." |
| guessing "stays impractical" | SECURITY.md:763-765 | gpt6-astra-10: true of one sitting; the owner's correct PIN resets the count | Add: "The count starts again after each correct PIN." |

I read the App Store description, the privacy policy, the review notes, the public README and SECURITY.md's first 445 lines as a user would. Apart from the rows above I found them accurate, and unusually frank about limits.

---

## 4. Where I went

### Looked at and found sound

- **The Mac verifier and the evidence core** (`MalinoisEvidence/`, `MalinoisVerifier/`):
  - The pinned App ID hash equals SHA-256 of the project's team ID and bundle ID; I recomputed it.
  - The built-in root has the same SHA-256 fingerprint as the certificate Apple publishes (`1C:B9:82:3B…C9:32`, valid to 2045-03-15).
  - Attestation and assertion checks follow Apple's steps: chain to the root only, nonce in the certificate, key ID, App ID hash, counter zero, environment, signature over authenticator data and statement hash.
  - By reading, I found no way to make an edited bundle pass: cutting the tail, reordering keys, swapping an attachment, hiding a revision and adding another phone's key are each reported.
- **PIN storage and lockout** (`KeychainService.swift`): sealed reads never count as absent; one private verify path; lockout on the uptime clock with an in-process mirror.
- **Gates**: Home's three gates, the first-session card (same gate as the button), the notification tap (sets a flag only), sheets closed on background, Settings PIN-only.
- **The welcome screen's Test sensors**, by reading: no permission prompt at defaults, and it creates no event.
- **The trip path** (`MonitoringTripResponder+Responses.swift`): the record before the camera, the fact pushed before the capture, trips during a capture folded in, flood handling.
- **The Vision reference still** (ADR 0081): which trips keep one, the stale-still guards, save under a store name only, signed and in the ZIP, never in an upload.
- **The evidence exporter and Share**: no bundle unless facts and bytes are what the last revision signed; leftovers swept at launch.
- **Set-aside log Delete and Share**, the download-room rule, account binding, pulled-record handling, iCloud backup off, the watch's owed alerts, the alert burst rule, entitlements and privacy manifests: through the sub-sessions, with the points above re-read by me.
- **App Review surface**: usage strings, the one background mode, Release push entitlement, privacy manifests, no network code of the app's own.

### Could not check, and why

- **Anything on a real iPhone or Apple Watch**: Guided Access, App Attest (so the `keyPending` half of gpt6-astra-1 and the end of gpt6-astra-2), Data Protection while locked, camera interruptions, WatchConnectivity, CloudKit's real answers.
- **The Release build**: I built Debug only.
- **1.12's source**: not in the folder, so "since 1.10" for gpt6-astra-1 and -2 is from this code, not from the shipped one.
- **The rest of SECURITY.md (lines 446-2090) and the full README**: read only where a finding led.
- **The Mac verifier's own tests**: not re-run; my points about it are from reading.
