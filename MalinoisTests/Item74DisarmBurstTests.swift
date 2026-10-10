//
//  Item74DisarmBurstTests.swift
//  MalinoisTests
//
//  Tests for BACKLOG 74 line 9, ruled (a) by the owner on 2026-09-28. The pending sweep re-pushes
//  arm/disarm records that never reached iCloud, and each disarm also writes the signal that
//  raises "Malinois was disarmed" on the owner's other devices, whatever its age: a backlog of old
//  disarms raised one alert per record. Now a disarm sent within ten minutes of happening always
//  alerts, and among the late ones in a sweep pass only the newest does, so the owner still learns
//  once that protection stopped. A cancelled countdown writes the same signal and counts the same.
//

import XCTest
@testable import Malinois

@MainActor
final class Item74DisarmBurstTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem74L9")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func state(_ kind: String, minutesAgo: Double) -> Event {
        let at = Date().addingTimeInterval(-minutesAgo * 60)
        return Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    private func muted(_ events: [Event]) -> Set<UUID> {
        MonitoringEngine.mutedLateDisarmSignals(in: events, now: Date(), lateAfter: MonitoringEngine.lateDisarmSignalAge)
    }

    // MARK: - The rule

    /// A disarm sent within minutes of happening always alerts.
    func testAFreshDisarmAlwaysAlerts() {
        XCTAssertTrue(muted([state("disarmed", minutesAgo: 1)]).isEmpty)
    }

    /// Among late disarms in one pass, only the newest alerts; a fresh one alerts as well.
    func testAmongLateDisarmsOnlyTheNewestAlerts() {
        let late = (1...5).map { state("disarmed", minutesAgo: Double($0) * 60) }   // 1 to 5 hours old
        let fresh = state("disarmed", minutesAgo: 2)
        XCTAssertEqual(muted(late + [fresh]), Set(late.dropFirst().map(\.id)),
                       "the newest late disarm (an hour old) still alerts, and so does the fresh one")
    }

    /// A cancelled countdown writes the same signal and counts the same; an arm never alerts, so
    /// none is muted.
    func testCancelledCountdownsCountAndOtherKindsDoNot() {
        let cancels = [state("armingCancelled", minutesAgo: 120), state("armingCancelled", minutesAgo: 60)]
        let arms = [state("armed", minutesAgo: 200), state("armed", minutesAgo: 100)]
        XCTAssertEqual(muted(cancels + arms), [cancels[0].id])
    }

    // MARK: - The sweep

    /// The sweep hands each record its decision: three late disarms and a fresh one in one pass,
    /// and only the newest late one and the fresh one alert.
    func testTheSweepPassesTheDecisionOn() async {
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let late = (1...3).map { state("disarmed", minutesAgo: Double($0) * 60) }
        let fresh = state("disarmed", minutesAgo: 1)
        for event in late + [fresh] { store.add(event) }
        engine.sweepUploadForTesting = { _ in (.synced, nil) }
        await engine.retryPendingSync()
        let decisions = engine.sweepDisarmSignalsForTesting
        XCTAssertEqual(decisions[late[0].id], true, "the newest late disarm alerts")
        XCTAssertEqual(decisions[late[1].id], false)
        XCTAssertEqual(decisions[late[2].id], false)
        XCTAssertEqual(decisions[fresh.id], true, "a fresh disarm alerts")
    }
}
