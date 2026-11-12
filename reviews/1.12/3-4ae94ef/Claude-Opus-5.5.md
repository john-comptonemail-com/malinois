# Open adversarial review of Malinois 1.12 (87) at `4ae94ef`

- **Reviewer:** Claude Opus 5.5 (Anthropic), working alone from `_REVIEW_PROMPT_OPEN.md`. I did not open `_REVIEW_PROMPT.md` or any other reviewer's report or notes.
- **Date:** 2026-11-11
- **Tests run** (my own probes only; each in a scratch copy of this folder, on a simulator I created and have since deleted, `Malinois-Review-Claude-Opus`, iOS 27.0, no permissions granted):
  - iOS simulator, two probe tests added to the scratch copy:
    `Item122SetAsideLogTests/testProbeDeleteLeavesNoRecordInTheEventLog` and `ReviewerProbeQuietWindowTests/testProbeTheQuietWindowRenewsOnKeypressesThatAreNoGuess`.
    Summary: `Executed 2 tests, with 0 failures (0 unexpected) in 1.658 (1.660) seconds` / `** TEST SUCCEEDED **`. (Both probes assert the behaviour I report, so passing confirms it.)
  - macOS, the evidence core and verifier built as `tools/release/run-macos-tests.zsh` builds them, with one probe added:
    `Item90VerifierTests/testProbeTheReportNeverPrintsAKeysWholeID`. Summary: `Executed 1 test, with 0 failures (0 unexpected) in 0.014 (0.014) seconds`.
  - I did not re-run the full suite, as the prompt asked.

---

## 1. For the owner, in plain English

**Overall judgement.** This is a careful, heavily reviewed codebase. I attacked the places where a thief, someone close to you, or a forger would go first: the disarm pad and PIN lockout, Guided Access, the "first-hand evidence always wins" rule for iCloud copies, the evidence signatures and the Mac verifier, and the new set-aside-log screens. None of them gave way. I found **no way past the PIN or Guided Access, and no way to forge evidence that passes the verifier.** What I did find is smaller. 1.12 adds the app's first **delete** button, and the documents and the audit trail haven't caught up with it. The new "signing key" feature also promises a bit more than the verifier lets a recipient check.

**The problems that matter, most serious first:**

1. **Deleting a set-aside log leaves no trace (Claude-1).** Say someone learns your Malinois PIN by watching you type it, and Malinois has set aside a log. That person can open the Event Log, delete the log with your PIN, and so delete the photos and clips only it names. Nothing records that it happened. No entry goes in the Event Log, nothing is uploaded to iCloud, and nothing is signed. Home's "Malinois set aside an event log" notice then disappears too. Everywhere else the app makes sure a PIN-holder leaves a trace: disarming, settings changes, a PIN change and turning iCloud backup off are all recorded. *What I'd do:* when a set-aside log is deleted, write one status record such as "A set-aside log from Nov 7, 1:25 PM was deleted (37 records, 4 photos and clips)". Upload it the way the "iCloud backup turned off" record is uploaded. It's a small change, and the right time is now, before the delete button first ships.
2. **The App Store description says something 1.12 makes untrue (Claude-2).** The description, which goes in again unchanged with 1.12, says the Event Log has "no way to delete a single entry, not even with your PIN". The public README says the same. 1.12's own What's New says you can "delete it". The privacy policy and support page were already updated with "the one exception", but the description and the public README were not. *What I'd do:* reword the description bullet before you submit (it's metadata, so no new build is needed) and update the public README when it is published.
3. **Only eight characters of the signing key can be checked (Claude-3).** Settings tells you to give someone your key's whole ID so they "can tell it was signed on this iPhone". The Mac verifier only ever prints the first 8 of the ID's 64 characters, so the recipient can compare 8 characters and nothing more. Forging a match is not practical today, but the whole-ID Copy button has nothing to be compared against. *What I'd do:* have the verifier print the export key's full ID (a change to the verifier only, not the app), or change the wording.
4. **Smaller things, all for later:**
   - The share sheet can freeze the screen for up to a minute (already known as BACKLOG 223, and there is a one-line fix) (Claude-4).
   - Face ID can open the Event Log, and from there all evidence can be shared. Face ID can't delete anything, but it can send everything (Claude-5).
   - On the armed screen, tapping backspace on the PIN pad keeps fresh warnings quiet without spending a guess (Claude-6).
   - Each storage-limit cleanup re-reads every set-aside log on the store's write queue, which could slow saving during an incident if a set-aside log is large (Claude-7, not proven).

