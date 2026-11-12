# An independent review of Malinois 1.12 (87)

**Reviewer:** DeepSeek V4.1 Flash 1017
**Date:** 2026-11-11
**Folder:** (the review folder) at `77d7792`

## Tests I ran

Only the tests named here, on a simulator I created (`Malinois-Review-DeepSeek`, iPhone 17 Pro, iOS 27.0), in a copy of the folder in my own scratch space. The full suite was not run again.

```
xcodebuild -scheme Malinois -destination 'platform=iOS Simulator,id=(the simulator's ID)' \
  -derivedDataPath ../DerivedData -collect-test-diagnostics never \
  -only-testing:MalinoisTests/Item90SignerTests/testRecordsADamagedLogTookAreNamedGoneAtTheNextWrite \
  -only-testing:MalinoisTests/Item90ExportTests/testAnExportShowsEveryAbsenceStatementInFull test
```

```
Test Case '-[MalinoisTests.Item90ExportTests testAnExportShowsEveryAbsenceStatementInFull]' passed (0.040 seconds).
Test Case '-[MalinoisTests.Item90SignerTests testRecordsADamagedLogTookAreNamedGoneAtTheNextWrite]' passed (0.143 seconds).
** TEST SUCCEEDED **
```

I also wrote one probe test (not in the folder; in my copy) and ran it:

```
xcodebuild … -only-testing:MalinoisTests/Item122SetAsideLogTests/testProbeTheSearchFindsANameOutsideTheRecordsMediaFields test
Test Case '-[MalinoisTests.Item122SetAsideLogTests testProbeTheSearchFindsANameOutsideTheRecordsMediaFields]' passed (0.011 seconds).
** TEST SUCCEEDED **
```

The verifier's own test that settles the last link of finding 1 (`Item90VerifierTests/testRecordsThatLeftThePhonesLogOtherThanByItsLimitEndInProblems`, macOS-only) was read, not run; the Mac lane's harness needs a git checkout and tag this folder does not carry. Its assertions are quoted under finding 1.

---

## 1. For the owner, in plain English

The new set-aside screen is careful work: I could not find a way to read or delete a set-aside log without the Malinois PIN, and the Delete does not remove a photo the event log, another set-aside log or a capture still names. The app's PIN, lockout and Guided Access handling are, as far as I could push them, sound. My serious finding is not in the new screen; it is in what a set-aside log does to the **older** signed-evidence feature.

**The problems that matter, most serious first:**

1. **One corrupt event log quietly breaks every evidence ZIP the phone will share afterwards.** When Malinois sets a log aside, the signer writes a signed statement saying those records "left the log other than by its limit". That statement is the one the app uses for records an attacker deleted. Every evidence ZIP includes it in full, and the Mac verifier reports it as a **problem** — not as information — so every later share ends in `PROBLEMS` instead of `PASS`, with a line naming up to hundreds of UUIDs. The recipient cannot tell "set aside and still on the phone" from "deleted". This lasts until the signature file is lost (a reinstall, which also loses the evidence). The owner is never told, and the What's New says sharing adds a checkable ZIP. *This predates 1.12* — the statement has been written since 1.10 — but 1.12's set-aside screen and its new Share make it visible and invite the owner to work with set-aside logs, so it is the right moment to settle it. *What I would do:* before archiving, decide what a set-aside should say to a verifier — either do not name set-aside records in an absence statement, or send absence statements as fingerprints (the verifier then passes; its own tests show a fingerprint passes), or add a signed "set aside" statement the verifier reports as information. Tell the owner in the set-aside screen and in SECURITY.md that a set-aside log makes later shares end in problems until this is fixed.

