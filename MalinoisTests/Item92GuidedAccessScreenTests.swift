//
//  Item92GuidedAccessScreenTests.swift
//  MalinoisTests
//
//  BACKLOG 92 (the owner's report and ruling, 2026-09-29). Malinois kept the screen on from the
//  ARM tap to the disarm, and let iOS's auto-lock run at every other moment. Disarmed under
//  Guided Access, iOS can wake a phone that slept into a stuck notification screen that only
//  ending Guided Access clears (README, Known iOS quirks): the owner met it with Guided Access on
//  and the phone stood up, unplugged. Now, disarmed under Guided Access, the screen also
//  stays on for `EngineTiming.guidedAccessScreenHold` (ten minutes) after Guided Access starts, a
//  disarm or a cancelled countdown, and the app's return to the screen; after that, and whenever
//  Guided Access is off, the phone sleeps as before. Guided Access is driven through a Debug
//  stand-in, since the simulator cannot start a session.
//

import XCTest
import UIKit
@testable import Malinois

@MainActor
final class Item92GuidedAccessScreenTests: XCTestCase {

    /// Used by the test and tearDown, which XCTest runs one after the other on the main thread;
    /// tearDown is not main-actor isolated, so this is not either (item 97).
    nonisolated(unsafe) private var engines: [MonitoringEngine] = []

