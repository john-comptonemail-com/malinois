# Malinois 1.13 (89) at 1aadc3c: adversarial review

- **Reviewer:** Fable 5.2 (claude-fable-5-2), run as a subagent of a Claude Code session. I started from this folder alone: no ledger, no project notes, no other reviewer's report or notes. I read none of the other `_REVIEW_REPORT_` files; two folder-wide text searches passed over them, with their lines filtered out before any output reached me.
- **Date:** 2026-11-15
- **Method:** static reading of the folder. I had no Simulator and no device.
- **Tests run:** none of the project's tests. Six small probes, compiled with `swiftc` for macOS in my own scratch space, against the folder's real `Malinois/Models/Event.swift`, `CoreTypes.swift` and `CaptureFailureReason.swift`, or against code copied verbatim from the file named. Nothing in the folder was built or changed. Their summary lines:
  1. Probe 1 (the two date clamps of `CloudExfiltrator.swift`, verbatim, with the real `Event`): `startDate NaN: after the clamps start=nan end=nan` / `THE LOG WITH IT DOES NOT ENCODE: EncodingError.invalidValue: nan (Double). Path: [1].startDate.` The same for minus infinity. Plus infinity is clamped and encodes; -1e300 encodes and decodes.
  2. Probe 2 (the date formatting and calendar calls the log's screens use, on NaN, minus infinity, plus and minus 1e18, -1e300): no crash, no hang.
  3. Probe 3 (`EvidenceExporter.watch(around:in:)`, verbatim, on an armed session ended by a forced restart): eight status records shown in full, six of them from after the session ended (listed under fable-2).
  4. Probe 4 (a `CKRecord` on macOS, nothing sent anywhere): `NaN: set nan; read back from the record: Optional(nan)` / `after an archive round trip (2671 bytes): Optional(nan)`, the same for both infinities; `CKDPDate ivars: _time:d`.
  5. Probe 5 (the same function, on an old incident whose own arm and disarm rows have left the log): shows `day +41 Malinois PIN changed in Settings`, `day +41 Camera switched off in Settings`, `day +42 Monitoring disarmed`.
  6. Probe 6 (which clock `ProcessInfo.systemUptime` is): `systemUptime - awake-only clock = -0.000 s; continuous - systemUptime = 156723.5 s (the time this Mac has slept since it started)`.
  The probes' sources are in (a temporary folder) (`probe1` to `probe6`); that folder is temporary. The tests I would add to the suite are written out under each finding.
- **Secrets:** none found (a search for private-key headers, common token shapes and key files, the other reviewers' files left out).

Anything that depends on a device, on CloudKit's servers or on SwiftUI's timing is marked SUSPECTED, with the check that would settle it.

## 1. For the owner, in plain English

**Overall.** I found no way to disarm Malinois, or to leave the armed screen, without the PIN. I found no way for an edited evidence ZIP to pass the Mac verifier. I found nothing that 1.13 makes worse than the 1.12 that is live. The PIN's storage and lockout, the welcome screen and the launch routing, the arming and disarm paths, the event log's protection against a crash, the account binding of uploads, and the verifier all held up to a close read.

I did find three problems worth fixing and four smaller ones. All of them are already in 1.12; none is new in 1.13.

**The problems that matter, most serious first**

1. **Reinstalling Malinois, or adding a second device, quietly brings back "Auto-delete after 12 months" for your whole iCloud account (fable-1, High; no App Store user can be hit before 24 August 2027).**
   You set iCloud Photo & Video Storage to Keep forever on your iPhone. More than a year later you delete and reinstall Malinois (the README itself describes "delete, reinstall, verify iCloud access"), or you set up a spare iPhone as the README's room-watching section suggests, and you verify iCloud access there. The new install starts at the default, 12 months. At its next clean-up pass it deletes from iCloud the full-size photos and clips of every event older than 12 months, from all your devices. Nothing asks you and nothing is written in the Event Log. After a reinstall those were the only full-size copies.
   The code already states the right rule in three other places: "nothing in iCloud is deleted on the strength of a setting the owner never chose". A new install's default is such a setting.
   What to do: an install's automatic clean-up should not delete until you have set or confirmed the setting on that install, and the first automatic deletion on an install should leave an Event Log entry. The first release was 24 August 2026, so no App Store user's photo is 12 months old before 24 August 2027; your own records from before the release reach 12 months sooner. This need not delay 1.13; it must be fixed well before that date.

2. **An evidence ZIP can show more of your log than SECURITY.md says (fable-2, Medium).**
   SECURITY.md says the ZIP shows the armed session around the event, "from the arming to the disarming", and the rest of the log only as fingerprints. That holds when you disarmed. It does not hold in the case where you are most likely to share evidence:
   - Someone forces a restart while Malinois is armed. You come back, stop the automatic re-arm, change your PIN, switch the camera off or change the response mode, and then share the event with building security. The ZIP shows, in full, every status entry from the arming up to that moment: the PIN change, each settings change, iCloud backup turned off. Those tell the reader how your phone is set up now.
   - You share an event that is some weeks old, whose own "armed" and "disarmed" entries have since left the log (it keeps the newest 100 status entries). The ZIP then shows the next entries the log still has, from another armed session weeks later, as if they belonged to this event.
   What to do: end the shown part at the armed session's real end, show the event alone when its session can no longer be found, and correct the sentence in SECURITY.md.

3. **One made-up iCloud record with an impossible date stops an iPhone from saving its event log (fable-3, Medium; the last step needs a device to confirm).**
   This needs the person SECURITY.md already describes: someone who has your Apple Account on a device they control and can write records to it. They save one record whose time is "not a number". Each of your iPhones takes it in at its next pull, which a push normally starts at once. From then until Malinois is restarted, that iPhone cannot save its event log and signs nothing new; Home says "storage may be full", which is not the cause. After a restart the next pull brings the record back. New events are not lost outright (each is still written to the journal as it starts, and its photos are still saved), but what is added to an event after it starts (its end, a growing count, a wrong-PIN count) is lost if the app stops, and no evidence ZIP can be made for events recorded meanwhile. SECURITY.md says such a record "buys distraction in the log, not reach into the on-device record"; this one reaches it.
   What to do: refuse a record whose date is not a real date (two lines, plus tests).

4. *(A finding is left out here until its fix ships; the release's page says so.)*

5. **The wait after wrong PINs only counts down while the iPhone is awake (fable-5, Low).** The help page says "up to an hour". With the iPhone locked in a pocket the hour barely moves.

6. **The Test sensors screen can switch off a session's Pro tripwires if an automatic re-arm starts under it (fable-6, Low, cannot happen while Early-Access is open).** A one-line guard closes it.

7. **A judgement, not a defect: steady gentle handling for under an hour can push an armed session's first events out of the log (fable-7).** SECURITY.md says so. On an iPhone that is not uploading them, nothing in the log then says that events were removed.

**Would I let 1.13 (89) go to the App Store?** Yes.

- **Before submission:** nothing in the build.
- **With the release's documents, which need no new build:** correct the three sentences in SECURITY.md listed in part 3 (a, b, c). Sentence a is false whenever an armed session ends without a disarm. Sentences a and b are already published with 1.12; c is new in 1.13's text.
- **Later, in 1.14:** fable-1, fable-2 and fable-3, each with the tests below. Each changes how evidence is handled, so I would not squeeze them into a build that has already passed its runs. fable-1 has a hard date: before August 2027.
- **After one device check:** fable-4 (left out here until its fix ships).
- **When convenient:** fable-5, fable-6, fable-7, and the camera permission text (part 3, e), which needs a build.

## 2. Findings

| ID | Severity | Status | Fix |
|---|---|---|---|
| fable-1 | High | VERIFIED (code) | later, before August 2027 |
| fable-2 | Medium | VERIFIED (code and probes) | later; the sentence now |
| fable-3 | Medium | VERIFIED on the phone's side, SUSPECTED for CloudKit's carriage | later |
| fable-4 | Medium | SUSPECTED | after a device check |
| fable-5 | Low | VERIFIED (code and probe) | later |
| fable-6 | Low | VERIFIED that the guard is missing, SUSPECTED for the order of events | later |
| fable-7 | Judgement | VERIFIED (code), disclosed | owner's choice |

### fable-1 (High, VERIFIED by code): a new install's untouched default deletes the account's old photos and clips

By the scale's wording, evidence lost without notice is Critical. I rate it High because the documents do state the default and the "shortest setting wins" rule, the event's facts and thumbnail stay, and no App Store user can be hit yet. If the owner counts the "shortest setting wins" sentence as covering a reinstall, read this as a judgement on a choice; I think it is an oversight, because the code's own rule (below) says otherwise.

**What is wrong.** The automatic iCloud clean-up acts on whatever retention value this install holds. A new install holds the default, 12 months, which nobody chose, and the clean-up covers every device's events on the account.

**The situation.** As in part 1: Keep forever (or Manual) chosen on the first install; a reinstall on the same iPhone, or a second device; Verify iCloud access. The pass is tried each time the app comes to the front, at most once an hour and once a day after a success. The first pass that has verified access deletes the full-size photo records of every event older than 12 months by iCloud's own dates. A reinstall has already removed the phone's copies. No entry is written: ADR 0084's decision 3 gives the reason as "every change of that setting is already in the log", and a new install's default is not a change. Its amendment of 2026-11-14 already names one other case where that reason fails and plans "a pass that acts only on a recorded value" for 1.14; this case belongs in the same change.

**Evidence.**
- `Malinois/Models/AppSettings.swift:342`: `cloudRetention = .months12` in `init()`. Lines 423 to 427: a stored value that cannot be read becomes `.forever`, an absent one `.months12`. Line 744: a settings reset sets `.forever`, with the comment "nothing in iCloud is deleted on the strength of a setting the owner never chose".
- `Malinois/Services/MonitoringCloudCoordinator+CloudRetention.swift:153-176`: the pass takes `settings.cloudRetention.autoMonths` and calls `cloud.purgeFullMedia`. `Malinois/Services/MonitoringEngine+Screen.swift:114`: run on every return to the front.
- `Malinois/Services/CloudExfiltrator.swift:2189-2236`: the purge pages the account's event records older than the cutoff and deletes their photo records; nothing limits it to this phone's events. `SECURITY.md:1453-1454` says the same.
- `Malinois/Views/SettingsView.swift:39` (the caption: "if they are set differently, the shortest setting wins") is the only notice, and the picker can be set before verifying, so an owner who knows can avoid it.
- `MalinoisTests/Item169ReviewTests.swift:239-243`, `testAnUnchangedSettingStillDeletes`: the suite's own control shows the pass deleting on whatever the settings object holds.

**Smallest fix.** Keep a flag per install, "the owner set or confirmed iCloud Photo & Video Storage here", set by the picker. While it is unset, the automatic pass deletes nothing; if iCloud holds events older than the period, Home or Settings says so and asks for the choice. And write a status entry the first time an install's automatic clean-up deletes anything, in the words 1.13's manual entry already has.

**Probe.** In `Item169ReviewTests`, with its own stand-in for iCloud:

```swift
/// A new install: nobody has touched the retention setting, and iCloud holds an event older than its default.
func testANewInstallsUntouchedDefaultDeletesNothing() async {
    let (engine, _, stand) = rig(retention: AppSettings().cloudRetention)   // 12 months, as a reinstall has it
    await engine.enforceCloudRetentionIfDue()
    XCTAssertEqual(stand.batches.count, 0, "a setting the owner never chose on this install deleted iCloud's photos")
    // today: 1 batch, the old event's photo records
}
```

**When.** Later, but well before 24 August 2027; sooner if the owner's own account has records from before the release and gets a second install.

### fable-2 (Medium, VERIFIED): the evidence ZIP shows status entries from outside the armed session

By the scale's wording a false published sentence is High. I rate it Medium because what leaks is status lines, not photos or the PIN.

**What is wrong.** `EvidenceExporter.watch(around:in:)` finds the armed session by its neighbours in the log: back to the last "armed" row, forward to the first "disarmed" row, or to the row before the next "armed", or to the end of the log. Every status record in that stretch goes into the ZIP in full (`statements/<hash>.json`). Two cases give the wrong stretch.

**Situation A, an armed session that never got a disarm.** A forced restart, a closed app, a flat battery. Probe 3, with the function copied verbatim:

```
Sharing the trip of the interrupted session shows these status records in full:
  +0 min  Monitoring armed
  +50 min  Monitoring interrupted: the device restarted while armed
  +51 min  Arming cancelled before going live
  +3000 min  Malinois PIN changed in Settings; the current PIN was entered first
  +3001 min  Camera switched off in Settings
  +3002 min  Response mode set to Stealth (covert) in Settings
  +3003 min  iCloud backup turned off: events recorded while it is off are never uploaded
  +3004 min  The siren played through Owner's AirPods Pro, not this iPhone's speaker
With a disarm record after the trip:
  +0 min  Monitoring armed
  +50 min  Monitoring disarmed
```

(The last line of the first list stands for any later status entry; the app writes that kind while armed, so in practice the entries shown are the ones made while disarmed: cancels, the PIN change, settings changes, the iCloud backup switch.)

**Situation B, an old event whose session's rows have left the log.** Incidents and status entries have separate limits (500 and 100, `EventStore.swift:108-110`), so an incident outlives its own "armed" and "disarmed" rows. The scan then runs forward into whatever status rows remain. Probe 5:

```
B. Sharing the day-0 incident after its session's own rows were retired shows in full:
  day +41  Malinois PIN changed in Settings; the current PIN was entered first
  day +41  Camera switched off in Settings
  day +42  Monitoring disarmed
```

A reader of that ZIP can also take the disarm of day 42 for the end of the day-0 session.

**Evidence.** `Malinois/Services/EvidenceExporter.swift:171-191` (the function) and line 113 (`shown = revision.id == record.id || watch.contains(revision.id)`). `SECURITY.md:334-338` (the sentence). `docs/adr/0067-evidence-signings-export-bundle.md:50` and `docs/adr/0070-evidence-signings-export-bundle-check-and-verifier.md:52` write the fallback down ("to the next arm or the log's end without one"), so the rule was chosen; the published sentence does not carry it, and I think the fallback itself is a mistake. `MalinoisTests/Item90ExportTests.swift:314-333` pins it ("no disarm yet: to the log's end"), reading it as a session still under way; but the Event Log opens only while disarmed, so a record shared with no disarm after it is always from a session that was cut short.

**Smallest fix.**
1. Stop the forward scan at an interruption record whose cause is `rebooted` or `terminated`, and keep that record: it is the session's end.
2. Stop before the first status entry that can only be written while disarmed (`armingCancelled`, `reArmSkipped`, `pinChanged`, the settings kinds, the iCloud backup kinds, `reinstalled`, `settingsReset`, a set-aside log's delete, the iCloud clean-up's entry).
3. When no "armed" row comes before the record, show the record alone, with an interruption record that directly follows it.
4. Correct `SECURITY.md:334-338` (part 3, a).
A sturdier fix for later: give every record its armed session's ID when it is made, and take the stretch from that.

**Probe.** In `Item90ExportTests`, with its own helpers:

```swift
func testAnInterruptedSessionsStatusRecordsEndAtTheInterruption() {
    let arm = status(10, "armed"), incident = trip(14), stopped = interruption(15)   // no disarm follows
    let cancelled = status(16, "armingCancelled"), pin = status(17, "pinChanged"), backup = status(18, Event.backupOffKind)
    let log = [backup, pin, cancelled, stopped, incident, arm]   // newest first
    XCTAssertEqual(EvidenceExporter.watch(around: incident, in: log), [arm.id, stopped.id])
    // today: all five
}

func testARecordWhoseSessionsRowsHaveLeftTheLogShowsNoOtherSessions() {
    let incident = trip(1), later = trip(20), pin = status(41, "pinChanged"), disarm = status(42, "disarmed")
    XCTAssertEqual(EvidenceExporter.watch(around: incident, in: [disarm, pin, later, incident]), [])
    // today: pin and disarm
}
```

**When.** The sentence with 1.13's documents. The code later.

### fable-3 (Medium; VERIFIED from the decoder onward, SUSPECTED that CloudKit carries the value): a cloud record whose date is not a number stops the log from saving

If the device check confirms the carriage, a published sentence is false and the scale's wording makes this High.

**What is wrong.** Both cloud decoders clamp the start date with `min(start, serverStamp + 1 day)` and check nothing else about it. `min` leaves NaN and minus infinity as they are. The row is merged as another device's copy. The log is one file, written whole by `JSONEncoder`, which throws on a date that is not finite. One such row therefore fails every write.

**The situation.** The adversary is SECURITY.md's "iCloud credentials and authorized clients": someone with your Apple Account on a device where a tool of theirs can act as the app towards CloudKit. I did not try to build such a client; SECURITY.md already grants that one "could also alter records or add made-up ones".
1. They save one tamper record with `encryptedValues["startDate"]` set to NaN.
2. CloudKit pushes; each running Malinois pulls (`MonitoringCloudCoordinator+Transfers.swift:48-57`, then line 313), armed or not.
3. `CloudExfiltrator.event(from:)` returns an event; `EventStore.merge` puts it at the top of the log; `persist()` fails. `persistDegraded` turns on, and Home shows "New events aren't being saved to this device - storage may be full."
4. For the rest of that run of the app: no log write succeeds; the signer hears no write, so nothing new is signed and Share can make no ZIP for new events; the journal is never trimmed; photo notes pile up towards their limit of 1,200, after which a new photo's save is refused (`EventStore.swift:2533`); the storage limit's deletions wait.
5. If the app then stops (a forced restart is the obvious next move), the log comes back from the last good file and the journal: each event as it was born, with its photos, but without what was added later.
6. At the next launch the pull brings the record back, for as long as it is among the newest 100 of its type by iCloud's dates (`CloudExfiltrator.swift:1563`, `1582`). Tamper records are rare, so that can be months. The app has no way to remove it; only deleting the app's iCloud data does.

**Evidence.**
- `Malinois/Services/CloudExfiltrator.swift:1200-1215` (the clamps), `1268-1273` (`event(from:)`), `1438-1465` (`stateEvent(from:)`): no check that the date is finite. The same file does check for it in `retryDelay` and in the retention clock, and `MalinoisTests/CloudExfiltratorTests.swift:35` and `:99-100` test those two; the decoders were missed.
- `Malinois/Services/EventStore.swift:538-549` (`merge`: no check), `374` (a NaN row goes to index 0, so the limits take it last), `2929` (`try JSONEncoder().encode(snapshot)`), `2931` and `2945` (the photo notes' trim and the signer's notice happen only after a write that succeeds).
- Probe 1 (output in the header): the event the decoders would return does not encode in an array with one of the phone's own records.
- Probe 4: CloudKit's own record object accepts a NaN date in `encryptedValues` and keeps it through its archive, and the framework's wire message for a date is a single `double`. The server cannot inspect an encrypted field. That is why I expect the value to arrive, and why this leg is still SUSPECTED.
- `MalinoisTests/Item148DecoderFuzzTests.swift:385-393`: `randomDate` makes only finite dates. `MalinoisTests/Item73RegressionTests.swift` (`testAnEventTheJournalCannotEncodeIsSurfacedToo`) says "No event the app makes is known to fail to encode"; this is a way to be handed one.
- `SECURITY.md:662`: "Insertion buys distraction in the log, not reach into the on-device record".

**What would confirm the suspected leg.** A development build on two devices on one test account: on the first, save one record of the tamper type with `record.encryptedValues["startDate"] = Date(timeIntervalSinceReferenceDate: .nan)` and a fresh `eventID`; on the second, pull and look at Home.

**Smallest fix.** In both decoders: `guard rawStart.timeIntervalSinceReferenceDate.isFinite else { return nil }`. The record then counts among those "this version can't read", which Home already reports. As a second line of defence, `EventStore.merge` should drop an incoming copy that does not encode. Later, consider making `persist()` find and set aside a row that does not encode instead of failing the whole file.

**Probes.** Add to `randomDate` a case that returns NaN, plus infinity or minus infinity, and to `testCloudEvidenceRecordsAreBoundedOrDropped` the check `(try? JSONEncoder().encode(event)) != nil`. The test's present check "start not clamped" already goes red on NaN. And:

```swift
func testACloudRecordWhoseDateIsNotANumberIsNotARecord() {
    for raw in [Double.nan, -Double.infinity] {
        let tamper = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2)
        tamper.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        tamper.encryptedValues["startDate"] = Date(timeIntervalSinceReferenceDate: raw) as CKRecordValue
        XCTAssertNil(CloudExfiltrator.event(from: tamper))            // today: an event

        let status = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2)
        status.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        status.encryptedValues["startDate"] = Date(timeIntervalSinceReferenceDate: raw) as CKRecordValue
        status.encryptedValues["kind"] = "armed" as CKRecordValue
        XCTAssertNil(CloudExfiltrator.stateEvent(from: status))      // today: an event
    }
}

func testNoCopyFromICloudStopsTheLogSaving() async {
    let store = EventStore()
    store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .localOnly))
    let bad = Event(id: UUID(), startDate: Date(timeIntervalSinceReferenceDate: .nan),
                    endDate: Date(timeIntervalSinceReferenceDate: .nan), triggeredSensors: [.motion],
                    cloudSyncState: .synced, sourceDevice: "another device", cloudRevision: 1)
    store.merge([bad])
    store.drainIOForTesting()
    await Task.yield()   // the flag is set by a main-actor task from the write's queue
    XCTAssertFalse(store.persistDegraded, "one copy from iCloud stopped every write of the log")   // today: true
}
```

**When.** Later (1.14), unless another build is made anyway; the decoder guard is two lines.

### fable-4 (Medium, SUSPECTED)

*(Left out here until its fix ships; the release's page says so.)*

### fable-5 (Low, VERIFIED by code and probe 6): the wrong-PIN wait is counted in awake time

`Malinois/Services/KeychainService.swift:458` and `:513` time the wait on `ProcessInfo.systemUptime`. Apple documents that as time awake, and probe 6 shows it equal to the kernel's awake-only clock. An armed iPhone stays awake, so the wait runs there. Disarmed, at the Event Log's or Settings' PIN gate, an iPhone that is locked and asleep does not count: "Try again in 3600s" can last many hours of ordinary use. `store/support.html:147-149` and `SECURITY.md:764-766` say up to an hour.

**Check on a device:** eight wrong PINs at Home's Event Log gate (the wait is then 4 minutes); lock the iPhone, unplugged, for 10 minutes; unlock and open the gate. If most of the wait is still there, it did not count the sleep.

**Smallest fix.** Time it on the continuous clock (`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`), which no setting moves either and which counts sleep; a restart still clears it, as now. Or keep the clock and correct the two sentences.

### fable-6 (Low; VERIFIED that the guard is missing, SUSPECTED for the order of events): `stopDryRun()` acts on a session it does not own

`Malinois/Services/MonitoringEngine+TestSensors.swift:111-131` has no guard: it stops every monitor, stands the camera down and sets `armedPro = false`. `Malinois/Views/DryRunView.swift:102` calls it whenever the Test sensors sheet goes away. If an owed automatic re-arm starts while that sheet is open on Home, `beginArming()` stops the test and takes the session's Pro snapshot (`MonitoringEngine.swift:2165`); Home is then replaced, the sheet goes away, and the second, unguarded stop clears the snapshot. The session runs without the Sound and Vision tripwires, with the free camera options and without heartbeats; uploads go on. The re-arm can only be owed with Home on screen while the Pro check is unanswered, which Early-Access settles at once, so this waits for the day the program closes.

**Smallest fix.** `guard dryRunActive else { return }` at the top of `stopDryRun()`.

**Probe.**

```swift
func testAStopOfATestThatIsNotRunningLeavesTheSessionAlone() {
    let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: EventStore(), cloud: CloudExfiltrator(),
                                                      camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .pro),
                                                      timing: EngineCharacterizationTests.fastTiming))
    engine.beginArming()
    XCTAssertTrue(engine.armedPro)
    engine.stopDryRun()   // what the Test sensors sheet does when it goes away
    XCTAssertTrue(engine.armedPro, "a test that was not running cleared the session's Pro snapshot")   // today: false
}
```

### fable-7 (a judgement; VERIFIED by code, disclosed in SECURITY.md): an armed session can lose its own first events

Up to 10 trips a minute from one sensor and 15 triggers a minute in all are not a flood (`MonitoringTripResponder.swift:86`, `:204`, and `+Responses.swift:322`). At those rates the 500-incident limit turns over in 33 to 50 minutes, slower if each capture takes longer; at the 6 a minute the code calls a human rate, in under an hour and a half. Records not yet uploaded go last, oldest first, so on an iPhone that is offline, has iCloud backup off or is not verified, the first photos of the handling are the first to go. The entry "Events not fully backed up to iCloud were removed to make room" is written only on Pro and not for records kept on the phone by choice (`MonitoringEngine+Retention.swift:29-33`). `SECURITY.md` (the flooding paragraph) states the limit, so this is a choice, and I would change it: never let the limit take the first few incidents of the armed session under way, and write one entry whenever it removes an incident of that session, whatever the tier.

## 3. Wrong claims in the documents

a. **`SECURITY.md:334-338`**: "the armed session around it, from the arming to the disarming; ... and the rest of your log only as fingerprints of what was signed, so its content stays private". Wrong when the session got no disarm, and for an old event whose session's rows have left the log (fable-2). Until the code changes: "this phone's status entries around it, from the arming to the disarming; if the armed session ended without a disarm (a forced restart, a closed app), every status entry up to the next arming, or to the end of the log, is shown in full". After the fix: "from the arming to the disarming, or to the entry that records the interruption".

b. **`SECURITY.md:662`**: "timestamps believed at most a day ahead of the record's own server stamp ... Insertion buys distraction in the log, not reach into the on-device record". Not true of a timestamp that is not a number (fable-3). The fix makes the sentence true. If 1.13 ships first, add: "A record whose date is not a valid date is not yet refused: it stops the log from saving until Malinois is restarted (fixed in 1.14)."

c. **`SECURITY.md:1456-1457`**: "The automatic clean-up leaves none; every change of its setting is already recorded." A new install starts at 12 months without a change, and another device's setting is not this phone's change (fable-1); ADR 0084's own amendment names a third case. I would write: "The automatic clean-up leaves none. A change of its setting is recorded when Settings closes or at the next arm. A new install starts at 12 months, and that, like another device's shorter setting, deletes with no entry on this phone."

d. **`store/support.html:147-149`** and **`SECURITY.md:764-766`**: the wait after wrong PINs "up to an hour". It is an hour of awake time (fable-5). "up to an hour with the iPhone awake; the wait does not count down while it sleeps".

e. **`Malinois/Support/Info.plist:37`**, the camera permission text: "it also watches the camera's view for movement, in memory only". Since 1.13 a frame from that watching is saved when Vision trips on a slow change (ADR 0081); the privacy policy and the README say so, this text does not. "it also watches the camera's view for movement, and saves a frame only when it trips". It needs a build, so with the next one.

f. **The ZIP's own `README.txt`** (`MalinoisEvidence/EvidenceBundle.swift:56-59`): "This folder contains one event ... the event's record as it was signed, the photos, clips and sensor traces it names, the phone's signatures, and Apple's certification". It also contains the armed session's status entries in full, which is what the person sending it most needs to know. Add: "and the phone's status entries from the armed session around it".

g. **`store/APP_REVIEW_NOTES_FIELD.md`**, not live and marked to be brought up to date before use: its step 1 ("Set a 4-digit PIN") skips 1.13's welcome screen, where the reviewer must first tap Set a PIN. `store/APP_REVIEW_NOTES.md` has it right.

## 4. Where I went

**Read line by line and found sound.**
- The PIN: `KeychainService.swift` (the three-way read of the Keychain, PBKDF2 and the salt, the lockout and its in-process copy, both recovery kinds); `PINViews.swift`; `BiometricBinding.swift`.
- Launch and 1.13's onboarding: `MalinoisApp.swift`, `RootView.swift`, `OnboardingViews.swift`, `FirstArmBriefing.swift`; the welcome screen shows only with no PIN and no recovery pending, and nothing behind it needs a PIN that does not exist.
- Arming, the armed screen and disarm: `MonitoringEngine.swift` and its extensions, the `MonitoringArmingFlow` files, `ArmingView.swift`, `ArmedView.swift`, `DisarmEntryCoordinator.swift`, `HomeView.swift`. Every caller of `disarm()` is behind the PIN or is a cancel before going live.
- Trips: `MonitoringTripResponder.swift` and `+Responses.swift`, the monitors, the flood rules.
- The log: all of `EventStore.swift` (the journal and its full sync, the write-back, the limits and their order, the photo notes, set-aside logs, the merge rule that another device's copy never replaces this phone's record) and `SetAsideLog.swift`. Sound apart from fable-3.
- Cloud input and the account: `CloudEnrollment.swift`; in `CloudExfiltrator.swift` the decoders' other bounds, the fetch, the full-media download, the clean-up's use of iCloud's dates and its 30-day floor; `MonitoringCloudCoordinator+Transfers.swift` including 1.13's "a download is saved only if it fits"; `+CloudRetention.swift`.
- Evidence: all of `MalinoisEvidence/` and `MalinoisVerifier/` (the certificate chain to the built-in Apple root, the nonce, the app's identity, counters and gaps, the export statement, the ZIP's layout), `EvidenceSignatureFile.swift`, `EvidenceExporter.swift`, the last third of `EvidenceSigner.swift`. The evidence code already refuses numbers that are not finite (`EvidenceForm.milliseconds`), which is the care the cloud decoders lack.
- `Info.plist`, the entitlements and privacy manifests; the notification extension; `AlertRewrite.swift`; `WatchAlertRelay.swift`.
- Documents: `SECURITY.md` lines 1 to 1130 and 1760 to the end, the README's first 300 lines, `_PUBLIC_README.md`, `_LIVE_APP_STORE.md`; in part the store listing, the privacy policy, both App Review notes and ADRs 0055, 0067, 0070, 0081 and 0084; the rest searched for the claims I checked.
- Trap hunting across the app: no force unwraps, no `try!`, no format strings or predicates built from data, no dictionary built from unchecked keys, and no conversion of a time to a whole number fed from iCloud or from a stored file without a bound. Probe 2 says the log's screens will not crash on the bad date of fable-3.

**Not read, or only searched.** `CameraController.swift` and its clip-thumbnail file, most of `EvidenceCapturePipeline.swift`, the first two thirds of `EvidenceSigner.swift`, the upload half of `CloudExfiltrator.swift`, `SirenPlayer.swift`, most of `SettingsView.swift`, `EvidenceBundleItem.swift`, most of the Watch app, most of the tests, `tools/`, most ADRs. I have no finding there and no assurance to give.

**Could not check, and why.** Anything on a device: Guided Access, the camera, CloudKit's servers (fable-3's carriage), App Attest, fable-4's check (left out here), sleep (fable-5 beyond the probe), SwiftUI's order when a sheet is torn down (fable-6). None of the project's tests were run, so I cannot say the suite passes on this commit.

**Blind spots in how the app is built, tested and reviewed.**
1. **The random-input tests only make ordinary numbers.** The fuzz test's dates are all finite. A rule would catch the whole class: whatever a decoder admits must be saved, signed and shown without error, checked on every admitted value.
2. **One row that cannot be written stops the whole log.** The log is one file written whole. The app knows this for its own events (item 220's test) and shows a notice; the same weakness is reachable from outside (fable-3).
3. **An armed session is not a thing in the data.** Records carry no session ID, so the export has to guess a session from its neighbours (fable-2), and the guess is pinned by tests written for the easy cases.
4. **Rules are applied where a review found them, not where the decision is made.** "Nothing in iCloud is deleted on a setting the owner never chose" was added for a sealed settings store, a damaged one and an unreadable value, each after a finding, and not at the one place the automatic pass decides (fable-1). The date clamp has the same history: its comment calls it "the one scalar the F6 clamp suite missed".
5. **The comments steer reviewers.** They record each past finding at length. A reviewer, human or model, is led to re-check the cases the comments name and away from the ones no comment names. Most of the findings here sit beside a comment saying the matter was settled. One review per release that reads the code with the comments stripped would be worth trying.
6. **The paths that take hostile input cannot run in the Simulator.** CloudKit, App Attest, Guided Access and screen capture are covered by pure-function tests and by hand on devices. A small set of deliberately malformed records, saved to a test account from a development build and pulled on a second device, would test the one boundary that an outside party can write to.
