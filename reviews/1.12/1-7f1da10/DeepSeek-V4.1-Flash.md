# Independent adversarial review — Malinois 1.12 (87), `7f1da10`

**Reviewer:** DeepSeek V4.1 Flash (DeepSeek-V4.1-Flash)  
**Date:** 10 November 2026  
**Tests run:** none. I did not boot a simulator or run the XCTest suite; I took the release-gate result stated in `_REVIEW_PROMPT_OPEN.md` (2,211 tests on iOS 27.0 and iOS 18.0, ThreadSanitizer, the macOS tests, the unsigned Release inspection and Xcode Cloud) as given. I read the source, the ADRs, `SECURITY.md`, the READMEs and the store texts, and used the existing tests as evidence of intent, not as a run. The only independent cryptographic check I ran was the SHA-256 of the app's App ID against the verifier's built-in `appIDHash`; they match (`d7c30790…69e7`). I did not read `_REVIEW_PROMPT.md` or any other reviewer's report.

---

## 1. For the owner, in plain English

My overall judgement: the core of this app is unusually carefully built. In the code I reviewed I did not find a way past the Malinois PIN or Guided Access, a way to make an edited evidence bundle pass the verifier, or a cross-account leak. The PIN storage, lockout, write-ahead log, signing and verifier, account binding and the file-type checks around the new set-aside log all look sound. The weak points are in the **new 1.12 set-aside feature** and in a few **sentences that promise more than the app can show**.

The problems that matter, most serious first:

1. **Deleting a set-aside log can quietly let the app's normal cleanup delete other photos or clips.** The copy of the log is what holds the app's media cleanup back after a corruption. The confirmation says only the photos and clips *that log names* are deleted. Once the log is gone, the next clean launch may also delete every unreferenced photo or clip in the media folder — including a capture whose event record was lost, exactly the kind of file that copy was kept to protect. Nothing on screen says that. Fix: keep a small "do not sweep yet" marker, or have the sweep take only names the deleted log had, before the App Store build.

2. **The set-aside screen says iCloud copies "are still there" and shows a frozen "iCloud synced" badge, but it never asks iCloud.** A previous upload is not proof that the remote copy exists now; the app's own `SECURITY.md` says so. The full photo or clip may already have been removed by the iCloud storage setting, by "Delete Data from iCloud", or by a change of account. An owner who deletes the local set-aside log because the screen says iCloud still has it can lose the last full copy. Fix the words now ("may still be there; Malinois can't check from here"); a real check can come later.

3. **A share that goes without the signed ZIP still gives the recipient the photos and the sentence, but not the signed record, and the recipient is not told.** The "sent without the signed evidence ZIP" line is only on the owner's event screen, after the share; it is not one of the items sent. If the owner shares while offline after a restore, or the ZIP cannot be made, the recipient gets a photo and "Malinois detected tampering…" and has no way to know a signed ZIP was meant to be there. The What's New also says the screen says why after any such share, but for Copy, Save Image and other destinations that take no file the screen says nothing. Fix: put a short provenance sentence into the share itself, and narrow the What's New line.

4. **Sharing a set-aside log sends the whole raw file, not just the rows the screen shows, and it may not contain the photos it says it does.** The screen says "These are the records it could read"; the ZIP is the file as kept, including records it could not read and any bytes after the list. A user who shares one event sends everything in that old log. Separately, only photos and clips still on the phone are copied, while the README and What's New say "with the photos and clips it names". Fix: say both things on the Share screen and in the README; list what is missing.

5. **Delete can leave the photos and clips behind and still close as if it worked.** The log is deleted first; if its bytes cannot be read, if the media folder is a link, or if the current log or a capture's record cannot be read, the app deletes no media and returns success. The screen dismisses either way. An owner deleting sensitive photos because the confirmation says they go may find they are still there. Fix: return a result and say "the log was deleted, but some photos could not be removed".

6. **Settings and the What's New say a recipient "can tell it was signed on this iPhone". The verifier cannot show that; it ties the ZIP to a key.** The recipient can compare the key ID you gave them, and that is useful, but the check itself says (in its own PASS text) that it cannot show which iPhone made the ZIP or whose it is. Say "signed with this key" or "the key this iPhone uses" instead.

