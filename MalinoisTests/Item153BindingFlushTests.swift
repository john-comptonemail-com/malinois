//
//  Item153BindingFlushTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-07 (1.8.2's step 18). Each event's account binding (`registerLocalEvent`) is written before its
//  journal line, but only the journal's append was synced to the storage medium (`F_FULLFSYNC`): the binding's atomic
//  write could sit in the OS's caches, so a forced restart within seconds of a trip could keep the line and lose the
//  binding, and the recovered event was then held as unknown account. The enrollment's file is now synced as the
//  journal is, before the write returns. The Simulator cannot cut power; the reviewer's T7 checks it on a device (a
//  trip, then a forced restart within seconds, repeated). Written before the change, red at that commit.
//

import XCTest
@testable import Malinois

@MainActor
final class Item153BindingFlushTests: XCTestCase {

    // Set in setUp and removed in tearDown, which XCTest runs without main-actor isolation (item 97).
    nonisolated(unsafe) private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Flush")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem153Flush-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func record() -> Event { Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]) }

    /// Every write of the enrollment's file reaches the medium before it returns: the binding of an event, and the
    /// verification itself.
    func testTheBindingIsSyncedToTheMedium() async throws {
        let enrollment = CloudEnrollment(file: directory.appendingPathComponent("enrollment.json"),
                                         authenticate: { _ in true })
        let start = CloudEnrollment.fullSyncsForTesting
        let verified = await enrollment.enroll(account: "owner", resolve: { "owner" })
        try XCTSkipUnless(verified, "the enrollment could not be written")
        XCTAssertEqual(CloudEnrollment.fullSyncsForTesting, start + 1, "the verification's write was synced")
        enrollment.registerLocalEvent(record())
        XCTAssertEqual(CloudEnrollment.fullSyncsForTesting, start + 2, "the binding's write was synced")
    }

    /// The real path: a trip binds its event and journals it; the binding reached the medium before the journal's
    /// line did, as the order of the two calls on every path puts it.
    func testATripsBindingIsSyncedBeforeItsJournalLine() {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.captureMode = .photo
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.state == .armed }, timeout: 5), "armed")
        let syncsBefore = CloudEnrollment.fullSyncsForTesting
        let journalBefore = store.journalFullSyncsForTesting
        var syncsWhenJournaled: Int?
        store.journalSyncObserverForTesting = { syncsWhenJournaled = CloudEnrollment.fullSyncsForTesting }
        engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { store.journalFullSyncsForTesting > journalBefore }, timeout: 2),
                      "the trip's line was journaled")
        XCTAssertNotNil(syncsWhenJournaled, "the line's sync was seen")
        XCTAssertGreaterThan(syncsWhenJournaled ?? syncsBefore, syncsBefore, "its binding was on the medium first")
        engine.disarm()
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}
