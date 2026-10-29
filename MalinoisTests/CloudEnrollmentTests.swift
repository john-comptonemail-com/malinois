import XCTest
@testable import Malinois

@MainActor
final class CloudEnrollmentTests: XCTestCase {
    private final class AuthState {
        var allowed = true
        var prompts = 0
        var gate: CloudEnrollment?
    }
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisEnrollment")
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "com.malinois.cloudRetention.lastRun")
        UserDefaults.standard.removeObject(forKey: "com.malinois.cloudRetention.lastAttempt")
        TestIsolation.tearDown()
        super.tearDown()
    }
    private func file() -> URL {
        (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
    }
    private func event() -> Event { Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]) }

    func testFreshInstallAndCanceledAuthenticationNeverGrant() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in false })
        XCTAssertNil(gate.authorize(account: "account-a"))
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
        XCTAssertNil(gate.authorize(account: "account-a"))
    }
    func testEnrollmentSurvivesRestartButNotNewInstallation() async throws {
        let path = file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        XCTAssertNotNil(gate.authorize(account: "account-a"))
        let restarted = CloudEnrollment(file: path, authenticate: { _ in false })
        XCTAssertNotNil(restarted.authorize(account: "account-a"))
        XCTAssertNil(CloudEnrollment(file: file()).authorize(account: "account-a"))
    }
    func testAccountChangeInvalidatesInflightLease() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertNil(gate.authorize(account: "account-b"))
        XCTAssertFalse(gate.isCurrent(lease))
        XCTAssertFalse(gate.verified)
    }
    /// A lease is good only for the account lookup it came from: once the account is looked up
    /// again, an operation still holding the old lease is refused, even for the same account.
    /// Checked before the new lookup only, the old lease was refused for being unverified
    /// (test-suite audit, CE04).
    func testALeaseFromAnEarlierLookupIsRefusedAfterTheNext() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let first = try XCTUnwrap(gate.authorize(account: "account-a"))
        gate.invalidateAccount()   // the account notification: the account is looked up again
        let second = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertFalse(gate.isCurrent(first), "the old lease does not outlive the new lookup")
    }
    /// A grant written by a newer version is neither read nor overwritten: this version cannot
    /// know what it means, and writing its own over it would lose it (test-suite audit, CE17).
    func testAGrantFromANewerVersionIsNeitherReadNorOverwritten() async throws {
        let path = file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let newer = Data((#"{"version":2,"installation":"8D7C6F1A-0000-4000-8000-000000000017","account":"account-a","#
                          + #""owners":{},"remoteOwners":{},"migrationSeeded":false}"#).utf8)
        try CloudEnrollment.write(newer, to: path)
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        XCTAssertNil(gate.authorize(account: "account-a"), "not read")
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
        XCTAssertEqual(try Data(contentsOf: path), newer, "not overwritten")
    }
    func testAuthenticationCannotEnrollAccountThatChangedDuringPrompt() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-b" })
        XCTAssertFalse(enrolled)
        XCTAssertNil(gate.authorize(account: "account-a"))
        XCTAssertNil(gate.authorize(account: "account-b"))
    }
    func testFailedDurableWriteDoesNotGrant() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true }, persist: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
        XCTAssertNil(gate.authorize(account: "account-a"))
    }
    func testCorruptGrantIsNotOverwrittenOrAuthorized() async throws {
        let path = file()
        try CloudEnrollment.write(Data("damaged".utf8), to: path)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
        XCTAssertEqual(try Data(contentsOf: path), Data("damaged".utf8))
    }
    func testOldUnboundEvidenceStaysLocalAfterEnrollment() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let old = event()
        gate.registerLocalEvent(old)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertFalse(gate.authorizeUpload(event: old, lease: lease))
    }
    func testNewEvidenceCannotTransferToAnotherAccount() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let local = event()
        gate.registerLocalEvent(local)
        let first = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertTrue(gate.authorizeUpload(event: local, lease: first))
        gate.invalidateAccount()
        _ = await gate.enroll(account: "account-b", resolve: { "account-b" })
        let second = try XCTUnwrap(gate.authorize(account: "account-b"))
        XCTAssertFalse(gate.authorizeUpload(event: local, lease: second))
    }
    func testAccountWideOffRequiresFreshAuthentication() async throws {
        let auth = AuthState()
        let gate = CloudEnrollment(file: file(), authenticate: { _ in auth.prompts += 1; return auth.allowed })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        auth.allowed = false
        let rejected = await gate.authorizeAccountControl(account: "account-a")
        XCTAssertNil(rejected)
        XCTAssertEqual(auth.prompts, 2)
        XCTAssertNotNil(gate.authorize(account: "account-a"))
    }
    func testAccountNotificationDuringAuthenticationInvalidatesResult() async {
        let auth = AuthState()
        let gate = CloudEnrollment(file: file(), authenticate: { _ in auth.gate?.invalidateAccount(); return true })
        auth.gate = gate
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
    }

    /// The rebuild when the bindings' file is missing holds every record it finds (codex-7, the owner's ruling (a)), runs
    /// once, and never relabels a binding made since.
    func testTheRebuildHoldsEveryRecordRunsOnceAndRelabelsNothing() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let old = event()
        gate.holdRestoredEvents([old])
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertFalse(gate.authorizeUpload(event: old, lease: lease), "held: nothing proves which account it went to")
        let fresh = event()
        gate.registerLocalEvent(fresh)
        gate.holdRestoredEvents([fresh])
        XCTAssertTrue(gate.authorizeUpload(event: fresh, lease: lease), "the rebuild ran once; a binding is never relabelled")
    }
    func testRemoteRecordCannotAdoptAnUnboundLocalEvent() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let local = event()
        gate.registerLocalEvent(local)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        var mirror = local
        mirror.sourceDevice = "Other phone"
        XCTAssertTrue(gate.registerRemoteEvents([mirror], lease: lease))
        XCTAssertFalse(gate.authorizeUpload(event: local, lease: lease))
        XCTAssertFalse(gate.authorizeRecord(local.id, lease: lease))
    }
    func testRegistrationFailureLeavesEvidenceHeld() async throws {
        let path = file()
        let auth = AuthState()
        let gate = CloudEnrollment(file: path, authenticate: { _ in true }, persist: { data, url in
            guard auth.allowed else { throw CocoaError(.fileWriteOutOfSpace) }
            try CloudEnrollment.write(data, to: url)
        })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        auth.allowed = false
        let local = event()
        gate.registerLocalEvent(local)
        auth.allowed = true
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertFalse(gate.authorizeUpload(event: local, lease: lease))
    }
    func testSessionOwnershipSurvivesRestartAndDoesNotMoveAccounts() async throws {
        let path = file()
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let session = UUID()
        gate.registerSession(session)
        let resumed = CloudEnrollment(file: path, authenticate: { _ in true })
        let original = try XCTUnwrap(resumed.authorize(account: "account-a"))
        XCTAssertTrue(resumed.authorizeSession(session: session, lease: original))
        _ = await resumed.enroll(account: "account-b", resolve: { "account-b" })
        let changed = try XCTUnwrap(resumed.authorize(account: "account-b"))
        XCTAssertFalse(resumed.authorizeSession(session: session, lease: changed))
    }

    func testOfflineCaptureRetainsVerifiedAccountWithoutMovingOnReconnect() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        gate.invalidateAccount()
        let offline = event()
        gate.registerLocalEvent(offline)
        XCTAssertNil(gate.authorize(account: "account-b"))
        let original = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertTrue(gate.authorizeUpload(event: offline, lease: original))
    }
    func testRemoteSessionCannotBecomeALocalHeartbeatOrTrimTarget() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        var remote = event()
        remote.sourceDevice = "Other phone"
        remote.stateChange = "armed"
        XCTAssertTrue(gate.registerRemoteEvents([remote], lease: lease))
        XCTAssertTrue(gate.authorizeRecord(remote.id, lease: lease))
        XCTAssertFalse(gate.authorizeSession(session: remote.id, lease: lease))
    }

    private func engineRig(verified: Bool = true) async -> (CloudEnrollment, MonitoringEngine, EventStore) {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        if verified { _ = await gate.enroll(account: "account-a", resolve: { "account-a" }) }
        let cloud = CloudExfiltrator(enrollment: gate)
        cloud.accountIdentityForTesting = { "account-a" }
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
            cloud: cloud, camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
            timing: EngineCharacterizationTests.fastTiming))
        engine.requiresCloudLeaseForTesting = true
        return (gate, engine, store)
    }
    func testEngineRejectsCloudMergeAfterAccountChangesDuringFetch() async {
        let (gate, engine, store) = await engineRig()
        var mirror = event()
        mirror.sourceDevice = "Other phone"
        engine.cloudFetchForTesting = { _ in
            gate.invalidateAccount()
            return ([mirror], true)
        }
        let count = await engine.syncFromCloud()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(store.events.contains { $0.id == mirror.id })
    }
    func testEngineRejectsDownloadedMediaAfterAccountChangesDuringFetch() async throws {
        let (gate, engine, store) = await engineRig()
        var mirror = event()
        mirror.sourceDevice = "Other phone"
        store.merge([mirror])
        let media = file().deletingLastPathComponent().appendingPathComponent("capture.jpg")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: media)
        engine.fullMediaFetchForTesting = { _, _ in
            gate.invalidateAccount()
            return CloudExfiltrator.FullMediaFetch(media: [
                CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: media)
            ], complete: true)
        }
        let result = await engine.downloadFullEvidence(for: mirror.id)
        XCTAssertFalse(result.landed)
        XCTAssertFalse(result.complete)
        XCTAssertNil(store.events.first { $0.id == mirror.id }?.mediaFilename)
    }
    func testUnverifiedEngineDoesNotAttemptEveryPendingUpload() async {
        let (_, engine, store) = await engineRig(verified: false)
        for _ in 0..<20 { store.add(event()) }
        var uploads = 0
        engine.sweepUploadForTesting = { _ in uploads += 1; return (.synced, nil) }
        await engine.retryPendingSync()
        XCTAssertEqual(uploads, 0)
        XCTAssertFalse(engine.pendingSweepActive)
    }
    func testHeldOldSessionsDoNotCrowdOutEligibleHeartbeatCleanup() async throws {
        let (gate, engine, _) = await engineRig()
        let old = Date().addingTimeInterval(-500 * 86_400)
        let held = (0..<50).map { _ in BeatSession(id: UUID(), start: old) }
        let eligible = BeatSession(id: UUID(), start: old.addingTimeInterval(1))
        gate.registerSession(eligible.id)
        UserDefaults.standard.set(try JSONEncoder().encode(held + [eligible]), forKey: "com.malinois.beats.sessions")
        UserDefaults.standard.set(true, forKey: "com.malinois.beats.sessionsSeeded")
        engine.settings.cloudRetention = .months12
        var asked: [UUID] = []
        engine.beatTrailsTrimForTesting = { sessions in
            asked = sessions.map(\.id)
            return [eligible.id: .trimmed]
        }
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked, [eligible.id])
        XCTAssertEqual(MonitoringEngine.beatSessions().count, 50, "held sessions remain locally tracked")
    }

    /// A later successful write must preserve a restrictive account observation whose first save failed.
    func testFailedAccountHoldSaveSurvivesSuccessfulRegistrationAndRelaunch() async throws {
        let path = file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var writes = 0
        let gate = CloudEnrollment(file: path, authenticate: { _ in true }, persist: { data, url in
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            try CloudEnrollment.write(data, to: url)
        })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let original = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertNil(gate.authorize(account: "account-b"), "The second write fails while recording the hold.")
        XCTAssertFalse(gate.isCurrent(original))
        XCTAssertFalse(gate.verified)
        let duringB = event()
        gate.registerLocalEvent(duringB)
        XCTAssertEqual(writes, 3, "Registration must successfully save after the one injected failure.")

        let restarted = CloudEnrollment(file: path, authenticate: { _ in false })
        let offlineAfterRestart = event()
        restarted.registerLocalEvent(offlineAfterRestart)
        let returned = try XCTUnwrap(restarted.authorize(account: "account-a"))
        XCTAssertFalse(restarted.authorizeUpload(event: duringB, lease: returned))
        XCTAssertFalse(restarted.authorizeUpload(event: offlineAfterRestart, lease: returned),
                       "The later successful registration must have made the account hold durable.")
        let afterResolvingA = event()
        restarted.registerLocalEvent(afterResolvingA)
        XCTAssertTrue(restarted.authorizeUpload(event: afterResolvingA, lease: returned),
                      "Positively resolving A releases only future captures; held IDs stay held.")
    }

    func testKnownDifferentAccountHoldsNewCapturesEvenAfterOfflineRestart() async throws {
        let path = file()
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertNil(gate.authorize(account: "account-b"))
        let underB = event()
        gate.registerLocalEvent(underB)
        gate.invalidateAccount()
        let restarted = CloudEnrollment(file: path, authenticate: { _ in true })
        let offlineAfterB = event()
        restarted.registerLocalEvent(offlineAfterB)
        let returned = try XCTUnwrap(restarted.authorize(account: "account-a"))
        XCTAssertFalse(restarted.authorizeUpload(event: underB, lease: returned))
        XCTAssertFalse(restarted.authorizeUpload(event: offlineAfterB, lease: returned))
        let current = event()
        restarted.registerLocalEvent(current)
        XCTAssertTrue(restarted.authorizeUpload(event: current, lease: returned))
    }
}

