//
//  Item87CloudWipeTests.swift
//  MalinoisTests
//
//  Tests for BACKLOG 87, ruled "all as recommended" on 2026-09-28. "Delete Data from iCloud" in iOS
//  Settings needs only the unlocked phone outside Guided Access (item 64), and afterwards this
//  phone's records still read synced while iCloud holds only what was sent since: nothing noticed.
//  At each launch pull the app now looks for its newest synced records in iCloud by name. When most
//  are gone it uploads them again and says so on Home, but only when the phone is still signed into
//  the account they went to (since 1.8.2 the one the installation is verified for; before, the one
//  remembered at the first check that found them all); otherwise it says so and nothing goes up to
//  another account. iCloud itself cannot run in the Simulator, so the
//  launch check is driven through the engine's test stand-ins. The test of records under 1.0's
//  names (a follow-up found by Claude's review of item 87 the same night) was written before its
//  fix and was red at that commit. Item 152's lead 13 (1.8.2's step 15): the remembered account
//  missed copies deleted before any check had found them, and every copy after a deliberate
//  change of account; the tests under its heading were written before the change and were red at
//  that commit, and the launch-check tests above now verify the installation and bind its records
//  as the app does.
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

    private func makeEngine(store: EventStore, enrollment: CloudEnrollment? = nil) -> MonitoringEngine {
        let cloud = enrollment.map { CloudExfiltrator(enrollment: $0) } ?? CloudExfiltrator()
        return TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                    camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                    timing: EngineCharacterizationTests.fastTiming))
    }

    /// An installation verified for `account`, as Settings' verification leaves it (item 152's lead 13).
    private func verifiedEnrollment(_ account: String) async throws -> CloudEnrollment {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem87-" + UUID().uuidString)
            .appendingPathComponent("enrollment.json")
        let enrollment = CloudEnrollment(file: file, authenticate: { _ in true })
        let verified = await enrollment.enroll(account: account, resolve: { account })
        try XCTSkipUnless(verified, "the enrollment could not be written")
        return enrollment
    }

    /// Records the events as the engine does: bound to the installation's account as each is recorded, then logged.
    private func add(_ events: [Event], to store: EventStore, boundBy enrollment: CloudEnrollment) {
        for event in events {
            enrollment.registerLocalEvent(event)
            store.add(event)
        }
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

    /// The upload goes back only to the account the records went to: the one this installation is verified for.
    func testTheAccountDecides() {
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(enrolledAccount: "A", currentAccount: "A"), .reupload)
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(enrolledAccount: "A", currentAccount: "B"), .differentAccount)
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(enrolledAccount: nil, currentAccount: "A"), .unknownAccount)
        XCTAssertEqual(MonitoringEngine.cloudWipeResponse(enrolledAccount: "A", currentAccount: nil), .unknownAccount)
    }

    // MARK: - The launch check

    /// The same account and most records gone: this phone's records go back up (pending again),
    /// another phone's mirror is left alone, and Home says so.
    func testDeletedCopiesGoBackUpWhenTheAccountIsTheSame() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        let mirror = record(minutesAgo: 10, mirrored: true)
        add([mirror] + mine.reversed(), to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .pending, "uploaded again") }
        XCTAssertEqual(syncState(store, mirror), .synced, "another phone's record is its to upload")
        XCTAssertNotNil(engine.cloudResetNotice, "Home says so")
    }

    /// Another account: nothing goes up to it, and Home says why.
    func testNothingGoesUpToADifferentAccount() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        add(mine, to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "someone else"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .synced, "nothing requeued") }
        XCTAssertNotNil(engine.cloudResetNotice, "Home says why")
    }

    /// Everything in place: nothing is said, and since 1.8.2 nothing is remembered (the bindings' rebuild that read it
    /// holds every restored record now; codex-7).
    func testNothingIsSaidOrRememberedWhenEverythingIsInPlace() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        add((1...5).map { record(minutesAgo: Double($0)) }, to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { names in Set(names) }
        await engine.checkCloudCopies()
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.accountKey), "no account remembered")
        XCTAssertNil(engine.cloudResetNotice)
    }

    /// A phone whose newest synced records went up under 1.0 holds them in iCloud under 1.0's names
    /// (`meta-<id>`; 1.1 moved to `meta-v2-` and renamed nothing already there). They are in place:
    /// no deletion is reported.
    func testRecordsUnderTheirFirstNamesAreInPlace() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        add((1...5).map { record(minutesAgo: Double($0)) }, to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { names in Set(names.filter { !$0.contains("-v2-") }) }   // only 1.0's names
        await engine.checkCloudCopies()
        XCTAssertNil(engine.cloudResetNotice, "records under 1.0's names are in place")
    }

    /// No conclusive answer (no account, a network error) changes nothing.
    func testAnInconclusiveCheckChangesNothing() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        add(mine, to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in nil }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .synced) }
        XCTAssertNil(engine.cloudResetNotice)
    }

    // MARK: - The installation's verified account (item 152's lead 13; 1.8.2's step 15)

    /// Copies deleted before any check had found them in place: no account had been remembered, so they never went
    /// back up. The installation's verified account decides now, and the records bound to it go back up.
    func testCopiesDeletedBeforeAnyCheckGoBackUpToTheVerifiedAccount() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        let mine = (1...5).map { record(minutesAgo: Double($0)) }
        add(mine, to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in mine { XCTAssertEqual(syncState(store, event), .pending, "uploaded again") }
        XCTAssertNotNil(engine.cloudResetNotice, "Home says so")
    }

    /// After a deliberate change of account (the installation verified again, for the new one), copies deleted from
    /// the new account never went back up: the account remembered was the old one. Now the records bound to the new
    /// account go back up, and the old account's stay as they are: they never go to another account.
    func testAfterAnAccountChangeTheNewAccountsRecordsGoBackUp() async throws {
        UserDefaults.standard.set("old account", forKey: Self.accountKey)   // remembered before the change
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("old account")
        let old = (6...8).map { record(minutesAgo: Double($0)) }
        add(old, to: store, boundBy: enrollment)
        let reverified = await enrollment.enroll(account: "owner", resolve: { "owner" })
        XCTAssertTrue(reverified, "verified again, for the new account")
        let new = (1...5).map { record(minutesAgo: Double($0)) }
        add(new, to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in new { XCTAssertEqual(syncState(store, event), .pending, "the new account's go back up") }
        for event in old { XCTAssertEqual(syncState(store, event), .synced, "the old account's never go to another") }
    }

    /// Only the records bound to the verified account go back up: one this installation holds back (recorded with no
    /// account it may upload to, as one carried over from before it was verified) stays as it is.
    func testOnlyTheRecordsBoundToTheVerifiedAccountGoBackUp() async throws {
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("owner")
        let bound = (1...5).map { record(minutesAgo: Double($0)) }
        let unbound = (6...7).map { record(minutesAgo: Double($0)) }
        add(bound, to: store, boundBy: enrollment)
        for event in unbound { store.add(event) }   // never registered to the account
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in [] }
        await engine.checkCloudCopies()
        for event in bound { XCTAssertEqual(syncState(store, event), .pending, "bound to the account: back up") }
        for event in unbound { XCTAssertEqual(syncState(store, event), .synced, "no account to go to: as it was") }
    }

    /// The check looks for the records bound to the account it is signed into. After an account change with one new
    /// record, the old account's records are not in the new account by design; looking for them there read as a
    /// deletion, and Home said the records were missing.
    func testAnotherAccountsRecordsAreNotLookedForInThisOne() async throws {
        UserDefaults.standard.set("old account", forKey: Self.accountKey)
        let store = EventStore()
        let enrollment = try await verifiedEnrollment("old account")
        let old = (2...7).map { record(minutesAgo: Double($0)) }
        add(old, to: store, boundBy: enrollment)
        let reverified = await enrollment.enroll(account: "owner", resolve: { "owner" })
        XCTAssertTrue(reverified)
        let new = record(minutesAgo: 1)
        add([new], to: store, boundBy: enrollment)
        let engine = makeEngine(store: store, enrollment: enrollment)
        engine.cloudAccountForTesting = "owner"
        let present = Set(CloudExfiltrator.cloudRecordNames(for: new))
        engine.cloudPresenceForTesting = { names in Set(names).intersection(present) }   // the new account holds its own
        await engine.checkCloudCopies()
        XCTAssertNil(engine.cloudResetNotice, "nothing is missing from the account the phone is signed into")
        for event in old + [new] { XCTAssertEqual(syncState(store, event), .synced) }
    }
}
