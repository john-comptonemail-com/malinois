//
//  Item141ReArmSkipTests.swift
//  MalinoisTests
//
//  Fable's fable-3 on 1.8 (75) (BACKLOG 141; item 132, from the owner's TestFlight 1.7.1 question): when the
//  crash-loop guard declines an automatic re-arm (two attempts within 90 seconds), nothing said so; Home showed at most
//  "Recovered an interrupted armed session". Now Home says the re-arm was skipped, and why; a re-arm that runs says
//  nothing of the kind, and the owner's next arm clears it. Driven through a real engine's launch recovery. Written
//  before the change, red at that commit (against compile-only stubs). Item 132's remainder and item 153's MAL-10
//  (1.8.2's step 20): the skip also leaves a silent record in the Event Log, read back on the owner's other devices
//  with no alert; those tests too were red at their commit.
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item141ReArmSkipTests: XCTestCase {
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let lastAttemptKey = "com.malinois.recovery.lastAt"

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
        let entitlements: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem141ReArm")
    }

    override func tearDown() {
        TestIsolation.tearDown()   // the recovery flags go with it
        super.tearDown()
    }

    /// Owed less than 90 seconds after the last attempt: the guard declines it, and Home says so.
    func testASkippedReArmSaysSoOnHome() throws {
        owe(lastAttemptSecondsAgo: 10)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.reArmSkipped }, timeout: 3), "Home is not told")
        XCTAssertEqual(rig.engine.state, .disarmed, "not re-armed")
        XCTAssertTrue(try home(rig).contains(HomeView.reArmSkippedNotice))
    }

    /// A re-arm that runs says nothing of the kind.
    func testAReArmThatRunsLeavesNoNotice() throws {
        owe(lastAttemptSecondsAgo: 600)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3), "the owed re-arm starts its countdown")
        XCTAssertFalse(rig.engine.reArmSkipped)
        rig.engine.disarm()
        XCTAssertFalse(try home(rig).contains(HomeView.reArmSkippedNotice))
    }

    /// The owner's own next arm clears it.
    func testTheNextArmClearsIt() {
        owe(lastAttemptSecondsAgo: 10)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.reArmSkipped }, timeout: 3))
        rig.engine.beginArming()
        XCTAssertFalse(rig.engine.reArmSkipped)
        rig.engine.cancelArming()
    }

    /// It gives the rule and what to do.
    func testTheNoticeGivesTheRule() {
        XCTAssertTrue(HomeView.reArmSkippedNotice.contains("90 seconds"), HomeView.reArmSkippedNotice)
        XCTAssertTrue(HomeView.reArmSkippedNotice.contains("Arm it again"), HomeView.reArmSkippedNotice)
    }

    // MARK: - The Event Log's record (item 132's remainder; item 153's MAL-10)

    /// The skip leaves a quiet status entry, in Home's words.
    func testASkippedReArmLeavesARecordInTheLog() {
        owe(lastAttemptSecondsAgo: 10)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.reArmSkipped }, timeout: 3))
        let record = rig.store.events.first { $0.stateChange == "reArmSkipped" }
        XCTAssertNotNil(record, "the skip is in the log")
        XCTAssertEqual(record?.sensorSummary,
                       "Not re-armed automatically: Malinois was closed again within 90 seconds of re-arming itself")
    }

    /// A re-arm that runs leaves no such record.
    func testAReArmThatRunsLeavesNoRecord() {
        owe(lastAttemptSecondsAgo: 600)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3))
        XCTAssertFalse(rig.store.events.contains { $0.stateChange == "reArmSkipped" })
        rig.engine.disarm()
    }

    /// The owner's other devices read it back from iCloud, with no alert there or on the watch; it has an icon of its own.
    func testTheRecordIsReadBackElsewhereWithNoAlert() {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "reArmSkipped")
        let record = CloudExfiltrator.makeStateRecord(event, kind: "reArmSkipped", deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "reArmSkipped")
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "reArmSkipped"), "no disarm alert through iCloud")
        XCTAssertTrue(WatchAlertRelay.alerts(for: [event], alertsOn: true, proActive: true).isEmpty, "nothing to the watch")
        XCTAssertEqual(EventRow.placeholderIcon(for: "reArmSkipped"), "exclamationmark.arrow.triangle.2.circlepath",
                       "Home's notice's own symbol")
    }

    // MARK: - Helpers

    private func owe(lastAttemptSecondsAgo seconds: TimeInterval) {
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970 - seconds, forKey: Self.lastAttemptKey)
    }

    /// A launch with a re-arm owed: the recovery runs once the Pro check has resolved, as on the phone.
    private func launch() -> Rig {
        let entitlements = ProEntitlements.unresolvedForTesting()
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        entitlements.resolveForTesting(as: .trial)
        return Rig(engine: engine, settings: settings, store: store, entitlements: entitlements)
    }

    /// What the real Home shows.
    private func home(_ rig: Rig) throws -> [String] {
        try shownOnScreen(HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(CloudExfiltrator())
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)).shown
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}