2. **A crafted or edited set-aside log can make Delete remove a photo its records do not name.** Delete searches the file's bytes for a photo name; the screen decodes its records. For a name in a media field they agree, but a name in any other field (a device name, a damaged status kind) is found by the search and not by the screen. The confirmation then says the photos "only it names" go, and one the file does not name goes too. Only an edited backup can put a name there, so this is narrow; it is still the one place the app destroys a file on the strength of bytes rather than a decoded record. *What I would do:* later. Either search only the records' media fields and the unreadable tail, or change the confirmation to say "the photos and clips the file's bytes name".

3. **The owner's Event Log, and the owner's other devices, show a red alarm that reads as lost evidence.** The same absence statement produces "37 signed records, from Nov 7 … to Nov 7 …, are no longer in the log" in red, immediately above the set-aside log's own row. On the owner's iPad or second iPhone (Pro, backup on) the line arrives with no set-aside log to explain it. *What I would do:* later, but before the next release that touches the signer: make the line say "set aside in a log on the iPhone" when the phone knows that, or drop the line for set-aside records.

4. **The approved What's New says the screen "says why" a share went without its ZIP; for the newest case it does not.** The new rule refuses a ZIP when the event's facts are not the ones its last signature covers. The screen then says "Malinois could not make it just now. Share again later." — which is not why. *What I would do:* change the note for this case to say the event has changed since it was signed, or soften the What's New line. Easy, and the text is not yet submitted.

5. **A set-aside log that names no photos can still report that its photos "may still be on this iPhone".** If the media folder is a link or a file (only an edited backup does that), Delete answers "photos and clips may have stayed" before it checks whether the log names any at all. *What I would do:* later; check the log's bytes for any stored name before reporting media left.

**Would I let 87 go to TestFlight, then the App Store?** Yes to TestFlight: the new screen, its PIN pad and its Delete hold up, and nothing here is a crash, a bypass or a data-loss path on an ordinary phone. I would not submit to the App Store until finding 1 is fixed or, at the least, the set-aside screen and SECURITY.md say plainly that a set-aside log makes later shared ZIPs end in problems — the app's main 1.10 promise is otherwise broken for any owner who has had a corrupt log, and the What's New does not say so. Finding 1 is not a 1.12 regression, so an owner decision to ship the warning now and the fix later is defensible. Findings 2, 3 and 5 can wait for a later release; finding 4 is a one-line store-text decision before submission.

---

## 2. Findings

### deepseek-1 — A set-aside log makes every later evidence bundle end in problems

**Severity:** High
**Status:** VERIFIED (two named tests I ran, one verifier test read, and code)

**What is wrong.** When `events.json` cannot be read, the store moves it aside and starts a fresh log. The signer then compares its signature file with the fresh log: every signed record of the set-aside log is "gone", and — because the store's limit did not remove it — the signer writes a signed **absence** statement naming it (`EvidenceSigner.declareGone`, `Malinois/Services/EvidenceSigner.swift:811`). The set-aside screen explains this as intended ("the signer has named its signed records gone"), but the consequence is not intended: `EvidenceExporter.assembled` shows **every** absence statement in full in **every** bundle, whichever record is shared (`Malinois/Services/EvidenceExporter.swift:115`), and the Mac verifier appends each absence to its problem list, unconditionally:

```swift
for absence in report.absences {
    …
    problems.append("the phone signed that … left its log other than by its limit: \(records)")
}
```
(`MalinoisVerifier/MalinoisVerifier.swift:488-492`)

A check with any problem prints `PROBLEMS` and exits 1, never `PASS` (`MalinoisVerifier/MalinoisVerifier.swift:380-386`).

**Concrete situation.** An owner's iPhone has one corrupt `events.json` (a storage fault, a kill mid-write). At the next launch Malinois sets it aside, starts a fresh log, and the signer names the old records gone. Weeks later the owner shares a *new* event — say a theft caught on camera. The share sheet sends the sentence, the photo and the evidence ZIP. The recipient runs `malinois-verify` as the README says; it prints a `PROBLEMS` list containing "the phone signed that 37 records left its log other than by its limit: 0A…, 1B…, …" and exits 1. The recipient now believes the phone's log was tampered with, and the owner cannot produce a passing ZIP again — the absence statement stays in the signature file after the set-aside log is deleted, and only a reinstall (which destroys the evidence) clears it. The set-aside screen and SECURITY.md do not mention this.

