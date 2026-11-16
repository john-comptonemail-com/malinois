# Malinois 1.13 (88) — independent open review

**Reviewer:** DeepSeek V4.1 Flash (`DeepSeek-V4.1-Flash`).
**Date:** 2026-11-13.
**Folder reviewed:** (the review folder), at the app files of `f7e564a` (the suite's last green
commit; the commits after it change documents and store texts only).
**Tests run:** none. The suite already passed on these exact app files (2,407 tests, iOS 27.0), and every finding below
is settled by code that leaves no doubt, or by an existing test I read. I did not create a simulator. The probes that
would pin the findings into the suite are written out under each finding; they are small additions to existing test
files.

---

## 1. For the owner, in plain English

**Overall.** I did not find a way past the PIN or past Guided Access that the app does not already document, I did not
find a forged evidence bundle that passes the Mac verifier, and I did not find evidence silently deleted. The PIN
handling, the lockout, the evidence signing and the cloud boundary are unusually carefully built, and the threat model
in `SECURITY.md` is honest about the attacks that cannot be stopped (a device-passcode holder, a Guided Access passcode
holder, a compromised phone, an iCloud-account holder). My problems are at the *seams between features*, which is where
a suite of 2,407 feature-by-feature tests is weakest.

**The problems that matter, most serious first.**

1. **After Malinois sets aside a log it cannot read, every evidence ZIP you share afterwards fails the recipient's
   check — and nothing tells you.** When the app cannot read its event log as a whole it starts a fresh log and signs a
   statement that the old log's signed records left it. That is honest. But every later Share also puts that statement
   in the ZIP (it shows *all* such statements, not just the ones about the event you are sharing), and the Mac verifier
   treats any such statement as a problem: it prints `PROBLEMS` and exits 1, even though your new event is genuine and
   untouched. If you rely on handing signed evidence to a building's security office or to the police, this quietly
   ends that for the life of the install, and the app never says so at Share time. *What I would do:* when Share opens,
   if the signature file holds one of these statements, say the recipient's check will report it and why; or teach the
   verifier to name it as "the phone set a log aside" while still failing closed. This is a deliberate, fail-closed
   design, so I am arguing about its cost, not calling the design a bug — but the cost is not disclosed where it is paid.

2. **"Nothing is deleted" is not true once a set-aside log exists.** The one-time "Before you arm" screen on a new
   install says: "Every arm, disarm and trip goes in the Event Log, and no one can delete an entry, not even with your
   PIN." The App Store description says the log has "no way to delete a single entry, not even with your PIN." But since
   1.12 a set-aside log's **Delete** removes that log's records and the photos and clips only it names, and it asks for
   your PIN to do it. It is reached from the Event Log. *What I would do:* keep the promise for the live log and say the
   exception: "No one can delete an entry from your event log, not even with your PIN. A log Malinois set aside can be
   deleted whole, with your PIN, and that leaves an entry of its own." Change the briefing and the description line.

3. **A download that did come back but could not be kept tells you "Nothing came back".** If iCloud returns a photo or
   clip and the phone cannot stage or store it (a clip too large for the download limit, a disk/protection failure, or
   the signer cannot yet say what it signed), the event's screen shows "Nothing came back - the full capture may not be
   in iCloud, or iCloud isn't reachable." That is the wrong reason: the capture *was* there, and a retry may get it.
   The screen has a correct "A capture downloaded, but not everything could be checked - try again for the rest" line,
   but the "nothing came back" branch wins. *What I would do:* one condition — do not show "Nothing came back" when the
   download was incomplete; show the "try again" line.

4. **A shared set-aside log can carry a photo that belongs to a different event.** The set-aside log's Share copies
   every media file in the phone's media folder whose *name* appears anywhere in the log's bytes. The Delete path
   deliberately refuses to remove a file the live event log also names; Share has no such check. A crafted set-aside log
   (only an edited backup can put one there) that names a live photo's file name would put that photo into the ZIP you
   send. This is narrow — the attacker needs an edited backup and you have to share that log — but the asymmetry is
   real, and the fix is to reuse the Delete path's rule.

