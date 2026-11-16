//
//  Item227RestoreNoticeTests.swift
//  MalinoisTests
//
//  BACKLOG item 227's Codex-1 (1.13, item 240's list; docs/design/1.13-fixes.md, part 5a; the owner, 2026-11-12: "as you
//  recommend, wording approved": D6 (a), W6 to W8). A pull of the event log from iCloud that came back incomplete showed
//  the owner nothing, and a record this version cannot read (no ID or date, or a status kind a later version wrote) was
//  left out without a word, and without making the pull incomplete. Now every pull says how it went: Home and the top of
//  the Event Log say when the last pull did not run to the end (W6, W7), until one does, and how many records it could
//  not read (W8); such records still settle an owed restore, or a later version's records would make every launch ask
//  for everything. Through the engine's own pulls (the launch's and the Event Log's), iCloud's answer stood in for, and
//  once through the real fetch with real records; Home and the Event Log laid out for real. Written before the fix, red
//  at that commit (where no pull says how it went, and the fetch counts nothing).
//

import CloudKit
import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item227RestoreNoticeTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem227")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Through the engine's pulls

    /// The launch's pull did not run to the end: Home says so (W6).
    func testALaunchPullThatDidNotRunToTheEndIsSaidOnHome() async throws {
        let rig = makeRig()
        rig.engine.cloudFetchForTesting = { _ in ([], false) }
        try await launch(rig)
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: false, unreadable: 0))
        let shown = try home(rig)
        XCTAssertTrue(shown.contains(CloudPullOutcome.homeIncomplete), "\(shown)")
    }

    /// The same, at the top of the Event Log (W7), which is a list the owner can pull down even with no event in it.
    func testTheEventLogSaysItAtItsTopEvenWithNothingElseToList() async throws {
        let rig = makeRig()
        rig.engine.cloudFetchForTesting = { _ in ([], false) }
        try await launch(rig)
        XCTAssertTrue(rig.store.events.isEmpty, "nothing else to list")
        let shown = try shownOnScreen(NavigationStack { EventLogView() }
            .environmentObject(rig.store).environmentObject(rig.engine)
            .environmentObject(rig.cloud).environmentObject(rig.entitlements)).shown
        XCTAssertTrue(shown.contains(CloudPullOutcome.logIncomplete), "\(shown)")
    }

    /// A later pull, the Event Log's own, runs to the end: Home says nothing of it any more.
    func testALaterPullThatRunsToTheEndClearsIt() async throws {
        let rig = makeRig()
        var complete = false
        rig.engine.cloudFetchForTesting = { _ in ([], complete) }
        try await launch(rig)
        XCTAssertEqual(rig.engine.lastCloudPull?.complete, false)
        complete = true
        _ = await rig.engine.syncFromCloud(limit: EventStore.maxEvents)
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: true, unreadable: 0))
        let shown = try home(rig)
        XCTAssertFalse(shown.contains(CloudPullOutcome.homeIncomplete), "\(shown)")
    }

    /// Records the pull could not read are counted and said (W8), plural and singular; the pull still ran to the end and
    /// settles the restore owed since the install.
    func testRecordsThisVersionCannotReadAreCountedSaidAndSettleTheRestore() async throws {
        let rig = makeRig()
        XCTAssertNotNil(rig.store.restoreOwedSince, "a new install owes a restore")
        rig.engine.cloudFetchForTesting = { _ in ([], true) }
        rig.engine.cloudUnreadableForTesting = 3
        try await launch(rig)
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: true, unreadable: 3))
        XCTAssertNil(rig.store.restoreOwedSince, "settled: records it cannot read do not keep it owed")
        var shown = try home(rig)
        XCTAssertTrue(shown.contains(CloudPullOutcome.unreadableLine(3)), "\(shown)")
        XCTAssertFalse(shown.contains(CloudPullOutcome.homeIncomplete), "it ran to the end")
        rig.engine.cloudUnreadableForTesting = 1
        _ = await rig.engine.syncFromCloud(limit: EventStore.maxEvents)
        shown = try home(rig)
        XCTAssertTrue(shown.contains("1 record in iCloud can't be read by this version of Malinois and isn't shown."), "\(shown)")
    }

    /// While a pull runs (Verify iCloud access's, here held), Home and the Event Log say it runs, not how the last one went.
    func testNotWhileAPullRuns() async throws {
        let rig = makeRig()
        let gate = PullGate()
        defer { gate.letGo() }   // a held fetch is let go, so no test's run waits on it after it ends
        rig.engine.cloudFetchForTesting = { _ in
            await gate.wait()
            return ([], false)
        }
        gate.open = true
        try await launch(rig)
        XCTAssertEqual(rig.engine.lastCloudPull?.complete, false)
        gate.open = false
        let verify = Task { await rig.engine.cloudAccessVerified() }
        try await waitUntil("the pull under way") { rig.engine.cloudRestoreInProgress && gate.waiting }
        let home = try home(rig)
        XCTAssertFalse(home.contains(CloudPullOutcome.homeIncomplete), "not while a pull runs: \(home)")
        let log = try shownOnScreen(NavigationStack { EventLogView() }
            .environmentObject(rig.store).environmentObject(rig.engine)
            .environmentObject(rig.cloud).environmentObject(rig.entitlements)).shown
        XCTAssertFalse(log.contains(CloudPullOutcome.logIncomplete), "nor in the Event Log: \(log)")
        gate.letGo()
        await verify.value
    }

    // MARK: - Through the real fetch

    /// The launch's pull through the real fetch, its queries answered with real records: a meta record it can read and one
    /// with no ID or date. The one it can read joins the log; the other is counted, and the pull still ran to the end.
    func testACloudPullCountsTheRecordsItCannotRead() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "account-a" }
        cloud.readDeadlineForTesting = 10
        let queries = HeldQueries()
        cloud.readSubmitForTesting = { queries.add($0) }
        let rig = makeRig(cloud: cloud)
        let readable = Event(startDate: Date().addingTimeInterval(-120), endDate: Date().addingTimeInterval(-119),
                             triggeredSensors: [.motion], cloudSyncState: .synced)
        let good = CloudExfiltrator.makeMetaRecord(readable, deviceName: "iPhone Air", thumbnailURL: nil)
        let bad = CKRecord(recordType: good.recordType, recordID: CKRecord.ID(recordName: "meta-v2-" + UUID().uuidString))
        rig.entitlements.resolveForTesting(as: .trial)   // the launch: its retry, then its pull
        var answered = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while answered < 4, clock.now < deadline {
            if let query = queries.next() {
                let records = query.query?.recordType == good.recordType ? [good, bad] : []
                for record in records { query.recordMatchedBlock?(record.recordID, .success(record)) }
                query.queryResultBlock?(.success(nil))
                answered += 1
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertEqual(answered, 4, "the four record types' queries")
        try await waitUntil("the pull's outcome") { rig.engine.lastCloudPull != nil && !rig.engine.cloudRestoreInProgress }
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: true, unreadable: 1))
        XCTAssertTrue(rig.store.events.contains { $0.id == readable.id }, "the record it could read joined the log")
    }

    // MARK: - Each pull's own outcome (item 241's A1, Codex-1)
    //
    // 1.13's full review: a pull that could not start (its account check failing for a while) recorded no outcome, so
    // Home and the Event Log went on showing the pull before's "complete"; and a fetch read its result from fields every
    // fetch shares, so a fetch whose account check failed, while another ran to the end, took the other's "complete":
    // a launch's restore that read nothing could be settled. Now every Pro pull that cannot start, the account still
    // verified, records an incomplete outcome, and every fetch answers with its own result.

    /// A pull that cannot start, its account check failing for a while (no network to Apple, an iCloud outage), the
    /// account still verified: Home says the pull did not run to the end.
    func testAPullThatCannotStartIsSaidOnHome() async throws {
        let (cloud, queries) = try await verifiedCloud()
        let rig = makeRig(cloud: cloud)
        rig.entitlements.resolveForTesting(as: .trial)   // the launch: its retry, then its pull
        try await answer(queries, count: 4)
        try await waitUntil("the launch's pull") { rig.engine.lastCloudPull != nil && !rig.engine.cloudRestoreInProgress }
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: true, unreadable: 0), "the launch's pull ran to the end")
        cloud.accountIdentityForTesting = { throw CKError(.networkFailure) }
        _ = await rig.engine.syncFromCloud()
        XCTAssertTrue(cloud.enrollment.verified, "a passing failure leaves the account verified")
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: false, unreadable: 0))
        let shown = try home(rig)
        XCTAssertTrue(shown.contains(CloudPullOutcome.homeIncomplete), "\(shown)")
    }

    /// A pull that cannot start with no verified account (iCloud never set up on this phone, or not this installation's
    /// account): it says nothing of the event log, since the account has lines of its own.
    func testAPullWithNoVerifiedAccountSaysNothing() async throws {
        let rig = makeRig()
        rig.entitlements.resolveForTesting(as: .trial)
        XCTAssertFalse(rig.cloud.enrollment.verified, "no verified account here")
        _ = await rig.engine.syncFromCloud()
        XCTAssertNil(rig.engine.lastCloudPull, "a pull that could not start, with no account to read from")
    }

    /// Two fetches at once (a push's pull while the launch's restore runs): the first waits on its account check while the
    /// second runs to the end, then the first's check fails for a while. The first answers with its own result.
    func testAFetchReportsItsOwnResultWhenAnotherRanMeanwhile() async throws {
        let (cloud, queries) = try await verifiedCloud()
        let gate = IdentityGate()
        defer { gate.fail(with: CKError(.networkFailure)) }
        cloud.accountIdentityForTesting = { try await gate.lookUp() }
        let first = Task { await cloud.fetchRecentEventsReporting(limit: 10) }
        try await waitUntil("the first fetch waits on its account check") { gate.holding }
        let second = Task { await cloud.fetchRecentEventsReporting(limit: 10) }
        try await answer(queries, count: 4)
        let secondResult = await second.value
        XCTAssertTrue(secondResult.complete, "the second ran to the end")
        gate.fail(with: CKError(.networkFailure))
        let firstResult = await first.value
        XCTAssertFalse(firstResult.complete, "the first's own result: its account check failed, and it read nothing")
        XCTAssertTrue(firstResult.events.isEmpty)
    }

    /// The engine's pulls take each fetch's own result (read from the source tree, as built): the pull's outcome, an owed
    /// restore's settling, and a push's answer to iOS.
    func testThePullsUseEachFetchsOwnResult() throws {
        let transfers = try String(contentsOf: Self.root.appendingPathComponent(
            "Malinois/Services/MonitoringCloudCoordinator+Transfers.swift"), encoding: .utf8)
        XCTAssertTrue(transfers.contains("let fetch = await cloud.fetchRecentEventsReporting(limit: limit)"))
        XCTAssertFalse(transfers.contains("cloud.lastFetchComplete"), "no shared field read after a fetch")
        XCTAssertFalse(transfers.contains("cloud.lastFetchFailed"), "nor for a push's answer")
    }

    // gpt6-astra's change review of round l: only the source-reading test above pinned that the engine's pulls take their
    // fetch's own result. A pull that took "complete" whatever its fetch said passed every test: the engine tests' fetches
    // were stood in for, the start-failure tests stop before the fetch, and the two-fetch test calls the fetch itself.
    // These two run the engine's pulls through the real fetch.

    /// The launch's restore through the real fetch, one of its four queries failing: the pull did not run to the end, so
    /// Home is told, and the restore owed since the install stays owed.
    func testALaunchRestoreWhoseFetchFailsAQueryStaysOwed() async throws {
        let (cloud, queries) = try await verifiedCloud()
        let rig = makeRig(cloud: cloud)
        XCTAssertNotNil(rig.store.restoreOwedSince, "a new install owes a restore")
        rig.entitlements.resolveForTesting(as: .trial)   // the launch: its retry, then its pull
        try await answer(queries, count: 4, failing: 0)
        try await waitUntil("the launch's pull") { rig.engine.lastCloudPull != nil && !rig.engine.cloudRestoreInProgress }
        XCTAssertEqual(rig.engine.lastCloudPull, CloudPullOutcome(complete: false, unreadable: 0), "one query failed")
        XCTAssertNotNil(rig.store.restoreOwedSince, "a restore that did not run to the end settles nothing")
    }

    /// A push's answer to iOS comes from its own pull: "failed" when the pull cannot start, though the fetch before it ran
    /// to the end; and "failed" when one of its own fetch's queries fails.
    func testAPushAnswersWithItsOwnPullsResult() async throws {
        let (cloud, queries) = try await verifiedCloud()
        let rig = makeRig(cloud: cloud)
        rig.entitlements.resolveForTesting(as: .trial)
        try await answer(queries, count: 4)
        try await waitUntil("the launch's pull") { rig.engine.lastCloudPull != nil && !rig.engine.cloudRestoreInProgress }
        XCTAssertFalse(cloud.lastFetchFailed, "precondition: the launch's fetch ran to the end")
        cloud.accountIdentityForTesting = { throw CKError(.networkFailure) }
        let couldNotStart = await rig.engine.handleRemotePush()
        XCTAssertEqual(couldNotStart, .failed, "a pull that could not start")
        cloud.accountIdentityForTesting = { "account-a" }
        let push = Task { await rig.engine.handleRemotePush() }
        try await answer(queries, count: 4, failing: 2)
        let failedQuery = await push.value
        XCTAssertEqual(failedQuery, .failed, "one of its fetch's queries failed")
    }

    // MARK: - Home's line for a log it could neither read nor set aside

    /// The event log could be neither read nor set aside (a folder in its place, the store's folder refusing the backup):
    /// Home's line says that opening Malinois again retries, and what reinstalling deletes (W10).
    func testHomesLineForALogItCouldNeitherReadNorSetAside() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events.json"), withIntermediateDirectories: true)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let store = EventStore(protectedDataAvailable: { true })
        XCTAssertTrue(store.loadFailed, "precondition: neither read nor set aside")
        let settings = AppSettings()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let cloud = CloudExfiltrator()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        let shown = try shownOnScreen(HomeView()
            .environmentObject(engine).environmentObject(settings).environmentObject(cloud)
            .environmentObject(store).environmentObject(entitlements)).shown
        let words = "The event log couldn't be read and new events aren't being saved on this iPhone. Close Malinois and "
            + "open it again to retry. Reinstalling starts a new log, but deletes every photo, clip and set-aside log on "
            + "this iPhone."
        XCTAssertEqual(HomeView.logUnreadableNotice, words, "the owner's approved words")
        XCTAssertTrue(shown.contains(words), "on Home: \(shown)")
    }

    // MARK: - The words

    /// W6 to W8, word for word (the owner's "wording approved", 2026-11-12).
    func testTheWordsAreTheApprovedOnes() {
        XCTAssertEqual(CloudPullOutcome.homeIncomplete,
                       "Malinois couldn't read all of your event log from iCloud. Pull down in the Event Log to try again.")
        XCTAssertEqual(CloudPullOutcome.logIncomplete, "Part of your event log in iCloud couldn't be read. Pull down to try again.")
        XCTAssertEqual(CloudPullOutcome.unreadableLine(3),
                       "3 records in iCloud can't be read by this version of Malinois and aren't shown.")
        XCTAssertEqual(CloudPullOutcome.unreadableLine(1),
                       "1 record in iCloud can't be read by this version of Malinois and isn't shown.")
    }

    // MARK: - Helpers

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let cloud: CloudExfiltrator
        let settings: AppSettings
        let entitlements: ProEntitlements
    }

    /// A new install (an empty log, so a restore is owed), the Pro check not yet answered.
    private func makeRig(cloud: CloudExfiltrator = CloudExfiltrator()) -> Rig {
        let store = EventStore()
        let settings = AppSettings()
        let entitlements = ProEntitlements.unresolvedForTesting()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        addTeardownBlock { @MainActor in store.drainIOForTesting() }
        return Rig(engine: engine, store: store, cloud: cloud, settings: settings, entitlements: entitlements)
    }

    /// The Pro check answers: the launch runs its retry and its pull, which this waits for.
    private func launch(_ rig: Rig) async throws {
        rig.entitlements.resolveForTesting(as: .trial)
        try await waitUntil("the launch's pull") { rig.engine.lastCloudPull != nil && !rig.engine.cloudRestoreInProgress }
    }

    /// A verified installation's iCloud, its account "account-a", its queries held for the test to answer.
    private func verifiedCloud() async throws -> (CloudExfiltrator, HeldQueries) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "account-a" }
        cloud.readDeadlineForTesting = 10
        let queries = HeldQueries()
        cloud.readSubmitForTesting = { queries.add($0) }
        return (cloud, queries)
    }

    /// Answers `count` held queries with no records, as iCloud does for an empty database, but the one at `failing`
    /// (counted from 0) with a network failure; after ten seconds, fails.
    private func answer(_ queries: HeldQueries, count: Int, failing: Int? = nil) async throws {
        var answered = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while answered < count, clock.now < deadline {
            if let query = queries.next() {
                let result: Result<CKQueryOperation.Cursor?, any Error> = answered == failing
                    ? .failure(CKError(.networkFailure)) : .success(nil)
                query.queryResultBlock?(result)
                answered += 1
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertEqual(answered, count, "the queries answered")
    }

    /// What the real Home shows.
    private func home(_ rig: Rig) throws -> [String] {
        try shownOnScreen(HomeView()
            .environmentObject(rig.engine).environmentObject(rig.settings).environmentObject(rig.cloud)
            .environmentObject(rig.store).environmentObject(rig.entitlements)).shown
    }

    /// Lets the main run loop turn until `condition` holds; after ten seconds, fails, naming what it waited for.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else { return XCTFail("waited ten seconds: \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Holds stood-in fetches until the test lets them go; open, it lets every fetch through. It holds every fetch that
    /// reaches it, not one: a screen the test shows can start its own pull while the first is held (the Event Log pulls
    /// when it appears). With one slot the second took the first's place, the first never returned, and the test waited
    /// for it until the run was ended (chain g, 2026-11-13).
    @MainActor
    private final class PullGate {
        var open = false
        private var held: [CheckedContinuation<Void, Never>] = []

        /// Whether a fetch is held now.
        var waiting: Bool { !held.isEmpty }

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { held.append($0) }
        }

        func letGo() {
            open = true
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    /// Holds the first account check until the test lets it fail; answers every later one with "account-a" at once.
    @MainActor
    private final class IdentityGate {
        private var held: CheckedContinuation<String?, Error>?
        private var calls = 0

        /// Whether the first check is held now.
        var holding: Bool { held != nil }

        func lookUp() async throws -> String? {
            calls += 1
            guard calls == 1 else { return "account-a" }
            return try await withCheckedThrowingContinuation { held = $0 }
        }

        /// Lets the held check fail with `error`; nothing when none is held.
        func fail(with error: Error) {
            let waiting = held
            held = nil
            waiting?.resume(throwing: error)
        }
    }

    /// The query operations the fetch submitted, each taken once to be answered.
    @MainActor
    private final class HeldQueries {
        private var waiting: [CKQueryOperation] = []

        func add(_ operation: CKDatabaseOperation) {
            if let query = operation as? CKQueryOperation { waiting.append(query) }
        }

        func next() -> CKQueryOperation? { waiting.isEmpty ? nil : waiting.removeFirst() }
    }
}