**Should 1.12 (87) go out?** **Yes to TestFlight as it is.** For the **App Store**, **fix the description bullet before you submit (Claude-2).** That needs no new build. I recommend **adding the deletion record (Claude-1) before 87 is archived.** If you decide not to, add a sentence to SECURITY.md saying that a PIN-holder can delete a set-aside log without a trace. Everything else can wait for a later release.

---

## 2. Findings

### Claude-1: A set-aside log's Delete is a PIN-gated evidence deletion that leaves no record
- **Severity:** Medium. It's the first delete in an app whose case rests on "a PIN-holder leaves proof", and it removes photos with no trace. It only applies when a log has been set aside, which keeps it from being High.
- **Status:** VERIFIED (code, plus a probe test).
- **What is wrong:** `EventStore.deleteSetAsideLog` (`Malinois/Services/EventStore.swift:2921-2938`) and `deleteSetAsideLogOnQueue` (`:2967-3018`) remove the file and the photos and clips only it names. The only other trace is a line in the system log (`Log.store.info`, `:3016`). No `logStateChange`, no `Event`, no upload and no signer statement follows. `grep -rn deleteSetAsideLog Malinois` finds one caller, `SetAsideLogView.delete()` (`Malinois/Views/SetAsideLogView.swift:153-161`), which records nothing either. After the delete `refreshSetAsideLogs()` empties `setAsideLogs`, so Home's notice (`HomeView.swift:496`) goes too. Compare the app's own rule, stated at `MonitoringEngine.swift:771-779`, `Event.swift:80` and `CloudExfiltrator.swift:1082`: a PIN holder can disarm, but "there's no delete affordance, so the 'disarmed' entry stands as proof". The signer named the log's records "gone" when the log was set aside, so the signature file doesn't capture the delete either.
- **Situation:**
  1. Malinois sets aside the log after a launch fails to decode `events.json`. The log holds a few incidents with front-camera photos of someone who handled the phone.
  2. That person, a housemate who has seen the owner type the PIN, opens Event Log → Set-aside log → Delete, enters the PIN and confirms. If the owner turned on Face ID unlock, the housemate needs the PIN only for the Delete step.
  3. The log and its photos go. The Event Log now looks exactly as it would if no log had ever been set aside, and Home no longer shows its notice.
  4. Free tier, or records that were "Local only": the evidence is gone for good, and nothing tells the owner. Pro with synced records: the iCloud copies stay, but nothing points the owner to them.
- **Evidence:** the probe `testProbeDeleteLeavesNoRecordInTheEventLog` (appended to `Item122SetAsideLogTests` in my scratch copy) adds one record, writes a set-aside log naming a photo, deletes it, and asserts `store.events.map(\.id)` is unchanged, the photo is gone and `setAsideLogs` is empty. It passed.
- **Smallest fix:** after an outcome other than `.notDeleted`, have the engine log one status kind, e.g. `setAsideDeleted:<seconds>:<records>:<media>`. Add it to the allow-list in `CloudExfiltrator.stateEvent(from:)` and give it an icon in `EventRow.placeholderIcon`. It then uploads like `backupOff`. If you want it in signed evidence as well, the signer can treat it like any other status record.
- **Probe that shows it fixed:** the same test, asserting one new record of that kind at the top of `store.events`.
- **When:** I recommend before 87 is archived, since the feature ships for the first time in 1.12. The alternative is to accept it and say so in SECURITY.md's set-aside paragraph (`SECURITY.md:1853`). That is a judgement for the owner.

### Claude-2: The App Store description and the public README say "no way to delete a single entry, not even with your PIN"; 1.12 adds one
- **Severity:** Medium. The claim is literally false from 1.12, and the same submission's What's New contradicts it. By the rubric a false published claim is High, but the exception is narrow, so I rate it Medium.
- **Status:** VERIFIED (documents against code).
- **What is wrong:** `store/APP_STORE_LISTING.md:157` (the live description, which "stays as it is" for 1.12): "An Event Log of every arm, disarm, and trigger, with no way to delete a single entry, not even with your PIN." `_PUBLIC_README.md:14` says the same, and its invariant at `:146` reads "There is no delete control for records". There is no `tools/release/readme-edits/1.12.json` yet to change either line. 1.12's What's New (`APP_STORE_LISTING.md:256`) says "...or delete it". `store/PRIVACY_POLICY.md:132-135` and `store/support.html:285-288` were updated with the exception; these two were not.
- **Situation:** A reviewer, or a user, reads the description, then the What's New, then finds a Delete button behind the PIN in the Event Log.
- **Smallest fix:** change the wording (section 3). The description can change at submission without a new build. The public README needs a 1.12 readme-edits entry.
- **When:** before 1.12 is submitted (description) and when its source is published (README). It doesn't block archiving.