5. **The "last pull from iCloud didn't finish" notice is kept only in memory, and the unreadable-record count covers
   only the newest page fetched.** After a relaunch the line is gone until another pull runs, and a record the app
   cannot read that is older than the page it asked for is not counted. The line is honest about what it saw, but
   "how many records this version can't read" can undercount the whole log.

6. **The App Review notes' one-minute test does not mention the new welcome screen.** The 1.13 paragraph in
   `store/APP_REVIEW_NOTES.md` describes only the Vision still. The numbered test still begins "Launch. On first run, set
   a 4-digit PIN", but 1.13 opens on a welcome screen with "See it work" and "Set a PIN". A reviewer following the steps
   will still find "Set a PIN" one tap further on, so this is a clarity problem, not a rejection risk — but the notes are
   supposed to make a reviewer's job trivial.

**Would I let 1.13 (88) go to TestFlight and then the App Store?** Yes to TestFlight now. Yes to the App Store, with
items 1 and 2 fixed before the archive if the wording/logic changes can be made cheaply (they can: a Share-time notice,
and two sentences), and items 3–6 later. Nothing here is a reason to hold the build: there is no Critical finding, and
the only privacy issue (item 4) is narrow and has a small fix. I would not spend the release on the absence-statement
redesign; I would disclose it at Share and decide in 1.14 whether the verifier should distinguish a set-aside log from a
vanished record.

---

## 2. Findings

Most severe first. Severity uses the prompt's definitions. "Fix before archive" means before 1.13 (88) is archived;
"later" means a follow-up release is acceptable.

### DeepSeek-V4.1-Flash-1 — A set-aside log's absence statement makes every later evidence share fail the verifier, silently

- **Severity:** Medium (High for an owner who relies on PASS; the trigger is uncommon, the effect is permanent).
- **Status:** VERIFIED (code; an existing verifier test proves the failing outcome).
- **What is wrong.** When a signed record leaves the live log by anything other than the log's size limit, the signer
  signs an absence statement naming it (`EvidenceSigner.declareGone`, `Malinois/Services/EvidenceSigner.swift:809-822`;
  the comparison that finds such records is at `:545-565`). A log the store has to set aside is exactly that case: every
  signed record in it is gone from the fresh log. The exporter then shows **every** retention, absence and unkept
  statement in the signature file, not only those about the shared record or its armed session
  (`Malinois/Services/EvidenceExporter.swift:115-118`), and the export statement names them all
  (`EvidenceSigner.shownCounters`, `:425`). The verifier turns each absence into a problem unconditionally
  (`MalinoisVerifier/MalinoisVerifier.swift:488-492`), so the run ends in `PROBLEMS` with status 1. The existing test
  `Item90VerifierTests.testRecordsThatLeftThePhonesLogOtherThanByItsLimitEndInProblems`
  (`MalinoisTests/Item90VerifierTests.swift:299-313`) asserts exactly that outcome.
- **Concrete situation.** The owner's `events.json` is damaged by an iOS/disk fault (or a bad backup). At launch the
  store moves it to `events.corrupt-<seconds>.json`, starts a fresh log, and the signer names the old signed records
  absent; Home and the Event Log say a log was set aside. The owner later shares a *new* event with a building's
  security office. The ZIP is genuine, the new event's bytes are exactly what the phone signed, and the verifier still
  prints `PROBLEMS (1): the phone signed that N records left its log other than by its limit: …` and exits 1. The
  recipient reasonably reads that as tampering. The app's Share screen says nothing; the recipient is the first to know.
- **Why it is a judgement, not a forgery.** The check is deliberately fail-closed: `SECURITY.md:350-357` says a PASS
  shows "that while it used the export's key, the phone never said a signed record left its log other than by the log's
  size limit." The verifier is doing what it promises. The defect is that the owner is not told where the cost is paid,
  and the absence has no signed reason (a set-aside is indistinguishable from a removed record).
- **Smallest fix.** At Share time, when the signature file holds any absence statement, show a line on the event's
  screen (the existing `shareNote` mechanism, `Malinois/Views/EvidenceBundleItem.swift:259-278`) saying the recipient's
  check will report that records left the log, and why (a set-aside log on <date>), before the sheet opens. A second,
  larger option is a signed absence reason so the verifier can say "the phone set a log aside" — that is a format change
  and belongs in 1.14.
