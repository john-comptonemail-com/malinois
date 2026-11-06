//
//  Item187ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 187's deepseek-5 (Medium; Claude: Low), taken by 1.11 (item 192's step 7): a backlog's one "disarmed" alert
//  lost when its signal fails after its record lands. A pending sweep pass sends one alert for its late disarms, carried
//  by the newest; when the newest did not land, the newest that did stands in (item 162's ds4f1-1017-6, item 170's
//  codex-3). The stand-in was chosen by whether the newest's record reached iCloud, so a record that landed with its
//  alert failing behind it (the alert is a courtesy on top of the audit record, its failure only logged) left the pass
//  with no alert at all. Now the stand-in is chosen by whether the newest's alert went out. Written before the change,
//  red at that commit.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item187ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem187")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func disarm(minutesAgo: Double) -> Event {
        let at = Date().addingTimeInterval(-minutesAgo * 60)
        return Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending, stateChange: "disarmed")
    }

    // MARK: - The rule

    /// The stand-in follows the newest late disarm's alert, not its record: the newest whose record landed and whose
    /// alert did not sends the pass's alert again; one whose alert went out needs none; one whose record failed is
    /// stood in for by the newest that landed, as before; with none landed, none stands in.
    func testTheStandInFollowsTheNewestsAlertNotItsRecord() {
        let late = (1...3).map { disarm(minutesAgo: Double($0) * 30) }   // the newest first
        let all = Set(late.map(\.id))
        XCTAssertEqual(MonitoringCloudCoordinator.lateDisarmAlertStandIn(late: late, uploaded: all, alerted: [])?.id,
                       late[0].id, "its record landed and its alert did not: it sends the pass's alert again")
        XCTAssertNil(MonitoringCloudCoordinator.lateDisarmAlertStandIn(late: late, uploaded: all, alerted: [late[0].id]),
                     "its alert went out: no stand-in")
        XCTAssertEqual(MonitoringCloudCoordinator.lateDisarmAlertStandIn(late: late, uploaded: [late[1].id, late[2].id],
                                                                         alerted: [])?.id,
                       late[1].id, "its record failed: the newest that landed stands in, as before")
        XCTAssertNil(MonitoringCloudCoordinator.lateDisarmAlertStandIn(late: late, uploaded: [], alerted: []),
                     "none landed: none stands in")
    }

    // MARK: - Through the real upload

    private struct Phone {
        let engine: MonitoringEngine
        let store: EventStore
        let enrollment: CloudEnrollment
    }

    /// A Pro phone verified for "owner", offline until the test says otherwise (item 170's rig).
    private func offlinePhone() async throws -> Phone {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let gate = CloudEnrollment(file: root.appendingPathComponent("enrollment-187/state.json"), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "owner", resolve: { "owner" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: gate)
        cloud.accountIdentityForTesting = { nil }   // offline: no account answers
        cloud.saveAttemptForTesting = { _ in throw CKError(.networkUnavailable) }
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        return Phone(engine: engine, store: store, enrollment: gate)
    }

    private func until(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    /// A pass online over `events`, recorded offline, in which a save throws when `fails` says so of a record in it.
    private func pass(over events: [Event], failing fails: @escaping (CKRecord) -> Bool) async throws -> Phone {
        let phone = try await offlinePhone()
        for event in events {
            phone.enrollment.registerLocalEvent(event)
            phone.store.add(event)
        }
        let idle = await until { !phone.engine.pendingSweepActive }
        XCTAssertTrue(idle, "no sweep running yet")
        phone.engine.cloud.accountIdentityForTesting = { "owner" }
        phone.engine.cloud.saveAttemptForTesting = { records in
            if records.contains(where: fails) { throw CKError(.serverRejectedRequest) }
        }
        await phone.engine.retryPendingSync()
        return phone
    }

    /// deepseek-5: the newest late disarm's record lands and its alert fails: the pass sends its alert again for it.
    /// Before, the record's landing counted as the alert, and the pass sent none.
    func testANewestLateDisarmWhoseAlertFailsHasItSentAgain() async throws {
        let older = disarm(minutesAgo: 50), newer = disarm(minutesAgo: 30)
        let newestAlert = "disarm-v2-" + newer.id.uuidString
        let phone = try await pass(over: [older, newer]) { $0.recordID.recordName == newestAlert }
        XCTAssertEqual(phone.engine.sweepDisarmSignalsForTesting[newer.id], true, "the newest was to carry the alert")
        XCTAssertEqual(phone.store.events.first { $0.id == newer.id }?.cloudSyncState, .synced, "its record landed")
        XCTAssertEqual(phone.engine.sweepStandInAlertsForTesting, [newer.id], "its alert did not: it is sent again")
    }

    /// The control: nothing fails, the newest carries the alert itself, and none stands in.
    func testNoStandInWhenTheNewestsAlertGoesOut() async throws {
        let older = disarm(minutesAgo: 50), newer = disarm(minutesAgo: 30)
        let phone = try await pass(over: [older, newer]) { _ in false }
        XCTAssertEqual(phone.engine.sweepDisarmSignalsForTesting[newer.id], true)
        XCTAssertEqual(phone.engine.sweepStandInAlertsForTesting, [])
    }
}
