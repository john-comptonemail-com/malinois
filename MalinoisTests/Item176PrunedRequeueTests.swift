import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item176PrunedRequeueTests: XCTestCase {
    @MainActor private final class Calls {
        var lookups = 0
        var questions = 0
        var uploaded: [Event] = []
        var photos = 0
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisPrunedRequeue")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func prunedCapture(in store: EventStore, policy: CloudEnrollment? = nil) async throws -> Event {
        var capture = Event(startDate: Date().addingTimeInterval(-120), endDate: Date().addingTimeInterval(-119),
                            triggeredSensors: [.motion], thumbnailData: Data([0xff, 0xd8, 0xff]), cloudSyncState: .synced)
        capture.primaryCamera = "front"
        capture.mediaFilename = UUID().uuidString + ".jpg"
        capture.uploadedMedia = ["front"]
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(try XCTUnwrap(capture.mediaFilename)))
        policy?.registerLocalEvent(capture)
        store.add(capture)
        store.mediaBudgetForTesting = 10
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]))
        let settled = await eventually { store.byteCapPruneIdleForTesting }
        XCTAssertTrue(settled)
        store.drainIOForTesting()
        let pruned = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNil(pruned.mediaFilename)
        XCTAssertNil(pruned.mediaDiscardUnchecked, "a synced cloud-backed prune has no loss check yet")
        XCTAssertNotEqual(pruned.mediaDiscarded, true)
        return pruned
    }

    func testRequeueOwesAnAlreadyPrunedCaptureACheckInTheNewGenerationAndPersistsIt() async throws {
        let store = EventStore()
        let pruned = try await prunedCapture(in: store)
        XCTAssertEqual(store.requeueForReupload { $0.id == pruned.id }, 1)
        let requeued = try XCTUnwrap(store.events.first { $0.id == pruned.id })
        XCTAssertEqual(requeued.cloudSyncState, .pending)
        XCTAssertNil(requeued.uploadedMedia)
        XCTAssertEqual(requeued.receiptEpoch, 1)
        XCTAssertEqual(requeued.mediaDiscardUnchecked, true)
        store.drainIOForTesting()
        let reloaded = EventStore()
        XCTAssertEqual(reloaded.events.first { $0.id == pruned.id }?.mediaDiscardUnchecked, true)
    }

    /// The real sweep checks the pruned capture before sending its metadata-only retry and propagates a confirmed loss.
    /// The model assertions cover the detail view's loss guard; this test does not render the view.
    func testTheSweepSettlesThePrunedCapturesLossBeforeItsRecordOnlyUpload() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let policy = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let enrolled = await policy.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: policy)
        let calls = Calls()
        cloud.accountIdentityForTesting = { calls.lookups += 1; return nil }
        let store = EventStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
            camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
            timing: EngineCharacterizationTests.fastTiming))
        let settled = await eventually { calls.lookups >= 2 && !engine.pendingSweepActive && !engine.cloudRestoreInProgress }
        XCTAssertTrue(settled)
        cloud.accountIdentityForTesting = { "account-a" }
        let pruned = try await prunedCapture(in: store, policy: policy)
        store.requeueForReupload { $0.id == pruned.id }
        let acquired = await cloud.acquireCloudLease()
        let lease = try XCTUnwrap(acquired)
        engine.cloudPresenceForTesting = { _ in nil }
        await engine.checkDiscardedCaptures(lease: lease)
        XCTAssertEqual(store.events.first { $0.id == pruned.id }?.mediaDiscardUnchecked, true, "an unknown answer settles nothing")
        let front = "photo-front-v2-" + pruned.id.uuidString
        engine.cloudPresenceForTesting = { names in Set(names.filter { $0 == front }) }
        await engine.checkDiscardedCaptures(lease: lease)
        XCTAssertEqual(store.events.first { $0.id == pruned.id }?.uploadedMedia, ["front"], "a current presence answer counts")
        XCTAssertNotEqual(store.events.first { $0.id == pruned.id }?.mediaDiscarded, true)
        store.requeueForReupload { $0.id == pruned.id }
        engine.cloudPresenceForTesting = { _ in calls.questions += 1; return [] }
        cloud.saveAttemptForTesting = { records in
            for record in records {
                if record.recordType == CloudExfiltrator.metaRecordTypeV2,
                   record.recordID.recordName == "meta-v2-" + pruned.id.uuidString {
                    calls.uploaded.append(try XCTUnwrap(CloudExfiltrator.event(from: record)))
                }
                if record.recordID.recordName.hasPrefix("photo-") { calls.photos += 1 }
            }
        }
        await engine.retryPendingSync()
        let final = try XCTUnwrap(store.events.first { $0.id == pruned.id })
        XCTAssertGreaterThan(calls.questions, 0)
        XCTAssertEqual(final.mediaDiscarded, true)
        XCTAssertNil(final.mediaDiscardUnchecked)
        XCTAssertEqual(final.cloudSyncState, .synced, "the fact can sync while honestly carrying its capture's loss")
        XCTAssertEqual(calls.photos, 0)
        XCTAssertEqual(calls.uploaded.last?.mediaDiscarded, true)
        XCTAssertTrue(final.fullCaptureMayBeInICloud, "this eligibility hint is independent of the confirmed-loss guard")
        XCTAssertFalse(final.mediaDiscarded != true && final.fullCaptureMayBeInICloud,
                       "the loss/eligibility part of EventDetailView's condition excludes this event")
        var oldMirror = pruned
        oldMirror.sourceDevice = "Other phone"
        oldMirror.cloudRevision = CloudExfiltrator.metaRevision(for: pruned)
        let mirror = EventStore.merged(local: [oldMirror], incoming: calls.uploaded).first
        XCTAssertEqual(mirror?.mediaDiscarded, true)
        store.drainIOForTesting()
        XCTAssertEqual(EventStore().events.first { $0.id == pruned.id }?.mediaDiscarded, true)
    }

    func testOnlyPickedFirsthandPrunedCapturesAcquireANewCheck() {
        func capture() -> Event {
            Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion],
                  primaryCamera: "rear", cloudSyncState: .synced)
        }
        let pruned = capture()
        var secondaryPruned = capture()
        secondaryPruned.primaryCamera = nil
        secondaryPruned.secondaryCamera = "front"
        var primaryHeld = capture()
        primaryHeld.mediaFilename = "primary-still-here.jpg"
        var secondaryHeld = capture()
        secondaryHeld.secondaryCamera = "front"
        secondaryHeld.secondaryMediaFilename = "secondary-still-here.jpg"
        let fact = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
        var mirror = capture()
        mirror.sourceDevice = "Other phone"
        var lost = capture()
        lost.mediaDiscarded = true
        let excluded = capture()
        // This reducer uses persisted filenames, not a filesystem existence check. The real pruning path is above.
        let cases: [(name: String, event: Event, check: Bool?, unchanged: Bool)] = [
            ("primary-only pruned identity", pruned, true, false),
            ("secondary-only pruned identity", secondaryPruned, true, false),
            ("primary local filename remains", primaryHeld, nil, false),
            ("secondary local filename remains", secondaryHeld, nil, false),
            ("no capture identity", fact, nil, false),
            ("another device's mirror", mirror, nil, true),
            ("already confirmed lost", lost, nil, false),
            ("not selected for requeue", excluded, nil, true)
        ]
        let chosen = Set(cases.dropLast().map { $0.event.id })
        let result = EventStore.requeuedForReupload(cases.map { $0.event }, only: chosen)
        XCTAssertEqual(result.changed, 6, "only selected first-hand synced records become pending")
        XCTAssertEqual(result.events.count, cases.count)
        for (sample, after) in zip(cases, result.events) {
            XCTAssertEqual(after.mediaDiscardUnchecked, sample.check, sample.name)
            XCTAssertEqual(after.mediaDiscarded, sample.event.mediaDiscarded, sample.name)
            XCTAssertEqual(after.mediaFilename, sample.event.mediaFilename, sample.name)
            XCTAssertEqual(after.secondaryMediaFilename, sample.event.secondaryMediaFilename, sample.name)
            XCTAssertEqual(after.primaryCamera, sample.event.primaryCamera, sample.name)
            XCTAssertEqual(after.secondaryCamera, sample.event.secondaryCamera, sample.name)
            if sample.unchanged {
                XCTAssertEqual(after, sample.event, sample.name)
            } else {
                XCTAssertEqual(after.cloudSyncState, .pending, sample.name)
                XCTAssertEqual(after.receiptEpoch, 1, sample.name)
            }
        }
    }
}
