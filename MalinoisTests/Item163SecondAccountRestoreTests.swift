//
//  Item163SecondAccountRestoreTests.swift
//  MalinoisTests
//
//  codex-7 on 1.8.2's step 15 (BACKLOG 163), twice; the owner's rulings (a), 2026-10-24: hold rather than guess. The
//  account bindings live in the grant's file, which the backup leaves out, so a restored phone rebuilds them once from
//  the log. That rebuild gave every restored record to the account the launch check remembered: after a deliberate
//  change of account, B's records went to A. 1.8.2's first fix held them only when a note said a second account had
//  been verified; Codex's look at 7242a61 found the note no proof (a 1.8.1 backup restored straight into 1.8.2 carries
//  none, and a record held to no account lost its hold). Now the rebuild holds every restored first-hand record,
//  whatever the history: each stays on the phone with the "no verified iCloud account" note, Share still saving a copy,
//  and none uploads to any account. Other devices' copies are left unbound, for the next fetch from the verified
//  account to bind. Records captured after the restore bind as always. Written before the change, red at that commit.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item163SecondAccountRestoreTests: XCTestCase {

    /// The account the launch check remembered before 1.8.2, which TestIsolation leaves alone.
    nonisolated private static let rememberedKey = "com.malinois.cloud.accountRecordName"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem163Restore")
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A new installation's grant, verifying whichever account it is asked to, on a file of its own in the test's
    /// folder: a restored phone starts without the file, which the backup leaves out.
    private func installation() throws -> (enrollment: CloudEnrollment, file: URL) {
        let file = try XCTUnwrap(EventStore.rootOverrideForTesting)
            .appendingPathComponent("grant-" + UUID().uuidString).appendingPathComponent("state.json")
        return (CloudEnrollment(file: file, authenticate: { _ in true }), file)
    }

    private func verify(_ enrollment: CloudEnrollment, _ account: String) async {
        let verified = await enrollment.enroll(account: account, resolve: { account })
        XCTAssertTrue(verified, "verified for \(account)")
    }

    /// A record captured now, bound as the installation binds it.
    private func recorded(on enrollment: CloudEnrollment) -> Event {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        enrollment.registerLocalEvent(event)
        return event
    }

    /// The bindings as the grant's file holds them.
    private func bindings(_ file: URL) throws -> (owners: [String: String], remoteOwners: [String: String]) {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return (object["owners"] as? [String: String] ?? [:], object["remoteOwners"] as? [String: String] ?? [:])
    }

    /// A store that read this launch's log from disk, holding `events`.
    private func storeReadFromDisk(_ events: [Event]) throws -> EventStore {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: root.appendingPathComponent("events.json"))
        let store = EventStore()
        XCTAssertTrue(store.hasReadTheLog, "the log was read from disk")
        return store
    }

    /// The phone restored from its backup: the log and the app's settings come back, the grant's file does not, and
    /// the engine's first launch rebuilds the bindings.
    private func restore(_ events: [Event], cloud: ((CloudEnrollment) -> CloudExfiltrator)? = nil) throws
        -> (enrollment: CloudEnrollment, file: URL, engine: MonitoringEngine) {
        let restored = try installation()
        let exfiltrator = cloud?(restored.enrollment) ?? CloudExfiltrator(enrollment: restored.enrollment)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: try storeReadFromDisk(events),
                                                          cloud: exfiltrator, camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (restored.enrollment, restored.file, engine)
    }

    // MARK: - Every restored record held

    /// One account only, remembered as before 1.8.2: the restored record is held too (the ruling's cost), and A,
    /// verified again, cannot upload it.
    func testARestoreHoldsTheRecordsOfASingleAccount() async throws {
        let before = try installation().enrollment
        await verify(before, "account-A")
        UserDefaults.standard.set("account-A", forKey: Self.rememberedKey)
        let underA = recorded(on: before)

        let after = try restore([underA])
        XCTAssertEqual(try bindings(after.file).owners[underA.id.uuidString], "", "held, not guessed")
        XCTAssertEqual(after.enrollment.uploadHoldReason(for: underA), .unknownAccount, "the existing note says why")
        await verify(after.enrollment, "account-A")
        let lease = try XCTUnwrap(after.enrollment.authorize(account: "account-A"))
        XCTAssertFalse(after.enrollment.authorizeUpload(event: underA, lease: lease), "held for good")
    }

    /// The first codex-7: A, then B, a record under each, restored. Neither is given to an account.
    func testARestoreAfterASecondAccountHoldsEveryRestoredRecord() async throws {
        let before = try installation().enrollment
        await verify(before, "account-A")
        UserDefaults.standard.set("account-A", forKey: Self.rememberedKey)
        let underA = recorded(on: before)
        await verify(before, "account-B")
        let underB = recorded(on: before)

        let after = try restore([underA, underB])
        let rebuilt = try bindings(after.file).owners
        XCTAssertEqual(rebuilt[underB.id.uuidString], "", "B's record held")
        XCTAssertEqual(rebuilt[underA.id.uuidString], "", "A's held too")
        await verify(after.enrollment, "account-A")
        let lease = try XCTUnwrap(after.enrollment.authorize(account: "account-A"))
        XCTAssertFalse(after.enrollment.authorizeUpload(event: underB, lease: lease), "A cannot upload B's record")
    }

    /// Codex's variant A on 7242a61: a backup made under 1.8.1 after A, then B, restored straight into 1.8.2 (nothing in
    /// it says B was ever verified). B's record is held, not given to the remembered A.
    func testABackupFromBeforeThisReleaseIsHeldWhole() async throws {
        let before = try installation().enrollment
        await verify(before, "account-A")
        UserDefaults.standard.set("account-A", forKey: Self.rememberedKey)
        await verify(before, "account-B")
        let underB = recorded(on: before)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("com.malinois.cloudAccounts.") {
            UserDefaults.standard.removeObject(forKey: key)   // a 1.8.1 backup has no such note
        }

        let after = try restore([underB])
        XCTAssertEqual(try bindings(after.file).owners[underB.id.uuidString], "", "held, not given to A")
        await verify(after.enrollment, "account-A")
        let lease = try XCTUnwrap(after.enrollment.authorize(account: "account-A"))
        XCTAssertFalse(after.enrollment.authorizeUpload(event: underB, lease: lease))
    }

    /// Codex's variant B: a record held to no account (iOS signed into B, never verified, while the grant was A's)
    /// stays held across a restore; A, verified again, cannot upload it.
    func testAHeldRecordStaysHeldAcrossARestore() async throws {
        let before = try installation().enrollment
        await verify(before, "account-A")
        UserDefaults.standard.set("account-A", forKey: Self.rememberedKey)
        XCTAssertNil(before.authorize(account: "account-B"), "B seen: no lease")
        let held = recorded(on: before)
        XCTAssertEqual(before.uploadHoldReason(for: held), .unknownAccount, "held as recorded")

        let after = try restore([held])
        XCTAssertEqual(try bindings(after.file).owners[held.id.uuidString], "", "still held")
        await verify(after.enrollment, "account-A")
        let lease = try XCTUnwrap(after.enrollment.authorize(account: "account-A"))
        XCTAssertFalse(after.enrollment.authorizeUpload(event: held, lease: lease))
    }

    /// Another device's copy in the restored log is left unbound, and the next fetch from the verified account binds it
    /// to that account, as a copy fetched from iCloud always is.
    func testARestoredCopyIsBoundByTheNextFetch() async throws {
        var copy = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        copy.sourceDevice = "Other phone"
        let after = try restore([copy])
        XCTAssertNil(try bindings(after.file).remoteOwners[copy.id.uuidString], "left for the next fetch")
        await verify(after.enrollment, "account-A")
        let lease = try XCTUnwrap(after.enrollment.authorize(account: "account-A"))
        XCTAssertTrue(after.enrollment.registerRemoteEvents([copy], lease: lease), "the fetch binds it")
        XCTAssertTrue(after.enrollment.authorizeRecord(copy.id, lease: lease), "to the account that supplied it")
    }

    /// Codex's sweep, with both his variants in one backup (a held record, then B's records, nothing in the backup
    /// saying B was verified): after the restore and A verified again, the real pending sweep sends no restored record.
    func testTheSweepAfterARestoreSendsNoRestoredRecord() async throws {
        let before = try installation().enrollment
        await verify(before, "account-A")
        UserDefaults.standard.set("account-A", forKey: Self.rememberedKey)
        let underA = recorded(on: before)
        XCTAssertNil(before.authorize(account: "account-B"), "B seen")
        let held = recorded(on: before)
        await verify(before, "account-B")
        let underB = recorded(on: before)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("com.malinois.cloudAccounts.") {
            UserDefaults.standard.removeObject(forKey: key)   // as a 1.8.1 backup
        }
        let sent = Sent()

        let after = try restore([underA, held, underB]) { enrollment in
            let cloud = CloudExfiltrator(enrollment: enrollment)
            cloud.accountIdentityForTesting = { "account-A" }
            cloud.saveAttemptForTesting = { records in sent.add(records) }
            return cloud
        }
        await verify(after.enrollment, "account-A")
        await after.engine.retryPendingSync()
        for id in [underA.id, held.id, underB.id] {
            XCTAssertFalse(sent.names.contains { $0.contains(id.uuidString) }, "no restored record sent: \(sent.names)")
        }
    }

    /// The record names the saves sent.
    @MainActor
    private final class Sent {
        private(set) var names: [String] = []
        func add(_ records: [CKRecord]) { names += records.map(\.recordID.recordName) }
    }

    /// Control: a record captured after the restore binds to the account verified then, as always.
    func testARecordCapturedAfterTheRestoreBindsAsAlways() async throws {
        let after = try restore([])
        await verify(after.enrollment, "account-A")
        let fresh = recorded(on: after.enrollment)
        let lease = try XCTUnwrap(after.enrollment.authorize(account: "account-A"))
        XCTAssertTrue(after.enrollment.authorizeUpload(event: fresh, lease: lease))
    }
}
