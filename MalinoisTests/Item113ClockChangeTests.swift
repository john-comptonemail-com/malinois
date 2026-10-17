//
//  Item113ClockChangeTests.swift
//  MalinoisTests
//
//  BACKLOG 113 (from item 108, F4; the owner: records only while armed, a one-minute threshold).
//  Nothing noticed a changed clock, which moves event times, the log's order, the armed timer and
//  the late-disarm rule. Now, while a watch is live, a jump of the device clock by a minute or more
//  against the time actually elapsed leaves a quiet status entry ("Device clock moved forward 2 h
//  14 min while armed"): never an alarm or a cross-device alert, uploaded like the heat warnings,
//  and read back by other devices. Written before the change, red at that commit (against
//  compile-only stubs).
//

import XCTest
import CloudKit
import UIKit
@testable import Malinois

@MainActor
final class Item113ClockChangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem113Clock")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The rule

    /// A jump counts at a minute or more, either way, in whole seconds.
    func testAJumpCountsFromOneMinuteEitherWay() {
        XCTAssertEqual(ClockWatch.jump(wallElapsed: 100, steadyElapsed: 40), 60)
        XCTAssertNil(ClockWatch.jump(wallElapsed: 100, steadyElapsed: 41), "59 s is below the threshold")
        XCTAssertEqual(ClockWatch.jump(wallElapsed: 0, steadyElapsed: 3_600), -3_600, "moved back an hour")
        XCTAssertEqual(ClockWatch.jump(wallElapsed: 8_050, steadyElapsed: 10), 8_040)
        XCTAssertNil(ClockWatch.jump(wallElapsed: 30, steadyElapsed: 30), "no change")
    }

    /// The watch compares the clock with the steady clock, reports a jump once, starts each
    /// measurement afresh, and stops at the disarm.
    func testTheWatchReportsAJumpOnceAndStopsAtTheDisarm() {
        var wall = Date(timeIntervalSince1970: 1_000_000)
        var steady = ContinuousClock.now
        let watch = ClockWatch(wallNow: { wall }, steadyNow: { steady })
        var jumps: [Int] = []
        watch.start { jumps.append($0) }
        XCTAssertTrue(watch.isRunning)

        wall += 10; steady += .seconds(10)
        watch.check()
        XCTAssertEqual(jumps, [], "the clock kept time")

        wall += 7_200
        watch.check()
        XCTAssertEqual(jumps, [7_200], "moved forward two hours")

        watch.check()
        XCTAssertEqual(jumps, [7_200], "measured afresh from the jump: nothing new")

        watch.stop()
        XCTAssertFalse(watch.isRunning)
        wall -= 3_600
        watch.check()
        XCTAssertEqual(jumps, [7_200], "nothing after the disarm")
    }

    /// Returning to the app checks the clock too: a clock set by hand in iOS Settings, while Malinois
    /// was in the background, is caught when it comes back.
    func testReturningToTheAppChecksTheClock() {
        var wall = Date(timeIntervalSince1970: 1_000_000)
        let steady = ContinuousClock.now
        let watch = ClockWatch(wallNow: { wall }, steadyNow: { steady })
        var jumps: [Int] = []
        watch.start { jumps.append($0) }
        wall += 600
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while jumps.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(jumps, [600], "moved forward ten minutes while away")
        watch.stop()
    }

    /// Small corrections, each under a minute, never add up to a record.
    func testSmallCorrectionsNeverAddUp() {
        var wall = Date(timeIntervalSince1970: 1_000_000)
        let steady = ContinuousClock.now
        let watch = ClockWatch(wallNow: { wall }, steadyNow: { steady })
        var jumps: [Int] = []
        watch.start { jumps.append($0) }
        for _ in 0..<3 {
            wall += 40
            watch.check()
        }
        XCTAssertEqual(jumps, [], "three 40-second corrections are not one 2-minute jump")
    }

    // MARK: - The record

    /// The status kind carries the jump; the log words it in at most two units.
    func testTheRecordNamesTheJump() {
        XCTAssertEqual(Event.clockChangeKind(seconds: 8_040), "clockChanged.8040")
        XCTAssertEqual(Event.clockChangeKind(seconds: -180), "clockChanged.-180")
        XCTAssertEqual(stateEvent("clockChanged.8040").sensorSummary, "Device clock moved forward 2 h 14 min while armed")
        XCTAssertEqual(stateEvent("clockChanged.-180").sensorSummary, "Device clock moved back 3 min while armed")
        XCTAssertEqual(stateEvent("clockChanged.90000").sensorSummary, "Device clock moved forward 1 d 1 h while armed")
        XCTAssertEqual(stateEvent("clockChanged.7200").sensorSummary, "Device clock moved forward 2 h while armed")
        XCTAssertNil(Event.clockChangeSeconds(kind: "clockChanged.0"), "no jump is no record")
        XCTAssertNil(Event.clockChangeSeconds(kind: "clockChanged.soon"))
        XCTAssertNil(Event.clockChangeSeconds(kind: "thermalSerious"))
        XCTAssertEqual(stateEvent("clockChanged.soon").sensorSummary,
                       "Status entry this version of Malinois does not recognize", "malformed is never Signal loss")
    }

    /// Another device's log reads the record back; a malformed one is dropped.
    func testAClockRecordIsReadBackFromTheCloud() {
        let kind = "clockChanged.120"
        let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind)
        let bad = CloudExfiltrator.makeStateRecord(stateEvent("clockChanged.x"), kind: "clockChanged.x", deviceName: "iPhone Air")
        XCTAssertNil(CloudExfiltrator.stateEvent(from: bad))
    }

    // MARK: - The engine

    /// The watch runs from go-live to the disarm, and a jump during it is logged as a quiet
    /// status entry; none is logged while disarmed.
    func testTheEngineLogsAJumpOnlyWhileArmed() {
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
        engine.recordClockChange(7_200)
        XCTAssertFalse(store.events.contains { $0.stateChange?.hasPrefix("clockChanged.") == true }, "disarmed: no record")
        XCTAssertFalse(engine.clockWatch.isRunning)

        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while engine.state != .armed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(engine.state, .armed)
        XCTAssertTrue(engine.clockWatch.isRunning, "timed from go-live")

        engine.recordClockChange(7_200)
        let records = store.events.compactMap(\.stateChange).filter { $0.hasPrefix("clockChanged.") }
        XCTAssertEqual(records, ["clockChanged.7200"])
        let entry = store.events.first { $0.stateChange == "clockChanged.7200" }
        XCTAssertEqual(entry?.isStateChange, true, "a status entry, not an incident")
        XCTAssertTrue(entry?.triggeredSensors.isEmpty == true, "no tripwire")

        engine.disarm()
        XCTAssertFalse(engine.clockWatch.isRunning, "stopped at the disarm")
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }
}
