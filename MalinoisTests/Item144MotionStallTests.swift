//
//  Item144MotionStallTests.swift
//  MalinoisTests
//
//  BACKLOG 144 (g), item 145 step 5 (the owner's "agree", 2026-10-21). The Motion tripwire's watchdog restarts a
//  stream that has delivered nothing for 3 s (BACKLOG 5), but the restart left only a line in the system log: the
//  primary tripwire could be deaf for a few seconds with nothing in the owner's log to say so. Now the first stall of
//  a live watch writes a quiet status entry, like the Sound and heat records: no siren, no cross-device alert,
//  nothing to the watch. Later stalls of the same watch add none; the monitor counts afresh at each start, so a new
//  watch records its first stall again. The watchdog itself cannot fire in the Simulator (no motion sensor), so the
//  tests drive the monitor's stall report; `MotionMonitor.isStalled` is unit-tested already.
//  Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
import UIKit
@testable import Malinois

@MainActor
final class Item144MotionStallTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem144Motion")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeRig() -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        return Rig(engine: engine, store: store)
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    private func motionRecords(_ rig: Rig) -> [String] {
        rig.store.events.compactMap(\.stateChange).filter { $0 == "motionStalled" }
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    // MARK: - The rule

    /// Only a watch's first stall writes the record: a stream that keeps stalling must not fill the status history.
    func testOnlyAWatchsFirstStallWritesTheRecord() {
        XCTAssertTrue(MonitoringEngine.motionStallRecordDue(count: 1), "the first stall of a watch")
        for count in [0, 2, 3, 50] {
            XCTAssertFalse(MonitoringEngine.motionStallRecordDue(count: count), "stall #\(count) writes nothing")
        }
    }

    // MARK: - The engine

    /// Armed, the first stall writes one quiet record; later stalls of the same watch add none; the watch carries on.
    func testTheFirstStallOfAnArmedWatchWritesOneQuietRecord() {
        let rig = makeRig()
        arm(rig)
        rig.engine.handleMotionStall(count: 1)
        rig.engine.handleMotionStall(count: 2)
        rig.engine.handleMotionStall(count: 3)
        XCTAssertEqual(motionRecords(rig), ["motionStalled"], "one record a watch")
        XCTAssertEqual(rig.engine.state, .armed, "not a trip: the watch carries on")
        XCTAssertFalse(rig.engine.alertActive, "no siren, no alert")
        rig.engine.disarm()
    }

    /// Nothing is recorded while disarmed (a stall during Test Sensors, say).
    func testNothingIsRecordedWhileDisarmed() {
        let rig = makeRig()
        rig.engine.handleMotionStall(count: 1)
        XCTAssertTrue(motionRecords(rig).isEmpty)
    }

    /// A new watch starts the monitor again, which counts afresh: its first stall is recorded too.
    func testANewWatchRecordsItsFirstStallAgain() {
        let rig = makeRig()
        arm(rig)
        rig.engine.handleMotionStall(count: 1)
        rig.engine.disarm()
        arm(rig)
        rig.engine.handleMotionStall(count: 1)
        XCTAssertEqual(motionRecords(rig), ["motionStalled", "motionStalled"])
        rig.engine.disarm()
    }

    /// A monitor from the engine's factory reports its stalls to the engine.
    func testTheFactorysMonitorReportsItsStallsToTheEngine() {
        let rig = makeRig()
        arm(rig)
        let motion = rig.engine.makeMotionMonitor()
        motion.onStall?(1)
        XCTAssertEqual(motionRecords(rig), ["motionStalled"])
        rig.engine.disarm()
    }

    /// The motion monitor the engine actually watches with is the wired one.
    func testTheEnginesOwnMotionMonitorIsWired() {
        let rig = makeRig()
        arm(rig)
        let motion = rig.engine.monitorForTesting(.motion) as? MotionMonitor
        XCTAssertNotNil(motion, "the engine built a motion monitor")
        motion?.onStall?(1)
        XCTAssertEqual(motionRecords(rig), ["motionStalled"])
        rig.engine.disarm()
    }

    // MARK: - The record

    /// The record reads as a plain sentence in the log.
    func testTheRecordReadsAsAPlainSentence() {
        XCTAssertEqual(stateEvent("motionStalled").sensorSummary,
                       "Motion tripwire stalled and was restarted: a few seconds were not watched")
    }

    /// The record has the Motion tripwire's own icon in the log, one iOS has.
    func testTheRecordHasTheMotionIconInTheLog() {
        let icon = EventRow.placeholderIcon(for: "motionStalled")
        XCTAssertEqual(icon, SensorType.motion.iconName, "the Motion tripwire's own symbol")
        XCTAssertNotNil(UIImage(systemName: icon), "an SF Symbol this iOS has")
    }

    /// The owner's other devices read the record back from iCloud.
    func testTheOwnersOtherDevicesReadTheRecordBack() {
        let record = CloudExfiltrator.makeStateRecord(stateEvent("motionStalled"), kind: "motionStalled", deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "motionStalled")
    }

    /// No alert anywhere: iCloud sends no disarm alert for it, and the watch relay sends nothing.
    func testTheRecordRaisesNoAlertOnAnotherDeviceOrTheWatch() {
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "motionStalled"), "no disarm alert through iCloud")
        XCTAssertTrue(WatchAlertRelay.alerts(for: [stateEvent("motionStalled")], alertsOn: true, proActive: true).isEmpty,
                      "nothing relayed to the watch")
    }
}