**Evidence.**
- `Malinois/Services/EvidenceSigner.swift:811-821` — `declareGone` signs an `Absence` for every signed record that left the log other than by the limit; the signer does not consult the set-aside logs (no `setAside` in the file).
- `MalinoisTests/Item90SignerTests.swift:679` — `testRecordsADamagedLogTookAreNamedGoneAtTheNextWrite`, which I ran and which passed: a damaged log is set aside, the signed record in it is named gone with its signature kept, no retention statement.
- `Malinois/Services/EvidenceExporter.swift:115-118` — every `.absence` statement is `shown = true` in every bundle.
- `MalinoisTests/Item90ExportTests.swift:423` — `testAnExportShowsEveryAbsenceStatementInFull`, which I ran and which passed: a bundle for a *different* record still shows the absence in full and names it as shown.
- `MalinoisTests/Item90VerifierTests.swift:301` — `testRecordsThatLeftThePhonesLogOtherThanByItsLimitEndInProblems` asserts `outcome.status == 1`, the line "left its log other than by its limit", and **no** `PASS`. (Read, not run: macOS-only.)
- `MalinoisEvidence/EvidenceBundle.swift:363` — `report.absences` is collected from the shown statements; `MalinoisVerifier/MalinoisVerifier.swift:488` turns each into a problem.
- The verifier's own test `Item90VerifierTests.testAnAbsenceCutDownToItsFingerprintAtARepeatedCounterIsNoLongerRead` shows the same absence **cut down to its fingerprint** passes (`status == 0`, `PASS`), which is the shape of the smallest fix.

