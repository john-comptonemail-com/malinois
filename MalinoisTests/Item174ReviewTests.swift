//
//  Item174ReviewTests.swift
//  MalinoisTests
//
//  Codex's full review of 1.8.2 at 8573b6c (BACKLOG 174; the owner: "as recommended"). Written before the fixes, red at
//  the round's red commit.
//  - codex-1's variant (step 62): after iCloud's copies were found deleted or reset, the upload receipts noted before
//    still said which camera files had reached iCloud, so the byte limit skipped its loss check, the capture read synced
//    with nothing in iCloud, and its download was still offered. Now that loss voids the receipts, for a partly uploaded
//    capture as for a synced one, and neither an older copy of the event nor an upload started before it brings them back.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item174ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem174Review")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// This phone's own one-camera capture, synced, its photo noted as landed.
    private func syncedCapture(minutesAgo: Double = 1) -> Event {
        let at = Date().addingTimeInterval(-60 * minutesAgo)
        var capture = Event(startDate: at, endDate: at.addingTimeInterval(1), triggeredSensors: [.motion],
                            cloudSyncState: .synced)
        capture.mediaFilename = UUID().uuidString + ".jpg"
        capture.primaryCamera = "front"
        capture.uploadedMedia = ["front"]
        return capture
    }

    /// A two-camera capture whose front photo landed and whose rear photo did not, still pending.
    private func partlyUploadedCapture(minutesAgo: Double = 2) -> Event {
        var capture = syncedCapture(minutesAgo: minutesAgo)
        capture.cloudSyncState = .pending
        capture.secondaryMediaFilename = UUID().uuidString + ".jpg"
        capture.secondaryCamera = "rear"
        return capture
    }

    // MARK: - The requeue voids the receipts (step 62)

    /// iCloud's copies found gone: every capture the check picks loses its receipts and moves to a new generation, the
    /// synced one returning to pending, the partly uploaded one as well, a copy from another device untouched. Red at the
    /// round's red commit: the receipts stayed.
    func testARequeueVoidsTheReceiptsOfEveryPickedCapture() throws {
        var mirror = syncedCapture(minutesAgo: 3)
        mirror.sourceDevice = "Desk phone"
        let result = EventStore.requeuedForReupload([syncedCapture(), partlyUploadedCapture(), mirror])
        XCTAssertEqual(result.changed, 1, "only the synced capture returns to pending")
        let (synced, partial, kept) = (result.events[0], result.events[1], result.events[2])
        XCTAssertEqual(synced.cloudSyncState, .pending)
        XCTAssertNil(synced.uploadedMedia, "the synced capture's receipt is void")
        XCTAssertEqual(synced.receiptEpoch, 1)
        XCTAssertEqual(partial.cloudSyncState, .pending)
        XCTAssertNil(partial.uploadedMedia, "the partly uploaded capture's receipt is void")
        XCTAssertEqual(partial.receiptEpoch, 1)
        XCTAssertEqual(kept, mirror, "another device's copy is not this phone's to requeue")
    }

    /// The requeue saves what it voided even when no capture was synced, so a relaunch does not bring the receipts back.
    /// Red at the round's red commit: nothing changed, and nothing was saved.
    func testARequeueOfOnlyAPartlyUploadedCaptureIsSaved() throws {
        let store = EventStore()
        store.add(partlyUploadedCapture())
        store.drainIOForTesting()
        XCTAssertEqual(store.requeueAllForReupload(), 0, "no synced capture to return to pending")
        XCTAssertNil(store.events.first?.uploadedMedia)
        store.drainIOForTesting()
        let reloaded = EventStore()
        XCTAssertNil(reloaded.events.first?.uploadedMedia, "the void receipt is on disk")
        XCTAssertEqual(reloaded.events.first?.receiptEpoch, 1)
    }

    /// Codex's case: a synced capture, iCloud's copies deleted, and then the byte limit takes its photo. The limit no
    /// longer reads the old receipt as "in iCloud": iCloud is asked before the capture is marked lost. Red at the round's
    /// red commit: no check was owed, and the capture would read synced with nothing in iCloud.
    func testTheByteLimitAsksICloudAboutARequeuedCapture() async throws {
        let store = EventStore()
        let capture = syncedCapture()
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(try XCTUnwrap(capture.mediaFilename)))
        store.add(capture)
        store.drainIOForTesting()
        store.requeueAllForReupload()
        store.mediaBudgetForTesting = 10
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !store.byteCapPruneIdleForTesting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        store.drainIOForTesting()
        let trimmed = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNil(trimmed.mediaFilename, "the limit took the photo")
        XCTAssertEqual(trimmed.mediaDiscardUnchecked, true, "iCloud is asked before the capture is called lost or kept")
    }

    /// A copy of the capture from before the loss (an upload's snapshot written back, say) cannot bring its receipt back;
    /// within one generation receipts still only grow. Red at the round's red commit: the older copy's receipt returned.
    func testAnOlderCopyCannotBringAVoidReceiptBack() throws {
        let before = syncedCapture()
        let after = try XCTUnwrap(EventStore.requeuedForReupload([before]).events.first)
        let merged = EventStore.preservingMonotonicFields(current: after, incoming: before)
        XCTAssertNil(merged.uploadedMedia, "the older copy's receipt stays void")
        XCTAssertEqual(merged.receiptEpoch, 1, "and the generation stays")
        var landed = after
        landed.uploadedMedia = ["front"]
        let same = EventStore.preservingMonotonicFields(current: landed, incoming: after)
        XCTAssertEqual(same.uploadedMedia, ["front"], "a receipt of this generation is kept")
    }

    /// A file reported as landed by an upload that began before the loss is not noted: it may have landed in the iCloud
    /// that was then wiped. One of the new generation is. Red at the round's red commit: the older report was noted.
    func testALandingReportedForAnEarlierGenerationIsIgnored() throws {
        let store = EventStore()
        let capture = syncedCapture()
        store.add(capture)
        store.requeueAllForReupload()
        store.noteMediaUploaded("front", for: capture.id, epoch: nil)
        XCTAssertNil(store.events.first?.uploadedMedia, "the upload began before the loss")
        store.noteMediaUploaded("front", for: capture.id, epoch: 1)
        XCTAssertEqual(store.events.first?.uploadedMedia, ["front"], "the re-upload's landing")
    }

    /// The requeued capture offers no download until a file lands again: iCloud holds none of it. Red at the round's red
    /// commit: the old receipt kept the download offered.
    func testARequeuedCaptureOffersNoDownloadUntilAFileLandsAgain() throws {
        var requeued = try XCTUnwrap(EventStore.requeuedForReupload([syncedCapture()]).events.first)
        XCTAssertFalse(requeued.fullCaptureMayBeInICloud, "nothing of it is in iCloud now")
        requeued.uploadedMedia = ["front"]
        XCTAssertTrue(requeued.fullCaptureMayBeInICloud, "once the re-upload lands, the download is offered")
    }

    /// A verified installation's engine, uploader and store, with a pending one-camera capture of this phone's, its photo
    /// on disk and nothing yet noted as landed.
    private func captureReadyToUpload() async throws -> (engine: MonitoringEngine, cloud: CloudExfiltrator,
                                                         store: EventStore, capture: Event) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let store = EventStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let cloud = CloudExfiltrator(enrollment: enrollment)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.simulateConnectivityForTesting(online: true)
        try? await Task.sleep(for: .milliseconds(200))   // the launch sweep finds no identity and ends
        cloud.accountIdentityForTesting = { "account-a" }
        var capture = syncedCapture()
        capture.uploadedMedia = nil
        capture.cloudSyncState = .pending
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(try XCTUnwrap(capture.mediaFilename)))
        enrollment.registerLocalEvent(capture)
        store.add(capture)
        return (engine, cloud, store, capture)
    }

    /// Through the uploader: iCloud's copies are found gone while the capture's photo is being saved. The photo's landing,
    /// reported in the generation the upload began in, is not noted, and the upload's completion leaves the capture
    /// pending, so the re-upload still runs. Red at the round's red commit: the landing restored a receipt.
    func testAnUploadUnderWayAtTheLossNotesNothing() async throws {
        let (engine, cloud, store, capture) = try await captureReadyToUpload()
        cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordID.recordName.hasPrefix("photo-") }) { store.requeueAllForReupload() }
        }
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        let after = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(after.receiptEpoch, 1, "the loss was found during the upload")
        XCTAssertNil(after.uploadedMedia, "the landing from before the loss is not noted")
        XCTAssertEqual(after.cloudSyncState, .pending, "the re-upload is still owed")
    }

    /// Through the uploader: an upload that begins after the loss notes its photo's landing in the new generation, so the
    /// uploader hands the generation on. (An upload reads the stored event as it begins, so a snapshot taken before the
    /// loss uploads as the requeued capture.)
    func testAnUploadAfterTheLossNotesItsLanding() async throws {
        let (engine, cloud, store, capture) = try await captureReadyToUpload()
        cloud.saveAttemptForTesting = { _ in }
        defer { cloud.saveAttemptForTesting = nil }
        store.requeueAllForReupload()
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        let after = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(after.receiptEpoch, 1)
        XCTAssertEqual(after.uploadedMedia, ["front"], "the re-upload's landing is noted")
    }
}