7. **Home's green "Guided Access ready" only means Guided Access is switched on.** It does not mean the Side Button is off, Voice Control is off, the Guided Access passcode is different, or Face ID/Touch ID cannot end it. The app's own `SECURITY.md` says it cannot see those, but "ready" reads as the whole setup. A green row should not promise more than the one switch it checks.

**Would I let it go?** Yes to TestFlight: these are not reasons to stop testing, and the core protections are sound. I would **not** send 1.12 to the App Store until **1 and 2** are fixed (they can cost evidence), and I would fix **3** and **6** in the same submission because they are the app's signed-evidence promise. **4, 5 and 7** can follow in 1.12.1 if you prefer, though 4 is a privacy wording fix worth doing now. Nothing here is Critical, and I found no PIN or Guided Access bypass.

---

## 2. Findings, most severe first

### DS-1 — High — VERIFIED

**Deleting a set-aside log can let the next launch's media sweep delete photos and clips the log never named.**

The media sweep is deliberately held while any `events.corrupt-*` file exists, because after a corruption an unreferenced photo or clip may be real evidence whose event record was lost (ADR 0048, ADR 0078 decision 3). Deleting the last set-aside log removes that hold. On the next clean launch, `sweepOrphanedMedia` deletes every unreferenced media file older than one day — not just the files the deleted log named. The owner's confirmation only says "The photos and clips only it names are deleted too."

**Concrete situation.** A capture is written to `Media/` and the app is killed, or its event is evicted before the media update lands, so the file is unreferenced. Separately, an event log has been set aside and Home shows the notice. The owner opens the set-aside log and taps Delete to tidy up; the confirmation says only that log's photos and clips go. The log and any media it names are removed. The orphan photo is not named by the log and stays for now. The next time the app launches with a clean current log, the sweep (with no set-aside log left) deletes the orphan. No screen said it would; there is no record of the orphan's deletion because its event record never existed. This is VERIFIED as a code path; the precondition is an unreferenced, old media file, which ADR 0048 says can be real evidence.

**Evidence.**
- `Malinois/Services/EventStore.swift:1462` — `let corruptBackupPresent = rootNames.contains { $0.hasPrefix("events.corrupt-") }`
- `Malinois/Services/EventStore.swift:1478-1479` — the sweep calls `orphanedMediaNames(... corruptBackupPresent: corruptBackupPresent ...)`
- `Malinois/Services/EventStore.swift:1549-1554` — `guard !corruptBackupPresent else { return [] }`; with none left, every unreferenced file past the age floor is returned.
- `Malinois/Services/EventStore.swift:2853-2866` — `deleteSetAsideLogOnQueue` removes the log and then only the media it names; it leaves no marker.
- `Malinois/Models/SetAsideLog.swift:162` — `deleteMessage = "The photos and clips only it names are deleted too. This can't be undone."`
- ADR 0078 decision 3 itself says: "A log whose bytes cannot be read goes alone: the launch's media sweep takes what nothing names once no set-aside log is left."
- ADR 0048: unreferenced media after a corruption may be real evidence, which is why the sweep is held.

**Smallest fix.** Leave a tombstone after the delete (a file outside the `events.corrupt-` prefix, or a flag in the store) that keeps the sweep held until the owner explicitly clears it, or make the sweep take only the names the deleted log contained. If you do not want either, the confirmation must say that a later cleanup may also remove other unclaimed captures. Doing nothing and keeping the current words is the one option I would not ship.

**Probe.** In `Item122SetAsideLogTests`, create a two-day-old `Media/<UUID>.jpg` that no event or log names, a clean current log, and one set-aside log; launch a store (the sweep is held), delete the set-aside log, then launch a fresh store and assert the orphan is still there. The current code fails that expectation.

**Before 1.12?** Yes.

---

### DS-2 — High — VERIFIED

**The set-aside screen claims iCloud copies are still there, and shows "iCloud synced" from a frozen field, without checking.**