- **Probe.** Add a test to `Item90ExportTests` that builds a signer with one record, an absence statement for an
  unrelated record, and an export of a different record, then asserts `EvidenceExporter.contents(...).signatures`
  contains the absence with `shown == true`; and a verifier test (the existing one is enough) that the resulting bundle
  is status 1. The first half is the missing coverage: the exporter's "all absence statements, always" rule is not
  pinned by a test that an unrelated absence is included.
- **When.** Not before the archive; disclose in 1.13 if the Share line is cheap, otherwise 1.14.

### DeepSeek-V4.1-Flash-2 — "Nothing is deleted" and "no way to delete a single entry, not even with your PIN" are false once a set-aside log exists

- **Severity:** Medium (a false claim on a screen every new install sees, and in the public listing).
- **Status:** VERIFIED (code).
- **What is wrong.** `FirstArmBriefing.noDeleteText` (`Malinois/Models/FirstArmBriefing.swift:34-35`) says "no one can
  delete an entry, not even with your PIN." The public description says the Event Log has "no way to delete a single
  entry, not even with your PIN" (`store/APP_STORE_LISTING.md:164`). But a set-aside log's Delete removes records and
  the photos and clips only it names, behind the PIN: `MonitoringEngine.deleteSetAsideLog`
  (`Malinois/Services/MonitoringEngine+AuditRecords.swift:38-49`) calls `EventStore.deleteSetAsideLogReporting`
  (`Malinois/Services/EventStore.swift:3034-3144`), and the confirmation itself says the photos and clips are deleted
  (`SetAsideLogWords.deleteMessage`, `Malinois/Models/SetAsideLog.swift:303-305`). The set-aside log is listed at the
  top of the Event Log, and its screen is reached from the Event Log.
- **Concrete situation.** A new install's owner reads "no one can delete an entry, not even with your PIN" before the
  first arm. Months later a log is set aside; the owner (or someone who has the PIN) deletes it, and its records and
  photos go. The promise the owner remembered is not the rule the app enforces. The public line is narrower ("a single
  entry"), but a reader will not parse that distinction.
- **Smallest fix.** Wording only: "No one can delete an entry from your event log, not even with your PIN. A log
  Malinois set aside can be deleted whole, with your PIN, and that leaves an entry of its own." Use the same distinction
  in the description line ("no way to delete a single entry from your live event log…").
- **Probe.** No code probe needed; if you want one, a test that the briefing's text and `SetAsideLogWords.deleteMessage`
  do not contradict each other is a string test, not worth the suite time.
- **When.** Before archive: two sentences, zero risk.

### DeepSeek-V4.1-Flash-3 — A download that came back but was not kept is reported as "Nothing came back"

- **Severity:** Low (a wrong reason on an error path; the owner can retry, and the copy is still in iCloud).
- **Status:** VERIFIED (code).
- **What is wrong.** `downloadFullEvidence` maps `.notKept` to `keptAll = false`
  (`Malinois/Services/MonitoringCloudCoordinator+Transfers.swift:542-552`), which makes `complete` false but leaves
  `landed`, `refused` and `noRoom` false. The event's screen then computes
  `downloadFoundNothing = !landed && !refused && !noRoom` (`Malinois/Views/EventDetailView.swift:337`), so it shows
  "Nothing came back - the full capture may not be in iCloud, or iCloud isn't reachable"
  (`:305-309`) instead of the correct incomplete line (`:310-317`, which is in an `else if` and never shows). The
  comment right above the computation says "Something came back (not added, or no room for it): not 'nothing came
  back'" (`:336`) — the `.notKept` case slipped through it.
- **Concrete situation.** A clip comes back from iCloud but exceeds `maxDownloadedMovieBytes`, or the store's write
  fails (disk full, Data Protection), or the signer's file is unreadable so it cannot compare the capture. The owner
  reads "Nothing came back" and concludes iCloud does not have the evidence, when it does and a retry may work.
- **Smallest fix.** `downloadFoundNothing = !outcome.landed && !outcome.refused && !outcome.noRoom && outcome.complete`
  — or, more simply, show the incomplete line whenever `!outcome.complete`, and keep "Nothing came back" for a complete
  fetch that returned nothing.
- **Probe.** In the download tests, drive a fetch that returns one media item and a `join` that answers `.notKept`, then
  assert the view state is "incomplete", not "found nothing". The existing `EvidenceDownload` tests already construct
  `.notKept` paths.
- **When.** Later; the fix is one condition.

### DeepSeek-V4.1-Flash-4 — Sharing a set-aside log copies any media its bytes name, including a file the live log also names

- **Severity:** Low–Medium (a privacy leak, but it needs a crafted/edited set-aside log and an owner who shares it).
- **Status:** VERIFIED (code).
- **What is wrong.** `SetAsideLogShare.folder` copies every file in the media folder whose name appears in the log's
  bytes, with only the name-shape and plain-file checks (`Malinois/Models/SetAsideLog.swift:368-389`). The Delete path
  has an explicit guard that a file the live event log names, on disk or in memory, another set-aside log names, or a
  capture being saved names, is **not** the log's (`EventStore.mediaGoingWithASetAsideLog`,
  `Malinois/Services/EventStore.swift:3146-3153`). Share has no equivalent. So a set-aside log that names a live
  event's `UUID.jpg` will put that photo into the ZIP the owner sends.
