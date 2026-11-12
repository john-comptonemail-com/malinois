# 1.12: the full reviews

Malinois 1.12 had four full reviews. Each looked at the release candidate that was about to be archived. The four
candidates were successive builds of 1.12 (87) in the private repository, so their commits are not in this one; the app
files of the fourth are the ones that shipped. Between reviews, the findings taken into 1.12 were fixed, those in the app
each with a test that fails without the fix, and Codex looked at each round of fixes, in a shorter review of the
changes, before the next step.

**How to read the tables of findings.** Each has one row per finding; a finding that several reports raised has one row
that names them all. The severity is the reviewer's own, and some reviewers did not rate every finding. "Fixed in 1.12" means
the fix is in the build that shipped. "Planned for a later release" means the work is recorded for a release after 1.12.
"As designed" means the behaviour is intended and described in SECURITY.md or a decision record (`docs/adr`). Where a
finding is left out of its report until its fix ships, its row says so; none of 1.12's was. The reports name files and lines of the candidate
they read, so line numbers in the earlier reports may have moved since; some files they name (the store texts, the
release tools, the private repository's README) are not in this repository.

## The four reviews

| Review | Date | Candidate | Report | Prompt | Its verdict, in its own words |
|---|---|---|---|---|---|
| 1 | 2026-11-10 | `7f1da10` | [Codex](1-7f1da10/Codex.md) | open | "I would not sign off 87 as the final App Store candidate until finding Codex-1 is fixed" |
| | | | [DeepSeek V4.1 Flash](1-7f1da10/DeepSeek-V4.1-Flash.md) | open | "Yes to TestFlight"; "I would not send 1.12 to the App Store until 1 and 2 are fixed" |
| | | | [GLM](1-7f1da10/GLM.md) | wide open | "The headline guarantees I probed held up"; "three things worth your attention, none of them a broken promise" |
| 2 | 2026-11-11 | `e01dfc8` | [Codex](2-e01dfc8/Codex.md) | wide open | "The clearest broken guarantee is that biometric access is only for viewing." |
| | | | [DeepSeek V4.1 Flash](2-e01dfc8/DeepSeek-V4.1-Flash.md) | open | TestFlight: "Yes"; the App Store: "Yes, after items 1 and 4 are fixed; both are words, not mechanisms" |
| | | | [GLM-5.3 Flash](2-e01dfc8/GLM-5.3-Flash.md) | structured | "Verdict: clean." |
| 3 | 2026-11-11 | `4ae94ef` | [Claude Opus 5.5](3-4ae94ef/Claude-Opus-5.5.md) | open | "Yes to TestFlight as it is"; "I recommend adding the deletion record (Claude-1) before 87 is archived." |
| | | | [Codex](3-4ae94ef/Codex.md) | open | "I would not use this exact snapshot as the final archive"; "Fix issue 2 first." |
| | | | [DeepSeek V4.1 Flash](3-4ae94ef/DeepSeek-V4.1-Flash.md) | open | "Yes to TestFlight now. For the App Store, yes after the two High items are fixed in the words" |
| 4 | 2026-11-11 | `77d7792` | [Codex](4-77d7792/Codex.md) | open | "fix Codex-1 and Codex-2 before archiving the release candidate"; "narrow, Medium-severity corrections" |
| | | | [DeepSeek V4.1 Flash](4-77d7792/DeepSeek-V4.1-Flash.md) | open | "Yes to TestFlight"; not the App Store "until finding 1 is fixed or, at the least, the set-aside screen and SECURITY.md say plainly" what it does |

The prompts: **structured**, with a checklist; **open**, which sets out the threat model and leaves where to look to the
reviewer; **wide open**, a short message asking the reviewer to work out what Malinois guarantees and show how those
guarantees fail.

None of the eleven reports found a way to disarm Malinois without its PIN, an altered evidence bundle that the verifier
passes, or evidence uploaded to the wrong iCloud account.

## Review 1: `7f1da10`, 2026-11-10

Three reports. Most findings were about 1.12's new screens for a set-aside log: an event log that Malinois could not
read and so set aside, which the Event Log now lists and lets you read, share or delete. Before the next review, Delete
was made to say what it left, the set-aside screen to say what it knows of iCloud, Delete's confirmation to say what
follows the last delete, and SECURITY.md was corrected in four places.

| Finding | Report and ID | Its severity | What was done |
|---|---|---|---|
| A restore from iCloud that comes back incomplete shows no notice, and a record this version can't read can let an unfinished restore count as done. SECURITY.md said otherwise. | Codex, Codex-1; DeepSeek, a remark on the support page's "your iCloud copies come back" | High (Codex) | SECURITY.md was corrected in 1.12: it now says that no screen tells you a restore is incomplete, and that a record this version can't read is left out without a notice. A notice on screen is planned for a later release. The support page was not changed. |
| After a partial download and the storage limit, an old record's front-camera thumbnail can show under "Rear camera". | Codex, Codex-2 | Medium | Planned for a later release: a thumbnail will carry the camera it came from. No file or signature is wrong. |
| Share's sheet may freeze the screen for up to a minute if iOS asks for the ZIP on the main thread while it is being made. | Codex, Codex-3 | Medium (suspected) | Known: ADR 0080 says so. A check on a phone comes first; a fix is planned for a later release. |
| Deleting the last set-aside log lets the launch's clean-up remove old photos and clips that no record names, and the confirmation didn't say so. | DeepSeek, DS-1 and wrong claim 3 | High | Fixed in 1.12: Delete's confirmation now says that after the last set-aside log is deleted, Malinois also clears photos and clips that no record names, and SECURITY.md says so too. The clean-up itself is as designed (ADR 0078). |
| The set-aside screen said iCloud copies "are still there" and showed "iCloud synced" without asking iCloud; the iCloud retention setting may since have removed the full photos and clips. | DeepSeek, DS-2 and wrong claims 1 and 8 | High | Fixed in 1.12: the badge reads "Synced when set aside", in grey, and the screen says Malinois doesn't check iCloud again; SECURITY.md adds that retention may have removed the full copies. Test: `Item122SetAsideLogTests.testASetAsideRecordsBadgeIsGrey`. "No copy is available in iCloud" stays: nothing can upload that file afterwards. |
| A share that goes without the signed ZIP tells the person who receives it nothing, and What's New's "says why" was too broad. | DeepSeek, DS-3 and wrong claim 5 | High | As designed: the line is for you, on the event's screen, and a sentence inside the share would be a new feature; Copy and Save Image never carry the ZIP. What's New now says the screen tells you so, "and why when it can". A line for a record not yet signed is being considered for a later release. |
| A set-aside log's Share sends the whole file, and the words said it has the photos and clips the log names, though only those still on the phone go. | DeepSeek, DS-4 and wrong claim 2 | Medium | As designed: Share sends an exact copy of the file (ADR 0078). The words were corrected in 1.12: SECURITY.md, the ZIP's README and What's New now say the photos and clips still on the iPhone. |
| Delete could leave a log's photos and clips behind and still close as if all had gone. | DeepSeek, DS-5 | Medium | Fixed in 1.12: Delete says when the photos and clips may have stayed or nothing was deleted, and the Event Log shows a notice until you dismiss it or Malinois is closed. Test: `Item122SetAsideLogTests.testTheEventLogSaysWhenADeletedLogsPhotosMayHaveStayed`. Codex's looks at this fix found more problems in it, also fixed (below). |
| "They can tell it was signed on this iPhone" says more than the check shows, which ties a ZIP to a key. | DeepSeek, DS-6 and wrong claim 4 | Medium | Not changed, a judgement on the wording: the same footer asks you to give the recipient your key's ID first, and the check names the key. |
| Home's green "Guided Access ready" means only that Guided Access is on. | DeepSeek, DS-7 and wrong claim 7 | Medium | Not changed: the row shows the one setting the app can see, and SECURITY.md lists the settings it cannot check. |
| Home's notice "Reinstalling will reset it" doesn't say that reinstalling also deletes every photo, clip and set-aside log on the phone. | DeepSeek, wrong claim 6 | not rated | Confirmed; planned for a later release, with other changes to the app's words. |
| The App Review notes had no line for 1.12's new screens. | DeepSeek, a remark | not rated | Done for the submission: the project's own App Review notes gained a line for 1.12. |
| A copy of another device's event, written to your iCloud with a higher revision number and less in it, replaces the fuller copy, and later honest copies are refused. | GLM, F1 | not rated ("residual") | No change for now: it needs someone who can write your iCloud records (SECURITY.md, "Made-up records"), and it reaches only copies of other devices' events, never this phone's own records or its signed evidence. |
| After a forced restart, someone with the iPhone's passcode can set the clock so that the record says the app was ended, not that the phone restarted. | GLM, F2 | not rated | Fixed in 1.12's documents: SECURITY.md now says so. The interruption is recorded either way, and the app can't tell the two apart without another clock. |
| The limit of 100 status entries can remove a disarm record that never reached iCloud. | GLM, F3 | not rated (documented) | As documented in SECURITY.md: the limit removes the oldest status entries first, and the removal is signed and noted in the log. |
| The revision order of a record's uploads, and re-runs of six test classes. | GLM, F4 and F5 | none | Nothing to do: no loss found, and every test passed. |

**The looks at this review's fixes.** Codex then looked at each round of changes. Its first three looks found four more
problems in the new Delete, none reachable unless an edited backup is restored to the phone: it said a log was deleted
when it could not look at it; it said a delete was whole when it could not look at a photo; it followed a link out of
the app's folder and removed a photo that the event log still names; and it removed a photo that another set-aside log
names with its name written another way. A separate check found one more problem of that last kind. Each was fixed, with
a test, before the next look. Codex's fourth look: ready, no new finding.

## Review 2: `e01dfc8`, 2026-11-11

Three reports. One defect in the code: a face or finger that opened the Event Log could also delete a set-aside log. It
was fixed before the next review; the rest were words in the documents, points already known, or planned for later.

| Finding | Report and ID | Its severity | What was done |
|---|---|---|---|
| A face or finger that opened the Event Log could also delete a set-aside log, with the photos and clips only it names, without the Malinois PIN. | Codex, 1 | not rated (verified) | Fixed in 1.12: Delete now asks for the Malinois PIN every time, on a pad that offers no face or finger, before its confirmation, and SECURITY.md says so. Tests: `Item122SetAsideLogTests.testDeletesStepsAskForThePINFirstEveryTime`, `Item122SetAsideLogTests.testDeletesPadOffersNoFaceOrFinger`. |
| Share can wait, before its sheet and its one-minute limit exist, on a signing step that never finishes. | Codex, 2 | not rated (suspected) | Known: ADR 0080 names it. Planned for a later release. No such stall has been seen. |
| A share that completes without the ZIP ever being made shows no line. | Codex, 3 | not rated (suspected) | The code's part is confirmed; whether iOS ever completes a share that way is to be checked on a phone, for a later release. |
| The set-aside ZIP's README said it has the photos and clips the log names; it has only those still on the iPhone. | DeepSeek, DS-1 and wrong claims 1 and 2 | Medium | Fixed in 1.12: the README now says "with the photos and clips it names that were still on the iPhone when it was shared". Test: `Item122SetAsideLogTests.testTheReadmeSaysTheZIPHasThePhotosStillOnTheIPhone`. What's New was reworded the same way at the submission. |
| A set-aside log's Share that can't make its ZIP does nothing and says nothing. | DeepSeek, DS-2 | Medium | Left for a later release. |
| The set-aside screen's reader stops at the first item in the file's list that isn't a record, so records after it aren't shown. | DeepSeek, DS-3 | Low | As designed: the app never writes such an item, and Share still sends the whole file. A reader that moves on to the next item is possible later. |
| The privacy policy and the support page said the oldest evidence is removed at the storage limits; a set-aside log never is. | DeepSeek, DS-4 and wrong claims 3 and 4; GLM-5.3 Flash, a note on the wording beside "no way to delete a single entry" | Medium (documents) | Fixed in 1.12: both pages now say that a set-aside log stays, with the photos and clips it names, until you delete it in the Event Log. |
| Share and Delete search a set-aside log once for every file in the media folder. | DeepSeek, DS-5 | Low (the time suspected) | Measured on a Mac: about 1.5 seconds for a 20 MB log and 1,200 files, not minutes. A search in one pass is possible later. |
| Delete's confirmation doesn't say it removes only files under names Malinois gives. | DeepSeek, wrong claim 5 | not rated | Not changed: only an edited backup restored to the phone can bring a file under another name, and SECURITY.md states the rule. |
| The signing key's footer, "Each evidence ZIP you share is signed with this key": an older record in the ZIP can carry an earlier key of the same iPhone. | DeepSeek, wrong claim 6 | not rated ("a judgement") | Not changed, a judgement on the wording. |
| The support page said "Deleting Malinois deletes everything stored on the iPhone"; the PIN and a few other items stay in the Keychain. | DeepSeek, wrong claim 7 | not rated | Fixed in 1.12's support page: it now says that the PIN and a few small items stay in the iPhone's Keychain, as the privacy policy lists. |
| The README in the folder had 1.11's counts and linked an index of decision records that the folder doesn't have. | GLM-5.3 Flash, notes (it reported no findings) | not rated | As built: the folder has the README published with 1.11, and the counts and the index are made when 1.12's source is published. |

**The look at this review's fix.** Codex looked at it: ready, no new finding.

## Review 3: `4ae94ef`, 2026-11-11

Three reports, all of which read the new PIN step at Delete and found no way round it. Two fixes before the next
review: Delete leaves a status entry, and Share makes no ZIP when the event's facts are not the ones last signed.

| Finding | Report and ID | Its severity | What was done |
|---|---|---|---|
| A set-aside log's Delete left no record: someone who had learned the PIN could delete one, with its photos and clips, and leave no trace. | Claude Opus 5.5, Claude-1 | Medium | Fixed in 1.12: a Delete writes a status entry in the Event Log (when the log was set aside, how many records, how many photos and clips went), uploaded on Pro like the others. Test: `Item122SetAsideLogTests.testTheEnginesDeleteWritesAStatusEntryWithItsNumbers`. If Malinois is stopped between the delete and its entry, no entry is written: SECURITY.md says so, and closing that gap is planned for a later release. |
| The description and the public README say no entry can be deleted, "not even with your PIN", and the README's invariant says there is no delete control. | Claude Opus 5.5, Claude-2; DeepSeek, DVF-2 and wrong claim 1 | Medium (Claude); High (DeepSeek) | The public README's invariant was corrected for 1.12: the event log's records have no delete control, and a set-aside log can be deleted whole, with the PIN, which leaves a status entry. The description and the README's opening stay: no single entry can be deleted, and a set-aside log goes whole. |
| The verifier prints only 8 of a key ID's 64 characters, so the whole ID that Settings copies can't be compared. | Claude Opus 5.5, Claude-3 | Low to Medium | Not changed in 1.12: Settings' footer says the check names the key by eight characters. Planned for a later release: the verifier prints the export's key in full. |
| The share sheet's ask on the main thread can wait up to a minute on the ZIP being made. | Claude Opus 5.5, Claude-4 | Low | Known (Codex-3 of the first review). Planned for a later release, with this report's one-line fix, after a check on a phone. |
| A face or finger that opens the Event Log can share all the evidence. | Claude Opus 5.5, Claude-5 | Low (a judgement) | SECURITY.md now says what a face or finger can do behind the Event Log besides read: share an event or a set-aside log, download a full photo or clip from iCloud, and dismiss notices; it cannot delete a set-aside log. Share is as designed. A download that never costs older evidence is planned for a later release. |
| On the armed screen's PIN pad, ⌫ delays a fresh warning without spending a guess. | Claude Opus 5.5, Claude-6 | Low | Known and accepted: SECURITY.md says that someone tapping keys can delay a fresh warning for as long as the pad is open. A warning or siren already sounding goes on, and detection and capture never stop. No change. |
| Each removal by the storage limits re-reads every set-aside log on the store's write queue. | Claude Opus 5.5, Claude-7 | Low (suspected) | Known (DS-5 of the second review): about 1.5 seconds for a 20 MB log on a Mac. A search in one pass is possible later. |
| The privacy policy doesn't say that an evidence ZIP also carries that watch's status entries and fingerprints of the rest of the log. | Claude Opus 5.5, wrong claims table | not rated | Not changed: SECURITY.md says what an evidence ZIP carries, and you choose each share. |
| The description's "your iPhone will either be in the same state you left it, or you'll know it wasn't" promises more than the sensors give: a slow, level lift can go unseen. | Codex, Codex-1 | High | Not changed: the sentence states what the app is built for, and SECURITY.md lists the slow, level lift among its limits. |
| A shared ZIP could carry older signed facts than the event has, after signing its newest revision failed. | Codex, Codex-2 | Medium | Fixed in 1.12: Share makes no ZIP unless the event's facts are those of its latest signed revision, and the event's screen then says the share went without it. Test: `Item90ExportTests.testABundleIsMadeOnlyWithTheFactsItsLatestRevisionSigned`. The decision records were corrected to match. |
| The journal's rewrite is not flushed to storage the way its appends are. | Codex, Codex-3 | Medium (the loss suspected) | Planned for a later release, with the work on simulated storage faults. A loss is suspected, not shown. |
| The signature file has no size bound, and the verifier refuses one over 64 MiB. | Codex, Codex-4 | Medium | Planned for a later release. Measured on a real bundle: about 450 bytes a signature, so the limit is about 149,000 signatures, some twenty years at that phone's rate. |
| On an iPhone with no passcode, a restart clears the wait after wrong PINs, so after the first five each restart allows one more guess. | DeepSeek, DVF-1 | High | Known as a decision, with this one gap: elsewhere a restart stops at the iPhone's own passcode, which someone guessing PINs doesn't have. SECURITY.md and the public README now say so, and that the iPhone needs a passcode. A change of behaviour, such as no arming without a passcode, is a decision for a later release. |
| A journal line that can't be read, or a journal that can't be read at all, is passed over without a notice on Home. | DeepSeek, DVF-3 | Medium | As designed for a torn last line, which a hard power-off leaves. A line on Home when the journal can't be read is being considered for a later release. |
| The watch's 10-second deadline can drop an alert not yet shown, with no sign on the watch. | DeepSeek, DVF-4 | Medium | As designed: the watch must hand back each wake within watchOS's limit, and the event is in the iPhone's Event Log. Planned for a later release: the watch saves each alert it is handed until it is shown. |
| A set-aside log's Share sends the whole file, with no warning at the button. | DeepSeek, DVF-5 | Medium | As designed: Share sends an exact copy of the file, as the ZIP's README says. No caption was added. |
| The notice after a Delete that left photos is lost if Malinois closes before you dismiss it. | DeepSeek, DVF-6 | Low | The decision record was corrected: the notice stays until you dismiss it or Malinois is closed. The status entry that each Delete now writes (Claude-1) says when its photos and clips were left on the iPhone. |
| A wrong PIN's red "Incorrect PIN" may never show. | DeepSeek, DVF-7 | Low (suspected) | Likely as described, by reading; to be checked on a phone. The shake, the buzz and the count of wrong PINs are not affected. |
| What's New's "with the photos and clips it names": only those still on the iPhone go. | DeepSeek, wrong claim 2 | not rated ("a judgement") | Fixed at the submission: What's New says "its photos and clips still on your iPhone". |
| The shorter copy of the App Review notes says "nothing is saved until a tripwire fires", leaving out the signal-loss record. | DeepSeek, wrong claim 3 | Medium (if pasted) | Confirmed; the full notes have it. To be corrected when that copy next changes. |
| The private repository's README says "Reaching Disarmed requires the PIN", leaving out a countdown cancelled before the watch began. | DeepSeek, wrong claim 5 | not rated ("a precision issue") | Not changed: the same README explains the cancelled countdown further down. |
| The App Review notes had no line for 1.12. | DeepSeek, wrong claim 6 | Low | Done for the submission: the project's own App Review notes gained a line for 1.12. |

**The look at this review's fixes.** Codex looked at both: ready, no new finding.

## Review 4: `77d7792`, 2026-11-11

Two reports. Neither found a way past the PIN or Guided Access, an upload to a wrong account, or a forged bundle that
passes, and both read the PIN step at Delete and the status entry it now leaves, and found them sound.

| Finding | Report and ID | Its severity | What was done |
|---|---|---|---|
| A picture still loading on an event's screen can land under the other camera's name after another device updates the event. What's New's sentence on the camera is too broad. | Codex, Codex-1 | Medium | Planned for a later release: the picture is set only if its load was not cancelled, with a test that uses real pictures. Nothing stored is wrong. What's New's sentence stays: it is true of where the file is stored. |
| An old record's front-camera thumbnail can show under "Rear camera". | Codex, Codex-2 | Medium | Known (Codex-2 of the first review). Planned for a later release, with Codex-1. |
| Share's preparation can wait on signing before its one-minute limit exists. | Codex, Codex-3 | Medium (suspected) | Known (Codex's second finding in the second review). Planned for a later release. |
| A siren that started may stay silent if iOS ends an audio interruption without saying so, or resets audio. | Codex, Codex-4 | Medium (suspected) | A look on a phone first; then, in a later release, a check each time Malinois comes back to the front, and a sentence in SECURITY.md. |
| Once a log has been set aside, the check of every evidence ZIP the iPhone shares afterwards ends in problems. | DeepSeek, deepseek-1 and wrong claim 3 | High | As decided in 1.10: those records did leave the log, and a milder statement would let damage to a backup hide a real deletion. Fixed in 1.12's documents: SECURITY.md and the public README now say so. |
| The search of a set-aside log's bytes finds a photo's name in a field that is not a photo's, and Delete removes that file. | DeepSeek, deepseek-2 and wrong claim 1 | Medium | Planned for a later release: the search limited to the records' photo fields and the part that could not be read, and the decision record's sentence corrected. Only an edited backup restored to the phone can write such a record. |
| After a log is set aside, a red line says signed records are no longer in the log, on your other devices too. | DeepSeek, deepseek-3 | Medium | As decided: the line is true, and the new sentences on set-aside logs (deepseek-1) explain it. |
| What's New's "the event's screen now says why" isn't true for the newest case. | DeepSeek, deepseek-4 and wrong claim 2 | Low | Fixed at the submission: What's New says the screen tells you so, "and why when it can". |
| A set-aside log that names no photo can be reported as having left its photos, where the media folder is a link. | DeepSeek, deepseek-5 | Low | Planned for a later release. Only an edited backup can put a link there. |
| Home's "It's at the top of the Event Log": a Delete's notice is listed above the set-aside logs. | DeepSeek, wrong claim 4 | not rated ("minor") | Not changed: a choice of words. |

**After this review.** No fixes followed: the candidate was archived as it was. Neither report found a way past the
PIN, a forged bundle or a loss of evidence on an ordinary phone, and the one new finding in the code is a rare wrong
picture on one screen, not a wrong record. This candidate is the build that shipped.
