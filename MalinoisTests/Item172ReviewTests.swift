//
//  Item172ReviewTests.swift
//  MalinoisTests
//
//  Codex's look at item 171's fixes, c22341f..087d05f (BACKLOG 172; the owner: "agreed"). Two edges of step 58's
//  burst record that Codex found untested and the code already gets right (step 61), so not red first: each is shown
//  able to fail by an undo check instead.
//  - Alerts at the same instant: an equal time is not a clock moved back, so they make a burst like any others.
//  - A record in both forms (the earlier form's key left when a write's cleanup was cut short): the one value is read,
//    the earlier key ignored.
//

import XCTest
@testable import Malinois

final class Item172ReviewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Four tamper alerts at the same instant, through the record kept in defaults as an alert path keeps it: the first
    /// three tap and the fourth comes quietly. Only an arrival dated before any the record holds starts it afresh; an
    /// equal one is counted and kept.
    func testAlertsAtTheSameInstantMakeABurst() throws {
        let suite = "Item172Record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let quiet = (0..<4).map { _ -> Bool in
            let before = AlertBurst.recordArrival(at: base, defaults: defaults, key: "burst")
            return AlertBurst.arrive(base, after: before).quiet
        }
        XCTAssertEqual(quiet, [false, false, false, true])
        XCTAssertEqual(AlertBurst.record(defaults: defaults, key: "burst"),
                       AlertBurst.Record(arrivals: Array(repeating: base, count: 4), burstLast: base), "all four kept")
    }

    /// A record in both forms: the one value (one arrival, no burst running) and the earlier form's key with a burst's
    /// last ten seconds before the next alert, left when the write that replaced it was cut short before removing it.
    /// The one value is read, so the alert taps; the leftover key would have made it come quietly.
    func testARecordInBothFormsReadsTheOneValue() throws {
        let suite = "Item172Record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = AlertBurst.Record(arrivals: [base], burstLast: nil)
        AlertBurst.commit(one, defaults: defaults, key: "burst")
        defaults.set(base.addingTimeInterval(100).timeIntervalSince1970, forKey: AlertBurst.burstKey("burst"))
        let before = AlertBurst.recordArrival(at: base.addingTimeInterval(110), defaults: defaults, key: "burst")
        XCTAssertEqual(before, one, "the one value, the earlier key ignored")
        XCTAssertFalse(AlertBurst.arrive(base.addingTimeInterval(110), after: before).quiet, "the alert taps")
        XCTAssertNil(defaults.object(forKey: AlertBurst.burstKey("burst")), "the leftover key removed by the next write")
    }
}