- **Concrete situation.** An attacker who can restore an edited backup plants a set-aside log whose JSON names a media
  file the phone still holds for another event. The owner opens the set-aside log (a read surface; a face or finger can
  open the Event Log) and taps Share to send it to, say, a lawyer or a security office. The ZIP includes the other
  event's photo. The attacker does not need the PIN to cause the inclusion, only to get the edited backup onto the
  phone. This is a narrow path, and the app already documents that an edited backup can add records; the point is that
  the Delete path defends against exactly this and Share does not.
- **Smallest fix.** In `SetAsideLogShare.folder`, filter `named` through the same rule the Delete uses (the live log's
  names, other set-aside logs, and captures being saved), or at least exclude names the live event log names. Reusing
  `mediaGoingWithASetAsideLog` keeps the two paths consistent.
- **Probe.** A unit test over `SetAsideLogShare.folder` with a log whose bytes name a file the current log's event
  names, asserting the file is absent from the share folder. This is the missing test; the Delete path already has its
  own.
- **When.** Before archive if the change is the few lines it looks like; otherwise 1.14 with a note in `SECURITY.md`.

### DeepSeek-V4.1-Flash-5 — The "last iCloud pull didn't finish" notice is not durable, and the unreadable count covers only the page fetched

- **Severity:** Low.
- **Status:** VERIFIED (code) for the durability; SUSPECTED for how often it hides a failure in practice (a relaunch
  with no pull, or an unreadable record older than the page).
- **What is wrong.** `CloudPullOutcome` is held in memory (`MonitoringCloudCoordinator.lastCloudPull`,
  `Malinois/Services/MonitoringCloudCoordinator.swift:47`; mirrored to `MonitoringEngine.lastCloudPull`,
  `Malinois/Services/MonitoringEngine.swift:156`), and is set only after a lease is acquired and a fetch returns
  (`MonitoringCloudCoordinator+Transfers.swift:295-311`). A relaunch starts with nil, so the line is absent until the
  next pull; a pull that could not even get a lease leaves the previous outcome standing. Separately, `fetch` stops
  paging at `out.count >= limit` (`CloudExfiltrator.swift:1569-1583`), so `lastFetchUnreadable` counts unreadable
  records only among the newest page(s) it asked for; the Home/Event Log line says "N records in iCloud can't be read
  by this version" without that bound.
- **Concrete situation.** A routine launch pull asks for one page of 100 and finds 2 unreadable records; a third
  unreadable record is older than the page and is never counted. Or a pull fails to acquire a lease and the previous
  "complete" outcome is what Home shows. The owner sees a narrower or older statement than "the last pull did not run to
  the end."
- **Smallest fix.** Persist `CloudPullOutcome` beside the other launch state and set it to incomplete when a pull cannot
  start (no lease, no account); or word the line as "the last check of the newest records" and count only what was
  checked. The first is the more honest.
- **Probe.** A test that a coordinator with a failed lease leaves an incomplete outcome, and a test that a second page
  with an unreadable record adds to the count.
