//
//  Item152FloodAlarmTests.swift
//  MalinoisTests
//
//  BACKLOG 152's lead 5 (1.8.2's step 23; the owner's ruling (a)). With "Alarm on suspected attack" off, a sensor flood's
//  coalesced trips did not extend the running alert or siren: it went quiet one window (8 s, or 28 s for a ramped siren)
//  into the flood while the tampering went on. Coalesced trips now keep a running alarm up, as a trip during a capture
//  does; they never start one that is not running, and Stealth stays silent. With the setting on, the flood's escalation
//  already kept it up (unchanged). Written before the change, red at that commit.
//

import XCTest
@testable import Malinois

@MainActor
final class Item152FloodAlarmTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152FloodAlarm")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// The alarm's window in these tests (`alertDuration`, no siren ramp).
    private let window = EngineCharacterizationTests.fastTiming.alertDuration

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A watch armed with the given response, "Alarm on suspected attack" as given, a photo per capture, and a flood
    /// that outlasts the test; the flood threshold's trips taken and the onset tripped, its record the anchor.
    private func floodUnderWay(alarmOnSuspectedAttack: Bool, response: ResponseMode) async -> MonitoringEngine {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sustainedIdleClear = 30
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.jammingResponse = alarmOnSuspectedAttack
        settings.responseMode = response
        settings.sirenRampUp = false
        settings.captureMode = .photo
        settings.cameraPosition = .front
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
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
        engine.handleTrip(.motion)   // the onset
        let anchored = await waitFor({ engine.state == .armed && engine.liveFloodAnchorID != nil }, timeout: 3)
        XCTAssertTrue(anchored, "the flood's anchor")
        return engine
    }

    /// Coalesced trips, one every quarter window, for `seconds`.
    private func keepTripping(_ engine: MonitoringEngine, for seconds: TimeInterval) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            engine.handleTrip(.motion)
            await pause(window / 4)
        }
    }

    // MARK: - Lead 5

    /// The setting off: the alarm the onset raised stays up while the flood goes on, and fades once the trips stop.
    func testCoalescedFloodTripsKeepARunningAlarmUp() async {
        let engine = await floodUnderWay(alarmOnSuspectedAttack: false, response: .alert)
        engine.handleTrip(.motion)   // coalesced
        XCTAssertTrue(engine.alertActive, "the alarm is up")
        await keepTripping(engine, for: window * 4)
        XCTAssertTrue(engine.alertActive, "still up while the flood goes on")
        let faded = await waitFor({ !engine.alertActive }, timeout: window * 4)
        XCTAssertTrue(faded, "it fades once the trips stop")
        engine.disarm()
    }

    /// A coalesced trip extends a running alarm only: once it has faded, another does not start it again (the
    /// owner's ruling: "they extend the running alarm").
    func testACoalescedTripDoesNotRestartAFadedAlarm() async {
        let engine = await floodUnderWay(alarmOnSuspectedAttack: false, response: .alert)
        let faded = await waitFor({ !engine.alertActive }, timeout: window * 4)
        XCTAssertTrue(faded, "faded with no trip")
        engine.handleTrip(.motion)   // coalesced
        await pause(window / 2)
        XCTAssertFalse(engine.alertActive, "not started again")
        engine.disarm()
    }

    /// Control: Stealth raises no alarm, and coalesced trips start none.
    func testStealthStaysSilentThroughAFlood() async {
        let engine = await floodUnderWay(alarmOnSuspectedAttack: false, response: .stealth)
        await keepTripping(engine, for: window * 2)
        XCTAssertFalse(engine.alertActive, "Stealth: no alarm")
        engine.disarm()
    }

    /// Control: with "Alarm on suspected attack" on, the flood's escalation already kept the warning up (unchanged).
    func testWithTheSettingOnTheEscalationKeepsItUp() async {
        let engine = await floodUnderWay(alarmOnSuspectedAttack: true, response: .alert)
        await keepTripping(engine, for: window * 4)
        XCTAssertTrue(engine.alertActive, "kept up by the flood's escalation")
        engine.disarm()
    }
}