extension CloudEnrollmentTests {
    func testRetryPresentationHoldsPreVerificationEventsWithoutAdoptingThem() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let old = event()
        gate.registerLocalEvent(old)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let summary = EventLogView.syncSummary(events: [old], enrollment: gate)
        XCTAssertEqual(summary.retryableCount, 0)
        XCTAssertEqual(summary.heldCount, 1)
        XCTAssertEqual(summary.reasons, [.unknownAccount])
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertFalse(gate.authorizeUpload(event: old, lease: lease))
    }

    func testRetryPresentationSeparatesMixedLocalAndEligibleEvents() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let held = event()
        gate.registerLocalEvent(held)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let pending = event()
        gate.registerLocalEvent(pending)
        var synced = event()
        synced.cloudSyncState = .synced
        var mirror = event()
        mirror.sourceDevice = "Other phone"
        let summary = EventLogView.syncSummary(events: [held, pending, synced, mirror], enrollment: gate)
        XCTAssertEqual(summary.retryableCount, 1)
        XCTAssertEqual(summary.heldCount, 1)
        XCTAssertEqual(summary.reasons, [.unknownAccount])
    }

    func testRetryPresentationKeepsVerifiedOfflineEvidenceRetryableAfterRelaunch() async {
        let path = file()
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        gate.invalidateAccount()
        let offline = event()
        gate.registerLocalEvent(offline)
        let reopened = CloudEnrollment(file: path, authenticate: { _ in false })
        let summary = EventLogView.syncSummary(events: [offline], enrollment: reopened)
        XCTAssertEqual(summary.retryableCount, 1)
        XCTAssertEqual(summary.heldCount, 0)
        XCTAssertNil(reopened.uploadHoldReason(for: offline))
        XCTAssertFalse(reopened.verified, "Presentation must not authorize a cloud operation")
    }

    func testRetryPresentationFollowsAccountSwitchAndReturnWithoutChangingOwnership() async throws {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let original = event()
        gate.registerLocalEvent(original)
        XCTAssertNil(gate.authorize(account: "account-b"))
        XCTAssertEqual(gate.uploadHoldReason(for: original), .differentAccount)
        let unverified = event()
        gate.registerLocalEvent(unverified)
        _ = await gate.enroll(account: "account-b", resolve: { "account-b" })
        XCTAssertEqual(gate.uploadHoldReason(for: original), .differentAccount)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertNil(gate.uploadHoldReason(for: original))
        XCTAssertEqual(gate.uploadHoldReason(for: unverified), .unknownAccount)
        let lease = try XCTUnwrap(gate.authorize(account: "account-a"))
        XCTAssertFalse(gate.authorizeUpload(event: unverified, lease: lease))
    }

    /// A rebuilt record is explained as having no verified account, before and after a verification: Retry cannot
    /// upload it, and the note says so rather than offering a retry (codex-7).
    func testARebuiltRecordIsExplainedAsHeldBeforeAndAfterAVerification() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let restored = event()
        gate.holdRestoredEvents([restored])
        XCTAssertEqual(gate.uploadHoldReason(for: restored), .unknownAccount)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertEqual(gate.uploadHoldReason(for: restored), .unknownAccount)
    }

    func testRetryPresentationDoesNotTreatUnreadableStateAsPermission() throws {
        let path = file()
        try CloudEnrollment.write(Data("damaged".utf8), to: path)
        let gate = CloudEnrollment(file: path, authenticate: { _ in true })
        let local = event()
        XCTAssertEqual(gate.uploadHoldReason(for: local), .unavailable)
        let summary = EventLogView.syncSummary(events: [local], enrollment: gate)
        XCTAssertEqual(summary.retryableCount, 0)
        XCTAssertEqual(summary.heldCount, 1)
        XCTAssertEqual(try Data(contentsOf: path), Data("damaged".utf8))
    }

    // MARK: - The held-events banner's Hide (owner, 2026-10-11)

    /// Hide covers the events held when it is tapped; a newly held event brings the banner back.
    func testHeldBannerHidesForTheCurrentHeldSetAndReturnsForANewHeldEvent() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true })
        let first = event(), second = event()
        gate.registerLocalEvent(first)
        gate.registerLocalEvent(second)
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        let before = EventLogView.syncSummary(events: [first], enrollment: gate)
        XCTAssertEqual(before.heldKeys, [EventLogView.heldBannerKey(eventID: first.id, reason: .unknownAccount)])
        XCTAssertTrue(EventLogView.heldBannerVisible(heldKeys: before.heldKeys, dismissedKeys: []))
        XCTAssertFalse(EventLogView.heldBannerVisible(heldKeys: before.heldKeys, dismissedKeys: before.heldKeys),
                       "Hide covers the events held when it was tapped")
        let after = EventLogView.syncSummary(events: [first, second], enrollment: gate)
        XCTAssertTrue(EventLogView.heldBannerVisible(heldKeys: after.heldKeys, dismissedKeys: before.heldKeys),
                      "a newly held event brings the banner back")
    }

    /// The same event held for a different reason is news; events leaving the held set are not.
    func testHeldBannerReturnsForAChangedReasonButNotForFewerHeldEvents() {
        let one = UUID(), two = UUID()
        let dismissed: Set<String> = [EventLogView.heldBannerKey(eventID: one, reason: .verificationRequired),
                                      EventLogView.heldBannerKey(eventID: two, reason: .unknownAccount)]
        let changed: Set<String> = [EventLogView.heldBannerKey(eventID: one, reason: .differentAccount)]
        XCTAssertTrue(EventLogView.heldBannerVisible(heldKeys: changed, dismissedKeys: dismissed),
                      "a changed hold reason brings the banner back")
        let fewer: Set<String> = [EventLogView.heldBannerKey(eventID: two, reason: .unknownAccount)]
        XCTAssertFalse(EventLogView.heldBannerVisible(heldKeys: fewer, dismissedKeys: dismissed),
                       "fewer held events is not news")
        XCTAssertFalse(EventLogView.heldBannerVisible(heldKeys: [], dismissedKeys: []), "nothing held, no banner")
    }

    /// Hide is remembered across relaunches, in this device's defaults.
    func testHeldBannerDismissalSurvivesRelaunch() throws {
        let suite = "MalinoisHeldBanner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(EventLogView.dismissedHeldKeys(in: defaults), [])
        let keys: Set<String> = [EventLogView.heldBannerKey(eventID: UUID(), reason: .unknownAccount)]
        EventLogView.rememberHeldBannerDismissal(keys, in: defaults)
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(EventLogView.dismissedHeldKeys(in: relaunched), keys)
    }
}