### Claude-3: The verifier prints only 8 of a key ID's 64 hex characters, so "give someone the whole ID" cannot be acted on
- **Severity:** Low to Medium. It's a misleading claim and a weak check, not a forgery.
- **Status:** VERIFIED (code and a probe). How easy a collision would be is SUSPECTED impractical (see below).
- **What is wrong:** `MalinoisVerifier.short(_:)` (`MalinoisVerifier/MalinoisVerifier.swift:723`) is the only way the report formats a key ID, and it keeps 8 hex characters (32 bits). Every mention goes through it (`:415-454`, `:536`, `:627`, `:703`). Settings offers the whole 64-character ID to copy (`SigningKeyRow.copyText`) and says "Give someone this ID before you send them one, and they can tell it was signed on this iPhone" (`Malinois/Models/SigningKeyRow.swift:27-29`). 1.12's What's New repeats this, and SECURITY.md:362-366 says "the recipient compares it with the export's key the check names". The recipient can only compare 8 characters, so the copied ID is never usable.
- **Situation:**
  1. The owner sends the full ID ahead, as advised.
  2. Someone passes off a ZIP signed by a different Malinois key whose ID starts with the same 8 characters.
  3. The recipient sees `key 5521c718…` and "PASS", and believes it came from the owner's iPhone.
  The ID is SHA-256 of an App Attest public key, and only the genuine Malinois app can make App Attest keys under Malinois's App ID. So a match needs about 2^31 Secure-Enclave key generations by a tampered genuine Malinois, then one attestation. That is impractical today, so the practical harm is that the feature promises more than it checks. **SUSPECTED:** what would settle the cost is a measurement of how many `DCAppAttestService.generateKey` calls per second a device sustains, and whether Apple throttles them.
- **Evidence:** the macOS probe `testProbeTheReportNeverPrintsAKeysWholeID` passed. The report showed `key f4703062…` and contained none of the ID past its 8th character.
- **Smallest fix:** print the export key's full ID once, under THE EXPORT (e.g. "signed by key `<64 hex>`"). Alternatively, reword Settings and SECURITY.md to promise an 8-character match only.
- **When:** before the 1.12 source and verifier are published, or later with a wording change. It's not in the app binary, so it doesn't block archiving.

### Claude-4: The share sheet's main-thread ask can wait up to 60 s on the lock the bundle making holds
- **Severity:** Low (known: ADR 0080's consequences, BACKLOG 223).
- **Status:** VERIFIED (code).
- **What is wrong:** `EvidenceBundleItem.madeBundle()` holds `state`'s `Mutex` while it waits on a semaphore for up to `makingLimit` (60 s) (`Malinois/Views/EvidenceBundleItem.swift:156-170`, `:184-196`). `keptBundle(for:)` is called on the main thread from `activityViewController(_:itemForActivityType:)` and takes the same lock (`:138-144`). If iOS makes that call while a ZIP is being made, the UI freezes for up to a minute. If the app is going to the background at the same moment, the scene watchdog may kill it.
- **Smallest fix:** in `keptBundle`, use `state.withLockIfAvailable { … } ?? nil` (Swift `Synchronization.Mutex`), or keep the made URL in a second `Mutex`, as `outcome` already is. Then the main thread never waits.
- **Probe:** a unit test that calls `madeBundle()` on a background thread with a `make` that sleeps for 2 s, then calls `activityViewController(…itemForActivityType:)` on the main actor and asserts it returns in well under 1 s.
- **When:** later.

### Claude-5 (judgement): A face or finger that opens the Event Log can export all of the evidence
- **Severity:** Low (a design choice, argued against).
- **Status:** VERIFIED (code).
- **What is wrong:** 1.12 rightly makes Delete ask for the PIN because "a face or finger must not delete". But the same Face ID–opened Event Log offers Share of every event: its photos, clips, traces and the signed ZIP (`EventDetailView.swift:89-99`, `:144-152`). It also offers Share of every set-aside log with all its photos and clips (`SetAsideLogView.swift:115-126`, `:132-143`). `HomeView.Gate.allowsBiometrics` treats the log as a "read surface" (`HomeView.swift:65-78`). Sending everything to an AirDrop target or a chat is reading in name only.
- **Situation:** A partner holds up the sleeping owner's face (or the owner's finger, on a Touch ID phone), opens the Event Log and AirDrops all the clips, including clips of third parties, without knowing the PIN.
- **What it costs:** your evidence and other people's images can go to the wrong person, and the Face ID caption ("Open the Event Log and Test Sensors with Face ID") doesn't say this.
- **Smallest fix:** have Share ask for the PIN, on the same pad and steps as Delete, when the Event Log was opened with a face or finger. Or at least add "and share from it" to the toggle's caption (`PINViews.swift:731-735`).
- **When:** later.

