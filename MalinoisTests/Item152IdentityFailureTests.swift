//
//  Item152IdentityFailureTests.swift
//  MalinoisTests
//
//  BACKLOG 152's lead 1, item 145 step 16 (ADR 0039 amended). Every upload, heartbeat and sweep step first resolves
//  the iCloud account's identity; one lookup that failed for any reason (a network error, or its 10 s deadline) was
//  treated as an account change for the whole process: every lease in flight voided, every save under way cancelled
//  and demoted to local-only, the pending sweep's reason to follow up erased, the verified state cleared. Now the
//  lookup tells a name, no account and a transient failure apart: a transient failure denies only its own caller,
//  records a network-class transient failure for the sweep's follow-up and the interference verdict, and leaves other
//  work and the verified state alone; no account, a positively different account and the account-changed notice
//  still invalidate. Written before the change, red at that commit (against compile-only stubs).
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item152IdentityFailureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152Identity")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    private struct CloudRig {
        let policy: CloudEnrollment
        let cloud: CloudExfiltrator
        let directory: URL
    }

    /// A verified installation on "account-A", resolving that name until a test says otherwise.
    private func verifiedRig() async throws -> CloudRig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let policy = CloudEnrollment(file: directory.appendingPathComponent("enrollment.json"), authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-A" }
        let enrolled = await cloud.enrollCloudAccess()
        try XCTSkipUnless(enrolled, "the enrollment could not be written")
        return CloudRig(policy: policy, cloud: cloud, directory: directory)
    }

    /// A save held open until the test lets it go: the window in which another caller's lookup fails.
    @MainActor
    private final class Hold {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var waiting = 0
        func wait() async {
            waiting += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            let held = waiters
            waiters = []
            held.forEach { $0.resume() }
        }
    }

    private func statusEvent() -> Event {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [])
        event.stateChange = "armed"
        return event
    }

    /// Waits for `condition`, yielding the main actor meanwhile: an async test holds the actor, and a nested run loop
    /// does not hand it over, so the tasks under test (a push, the sweep's follow-up) run only while this awaits.
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    // MARK: - The rule

    /// A name is a name; none, or an empty one, is no account; the network class and the deadline are transient;
    /// iCloud's "not authenticated" and anything unclassified keep invalidating, as before.
    func testTheLookupTellsANameNoAccountAndATransientFailureApart() {
        typealias Lookup = CloudExfiltrator.IdentityLookup
        XCTAssertEqual(CloudExfiltrator.identityLookup(.success("_abc")), Lookup.named("_abc"))
        XCTAssertEqual(CloudExfiltrator.identityLookup(.success(nil)), .noAccount)
        XCTAssertEqual(CloudExfiltrator.identityLookup(.success("")), .noAccount)
        // The network class is interference; Apple's throttles and outages are answers, not interference, and their
        // retry-after is kept (item 155's A3, Codex's codex-5).
        for code in [CKError.Code.networkFailure, .networkUnavailable, .serverResponseLost] {
            XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(CKError(code))),
                           .transient(interference: true, retryAfter: nil), "\(code)")
        }
        for code in [CKError.Code.serviceUnavailable, .requestRateLimited, .zoneBusy] {
            XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(CKError(code))),
                           .transient(interference: false, retryAfter: nil), "\(code): an answer, not interference")
        }
        let throttled = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0])
        XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(throttled)),
                       .transient(interference: false, retryAfter: 120), "the server's wait is kept")
        XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(CKError(.accountTemporarilyUnavailable))),
                       .transient(interference: false, retryAfter: nil),
                       "the account is there but not ready (item 155's S2): an answer to wait out, not a missing account")
        XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(URLError(.timedOut))),
                       .transient(interference: true, retryAfter: nil), "a bare transport error")
        let wrapped = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["x": CKError(.networkFailure)]])
        XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(wrapped)),
                       .transient(interference: true, retryAfter: nil), "the real code is inside")
        XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(CKError(.notAuthenticated))), .noAccount, "iCloud's answer")
        XCTAssertEqual(CloudExfiltrator.identityLookup(.failure(CKError(.internalError))), .noAccount, "unclassified: as before")
    }

    // MARK: - Leases and the verified state

    /// A transient lookup denies only its caller: the leases in flight stay current, the installation stays verified,
    /// the next lookup resolves the same generation, and a network-class transient failure is on record for the
    /// sweep. No account still invalidates everything, as before.
    func testATransientLookupDeniesOnlyItsCallerAndRecordsATransientFailure() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let firstLease = await rig.cloud.acquireCloudLease()
        let first = try XCTUnwrap(firstLease)
        rig.cloud.accountIdentityForTesting = { throw CKError(.networkFailure) }   // the deadline's error, or a lost path
        let denied = await rig.cloud.acquireCloudLease()
        XCTAssertNil(denied, "this caller gets no lease")
        XCTAssertTrue(rig.policy.isCurrent(first), "the lease in flight stands")
        XCTAssertTrue(rig.policy.verified, "the verified state stands")
        XCTAssertEqual(rig.cloud.lastTransientFailure, CloudExfiltrator.TransientFailure(retryAfter: nil),
                       "a network-class transient failure, for the sweep's follow-up")
        rig.cloud.accountIdentityForTesting = { "account-A" }
        let again = await rig.cloud.acquireCloudLease()
        XCTAssertEqual(again, first, "the same generation: nothing was invalidated")
        rig.cloud.accountIdentityForTesting = { nil }   // iCloud: no account
        let afterNoAccount = await rig.cloud.acquireCloudLease()
        XCTAssertNil(afterNoAccount)
        XCTAssertFalse(rig.policy.isCurrent(first), "no account still invalidates")
        XCTAssertFalse(rig.policy.verified)
    }

    /// A save under way when another caller's lookup fails transiently still lands; one under way when iCloud answers
    /// no account is cancelled, as before.
    func testAnInFlightSaveSurvivesAnotherCallersTransientLookup() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let event = statusEvent()
        rig.policy.registerLocalEvent(event)
        let hold = Hold()
        rig.cloud.saveAttemptForTesting = { _ in await hold.wait() }
        defer { rig.cloud.saveAttemptForTesting = nil }
        let push = Task { await rig.cloud.pushStateChange(event) }
        let underWay = await waitFor({ hold.waiting == 1 }, timeout: 3)
        XCTAssertTrue(underWay, "the save is under way")
        rig.cloud.accountIdentityForTesting = { throw CKError(.networkFailure) }
        let transientLease = await rig.cloud.acquireCloudLease()
        XCTAssertNil(transientLease, "another caller's lookup fails transiently")
        hold.release()
        let landed = await push.value
        XCTAssertTrue(landed, "the save under way lands")

        rig.cloud.accountIdentityForTesting = { "account-A" }
        let second = statusEvent()
        rig.policy.registerLocalEvent(second)
        let push2 = Task { await rig.cloud.pushStateChange(second) }
        let secondUnderWay = await waitFor({ hold.waiting == 2 }, timeout: 3)
        XCTAssertTrue(secondUnderWay, "the second save is under way")
        rig.cloud.accountIdentityForTesting = { nil }
        let noAccountLease = await rig.cloud.acquireCloudLease()
        XCTAssertNil(noAccountLease, "iCloud: no account")
        hold.release()
        let cancelled = await push2.value
        XCTAssertFalse(cancelled, "no account cancels the save under way, as before")
    }

    // MARK: - The verdict

    /// An evidence push denied by a transient lookup yields the network-class verdict the jamming escalation reads
    /// (ADR 0001), as a save that lost the network would; denied by no account, no verdict, as before.
    func testAnEvidencePushDeniedByATransientLookupYieldsTheNetworkClassVerdict() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        rig.policy.registerLocalEvent(event)
        rig.cloud.accountIdentityForTesting = { throw CKError(.networkFailure) }
        let transient = await rig.cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(transient, .init(syncState: .localOnly, metaFailureWasInterference: true))
        rig.cloud.accountIdentityForTesting = { nil }
        let noAccount = await rig.cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(noAccount, .init(syncState: .localOnly, metaFailureWasInterference: nil))
    }

    // MARK: - The sweep

    /// A pending sweep whose lookup fails transiently follows up, as it does after a save that lost the network,
    /// instead of ending with records left; a lookup that finds no account ends it, as before.
    func testTheSweepFollowsUpAfterATransientLookup() async throws {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sweepWaitFloor = 0.05
        timing.sweepWaitCeiling = 0.2
        func makeEngine() async throws -> (engine: MonitoringEngine, cloud: CloudExfiltrator, store: EventStore) {
            let rig = try await verifiedRig()
            let store = EventStore()
            let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: rig.cloud,
                                                              camera: FakeCamera(),
                                                              entitlements: ProEntitlements(resolvedAs: .trial),
                                                              timing: timing))
            engine.requiresCloudLeaseForTesting = true
            let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
            rig.policy.registerLocalEvent(event)
            store.add(event)
            return (engine, rig.cloud, store)
        }
        let transient = try await makeEngine()
        transient.cloud.accountIdentityForTesting = { throw CKError(.networkFailure) }
        await transient.engine.retryPendingSync()
        XCTAssertTrue(transient.engine.pendingSweepWaiting, "the sweep waits for a follow-up pass instead of ending")
        let ended = await waitFor({ !transient.engine.pendingSweepActive }, timeout: 5)
        XCTAssertTrue(ended, "and ends once its passes are spent")

        let noAccount = try await makeEngine()
        noAccount.cloud.accountIdentityForTesting = { nil }
        await noAccount.engine.retryPendingSync()
        XCTAssertFalse(noAccount.engine.pendingSweepActive, "no account: the sweep ends at once, as before")
        XCTAssertFalse(noAccount.engine.pendingSweepWaiting)
    }

    // MARK: - Item 155's A1 (step 20): a sweep during a capture is not the event's last word

    /// Codex's P1 (the fresh review of 1.8.1, item 155). A capture is held open; a sweep lands the event's sparse
    /// record meanwhile and marks it synced; the photo's upload is then refused. The event must read pending, the
    /// next sweep must retry the photo, and when the cap takes the never-uploaded photo the loss must be marked.
    /// Red at the step's red commit: synced for good, no retry, the photo deleted with no mark.
    func testASweepDuringACaptureDoesNotMarkTheEventSyncedForGood() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let settings = AppSettings()
        settings.enabledSensors = [.touch, .camera]
        settings.captureMode = .photo
        settings.cameraPosition = .front
        settings.cameraReadiness = .batterySaver
        settings.responseMode = .stealth
        settings.illumination = .off
        settings.jammingResponse = false
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.cloudBackup = true
        let camera = FakeCamera()
        let store = EventStore()
        var photoAttempts = 0
        rig.cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordType == CloudExfiltrator.photoRecordTypeV2 }) {
                photoAttempts += 1
                throw CKError(.quotaExceeded)
            }
        }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: rig.cloud,
                                                          camera: camera, entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        defer { camera.releaseStills(); engine.disarm(); rig.cloud.saveAttemptForTesting = nil }
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitFor({ engine.state == .armed }, timeout: 4) else { return XCTFail("did not arm") }
        camera.holdStills = true
        engine.handleTrip(.touch)
        guard await waitFor({ !camera.stills.isEmpty }, timeout: 4) else { return XCTFail("capture not held") }
        let id = try XCTUnwrap(store.events.first { !$0.isStateChange }?.id)
        XCTAssertNil(store.events.first { $0.id == id }?.mediaFilename, "no media yet: the capture is held")
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == id }?.cloudSyncState, .synced, "the sparse sweep landed")
        camera.releaseStills()
        guard await waitFor({ photoAttempts > 0 && !store.isUploading(id) && engine.state == .armed }, timeout: 5)
        else { return XCTFail("the full media push did not finish") }
        let filename = try XCTUnwrap(store.events.first { $0.id == id }?.mediaFilename)
        let mediaURL = store.mediaDirectory.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path), "the photo is on disk")
        XCTAssertEqual(store.events.first { $0.id == id }?.cloudSyncState, .pending, "the only full photo was refused")
        let before = photoAttempts
        await engine.retryPendingSync()
        XCTAssertGreaterThan(photoAttempts, before, "an ordinary retry tries the unuploaded photo again")
        store.mediaBudgetForTesting = 0
        engine.disarm()
        let pruned = await waitFor({ store.events.first { $0.id == id }?.mediaFilename == nil }, timeout: 4)
        XCTAssertTrue(pruned, "the byte-cap pass ran")
        store.drainIOForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path), "the only photo was deleted")
        XCTAssertEqual(store.events.first { $0.id == id }?.mediaDiscarded, true, "the loss of a never-uploaded photo is marked")
    }

    // MARK: - Item 155's A2 and A3 (step 21): a temporary answer at the other entry point; a throttle is not interference

    /// Codex's P3. Home's and Settings' account-status refresh answers "temporarily unavailable": the verification and
    /// the leases in flight stand, and an unrelated save under way lands. Red at the step's red commit: the refresh
    /// invalidated everything, as the identity lookup did before step 16.
    func testATemporaryStatusRefreshDoesNotRevokeAnInFlightSave() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let leaseValue = await rig.cloud.acquireCloudLease()
        let lease = try XCTUnwrap(leaseValue)
        let event = statusEvent()
        rig.policy.registerLocalEvent(event)
        let hold = Hold()
        rig.cloud.saveAttemptForTesting = { _ in await hold.wait() }
        defer { rig.cloud.saveAttemptForTesting = nil }
        let push = Task { await rig.cloud.pushStateChange(event) }
        let started = await waitFor({ hold.waiting == 1 }, timeout: 3)
        XCTAssertTrue(started, "the save is under way")
        rig.cloud.accountStatusForTesting = .error("temporarily unavailable")
        await rig.cloud.refreshAccountState()
        XCTAssertTrue(rig.policy.verified, "a temporary status failure preserves the verification")
        XCTAssertTrue(rig.policy.isCurrent(lease), "a temporary status failure preserves the lease in flight")
        XCTAssertEqual(rig.cloud.lastTransientFailure, CloudExfiltrator.TransientFailure(retryAfter: nil),
                       "on record for the sweep's follow-up")
        hold.release()
        let landed = await push.value
        XCTAssertTrue(landed, "the unrelated save under way lands")
        rig.cloud.accountStatusForTesting = .noAccount
        await rig.cloud.refreshAccountState()
        XCTAssertFalse(rig.policy.isCurrent(lease), "no account still invalidates, as before")
    }

    /// Codex's P4. iCloud throttles the identity lookup with a wait: the push's verdict is a refusal, not interference,
    /// so the engine surfaces it instead of sounding the jamming siren, and the server's wait is kept for the sweep.
    func testAThrottledIdentityLookupIsNoInterference() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        rig.policy.registerLocalEvent(event)
        rig.cloud.accountIdentityForTesting = { throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0]) }
        let outcome = await rig.cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(outcome.metaFailureWasInterference, false, "a throttle is an answer")
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(syncState: outcome.syncState, isStateChange: false,
                                                            interference: outcome.metaFailureWasInterference,
                                                            jammingResponse: true, hadConnectivityAtArm: true,
                                                            online: true, watching: true),
                       .surfaceRefusal, "surfaced, not the siren")
        XCTAssertEqual(rig.cloud.lastTransientFailure?.retryAfter, 120, "the server's wait is kept for the sweep")
    }

    // MARK: - Item 155's S1, S2 and S3 (step 24): Codex's second look

    /// Codex's checkpoint probe (the second look, item 155's S1): keeps the FIRST snapshot the store writes with the
    /// event's media on it, with the media, the attachment intents and the journal as they are at that moment, in a
    /// folder of its own: the disk as a kill right after that write would leave it. Runs on the store's I/O queue.
    private final class CheckpointCapture: @unchecked Sendable {
        private let lock = NSLock()
        let sourceRoot: URL
        let destination: URL
        let eventID: UUID
        private var capturedValue = false
        private var firstStateValue: CloudSyncState?
        private var errorValue: String?

        init(sourceRoot: URL, destination: URL, eventID: UUID) {
            self.sourceRoot = sourceRoot
            self.destination = destination
            self.eventID = eventID
        }
        var captured: Bool { lock.lock(); defer { lock.unlock() }; return capturedValue }
        /// The event's sync state in that first snapshot.
        var firstAttachedState: CloudSyncState? { lock.lock(); defer { lock.unlock() }; return firstStateValue }
        var error: String? { lock.lock(); defer { lock.unlock() }; return errorValue }

        func observe(root: URL, snapshot: [Event], data: Data) {
            guard root.standardizedFileURL == sourceRoot.standardizedFileURL,
                  let row = snapshot.first(where: { $0.id == eventID }), row.mediaFilename != nil else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !capturedValue, errorValue == nil else { return }
            firstStateValue = row.cloudSyncState
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent("events.json"), options: .atomic)
                for name in ["Media", "MediaAttachments"] where fm.fileExists(atPath: root.appendingPathComponent(name).path) {
                    try fm.copyItem(at: root.appendingPathComponent(name), to: destination.appendingPathComponent(name))
                }
                if let journal = try? Data(contentsOf: root.appendingPathComponent("events.journal")) {
                    try journal.write(to: destination.appendingPathComponent("events.journal"), options: .atomic)
                }
                capturedValue = true
            } catch { errorValue = String(describing: error) }
        }
    }

    /// Codex's checkpoint probe (the second look, item 155's S1). The capture is held while a sweep lands the sparse
    /// record (synced); the capture then completes and the photo's upload is refused. The first snapshot written with
    /// the media on it must already carry the upload obligation: a kill right after that write, replayed by opening the
    /// kept folder as a new store, must leave an event that reads pending, whose photo the next sweep offers and whose
    /// loss the cap marks. Red at the step's red commit: the attachment and its reopen were two writes, so that first
    /// snapshot read synced, and the replay relaunched synced, offered no photo and deleted it unmarked.
    func testTheFirstSnapshotWithTheMediaCarriesTheUploadObligation() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let settings = AppSettings()
        settings.enabledSensors = [.touch, .camera]
        settings.captureMode = .photo
        settings.cameraPosition = .front
        settings.cameraReadiness = .batterySaver
        settings.responseMode = .stealth
        settings.illumination = .off
        settings.jammingResponse = false
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.cloudBackup = true
        let camera = FakeCamera()
        let store = EventStore()
        let originalRoot = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let keptRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem152Checkpoint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: keptRoot) }
        var photoAttempts = 0
        rig.cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordType == CloudExfiltrator.photoRecordTypeV2 }) {
                photoAttempts += 1
                throw CKError(.quotaExceeded)
            }
        }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: rig.cloud,
                                                          camera: camera, entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        defer { camera.releaseStills(); engine.disarm(); store.drainIOForTesting(); rig.cloud.saveAttemptForTesting = nil }
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitFor({ engine.state == .armed }, timeout: 4) else { return XCTFail("did not arm") }
        camera.holdStills = true
        engine.handleTrip(.touch)
        guard await waitFor({ !camera.stills.isEmpty }, timeout: 4) else { return XCTFail("capture not held") }
        let id = try XCTUnwrap(store.events.first { !$0.isStateChange }?.id)
        await engine.retryPendingSync()
        XCTAssertEqual(store.events.first { $0.id == id }?.cloudSyncState, .synced, "the sparse sweep landed")
        let capture = CheckpointCapture(sourceRoot: originalRoot, destination: keptRoot, eventID: id)
        EventStore.checkpointObserverForTesting = { root, snapshot, data in capture.observe(root: root, snapshot: snapshot, data: data) }
        camera.releaseStills()
        guard await waitFor({ photoAttempts > 0 && !store.isUploading(id) && engine.state == .armed }, timeout: 5)
        else { return XCTFail("the full media push did not finish") }
        store.drainIOForTesting()
        EventStore.checkpointObserverForTesting = nil
        XCTAssertNil(capture.error)
        guard capture.captured else { return XCTFail("no written snapshot carried the media") }
        XCTAssertEqual(capture.firstAttachedState, .pending, "the first snapshot with the media on it carries the upload obligation")
        XCTAssertEqual(store.events.first { $0.id == id }?.cloudSyncState, .pending, "control: the uninterrupted process reads pending")
        engine.disarm()
        store.drainIOForTesting()

        // The kill replayed: the kept folder opened as a new store, a new uploader on the same enrollment.
        EventStore.rootOverrideForTesting = keptRoot
        let recovered = EventStore()
        EventStore.rootOverrideForTesting = originalRoot
        let restored = try XCTUnwrap(recovered.events.first { $0.id == id })
        let filename = try XCTUnwrap(restored.mediaFilename)
        let mediaURL = recovered.mediaDirectory.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path), "the photo is in the kept folder")
        XCTAssertEqual(restored.cloudSyncState, .pending, "after the relaunch the event still owes its photo")
        let newPolicy = CloudEnrollment(file: rig.directory.appendingPathComponent("enrollment.json"), authenticate: { _ in true })
        let newCloud = CloudExfiltrator(enrollment: newPolicy)
        newCloud.accountIdentityForTesting = { "account-A" }
        var recoveredPhotoAttempts = 0
        newCloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordType == CloudExfiltrator.photoRecordTypeV2
                                            && $0.recordID.recordName.hasSuffix(id.uuidString) }) {
                recoveredPhotoAttempts += 1
                throw CKError(.quotaExceeded)
            }
        }
        let recoveredEngine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: recovered, cloud: newCloud,
                                                                   camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                                   timing: EngineCharacterizationTests.fastTiming))
        defer { recoveredEngine.disarm(); recovered.drainIOForTesting(); newCloud.saveAttemptForTesting = nil }
        let leaseValue = await newCloud.acquireCloudLease()
        let lease = try XCTUnwrap(leaseValue)
        XCTAssertTrue(newPolicy.authorizeUpload(event: restored, lease: lease), "the account authorizes the upload")
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await waitFor({ !recoveredEngine.pendingSweepActive }, timeout: 3)
        await recoveredEngine.retryPendingSync()
        XCTAssertGreaterThan(recoveredPhotoAttempts, 0, "the relaunch's sweep offers the only photo")
        recovered.mediaBudgetForTesting = 0
        let pressure = statusEvent()
        newPolicy.registerLocalEvent(pressure)
        recovered.add(pressure)   // a new record schedules the cap's pass, armed or not
        let pruned = await waitFor({ recovered.events.first { $0.id == id }?.mediaFilename == nil }, timeout: 4)
        XCTAssertTrue(pruned, "the byte-cap pass ran")
        recovered.drainIOForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path), "the only photo was deleted")
        XCTAssertEqual(recovered.events.first { $0.id == id }?.mediaDiscarded, true, "the loss of a never-uploaded photo is marked")
    }

    /// Codex's probe (the second look, item 155's S2). iCloud answers the identity lookup "account temporarily
    /// unavailable": the caller that met it is denied, and nothing else changes: the verification, the lease in flight,
    /// the save under way; the answer goes on record for the sweep's follow-up. Red at the step's red commit: the answer
    /// read as no account and revoked all three.
    func testATemporarilyUnavailableAccountDeniesOnlyItsCaller() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let leaseValue = await rig.cloud.acquireCloudLease()
        let lease = try XCTUnwrap(leaseValue)
        let event = statusEvent()
        rig.policy.registerLocalEvent(event)
        let hold = Hold()
        rig.cloud.saveAttemptForTesting = { _ in await hold.wait() }
        defer { hold.release(); rig.cloud.saveAttemptForTesting = nil }
        let push = Task { await rig.cloud.pushStateChange(event) }
        let started = await waitFor({ hold.waiting == 1 }, timeout: 3)
        XCTAssertTrue(started, "the save is under way")
        rig.cloud.accountIdentityForTesting = { throw CKError(.accountTemporarilyUnavailable) }
        let denied = await rig.cloud.acquireCloudLease()
        XCTAssertNil(denied, "the caller that met the answer is denied")
        XCTAssertTrue(rig.policy.verified, "a temporarily unavailable account preserves the verification")
        XCTAssertTrue(rig.policy.isCurrent(lease), "and the lease in flight")
        XCTAssertEqual(rig.cloud.lastTransientFailure, CloudExfiltrator.TransientFailure(retryAfter: nil),
                       "on record for the sweep's follow-up")
        hold.release()
        let landed = await push.value
        XCTAssertTrue(landed, "the unrelated save under way lands")
    }

    /// Codex's probe (the second look, item 155's S3). The sweep's first identity lookup is throttled with a half-second
    /// wait and the next succeeds: nothing is handed out before the wait, the sweep shows itself waiting, and the second
    /// lookup comes after the wait. Red at the step's red commit: the preflight lookup's wait was dropped by the pass's
    /// own lookup, which ran at once and uploaded.
    func testTheSweepKeepsTheFirstLookupsWait() async throws {
        let rig = try await verifiedRig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let settings = AppSettings()
        settings.cloudBackup = true
        let store = EventStore()
        var timing = EngineCharacterizationTests.fastTiming
        timing.sweepWaitFloor = 0.05
        timing.sweepWaitCeiling = 2
        rig.cloud.saveAttemptForTesting = { _ in }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: rig.cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        defer { engine.disarm(); rig.cloud.saveAttemptForTesting = nil }
        engine.simulateConnectivityForTesting(online: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let settled = await waitFor({ !engine.pendingSweepActive }, timeout: 3)
        XCTAssertTrue(settled, "the launch's own sweep is over")
        let event = statusEvent()
        rig.policy.registerLocalEvent(event)
        store.add(event)
        var lookups: [Date] = []
        var saves = 0
        rig.cloud.saveAttemptForTesting = { _ in saves += 1 }
        rig.cloud.accountIdentityForTesting = {
            lookups.append(Date())
            if lookups.count == 1 { throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 0.5]) }
            return "account-A"
        }
        await engine.retryPendingSync()
        XCTAssertEqual(saves, 0, "nothing is handed out before the wait the server named")
        XCTAssertTrue(engine.pendingSweepWaiting, "the sweep waits it out")
        let ended = await waitFor({ !engine.pendingSweepActive }, timeout: 5)
        XCTAssertTrue(ended, "and finishes by itself")
        XCTAssertGreaterThanOrEqual(saves, 1, "the record went up after the wait")
        XCTAssertGreaterThanOrEqual(lookups.count, 2, "the sweep looked up again")
        if lookups.count >= 2 {
            XCTAssertGreaterThanOrEqual(lookups[1].timeIntervalSince(lookups[0]), 0.45, "the second lookup came after the half second")
        }
    }
}