The screen's explanation says: "Except any marked below, they are not in your event log; any already backed up to iCloud are still there." Each row's badge is produced by `CloudSyncState.badge(held:setAside:)`, which for a set-aside record returns "iCloud synced" whenever the frozen `cloudSyncState` is `.synced`. The set-aside screen never reads CloudKit, and the normal launch check for missing cloud copies covers records in the current log, not records only an old set-aside log holds. `SECURITY.md` says "Cloud copies have a separate retention policy" and "A previous successful upload is not proof that the remote copy still exists today."

**Concrete situation.** A Pro owner uploads an event, then sets iCloud photo/video retention to one month. Two months later the event log is set aside. The full clip was already removed from iCloud by retention; only the event details and thumbnail remain. The set-aside row still shows "iCloud synced", and the screen says the record is still there. The owner deletes the set-aside log to free space, and with it the only full clip. Or the owner used "Delete Data from iCloud" earlier: the app cannot know from the set-aside screen. The same screen can even show both "iCloud synced" and, for a record with `mediaDiscarded == true`, the line "No copy is available in iCloud" (`EventDetailView.swift:187-188`) — a direct contradiction. This is VERIFIED as an unbacked claim; whether a given account still holds a copy is exactly what the app cannot tell.

**Evidence.**
- `Malinois/Models/SetAsideLog.swift:150-152` — the explanation, including "any already backed up to iCloud are still there."
- `Malinois/Models/CoreTypes.swift:195-199` — `badge(held:setAside:)` returns `displayName` ("iCloud synced") for `.synced` and never says "when set aside".
- `Malinois/Views/EventDetailView.swift:187-188` — the "No copy is available in iCloud" line; `:211-212` — no download/check for `setAside`.
- `SECURITY.md:202` — "Cloud copies have a separate retention policy from the local log."
- `SECURITY.md:262` — "A previous successful upload is not proof that the remote copy still exists today."
- `MalinoisTests/Item122SetAsideLogTests.swift:331` pins the explanation verbatim; `:474` pins "iCloud synced" for a set-aside record. The wording is owner-approved, but that does not make the claim knowable.

**Smallest fix.** Change the explanation to "Any already backed up to iCloud may still be there; Malinois can't check from here," and change the set-aside badge to "iCloud synced when set aside" (or hide it). A real check would need a read-only CloudKit presence lookup for the set-aside record IDs, which is more work and should not be promised before it exists.

**Probe.** A UI test with a `.synced` set-aside record whose CloudKit record is absent: the screen shows "iCloud synced" and the "still there" sentence, and makes no cloud call. A source test can also assert that `SetAsideLogView`/`EventDetailView(setAside: true)` has no CloudKit path. (CloudKit does not run in the Simulator; this is a source-level check.)

**Before 1.12?** Yes, at least the wording; it is a few lines and prevents a false assurance.

---

### DS-3 — High — VERIFIED

**A share that goes without the signed ZIP gives the recipient no indication; the "why" line is only on the owner's screen.**

`EventDetailView.shareItems` hands the sheet the sentence, the loose photos/clips still on the phone, and the bundle item. If no bundle is offered (no certified key, signature file unreadable, log not compared, record unsigned) or its making fails, the share still contains the sentence and the photos. The `ShareNote` explaining the missing ZIP is assigned to the event screen only after the sheet completes; it is not an item in the share, and it is gone if the owner leaves the screen. The recipient receives a photo and "Malinois detected tampering…" with no signed record and no statement that one was meant to be there.

**Concrete situation.** After restoring a backup, the owner is offline. They open a signed event and share it to the police or building security. Apple has not certified the new key, so no ZIP is offered. The recipient gets the event sentence and the photo. The owner's screen says "Sent without the signed evidence ZIP: Apple has not certified this iPhone's signing key yet…" after the share, but the recipient never sees that; if the owner puts the phone away, nobody knows. The same happens when the ZIP's making fails after a destination is picked.

The What's New line "After a share of a signed event that went without its evidence ZIP, the event's screen now says why" is also too broad: `ShareNote.line` returns nil for destinations that take no file (`takesFile`), so Copy, Save Image and Save Video go without the ZIP and with no line. The app's own comment says those destinations never get the bundle; the What's New sentence does not say that.