### Claude-6: Backspace keeps the disarm pad's quiet window open without spending a guess
- **Severity:** Low.
- **Status:** VERIFIED (code, plus a probe test).
- **What is wrong:** `PINPad.tap` calls `onActivity` for every key, including ⌫ on an empty entry (`PINViews.swift:136-141`). `DisarmEntryCoordinator.noteActivity()` then renews `lastKeypress` "even past the ceiling" (`DisarmEntryCoordinator.swift:139-147`). While `presentationSuppressed` holds, a fresh warning (or a fresh siren in Siren mode) is held back (`MonitoringEngine.swift:1512-1517`, `:2120-2125`). So someone who did the 5-second hold can keep fresh warnings quiet for up to the 120 s ceiling per hold just by tapping ⌫, without making a single guess. The comment at `DisarmEntryCoordinator.swift:119-125` says the window is "one 20 s window … not renewable without another hold".
- **Limits:** a warning or siren that is already sounding is extended, not suppressed. A flood (more than 10 trips in 60 s) escalates regardless, and capture and push carry on. Each hold is itself logged as a Touch trip. So the real gain is short gaps of silence, not a defeat.
- **Evidence:** the probe `testProbeTheQuietWindowRenewsOnKeypressesThatAreNoGuess` keeps `presentationSuppressed` true for 5 graces using `noteActivity()` alone. It passed.
- **Smallest fix:** count only keys that change the entry (a digit, or ⌫ on a non-empty entry) as activity, or cap the total quiet time per pad opening (e.g. 30 s). Correct the comment either way.
- **When:** later.

### Claude-7: Every limit removal re-reads and searches each set-aside log on the store's serial write queue
- **Severity:** Low.
- **Status:** SUSPECTED.
- **What is wrong:** `removeMediaOnQueue` calls `mediaNamesSetAsideLogsMayReference` on each batch (`EventStore.swift:1367-1388`). That function reads every `events.corrupt-*` file whole and runs `range(of:)` for each name, over one or two copies of its bytes (`:1420-1433`, `SetAsideLog.searchForms`). It runs on `ioQueue`, the same serial queue that writes `events.json`. A large set-aside log (hundreds of records with embedded thumbnails, tens of MB) and a byte-cap prune of dozens of names during an incident could hold the log's writes back by seconds. The journal still makes each record durable first, so this is about delay, not loss.
- **Probe that would settle it:** in a test, write a 20 MB set-aside log, call `deleteMediaNames` with 50 names, then time an `add(_:)` followed by `drainIOForTesting()`.
- **Fix if confirmed:** read each set-aside log once per batch and search all names in one pass, or cache the set of stored-media names each set-aside log contains, keyed by the file's size and modification time.
- **When:** later.

---

## 3. Wrong claims in the documents

