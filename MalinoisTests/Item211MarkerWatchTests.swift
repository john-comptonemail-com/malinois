//
//  Item211MarkerWatchTests.swift
//  MalinoisTests
//
//  BACKLOG 211 (the owner, 2026-11-06: "yes to 211 in 1.12"): the log-full line ("Events not fully backed up to iCloud
//  were removed to make room") is meant to come once per watch. The engine knows the watch by comparing its start with
//  the start it kept in UserDefaults beside the last line, and it keeps that start as seconds since 1970. About half of
//  all starts come back from that a fraction of a microsecond off, so in those watches the two never compared equal and
//  every removal wrote a line (the iPhone Air's log, 2026-11-06: eight in one 13-second watch). Written before the fix,
//  red at that commit: the tests go through the stored property, with a start that does not survive the round trip.
//

import XCTest
@testable import Malinois

@MainActor
final class Item211MarkerWatchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem211Marker")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// Two removals in one watch, whose start comes back changed from storage: one line, not two.
    func testTwoRemovalsInOneWatchWriteOneLine() async {
        let watch = Self.startThatDoesNotSurvive()
        XCTAssertNotEqual(Self.roundTrip(watch), watch, "the test needs a start that does not survive the round trip")
        let rig = await makeProRig()
        let one = rig.incident(), two = rig.incident()
        rig.engine.noteCountEviction([one], inWatch: watch)
        rig.engine.noteCountEviction([two], inWatch: watch)
        XCTAssertEqual(markers(rig.store), 1, "one line per watch, however its start comes back from storage")
    }

    /// The last line, read back from storage, still counts for the watch it was written in.
    func testTheStoredLineStillCountsForItsWatch() async {
        let watch = Self.startThatDoesNotSurvive(), now = watch.addingTimeInterval(60)
        XCTAssertNotEqual(Self.roundTrip(watch), watch, "the test needs a start that does not survive the round trip")
        let rig = await makeProRig()
        rig.engine.lastUnsyncedRemovalMarker = (now, watch)
        XCTAssertFalse(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: rig.engine.lastUnsyncedRemovalMarker,
                                                                   armedSince: watch, now: now.addingTimeInterval(1)),
                       "the same watch, read back from storage")
    }

    /// A guard, green before the fix and after: another watch still gets its line, even one that started a second after
    /// the last line's watch, and a line written while disarmed does not count for a watch.
    func testAnotherWatchStillGetsItsLine() {
        let watch = Self.startThatDoesNotSurvive(), now = watch.addingTimeInterval(60)
        XCTAssertTrue(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now, watch), armedSince: watch.addingTimeInterval(1),
                                                                  now: now.addingTimeInterval(1)),
                      "a watch that started a second later is another watch")
        XCTAssertTrue(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now, nil), armedSince: watch, now: now.addingTimeInterval(1)),
                      "a line written while disarmed does not count for a watch")
    }

    // MARK: - Helpers

    /// A start as the stored property keeps it and reads it back: seconds since 1970.
    private static func roundTrip(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970) }

    /// A watch start near now that comes back changed from the round trip, as about half of all starts do (a probe of
    /// 200,000 random times of 2026: 100,149 changed). `distantPast`, which survives it, only if none of a thousand does.
    private static func startThatDoesNotSurvive() -> Date {
        let base = Date().timeIntervalSinceReferenceDate
        return (0..<1_000).lazy.map { Date(timeIntervalSinceReferenceDate: base + Double($0) * 0.000_123_7) }
            .first { roundTrip($0) != $0 } ?? .distantPast
    }

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let gate: CloudEnrollment

        /// A record this phone was meant to upload: registered to the verified account, as every local event is.
        @MainActor func incident() -> Event {
            let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
            gate.registerLocalEvent(event)
            return event
        }
    }

    /// A Pro engine whose removed records count as missed uploads (item 114's rig).
    private func makeProRig() async -> Rig {
        let gate = CloudEnrollment(file: (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: gate),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        return Rig(engine: engine, store: store, gate: gate)
    }

    private func markers(_ store: EventStore) -> Int {
        store.events.filter { $0.stateChange == "unsyncedRemoved" }.count
    }
}