- **When.** Later.

### DeepSeek-V4.1-Flash-6 — The App Review notes' one-minute test predates the welcome screen

- **Severity:** Low (reviewer clarity; not a rejection risk I can show).
- **Status:** VERIFIED (document vs code).
- **What is wrong.** `store/APP_REVIEW_NOTES.md:139-166` starts "1. Launch. On first run, set a 4-digit PIN…", but 1.13
  opens on the welcome screen with "See it work" and "Set a PIN" (`Malinois/Views/OnboardingViews.swift:204-247`,
  `RootView.swift:53-54`). The 1.13 paragraph at `:75-77` describes only the Vision still. The notes say a new feature
  gets "a specific line here, in the release that adds it" (`:19-22`); the welcome screen is that feature in 1.13.
- **Concrete situation.** A reviewer follows step 1, sees a welcome screen, and either taps "See it work" (and tests
  sensors instead of arming) or has to infer that "Set a PIN" is the next step. It costs a minute, not an approval, but
  the notes exist to make the reviewer's job trivial.
- **Smallest fix.** Add one line to the 1.13 note: "A new install opens on a welcome screen; tap Set a PIN, then
  follow step 1." Update step 1 to "Launch. On the welcome screen tap Set a PIN…".
- **Probe.** None.
- **When.** Before the submission; it is a text edit.

---

## 3. Wrong claims in the documents

Only claims I can show are wrong, with the wording I would use.

1. **"No one can delete an entry, not even with your PIN."**
   `Malinois/Models/FirstArmBriefing.swift:35` (the "Nothing is deleted" part of "Before you arm"), shown to every new
   install. Wrong once a set-aside log exists: its Delete removes records and photos with the PIN
   (`MonitoringEngine+AuditRecords.swift:38-49`, `EventStore.swift:3034-3144`). Suggested: "No one can delete an entry
   from your event log, not even with your PIN. A log Malinois set aside can be deleted whole, with your PIN, and that
   leaves an entry of its own."

2. **"An Event Log of every arm, disarm, and trigger, with no way to delete a single entry, not even with your PIN."**
   `store/APP_STORE_LISTING.md:164`. The "single entry" wording is literally defensible for the live log, but a reader
   will read it as the briefing above, and the set-aside Delete is a way to delete a whole log's entries with the PIN.
   Suggested: "…with no way to delete a single entry from your live event log, not even with your PIN; a log Malinois
   had to set aside can be deleted whole, with your PIN, and leaves a record of it."

3. **The App Review notes' test steps.** `store/APP_REVIEW_NOTES.md:140` says "On first run, set a 4-digit PIN"; the
   first screen in 1.13 is the welcome screen (`OnboardingViews.swift:204-247`). Suggested: "Launch. On the welcome
   screen tap Set a PIN and set a 4-digit PIN (e.g. 4831; an easy one like 1234 shows a warning with 'Use Anyway')."
   The 1.13 paragraph at `:75-77` should also name the welcome screen, since the notes' own rule is one specific line per
   new feature.

4. **"The last pull from iCloud did not run to the end" / "how many records this version can't read."**
   `CloudPullOutcome.homeIncomplete` / `unreadableLine` (`MonitoringCloudCoordinator+LaunchPull.swift:66-75`). The
   notice is in memory only, and the count covers the fetched page, not the whole log (finding 5). Suggested: either
   persist the outcome and set it incomplete when a pull cannot start, or say "the newest records" in the line.

I did **not** find a false claim in the parts of `SECURITY.md`, `README.md`, the privacy policy or the listing I
checked against the code: the PIN storage and lockout, the Guided Access requirement and its one-session exceptions, the
account-binding and mirror rules, the siren's volume limits, the Vision still's "on the phone only, never uploaded"
rule, the 2 GB media limit, and the "no account, no server, no analytics" statements all match the code.

---

## 4. Where I went

**What I examined and found sound.**

