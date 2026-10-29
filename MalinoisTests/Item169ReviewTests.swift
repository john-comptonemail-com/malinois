//
//  Item169ReviewTests.swift
//  MalinoisTests
//
//  Codex's full review of 1.8.2 at 60a8f1a (BACKLOG 169; the owner: "1 - yes"). Written before each fix, red at its
//  commit.
//  - codex-2 (step 49): a change of the automatic clean-up's setting did not reach a pass already under way: the pass
//    read the setting once and, while it waited on iCloud, checked only the account. Keep forever chosen meanwhile
//    still let it delete old full-size media (Codex's probe: 8 deletions sent). Now the pass asks before every batch
//    of deletions whether the setting still wants it, in the media purge and in the heartbeat trim.
//  - codex-1 (step 50): ARM then Cancel needs no PIN on an unlocked, disarmed phone, and each cancel added a status
//    record; the status budget holds 100, so a hundred cancels pushed out the oldest, those not yet uploaded with them
//    (a "Guided Access ended", an interruption), and the loss notice never counted status records. Now cancels in a
//    row count on one record, the run kept across a relaunch and ended by ten quiet minutes or a watch going live; and
//    the loss notice counts first-hand status and interruption records lost before they uploaded.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item169ReviewTests: XCTestCase {
    nonisolated private static let keys = ["com.malinois.cloudRetention.lastRun", "com.malinois.cloudRetention.lastAttempt",
                                           "com.malinois.beats.sessions", "com.malinois.beats.sessionsSeeded",
                                           MonitoringEngine.cancelRunKey]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem169")
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - codex-1: cancels in a row count on one record (step 50)

    private struct Phone {
        let engine: MonitoringEngine
        let store: EventStore
        let enrollment: CloudEnrollment
    }

    /// A Pro phone verified for "owner", offline (nothing it records reaches iCloud), disarmed on Home, the PIN set and
    /// entered recently, so ARM asks for nothing.
    private func offlinePhone(store: EventStore = EventStore(), enrollment: CloudEnrollment? = nil) async throws -> Phone {
        XCTAssertTrue(KeychainService.setPIN("7391"))
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let gate: CloudEnrollment
        if let enrollment {
            gate = enrollment
        } else {
            gate = CloudEnrollment(file: root.appendingPathComponent("enrollment-169/state.json"), authenticate: { _ in true })
            let enrolled = await gate.enroll(account: "owner", resolve: { "owner" })
            XCTAssertTrue(enrolled)
        }
        let cloud = CloudExfiltrator(enrollment: gate)
        cloud.accountIdentityForTesting = { nil }   // offline: no account answers
        cloud.saveAttemptForTesting = { _ in throw CKError(.networkUnavailable) }
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        engine.simulateGuidedAccessForTesting(on: true)
        return Phone(engine: engine, store: store, enrollment: gate)
    }

    private func cancelACountdown(_ phone: Phone) {
        XCTAssertFalse(phone.engine.armPINCheckIsDue)
        phone.engine.beginArming()
        phone.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(phone.engine.state, .arming)
        phone.engine.cancelArming()
        XCTAssertEqual(phone.engine.state, .disarmed)
    }

    private func cancels(_ phone: Phone) -> [Event] {
        phone.store.events.filter { $0.stateChange == "armingCancelled" }
    }

    /// Codex's probe: 101 cancels on an offline phone. The older status records not yet uploaded stay, the cancels count
    /// on one record, and so it is on disk.
    func testCancelsInARowKeepTheOlderStatusRecords() async throws {
        let phone = try await offlinePhone()
        let at = Date().addingTimeInterval(-3600)
        let ended = Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "guidedAccessEnded")
        let interruption = Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending, interrupted: true)
        let incident = Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .pending)
        for event in [ended, incident, interruption] {
            phone.enrollment.registerLocalEvent(event)
            phone.store.add(event)
        }
        for _ in 0..<(EventStore.maxAuditEvents + 1) { cancelACountdown(phone) }
        XCTAssertTrue(phone.store.events.contains { $0.id == ended.id }, "the Guided Access record stays")
        XCTAssertTrue(phone.store.events.contains { $0.id == interruption.id }, "the interruption stays")
        XCTAssertTrue(phone.store.events.contains { $0.id == incident.id })
        XCTAssertEqual(cancels(phone).count, 1, "one record for the run")
        XCTAssertEqual(cancels(phone).first?.cancelCount, EventStore.maxAuditEvents + 1)
        try await Task.sleep(for: .milliseconds(200))
        phone.store.drainIOForTesting()
        let reloaded = EventStore()
        XCTAssertTrue(reloaded.events.contains { $0.id == ended.id } && reloaded.events.contains { $0.id == interruption.id },
                      "and so on disk")
    }

    /// A relaunch does not start a new run: the run is kept on disk.
    func testARelaunchContinuesTheRun() async throws {
        let store = EventStore()
        let first = try await offlinePhone(store: store)
        for _ in 0..<3 { cancelACountdown(first) }
        let relaunched = try await offlinePhone(store: store, enrollment: first.enrollment)
        for _ in 0..<2 { cancelACountdown(relaunched) }
        XCTAssertEqual(cancels(relaunched).count, 1)
        XCTAssertEqual(cancels(relaunched).first?.cancelCount, 5)
    }

    /// Ten quiet minutes end the run: a later cancel is a record of its own, and alerts as one.
    func testACancelAfterTenQuietMinutesIsARecordOfItsOwn() async throws {
        let phone = try await offlinePhone()
        for _ in 0..<2 { cancelACountdown(phone) }
        let run = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: MonitoringEngine.cancelRunKey))
        var aged = run
        aged["last"] = Date().addingTimeInterval(-11 * 60).timeIntervalSince1970
        UserDefaults.standard.set(aged, forKey: MonitoringEngine.cancelRunKey)
        cancelACountdown(phone)
        XCTAssertEqual(cancels(phone).count, 2)
    }

    /// A watch going live ends the run: the next cancel is a record of its own.
    func testAWatchGoingLiveEndsTheRun() async throws {
        let phone = try await offlinePhone()
        cancelACountdown(phone)
        phone.engine.settings.gracePeriodSeconds = 0
        phone.engine.beginArming()
        phone.engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while phone.engine.state != .armed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(phone.engine.state, .armed, "the watch went live")
        phone.engine.disarm()
        phone.engine.settings.gracePeriodSeconds = 60
        cancelACountdown(phone)
        XCTAssertEqual(cancels(phone).count, 2)
    }

    /// The run's record says how many countdowns it counts; one cancel reads as before.
    func testTheRunsRecordSaysHowManyTimes() {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "armingCancelled")
        XCTAssertEqual(event.sensorSummary, "Arming cancelled before going live")
        event.cancelCount = 3
        XCTAssertEqual(event.sensorSummary, "Arming cancelled before going live, 3 times in a row")
    }

    /// The loss notice counts a first-hand status record lost before it uploaded, as it counts an incident.
    func testAStatusRecordLostBeforeUploadingIsNoticed() async throws {
        let phone = try await offlinePhone()
        let at = Date().addingTimeInterval(-3600)
        let ended = Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "guidedAccessEnded")
        phone.enrollment.registerLocalEvent(ended)
        phone.engine.noteCountEviction([ended])
        XCTAssertEqual(phone.store.events.filter { $0.stateChange == "unsyncedRemoved" }.count, 1)
    }

    // MARK: - codex-2: a change of the setting stops a clean-up under way (step 49)

    /// iCloud as the clean-up sees it: its old events, the candidate query held while a test wants it held, and every
    /// batch of deletions sent.
    @MainActor
    private final class StandInCloud {
        var holdQuery = false
        var held: CheckedContinuation<Void, Never>?
        var events: [UUID] = [UUID()]
        var batches: [[CKRecord.ID]] = []
        var afterBatch: (() -> Void)?
        /// The watches the engine handed over for their heartbeat trim, and what a trim deleted.
        var handedOver: [[UUID]] = []
        var trailDeleted = 0
    }

    private func rig(retention: CloudRetention = .months1) -> (MonitoringEngine, AppSettings, StandInCloud) {
        let settings = AppSettings()
        settings.cloudRetention = retention
        let cloud = CloudExfiltrator()
        let stand = StandInCloud()
        let now = Date()
        cloud.retentionAccessForTesting = .init(
            serverDate: { _ in now },
            mediaEvents: { _, type in
                guard type == CloudExfiltrator.metaRecordTypeV2 else { return ([], true) }
                if stand.holdQuery { await withCheckedContinuation { stand.held = $0 } }
                return (stand.events, true)
            },
            beatRecords: { _, _ in [:] },
            delete: { ids in
                stand.batches.append(ids)
                stand.afterBatch?()
                return (ids.count, false)
            })
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, settings, stand)
    }

    /// One old watch waiting for its heartbeat trim, as the engine keeps the list.
    private func keepAnOldWatch() throws -> BeatSession {
        let old = BeatSession(id: UUID(), start: Date().addingTimeInterval(-400 * 86_400))
        UserDefaults.standard.set(try JSONEncoder().encode([old]), forKey: "com.malinois.beats.sessions")
        UserDefaults.standard.set(true, forKey: "com.malinois.beats.sessionsSeeded")
        return old
    }

    /// Codex's probe: Keep forever chosen while the pass waits on its candidate query. Nothing is deleted.
    func testKeepForeverChosenMidPassStopsItsDeletions() async {
        let (engine, settings, stand) = rig()
        stand.holdQuery = true
        let pass = Task { await engine.enforceCloudRetentionIfDue() }
        let deadline = Date().addingTimeInterval(3)
        while stand.held == nil && Date() < deadline { await Task.yield() }
        guard let held = stand.held else {
            pass.cancel()
            return XCTFail("the pass never reached its candidate query")
        }
        settings.cloudRetention = .forever   // as the Settings picker sets it
        held.resume()
        await pass.value
        XCTAssertEqual(stand.batches.flatMap { $0 }.count, 0, "Keep forever is chosen, yet deletions were sent")
    }

    /// Control: with the setting unchanged the pass deletes as before.
    func testAnUnchangedSettingStillDeletes() async {
        let (engine, _, stand) = rig()
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(stand.batches.count, 1, "one batch for the one old event")
    }

    /// The pass asks before every batch, not once: a change after the first stops the second.
    func testAChangeBetweenBatchesStopsTheNext() async {
        let (engine, settings, stand) = rig()
        stand.events = (0..<30).map { _ in UUID() }   // several names each: more than one batch of 200
        stand.afterBatch = { settings.cloudRetention = .manual }
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(stand.batches.count, 1, "the second batch is not sent")
    }

    /// The heartbeat trim after the purge asks too: a change during the purge leaves the trails alone.
    func testAChangeDuringThePurgeSkipsTheHeartbeatTrim() async throws {
        let (engine, settings, stand) = rig()
        _ = try keepAnOldWatch()
        engine.beatTrailsTrimForTesting = { sessions in
            stand.handedOver.append(sessions.map(\.id))
            return [:]
        }
        stand.afterBatch = { settings.cloudRetention = .forever }
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(stand.handedOver, [], "no trim once the setting changed")
    }

    /// Control: with the setting unchanged the old watch is handed over for its trim.
    func testAnUnchangedSettingStillTrims() async throws {
        let (engine, _, stand) = rig()
        let old = try keepAnOldWatch()
        engine.beatTrailsTrimForTesting = { sessions in
            stand.handedOver.append(sessions.map(\.id))
            return [:]
        }
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(stand.handedOver, [[old.id]])
    }

    /// Inside the heartbeat trim the cloud asks before every batch as well; asked and wanted, it deletes.
    func testTheHeartbeatTrimAsksBeforeEachBatch() async {
        let cloud = CloudExfiltrator()
        let server = Date()
        let lastBeat = server.addingTimeInterval(-400 * 86_400)
        let stand = StandInCloud()
        cloud.retentionAccessForTesting = .init(
            serverDate: { _ in server },
            mediaEvents: { _, _ in ([], true) },
            beatRecords: { names, _ in
                Dictionary(uniqueKeysWithValues: names.map { name in
                    (name, name.hasPrefix("beat-latest-")
                        ? .success(FetchedBeat(modified: lastBeat, sequence: 1))
                        : .failure(CKError(.unknownItem)))
                })
            },
            delete: { ids in
                stand.trailDeleted += ids.count
                return (ids.count, false)
            })
        let session = BeatSession(id: UUID(), start: lastBeat)
        _ = await cloud.trimBeatTrails([session], monthsOld: 1, stillWanted: { false })
        XCTAssertEqual(stand.trailDeleted, 0, "not wanted: nothing deleted")
        _ = await cloud.trimBeatTrails([session], monthsOld: 1, stillWanted: { true })
        XCTAssertGreaterThan(stand.trailDeleted, 0, "control: wanted, the trail goes")
    }
}
