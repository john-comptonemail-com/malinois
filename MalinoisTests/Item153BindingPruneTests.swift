//
//  Item153BindingPruneTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-08 (1.8.2's step 17). The installation's account bindings (`owners`, `remoteOwners` in the
//  enrollment's file) gained one entry per record for ever, and the whole file is rewritten at every new record, before
//  the journal append: about 80 bytes an entry, so a year of heavy use wrote most of a megabyte on the trigger path.
//  Once the complete log has been read, the bindings no record needs any longer are now pruned: those of records gone
//  from the log, keeping uploads under way and the watches whose heartbeat records iCloud may still hold. The hold rule
//  (ADR 0039) is kept for what the log holds; a record gone from the log that comes back from iCloud comes back as a
//  copy, bound to the account that supplies it, the documented direction. Written before the change, red at that
//  commit. Codex's codex-6, twice: what the engine still uploads keeps its binding too (the live flood's record and
//  fact pushes waiting their turn; then a record whose capture is still running), each case red at its fix's commit.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item153BindingPruneTests: XCTestCase {

    nonisolated private static let beatKeys = ["com.malinois.beats.sessions", "com.malinois.beats.sessionsSeeded"]

    // Set in setUp and removed in tearDown, which XCTest runs without main-actor isolation (item 97).
    nonisolated(unsafe) private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Prune")
        for key in Self.beatKeys { UserDefaults.standard.removeObject(forKey: key) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem153Prune-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        for key in Self.beatKeys { UserDefaults.standard.removeObject(forKey: key) }
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    private var file: URL { directory.appendingPathComponent("enrollment.json") }

    /// An installation verified for "owner".
    private func verified() async throws -> CloudEnrollment {
        let enrollment = CloudEnrollment(file: file, authenticate: { _ in true })
        let ok = await enrollment.enroll(account: "owner", resolve: { "owner" })
        try XCTSkipUnless(ok, "the enrollment could not be written")
        return enrollment
    }

    /// The bindings as the file holds them, and the file's size.
    private func written() throws -> (owners: [String: String], remoteOwners: [String: String], bytes: Int) {
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (object["owners"] as? [String: String] ?? [:], object["remoteOwners"] as? [String: String] ?? [:],
                data.count)
    }

    private func record() -> Event { Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]) }

    // MARK: - The bound

    /// Twice the log's capacity bound over time (written in one go, as the rebuild after a restore holds a log), the
    /// log's capacity still in it: the file keeps exactly those, and its size comes down with them (the bound, measured).
    func testTheBindingsOfRecordsGoneFromTheLogArePruned() async throws {
        let enrollment = try await verified()
        let all = (0..<(2 * EventStore.maxEvents)).map { _ in record() }
        enrollment.holdRestoredEvents(all)
        let before = try written()
        XCTAssertEqual(before.owners.count, all.count)
        let kept = Set(all.suffix(EventStore.maxEvents).map(\.id))
        let pruned = enrollment.pruneBindings(keeping: kept)
        let after = try written()
        XCTAssertEqual(pruned, all.count - kept.count)
        XCTAssertEqual(Set(after.owners.keys), Set(kept.map(\.uuidString)), "exactly the log's")
        let perEntry = Double(before.bytes) / Double(all.count)
        XCTAssertLessThan(Double(after.bytes), perEntry * Double(kept.count) + 1_000,
                          "about \(Int(perEntry)) bytes an entry: \(after.bytes) bytes for \(kept.count), from \(before.bytes)")
    }

    /// Copies from iCloud gone from the log lose their bindings too; those it holds keep theirs.
    func testTheBindingsOfCopiesGoneFromTheLogArePruned() async throws {
        let enrollment = try await verified()
        let lease = try XCTUnwrap(enrollment.authorize(account: "owner"))
        let copies = (0..<10).map { _ in record() }
        XCTAssertTrue(enrollment.registerRemoteEvents(copies, lease: lease))
        enrollment.pruneBindings(keeping: Set(copies.prefix(3).map(\.id)))
        XCTAssertEqual(Set(try written().remoteOwners.keys), Set(copies.prefix(3).map(\.id.uuidString)))
    }

    // MARK: - The hold rule (ADR 0039)

    /// A held record (recorded with no account it may upload to) keeps its empty binding while the log holds it, so a
    /// copy from iCloud under its ID is still refused. Gone from the log, its binding goes, and a copy that comes back
    /// is bound to the account that supplied it: a copy, not the held record adopted.
    func testAHeldRecordStaysHeldWhileTheLogHoldsIt() async throws {
        let enrollment = try await verified()
        let held = record(), gone = record()
        enrollment.holdsNewEventsLocal = { true }
        enrollment.registerLocalEvent(held)
        enrollment.registerLocalEvent(gone)
        enrollment.holdsNewEventsLocal = { false }
        enrollment.pruneBindings(keeping: [held.id])
        let after = try written()
        XCTAssertEqual(after.owners[held.id.uuidString], "", "still held")
        XCTAssertNil(after.owners[gone.id.uuidString], "gone from the log: nothing left to hold")
        let lease = try XCTUnwrap(enrollment.authorize(account: "owner"))
        XCTAssertTrue(enrollment.registerRemoteEvents([held, gone], lease: lease))
        XCTAssertFalse(enrollment.authorizeRecord(held.id, lease: lease), "a copy under a held record's ID is refused")
        XCTAssertTrue(enrollment.authorizeRecord(gone.id, lease: lease), "one gone from the log comes back as a copy")
    }

    // MARK: - The engine

    /// A store that read this launch's log from disk, holding `events`.
    private func storeReadFromDisk(_ events: [Event]) throws -> EventStore {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: root.appendingPathComponent("events.json"))
        let store = EventStore()
        XCTAssertTrue(store.hasReadTheLog, "the log was read from disk")
        return store
    }

    private func makeEngine(store: EventStore, enrollment: CloudEnrollment) -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                             cloud: CloudExfiltrator(enrollment: enrollment),
                                             camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                             timing: EngineCharacterizationTests.fastTiming))
    }

    /// Once the complete log is read, the engine keeps what still needs a binding: the log's records, an upload under
    /// way (its record already gone from the log), and a Pro watch whose heartbeat trail iCloud may hold; the rest goes.
    func testTheEngineKeepsWhatStillNeedsABinding() async throws {
        let enrollment = try await verified()
        let inLog = record(), uploading = record(), gone = record()
        let watch = UUID()
        for event in [inLog, uploading, gone] { enrollment.registerLocalEvent(event) }
        enrollment.registerSession(watch)
        let store = try storeReadFromDisk([inLog])
        store.beginUpload(uploading.id)
        defer { store.endUpload(uploading.id) }
        BeatSessionRegistry.save([BeatSession(id: watch, start: Date())])
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.pruneCloudBindingsIfReadable()
        let owners = try written().owners
        XCTAssertNotNil(owners[inLog.id.uuidString], "in the log")
        XCTAssertNotNil(owners[uploading.id.uuidString], "its upload under way")
        XCTAssertNotNil(owners[watch.uuidString], "a watch whose heartbeat trail iCloud may hold")
        XCTAssertNil(owners[gone.id.uuidString], "gone, and nothing needs it")
    }

    /// The event limit's removals at launch wait for the unsynced-removal marker (item 114), which reads their bindings
    /// when the engine first listens; their bindings stay until it has. The first gate on this step found the prune
    /// coming first: the removed incident read as held for good, and no marker was left (Item116ReviewTests).
    func testARemovalAwaitingItsMarkerKeepsItsBinding() async throws {
        let enrollment = try await verified()
        let incidents = (0...EventStore.maxIncidentEvents).map { minutes -> Event in
            let at = Date().addingTimeInterval(-Double(minutes) * 60)
            return Event(startDate: at, endDate: at, triggeredSensors: [.touch], cloudSyncState: .pending,
                         stateChange: nil, sourceDevice: nil)
        }
        for event in incidents { enrollment.registerLocalEvent(event) }
        let store = try storeReadFromDisk(incidents)   // one over the limit: the load removes one
        let awaiting = store.removalsAwaitingReport
        XCTAssertEqual(awaiting.count, 1, "the removal waits for the engine to listen")
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.pruneCloudBindingsIfReadable()
        let owners = try written().owners
        for id in awaiting { XCTAssertEqual(owners[id.uuidString], "owner", "kept until the marker has read it") }
    }

    /// Control: a log not read from disk (one still locked after a restart, or one started fresh) reads as empty, and
    /// pruning from it would drop every binding; nothing is pruned.
    func testNothingIsPrunedFromALogNotReadFromDisk() async throws {
        let enrollment = try await verified()
        let gone = record()
        enrollment.registerLocalEvent(gone)
        let engine = makeEngine(store: EventStore(), enrollment: enrollment)
        engine.pruneCloudBindingsIfReadable()
        XCTAssertNotNil(try written().owners[gone.id.uuidString], "kept: the log was not read")
    }

    // MARK: - What the engine still uploads (codex-6 on 1.8.2's step 17)

    /// The meta records the saves sent, read back as a receiving device reads them.
    @MainActor
    private final class Sent {
        private(set) var events: [Event] = []
        func add(_ records: [CKRecord]) { events += records.compactMap(CloudExfiltrator.event(from:)) }
    }

    /// A job holding an event's upload queue until the test lets it go.
    @MainActor
    private final class Hold {
        private var waiter: CheckedContinuation<Void, Never>?
        var holding: Bool { waiter != nil }
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }

    /// Waits for `condition`, yielding the main actor meanwhile: an async test holds the actor, and the engine's timers
    /// and tasks run only while it awaits.
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    /// A live flood's record can leave a full log (count retention takes older flood rows first) while the engine
    /// keeps its copy and goes on pushing the count every tenth trip. The prune forgot it, and those pushes were
    /// refused for want of a binding: iCloud's count stopped. Driven through a real flood against a full log.
    func testALiveFloodRecordGoneFromTheLogStillUploads() async throws {
        let enrollment = try await verified()
        let full = (1...EventStore.maxIncidentEvents).map { minutes -> Event in
            let at = Date().addingTimeInterval(-Double(minutes) * 60)
            return Event(startDate: at, endDate: at, triggeredSensors: [.touch], cloudSyncState: .synced,
                         stateChange: nil, sourceDevice: nil)
        }
        for event in full { enrollment.registerLocalEvent(event) }
        let store = try storeReadFromDisk(full)
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "owner" }
        let sent = Sent()
        cloud.saveAttemptForTesting = { records in sent.add(records) }
        var timing = EngineCharacterizationTests.fastTiming
        timing.sustainedIdleClear = 30   // the flood outlasts the test
        timing.floodCaptureInterval = 0.3
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.jammingResponse = false
        settings.captureMode = .photo
        settings.cameraPosition = .front
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let armed = await waitFor({ engine.state == .armed }, timeout: 5)
        XCTAssertTrue(armed, "armed")
        for _ in 0..<MonitoringEngine.floodTripThreshold {
            engine.handleTrip(.motion)
            let settled = await waitFor({ engine.state == .armed }, timeout: 3)
            XCTAssertTrue(settled)
        }
        engine.handleTrip(.motion)   // the flood's onset: its record is the anchor
        let anchor = { store.events.first { !$0.isStateChange && $0.sustainedCount != nil }?.id }
        let onset = await waitFor({ engine.state == .armed && anchor() != nil }, timeout: 3)
        XCTAssertTrue(onset, "the anchor")
        let anchorID = try XCTUnwrap(anchor())
        let uploaded = await waitFor({ !store.isUploading(anchorID) }, timeout: 3)
        XCTAssertTrue(uploaded, "its own upload over")
        try? await Task.sleep(nanoseconds: 400_000_000)   // past the cadence's interval
        engine.handleTrip(.motion)   // coalesced (2), with a cadence capture: a newer record in a full log
        let evicted = await waitFor({ !store.events.contains { $0.id == anchorID } }, timeout: 3)
        XCTAssertTrue(evicted, "the anchor left the log")
        let reported = await waitFor({ store.removalsAwaitingReport.isEmpty }, timeout: 3)
        XCTAssertTrue(reported, "its removal reported")
        engine.pruneCloudBindingsIfReadable()   // as a return to the foreground does
        for _ in 3...10 {   // coalesced, each settled before the next
            let settled = await waitFor({ engine.state == .armed }, timeout: 3)
            XCTAssertTrue(settled)
            engine.handleTrip(.motion)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let counted = await waitFor({ sent.events.contains { $0.id == anchorID && $0.sustainedCount == 10 } }, timeout: 3)
        XCTAssertTrue(counted, "the tenth trip's count reached iCloud")
        engine.disarm()
    }

    /// A fact push waits its turn in the record's queue (behind another write, or its identity lookup); the record can
    /// leave the log meanwhile. The prune forgot it, and the push was refused at its turn. Its binding now stays from
    /// before its task starts until it ends.
    func testAFactPushWaitingItsTurnKeepsItsBinding() async throws {
        let enrollment = try await verified()
        let store = try storeReadFromDisk([record()])
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "owner" }
        let sent = Sent()
        cloud.saveAttemptForTesting = { records in sent.add(records) }
        let engine = makeEngine(store: store, cloud: cloud)
        let gone = record()   // its push asked for while it was in the log; it has left the log since
        enrollment.registerLocalEvent(gone)
        let hold = Hold()
        Task { await cloud.enqueue(gone.id) { await hold.wait() } }   // an earlier write for the same record
        let holding = await waitFor({ hold.holding }, timeout: 2)
        XCTAssertTrue(holding, "the queue is held")
        engine.pushFactIfCloud(gone)
        try? await Task.sleep(nanoseconds: 200_000_000)
        engine.pruneCloudBindingsIfReadable()
        hold.release()
        let landed = await waitFor({ sent.events.contains { $0.id == gone.id } }, timeout: 3)
        XCTAssertTrue(landed, "the push landed at its turn")
    }

    // MARK: - A record gone from the log during its capture (codex-6, Codex's look at 0ed887f)

    private struct FloodRig {
        let engine: MonitoringEngine
        let store: EventStore
        let camera: FakeCamera
        let sent: Sent
    }

    /// A Pro watch verified for "owner" on a full log (500 synced incidents), saves landing at once, a photo per capture,
    /// the flood threshold's trips taken and settled: the next trip is a flood's onset.
    private func armedOnAFullLog() async throws -> FloodRig {
        let enrollment = try await verified()
        let full = (1...EventStore.maxIncidentEvents).map { minutes -> Event in
            let at = Date().addingTimeInterval(-Double(minutes) * 60)
            return Event(startDate: at, endDate: at, triggeredSensors: [.touch], cloudSyncState: .synced,
                         stateChange: nil, sourceDevice: nil)
        }
        for event in full { enrollment.registerLocalEvent(event) }
        let store = try storeReadFromDisk(full)
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "owner" }
        let sent = Sent()
        cloud.saveAttemptForTesting = { records in sent.add(records) }
        var timing = EngineCharacterizationTests.fastTiming
        timing.sustainedIdleClear = 30   // the flood outlasts the test
        timing.floodCaptureInterval = 0.3
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.jammingResponse = false
        settings.captureMode = .photo
        settings.cameraPosition = .front
        let camera = FakeCamera()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: camera, entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let armed = await waitFor({ engine.state == .armed }, timeout: 5)
        XCTAssertTrue(armed, "armed")
        for _ in 0..<MonitoringEngine.floodTripThreshold {
            engine.handleTrip(.motion)
            let settled = await waitFor({ engine.state == .armed }, timeout: 3)
            XCTAssertTrue(settled)
        }
        return FloodRig(engine: engine, store: store, camera: camera, sent: sent)
    }

    /// While a record's capture is held: a newer incident (the blackout's signal-loss record, which an observed upload
    /// failure raises) takes its place in the full log, its removal is reported, and the app comes back to the
    /// foreground (from Control Centre, say), whose active scene prunes. Returns with the capture still held.
    private func evictDuringItsCapture(_ id: UUID, in rig: FloodRig) async {
        rig.engine.escalate(.blackout)
        let evicted = await waitFor({ !rig.store.events.contains { $0.id == id } }, timeout: 3)
        XCTAssertTrue(evicted, "the record left the log during its capture")
        let reported = await waitFor({ rig.store.removalsAwaitingReport.isEmpty }, timeout: 3)
        XCTAssertTrue(reported, "its removal reported")
        rig.engine.handleScenePhase(true)
    }

    /// Codex's case: a flood's onset record leaves the full log while its capture is held, after its sparse fact has
    /// landed, and the foreground's prune runs before the capture ends. The prune forgot it: the capture's final
    /// metadata and the later coalesced count were refused for want of a binding.
    func testAFloodOnsetGoneFromTheLogDuringItsCaptureStillUploads() async throws {
        let rig = try await armedOnAFullLog()
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)   // the onset: its record and its fact, then its capture, held
        let onset = { rig.store.events.first { !$0.isStateChange && $0.sustainedCount != nil }?.id }
        let recorded = await waitFor({ onset() != nil }, timeout: 3)
        XCTAssertTrue(recorded, "the onset's record")
        let onsetID = try XCTUnwrap(onset())
        let factLanded = await waitFor({ rig.sent.events.contains { $0.id == onsetID } }, timeout: 3)
        XCTAssertTrue(factLanded, "its sparse fact landed")
        await evictDuringItsCapture(onsetID, in: rig)
        XCTAssertEqual(try written().owners[onsetID.uuidString], "owner", "its binding kept while its capture runs")
        rig.camera.releaseStills()
        let finished = await waitFor({ rig.sent.events.contains { $0.id == onsetID && $0.captureFailure != nil } },
                                     timeout: 3)
        XCTAssertTrue(finished, "the capture's final metadata reached iCloud")
        for _ in 2...10 {   // coalesced into the onset, the live anchor now; each settled before the next
            let settled = await waitFor({ rig.engine.state == .armed }, timeout: 3)
            XCTAssertTrue(settled)
            rig.engine.handleTrip(.motion)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let counted = await waitFor({ rig.sent.events.contains { $0.id == onsetID && $0.sustainedCount == 10 } },
                                    timeout: 3)
        XCTAssertTrue(counted, "the tenth trip's count reached iCloud")
        rig.engine.disarm()
    }

    /// The same window for a flood's cadence still: its record (a flood row, the first the event limit takes) leaves the
    /// full log while its photo is held, and the foreground's prune runs before the photo ends. Its final upload must
    /// still go up.
    func testAFloodStillGoneFromTheLogDuringItsCaptureStillUploads() async throws {
        let rig = try await armedOnAFullLog()
        rig.engine.handleTrip(.motion)   // the onset, captured at once: the anchor
        let flood = { rig.store.events.first { !$0.isStateChange && $0.sustainedCount != nil }?.id }
        let anchored = await waitFor({ rig.engine.state == .armed && flood() != nil }, timeout: 3)
        XCTAssertTrue(anchored, "the anchor")
        let anchorID = try XCTUnwrap(flood())
        let uploaded = await waitFor({ !rig.store.isUploading(anchorID) }, timeout: 3)
        XCTAssertTrue(uploaded, "its own upload over")
        try? await Task.sleep(nanoseconds: 400_000_000)   // past the cadence's interval
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)   // coalesced, with a cadence still: a new flood record, its photo held
        let still = { rig.store.events.first { !$0.isStateChange && $0.sustainedCount != nil && $0.id != anchorID }?.id }
        let recorded = await waitFor({ still() != nil }, timeout: 3)
        XCTAssertTrue(recorded, "the still's record")
        let stillID = try XCTUnwrap(still())
        let factLanded = await waitFor({ rig.sent.events.contains { $0.id == stillID } }, timeout: 3)
        XCTAssertTrue(factLanded, "its sparse fact landed")
        await evictDuringItsCapture(stillID, in: rig)
        XCTAssertEqual(try written().owners[stillID.uuidString], "owner", "its binding kept while its photo is taken")
        rig.camera.releaseStills()
        let finished = await waitFor({ rig.sent.events.contains { $0.id == stillID && $0.captureFailure != nil } },
                                     timeout: 3)
        XCTAssertTrue(finished, "the still's final metadata reached iCloud")
        rig.engine.disarm()
    }

    private func makeEngine(store: EventStore, cloud: CloudExfiltrator) -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                             camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                             timing: EngineCharacterizationTests.fastTiming))
    }
}