**Evidence.**
- `Malinois/Views/EventDetailView.swift:116-126` — `shareItems(sentence:media:bundle:)` returns only the sentence, media, and bundle.
- `Malinois/Views/EventDetailView.swift:104` — the note is assigned to `@State shareNote` on the event screen only.
- `Malinois/Views/EvidenceBundleItem.swift:216-224` — `ShareNote.line`; `case .notSigned: return nil`; `guard ... EvidenceBundleItem.takesFile(destination) ...`; `case .ready: return made == false ? notMade : nil`.
- `MalinoisTests/Item200ShareNoteTests.swift:61` — `XCTAssertNil(line(.notSigned), "a record this phone never signed has no ZIP")`; the test explicitly accepts no line for an unsigned record.
- `store/APP_STORE_LISTING.md:258` — the What's New sentence.
- `Malinois/Services/EvidenceSigner.swift:72-79` and `:498-503` — the readiness cases.

**Smallest fix.** Add a short text item to the share itself when no ZIP is offered or when the record is unsigned, e.g. "This share does not include the signed evidence ZIP; the photos are not signed evidence." If the ZIP is offered but its making fails, the screen note can stay, but the recipient still needs a way to know; the safest is to always include a provenance sentence ("Signed evidence ZIP: attached" / "not attached"). Narrow the What's New to "after a share to a destination that takes files".

**Probe.** A unit test on `EventDetailView.shareItems(sentence: "…", media: [], bundle: nil)` asserts the items contain a provenance sentence; the current code returns only the sentence. A source check of `ShareNote.line` shows `Copy`, `Save Image` and `Save Video` return nil.

**Before 1.12?** Yes; this is the app's headline feature and a few words in the share.

---

### DS-4 — Medium — VERIFIED

**Sharing a set-aside log sends the whole raw file, including records the screen did not show, and the README claims media it may not contain.**

`SetAsideLogShare.folder` writes the log's bytes in full, then copies only the media whose full filename appears in those bytes **and which are still in the media folder**. The ZIP's README says it contains "an event log … with the photos and clips it names"; the What's New says "with the photos and clips it names". If a photo or clip was removed by the storage cap, it is not in the ZIP, and nothing says so. The raw log also holds every record in that old log, including records `SetAsideLog.reading` could not decode, bytes after the list's end, and records the owner did not see on the "These are the records it could read" screen. An owner who shares a set-aside log to show one event sends the whole old log to the recipient.

**Concrete situation.** An owner has a set-aside log with three readable events; one is the event they want to send. They tap Share and AirDrop the ZIP. The recipient gets all three events, plus any unreadable records and trailing bytes. In another case, the full clip was removed by the storage cap; the ZIP has no `Media/` clip, but its README still says the photos and clips it names are there.

**Evidence.**
- `Malinois/Models/SetAsideLog.swift:195-215` — `folder` reads the log's bytes, writes them whole, then filters `onPhone` by name; `:165` — the README says "with the photos and clips it names".
- `store/APP_STORE_LISTING.md:256` — the What's New wording, without "on the phone".
- ADR 0078 decision 2 — the byte-for-byte choice; decision 3 — "each photo and clip **on the phone**".
- `Malinois/Views/SetAsideLogView.swift:52` — the screen's explanation, "These are the records it could read."
- ADR 0048 / ADR 0078's consequences — the set-aside log is the whole old log, not a per-event extract.

**Smallest fix.** On the Share screen, say: "This sends the whole log as kept, including parts Malinois could not read. It includes the photos and clips still on this phone." In the ZIP, add a `MISSING.txt` (or a README sentence) listing each media name in the log that is not in the ZIP. Change "with the photos and clips it names" to "with the photos and clips still on the phone" in the README and the What's New.

**Probe.** A test that a log naming `A.jpg` (present) and `B.jpg` (absent) produces a ZIP with `A.jpg`, no `B.jpg`, and no missing list; current behavior. A source test that the Share screen has no warning about the whole file.

**Before 1.12?** The wording can go in 1.12; the byte-for-byte behavior is a deliberate design choice and need not change.

---

### DS-5 — Medium — VERIFIED

**Delete can leave the named photos and clips in place and still dismiss as if it worked.**

