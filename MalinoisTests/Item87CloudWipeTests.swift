//
//  Item87CloudWipeTests.swift
//  MalinoisTests
//
//  Tests for BACKLOG 87, ruled "all as recommended" on 2026-09-28. "Delete Data from iCloud" in iOS
//  Settings needs only the unlocked phone outside Guided Access (item 64), and afterwards this
//  phone's records still read synced while iCloud holds only what was sent since: nothing noticed.
//  At each launch pull the app now looks for its newest synced records in iCloud by name. When most
//  are gone it uploads them again and says so on Home, but only when the phone is still signed into
//  the account they went to (remembered at the first check that found them all); otherwise it says
//  so and nothing goes up to another account. iCloud itself cannot run in the Simulator, so the
//  launch check is driven through the engine's test stand-ins. The test of records under 1.0's
//  names (a follow-up found by Claude's review of item 87 the same night) was written before its
//  fix and was red at that commit.
//

import XCTest
@testable import Malinois

@MainActor
final class Item87CloudWipeTests: XCTestCase {

    nonisolated private static let accountKey = "com.malinois.cloud.accountRecordName"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem87")
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func record(minutesAgo: Double, state: String? = nil, mirrored: Bool = false, synced: Bool = true) -> Event {
        let at = Date().addingTimeInterval(-minutesAgo * 60)
        return Event(startDate: at, endDate: at, triggeredSensors: state == nil ? [.touch] : [],
                     cloudSyncState: synced ? .synced : .pending, stateChange: state,
                     sourceDevice: mirrored ? "iPhone Air" : nil)
    }

