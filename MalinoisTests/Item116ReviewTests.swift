//
//  Item116ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 116: Codex's review of 1.7 (2026-10-13), ten findings, all confirmed. These are the
//  regression tests for the fixes, in the owner's three batches. Each drives the real path where
//  it can (the owner's rule of 2026-10-14: a test that sets up the very state it checks proves
//  nothing). Written before the fixes, red at their commits.
//
//  Batch A, what leaves the phone:
//  - R1: an incident recorded while backup is off lost its keep-local mark when the response
//    wrote its own copy back, and uploaded once backup was on again.
//  - R2: turning backup off stopped new uploads only at their start; an upload already under way
//    went on to its media steps and retries.
//  - R3: 1.6 and 1.5.1 ignore the mark, so installing one over 1.7 uploaded the kept events; they
//    are now also registered to no account, a hold every version since 1.5.1 keeps.
//  - R4: turning backup on during a running sweep lost its request to upload the backlog.
//  - The engine itself refuses the switch while armed (only the screen did).
//  - R8: the paired watch keeps its direct alerts while backup is off (the owner's ruling), and
//    the switch's text now says so.
//
//  Batch B, what the log keeps:
//  - R5: a status entry being uploaded had no protection from the log limit.
//  - R6: removals made while the log loads at launch left no marker: nothing listened yet, and
//    the Pro check had not answered.
//  - R7: the media clean-up could wait for an upload that ended while it measured the files.
//  - R9: the marker's once-a-day limit lived in memory and on a clock that can move back.
//  - The marker says the events were not fully backed up: some may have their record in iCloud.
//
//  Batch C:
//  - R10: a damaged clock entry (Int.min) trapped while its number was checked.
//  - Item 112's Both-cameras test could not tell whether two clips' room was asked for.
//
//  Batch D, from Codex's second look (2026-10-14), what was left of R4 and R9:
//  - N1: the request for a sweep after the running one was dropped when that sweep outlasted a
//    ten-minute wall-clock wait.
//  - N2: a removal's report read the watch when it ran, so a disarm in between counted a watch's
//    first loss as a disarmed one.
//
//  Batch E, from Codex's third look (2026-10-14):
//  - P1: the launch buffer, bounded by whole batches, dropped a batch of more than 600 removals
//    entirely, and with it the marker.
//  - N1's owed sweep: many requests during one sweep add one pass, never a loop.
//
//  Batch F, from Codex's fourth look (2026-10-14):
//  - Q1: the bound kept the newest 600 removals, so one trim of a single unsynced incident and 600
//    newer status entries kept only entries the marker can never count. The buffer now keeps every
//    removal the marker could count, and nothing else; there is no bound left to get wrong.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item116ReviewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem116Review")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - R1: the keep-local mark survives the response's write-back

    /// Through a real trigger: an incident recorded while backup is off keeps its mark after the
    /// response finishes, and turning backup on does not upload it.
    func testAnIncidentRecordedWhileBackupIsOffKeepsItsMarkThroughARealTrigger() async {
        let rig = makeRig()
        XCTAssertTrue(rig.engine.setCloudBackup(false))
        await arm(rig)
        rig.engine.handleTrip(.motion)
        let responded = await waitUntil(timeout: 5) { self.incidents(rig).first?.cloudSyncState == .localOnly }
        XCTAssertTrue(responded, "the response ran to its upload step, which backup held")
        rig.engine.disarm()
        let incident = incidents(rig).first
        XCTAssertEqual(incident?.keptLocal, true, "the response's write-back must not clear the mark")

        var offered: [UUID] = []
        rig.engine.sweepUploadForTesting = { event in offered.append(event.id); return (.synced, nil) }
        defer { rig.engine.sweepUploadForTesting = nil }
        XCTAssertTrue(rig.engine.setCloudBackup(true))
        let on = rig.store.events.first { $0.stateChange == Event.backupOnKind }
        let swept = await waitUntil(timeout: 4) { on.map { offered.contains($0.id) } ?? false }
        XCTAssertTrue(swept, "turning backup on ran a sweep")
        XCTAssertFalse(offered.contains { $0 == incident?.id }, "recorded while off: never offered, even once backup is on")
    }

    /// The rule underneath: a stale copy written back never clears the mark.
    func testAWriteBackNeverClearsTheKeepLocalMark() {
        var stored = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
        stored.keptLocal = true
        var stale = stored
        stale.keptLocal = nil
        XCTAssertEqual(EventStore.preservingMonotonicFields(current: stored, incoming: stale).keptLocal, true)
    }

    // MARK: - R2: off stops an upload already under way

    /// Backup turned off while an upload's first record is being saved: neither camera's file
    /// follows it.
    func testTurningBackupOffStopsTheRestOfAnUploadAlreadyUnderWay() async throws {
        let rig = await makeCloudRig()
        let event = try mediaEvent(in: rig)
        let meta = "meta-v2-" + event.id.uuidString
        var saved: [String] = []
        rig.cloud.saveAttemptForTesting = { records in
            let names = records.map(\.recordID.recordName)
            saved.append(contentsOf: names)
            if names.contains(meta) { rig.engine.setCloudBackup(false) }   // the owner turns it off now
        }
        defer { rig.cloud.saveAttemptForTesting = nil }
        await rig.engine.uploadSnapshotForTesting(event, throughSweep: false)
        XCTAssertTrue(saved.contains(meta), "the step under way when backup went off")
        XCTAssertFalse(saved.contains { $0.hasPrefix("photo-") }, "nothing new starts after off: \(saved)")
        XCTAssertNotEqual(rig.store.events.first { $0.id == event.id }?.cloudSyncState, .synced,
                          "the event waits for backup to come back on")
    }

    /// Backup turned off while a save waits to retry: the retry never goes out.
    func testTurningBackupOffStopsARetry() async throws {
        let rig = await makeCloudRig()
        let event = incident()
        rig.gate.registerLocalEvent(event)
        rig.store.add(event)
        let meta = "meta-v2-" + event.id.uuidString
        var attempts = 0
        rig.cloud.saveAttemptForTesting = { records in
            guard records.contains(where: { $0.recordID.recordName == meta }) else { return }
            attempts += 1
            if attempts == 1 {
                rig.engine.setCloudBackup(false)
                throw CKError(.networkFailure)   // a retry would follow in half a second
            }
        }
        defer { rig.cloud.saveAttemptForTesting = nil }
        await rig.engine.uploadSnapshotForTesting(event, throughSweep: false)
        XCTAssertEqual(attempts, 1, "the retry after off never goes out")
    }

    /// Every upload step and every save attempt reads the switch, after each wait: ownership is
    /// checked only through `mayUpload`, every `save` re-reads the switch before each attempt, and
    /// a heartbeat reads it before it is sent.
    func testEveryUploadStepAndAttemptReadsTheSwitch() throws {
        let source = try text("Malinois/Services/CloudExfiltrator.swift")
        XCTAssertEqual(source.components(separatedBy: "enrollment.authorizeUpload(").count - 1, 1,
                       "ownership is checked in one place, beside the switch")
        XCTAssertTrue(source.contains("enrollment.authorizeUpload(event: event, lease: lease) && backupPermits(event)"))
        let saveCalls = source.components(separatedBy: "try await save(").dropFirst()
        XCTAssertFalse(saveCalls.isEmpty)
        for call in saveCalls {
            XCTAssertTrue(call.prefix { $0 != "\n" }.contains("permitted:"), "a save that does not re-read the switch: \(call.prefix(60))")
        }
        let beat = try XCTUnwrap(slice(source, from: "func pushBeat(", to: "func latestBeat("))
        XCTAssertTrue(beat.contains("backupOn()"), "a heartbeat reads the switch before it is sent")
    }

    // MARK: - R3: kept events are held in a way older versions keep too

    /// Everything recorded while backup is off is registered to no account, so even 1.6 or 1.5.1
    /// installed over this build (which drop the mark) holds it for good; the off entry itself and
    /// what was recorded before still upload.
    func testEventsRecordedWhileBackupIsOffAreRegisteredToNoAccount() async throws {
        let rig = await makeCloudRig()
        let before = rig.engine.logStateChange("thermalSerious")
        XCTAssertTrue(rig.engine.setCloudBackup(false))
        let offEntry = try XCTUnwrap(rig.store.events.first { $0.stateChange == Event.backupOffKind })
        await arm(rig)
        rig.engine.handleTrip(.motion)
        let responded = await waitUntil(timeout: 5) { self.incidents(rig).first?.cloudSyncState == .localOnly }
        XCTAssertTrue(responded)
        rig.engine.disarm()

        let lease = try XCTUnwrap(rig.gate.authorize(account: "account-a"))
        XCTAssertTrue(rig.gate.authorizeUpload(event: before, lease: lease), "recorded before off: uploads")
        XCTAssertTrue(rig.gate.authorizeUpload(event: offEntry, lease: lease), "the off entry still uploads")
        let whileOff = rig.store.events.filter { $0.id != before.id && $0.id != offEntry.id }
        XCTAssertTrue(whileOff.contains { !$0.isStateChange }, "the incident")
        XCTAssertTrue(whileOff.contains { $0.stateChange == "armed" }, "the arm entry")
        for event in whileOff {
            let what = event.stateChange ?? "incident"
            XCTAssertFalse(rig.gate.authorizeUpload(event: event, lease: lease), "\(what): held by the account register too")
            let older = try decodedWithoutTheMark(event)   // what 1.6 and 1.5.1 keep of it
            XCTAssertNil(older.keptLocal)
            XCTAssertEqual(rig.gate.uploadHoldReason(for: older), .unknownAccount, "\(what): an older version holds it for good")
            XCTAssertFalse(rig.gate.authorizeUpload(event: older, lease: lease))
        }
    }

    // MARK: - R4: backup on during a running sweep

    /// A sweep running while backup is off chose only the off entry. Backup turned on meanwhile:
    /// once that sweep ends, the backlog recorded before off is offered without another trigger.
    func testTurningBackupOnDuringASweepStillUploadsTheBacklog() async throws {
        let rig = makeRig(timing: Self.sweepTiming)
        try? await Task.sleep(nanoseconds: 200_000_000)   // the launch sweep finds no iCloud and ends
        let backlog = incident()
        rig.store.add(backlog)                              // recorded while backup was on
        XCTAssertTrue(rig.engine.setCloudBackup(false))
        let offEntry = try XCTUnwrap(rig.store.events.first { $0.stateChange == Event.backupOffKind })
        var release = false
        var offered: [UUID] = []
        rig.engine.sweepUploadForTesting = { event in
            offered.append(event.id)
            while !release { try? await Task.sleep(nanoseconds: 10_000_000) }
            return (.synced, nil)
        }
        defer { rig.engine.sweepUploadForTesting = nil }
        let sweep = Task { await rig.engine.retryPendingSync() }   // a foreground while off
        await waitUntil(timeout: 2) { offered.contains(offEntry.id) }
        XCTAssertFalse(offered.contains(backlog.id), "while off, only the off entry")
        XCTAssertTrue(rig.engine.setCloudBackup(true))
        release = true
        await sweep.value
        let uploaded = await waitUntil(timeout: 4) { offered.contains(backlog.id) }
        XCTAssertTrue(uploaded, "the backlog goes up once the running sweep ends")
    }

    // MARK: - The engine refuses the switch while armed

    /// Only the screen used to stop it; now the engine does too, and says so.
    func testTheEngineRefusesTheSwitchWhileArmed() async {
        let rig = makeRig()
        await arm(rig)
        XCTAssertFalse(rig.engine.setCloudBackup(false), "refused while armed")
        XCTAssertTrue(rig.engine.settings.cloudBackup)
        XCTAssertFalse(rig.store.events.contains { $0.stateChange == Event.backupOffKind }, "and nothing logged")
        rig.engine.disarm()
        XCTAssertTrue(rig.engine.setCloudBackup(false), "allowed once disarmed")
        XCTAssertFalse(rig.engine.settings.cloudBackup)
    }

    // MARK: - R8: the paired watch's direct alerts

    /// The owner's ruling: the paired watch keeps getting this iPhone's alerts directly while
    /// backup is off, and the switch's text says so instead of "no alerts".
    func testTheSwitchSaysThePairedWatchStillGetsAlerts() throws {
        // As Settings shows it (laid out; it read the screen's source before: the test-suite audit's P4).
        let shown = try settingsShownOnScreen()
        let caption = try XCTUnwrap(shown.first { $0.hasPrefix("Uploads this iPhone's events") }, "\(shown)")
        XCTAssertTrue(caption.contains("paired Apple Watch"), caption)
        XCTAssertFalse(caption.contains("your other devices get no alerts from this iPhone."), caption)
    }

    // MARK: - R5: a status entry being uploaded is protected too

    /// Through the real status upload, held mid-save: the entry counts as uploading, the log limit
    /// leaves it alone, and the limit applies again once the upload ends.
    func testAStatusEntryBeingUploadedIsKeptByTheLogLimit() async throws {
        let rig = await makeCloudRig()
        let day = Date().addingTimeInterval(-86_400)
        let oldest = Event(startDate: day, endDate: day, triggeredSensors: [], cloudSyncState: .pending,
                           stateChange: "thermalSerious")
        rig.gate.registerLocalEvent(oldest)
        rig.store.add(oldest)
        let record = "state-v2-" + oldest.id.uuidString
        let holding = TestFlag(true)
        let entered = TestFlag()
        rig.cloud.saveAttemptForTesting = { records in
            guard records.contains(where: { $0.recordID.recordName == record }) else { return }
            entered.value = true
            while holding.value { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        defer { rig.cloud.saveAttemptForTesting = nil }
        let upload = Task { await rig.engine.uploadSnapshotForTesting(oldest, throughSweep: false) }
        await waitUntil(timeout: 3) { entered.value }
        XCTAssertTrue(rig.store.isUploading(oldest.id), "protected while its record uploads")
        let now = Date()
        for i in 0..<EventStore.maxAuditEvents {
            let at = now.addingTimeInterval(Double(i - 3_000))
            rig.store.add(Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending,
                                stateChange: "thermalSerious"))
        }
        XCTAssertTrue(rig.store.events.contains { $0.id == oldest.id }, "the log limit leaves it alone while it uploads")
        holding.value = false
        await upload.value
        XCTAssertFalse(rig.store.isUploading(oldest.id))
        let trimmed = await waitUntil(timeout: 2) { !rig.store.events.contains { $0.id == oldest.id } }
        XCTAssertTrue(trimmed, "the limit applies once the upload has ended")
    }

    // MARK: - R6: removals at launch still leave the marker

    /// The app ended while an upload held a full log one over its limit. At the next launch the
    /// store trims it while loading, before anything listens and before the Pro check answers;
    /// the removal is kept and reported once both are ready.
    func testRemovalsWhileTheLogLoadsStillLeaveTheMarker() async throws {
        let gate = CloudEnrollment(file: Self.enrollmentFile(), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let before = EventStore()
        let twoDays = Date().addingTimeInterval(-172_800)
        let oldest = Event(startDate: twoDays, endDate: twoDays, triggeredSensors: [.motion], cloudSyncState: .pending)
        gate.registerLocalEvent(oldest)
        before.beginUpload(oldest.id)
        before.add(oldest)
        let day = Date().addingTimeInterval(-86_400)
        before.merge((0..<EventStore.maxIncidentEvents).map { i in   // pending: synced ones would go first
            Event(startDate: day.addingTimeInterval(Double(i)), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        })
        XCTAssertEqual(before.events.count, EventStore.maxIncidentEvents + 1, "held one over by the upload")
        before.drainIOForTesting()

        let relaunched = EventStore()   // the same folder: the log as the ended app left it
        XCTAssertFalse(relaunched.events.contains { $0.id == oldest.id }, "trimmed while loading")
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: relaunched,
                                                          cloud: CloudExfiltrator(enrollment: gate),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        let marked = await waitUntil(timeout: 3) { relaunched.events.contains { $0.stateChange == "unsyncedRemoved" } }
        XCTAssertTrue(marked, "the removal at launch leaves the marker")
        _ = engine
    }

    // MARK: - R7: the media clean-up looks again

    /// Media over its budget only because of an upload: the clean-up measures, the upload ends
    /// meanwhile, and the clean-up must look again rather than wait for an upload that is over.
    func testTheMediaCleanupLooksAgainWhenTheUploadItWaitedForEnds() async throws {
        let store = EventStore()
        store.mediaBudgetForTesting = 10
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
        event.mediaFilename = "r7.jpg"
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent("r7.jpg"))
        let holding = TestFlag(true)
        let entered = TestFlag()
        store.mediaMeasuredForTesting = {
            entered.value = true
            while holding.value { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        defer { store.mediaMeasuredForTesting = nil }
        store.beginUpload(event.id)
        store.add(event)                                    // starts a clean-up pass
        await waitUntil(timeout: 2) { entered.value }
        store.endUpload(event.id)                           // the upload ends while the files are measured
        holding.value = false
        let cleaned = await waitUntil(timeout: 3) { store.events.first { $0.id == event.id }?.mediaFilename == nil }
        XCTAssertTrue(cleaned, "the clean-up looked again once the upload had ended")
    }

    // MARK: - R9: the marker's daily limit

    /// Disarmed, at most one marker a day, even across a relaunch.
    func testTheDailyMarkerLimitSurvivesARelaunch() async {
        let gate = CloudEnrollment(file: Self.enrollmentFile(), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let first = makeRig(gate: gate)
        let one = incident(), two = incident()
        gate.registerLocalEvent(one)
        gate.registerLocalEvent(two)
        first.engine.noteCountEviction([one])
        XCTAssertEqual(markers(first.store), 1)
        let relaunched = makeRig(gate: gate, store: first.store)   // a new engine: nothing kept in memory
        relaunched.engine.noteCountEviction([two])
        XCTAssertEqual(markers(first.store), 1, "one a day while disarmed, across a relaunch")
    }

    /// A last marker later than now means the clock was moved back: due, instead of waiting out
    /// the whole difference.
    func testAClockMovedBackMakesTheMarkerDue() {
        let now = Date()
        XCTAssertTrue(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now.addingTimeInterval(7_200), nil),
                                                                  armedSince: nil, now: now))
    }

    /// The marker's words: some of the removed events may have their record in iCloud already.
    func testTheMarkerSaysTheEventsWereNotFullyBackedUp() {
        let marker = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                           stateChange: "unsyncedRemoved")
        XCTAssertEqual(marker.sensorSummary, "Events not fully backed up to iCloud were removed to make room (log full)")
    }

    // MARK: - R10: damaged clock entries never crash

    /// A clock entry's number comes from the log or from iCloud, where it may be damaged: the
    /// extremes are refused without trapping, the century bound still holds, and neither this
    /// device's log nor another device's reading of the record crashes.
    func testDamagedClockEntriesNeverCrash() {
        let century = 100 * 365 * 86_400
        for value in [Int.min, Int.max, century + 1, -(century + 1)] {
            XCTAssertNil(Event.clockChangeSeconds(kind: "clockChanged.\(value)"), "\(value)")
        }
        XCTAssertEqual(Event.clockChangeSeconds(kind: "clockChanged.\(century)"), century)
        XCTAssertEqual(Event.clockChangeSeconds(kind: "clockChanged.\(-century)"), -century)
        let damaged = "clockChanged.\(Int.min)"
        let row = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                        stateChange: damaged)
        XCTAssertEqual(row.sensorSummary, "Status entry this version of Malinois does not recognize")
        let record = CloudExfiltrator.makeStateRecord(row, kind: damaged, deviceName: "iPhone Air")
        XCTAssertNil(CloudExfiltrator.stateEvent(from: record), "another device drops it")
    }

    // MARK: - Item 112's storage check: as many clips as cameras

    /// Both cameras ask for two clips' room and one camera for one; item 112's test used a fake
    /// that ignored the number, so a check for one clip before a Both capture would have passed.
    func testTheStorageCheckAsksForAsManyClipsAsCameras() async {
        let camera = FakeCamera()
        camera.clipStorageFull = true
        camera.supportsMultiCam = true
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: EngineCharacterizationTests.fastTiming)
        let host = FakeCaptureHost()
        pipeline.host = host
        _ = await pipeline.captureBoth(mode: .clip5, illumination: .off)
        _ = await pipeline.capture(from: .front, mode: .clip5, illumination: .off)
        XCTAssertEqual(camera.roomChecks, [2, 1])
    }

    // MARK: - N1: a sweep request is never lost

    /// Backup turned on while a sweep runs long: however long it runs (and whatever the clock
    /// does), the backlog is offered once it ends. The old helper gave up after a wall-clock wait
    /// and its request was turned away by the still-running sweep.
    func testABackupOnSweepRequestSurvivesASweepThatRunsLong() async throws {
        let rig = makeRig(timing: Self.sweepTiming)
        try? await Task.sleep(nanoseconds: 200_000_000)   // the launch sweep finds no iCloud and ends
        let backlog = incident()
        rig.store.add(backlog)
        XCTAssertTrue(rig.engine.setCloudBackup(false))
        let offEntry = try XCTUnwrap(rig.store.events.first { $0.stateChange == Event.backupOffKind })
        var release = false
        var offered: [UUID] = []
        rig.engine.sweepUploadForTesting = { event in
            offered.append(event.id)
            while !release { try? await Task.sleep(nanoseconds: 10_000_000) }
            return (.synced, nil)
        }
        defer { rig.engine.sweepUploadForTesting = nil }
        let sweep = Task { await rig.engine.retryPendingSync() }
        await waitUntil(timeout: 2) { offered.contains(offEntry.id) }
        XCTAssertTrue(rig.engine.setCloudBackup(true))
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // the running pass outlasts any wait
        release = true
        await sweep.value
        let uploaded = await waitUntil(timeout: 4) { offered.contains(backlog.id) }
        XCTAssertTrue(uploaded, "the request waited for the sweep, however long it ran")
    }

    // MARK: - N2: a removal counts for the watch it happened in

    /// A removal while disarmed leaves the day's marker. In a later watch the log removes evidence
    /// again, and the watch is disarmed before the removal's report runs: the watch's first loss
    /// still leaves its own marker.
    func testAWatchsFirstLossIsNotHiddenByADisarmBeforeItIsReported() async {
        let gate = CloudEnrollment(file: Self.enrollmentFile(), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let rig = makeRig(gate: gate)
        let listening = await waitUntil(timeout: 3) { rig.store.onCountEviction != nil }
        XCTAssertTrue(listening, "the engine listens once the Pro check has answered")
        let day = Date().addingTimeInterval(-86_400)
        let backlog = (0..<EventStore.maxIncidentEvents).map { i in
            Event(startDate: day.addingTimeInterval(Double(i)), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        }
        backlog.forEach(gate.registerLocalEvent)
        rig.store.merge(backlog)                            // a full log of evidence meant for iCloud

        let first = incident()
        gate.registerLocalEvent(first)
        rig.store.add(first)                                // disarmed: the oldest goes, the day's marker
        let daily = await waitUntil(timeout: 2) { self.markers(rig.store) == 1 }
        XCTAssertTrue(daily)

        await arm(rig)
        let second = incident()
        gate.registerLocalEvent(second)
        rig.store.add(second)                               // in the watch: the next oldest goes
        rig.engine.disarm()                                 // before the removal's report has run
        let own = await waitUntil(timeout: 2) { self.markers(rig.store) == 2 }
        XCTAssertTrue(own, "the watch's first loss leaves its own marker")
    }

    // MARK: - P1: the launch buffer keeps part of a large batch

    /// One trim of 601 unsynced incidents before anyone listens: all 601 are kept for the marker,
    /// none dropped (P1; batch F keeps every removal the marker could count).
    func testAnOversizedRemovalBatchIsKeptNotDropped() async {
        let store = EventStore()
        let day = Date().addingTimeInterval(-86_400)
        store.merge((0..<(EventStore.maxIncidentEvents + 601)).map { i in
            Event(startDate: day.addingTimeInterval(Double(i)), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        })
        XCTAssertEqual(store.events.count, EventStore.maxIncidentEvents, "601 removed in one batch")
        var delivered: [Int] = []
        store.onCountEviction = { removed, _ in delivered.append(removed.count) }
        let heard = await waitUntil(timeout: 2) { !delivered.isEmpty }
        XCTAssertTrue(heard, "a large batch is kept, not dropped whole")
        XCTAssertEqual(delivered, [601])
    }

    /// Two trims before anyone listens, 400 unsynced incidents in one watch and 300 in another: all
    /// are kept, each with its watch.
    func testTheBufferKeepsEveryCandidateWithItsWatch() async {
        let store = EventStore()
        let watchA = Date(timeIntervalSince1970: 1_000)
        let watchB = Date(timeIntervalSince1970: 2_000)
        let day = Date().addingTimeInterval(-86_400)
        func incidents(_ count: Int, from start: Int) -> [Event] {
            (start..<(start + count)).map { i in
                Event(startDate: day.addingTimeInterval(Double(i)), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
            }
        }
        store.evictionWatch = { watchA }
        store.merge(incidents(EventStore.maxIncidentEvents + 400, from: 0))   // 400 removed in watch A
        store.evictionWatch = { watchB }
        store.merge(incidents(300, from: 10_000))                             // 300 more, newer, in watch B
        var delivered: [(count: Int, watch: Date?)] = []
        store.onCountEviction = { removed, watch in delivered.append((removed.count, watch)) }
        await waitUntil(timeout: 2) { delivered.count == 2 }
        XCTAssertEqual(delivered.map(\.count), [400, 300], "every removal the marker could count is kept")
        XCTAssertEqual(delivered.map(\.watch), [watchA, watchB] as [Date?], "each kept removal keeps its watch")
    }

    // MARK: - Q1: a trim of one incident among many status entries

    /// One trim before anyone listens removes the oldest unsynced incident and 600 newer status
    /// entries: all are kept for the marker, the incident without its thumbnail. Before 1.8.2 the
    /// status entries were not, the marker never counting them (item 169's codex-1).
    func testAMixedTrimKeepsItsRemovalsForTheMarker() async {
        let store = EventStore()
        let day = Date().addingTimeInterval(-86_400)
        var oldest = Event(startDate: day.addingTimeInterval(-60), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        oldest.thumbnailData = Data(count: 2_000)
        let incidents = [oldest] + (0..<EventStore.maxIncidentEvents).map { i in
            Event(startDate: day.addingTimeInterval(Double(i)), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        }
        let statuses = (0..<700).map { i in
            Event(startDate: day.addingTimeInterval(Double(10_000 + i)), endDate: day, triggeredSensors: [],
                  cloudSyncState: .pending, stateChange: "thermalSerious")
        }
        store.merge(incidents + statuses)
        XCTAssertFalse(store.events.contains { $0.id == oldest.id }, "the incident was trimmed")
        var delivered: [Event] = []
        store.onCountEviction = { removed, _ in delivered.append(contentsOf: removed) }
        await waitUntil(timeout: 2) { !delivered.isEmpty }
        let statusIDs = Set(statuses.map(\.id))
        XCTAssertTrue(delivered.contains { $0.id == oldest.id }, "the incident")
        XCTAssertEqual(delivered.filter { statusIDs.contains($0.id) }.count, 600, "and the status entries removed")
        XCTAssertEqual(delivered.count, 601)
        XCTAssertNil(delivered.first { $0.id == oldest.id }?.thumbnailData, "kept without its evidence")
    }

    /// Codex's case through the engine: the log left on disk holds 501 unsynced incidents and 700
    /// newer status entries; the relaunched store trims one incident and 600 entries while it loads,
    /// and the incident's loss still leaves the marker once the Pro check answers.
    func testAMixedLaunchTrimStillLeavesTheMarker() async throws {
        let gate = CloudEnrollment(file: Self.enrollmentFile(), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let day = Date().addingTimeInterval(-86_400)
        let oldest = Event(startDate: day.addingTimeInterval(-60), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        gate.registerLocalEvent(oldest)
        let incidents = (0..<EventStore.maxIncidentEvents).map { i in
            Event(startDate: day.addingTimeInterval(Double(i)), endDate: day, triggeredSensors: [.motion], cloudSyncState: .pending)
        }
        let statuses = (0..<700).map { i in
            Event(startDate: day.addingTimeInterval(Double(10_000 + i)), endDate: day, triggeredSensors: [],
                  cloudSyncState: .pending, stateChange: "thermalSerious")
        }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = (statuses + incidents + [oldest]).sorted { $0.startDate > $1.startDate }
        try JSONEncoder().encode(log).write(to: root.appendingPathComponent("events.json"))

        let relaunched = EventStore()
        XCTAssertFalse(relaunched.events.contains { $0.id == oldest.id }, "trimmed while loading")
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: relaunched,
                                                          cloud: CloudExfiltrator(enrollment: gate),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        let marked = await waitUntil(timeout: 3) { relaunched.events.contains { $0.stateChange == "unsyncedRemoved" } }
        XCTAssertTrue(marked, "the incident's loss leaves the marker")
        _ = engine
    }

    /// The rule the store keeps removals by: only a first-hand record not fully backed up and not
    /// kept on this device by choice could be a missed upload; since 1.8.2 status entries and
    /// interruptions as well as incidents (item 169's codex-1).
    func testOnlyAnUnsyncedFirstHandRecordCouldBeAMissedUpload() {
        func event(_ change: (inout Event) -> Void) -> Event {
            var e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
            change(&e)
            return e
        }
        XCTAssertTrue(event { _ in }.mayBeAMissedUpload)
        XCTAssertTrue(event { $0.cloudSyncState = .localOnly }.mayBeAMissedUpload)
        XCTAssertFalse(event { $0.cloudSyncState = .synced }.mayBeAMissedUpload, "synced")
        XCTAssertFalse(event { $0.sourceDevice = "iPhone Air" }.mayBeAMissedUpload, "another device's copy")
        XCTAssertFalse(event { $0.sustainedCount = 3 }.mayBeAMissedUpload, "a flood record")
        XCTAssertTrue(event { $0.interrupted = true }.mayBeAMissedUpload, "an interruption record")
        XCTAssertFalse(event { $0.keptLocal = true }.mayBeAMissedUpload, "kept on this device by choice")
        XCTAssertTrue(Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                            stateChange: "armed").mayBeAMissedUpload, "a status entry")
    }

    // MARK: - N1's owed sweep: one more pass, never a loop

    /// Twenty requests during one sweep owe one more pass. A record the upload refuses stays
    /// pending, so a loop would show as more passes.
    func testRequestsDuringOneSweepAddOnePassNotALoop() async {
        let rig = makeRig(timing: Self.sweepTiming)
        try? await Task.sleep(nanoseconds: 200_000_000)   // the launch sweep finds no iCloud and ends
        let refused = incident()
        rig.store.add(refused)
        var release = false
        var offers = 0
        rig.engine.sweepUploadForTesting = { event in
            if event.id == refused.id { offers += 1 }
            while !release { try? await Task.sleep(nanoseconds: 10_000_000) }
            return (.localOnly, nil)                       // refused: still pending, no transient failure
        }
        defer { rig.engine.sweepUploadForTesting = nil }
        let sweep = Task { await rig.engine.retryPendingSync() }
        await waitUntil(timeout: 2) { offers == 1 }
        for _ in 0..<20 { rig.engine.captureEvidenceStoredLate() }
        release = true
        await sweep.value
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // room for any further pass
        XCTAssertEqual(offers, 2, "one more pass for twenty requests, and no loop")
    }

    // MARK: - Helpers

    private static let sweepTiming: EngineTiming = {
        var t = EngineCharacterizationTests.fastTiming
        t.sweepWaitFloor = 0.05
        t.sweepWaitCeiling = 0.2
        return t
    }()

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let cloud: CloudExfiltrator
        let gate: CloudEnrollment
    }

    private func makeRig(timing: EngineTiming = EngineCharacterizationTests.fastTiming,
                         gate: CloudEnrollment? = nil, store existing: EventStore? = nil) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = existing ?? EventStore()
        let enrollment = gate ?? CloudEnrollment(file: Self.enrollmentFile(), authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: enrollment)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing, thermalState: { .nominal }))
        engine.simulateConnectivityForTesting(online: true)
        return Rig(engine: engine, store: store, cloud: cloud, gate: enrollment)
    }

    /// An installation verified for "account-a", whose uploads reach `saveAttemptForTesting`
    /// through every real step: the lease, ownership, the per-event queue and each record.
    private func makeCloudRig() async -> Rig {
        let gate = CloudEnrollment(file: Self.enrollmentFile(), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let rig = makeRig(gate: gate)
        try? await Task.sleep(nanoseconds: 200_000_000)   // the launch sweep finds no identity and ends
        rig.cloud.accountIdentityForTesting = { "account-a" }
        return rig
    }

    private static func enrollmentFile() -> URL {
        (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
    }

    /// An incident recorded while backup is on, registered to the account, with a file from each camera.
    private func mediaEvent(in rig: Rig) throws -> Event {
        var event = incident()
        event.mediaFilename = "r2-front.jpg"
        event.primaryCamera = "front"
        event.secondaryMediaFilename = "r2-rear.jpg"
        event.secondaryCamera = "rear"
        try FileManager.default.createDirectory(at: rig.store.mediaDirectory, withIntermediateDirectories: true)
        for name in ["r2-front.jpg", "r2-rear.jpg"] {
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: rig.store.mediaDirectory.appendingPathComponent(name))
        }
        rig.gate.registerLocalEvent(event)
        rig.store.add(event)
        return event
    }

    /// Async tests wait by suspending: a run-loop wait inside one lets no main-actor work run.
    private func arm(_ rig: Rig) async {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        let armed = await waitUntil(timeout: 5) { rig.engine.state == .armed }
        XCTAssertTrue(armed, "armed")
    }

    private func incidents(_ rig: Rig) -> [Event] {
        rig.store.events.filter { !$0.isStateChange && !$0.isMirrored }
    }

    private func incident() -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
    }

    private func markers(_ store: EventStore) -> Int {
        store.events.filter { $0.stateChange == "unsyncedRemoved" }.count
    }

    /// The event as 1.6 and 1.5.1 keep it: their model has no `keptLocal`, so it is dropped.
    private func decodedWithoutTheMark(_ event: Event) throws -> Event {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        fields.removeValue(forKey: "keptLocal")
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from begin: String, to end: String) -> Substring? {
        guard let start = source.range(of: begin) else { return nil }
        let rest = source[start.upperBound...]
        let stop = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return rest[..<stop]
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }
}