`deleteSetAsideLogOnQueue` removes the log first, then computes the media it names. If the log's bytes cannot be read (`guard let bytes else { return true }`), if the media folder is not a real folder (`guard Self.realDirectory(media) else { return true }`), or if the current log or a capture's record cannot be read (`mediaGoingWithASetAsideLog` returns `[]` when `onDisk` or `saving` is nil), it returns **true** having deleted the log but **no media**. `SetAsideLogView.delete` ignores the Bool, clears `deleting`, and calls `dismiss()` unconditionally. The confirmation said the photos and clips only it names are deleted too, and "This can't be undone."

**Concrete situation.** The set-aside log's bytes cannot be read, or the current log or a capture's attachment record cannot be read, when the owner taps Delete. The set-aside log goes; the app cannot prove which media the current log needs, so it deletes none. The screen closes. The owner believes sensitive photos are gone; they remain, possibly until a later sweep (and if another set-aside log exists, the sweep never runs). The same happens if a media file is a link or folder from an edited backup.

**Evidence.**
- `Malinois/Services/EventStore.swift:2849-2866` — the log is removed, `guard let bytes else { return true }`, `guard Self.realDirectory(media) else { return true }`, and `mediaGoing` only deletes when both `onDisk` and `saving` are known.
- `Malinois/Services/EventStore.swift:2873-2876` — `guard let onDisk, let saving else { return [] }`.
- `Malinois/Views/SetAsideLogView.swift:127-134` — `_ = await eventStore.deleteSetAsideLog(log)`, then `dismiss()`, regardless of the result.
- `Malinois/Models/SetAsideLog.swift:162` — the confirmation wording.
- ADR 0078 decision 3 — the safety rule: when the log on disk or a capture's record cannot be read, the photos and clips stay. The rule is sound; the screen does not tell the owner.

**Smallest fix.** Return a result with what happened (log deleted, media deleted, media kept), and show "The log was deleted, but some photos or clips could not be removed" when not everything went. If the owner's goal is deletion of sensitive media, offer a retry when the phone is unlocked and the current log readable. The log-first order can stay.

**Probe.** A test that creates a set-aside log naming a present photo, makes `events.json` unreadable (or the media folder a link), calls `deleteSetAsideLog`, and asserts the log is gone, the photo remains, and the screen path can report the partial result. The current code returns `true` and the view dismisses.

**Before 1.12?** Yes, at least the message; the safety behavior itself is correct.

---

### DS-6 — Medium — VERIFIED

**Settings and the What's New promise a recipient can tell the ZIP was signed "on this iPhone"; the verifier can only tie it to a key.**

The Settings footer says: "Give someone this ID before you send them one, and they can tell it was signed on this iPhone." The What's New repeats "they can tell it was signed on your iPhone." The verifier's own PASS words say: "It cannot show: which iPhone made the ZIP or whose (any Malinois on any iPhone signs the same way)." `SECURITY.md` says the same: "a check ties a ZIP to a key, not to a person or a phone." The key-ID comparison is valuable, but it proves the ZIP was signed by **the key the owner named**, not that the key is on the physical iPhone the recipient thinks it is; that last step is the owner's out-of-band assertion. An earlier key of the same phone, another Malinois phone, or a key an attacker presents with the owner's real key in the bundle must all be distinguished by the key ID, not by the phone.

**Concrete situation.** The owner gives a recipient the eight-character ID from Settings. The recipient gets a ZIP signed by that key and can check it; good. But if the recipient instead receives a ZIP signed by a **different** key that follows the owner's key, the verifier shows the export key and the chain; the recipient must compare the ID. The sentence "signed on this iPhone" could lead them to accept the first key that appears in the bundle (the owner's earlier key) as proof of the export, when the export itself is signed by the follower. The check does not say which phone; the owner's ID is the only link.

**Evidence.**
- `Malinois/Models/SigningKeyRow.swift:28-30` — the footer.
- `store/APP_STORE_LISTING.md:257` — the What's New line.
- `SECURITY.md:372-373` — "which iPhone made the ZIP, or whose … a check ties a ZIP to a key, not to a person or a phone."
- `MalinoisVerifier/MalinoisVerifier.swift:347-351` — the PASS text, same limit.
- `MalinoisVerifier/MalinoisVerifier.swift:420-456` — the report names keys and signatures; the export line does not assert a phone.