    private func makeEngine(store: EventStore) -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                             camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                             timing: EngineCharacterizationTests.fastTiming))
    }

    private func syncState(_ store: EventStore, _ event: Event) -> CloudSyncState? {
        store.events.first { $0.id == event.id }?.cloudSyncState
    }

    // MARK: - The rules

    /// The check looks for this phone's own newest synced records: never a mirror (the capturing
    /// device owns it) and never a record that has not gone up yet.
    func testTheCheckLooksForTheNewestFirstHandSyncedRecords() {
        let mine = (1...25).map { record(minutesAgo: Double($0)) }
        let mirror = record(minutesAgo: 0.5, mirrored: true)
        let pending = record(minutesAgo: 0.2, synced: false)
        let sample = MonitoringEngine.cloudCheckSample([pending, mirror] + mine.reversed(), limit: 20)
        XCTAssertEqual(sample.map(\.id), mine.prefix(20).map(\.id), "the 20 newest, newest first")
    }

    /// The names looked for are the names the app saves under.
    func testTheNamesAreTheOnesTheAppWrites() {
        let tamper = record(minutesAgo: 1)
        let audit = record(minutesAgo: 1, state: "disarmed")
        XCTAssertEqual(CloudExfiltrator.cloudRecordName(for: tamper),
                       CloudExfiltrator.makeMetaRecord(tamper, deviceName: "x", thumbnailURL: nil).recordID.recordName)
        XCTAssertEqual(CloudExfiltrator.cloudRecordName(for: audit),
                       CloudExfiltrator.makeStateRecord(audit, kind: "disarmed", deviceName: "x").recordID.recordName)
    }

    /// Evidence is looked for under its own name and 1.0's; an audit record only under its own
    /// (1.0 uploaded none).
    func testEvidenceIsAlsoLookedForUnderItsFirstName() {
        let tamper = record(minutesAgo: 1)
        let audit = record(minutesAgo: 1, state: "disarmed")
        XCTAssertEqual(CloudExfiltrator.cloudRecordNames(for: tamper),
                       ["meta-v2-" + tamper.id.uuidString, "meta-" + tamper.id.uuidString])
        XCTAssertEqual(CloudExfiltrator.cloudRecordNames(for: audit), ["state-v2-" + audit.id.uuidString])
    }

    /// Most missing is a wipe; a single missing record never is.
    func testOneMissingRecordIsNotAWipe() {
        XCTAssertFalse(MonitoringEngine.cloudCopiesDeleted(sampled: 20, missing: 1))
        XCTAssertFalse(MonitoringEngine.cloudCopiesDeleted(sampled: 20, missing: 10), "half is not most")
        XCTAssertTrue(MonitoringEngine.cloudCopiesDeleted(sampled: 20, missing: 11))
        XCTAssertTrue(MonitoringEngine.cloudCopiesDeleted(sampled: 3, missing: 2))
        XCTAssertFalse(MonitoringEngine.cloudCopiesDeleted(sampled: 1, missing: 1), "never a single one")
    }

    /// The upload goes back only to the account the records went to.
    func testTheAccountDecides() {
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(storedAccount: "A", currentAccount: "A"), .reupload)
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(storedAccount: "A", currentAccount: "B"), .differentAccount)
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(storedAccount: nil, currentAccount: "A"), .unknownAccount)
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(storedAccount: "A", currentAccount: nil), .unknownAccount)
    }

    // MARK: - The launch check

    /// The same account and most records gone: this phone's records go back up (pending again),
    /// another phone's mirror is left alone, and Home says so.
    func testDeletedCopiesGoBackUpWhenTheAccountIsTheSame() async {
        UserDefaults.standard.set("owner", forKey: Self.accountKey)
        let store = EventStore()
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        let mirror = record(minutesAgo: 10, mirrored: true)
        for event in [mirror] + mine.reversed() { store.add(event) }
        let engine = makeEngine(store: store)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .pending, "uploaded again") }
        XCTAssertEqual(syncState(store, mirror), .synced, "another phone's record is its to upload")
        XCTAssertNotNil(engine.cloudResetNotice, "Home says so")
    }

    /// Another account: nothing goes up to it, and Home says why.
    func testNothingGoesUpToADifferentAccount() async {
        UserDefaults.standard.set("owner", forKey: Self.accountKey)
        let store = EventStore()
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        for event in mine { store.add(event) }
        let engine = makeEngine(store: store)
        engine.cloudAccountForTesting = "someone else"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .synced, "nothing requeued") }
        XCTAssertNotNil(engine.cloudResetNotice, "Home says why")
    }

    /// Everything in place: the account is remembered the first time, and nothing is said.
    func testTheAccountIsRememberedWhenEverythingIsInPlace() async {
        let store = EventStore()
        for event in (1...5).map({ record(minutesAgo: Double($0)) }) { store.add(event) }
        let engine = makeEngine(store: store)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { names in Set(names) }
        await engine.checkCloudCopies()
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.accountKey), "owner")
        XCTAssertNil(engine.cloudResetNotice)
    }

    /// A phone whose newest synced records went up under 1.0 holds them in iCloud under 1.0's names
    /// (`meta-<id>`; 1.1 moved to `meta-v2-` and renamed nothing already there). They are in place:
    /// no deletion is reported, and the account is remembered.
    func testRecordsUnderTheirFirstNamesAreInPlace() async {
        let store = EventStore()
        for event in (1...5).map({ record(minutesAgo: Double($0)) }) { store.add(event) }
        let engine = makeEngine(store: store)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { names in Set(names.filter { !$0.contains("-v2-") }) }   // only 1.0's names
        await engine.checkCloudCopies()
        XCTAssertNil(engine.cloudResetNotice, "records under 1.0's names are in place")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Self.accountKey), "owner")
    }

    /// No conclusive answer (no account, a network error) changes nothing.
    func testAnInconclusiveCheckChangesNothing() async {
        UserDefaults.standard.set("owner", forKey: Self.accountKey)
        let store = EventStore()
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        for event in mine { store.add(event) }
        let engine = makeEngine(store: store)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in nil }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .synced) }
        XCTAssertNil(engine.cloudResetNotice)
    }
}
