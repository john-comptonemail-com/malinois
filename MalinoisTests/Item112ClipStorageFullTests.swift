//
//  Item112ClipStorageFullTests.swift
//  MalinoisTests
//
//  BACKLOG 112 (from item 108, F8): when the store that holds clips until the log takes them is
//  full, a clip fails at once with its own reason and a Home notice, before the camera starts.
//  Before, the camera came up, the front screen flash could light, and the pipeline waited out
//  the clip's whole length recording nothing, then reported a generic failure.
//

import XCTest
@testable import Malinois

@MainActor
final class Item112ClipStorageFullTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item112ClipStorageFullTests")
    }

    override func tearDown() {
        TestIsolation.tearDownFolderAndFlags()
        super.tearDown()
    }

    private static let fastTiming: EngineTiming = {
        var t = EngineTiming.production
        t.reconfigureSettle = 0.01
        t.autoExposureSettle = 0.01
        t.flashSettle = 0.01
        t.untilClearIdle = 0.15
        t.untilClearMax = 1.0
        t.untilClearPoll = 0.02
        t.warmUpDeadline = 0.2
        return t
    }()

    private func makeRig(_ configure: (FakeCamera) -> Void = { _ in })
        -> (pipeline: EvidenceCapturePipeline, camera: FakeCamera, host: FakeCaptureHost) {
        let camera = FakeCamera()
        configure(camera)
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: Self.fastTiming)
        pipeline.host = host
        return (pipeline, camera, host)
    }

    /// A full store fails a clip before the camera starts: no warm-up, no clip, no flash, no
    /// microphone taken from Sound, no wait for the clip's length, and its own reason and notice.
    func testAFullClipStoreFailsAClipBeforeTheCameraStarts() async {
        let rig = makeRig { $0.clipStorageFull = true; $0.lowLight = true }
        let started = Date()
        let outcome = await rig.pipeline.capture(from: .front, mode: .clip5, illumination: .auto)
        XCTAssertEqual(outcome.failure, .storageFull)
        XCTAssertNil(outcome.capture)
        XCTAssertTrue(rig.camera.warmUps.isEmpty, "the camera never started")
        XCTAssertTrue(rig.camera.clips.isEmpty, "no clip was begun")
        XCTAssertFalse(rig.host.flashStates.contains(true), "the screen flash never lit")
        XCTAssertEqual(rig.host.audioPauses, 0, "Sound kept its microphone")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "it did not wait out the 5-second clip")
        XCTAssertEqual(rig.host.notices.last, EvidenceCapturePipeline.clipStorageFullNotice)
    }

    /// Both cameras need two clips' room; without it they fail the same way, multi-cam untouched.
    func testAFullClipStoreFailsBothCameraClipsTheSameWay() async {
        let rig = makeRig { $0.clipStorageFull = true; $0.supportsMultiCam = true }
        let outcome = await rig.pipeline.captureBoth(mode: .clip5, illumination: .off)
        XCTAssertEqual(outcome.failure, .storageFull)
        XCTAssertNil(outcome.front)
        XCTAssertNil(outcome.rear)
        XCTAssertEqual(rig.camera.multiCamWarmUps, 0, "the multi-cam session never started")
        XCTAssertEqual(rig.camera.bothClips, 0)
        XCTAssertEqual(rig.host.notices.last, EvidenceCapturePipeline.clipStorageFullNotice)
    }

    /// A photo goes to the event store, not the clip store, so a full clip store does not stop it.
    func testAFullClipStoreDoesNotStopAPhoto() async {
        let rig = makeRig { $0.clipStorageFull = true }
        let outcome = await rig.pipeline.capture(from: .rear, mode: .photo, illumination: .off)
        XCTAssertNotNil(outcome.capture)
        XCTAssertEqual(rig.camera.stills.count, 1)
        XCTAssertFalse(rig.host.notices.contains(EvidenceCapturePipeline.clipStorageFullNotice))
    }

    /// Once there is room again, the next clip clears the notice and records.
    func testRoomReturningClearsTheNotice() async {
        let rig = makeRig { $0.clipStorageFull = true }
        _ = await rig.pipeline.capture(from: .rear, mode: .clip5, illumination: .off)
        XCTAssertEqual(rig.host.notices.last, EvidenceCapturePipeline.clipStorageFullNotice)
        rig.camera.clipStorageFull = false
        let outcome = await rig.pipeline.capture(from: .rear, mode: .clip5, illumination: .off)
        XCTAssertNotNil(outcome.capture)
        XCTAssertEqual(rig.host.notices.last, .some(nil), "the storage notice was cleared")
    }

    /// Its own words on the event, and nothing to wait for, so no retry.
    func testStorageFullReadsAsItsOwnReasonAndIsNotRetried() {
        XCTAssertFalse(CaptureFailureReason.storageFull.isInterruption)
        XCTAssertTrue(CaptureFailureReason.storageFull.summary.contains("clip storage is full"))
        XCTAssertEqual(CaptureFailureReason(rawValue: "storageFull"), .storageFull, "the stored raw value")
    }
}
