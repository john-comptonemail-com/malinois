//
//  Item148SweepOrderTests.swift
//  MalinoisTests
//
//  BACKLOG 148 (a reviewer's Tier 2 point, 2026-10-21; the owner's "do the small items"): after an outage the pending
//  sweep handed records out newest first, incidents and status entries alike. Now incidents (interruption records
//  included) go before status entries, so the evidence goes up before the bookkeeping; within each group the order
//  given (the store's, newest first) is kept, and nothing is dropped or doubled.
//

import XCTest
@testable import Malinois

final class Item148SweepOrderTests: XCTestCase {

    private func event(secondsAgo: TimeInterval, status: String? = nil, interrupted: Bool? = nil) -> Event {
        let at = Date().addingTimeInterval(-secondsAgo)
        return Event(startDate: at, endDate: at, triggeredSensors: status == nil && interrupted == nil ? [.motion] : [],
                     cloudSyncState: .pending, interrupted: interrupted, stateChange: status)
    }

    /// Incidents first, then status entries, each group in the order given.
    func testIncidentsGoBeforeStatusEntriesInTheOrderGiven() {
        let newestStatus = event(secondsAgo: 10, status: "armed")
        let incident = event(secondsAgo: 20)
        let olderStatus = event(secondsAgo: 30, status: "disarmed")
        let interruption = event(secondsAgo: 40, interrupted: true)
        let ordered = MonitoringEngine.sweepOrder([newestStatus, incident, olderStatus, interruption])
        XCTAssertEqual(ordered.map(\.id), [incident.id, interruption.id, newestStatus.id, olderStatus.id],
                       "incidents and interruptions before status entries, newest first within each")
    }

    /// Nothing is dropped or doubled, whatever the mix.
    func testTheOrderKeepsEveryRecordOnce() {
        let records = (0..<6).map { event(secondsAgo: Double($0 * 10), status: $0 % 2 == 0 ? "armed" : nil) }
        let ordered = MonitoringEngine.sweepOrder(records)
        XCTAssertEqual(ordered.count, records.count)
        XCTAssertEqual(Set(ordered.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(ordered.prefix(3).map(\.isStateChange), [false, false, false], "the incidents lead")
    }
}
