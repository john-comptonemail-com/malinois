//
//  Item83TouchAlwaysOnTests.swift
//  MalinoisTests
//
//  BACKLOG 83 (owner ruling 2026-09-26, "go with option 1"): the Touch tripwire is always on.
//  Nothing benign touches the armed screen, and Touch is what photographs whoever opens the
//  disarm pad — with it switchable, a PIN holder could turn it off and disarm unphotographed
//  (item 73, R5). Written before the change, red at that commit: the rule itself, the three
//  places it holds (a change, a load, the arm), and the Test Sensors pad.
//

import XCTest
@testable import Malinois

@MainActor
final class Item83TouchAlwaysOnTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem83")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// The rule: Touch joins any set, and nothing else in the set changes.
    func testTheRuleAddsTouchAndKeepsTheRest() {
        XCTAssertEqual(AppSettings.withTouch([.motion, .audio]), [.motion, .audio, .touch])
        XCTAssertEqual(AppSettings.withTouch([]), [.touch])
        XCTAssertEqual(AppSettings.withTouch([.touch, .power]), [.touch, .power], "already there: unchanged")
    }

    /// Whatever is assigned — a switch, a stale caller, a test — the settings keep Touch.
    func testTouchCannotBeSwitchedOff() {
        let s = AppSettings()
        s.enabledSensors.remove(.touch)
        XCTAssertTrue(s.isEnabled(.touch), "removing it leaves it on")
        s.enabledSensors = [.motion]
        XCTAssertEqual(s.enabledSensors, [.motion, .touch], "replacing the set keeps it too")
    }

    /// An install that switched Touch off before this build gets it back once, at the update:
    /// a save without Touch loads with Touch.
    func testASaveWithTouchOffLoadsWithTouchOn() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var blob = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        blob["enabledSensors"] = ["motion", "power"]   // as a build with the switch saved it
        let loaded = try JSONDecoder().decode(AppSettings.self,
                                              from: JSONSerialization.data(withJSONObject: blob))
        XCTAssertTrue(loaded.isEnabled(.touch))
        XCTAssertEqual(loaded.enabledSensors, [.motion, .power, .touch], "and nothing else changes")
    }

    /// At arm, belt and braces (ADR 0012's pattern): the set the engine runs with has Touch,
    /// with or without Pro, whatever the saved set says.
    func testTheArmTimeSetAlwaysHasTouch() {
        XCTAssertTrue(AppSettings.effectiveSensors([.motion], pro: false).contains(.touch))
        XCTAssertTrue(AppSettings.effectiveSensors([.motion], pro: true).contains(.touch))
        XCTAssertEqual(AppSettings.effectiveSensors([.audio], pro: false), [.touch],
                       "a Pro-only set on the free tier still has Touch")
    }

    /// Test Sensors counts a tap on its pad whatever the saved set said about Touch.
    func testTestSensorsCountsATouchWhateverTheSavedSet() {
        let settings = AppSettings()
        settings.enabledSensors.remove(.touch)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.startDryRun()
        engine.dryRunReportTouch()
        XCTAssertEqual(engine.dryRunCounts[.touch], 1)
        engine.stopDryRun()
    }
}