**Smallest fix.** One of:
1. Send absence statements as their fingerprints, not in full, **and** stop naming them in the export statement's `shown` list. That needs both `EvidenceExporter.assembled` (`shown = false` for `.absence`) and `EvidenceSigner.shownCounters` (leave absences out); the verifier then accounts for the counter, does not read the statement, and passes — the verifier's own test `testAnAbsenceCutDownToItsFingerprintAtARepeatedCounterIsNoLongerRead` shows exactly that shape (`status == 0`, `PASS`). The recipient loses only the list of records the phone says left the log. This is the smallest code change, but it weakens the owner's "B" ruling that a bundle shows its absences.
2. Do not name set-aside records in an absence statement. This needs a way to keep the "these records are out of the log" guarantee for the set-aside file (the set-aside log's own presence is the record); a new signed "set aside" statement the verifier reports as **information** (not a problem) is the clean version.
3. At minimum, tell the owner: a line on the set-aside screen ("Sharing a signed event from this iPhone will now end its check in problems until the next reinstall") and a paragraph in SECURITY.md.

I would not ship the current behaviour silently. The choice between (1) and (2) is the owner's; (3) is not optional.

**Probe.** The three tests above, run as shown; or, on a Mac with the macOS lane, run `Item90VerifierTests/testRecordsThatLeftThePhonesLogOtherThanByItsLimitEndInProblems` and see `PROBLEMS`.

**Before 1.12 (87) is archived?** Yes, or a written owner decision plus the warning in (3).

---

### deepseek-2 — The set-aside search can find a photo name its records do not name, and Delete removes it

**Severity:** Medium
**Status:** VERIFIED (probe test I ran, and code)

**What is wrong.** The set-aside file does not decode as a whole, so Delete searches its bytes for the photo names in the media folder (`SetAsideLog.searchForms`/`names`, `Malinois/Models/SetAsideLog.swift:53` and `:86`; used by `deleteSetAsideLogOnQueue`, `Malinois/Services/EventStore.swift:3006`). The screen decodes the records. ADR 0078's decision 3 says the two "must agree on what it names". They do for a name in `mediaFilename`/`secondaryMediaFilename`; they do not for a name in any other field, because the search has no idea which field a byte string is in. The confirmation says "the photos and clips only it names are deleted from this iPhone too".

**Concrete situation.** An edited backup restored to the phone contains a set-aside log whose record carries the owner's photo name in a text field (a device name, a damaged status kind, a trace string) and no `mediaFilename`. The set-aside screen shows the record with its thumbnail and no photo. The owner, trusting the screen, deletes the set-aside log. Delete finds the name in the bytes and removes the photo file, which no record names; the Event Log reports a whole delete (no notice). The owner has lost a photo that the screen never said the log named.

A second, quieter version: the name is in a decoded record's *other* field, so the screen shows the record and the file is removed, again with no notice.

**Evidence.**
- `Malinois/Models/SetAsideLog.swift:45-53` — the search forms and the "the two must agree" comment.
- `Malinois/Services/EventStore.swift:2974-3035` — `deleteSetAsideLogOnQueue` builds `named` from the *listing* and the *search*, not from the decoded records; `mediaGoingWithASetAsideLog` then removes what nothing else names.
- My probe `testProbeTheSearchFindsANameOutsideTheRecordsMediaFields` (in my copy of `Item122SetAsideLogTests.swift`) passed: a record with `mediaFilename == nil` and a photo name in `sourceDevice` gives `reading.records[0].mediaFilename == nil` while `SetAsideLog.names(name, in: SetAsideLog.searchForms(of: bytes)) == true`.
- ADR 0078 decision 3, "A set-aside log names a photo or clip only by a name the store gives one … The log does not decode as a whole, so its bytes are searched for a name, while its screen decodes its records, and the two must agree on what it names."

**Smallest fix.** Before removing, require the name to be in a decoded record's media field **or** in the unreadable part after the last decoded record (the part the search exists for). A simpler alternative: change the confirmation and the words to "the photos and clips the file's bytes name", which is true, and add a note to the set-aside screen when the screen and the search disagree (a name found only in bytes). The latter is honest but still deletes; the former is the safe direction.

**Probe.** The probe test above; to see the deletion, build the same record with a real `Media/<name>` file and call `deleteSetAsideLogReporting`; the report says `mediaRemoved: 1`.

**Before 1.12 (87)?** No. It needs an edited backup, and the owner must press Delete. Fix later.

---

### deepseek-3 — A set-aside log puts a red "signed records are no longer in the log" alarm in the owner's log, and on the owner's other devices

**Severity:** Medium
**Status:** VERIFIED (code and the test named in finding 1)

**What is wrong.** The absence statement of finding 1 is also written into the Event Log as a status entry: "A signed record from Nov 7, 1:25 PM is no longer in the log", or "37 signed records, from … to …, are no longer in the log" (`Event.signedRecordsGoneSummary`, `Malinois/Models/Event.swift:532`). The row is an alarm: red and unclipped (`EventRow.isAlarm`/`summaryColor`, `Malinois/Views/EventLogView.swift:326-329`). On Pro with iCloud backup on it is uploaded like the other status entries, so the owner's other devices show it too — and there the set-aside log does not exist to explain it.

**Concrete situation.** The owner's phone has a corrupt log; they set it aside. The Event Log shows the set-aside log at the top (orange) and, among the events, a red line saying signed records are "no longer in the log". The owner reads the red line as evidence loss and posts to support. Their iPad, which received the status entry through iCloud, shows the red line with no set-aside log at all.

**Evidence.** `Malinois/Services/EvidenceSigner.swift:811` → `noteAbsence` → `Event.signedRecordsGoneKind`; `Malinois/Models/Event.swift:532-539`; `Malinois/Views/EventLogView.swift:326-329`; the signer test named in finding 1 proves the statement is written; the status entry travels like the others (the same kind is in the cloud allow-list, `Malinois/Services/CloudExfiltrator.swift:1453`).

**Smallest fix.** When the signer names a set-aside log's records, write a different status kind that says "set aside in a log on this iPhone" (or no line at all; the set-aside log's own row is the record). If the absence statement is kept for the bundle, keep the line's wording separate from the bundle's.

