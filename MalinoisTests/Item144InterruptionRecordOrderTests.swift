//
//  Item144InterruptionRecordOrderTests.swift
//  MalinoisTests
//
//  BACKLOG 144 (d), a reader's L (2026-10-21; the owner's "approved"): when an active session was sent to the
//  background, the flag that keeps the next launch from recording the same lapse twice was made durable BEFORE the
//  interruption record itself, so a kill between the two statements left the flag and no record, and the next launch
//  then dropped its own record too. Now the record is journaled first and the flag set after it: a kill in between
//  gives a second record, never none. Driven through a real engine: the store's publication of the interruption
//  record is observed, and the flag must not be set at that moment.
//

import Combine
import XCTest
@testable import Malinois

@MainActor
final class Item144InterruptionRecordOrderTests: XCTestCase {
    nonisolated private static let lapseKey = "com.malinois.armed.backgroundLapseLogged"   // read by the nonisolated hooks

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem144Order")
        UserDefaults.standard.removeObject(forKey: Self.lapseKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.lapseKey)
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// The interruption record reaches the store before the lapse flag is set.
    func testTheInterruptionRecordIsWrittenBeforeTheLapseFlag() {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.state == .armed }, timeout: 5), "grace 0 + calibration + review reach .armed")

        var flagWhenTheRecordAppeared: Bool?
        let subscription = store.$events.sink { events in
            guard flagWhenTheRecordAppeared == nil, events.contains(where: { $0.interrupted == true }) else { return }
            flagWhenTheRecordAppeared = UserDefaults.standard.bool(forKey: Self.lapseKey)
        }
        defer { subscription.cancel() }
        engine.handleEnteredBackground()
        XCTAssertEqual(flagWhenTheRecordAppeared, false, "the record is on the record before the flag is set")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.lapseKey), "and the flag follows it")
        XCTAssertTrue(store.events.contains { $0.interrupted == true }, "the lapse leaves its record")
        engine.disarm()
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
