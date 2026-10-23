//
//  Item152WalkAwayTests.swift
//  MalinoisTests
//
//  BACKLOG 152's hardening note (b), item 145 step 14 (ADR 0050 amended, decision 8; the owner's option A). The
//  arming flow held auto-lock in every state but disarmed, and "Before you arm" never timed out, so an owner who
//  tapped Start countdown and set the phone down left it unlocked, unarmed and awake, on a screen 1.8.1 shows once
//  to every install. Now, while the screen shows, the arming flow does not hold auto-lock (the phone may sleep as on
//  Home; under Guided Access item 92's screen hold applies as on Home), and a minute without a touch cancels the arm
//  back to Home, disarmed, with the parts still due; a touch restarts the minute, and "I understand" still starts
//  the countdown. Written before the change, red at that commit (against compile-only stubs).
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item152WalkAwayTests: XCTestCase {

    nonisolated private static let ackKeys = ["com.malinois.onboarding.acknowledgedDisarmBriefing",
                                              "com.malinois.onboarding.acknowledgedGuidedAccessBriefing",
                                              "com.malinois.onboarding.acknowledgedVoiceControlBriefing"]
    /// The simulator's own acknowledgments, put back after each test.
    nonisolated(unsafe) private var savedAcks: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152WalkAway")
        for key in Self.ackKeys {
            savedAcks[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)   // a new install: every part due
        }
    }

    override func tearDown() {
        for key in Self.ackKeys {
            if let value = savedAcks[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        TestIsolation.tearDown()
        super.tearDown()
    }

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    /// An engine whose screen waits `timeout` seconds without a touch, with every part of the screen due.
    private func makeRig(timeout: TimeInterval = 60) -> Rig {
        var timing = EngineCharacterizationTests.fastTiming
        timing.firstArmBriefingTimeout = timeout
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        return Rig(engine: engine, store: store)
    }

    /// Start countdown on a new install: the screen shows and the countdown waits.
    private func showTheScreen(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck, "the countdown waits for the screen", file: file, line: line)
        XCTAssertNotNil(rig.engine.firstArmBriefing, "the screen shows", file: file, line: line)
    }

    private func acknowledgedAny() -> Bool {
        Self.ackKeys.contains { UserDefaults.standard.bool(forKey: $0) }
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - Auto-lock

    /// The rule: while the screen shows, the arming flow's hold on auto-lock is off; every other state keeps its hold,
    /// and item 92's Guided Access screen hold still applies, as on Home. Then the live flag through the real flow.
    func testTheScreenDoesNotHoldAutoLock() {
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.guidedAccessCheck), "the Guided Access step holds, as before")
        XCTAssertFalse(MonitoringEngine.keepsDeviceAwake(.guidedAccessCheck, briefingShowing: true),
                       "the screen does not: the phone may sleep, as on Home")
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.guidedAccessCheck, guidedAccessOn: true, holdRunning: true,
                                                        briefingShowing: true),
                      "under Guided Access item 92's screen hold applies, as on Home")
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.arming, briefingShowing: false))
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.armed))
        XCTAssertFalse(MonitoringEngine.keepsDeviceAwake(.disarmed))

        let rig = makeRig()
        showTheScreen(rig)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "auto-lock is handed back while the screen shows")
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "the countdown holds it, as before")
        rig.engine.cancelArming()
    }

    // MARK: - The minute

    /// A minute (here a fraction of a second) without a touch cancels the arm back to Home, disarmed: nothing is
    /// acknowledged, so every part is still due, and nothing is recorded (the countdown never started).
    func testAMinuteWithoutATouchCancelsTheArmWithThePartsStillDue() {
        let rig = makeRig(timeout: 0.3)
        showTheScreen(rig)
        XCTAssertTrue(pump(until: { rig.engine.state == .disarmed }, timeout: 3), "cancelled back to Home")
        XCTAssertNil(rig.engine.firstArmBriefing, "the screen is gone")
        XCTAssertFalse(acknowledgedAny(), "nothing acknowledged: the parts are still due")
        XCTAssertTrue(rig.store.events.isEmpty, "no record: the countdown never started")
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertNotNil(rig.engine.firstArmBriefing, "the next arm shows it again")
        rig.engine.cancelArming()
    }

    /// A touch on the screen (a scroll, a tap) restarts the minute.
    func testATouchRestartsTheMinute() {
        let rig = makeRig(timeout: 0.4)
        showTheScreen(rig)
        settle(0.25)
        rig.engine.noteFirstArmBriefingActivity()
        settle(0.3)   // 0.55 s since the screen appeared, 0.3 s since the touch
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck, "the touch restarted the minute")
        XCTAssertNotNil(rig.engine.firstArmBriefing)
        XCTAssertTrue(pump(until: { rig.engine.state == .disarmed }, timeout: 3), "and the restarted minute runs out")
    }

    /// "I understand" still starts the countdown, and the minute is over with it: the countdown is never cancelled
    /// by a wait that ended.
    func testIUnderstandStillStartsTheCountdownAndEndsTheWait() {
        let rig = makeRig(timeout: 0.3)
        showTheScreen(rig)
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming, "I understand starts the countdown")
        XCTAssertTrue(acknowledgedAny())
        settle(0.6)
        XCTAssertEqual(rig.engine.state, .arming, "the wait ended with the screen: the countdown goes on")
        rig.engine.cancelArming()
    }

    /// The production wait is a minute (the owner's option A).
    func testTheWaitIsAMinute() {
        XCTAssertEqual(EngineTiming.production.firstArmBriefingTimeout, 60)
    }

    // MARK: - The screen

    /// The screen reports every touch to the engine, scrolls and taps alike, and the arming screen wires it so (read
    /// from their source: the harness renders screens but cannot touch them).
    func testTheScreenPassesEveryTouchToTheEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("Malinois/Views/FirstArmBriefingView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(screen.contains("DragGesture(minimumDistance: 0)") && screen.contains("onActivity()"),
                      "the screen does not report touches")
        let arming = try String(contentsOf: root.appendingPathComponent("Malinois/Views/ArmingView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(arming.range(of: "FirstArmBriefingView(parts: parts"), "the screen's presentation not found")
        let call = arming[start.upperBound...].prefix(240)
        XCTAssertTrue(call.contains("onActivity: engine.noteFirstArmBriefingActivity"), "not wired: \(call)")
    }
}