**Smallest fix.** "Give someone this ID before you send them one, and they can tell it was signed with this key" (Settings) and "the key your iPhone uses" (What's New). Keep the owner's out-of-band statement that the key is this phone's; do not present it as something the check shows.

**Probe.** A text comparison of `SigningKeyRow.footer` with `MalinoisVerifier.passWords`; a unit test can assert the footer does not claim more than "this key".

**Before 1.12?** Yes, wording only.

---

### DS-7 — Medium — VERIFIED

**Home's green "Guided Access ready" only means the Guided Access switch is on, not the settings the app's own documentation calls necessary.**

`HomeView` draws `statusRow(ready: engine.guidedAccessEnabled, text: engine.guidedAccessEnabled ? "Guided Access ready" : "Guided Access off")`. `SECURITY.md` says the app checks only that Guided Access is on and that the rest is up to the owner: a Guided Access passcode different from the iPhone passcode, Face ID/Touch ID off for ending it, Side Button off, Volume Buttons off in Siren mode, Voice Control off, and Screen Time's deleting-apps restriction. A green "ready" is stronger than "the switch is on".

**Concrete situation.** The owner turns Guided Access on but leaves the Side Button option on. Home shows a green "Guided Access ready". A thief presses the side button; the screen locks and the watch pauses (the app records a "locked" interruption when it returns, but there is a gap). The owner thought the setup was ready. The same applies to Voice Control: "Close application" can close Malinois under Guided Access if Voice Control is on.

**Evidence.**
- `Malinois/Views/HomeView.swift:349-350` — the row.
- `SECURITY.md:71-75` — "It checks that Guided Access is on: Home shows it … iOS doesn't let it see the rest, so these are up to you."
- ADR 0072 / the arming screen's Side Button part: the app already knows the Side Button setting matters.

**Smallest fix.** Make the row say "Guided Access on" (not "ready"), with a tappable "Check Side Button and Voice Control" line, or add a second line that names what the app cannot check. This is a wording change, not a new check.

**Probe.** A pure test of the Home status row text; the current text says "Guided Access ready" whenever the toggle is on.

**Before 1.12?** Later is acceptable; the wording fix is small and could go now.

---

## 3. Wrong claims in the documents

These are the claims I would change, with the wording I would use.

1. **`Malinois/Models/SetAsideLog.swift:150-152`** — "any already backed up to iCloud are still there."  
   **Why wrong:** the app never checks; cloud retention, "Delete Data from iCloud", and account changes can remove the record or the full media; `SECURITY.md:262` says a previous upload is not proof. This is pinned by `Item122SetAsideLogTests.swift:331`.  
   **Wording:** "Any already backed up to iCloud may still be there; Malinois can't check from here."

2. **`Malinois/Models/SetAsideLog.swift:165`** — the README's "with the photos and clips it names", and **`store/APP_STORE_LISTING.md:256`** — the What's New's "with the photos and clips it names."  
   **Why wrong:** `SetAsideLogShare.folder` copies only media still on the phone; a storage-cap removal leaves the name in the log and no file in the ZIP.  
   **Wording:** "with the photos and clips still on the phone."

3. **`store/APP_STORE_LISTING.md:256`** — "or delete it, and with it the photos and clips only it names."  
   **Why wrong:** if the log's bytes, the media folder, the current log, or a capture's record cannot be read, the app deletes the log and leaves the media; and after the last set-aside log goes, the launch sweep can delete other unreferenced media (DS-1, DS-5).  
   **Wording:** "or delete it; the photos and clips it names are deleted with it when Malinois can read the log, and a later cleanup may remove other unclaimed captures."

4. **`Malinois/Models/SigningKeyRow.swift:28-30` and `store/APP_STORE_LISTING.md:257`** — "they can tell it was signed on this iPhone" / "on your iPhone."  
   **Why wrong:** the verifier ties the ZIP to a key; `SECURITY.md:372-373` and `MalinoisVerifier.swift:347-351` say it cannot show which iPhone.  
   **Wording:** "they can tell it was signed with this key" / "the key your iPhone uses."

5. **`store/APP_STORE_LISTING.md:258`** — "After a share of a signed event that went without its evidence ZIP, the event's screen now says why."  
   **Why wrong:** `ShareNote.line` returns nil for destinations that take no file (`Copy`, Save Image, Save Video), so those shares get no line; and the recipient gets no line at all.  
   **Wording:** "After a share of a signed event to a destination that takes files, when it went without its evidence ZIP, the event's screen now says why; Copy and Save Image do not carry the ZIP."

6. **`Malinois/Views/HomeView.swift:477`** — "The event log couldn't be read and new events aren't being saved locally. Reinstalling will reset it."  
   **Why wrong:** reinstalling deletes the set-aside log and all local evidence; "reset" is true only in the sense of destroying it. The set-aside log exists so the owner can read or share it before that.  
   **Wording:** "The event log couldn't be read and new events aren't being saved locally. Share the set-aside log before reinstalling: reinstalling deletes it and all local evidence."

7. **`Malinois/Views/HomeView.swift:349-350`** — "Guided Access ready."  
   **Why wrong:** it reports only `UIAccessibility.isGuidedAccessEnabled`, not the Side Button, Voice Control, passcode and Face ID/Touch ID settings that `SECURITY.md:67-75` says are required.  
   **Wording:** "Guided Access on" plus "Check Side Button and Voice Control" (see DS-7).

8. **`Malinois/Views/EventDetailView.swift:187-188`** — "No copy is available in iCloud" on a set-aside record.  
   **Why wrong:** a set-aside record's `mediaDiscarded` is a frozen field, and the screen does not check iCloud; the record may be `.synced` and the full media may still be there, or may not. The same screen can show "iCloud synced".  
   **Wording:** for `setAside`, "Malinois can't check iCloud for this record now."

I checked the public README, the privacy policy, the support page and the App Review notes for the same claims. The public README is 1.11's and does not make the new set-aside claims; the privacy policy's statements about backups, CloudKit and App Attest are accurate for this code. The support page's "with Pro, your iCloud copies come back" is true only when the copies still exist and the account is verified; it is a support answer, not a guarantee, but "come back" could mislead. The App Review notes are still 1.8.1/1.11-era and do not mention the 1.12 set-aside Delete/Share or the signing-key row; if App Review asks about the new Delete, the field notes will not answer. That is a documentation gap, not a code defect.

---

## 4. Where I went

### What I looked at and found sound

- **PIN and lockout.** `KeychainService` stores a salted PBKDF2-SHA256 hash (120,000 iterations) plus a 16-byte salt, versioned; no plaintext PIN. The failure count and lockout survive app restarts; the deadline is against `ProcessInfo.systemUptime`, with the in-process mirror for a Keychain that refuses writes, and a damaged deadline is repaired from the failure count. Sealed Keychain reads are kept distinct from absence (`pinPresence`, `itemRead`), so a locked phone is never treated as "no PIN"; setup is not offered over a sealed item. The 14-day ARM check is read from `lastCorrectEntry`; a clock moved back asks rather than trusts. The lockout does not protect a 4-digit PIN against a compromised OS or a person with the device passcode, and `SECURITY.md` says so.
- **PIN recovery.** `PINContinuityView`/`PINRecoveryView` require `.deviceOwnerAuthentication`; failure or cancellation does not reset; Guided Access defers the system sheet, and the view fails closed rather than hanging. A surviving PIN with a lost setup flag is repaired only after the existing PIN or device auth. I found no unauthenticated `setPIN` path: the only production caller is `PINSetupView.savePIN`, reached from first setup or the authenticated recovery.
- **Disarm and Guided Access.** The armed screen needs a 5-second hold and the Malinois PIN; the biometric unlock is allowed only for the Event Log/Test Sensors, never disarm or Settings. `RecoveryCancelPINView` gates a crash-recovery re-arm; `cancelArming` refuses an automatic re-arm; the Calibrated review has no Cancel button and the live watch starts before the card. I found no state transition from `.armed` to `.disarmed` without the PIN path.
- **Event log at rest.** The write-ahead journal appends and `F_FULLFSYNC`s before `add` returns; the log write is atomic with `.completeFileProtectionUnlessOpen`; a decode failure sets the file aside rather than overwriting; a deferred load waits for the unlock. The media sweep is held while a set-aside log exists, and the media deletion paths refuse names that are not plain file names, links or folders, and keep names a set-aside log may refer to. The new set-aside list/read/share/delete also checks for plain files and real folders; I found no path traversal or link-following in the code I read (the store-root link case is an edited-backup edge, not a normal path).
- **Signing and the verifier.** The fixed-form statements, the App Attest chain and nonce, the key statement, the counter accounting (retention, absence, unkept, repeated), the export statement and the bundle check are careful. The verifier's ZIP layout checks (`refusal(ofLayout:)`, `refusal(ofListing:unpacking:streaming:)`, `refusal(ofUnpacked:)`) and its plain-file readers are hardened; I did not find an edited-bundle pass in the code I read. The App ID SHA-256 in `MalinoisVerifier` matches the project's App ID hash, so a bundle for this app is judged against the right app. The tests pin the Air fixture's ten real signatures and the key ID (SHA-256 of the public key); the Air fixture confirms that Apple's App Attest key ID is that hash, which is what the verifier derives, and the signer uses Apple's key ID.
- **Cloud.** The container is the owner's CloudKit **private** database; records use encrypted fields, account bindings are kept in a file excluded from backup, a free install sends no evidence, a backed-off install keeps new events local, and the cross-device alert text is generic. The watch relay sends kind, identifier and time, not photos or records.
- **Release configuration.** The Release build uses `Malinois-Release.entitlements` with `aps-environment = production`; the Watch Release entitlements use the shared container name and production APNs; the notification extensions have no CloudKit entitlements and read no records. The usage strings, privacy manifest and `ITSAppUsesNonExemptEncryption` are present. The app, watch and both extensions are `CURRENT_PROJECT_VERSION = 87` (the test target is 1, as usual).
- **Tests and wording.** The existing tests for the set-aside feature, the share note, the watch deadlines, the signing/verifier rules and the PIN/lockout are extensive; I used their names and several bodies as evidence. The fact that they are green is not evidence for the claims I flag above: several of them **pin the questionable words** (`Item122SetAsideLogTests:331`, `:474`) or **accept the no-line case** (`Item200ShareNoteTests:61`).

### What I could not check, and why

- **Real device behavior.** App Attest, CloudKit, StoreKit, the real share sheet's order, Guided Access's Side Button/Voice Control behavior, Face ID/Touch ID and the actual iOS camera indicator cannot be exercised in the Simulator. I did not use a physical iPhone. The App Attest key ID derivation is confirmed by the Air fixture and the code; a real device's current key ID matching the Settings row is not independently checked here.
- **iCloud retention and deletion.** I could not observe an owner's CloudKit copies being removed by retention, "Delete Data from iCloud" or an account change; the DS-2 scenario is built from the code and `SECURITY.md`, not from a live account.
- **App Review.** I cannot predict Apple's reviewer. The app is in a category Apple scrutinizes (camera/mic while the screen is black); the existing 1.11 review passed, and I found no new permission or entitlement. The stale App Review notes are a gap if a reviewer asks about the new Delete.
- **A full test run.** I did not run the suite; the prompt says it passed on these files, and a second full run would slow the other reviewers. My findings are static, and each probe above says what would settle the point if you want a test.
- **Other reviewers and the checklist.** I did not read `_REVIEW_PROMPT.md`, any `_REVIEW_REPORT_` or `_REVIEW_NOTES_` folder, or any of the project's private ledger/notes. I worked only from this folder; I did not use any memory folder or outside notes.

### Blind spots in how the app is tested and reviewed

The tests are strong on **pure rules** and **source strings**. They are weaker on **what the recipient sees** (the share items, not just the owner's screen), **what happens to media after the set-aside log is deleted**, and **what iCloud holds later** (a live CloudKit account is not in the suite). The set-aside tests use fake media and a fake log; they do not have a test for a missing media file, a sweep after the last set-aside log is deleted, or a set-aside record whose cloud copy was deleted. The share-note tests pin the owner's line but not a recipient's line. The new feature's tests also **pin the approved words**, which is good for wording control but means a wording bug looks green. Those are the gaps I would add probes for first.