- **PIN and lockout.** `KeychainService`: PBKDF2-HMAC-SHA256 at 120,000 iterations with a 16-byte random salt, a
  version byte, constant-time comparison, legacy SHA-256 verified and upgraded in place, no salt minting on
  verification, `WhenUnlockedThisDeviceOnly`, update-in-place writes, a sealed-read three-way classification that never
  mints a PIN over a lock, and a monotonic-uptime lockout (30 s doubling to 1 h, count monotonic, mirror for refused
  writes, damage repaired from the count). I checked the no-passcode restart case against the docs: the count survives
  and each restart buys one guess, exactly as `SECURITY.md:653` says. The ARM 14-day check, the `.notChecked` path, the
  pad's auto-submit and lockout display, and the PIN-change/arm-gate separation are consistent.
- **Guided Access and recovery.** The requirement, the first-arm auto-lift (logged), the manual one-arm lift, the
  auto-recovery re-arm that cannot be cancelled without the PIN, the Guided Access-ended status entry, and the
  device-passcode/no-passcode lines all match the docs. The background lapse is recorded, and the "armed session" state
  machine has no path I found that ends an armed session without the PIN except the documented ones (restart, app kill,
  device passcode reinstall).
- **Evidence core.** I verified that the hard-coded `MalinoisVerifier.appIDHash` is
  `SHA-256("(the team ID).com.johncompton.Malinois")` = `d7c30790…def69e7`, matching the project's team and bundle IDs
  (`project.pbxproj:1879,1889`); a different app's key is refused. The App Attest chain is checked against Apple's root
  at a judged time inside the leaf's life, the nonce binds the statement's hash, the credential/COES key and the key ID
  must name one key, the counter must be zero, the environment is allow-listed, and the assertion binds the statement's
  hash. The JSON/CBOR/DER readers are bounded and strict (fixed form re-serialization, depth and size limits, no
  duplicate keys, definite lengths only), the bundle inventory names every file (links and folders never followed), and
  the ZIP reader checks the layout, the three readings, and the unpacked count. I did not find a way to pass a forged or
  edited bundle.
- **Cloud.** Only the private database is used (no `CKShare`, no public/shared database anywhere), metadata goes in
  `encryptedValues`, the thumbnail is a plain asset by Apple's constraint, the installation/account lease is
  device-authenticated, events are bound to the account at capture, a different account pauses uploads and holds new
  events, mirrors are clamped and never supersede first-hand records, and the notification extension reads no records.
- **Store and evidence at rest.** The journal-first write, set-aside-not-overwrite rule, media byte and count limits,
  the byte-cap eviction order (flood, then synced, then a genuine emergency), the "a download never evicts to make
  room" rule, the media-owed-deletion ordering, the set-aside log's Delete guards, and the 1.13 delete-note ordering
  (note written on the store queue before the delete, entry under the note's ID, note retired after) all match the ADRs
  and the comments.
- **Watch and notifications.** The relayed-alert ledger, the owed list (written before the hand-over returns, taken
  off after the shown record, retried three times, newest 100), the iCloud/relay pairing, the burst rule, and the
  extension's "no record reads" rule are consistent with ADR 0082 and the store texts.
- **Privacy manifest and permissions.** The manifest declares UserDefaults, boot time and file timestamps with reasons
  that match the code; the app requests Camera, Microphone, Face ID and Notifications, and add-only Photos from Share,
  as the notes say. The privacy policy's Vision paragraph was updated for the 1.13 still.

**What I could not check, and why.**

- No device or simulator run: the suite already passed on these files, and every finding above is a code-level
  certainty or an existing test. The findings that would benefit from a run are the probe tests named under each one.
- The Release build's real paths — App Attest against Apple, CloudKit, the notification extensions, the siren's audio
  route — are exercised only by the manual release gate, not by the suite; 1.13 has not yet had ThreadSanitizer, the
  iOS 18.0 run, or Apple's Xcode Cloud. My review inherits that gap.
- I did not verify the store screenshots or the live listing JSON against the app; I read the listing text.
- I did not attempt to build the Mac verifier; I read its source and the evidence core it shares with the app.

**The blind spot I would name.** The suite is very strong *inside* each feature and *on pure functions*, and weaker
*across* features: the absence statement is tested by the signer and by the verifier, but not by an export that carries
an unrelated one; the set-aside Delete is tested against the live log, but Share is not; the download result is tested
for `.notKept`, but the screen's wording is not. Those seams are where this review found its problems, and they are
where I would add tests before the next full review.