    // XCTest's setUp and tearDown are not main-actor isolated but run on the main thread (item 97).
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem92")
        MainActor.assumeIsolated { UIApplication.shared.isIdleTimerDisabled = false }
    }

    override func tearDown() {
        // Guided Access off first, so the disarms in the shared tearDown leave no hold running.
        let engines = self.engines
        MainActor.assumeIsolated { for engine in engines { engine.simulateGuidedAccessForTesting(on: false) } }
        self.engines.removeAll()
        TestIsolation.tearDown()
        MainActor.assumeIsolated { UIApplication.shared.isIdleTimerDisabled = false }
        super.tearDown()
    }

    /// Whether the app holds the screen on: the flag iOS's auto-lock reads.
    private var screenHeldOn: Bool { UIApplication.shared.isIdleTimerDisabled }

    /// A disarmed engine on this test's store, its screen hold `hold` seconds long.
    private func makeEngine(hold: TimeInterval = 600) -> MonitoringEngine {
        var timing = EngineCharacterizationTests.fastTiming
        timing.guidedAccessScreenHold = hold
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: timing))
        engines.append(engine)
        return engine
    }

    /// Arms `engine` through the countdown (0 s), calibration and the review.
    private func arm(_ engine: MonitoringEngine, file: StaticString = #filePath, line: UInt = #line) {
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        spin(until: { engine.state == .armed }, timeout: 5)
        XCTAssertEqual(engine.state, .armed, "grace 0 + calibration + review reach .armed", file: file, line: line)
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes.
    private func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - The rule

    /// Disarmed under Guided Access, the screen stays on while the hold runs.
    func testDisarmedUnderGuidedAccessStaysAwakeWhileTheHoldRuns() {
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.disarmed, guidedAccessOn: true, holdRunning: true))
    }

    /// Disarmed, the phone sleeps as it always has once the hold is over, and with Guided Access
    /// off whatever the hold says.
    func testDisarmedSleepsOnceTheHoldIsOverAndWithoutGuidedAccess() {
        XCTAssertFalse(MonitoringEngine.keepsDeviceAwake(.disarmed, guidedAccessOn: true, holdRunning: false),
                       "the hold is over")
        XCTAssertFalse(MonitoringEngine.keepsDeviceAwake(.disarmed, guidedAccessOn: false, holdRunning: true),
                       "no hold without Guided Access")
        XCTAssertFalse(MonitoringEngine.keepsDeviceAwake(.disarmed))
    }

    /// From the ARM tap to the disarm the screen stays on, whatever Guided Access and the hold say.
    func testEveryOtherStateStaysAwakeWhateverTheHold() {
        for state in [MonitoringState.guidedAccessCheck, .arming, .calibrating, .armed, .triggered] {
            for (on, hold) in [(false, false), (true, false), (false, true), (true, true)] {
                XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(state, guidedAccessOn: on, holdRunning: hold),
                              "\(state), Guided Access \(on), hold \(hold)")
            }
        }
    }

    // MARK: - The engine

    /// Guided Access started on the Home screen, before ARM: the screen stays on.
    func testGuidedAccessStartedBeforeArmingHoldsTheScreenOn() {
        let engine = makeEngine()
        engine.simulateGuidedAccessForTesting(on: true)
        XCTAssertTrue(screenHeldOn)
    }

    /// The hold ends by itself, and the phone may sleep again.
    func testTheHoldEndsAfterItsTime() {
        let engine = makeEngine(hold: 0.3)
        engine.simulateGuidedAccessForTesting(on: true)
        XCTAssertTrue(screenHeldOn, "held at the start")
        spin(until: { !self.screenHeldOn }, timeout: 3)
        XCTAssertFalse(screenHeldOn, "released when the hold is over")
    }

    /// Ending Guided Access ends the hold at once: without it, the stuck screen cannot happen.
    func testEndingGuidedAccessReleasesTheScreenAtOnce() {
        let engine = makeEngine()
        engine.simulateGuidedAccessForTesting(on: true)
        XCTAssertTrue(screenHeldOn, "held while Guided Access is on")
        engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertFalse(screenHeldOn)
    }

    /// A disarm under Guided Access holds the screen on, then lets it sleep.
    func testADisarmUnderGuidedAccessHoldsTheScreenOn() {
        let engine = makeEngine(hold: 0.3)
        engine.simulateGuidedAccessForTesting(on: true)
        arm(engine)
        engine.disarm()
        XCTAssertEqual(engine.state, .disarmed)
        XCTAssertTrue(screenHeldOn, "held after the disarm")
        spin(until: { !self.screenHeldOn }, timeout: 3)
        XCTAssertFalse(screenHeldOn, "released when the hold is over")
    }

    /// A countdown cancelled under Guided Access holds the screen on too.
    func testACancelledArmingUnderGuidedAccessHoldsTheScreenOn() {
        let engine = makeEngine()
        engine.simulateGuidedAccessForTesting(on: true)
        engine.beginArming()
        XCTAssertEqual(engine.state, .guidedAccessCheck)
        engine.cancelArming()
        XCTAssertEqual(engine.state, .disarmed)
        XCTAssertTrue(screenHeldOn)
    }

    /// Without Guided Access a disarm lets the phone sleep at once, as it always has.
    func testADisarmWithoutGuidedAccessReleasesTheScreen() {
        let engine = makeEngine()
        arm(engine)
        XCTAssertTrue(screenHeldOn, "armed")
        engine.disarm()
        XCTAssertFalse(screenHeldOn)
    }

    /// Back on screen disarmed under Guided Access (woken after a sleep, or launched into a
    /// session), the hold starts again.
    func testComingBackOnScreenUnderGuidedAccessStartsTheHoldAgain() {
        let engine = makeEngine(hold: 0.3)
        engine.simulateGuidedAccessForTesting(on: true)
        spin(until: { !self.screenHeldOn }, timeout: 3)
        engine.handleScenePhase(true)
        XCTAssertTrue(screenHeldOn)
    }

    /// Back on screen without Guided Access, nothing is held.
    func testComingBackOnScreenWithoutGuidedAccessHoldsNothing() {
        let engine = makeEngine()
        engine.handleScenePhase(true)
        XCTAssertFalse(screenHeldOn)
    }

    /// The hold running out while the owner is on the arming screen leaves the arming flow's own
    /// hold in place.
    func testTheHoldEndingDuringArmingKeepsTheScreenOn() {
        let engine = makeEngine(hold: 0.2)
        engine.simulateGuidedAccessForTesting(on: true)
        engine.beginArming()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // past the hold's end
        XCTAssertEqual(engine.state, .guidedAccessCheck)
        XCTAssertTrue(screenHeldOn)
    }
}