| Claim | Where | Why it is wrong | Wording I'd use |
|---|---|---|---|
| "An Event Log of every arm, disarm, and trigger, with no way to delete a single entry, not even with your PIN." | `store/APP_STORE_LISTING.md:157` (description, re-sent with 1.12) | 1.12 deletes a set-aside log, with its photos and clips, behind the PIN; the same submission's What's New says so. | "An Event Log of every arm, disarm, and trigger, with no way to delete a single entry, not even with your PIN. Only a log Malinois had to set aside, because it couldn't read it, can be deleted, with your PIN." (Check the 4,000-character count.) |
| "logged with no way to delete a single entry, not even with your PIN" and invariant "There is no delete control for records" | `_PUBLIC_README.md:14`, `:146` (no 1.12 readme-edits yet) | Same as above. | Add the same exception, and to the invariant: "…except a set-aside log's Delete, behind the PIN (ADR 0078)". If Claude-1 is fixed, add "which leaves a record". |
| "Give someone this ID before you send them one, and they can tell it was signed on this iPhone." / "the recipient compares it with the export's key the check names" | `Malinois/Models/SigningKeyRow.swift:27-29`; What's New line 2 (`APP_STORE_LISTING.md:257`); `SECURITY.md:362-366` | The verifier prints only 8 hex characters of any key, so the whole ID can't be compared (Claude-3). | Best: make the verifier print the export key's full ID and leave the words alone. Otherwise: "…and they can check that its first eight characters match the key the check names." |
| (gap) What a share sends | `store/PRIVACY_POLICY.md` | The evidence ZIP carries the watch's status records (arm and disarm times, settings changes and so on) and statements naming other records that left the log, with their IDs and times. SECURITY.md:333-339 says this; the privacy policy doesn't mention Share's ZIP at all. Minor, since the owner starts every share. | One sentence under "Where that information goes": "If you share a signed event, its evidence ZIP also carries the status entries of that armed session and fingerprints of the rest of your log; only what you share leaves the iPhone." |

---

## 4. Where I went

**Looked at, and found sound:**
- **PIN storage and lockout** (`KeychainService.swift`). PBKDF2 with salt; read-only verify; failures counted inside the service; uptime deadline plus an in-process mirror against refused writes; repair of damaged values. A sealed Keychain is never taken for an absent PIN. Recovery routing is in `RootView`/`PINContinuityView`. I agree with SECURITY.md's reboot argument.
- **The disarm path.** It is a 5-second `LongPressGesture`; a touch-down is a trip; the attribution window opens and closes correctly; a wrong PIN on the armed pad is recorded. Biometrics are never offered on the disarm, Settings, ARM or change-PIN pads, nor (new) on the set-aside Delete pad. The Delete steps type (`SetAsideLogDeleteSteps`) gives one confirmation per entry and resets on going to the background.
- **No back doors.** No URL scheme, App Intents, notification actions or incoming WatchConnectivity messages on the iPhone. Test seams (`TestHost`, `MALINOIS_TRIAL_DAYS_AGO`, Keychain fault injection) are `#if DEBUG`.
- **The iCloud merge.** A copy from iCloud is always marked mirrored (`sanitizedDeviceName` never returns nil), never replaces first-hand evidence, and is held to bounds on load.
- **Evidence core and verifier.** The chain is checked against the App Attest root with anchors only and no network; nonce, key and COSE agree; the App ID hash, a zero counter and the AAGUID environment are checked; signatures are checked over the authenticator data plus the hash; iOS 27 extensions are handled. The built-in root matches Apple's published certificate. The ZIP unpacking defences are layout, three listings agreeing, no links and a file count. Sender text is escaped. The PASS words are honest about what a check can't show.
- **Set-aside logs.** Reading record by record, the search forms and `isStoredMediaName`, refusing links and folders, which photos may be removed (event log in memory and on disk, captures being saved, other logs), the media sweep holding off while any set-aside log exists, numbered names within one second.
- **Count and byte-cap eviction:** mirrors first, then floods, then synced, with in-flight rows protected and reports owed.
- **Documents.** The Keychain list in the privacy policy matches `KeychainService`. Background modes and permissions in the App Review notes match `Info.plist` and the entitlements. The release-staging script's secret and team-ID sweeps.

**Could not check, and why:**
- Anything that needs a real device: Guided Access, App Attest and the Secure Enclave (including Claude-3's key-generation rate), Face ID, CloudKit pushes, the Apple Watch, and how the share sheet actually calls the item provider (Claude-4).
- The simulator can't run CloudKit or App Attest.
- I didn't re-run the full suite, ThreadSanitizer or lint, as the prompt asked.
- I read the watch app's link-wake code and found nothing, but couldn't exercise it.

**A blind spot in how this is built and reviewed.** Reviews and tests focus closely on making each mechanism correct, for example which photos a delete may take. They pay less attention to whether a new action keeps the app's own guarantees, such as "a PIN-holder leaves a trace" and "a face only reads". Claude-1 and Claude-5 are both that kind of gap. One useful standing check for each release: for every new button reachable behind a gate, ask (a) can a face reach it, (b) does using it leave a record, and (c) does any published sentence say it can't exist.