**Probe.** After the test named in finding 1, read the log: `store.events` contains a `signedRecordsGone.<n>` entry; `EventRow.isAlarm` is true.

**Before 1.12 (87)?** No, if finding 1 is fixed by not naming set-aside records absent, this goes with it. Otherwise, yes: a red alarm that says the opposite of what the set-aside screen says is worse than the absence itself.

---

### deepseek-4 — The What's New's "the event's screen now says why" is not true for the newest case

**Severity:** Low
**Status:** VERIFIED (code)

**What is wrong.** The approved 1.12 What's New (line 3) says: "After a share of a signed event that went without its evidence ZIP, the event's screen now says why." The note has two lines: for a missing certified key it says why (Apple has not certified the key); for every other case — including the new 1.12 rule that refuses a ZIP when the event's facts are not those of its last signed revision — it says only "Sent without the signed evidence ZIP: Malinois could not make it just now. Share again later." That is a restatement, not a reason.

**Concrete situation.** An event's owner attribution or wrong-PIN count changed after the last signature; the owner shares it; the ZIP is left out (correctly, by the new rule); the screen says "could not make it just now", and the owner shares again and again, getting the same result. Nothing tells them the event has changed since it was signed and is waiting for the signer's next pass.

**Evidence.** `Malinois/Views/EvidenceBundleItem.swift:210-224` — `ShareNote.line`: `.noCertifiedKey` has the key sentence, `.notNow` is "could not make it just now"; `Malinois/Services/EvidenceExporter.swift:138` — the facts check returns nil, which reaches the `.notNow` line through `made == false`.

**Smallest fix.** Add a third note for the facts case: "Sent without the signed evidence ZIP: the event has changed since your iPhone signed it. Share again once it has been signed." Or change the What's New line to "the event's screen now says so". The store text is not yet submitted, so this is a one-line decision.

