//
//  Item166ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 166, Codex's open review of 1.8.2 at 144e723 (item 163's steps 40, 41 and 43). A2: another device kept its
//  copy from before the capturing phone discarded an unsent photo: the merge let a copy of the same revision replace it
//  only for a grown count or a new failure reason, and without a thumbnail the discard lowered the record's revision, so
//  the copy that said so was refused as older on both phones. A1: the count limit's report of an unsent incident it
//  removed was owed only in memory, for a later turn of the main actor, while the file queue wrote the smaller log and
//  deleted the photo; a kill in between left neither the incident nor its report. B2: Settings' alerts caption said
//  turning alerts off removes them for all devices, when each iPhone keeps sending its own alerts to its own watch.
//  Codex's look at those fixes: codex-22, the reports owed could be written over by the journal's recovery or outrun by
//  the log; codex-23, a capture part of which reached iCloud was marked lost, hiding its download; codex-25, the
//  capturing phone did not offer the download of a file it knew had landed; codex-26, an unlock handed a report owed to
//  the engine before the recovery could bring its incident back; codex-24, an older event's missing record of what
//  reached iCloud was read as none. Each written before its change, red at that commit. And BACKLOG 176's codex-2 (step
//  67): an answer asked for before iCloud's copies were lost no longer settles the check after it.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item166ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem166Review")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// Polls until `condition` holds, for at most `seconds` (three by default).
    private func eventually(within seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // MARK: - A2 (codex-2): another device learns a photo was discarded

    /// Whether the store's byte-limit pass has finished, waiting at most four seconds.
    private func settled(_ store: EventStore) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !store.byteCapPruneIdleForTesting, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return store.byteCapPruneIdleForTesting
    }

    /// An unsent capture whose full photo the byte limit discards, as the capturing phone records it (`thumbnail`: whether
    /// the capture has one). Returns the copy another phone fetched before the discard, and the one a retry then uploads.
    private func copiesAcrossADiscard(thumbnail: Bool) async throws -> (before: Event, after: Event) {
        let store = EventStore()
        defer { store.drainIOForTesting() }
        store.mediaBudgetForTesting = 1_000
        let at = Date().addingTimeInterval(-60)
        var source = Event(startDate: at, endDate: at.addingTimeInterval(1), triggeredSensors: [.motion],
                           cloudSyncState: .pending)
        source.mediaFilename = UUID().uuidString + ".jpg"
        source.primaryCamera = "front"
        if thumbnail { source.thumbnailData = Data([0xff, 0xd8, 0xff]) }
        let file = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(source.mediaFilename))
        try Data(count: 100).write(to: file)
        store.add(source)
        let firstPass = await settled(store)
        XCTAssertTrue(firstPass)
        // The metadata went up, with its thumbnail as the uploader sends it, the full photo's upload failed, and the
        // other phone fetched this copy.
        let thumbnailFile: URL? = try source.thumbnailData.map { data in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try data.write(to: url)
            return url
        }
        defer { thumbnailFile.map { try? FileManager.default.removeItem(at: $0) } }
        let before = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(source, deviceName: "Desk phone", thumbnailURL: thumbnailFile)))
        // Later the unsent media outgrow the byte limit, and the limit discards this photo.
        store.mediaBudgetForTesting = 10
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch]))
        let secondPass = await settled(store)
        XCTAssertTrue(secondPass)
        store.drainIOForTesting()
        store.resolveDiscardCheck(source.id, landed: [], epoch: nil)   // iCloud, asked at the sweep, holds none of it (codex-24)
        let discarded = try XCTUnwrap(store.events.first { $0.id == source.id })
        XCTAssertEqual(discarded.mediaDiscarded, true, "the capturing phone records the loss")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the photo is gone")
        let after = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(discarded, deviceName: "Desk phone", thumbnailURL: thumbnailFile)))
        XCTAssertEqual(after.mediaDiscarded, true, "the copy a retry uploads says so")
        return (before, after)
    }

    /// codex-2 on 144e723: the capturing phone discarded an unsent photo after another phone had fetched the event, and
    /// the retry's copy says so at the same revision (the thumbnail stays). The other phone kept its earlier copy: it
    /// never showed the loss, and kept offering a download of a photo that never reached iCloud.
    func testAnotherDeviceLearnsAPhotoWasDiscardedBeforeItUploaded() async throws {
        let (before, after) = try await copiesAcrossADiscard(thumbnail: true)
        XCTAssertEqual(after.cloudRevision, before.cloudRevision, "the same revision: the thumbnail stays")
        let merged = try XCTUnwrap(EventStore.merged(local: [before], incoming: [after]).first)
        XCTAssertEqual(merged.mediaDiscarded, true, "the other phone learns the loss")
        XCTAssertNotNil(before.thumbnailData, "the copy it held has the thumbnail")
        XCTAssertEqual(merged.thumbnailData, before.thumbnailData, "and keeps what its copy had")
    }

    /// codex-2: without a thumbnail, the discard lowered the record's revision, so the capturing phone refused to send
    /// the copy that says so (an older revision than it had sent), and the other phone would have refused it as older.
    func testWithoutAThumbnailTheLossStillReachesTheOtherDevice() async throws {
        let (before, after) = try await copiesAcrossADiscard(thumbnail: false)
        XCTAssertTrue(CloudExfiltrator.mayWrite(revision: after.cloudRevision ?? 0, alreadySubmitted: before.cloudRevision),
                      "the capturing phone sends it: revision \(String(describing: after.cloudRevision)) after "
                        + "\(String(describing: before.cloudRevision))")
        let merged = try XCTUnwrap(EventStore.merged(local: [before], incoming: [after]).first)
        XCTAssertEqual(merged.mediaDiscarded, true, "the other phone learns the loss")
    }

    /// codex-2: a copy that replaces the other phone's (a later revision) but does not say the photo was discarded never
    /// takes the loss back: it is the capturing phone's for good.
    func testACopyThatDoesNotSaySoNeverTakesTheLossBack() async throws {
        let (before, after) = try await copiesAcrossADiscard(thumbnail: true)
        let known = try XCTUnwrap(EventStore.merged(local: [before], incoming: [after]).first)
        var later = before
        later.cloudRevision = (after.cloudRevision ?? 0) + 1
        later.ownerAttributed = true
        let merged = try XCTUnwrap(EventStore.merged(local: [known], incoming: [later]).first)
        XCTAssertEqual(merged.ownerAttributed, true, "the later copy replaced it")
        XCTAssertEqual(merged.mediaDiscarded, true, "and the loss stayed")
    }

    // MARK: - A1 (codex-1): the count limit's report survives a kill

    /// An engine over `store` whose Pro check has answered `pro`, with `enrollment`'s grant; evidence pushes stay
    /// pending (no CloudKit in the Simulator).
    private func engine(over store: EventStore, enrollment: CloudEnrollment, pro: ProEntitlements) -> MonitoringEngine {
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment),
                                                          camera: FakeCamera(), entitlements: pro,
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.evidencePushForTesting = { _ in .init(syncState: .pending, metaFailureWasInterference: nil) }
        return engine
    }

    /// An installation verified for "account-a", and the log at the incident limit on disk, every incident unsent: the
    /// oldest holds the only copy of its photo, and the journal lines of their births were retired long ago.
    private func logAtTheIncidentLimit() async throws -> (enrollment: CloudEnrollment, oldest: Event, photo: URL) {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let now = Date()
        var held = (0..<EventStore.maxIncidentEvents).map { index in
            let at = now.addingTimeInterval(-Double(index + 1))
            return Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .pending)
        }
        held[held.count - 1].mediaFilename = UUID().uuidString + ".jpg"
        held[held.count - 1].primaryCamera = "front"
        let oldest = held[held.count - 1]
        enrollment.registerLocalEvent(oldest)
        let photo = media.appendingPathComponent(try XCTUnwrap(oldest.mediaFilename))
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: photo)
        try JSONEncoder().encode(held).write(to: root.appendingPathComponent("events.json"))
        return (enrollment, oldest, photo)
    }

    /// codex-1 on 144e723: at the incident limit the oldest unsent incident goes to make room, and its report (the log's
    /// "not fully backed up" record, item 114) was owed only in memory, for a later turn of the main actor, while the
    /// file queue wrote the smaller log and deleted the photo. A kill in between left neither the incident nor its
    /// report. The report owed is now on disk before the smaller log: the next launch owes it, and once its engine
    /// listens, the log keeps the record, once.
    func testTheCountLimitsReportSurvivesAKillBeforeItRuns() async throws {
        let fm = FileManager.default
        let (enrollment, oldest, photo) = try await logAtTheIncidentLimit()
        let now = Date()

        // A launch whose engine hears the limit's removals; an incident is recorded.
        let first = EventStore()
        let firstPro = ProEntitlements(resolvedAs: .trial)
        engine(over: first, enrollment: enrollment, pro: firstPro).watchCountEvictions()
        let incident = Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending)
        enrollment.registerLocalEvent(incident)
        first.add(incident)
        // The cut: the file queue writes the smaller log and deletes the photo before the main actor turns again.
        first.drainIOForTesting()
        XCTAssertFalse(fm.fileExists(atPath: photo.path), "the photo is gone")
        firstPro.resolveForTesting(as: .free)   // the app is killed here: that launch's engine reports nothing more

        // The next launch reads the files.
        let next = EventStore()
        next.drainIOForTesting()
        XCTAssertFalse(next.events.contains { $0.id == oldest.id }, "the incident is gone")
        XCTAssertTrue(next.removalsAwaitingReport.contains(oldest.id), "its report is still owed")
        engine(over: next, enrollment: enrollment, pro: ProEntitlements(resolvedAs: .trial)).watchCountEvictions()
        let reported = await eventually { next.events.contains { $0.stateChange == "unsyncedRemoved" } }
        XCTAssertTrue(reported, "the log keeps the record that an unsent incident was removed")
        XCTAssertEqual(next.events.filter { $0.stateChange == "unsyncedRemoved" }.count, 1, "once")
        XCTAssertTrue(next.removalsAwaitingReport.isEmpty, "and owes nothing more")
    }

    /// A removal made before the engine listens (as the launch trims are, until the Pro check answers) is owed on disk
    /// too: the next launch reports it once, and the launch after that owes nothing, a report that has run being retired.
    /// No earlier launch is left running here to retire it in its place.
    func testAReportOwedBeforeTheEngineListensIsMadeOnceAndThenRetired() async throws {
        let (enrollment, oldest, _) = try await logAtTheIncidentLimit()
        do {
            let first = EventStore()   // the Pro check has not answered: no engine listens
            let now = Date()
            first.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))
            first.drainIOForTesting()
            XCTAssertTrue(first.removalsAwaitingReport.contains(oldest.id), "kept for the report")
        }   // the app ends before it answers
        let next = EventStore()
        XCTAssertTrue(next.removalsAwaitingReport.contains(oldest.id), "the report is owed at the next launch")
        engine(over: next, enrollment: enrollment, pro: ProEntitlements(resolvedAs: .trial)).watchCountEvictions()
        let reported = await eventually {
            next.events.contains { $0.stateChange == "unsyncedRemoved" } && next.removalsAwaitingReport.isEmpty
        }
        XCTAssertTrue(reported, "the log keeps the record, and the report is retired")
        next.drainIOForTesting()
        XCTAssertTrue(EventStore().removalsAwaitingReport.isEmpty, "a report that has run is not owed again")
    }

    // MARK: - codex-23 on ae720ca: a capture is marked lost only when none of it reached iCloud

    /// An engine whose uploads reach the save seam through every real step (the lease, the binding, the per-event queue,
    /// each record), and its store, with a two-camera capture on disk, registered and logged.
    private func twoCameraCaptureReadyToUpload() async throws -> (engine: MonitoringEngine, cloud: CloudExfiltrator,
                                                                  store: EventStore, capture: Event) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let store = EventStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let cloud = CloudExfiltrator(enrollment: enrollment)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.simulateConnectivityForTesting(online: true)
        try? await Task.sleep(for: .milliseconds(200))   // the launch sweep finds no identity and ends
        cloud.accountIdentityForTesting = { "account-a" }
        var capture = Event(startDate: Date().addingTimeInterval(-60), endDate: Date().addingTimeInterval(-59),
                            triggeredSensors: [.motion], cloudSyncState: .pending)
        capture.mediaFilename = UUID().uuidString + ".jpg"
        capture.primaryCamera = "front"
        capture.secondaryMediaFilename = UUID().uuidString + ".jpg"
        capture.secondaryCamera = "rear"
        capture.thumbnailData = Data([0xff, 0xd8, 0xff])
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        for name in [capture.mediaFilename, capture.secondaryMediaFilename].compactMap({ $0 }) {
            try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(name))
        }
        enrollment.registerLocalEvent(capture)
        store.add(capture)
        return (engine, cloud, store, capture)
    }

    /// The byte limit run with a budget the capture's two files exceed: the next record's add starts its pass.
    private func runTheByteLimit(on store: EventStore) async throws {
        store.mediaBudgetForTesting = 10
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch]))
        let pass = await settled(store)
        XCTAssertTrue(pass)
        store.drainIOForTesting()
    }

    /// codex-23 on ae720ca: a two-camera capture uploaded its record and its front photo, and its rear photo's upload
    /// failed, so it stayed pending; the byte limit then discarded both files and marked the whole capture lost before
    /// upload. Since step 40 the other device learns that mark, and it hid "Download full evidence" for a front photo that
    /// is in iCloud; the capturing phone always did. The event now records which camera files reached iCloud, and the
    /// limit marks a capture lost only when none did (the owner's option (a)).
    func testATwoCameraCaptureWhoseFrontPhotoReachedICloudIsNotMarkedLost() async throws {
        let (engine, cloud, store, capture) = try await twoCameraCaptureReadyToUpload()
        cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordID.recordName.hasPrefix("photo-rear") }) { throw CKError(.limitExceeded) }
        }
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        let uploaded = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(uploaded.cloudSyncState, .pending, "the rear photo did not land")
        // The copy the other phone holds: the record as it went up, naming both cameras.
        let held = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(uploaded, deviceName: "Desk phone", thumbnailURL: nil)))

        try await runTheByteLimit(on: store)
        let trimmed = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNil(trimmed.mediaFilename, "the limit took the files")
        XCTAssertNotEqual(trimmed.mediaDiscarded, true, "the front photo is in iCloud: the capture is not lost")
        try await assertTheCapturingPhoneOffersItsDownload(trimmed, engine: engine, store: store)

        let fetched = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(trimmed, deviceName: "Desk phone", thumbnailURL: nil)))
        let merged = try XCTUnwrap(EventStore.merged(local: [held], incoming: [fetched]).first)
        XCTAssertNotEqual(merged.mediaDiscarded, true, "the other phone is not told it is lost")
        XCTAssertTrue(merged.fullCaptureMayBeInICloud, "and still offers its download")
    }

    /// The same when the photo's file landed and the record's save failed (a one-camera capture): the photo is in
    /// iCloud, so the capture is not marked lost.
    func testACaptureWhosePhotoLandedThoughItsRecordFailedIsNotMarkedLost() async throws {
        let (engine, cloud, store, capture) = try await twoCameraCaptureReadyToUpload()
        let meta = "meta-v2-" + capture.id.uuidString
        cloud.saveAttemptForTesting = { records in
            let names = records.map(\.recordID.recordName)
            if names.contains(meta) || names.contains(where: { $0.hasPrefix("photo-rear") }) { throw CKError(.limitExceeded) }
        }
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        try await runTheByteLimit(on: store)
        let trimmed = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(trimmed.mediaDiscarded, true, "the front photo is in iCloud: the capture is not lost")
        try await assertTheCapturingPhoneOffersItsDownload(trimmed, engine: engine, store: store)
    }

    /// codex-25 on 118f4b1: the capturing phone offered "Download full evidence" only for an event synced in full, so the
    /// front photo it had just recorded as in iCloud stayed out of reach until a later record upload succeeded. A file it
    /// knows landed now offers the download, and the download brings it back (the fetch's stand-in returns the front).
    private func assertTheCapturingPhoneOffersItsDownload(_ trimmed: Event, engine: MonitoringEngine,
                                                          store: EventStore) async throws {
        XCTAssertNotEqual(trimmed.cloudSyncState, .synced, "the upload has not ended in full")
        XCTAssertTrue(trimmed.fullCaptureMayBeInICloud, "the capturing phone offers the download of what landed")
        store.mediaBudgetForTesting = nil
        let front = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: front)
        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front)],
                                            complete: true)
        }
        defer { engine.fullMediaFetchForTesting = nil }
        let download = await engine.downloadFullEvidence(for: trimmed.id)
        XCTAssertTrue(download.landed, "the front photo comes back")
        store.drainIOForTesting()
    }

    /// The control: a capture none of whose files reached iCloud is still marked lost, as step 40 needs, once iCloud,
    /// asked at the sweep, holds none of them (codex-24).
    func testACaptureNoneOfWhichReachedICloudIsStillMarkedLost() async throws {
        let (engine, cloud, store, capture) = try await twoCameraCaptureReadyToUpload()
        cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordID.recordName.hasPrefix("photo-") }) { throw CKError(.limitExceeded) }
        }
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        try await runTheByteLimit(on: store)
        engine.cloudPresenceForTesting = { _ in [] }   // iCloud holds none of its files
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "nothing of it is in iCloud")
    }

    /// What reached iCloud is kept through a later write of the event from a copy taken before the upload: the store's
    /// updates keep what only grows.
    func testWhatReachedICloudSurvivesAStaleWrite() async throws {
        let (engine, cloud, store, capture) = try await twoCameraCaptureReadyToUpload()
        cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordID.recordName.hasPrefix("photo-rear") }) { throw CKError(.limitExceeded) }
        }
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        var stale = capture   // taken before the upload, written back after it (a field the byte limit does not read)
        stale.endDate = capture.endDate.addingTimeInterval(1)
        store.update(stale)
        try await runTheByteLimit(on: store)
        XCTAssertNotEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true,
                          "the front photo's landing outlived the stale write")
    }

    /// An upload that lands every file still ends synced: the files it notes as they land change the stored event while
    /// it runs, which must not count as a newer event its verdict would be stale for.
    func testAnUploadThatLandsEveryFileEndsSynced() async throws {
        let (engine, cloud, store, capture) = try await twoCameraCaptureReadyToUpload()
        cloud.saveAttemptForTesting = { _ in }
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.cloudSyncState, .synced)
    }

    // MARK: - codex-24 on 118f4b1: iCloud is asked before a capture is marked lost (the owner's option (b))

    /// The records a test's save stand-in was handed.
    @MainActor
    private final class SavedRecords {
        var records: [CKRecord] = []
    }

    /// The record names a test's presence stand-in was asked about, one list a question.
    @MainActor
    private final class PresenceQuestions {
        var asked: [[String]] = []
    }

    /// How many times a test's identity stand-in was asked.
    @MainActor
    private final class Lookups {
        var count = 0
    }

    /// A log saved before this version: `count` pending two-camera captures, a minute apart and the oldest first, both
    /// files of each on disk and no record of which of them reached iCloud (the key absent, as an older version writes
    /// it), registered to `owner`, by default the account verified now ("account-a"). Its engine's sweep asks iCloud
    /// through the presence stand-in, which holds the camera files `iCloudHolds` names (nil: iCloud gives no answer),
    /// and its saves land, kept for the test.
    private func olderLogWithUnsentCaptures(_ count: Int, iCloudHolds: Set<String>?, boundTo owner: String = "account-a")
        async throws -> (engine: MonitoringEngine, store: EventStore, captures: [Event], saved: SavedRecords) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: owner, resolve: { owner })
        XCTAssertTrue(verified, "a verified installation")
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var captures: [Event] = []
        for minutesOlder in (0..<count).reversed() {
            let start = Date().addingTimeInterval(-60 - Double(minutesOlder) * 60)
            var capture = Event(startDate: start, endDate: start.addingTimeInterval(1),
                                triggeredSensors: [.motion], cloudSyncState: .pending)
            capture.mediaFilename = UUID().uuidString + ".jpg"
            capture.primaryCamera = "front"
            capture.secondaryMediaFilename = UUID().uuidString + ".jpg"
            capture.secondaryCamera = "rear"
            capture.thumbnailData = Data([0xff, 0xd8, 0xff])
            for name in [capture.mediaFilename, capture.secondaryMediaFilename].compactMap({ $0 }) {
                try Data(count: 100).write(to: media.appendingPathComponent(name))
            }
            enrollment.registerLocalEvent(capture)
            captures.append(capture)
        }
        if owner != "account-a" {   // the account changed after the captures
            let switched = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
            XCTAssertTrue(switched, "account-a verified now")
        }
        let log = try JSONEncoder().encode(captures)
        XCTAssertFalse(try XCTUnwrap(String(bytes: log, encoding: .utf8)).contains("uploadedMedia"),
                       "no record, as an older version saved it")
        try log.write(to: root.appendingPathComponent("events.json"))

        let store = EventStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let cloud = CloudExfiltrator(enrollment: enrollment)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        try? await Task.sleep(for: .milliseconds(200))   // the launch sweep finds no identity and ends
        cloud.accountIdentityForTesting = { "account-a" }
        let saved = SavedRecords()
        cloud.saveAttemptForTesting = { records in saved.records += records }
        engine.cloudPresenceForTesting = { names in
            iCloudHolds.map { cameras in Set(names.filter { name in cameras.contains { name.hasPrefix("photo-\($0)-") } }) }
        }
        return (engine, store, captures, saved)
    }

    /// One such capture (`olderLogWithUnsentCaptures`).
    private func olderLogWithAnUnsentCapture(iCloudHolds: Set<String>?, boundTo owner: String = "account-a") async throws
        -> (engine: MonitoringEngine, store: EventStore, capture: Event, saved: SavedRecords) {
        let (engine, store, captures, saved) = try await olderLogWithUnsentCaptures(1, iCloudHolds: iCloudHolds, boundTo: owner)
        return (engine, store, try XCTUnwrap(captures.first), saved)
    }

    /// The record the sweep's last save of `capture`'s metadata carried, as another device decodes it.
    private func lastRecordSent(of capture: Event, in saved: SavedRecords) throws -> Event {
        let record = try XCTUnwrap(saved.records.last { $0.recordID.recordName == "meta-v2-" + capture.id.uuidString },
                                   "the sweep sent the capture's record")
        return try XCTUnwrap(CloudExfiltrator.event(from: record))
    }

    /// codex-24 on 118f4b1: an event saved before this version has no record of which files reached iCloud, and the
    /// byte limit read no record as none: a two-camera capture whose front photo reached iCloud under the older version
    /// was marked lost at the limit, and the other device, learning the mark, hid its download. Now the limit leaves
    /// the mark until iCloud has been asked, the download offered meanwhile; iCloud holds the front photo, so the
    /// capture is not marked, and what iCloud holds becomes its record.
    func testAnOlderCaptureWhoseFrontPhotoIsInICloudIsAskedOfICloudAndNotMarkedLost() async throws {
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: ["front"])
        let held = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(capture, deviceName: "Desk phone", thumbnailURL: nil)))   // the other phone's copy
        try await runTheByteLimit(on: store)
        let trimmed = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(trimmed.mediaDiscarded, true, "not marked lost before iCloud is asked")
        XCTAssertTrue(trimmed.fullCaptureMayBeInICloud, "its download offered meanwhile")

        await engine.retryPendingSync()   // the sweep asks iCloud
        let asked = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(asked.mediaDiscarded, true, "iCloud holds the front photo: not lost")
        XCTAssertEqual(asked.uploadedMedia, ["front"], "what iCloud holds becomes its record")
        let merged = try XCTUnwrap(EventStore.merged(local: [held], incoming: [try lastRecordSent(of: capture, in: saved)]).first)
        XCTAssertNotEqual(merged.mediaDiscarded, true, "the other phone is not told it is lost")
        XCTAssertTrue(merged.fullCaptureMayBeInICloud, "and still offers its download")
    }

    /// codex-24: iCloud holds none of the capture's files: once asked, the capture is marked lost, and the record the
    /// sweep sends carries the mark to the other devices.
    func testACaptureICloudHoldsNoneOfIsMarkedLostOnceICloudIsAsked() async throws {
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        let held = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(capture, deviceName: "Desk phone", thumbnailURL: nil)))
        try await runTheByteLimit(on: store)
        XCTAssertNotEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true,
                          "not marked lost before iCloud is asked")

        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "iCloud holds none: lost")
        let merged = try XCTUnwrap(EventStore.merged(local: [held], incoming: [try lastRecordSent(of: capture, in: saved)]).first)
        XCTAssertEqual(merged.mediaDiscarded, true, "the other phone learns it")
    }

    /// codex-24: iCloud gives no answer (offline, no verified account, an error): the capture stays unmarked, its
    /// download offered, for the next sweep to ask again.
    func testACaptureICloudGivesNoAnswerAboutStaysUnmarkedWithItsDownload() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: nil)
        try await runTheByteLimit(on: store)
        await engine.retryPendingSync()
        let unanswered = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(unanswered.mediaDiscarded, true, "no answer: not marked lost")
        XCTAssertTrue(unanswered.fullCaptureMayBeInICloud, "its download still offered")
    }

    /// codex-24: iCloud gives no answer at one sweep, which still sends the capture's record (synced, unmarked); at the next
    /// it holds none of the files: the capture is marked lost then, and its record goes up again carrying the mark.
    func testAMarkSetAfterTheRecordSyncedGoesUpAgain() async throws {
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: nil)
        try await runTheByteLimit(on: store)
        await engine.retryPendingSync()   // no answer; the record goes up without a mark
        let first = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(first.cloudSyncState, .synced)
        XCTAssertNotEqual(first.mediaDiscarded, true)
        engine.cloudPresenceForTesting = { _ in [] }   // the next sweep: iCloud holds none
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "lost, once asked")
        XCTAssertEqual(try lastRecordSent(of: capture, in: saved).mediaDiscarded, true, "and its record went up again with the mark")
    }

    /// codex-24: a write of the capture from a copy taken before the limit does not take back the check it owes.
    func testAStaleWriteKeepsTheCheckOwed() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        var stale = capture   // from before the limit, written back after it (a field the limit does not read)
        stale.endDate = capture.endDate.addingTimeInterval(1)
        store.update(stale)
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "the check still ran: lost")
    }

    /// codex-24: a write of the capture from a copy taken before the mark (the check ran at the sweep, after the copy was
    /// taken) does not take the mark back.
    func testAStaleWriteKeepsTheMark() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        await engine.retryPendingSync()   // iCloud holds none: marked lost
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "lost, once asked")
        var stale = capture   // from before the mark, written back after it
        stale.endDate = capture.endDate.addingTimeInterval(1)
        store.update(stale)
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "the mark stayed")
    }

    /// codex-24, a capture discarded with its check owed (Claude's self-review of 9ddd02d): a camera's file that finishes
    /// after the byte limit discarded the capture was refused while the limit marked the capture lost at once; a capture
    /// awaiting its check took the file, and could then be marked lost while it held a photo. A discard closes the
    /// capture's slots either way.
    func testALateFileForACaptureDiscardedWithItsCheckOwedIsRefused() async throws {
        let (_, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: nil)
        try await runTheByteLimit(on: store)
        let discarded = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(discarded.mediaDiscardUnchecked, true, "discarded, its check owed")
        XCTAssertNil(discarded.mediaFilename, "its files are gone")
        let late = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: discarded, camera: "front")
        XCTAssertNil(late, "the late file is refused")
        XCTAssertNil(store.events.first { $0.id == capture.id }?.mediaFilename, "the capture holds no file")
    }

    // MARK: - codex-27 on 1753878: an absence answer and a file that lands anyway

    /// codex-27 on 1753878: a full upload handed a copy of the capture before the byte limit discarded it took its pin
    /// only when its task ran, and sent the files that copy named. With the log's write failing, those files were still
    /// on disk, so a photo landed after the discard; iCloud, asked before it landed, held none, and the capture was
    /// marked lost while iCloud held its photo. Here the upload's turn comes after that mark, the order no receipt check
    /// could undo. An upload now sends only the files the log's copy names once it holds its pin.
    func testAnUploadHandedACopyBeforeTheLimitSendsNoFileTheLimitDiscarded() async throws {
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        let handed = try XCTUnwrap(store.events.first { $0.id == capture.id })   // the copy a queued upload holds
        let front = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(handed.mediaFilename))
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // the log cannot be replaced
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        try await runTheByteLimit(on: store)
        let failed = await eventually { store.persistDegraded }
        XCTAssertTrue(failed, "the write must actually fail")
        XCTAssertTrue(FileManager.default.fileExists(atPath: front.path), "the discarded photo is still on disk")
        await engine.retryPendingSync()   // iCloud, asked, holds none of it
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "marked lost")
        await engine.exfiltrate(handed)   // the queued upload's turn, with the copy it was handed
        XCTAssertFalse(saved.records.contains { $0.recordID.recordName.hasPrefix("photo-") }, "no discarded file is sent")
        XCTAssertNil(store.events.first { $0.id == capture.id }?.uploadedMedia, "no file landed after the discard")
    }

    /// codex-27: a receipt that arrives while iCloud is asked outweighs an empty answer sampled before its file landed:
    /// the capture is not marked lost, and its receipt stands.
    func testAReceiptThatArrivesWhileICloudIsAskedOutweighsAnEmptyAnswer() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        engine.cloudPresenceForTesting = { _ in
            store.noteMediaUploaded("front", for: capture.id)   // its front photo lands while the answer is on its way
            return []
        }
        await engine.retryPendingSync()
        let answered = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(answered.mediaDiscarded, true, "a file landed: not marked lost")
        XCTAssertEqual(answered.uploadedMedia, ["front"], "its receipt stands")
        XCTAssertNil(answered.mediaDiscardUnchecked, "the check is settled")
    }

    /// BACKLOG 176's codex-2: iCloud's answer that it holds a capture's front photo, asked for before iCloud's copies were
    /// lost and handled after the phone noticed the loss, is not taken: no receipt comes back in the new generation, and
    /// the check is left to an answer asked for after the loss. Red at its red commit: the old answer settled the check and
    /// wrote the receipt into the new generation.
    func testAnAnswerAskedForBeforeICloudsLossIsNotTaken() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: ["front"])
        try await runTheByteLimit(on: store)
        var lost = false
        engine.cloudPresenceForTesting = { names in
            guard !lost else { return [] }   // after the loss iCloud holds none
            lost = true
            _ = store.requeueAllForReupload()   // the loss noticed while this answer, from before it, is on its way
            return Set(names.filter { $0.hasPrefix("photo-front-") })
        }
        await engine.retryPendingSync()
        let held = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(held.receiptEpoch, 1, "the loss began a new generation")
        XCTAssertNil(held.uploadedMedia, "no receipt from before the loss")
        XCTAssertTrue(held.mediaDiscardUnchecked == true || held.mediaDiscarded == true,
                      "the old answer settled nothing: still owed, or marked lost by an answer asked for after the loss")
        await engine.retryPendingSync()   // iCloud, asked after the loss, holds none of it
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "lost, once asked after the loss")
    }

    // MARK: - codex-28 on 1753878: a wait iCloud names to the check

    /// A throttle that names a two-minute wait, as CloudKit reports one.
    private static var throttle: CKError { CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0]) }

    /// The check's fetch meets `fetch`'s throttle in a pass with the capture still to upload: nothing may be handed out
    /// during the wait iCloud named, the check stays owed, and the sweep's follow-up waits.
    private func assertAThrottledCheckHoldsThePass(
        _ fetch: @escaping @MainActor ([String]) async throws -> [(String, Result<Void, any Error>)]) async throws {
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        engine.cloudPresenceForTesting = nil   // the real presence check, only its fetch stood in for
        engine.cloud.presenceFetchForTesting = fetch
        let sent = saved.records.count
        await engine.retryPendingSync()
        XCTAssertEqual(saved.records.count, sent, "nothing handed out during the wait iCloud named")
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscardUnchecked, true, "the check still owed")
        XCTAssertTrue(engine.pendingSweepWaiting, "the follow-up waits")
    }

    /// codex-28 on 1753878: the check's fetch, refused by a throttle that named a wait, gave no answer and dropped the
    /// wait, and the pass handed out its uploads at once, against the sweep's rule that a named wait closes its door.
    func testAThrottleOnTheChecksFetchHoldsThePassesUploads() async throws {
        try await assertAThrottledCheckHoldsThePass { _ in throw Self.throttle }
    }

    /// codex-28: the same throttle, reported for one of the fetch's records.
    func testAThrottleOnOneOfTheChecksRecordsHoldsThePassesUploads() async throws {
        try await assertAThrottledCheckHoldsThePass { names in
            names.enumerated().map { index, name in
                (name, Result<Void, any Error>.failure(index == 0 ? Self.throttle : CKError(.unknownItem)))
            }
        }
    }

    /// codex-28: a pass whose check met the wait comes back for it even with every record up: an owed check counts
    /// toward the sweep's follow-up, as a record still to upload does.
    func testAThrottledCheckIsAskedAgainAfterTheWaitWithNothingLeftToUpload() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: nil)
        try await runTheByteLimit(on: store)
        await engine.retryPendingSync()   // no answer: the record goes up unmarked, its check still owed
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.cloudSyncState, .synced)
        for other in store.events where other.id != capture.id {
            store.setSyncState(.synced, for: other.id)   // the limit's trigger, bound to no account, as if up too
        }
        XCTAssertEqual(EventStore.unsyncedCount(in: store.events), 0, "nothing left to upload")
        engine.cloudPresenceForTesting = nil
        let questions = PresenceQuestions()
        engine.cloud.presenceFetchForTesting = { names in
            questions.asked.append(names)
            if questions.asked.count == 1 { throw Self.throttle(waiting: 0) }   // first: wait (the sweep's floor, 2 s)
            return names.map { ($0, Result<Void, any Error>.failure(CKError(.unknownItem))) }   // then: none of it is there
        }
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscardUnchecked, true, "the check still owed")
        XCTAssertTrue(engine.pendingSweepWaiting, "the follow-up waits to ask again")
        let askedAgain = await eventually(within: 6) { questions.asked.count == 2 }
        XCTAssertTrue(askedAgain, "the follow-up asked again (Codex's note on e191c72)")
        let answered = await eventually { store.events.first { $0.id == capture.id }?.mediaDiscarded == true }
        XCTAssertTrue(answered, "and settled the check: iCloud holds none of it")
    }

    // MARK: - codex-30 on 694e8d5: every failure in the check's answer is read

    /// A throttle that names `seconds` of wait.
    private static func throttle(waiting seconds: TimeInterval) -> CKError {
        CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: seconds])
    }

    /// The check's fetch answers the capture's record names with `failures`, in that order, the rest "no such record":
    /// nothing may be handed out during the wait, and the longest wait any record named reaches the sweep.
    private func assertTheLongestWaitHoldsThePass(_ failures: [any Error], expectedWait: TimeInterval) async throws {
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        engine.cloudPresenceForTesting = nil   // the real presence check, only its fetch stood in for
        engine.cloud.presenceFetchForTesting = { names in
            names.enumerated().map { index, name in
                (name, Result<Void, any Error>.failure(index < failures.count ? failures[index] : CKError(.unknownItem)))
            }
        }
        let sent = saved.records.count
        await engine.retryPendingSync()
        XCTAssertEqual(saved.records.count, sent, "nothing handed out during the wait iCloud named")
        XCTAssertEqual(engine.cloud.lastTransientFailure?.retryAfter, expectedWait, "the longest wait reaches the sweep")
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscardUnchecked, true, "the check still owed")
    }

    /// codex-30 on 694e8d5: the check's answer was read only up to its first failure; a permanent failure met first hid a
    /// throttle behind it, and the pass handed out its uploads during the wait iCloud named.
    func testAPermanentFailureMetFirstDoesNotHideAThrottle() async throws {
        try await assertTheLongestWaitHoldsThePass([CKError(.permissionFailure), Self.throttle(waiting: 120)], expectedWait: 120)
    }

    /// codex-30: the same answer in the other order.
    func testAThrottleMetFirstHoldsThePassWithAPermanentFailureAfterIt() async throws {
        try await assertTheLongestWaitHoldsThePass([Self.throttle(waiting: 120), CKError(.permissionFailure)], expectedWait: 120)
    }

    /// codex-30: of two waits, the shorter met first hid the longer, and the sweep would come back too soon.
    func testTheLongerOfTwoWaitsReachesTheSweep() async throws {
        try await assertTheLongestWaitHoldsThePass([Self.throttle(waiting: 5), Self.throttle(waiting: 120)], expectedWait: 120)
    }

    /// codex-30: the two waits in the other order.
    func testTheLongerOfTwoWaitsMetFirstReachesTheSweep() async throws {
        try await assertTheLongestWaitHoldsThePass([Self.throttle(waiting: 120), Self.throttle(waiting: 5)], expectedWait: 120)
    }

    /// codex-30: every failure a partial failure nests is read for its wait, where the classifier reads only the first it
    /// finds: a permanent one and two throttles give both waits, whatever order the partial failure keeps them in.
    func testEveryWaitAPartialFailureNestsIsRead() {
        let ids = (0..<3).map { _ in CKRecord.ID(recordName: "photo-front-v2-" + UUID().uuidString) }
        let nested: [CKRecord.ID: Error] = [ids[0]: CKError(.permissionFailure), ids[1]: Self.throttle(waiting: 5),
                                            ids[2]: Self.throttle(waiting: 120)]
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: nested])
        let waits = CloudExfiltrator.transientFailures(in: partial).compactMap(\.retryAfter).sorted()
        XCTAssertEqual(waits, [5, 120], "both waits read")
        let outer = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            CKRecord.ID(recordName: "photo-rear-v2-" + UUID().uuidString): partial,
            CKRecord.ID(recordName: "photo-rear-" + UUID().uuidString): Self.throttle(waiting: 30)]])
        let deeper = CloudExfiltrator.transientFailures(in: outer).compactMap(\.retryAfter).sorted()
        XCTAssertEqual(deeper, [5, 30, 120], "a partial failure nested in another is read too (Codex's note on e191c72)")
    }

    /// codex-30, through the sweep (Codex's note on e191c72): a partial failure the check's fetch throws, nesting a
    /// permanent failure and two throttles, holds the pass, and the longest of its waits reaches the sweep.
    func testAPartialFailureThrownByTheCheckHoldsThePassForItsLongestWait() async throws {
        let ids = (0..<3).map { _ in CKRecord.ID(recordName: "photo-front-v2-" + UUID().uuidString) }
        let nested: [CKRecord.ID: Error] = [ids[0]: CKError(.permissionFailure), ids[1]: Self.throttle(waiting: 5),
                                            ids[2]: Self.throttle(waiting: 120)]
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: nested])
        let (engine, store, capture, saved) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        engine.cloudPresenceForTesting = nil   // the real presence check, only its fetch stood in for
        engine.cloud.presenceFetchForTesting = { _ in throw partial }
        let sent = saved.records.count
        await engine.retryPendingSync()
        XCTAssertEqual(saved.records.count, sent, "nothing handed out during the wait iCloud named")
        XCTAssertEqual(engine.cloud.lastTransientFailure?.retryAfter, 120, "the longest wait reaches the sweep")
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscardUnchecked, true, "the check still owed")
    }

    // MARK: - codex-29 on 1753878: a restored capture's upload history is unknown

    /// A pending two-camera capture, `minutesAgo` minutes old, its files named; `withFilesIn` writes them.
    private func twoCameraCapture(minutesAgo: Double, withFilesIn media: URL) throws -> Event {
        let start = Date().addingTimeInterval(-minutesAgo * 60)
        var capture = Event(startDate: start, endDate: start.addingTimeInterval(1), triggeredSensors: [.motion],
                            cloudSyncState: .pending)
        capture.mediaFilename = UUID().uuidString + ".jpg"
        capture.primaryCamera = "front"
        capture.secondaryMediaFilename = UUID().uuidString + ".jpg"
        capture.secondaryCamera = "rear"
        capture.thumbnailData = Data([0xff, 0xd8, 0xff])
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for name in [capture.mediaFilename, capture.secondaryMediaFilename].compactMap({ $0 }) {
            try Data(count: 100).write(to: media.appendingPathComponent(name))
        }
        return capture
    }

    /// A phone restored from its device backup with one capture: the log and the capture's files come back, the grant's
    /// file does not, and the engine's first launch rebuilds the bindings, holding every restored first-hand record; the
    /// installation is then verified again.
    private func phoneRestoredWithACapture() async throws
        -> (engine: MonitoringEngine, store: EventStore, enrollment: CloudEnrollment, restored: Event) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let restored = try twoCameraCapture(minutesAgo: 60, withFilesIn: root.appendingPathComponent("Media", isDirectory: true))
        try JSONEncoder().encode([restored]).write(to: root.appendingPathComponent("events.json"))
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let store = EventStore()
        XCTAssertTrue(store.hasReadTheLog, "the restored log was read")
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "verified again after the restore")
        return (engine, store, enrollment, restored)
    }

    /// codex-29 on 1753878: the byte limit marked at once every capture with no account behind it, "discarded by the
    /// storage cap before it could upload", rightly for one recorded while the installation was not uploading, which never
    /// went up; but a restore from a device backup leaves every restored record with no account too, and a restored
    /// capture whose front photo had reached the original account's iCloud then read as never uploaded. The owner's
    /// option (a): such a capture is never said to have been discarded before it could upload; its check is owed, though
    /// this installation cannot run it.
    func testARestoredCaptureTheLimitDiscardsIsNotSaidToHaveNeverUploaded() async throws {
        let (engine, store, enrollment, restored) = try await phoneRestoredWithACapture()
        XCTAssertEqual(enrollment.uploadHoldReason(for: restored), .unknownAccount, "held by the restore's rebuild")
        try await runTheByteLimit(on: store)
        let discarded = try XCTUnwrap(store.events.first { $0.id == restored.id })
        XCTAssertNil(discarded.mediaFilename, "the limit took its files")
        XCTAssertNotEqual(discarded.mediaDiscarded, true, "not said to have been discarded before it could upload")
        XCTAssertEqual(discarded.mediaDiscardUnchecked, true, "its check owed, its upload history not known")
        withExtendedLifetime(engine) {}
    }

    /// codex-29's control: a capture recorded while this installation was not uploading (here, before its first
    /// verification) never went up, and the limit still marks it at once, with its line.
    func testACaptureRecordedBeforeVerificationIsStillMarkedAtOnce() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let capture = try twoCameraCapture(minutesAgo: 5, withFilesIn: store.mediaDirectory)
        enrollment.registerLocalEvent(capture)   // no account verified yet: held, tied to no account
        store.add(capture)
        XCTAssertEqual(enrollment.uploadHoldReason(for: capture), .unknownAccount)
        try await runTheByteLimit(on: store)
        XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "marked at once, with its line")
        withExtendedLifetime(engine) {}
    }

    /// codex-29: the rebuild notes the records it holds as restored, their upload history unknown, and no record recorded
    /// after it, though the app calls it again on each return to the screen.
    func testTheRestoresRebuildNotesOnlyTheRecordsItHolds() async throws {
        let (engine, store, enrollment, restored) = try await phoneRestoredWithACapture()
        XCTAssertTrue(enrollment.uploadHistoryUnknown(for: restored), "the restored record noted")
        let later = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        enrollment.registerLocalEvent(later)
        store.add(later)
        engine.seedCloudOwnershipIfReadable()   // as the app's return to the screen calls it
        XCTAssertFalse(enrollment.uploadHistoryUnknown(for: later), "a record made after the restore is not")
    }

    /// codex-31: the note is kept in the grant's file with the binding it qualifies, through the bindings' prune while
    /// its record is in the log.
    func testTheRestoredNoteStaysWithItsBindingThroughThePrune() async throws {
        let (engine, store, enrollment, restored) = try await phoneRestoredWithACapture()
        let gone = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        enrollment.registerLocalEvent(gone)   // a binding no record in the log needs
        XCTAssertEqual(enrollment.pruneBindings(keeping: Set(store.events.map(\.id))), 1, "the prune writes the grant")
        let reread = CloudEnrollment(file: try XCTUnwrap(EventStore.rootOverrideForTesting)
            .appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        XCTAssertTrue(reread.uploadHistoryUnknown(for: restored), "the restored record's note is kept with its binding")
        withExtendedLifetime(engine) {}
    }

    // MARK: - codex-31 and codex-32 on 694e8d5: the restore's note, durable and in time

    /// A relaunch from the phone's files as they are on disk now, copied to a folder of their own (what a kill at this
    /// moment leaves): a new store, grant and engine over that copy, which is removed when the test ends.
    private func relaunchFromTheFilesOnDisk(at root: URL) throws -> (engine: MonitoringEngine, store: EventStore,
                                                                    enrollment: CloudEnrollment) {
        let image = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem166Image-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: root, to: image)
        addTeardownBlock { try? FileManager.default.removeItem(at: image) }
        EventStore.rootOverrideForTesting = image
        let store = EventStore()
        EventStore.rootOverrideForTesting = root
        XCTAssertTrue(store.hasReadTheLog, "the relaunch read the log")
        let enrollment = CloudEnrollment(file: image.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, store, enrollment)
    }

    /// The grant's file as it is on disk: its bindings, whether the restore's rebuild ran, and its restored notes.
    private func grantOnDisk(_ file: URL) throws -> (owners: [String: String], migrationSeeded: Bool,
                                                    restoredHolds: Set<String>) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return (object["owners"] as? [String: String] ?? [:], object["migrationSeeded"] as? Bool ?? false,
                Set(object["restoredHolds"] as? [String] ?? []))
    }

    /// The byte limit discards `restored` on `store`: not said to have been discarded before it could upload, its
    /// check owed.
    private func assertTheLimitLeavesItsHistoryUnknown(_ restored: Event, on store: EventStore) async throws {
        try await runTheByteLimit(on: store)
        let discarded = try XCTUnwrap(store.events.first { $0.id == restored.id })
        XCTAssertNil(discarded.mediaFilename, "the limit took its files")
        XCTAssertNotEqual(discarded.mediaDiscarded, true, "not said to have been discarded before it could upload")
        XCTAssertEqual(discarded.mediaDiscardUnchecked, true, "its history unknown, its check owed")
    }

    /// codex-31 on 694e8d5: the restore's rebuild wrote the grant's file (the empty bindings, the rebuild done) at once,
    /// and the note on the restored capture into the event log by a later, queued write. A kill between the two (here a
    /// log write that fails, then a relaunch from the files as they were) left the rebuild done and the note gone for
    /// good, and the relaunched phone marked the restored capture lost at once.
    func testARelaunchAfterTheRestoresLogWriteFailedKeepsItsHistoryUnknown() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let restored = try twoCameraCapture(minutesAgo: 60, withFilesIn: root.appendingPathComponent("Media", isDirectory: true))
        try JSONEncoder().encode([restored]).write(to: root.appendingPathComponent("events.json"))
        let grant = root.appendingPathComponent("grant", isDirectory: true)
        try FileManager.default.createDirectory(at: grant, withIntermediateDirectories: true)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // the log cannot be replaced
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        let enrollment = CloudEnrollment(file: grant.appendingPathComponent("state.json"), authenticate: { _ in true })
        let store = EventStore()
        XCTAssertTrue(store.hasReadTheLog, "the restored log was read")
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        store.drainIOForTesting()
        let written = try grantOnDisk(grant.appendingPathComponent("state.json"))   // Codex's note on e191c72
        XCTAssertEqual(written.owners[restored.id.uuidString], "", "the rebuild's binding is on disk")
        XCTAssertTrue(written.migrationSeeded, "and the rebuild is done")
        XCTAssertTrue(written.restoredHolds.contains(restored.id.uuidString), "with its note, in the same write")
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path)
        let relaunched = try relaunchFromTheFilesOnDisk(at: root)
        try await assertTheLimitLeavesItsHistoryUnknown(restored, on: relaunched.store)
        withExtendedLifetime(engine) {}
    }

    /// codex-31's control: a rebuild whose writes all landed, then a relaunch; the restored capture's history stays
    /// unknown.
    func testARelaunchAfterACompletedRebuildKeepsItsHistoryUnknown() async throws {
        let (engine, store, _, restored) = try await phoneRestoredWithACapture()
        store.drainIOForTesting()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let relaunched = try relaunchFromTheFilesOnDisk(at: root)
        try await assertTheLimitLeavesItsHistoryUnknown(restored, on: relaunched.store)
        withExtendedLifetime(engine) {}
    }

    /// codex-32 on 694e8d5: with the restored log sealed when the engine was built (a launch before the first unlock),
    /// the rebuild waited for the next return to the screen; at the unlock, the engine's recovery logged the session it
    /// found interrupted, and the byte limit ran before the rebuild: a restored capture with no binding yet was marked
    /// lost at once, and the rebuild could not take the mark back.
    func testAnUnlockBeforeTheRestoresRebuildDoesNotMarkARestoredCaptureLost() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let restored = try twoCameraCapture(minutesAgo: 60, withFilesIn: root.appendingPathComponent("Media", isDirectory: true))
        let logURL = root.appendingPathComponent("events.json")
        try JSONEncoder().encode([restored]).write(to: logURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)   // sealed
        UserDefaults.standard.set(0.5, forKey: MonitoringEngine.armedMarkerKey)   // an armed session the process died out of
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        XCTAssertFalse(store.hasReadTheLog, "the launch waits for the first unlock")
        store.mediaBudgetForTesting = 10
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          protectedDataAvailable: { phone.unlocked }))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path)
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let recovered = await eventually { store.hasReadTheLog && store.events.contains { $0.interrupted ?? false } }
        XCTAssertTrue(recovered, "the unlock loads the log, and the recovery logs the interrupted session")
        let trimmed = await eventually { store.events.first { $0.id == restored.id }?.mediaFilename == nil }
        XCTAssertTrue(trimmed, "the byte limit ran before the rebuild")
        _ = await settled(store)
        store.drainIOForTesting()
        let discarded = try XCTUnwrap(store.events.first { $0.id == restored.id })
        XCTAssertNotEqual(discarded.mediaDiscarded, true, "not said to have been discarded before it could upload")
        XCTAssertEqual(discarded.mediaDiscardUnchecked, true, "its history unknown, its check owed")
        engine.seedCloudOwnershipIfReadable()   // the rebuild, as the next return to the screen runs it
        XCTAssertNotEqual(store.events.first { $0.id == restored.id }?.mediaDiscarded, true, "nor after the rebuild")
        engine.disarm()
    }

    /// codex-24: a capture bound to another iCloud account than the one verified now is not asked of this one, whose
    /// iCloud cannot hold its files: it is not marked lost on this account's answer, and its check stays owed.
    func testACaptureBoundToAnotherAccountIsNotMarkedLostOnThisOnesAnswer() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: [], boundTo: "account-b")
        try await runTheByteLimit(on: store)
        await engine.retryPendingSync()
        let held = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(held.mediaDiscarded, true, "not marked lost on another account's answer")
        XCTAssertEqual(held.mediaDiscardUnchecked, true, "its check still owed")
    }

    /// codex-24's check, its cost (Claude's self-review on 9ddd02d): the sweep asked iCloud about each capture awaiting a
    /// check on its own, each question under a lease of its own (an identity lookup each), before the pass uploaded
    /// anything; a storage emergency's backlog on a slow network held the pass's uploads for as many round trips. One
    /// pass now asks once, about all of them.
    func testOnePassAsksICloudOnceAboutTheCapturesAwaitingACheck() async throws {
        let (engine, store, captures, _) = try await olderLogWithUnsentCaptures(3, iCloudHolds: [])
        try await runTheByteLimit(on: store)
        let questions = PresenceQuestions()
        engine.cloudPresenceForTesting = { names in
            questions.asked.append(names)
            return []
        }
        await engine.retryPendingSync()
        XCTAssertEqual(questions.asked.count, 1, "one question for the pass")
        for capture in captures {
            XCTAssertTrue(questions.asked.first?.contains { $0.hasSuffix(capture.id.uuidString) } == true, "about each capture")
            XCTAssertEqual(store.events.first { $0.id == capture.id }?.mediaDiscarded, true, "each settled by the answer")
        }
    }

    /// codex-24's check makes no identity lookup of its own: it asks under the pass's lease. A pass whose lookup gets no
    /// answer (no network) asks iCloud nothing about the captures; they stay unmarked, their check owed.
    func testAPassWithoutALeaseAsksICloudNothingAboutTheCaptures() async throws {
        let (engine, store, capture, _) = try await olderLogWithAnUnsentCapture(iCloudHolds: [])
        try await runTheByteLimit(on: store)
        let questions = PresenceQuestions()
        engine.cloudPresenceForTesting = { names in
            questions.asked.append(names)
            return []
        }
        engine.cloud.accountIdentityForTesting = { throw CKError(.networkUnavailable) }
        await engine.retryPendingSync()
        XCTAssertTrue(questions.asked.isEmpty, "no question without the pass's lease")
        let held = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotEqual(held.mediaDiscarded, true, "not marked lost")
        XCTAssertEqual(held.mediaDiscardUnchecked, true, "its check still owed")
    }

    /// codex-24's check asks about at most `discardCheckBatchSize` captures a pass, the oldest first, so one fetch stays
    /// well within what CloudKit takes at once; the rest are asked at the next pass or sweep.
    func testOnePassAsksAboutABatchOfCapturesTheOldestFirst() async throws {
        let size = MonitoringEngine.discardCheckBatchSize
        let (engine, store, captures, _) = try await olderLogWithUnsentCaptures(size + 1, iCloudHolds: [])
        try await runTheByteLimit(on: store)
        let questions = PresenceQuestions()
        engine.cloudPresenceForTesting = { names in
            questions.asked.append(names)
            return []
        }
        await engine.retryPendingSync()
        XCTAssertEqual(questions.asked.count, 1, "one question for the pass")
        let newest = try XCTUnwrap(captures.last)
        XCTAssertFalse(questions.asked.first?.contains { $0.hasSuffix(newest.id.uuidString) } ?? true, "the newest waits")
        XCTAssertEqual(store.events.filter { $0.mediaDiscarded == true }.count, size, "the batch settled")
        XCTAssertEqual(store.events.first { $0.id == newest.id }?.mediaDiscardUnchecked, true, "the newest's check still owed")
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == newest.id }?.mediaDiscarded, true, "asked at the next sweep")
    }

    /// codex-24's one answer for many captures settles each from its own files: iCloud holds one capture's front photo
    /// and nothing of the other's, so the first keeps its download and the second is marked lost.
    func testEachCaptureIsSettledByItsOwnFilesInICloud() async throws {
        let (engine, store, captures, _) = try await olderLogWithUnsentCaptures(2, iCloudHolds: [])
        let (kept, lost) = (captures[0], captures[1])
        try await runTheByteLimit(on: store)
        engine.cloudPresenceForTesting = { names in Set(names.filter { $0 == "photo-front-v2-" + kept.id.uuidString }) }
        await engine.retryPendingSync()
        let first = try XCTUnwrap(store.events.first { $0.id == kept.id })
        XCTAssertNotEqual(first.mediaDiscarded, true, "its front photo is in iCloud")
        XCTAssertEqual(first.uploadedMedia, ["front"])
        let second = try XCTUnwrap(store.events.first { $0.id == lost.id })
        XCTAssertEqual(second.mediaDiscarded, true, "none of its files is: lost")
        XCTAssertNil(second.uploadedMedia, "and the other capture's file is not counted as its own")
    }

    /// codex-24's check makes no identity lookup of its own: the presence check under a caller's lease looks no account
    /// up, where the form without one does (the Simulator has no container, so neither gets an answer; only the
    /// lookups differ). No engine, so nothing else looks the account up meanwhile.
    func testThePresenceCheckUnderALeaseLooksUpNoAccount() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let cloud = CloudExfiltrator(enrollment: enrollment)
        let lookups = Lookups()
        cloud.accountIdentityForTesting = {
            lookups.count += 1
            return "account-a"
        }
        let granted = await cloud.acquireCloudLease()
        let lease = try XCTUnwrap(granted, "the lease")
        XCTAssertEqual(lookups.count, 1)
        let names = ["photo-front-v2-" + UUID().uuidString]
        _ = await cloud.presentRecordNames(names, lease: lease)
        XCTAssertEqual(lookups.count, 1, "no lookup under the caller's lease")
        _ = await cloud.presentRecordNames(names)
        XCTAssertEqual(lookups.count, 2, "the form without one looks the account up")
    }

    /// A capture that can never have gone up (recorded while iCloud backup was off) is marked lost at the limit at once,
    /// as before, with no download offered: there is nothing in iCloud to ask about.
    func testACaptureThatCouldNeverGoUpIsMarkedLostAtOnce() async throws {
        let (_, _, store, capture) = try await twoCameraCaptureReadyToUpload()
        var kept = try XCTUnwrap(store.events.first { $0.id == capture.id })
        kept.keptLocal = true   // recorded while iCloud backup was off
        store.update(kept)
        try await runTheByteLimit(on: store)
        let trimmed = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(trimmed.mediaDiscarded, true, "lost at once")
        XCTAssertFalse(trimmed.fullCaptureMayBeInICloud, "no download offered")
    }

    /// The token a photo record's name carries, as the check reads what iCloud holds.
    func testThePhotoRecordNamesTokenIsItsCameraOrSlot() {
        let id = UUID().uuidString
        XCTAssertEqual(MonitoringEngine.mediaToken(fromPhotoRecordName: "photo-front-v2-" + id), "front")
        XCTAssertEqual(MonitoringEngine.mediaToken(fromPhotoRecordName: "photo-rear-" + id), "rear")
        XCTAssertEqual(MonitoringEngine.mediaToken(fromPhotoRecordName: "photo-secondary-v2-" + id), "secondary")
        XCTAssertNil(MonitoringEngine.mediaToken(fromPhotoRecordName: "meta-v2-" + id))
    }

    // MARK: - codex-26 on 118f4b1: an unlock hands over only the reports still owed after the recovery

    /// What a report listening on the store has been handed.
    @MainActor
    private final class HandedOver {
        var ids: [UUID] = []
    }

    /// A launch removes the oldest incident at the limit and owes its report, with no engine listening; another row has
    /// synced since, so a later recovery's limit takes it instead. `restorable`: the oldest's birth line is still in the
    /// journal (its retirement never ran), so the next launch's recovery brings it back. Then the log is sealed, and the
    /// next launch waits for the first unlock with a report already listening.
    private func anUnlockOwingTheOldest(restorable: Bool) async throws -> (store: EventStore, oldest: Event,
                                                                             handed: HandedOver, phone: LockState) {
        let (_, oldest, _) = try await logAtTheIncidentLimit()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        do {
            let first = EventStore()
            let now = Date()
            first.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))
            first.drainIOForTesting()
            XCTAssertTrue(first.removalsAwaitingReport.contains(oldest.id))
        }
        let logURL = root.appendingPathComponent("events.json")
        var log = try JSONDecoder().decode([Event].self, from: Data(contentsOf: logURL))
        let synced = try XCTUnwrap(log.indices.last)   // the oldest row left: it synced since
        log[synced].cloudSyncState = .synced
        try JSONEncoder().encode(log).write(to: logURL)
        if restorable {
            let journal = try FileHandle(forWritingTo: root.appendingPathComponent("events.journal"))
            try journal.seekToEnd()
            try journal.write(contentsOf: try XCTUnwrap(EventStore.journalLine(for: oldest)))
            try journal.close()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)   // sealed
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        XCTAssertFalse(store.hasReadTheLog, "the launch waits for the first unlock")
        let handed = HandedOver()
        store.onCountEviction = { removed, _ in handed.ids += removed.map(\.id) }   // a report already listening
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path)
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let loaded = await eventually { store.hasReadTheLog }
        XCTAssertTrue(loaded, "the unlock loads the log")
        return (store, oldest, handed, phone)
    }

    /// codex-26 on 118f4b1: at the unlock, the reports owed were handed to the report already listening before the
    /// journal's recovery ran; when the recovery brought the owed incident back, its report still went out, a false
    /// "not fully backed up" record spending that watch's or day's one record. The reports owed are handed over after the
    /// recovery, without the incidents it brought back.
    func testAnUnlockHandsOverNoReportForAnIncidentTheRecoveryBringsBack() async throws {
        let (store, oldest, handed, _) = try await anUnlockOwingTheOldest(restorable: true)
        XCTAssertTrue(store.events.contains { $0.id == oldest.id }, "the recovery brought the oldest back")
        let reported = await eventually(within: 0.5) { handed.ids.contains(oldest.id) }
        XCTAssertFalse(reported, "no report for an incident the log holds again")
        XCTAssertFalse(store.removalsAwaitingReport.contains(oldest.id), "nor one owed")
        store.drainIOForTesting()
    }

    /// The control: an owed incident the recovery does not bring back is handed over at the unlock.
    func testAnUnlockHandsOverTheReportsStillOwed() async throws {
        let (store, oldest, handed, _) = try await anUnlockOwingTheOldest(restorable: false)
        XCTAssertFalse(store.events.contains { $0.id == oldest.id })
        let reported = await eventually { handed.ids.contains(oldest.id) }
        XCTAssertTrue(reported, "the report still owed is handed over")
        store.drainIOForTesting()
    }

    // MARK: - codex-22 on ae720ca: the reports owed are never written over

    /// The files a crash leaves at the moment the first log write lands (the checkpoint observer runs on the file queue,
    /// right after it): the log, and the files `beside` it (the journal, the reports owed), copied into `image`. Only the
    /// first write is copied.
    private final class CrashImage: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        let image: URL
        private let beside: [String]
        init(image: URL, beside: [String]) {
            self.image = image
            self.beside = beside
        }
        func take(from root: URL, log: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !taken else { return }
            taken = true
            let fm = FileManager.default
            try? fm.createDirectory(at: image, withIntermediateDirectories: true)
            try? log.write(to: image.appendingPathComponent("events.json"))
            for name in beside {
                try? fm.copyItem(at: root.appendingPathComponent(name), to: image.appendingPathComponent(name))
            }
        }
    }

    /// codex-22 on ae720ca: the journal's recovery at launch can trim the log too, and it wrote the reports owed before
    /// the launch had read the ones a launch before still owed, so a crash after its log write lost them. A report is
    /// owed for an incident a launch removed (A); the next launch's journal brings back an incident whose log write never
    /// landed, and the limit removes another (D, tied to no account, so its own report writes no record). The files as
    /// that log write leaves them must still owe A's report, and the record follows.
    func testTheJournalsRecoveryKeepsTheReportsALaunchBeforeOwed() async throws {
        let (enrollment, oldest, _) = try await logAtTheIncidentLimit()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        do {
            let first = EventStore()   // no engine listens yet: the report for the oldest is owed
            let now = Date()
            first.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))
            first.drainIOForTesting()
            XCTAssertTrue(first.removalsAwaitingReport.contains(oldest.id))
        }   // the app ends
        // An incident whose log write never landed: only its journal line is on disk.
        let later = Date().addingTimeInterval(1)
        let journaled = Event(startDate: later, endDate: later, triggeredSensors: [.touch], cloudSyncState: .pending)
        let journal = try FileHandle(forWritingTo: root.appendingPathComponent("events.journal"))
        try journal.seekToEnd()
        try journal.write(contentsOf: try XCTUnwrap(EventStore.journalLine(for: journaled)))
        try journal.close()

        let crash = CrashImage(image: root.appendingPathComponent("after-a-crash", isDirectory: true),
                               beside: ["events.journal", EventStore.reportsOwedFileName])
        EventStore.checkpointObserverForTesting = { storeRoot, _, log in crash.take(from: storeRoot, log: log) }
        let next = EventStore()   // the recovery: the journaled incident back, the limit removes another
        next.drainIOForTesting()
        EventStore.checkpointObserverForTesting = nil
        XCTAssertTrue(next.events.contains { $0.id == journaled.id }, "the journal brought it back")

        EventStore.rootOverrideForTesting = crash.image   // the launch after a crash at that log write
        defer { EventStore.rootOverrideForTesting = root }
        let relaunched = EventStore()
        XCTAssertTrue(relaunched.removalsAwaitingReport.contains(oldest.id), "the report a launch before owed is kept")
        engine(over: relaunched, enrollment: enrollment, pro: ProEntitlements(resolvedAs: .trial)).watchCountEvictions()
        let reported = await eventually { relaunched.events.contains { $0.stateChange == "unsyncedRemoved" } }
        XCTAssertTrue(reported, "the log keeps the record that an unsent incident was removed")
        relaunched.drainIOForTesting()
    }

    /// codex-22: a failed write of the reports owed was logged and passed over, and the log that drops the incident was
    /// written and its photo deleted anyway, the gap A1 closed. A log never drops an event whose report is not on disk:
    /// with the reports owed unwritable (a folder in their file's place) and the log writable, the log on disk keeps the
    /// incident and its photo, and Home hears that the log could not be saved.
    func testALogWaitsForTheReportsOwedToReachTheDisk() async throws {
        let (_, oldest, photo) = try await logAtTheIncidentLimit()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let store = EventStore()
        let blocker = root.appendingPathComponent(EventStore.reportsOwedFileName, isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))
        store.drainIOForTesting()
        let disk = try JSONDecoder().decode([Event].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
        XCTAssertTrue(disk.contains { $0.id == oldest.id }, "the log on disk keeps the incident whose report is not saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "and its photo")
        let degraded = await eventually { store.persistDegraded }
        XCTAssertTrue(degraded, "Home hears the log could not be saved")
    }

    /// codex-22: a file of reports owed that could not be read was taken for none and written over at the next report.
    /// It is set aside, as a damaged log is, and the reports owed start afresh.
    func testAnUnreadableReportsOwedFileIsSetAsideNotWrittenOver() async throws {
        let (_, oldest, _) = try await logAtTheIncidentLimit()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let garbage = Data("not a report".utf8)
        try garbage.write(to: root.appendingPathComponent(EventStore.reportsOwedFileName))
        let store = EventStore()
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))
        store.drainIOForTesting()
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("reports-owed.corrupt-") }
        XCTAssertEqual(aside.count, 1, "the unreadable file is kept aside")
        if let name = aside.first {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), garbage, "as it was")
        }
        XCTAssertTrue(store.removalsAwaitingReport.contains(oldest.id), "and the new report is owed")
    }

    // MARK: - B2 (codex-4): the alerts caption names both paths

    /// codex-4 on 144e723: Settings called the alerts switch "one switch for the whole account" whose off "removes alerts
    /// for all devices", while each iPhone keeps sending its own alerts to its own Apple Watch until its own switch is
    /// off (ADR 0043; README and SECURITY.md say so). Read as Settings shows it.
    func testTheAlertsCaptionSaysEachIPhoneKeepsAlertingItsOwnWatch() throws {
        let shown = try settingsShownOnScreen()
        let caption = try XCTUnwrap(shown.first { $0.hasPrefix("Alert every device on this iCloud account") },
                                    "Settings shows no alerts caption: \(shown)")
        XCTAssertFalse(caption.contains("removes alerts for all devices"), caption)
        XCTAssertFalse(caption.contains("One switch for the whole account"), caption)
        XCTAssertTrue(caption.contains("its own Apple Watch until its own switch is off"), caption)
    }
}