**Probe.** Share an event after changing a fact (the tests' `Item90ExportTests` stage the exporter; a UI test is not needed) and read `ShareNote.line`.

**Before 1.12 (87)?** Yes if the store text is to stay exactly as approved; otherwise later.

---

### deepseek-5 — A set-aside log that names no photos can report that its photos "may still be on this iPhone"

**Severity:** Low
**Status:** VERIFIED (code)

**What is wrong.** In `deleteSetAsideLogOnQueue`, the media folder is checked before the log's bytes are searched for names:

```swift
guard Self.realDirectory(media) else { return answer(.deletedMediaLeft) }
guard let onPhone = … else { return answer(.deletedMediaLeft) }
var named: [String] = []
let forms = SetAsideLog.searchForms(of: bytes)
```
(`Malinois/Services/EventStore.swift:3000-3006`)

So a log that names **no** photo, deleted while the media folder is a link or a file (only an edited backup puts one there), answers `.deletedMediaLeft`, and the Event Log says "Its photos and clips may still be on this iPhone" — a false alarm. The same happens if the media folder cannot be listed.

**Concrete situation.** An edited backup leaves `Media` as a link. The owner deletes a set-aside log whose records carry no photos. The log is gone; the Event Log says its photos and clips may have stayed; the owner looks for photos that never existed.

**Evidence.** `Malinois/Services/EventStore.swift:3003-3004`; `Malinois/Models/SetAsideLog.swift:229-241` (the notice words); the tests `testDeleteWithNoMediaFolderHasNothingToTell` and `testDeleteSaysThePhotosStayedWhenTheMediaFolderCannotBeListed` cover the folder's absence and an unlistable folder, but not "a log naming no photos + a linked folder".

**Smallest fix.** Before the media-folder guard, ask whether the log's bytes contain any stored-name-shaped token (a 40-byte UUID plus `.jpg`/`.mov`); if none, answer `.deleted`. Or, when the folder cannot be read, say "Malinois could not check for photos" rather than "its photos and clips may still be on this iPhone".

**Probe.** Build a set-aside log with a record that names no photo, make `Media` a symlink, and call `deleteSetAsideLogReporting`; the report is `.deletedMediaLeft` and `SetAsideLogWords.deleteNotice` is the "may still be" notice.

**Before 1.12 (87)?** No.

---

## 3. Wrong claims in the documents

1. **"A set-aside log names a photo or clip only by a file name the app gives one … The log does not decode as a whole, so its bytes are searched for a name, while its screen decodes its records, and the two must agree on what it names. For a name of that form they do."**
   Where: ADR 0078, decision 3; echoed in `Malinois/Models/SetAsideLog.swift:45-53` and the review prompt's summary.
   Why wrong: the search has no field context. A name of the store's form in a non-media field is found by the search and not shown by the screen (my probe), and Delete removes it. "For a name of that form they do" is true only for names in a media field.
   Wording I would use: "The search reads every name of the store's form in the file's bytes, including one in a field that is not a photo's; the screen shows only the names in its records. Delete removes what the search finds, and the confirmation says 'the photos and clips the file's bytes name'."

2. **"After a share of a signed event that went without its evidence ZIP, the event's screen now says why."**
   Where: `store/APP_STORE_LISTING.md`, 1.12 What's New, line 3 (approved).
   Why wrong: the screen says why only for a missing certified key; for the new facts-not-signed case it says "Malinois could not make it just now."
   Wording I would use: "After a share of a signed event that went without its evidence ZIP, the event's screen now says so and, where it can, why."

3. **"A check that passes shows … that while it used the export's key, the phone never said a signed record left its log other than by the log's size limit."**
   Where: SECURITY.md, "Evidence someone else can check" (the list under "A check that passes shows").
   Why wrong: it is not wrong in itself — it is the reason finding 1 happens — but it is the only place the consequence is visible, and the set-aside section of the same document says nothing about it. An owner reading the set-aside section reasonably expects their later shares to pass. I would add to the set-aside paragraph: "A log set aside makes the phone sign that its records left the log; every evidence ZIP this phone shares afterwards ends its check in problems, until the signature file is lost with a reinstall."

4. **"It's at the top of the Event Log."** (Home's notice, `SetAsideLogWords.home`.)
   Where: `Malinois/Models/SetAsideLog.swift:344`; Home's notice.
   Why wrong: a Delete notice is listed above the set-aside logs (`EventLogView` puts `deleteNotices` first), so a set-aside log is not always at the top. Minor; the meaning is clear.
   Wording I would use: "near the top of the Event Log".

I found no other false claims in the documents I read (README, SECURITY.md, the store texts, the privacy policy and support page, the ADRs). The set-aside feature's own words, the Delete's words and the status entry's words match the code.

---

## 4. Where I went

**What I looked at and found sound.**

- **The set-aside screen and its Delete.** `SetAsideLogView` and `SetAsideLogDeleteSteps`: the PIN pad is `PINEntryView` with `allowBiometrics` defaulting false, so no face or finger; the confirmation opens only after a pad that was asked for and whose entry was taken; one entry opens one confirmation; a background closes the pad and the confirmation; a pad cancelled or a PIN entered as the app leaves opens nothing. The tests at `Item122SetAsideLogTests.swift:1768-2076` cover each of these, including a real PIN pad on the screen. The only way I could see to reach Delete without the PIN is a bug in SwiftUI's cover/dialog ordering, which the tests exercise.
- **Delete's media protection.** It consults the event log in memory and on disk, attachment intents, and the other set-aside logs; it refuses links and folders, and a look it cannot make; it removes the log first and the media after; the tests cover each refusal. I could not find a reachable state where a record is only in the journal at Delete time (the journal is replayed at load and after unlock before the UI can act).
- **The PIN, lockout and Guided Access.** `KeychainService.verifyEntry` owns the failure count and the lockout; the lockout deadline is on the monotonic clock and a reboot clears the wait only because the device passcode is then required; a correct PIN clears the count; the hash is `WhenUnlockedThisDeviceOnly`; a lost salt fails closed to the device-authenticated recovery. The first-arm Guided Access lift is one arm and logged; later arms enforce the requirement; the "Don't require it for this arm" choice is the owner's and is warned about.
- **The evidence verifier.** It checks the App Attest chain to Apple's root, the nonce over the statement, the key ID/credential/COSE key, the app ID hash, the counter at zero, the environment, the assertion signature, the statement hash and the fixed form, the export's counter accounting, the record's revisions, the attachments' bytes and every file in the bundle. Its ZIP handling refuses links, paths outside, duplicate entries, extra files, and too many bytes. I could not construct a bundle that passes without a key Apple certified for Malinois.
- **The signer's file and key list.** The key list is `AfterFirstUnlockThisDeviceOnly`, so it is not synced and does not move to another iPhone; a key added to an edited file does not join an anchored list; the unanchored rebuild is the documented limit after a restore to a phone that never ran Malinois.
- **The account binding.** A record is bound to the verified iCloud account; a restore holds every restored first-hand record rather than guessing; a different account holds rather than uploads. The cost (a legitimate restore's records never upload) is deliberate and told to the owner.
- **The watch relay and the watch's inbox.** The relay sends only first-hand incidents and disarms, only with Pro and the alerts switch; the watch shows each event once, pairs iCloud's copy, sums up old alerts, and gives each link wake back by 10 s; the inbox's list reads share one allowance.
- **The app's documented limits.** The Side Button lock, calls and Siri, the hot-swap power gap, the siren's volume, the clock-change restart classification and the edited-backup limits are stated in SECURITY.md; I found the statements honest.

**What I could not check, and why.**

- **The macOS verifier lane.** `Item90VerifierTests` is macOS-only and its harness copies a git checkout and an earlier tag; this folder has no git history. I read the tests and the verifier's code instead. The link from "absence statement in the report" to "PROBLEMS" is code plus the test's assertions, not a run of my own.
- **Real device behaviour.** Guided Access's blocking of calls/Siri, the lock button, the camera and mic indicators with the status bar hidden, the audio route, notification delivery and App Attest are not simulated. The gate's 2,277 tests are simulator tests; the app's own documents say the call/Siri behaviour has varied. That is the biggest blind spot in how this app is tested, and the docs are honest about it, but no test in this folder can settle those properties.
- **The full suite, TSan, the macOS lane and Xcode Cloud.** Not rerun, per the prompt. I ran only the tests named at the top.
- **The other reviewers' reports and the checklist.** Not opened, as asked.
- **The live App Store and the published pages.** Read only from the folder's `_LIVE_APP_STORE.*` and the store texts; I did not fetch Apple's pages or the public site.
- **The set-aside media's effect on the 2 GB storage cap.** `pruneMediaBytes` measures only the current log's media, so a set-aside log's photos and clips are kept outside the cap (by design: the limits do not remove them). The consequence is that a large set-aside log can fill the phone and stop new captures; the app then says so on Home. I did not treat this as a finding because it is the price of keeping the evidence, but the owner should know the cap no longer bounds the app's disk use.
- **A reachable false positive in the absence statement from a merely corrupt (not crafted) log.** I could not construct one; the set-aside records are named gone by design, so finding 1 is not about corruption producing a *wrong* statement, it is about a true statement being reported as a problem to every recipient.

**One blind spot in the review process itself.** The release gate checks the code and the documents against a checklist of approved words; it does not check the *interaction* between a new feature and an old signed guarantee. Finding 1 is exactly that: each part is tested and correct, and the composition is not. A small cross-feature test — "set a log aside, share an unrelated signed event, run the verifier's report" — would have caught it, and I would add one.
