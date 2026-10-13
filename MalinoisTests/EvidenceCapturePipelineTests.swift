//
//  EvidenceCapturePipelineTests.swift
//  MalinoisTests
//
//  The capture mechanism on its own (1.3 step 5): a fake camera answers the lens, a fake
//  host answers the session. No engine in the loop — the engine's side is pinned by the
//  characterization tests, which drive the real engine through this same pipeline.
//

import XCTest
import AVFoundation
@testable import Malinois

/// Records what a capture asked of the session, and answers with knobs.
@MainActor
final class FakeCaptureHost: CapturePipelineHost {
    var captureSessionIsOver = false
    var mayFlashScreen = true
    var audioHandoffNeeded = false
    private(set) var flashStates: [Bool] = []
    private(set) var rearms = 0
    private(set) var audioPauses = 0
    private(set) var audioResumes = 0
    private(set) var visionSuppressions: [TimeInterval] = []
    private(set) var visionSyncs = 0
    private(set) var notices: [String?] = []
    func setCaptureFlash(_ on: Bool) { flashStates.append(on) }
    func rearmTripwiresDuringCapture() { rearms += 1 }
    @discardableResult func pauseAudioForCapture() -> Bool { audioPauses += 1; return audioHandoffNeeded }
    func resumeAudioAfterCapture() { audioResumes += 1 }
    func suppressVision(for seconds: TimeInterval) { visionSuppressions.append(seconds) }
    func syncVisionTap() { visionSyncs += 1 }
    func report(cameraNotice: String?) { notices.append(cameraNotice) }
    func captureCameraBecameAvailable() {}
    private(set) var lateEvidenceStored = 0
    func captureEvidenceStoredLate() { lateEvidenceStored += 1 }
    func clearCaptureNotice(matching notice: String) {
        if notices.last == notice { notices.append(nil) }
    }
}

@MainActor
final class EvidenceCapturePipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "CameraDeadlineTests")
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

    private struct Rig {
        let pipeline: EvidenceCapturePipeline
        let camera: FakeCamera
        let host: FakeCaptureHost
    }

    private func makeRig(_ configure: (FakeCamera) -> Void = { _ in }) -> Rig {
        let camera = FakeCamera()
        configure(camera)
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: Self.fastTiming)
        pipeline.host = host
        return Rig(pipeline: pipeline, camera: camera, host: host)
    }

    // MARK: - Whole-attempt deadlines and measured movies

    /// A held post-warmup query cannot wedge the caller. The fake does not simulate AVFoundation.
    func testLightProbeCannotOutliveAttemptDeadline() async {
        await characterizeHeldProbe(mode: .photo, illumination: .auto)
    }

    /// A blocked interruption query cannot defeat the whole-attempt ceiling.
    func testInterruptionProbeCannotOutliveAttemptDeadline() async {
        await characterizeHeldProbe(mode: .untilClear, illumination: .off)
    }

    private func characterizeHeldProbe(mode: CaptureMode, illumination: IlluminationMode) async {
        let gate = InvestigationCaptureGate()
        let camera = FakeCamera()
        if mode == .photo {
            camera.lowLightProbeForTesting = { await gate.wait(); return false }
        } else {
            camera.interruptionProbeForTesting = { await gate.wait(); return true }
        }
        var timing = Self.fastTiming
        timing.warmUpDeadline = 0.02
        timing.untilClearIdle = 0.03
        timing.untilClearMax = 0.05
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        var finished = false
        let capture = Task { @MainActor in
            let result = await pipeline.capture(from: .front, mode: mode, illumination: illumination)
            finished = true
            return result
        }
        // Always releases the only injected suspension, even if an assertion fails.
        // Explicit release below is the normal path; await both tasks before leaving.
        let safetyRelease = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await gate.release()
        }
        let entryDeadline = Date().addingTimeInterval(1)
        while !(await gate.entered), Date() < entryDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.entered
        try? await Task.sleep(for: .milliseconds(150))
        let finishedWhileHeld = finished
        let prematurelyStartedStills = camera.stills.count
        let prematurelyEndedClips = camera.clipEnds
        await gate.release()
        let result = await capture.value
        safetyRelease.cancel()
        await safetyRelease.value
        defer { if case .clip(let url) = result.capture?.source { try? FileManager.default.removeItem(at: url) } }

        XCTAssertTrue(entered, "must reach the post-warmup dependency, not merely delay task scheduling")
        XCTAssertTrue(finishedWhileHeld, "whole-attempt deadline must return while the camera dependency is held")
        XCTAssertEqual(prematurelyStartedStills, 0)
        XCTAssertEqual(prematurelyEndedClips, 0)
        XCTAssertNotNil(result.failure, "expiry must report failure without taking new evidence after the deadline")
    }

    /// Early disarm preserves the real short movie and labels its encoded duration.
    func testEarlyDisarmLabelsActualMovieDuration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureInvestigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("short.mov")
        try await EventTests.playableClip(at: movie, frames: 4)
        let assetDuration = try await AVURLAsset(url: movie).load(.duration).seconds
        XCTAssertEqual(assetDuration, 0.4, accuracy: 0.05, "fixture must really contain a short video")
        let rig = makeRig { $0.finalizedClipForTesting = movie }
        let disarm = Task { @MainActor in
            let deadline = Date().addingTimeInterval(1)
            while rig.camera.clips.isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let began = !rig.camera.clips.isEmpty
            rig.host.captureSessionIsOver = true
            rig.camera.shutDown() // models the engine's disarm; fake returns the finalized partial
            return began
        }
        let outcome = await rig.pipeline.capture(from: .front, mode: .clip3, illumination: .off)
        let disarmedDuringClip = await disarm.value
        let capture = try XCTUnwrap(outcome.capture)
        XCTAssertTrue(disarmedDuringClip)
        XCTAssertEqual(capture.camera, .front)
        XCTAssertNil(outcome.failure, "a surviving file is currently represented as a successful capture")
        XCTAssertEqual(try XCTUnwrap(capture.duration), assetDuration, accuracy: 0.05, "label must measure this movie, not time spent waiting")
        guard case .clip(let returnedURL) = capture.source else { return XCTFail("expected preserved movie") }
        XCTAssertEqual(returnedURL, movie, "partial evidence must survive; do not fix labeling by discarding it")
        let retainedDuration = try await AVURLAsset(url: returnedURL).load(.duration).seconds
        XCTAssertEqual(retainedDuration, assetDuration, accuracy: 0.001)
        XCTAssertEqual(rig.host.audioResumes, 1)
    }

    func testCancelledQueuedWorkerCannotTouchReplacementWatch() async {
        let gate = InvestigationCaptureGate()
        let rig = makeRig()
        rig.host.audioHandoffNeeded = true
        rig.pipeline.beforeAttemptWorkForTesting = { await gate.wait() }
        let task = Task { await rig.pipeline.capture(from: .front, mode: .clip3, illumination: .off) }
        let end = Date().addingTimeInterval(1)
        while !(await gate.entered), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        rig.pipeline.cancelUntilClear()
        rig.host.captureSessionIsOver = false
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result.failure, .disarmed)
        XCTAssertEqual(rig.host.audioPauses, 0, "the replacement Sound recorder must not be borrowed")
        XCTAssertEqual(rig.host.visionSyncs, 0)
        XCTAssertTrue(rig.host.visionSuppressions.isEmpty)
        XCTAssertTrue(rig.camera.warmUps.isEmpty)
        XCTAssertEqual(rig.camera.attemptBegins, 0)
    }

    func testBothPhotoPreservesFrontWhileRearDelegateIsStalled() async throws {
        try await assertIndependentPhoto(heldLens: .rear)
    }

    func testBothPhotoPreservesRearWhileFrontDelegateIsStalled() async throws {
        try await assertIndependentPhoto(heldLens: .front)
    }

    private func assertIndependentPhoto(heldLens: CameraChoice) async throws {
        let gate = InvestigationCaptureGate()
        let camera = FakeCamera()
        camera.supportsMultiCam = true
        camera.heldBothPhotoLensForTesting = heldLens
        camera.bothPhotoProbeForTesting = { await gate.wait() }
        var timing = Self.fastTiming
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        store.add(event)
        let result = await pipeline.captureBoth(mode: .photo, illumination: .off,
                                                preservation: .init(event: event, store: store))
        XCTAssertEqual(result.failure, .captureTimedOut)
        try? await Task.sleep(for: .milliseconds(150))
        let current = try XCTUnwrap(store.events.first { $0.id == event.id })
        XCTAssertNotNil(heldLens == .rear ? current.mediaFilename : current.secondaryMediaFilename,
                        "the finished lens must survive while its sibling callback remains blocked")
        XCTAssertNil(heldLens == .rear ? current.secondaryMediaFilename : current.mediaFilename)
        await gate.release()
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testStillCompletedBeforeBlockedShutdownSurvivesDeadline() async throws {
        let gate = InvestigationCaptureGate()
        let camera = FakeCamera()
        camera.quarantineFinishProbeForTesting = { await gate.wait() }
        var timing = Self.fastTiming
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        camera.onStillCapturedForTesting = { pipeline.cancelUntilClear() }
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        store.add(event)
        let result = await pipeline.capture(from: .front, mode: .photo, illumination: .off,
                                            preservation: .init(event: event, store: store))
        XCTAssertEqual(result.failure, .disarmed)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(store.events.first { $0.id == event.id }?.mediaFilename,
                        "the completed still must be retained even when shutdown confirmation stalls")
        await gate.release()
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testLateFinalizationPreservesOriginalEventAndCannotTouchRearmedHost() async throws {
        let gate = InvestigationCaptureGate()
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try await EventTests.playableClip(at: movie, frames: 4)
        defer { try? FileManager.default.removeItem(at: movie) }
        let camera = FakeCamera()
        camera.finalizedClipForTesting = movie
        camera.endClipProbeForTesting = { await gate.wait() }
        var timing = Self.fastTiming
        timing.untilClearIdle = 0.02
        timing.untilClearMax = 0.04
        timing.captureFinalizationDeadline = 0.04
        let host = FakeCaptureHost()
        host.audioHandoffNeeded = true
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
        store.add(event)
        let other = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        store.add(other)
        let outcome = await pipeline.capture(from: .rear, mode: .untilClear, illumination: .off,
                                             preservation: .init(event: event, store: store))
        XCTAssertEqual(outcome.failure, .captureTimedOut)
        let entered = await gate.entered
        XCTAssertTrue(entered)
        pipeline.cancelUntilClear()
        host.captureSessionIsOver = false // a replacement watch starts before the old callback
        XCTAssertEqual(host.audioResumes, 0)
        XCTAssertTrue(host.notices.compactMap { $0 }.contains { $0.contains("Sound detection stays paused") })
        let resumes = host.audioResumes
        let rearms = host.rearms
        let denied = await pipeline.capture(from: .front, mode: .photo, illumination: .on)
        XCTAssertEqual(denied.failure, .cameraBusy)
        camera.emitFinalizedClipForTesting(movie, camera: .rear)
        let end = Date().addingTimeInterval(3)
        while store.events.first(where: { $0.id == event.id })?.mediaFilename == nil, Date() < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let recovered = try XCTUnwrap(store.events.first(where: { $0.id == event.id }))
        XCTAssertNotNil(recovered.mediaFilename)
        XCTAssertEqual(try XCTUnwrap(recovered.primaryDuration), 0.4, accuracy: 0.05)
        XCTAssertEqual(recovered.primaryCamera, "rear")
        XCTAssertNil(recovered.secondaryMediaFilename)
        XCTAssertEqual(recovered.captureFailuresByCamera?["rear"], CaptureFailureReason.captureTimedOut.rawValue)
        XCTAssertEqual(recovered.cloudSyncState, .pending)
        XCTAssertNil(store.events.first(where: { $0.id == other.id })?.mediaFilename)
        XCTAssertEqual(host.audioResumes, resumes, "late worker cannot resume replacement session audio")
        XCTAssertEqual(host.rearms, rearms, "late worker cannot rearm replacement tripwires")
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
    }

    func testStalledStillReturnsAndKeepsNewCaptureQuarantinedUntilCallback() async {
        let camera = FakeCamera()
        camera.holdStills = true
        var timing = Self.fastTiming
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        let outcome = await pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertEqual(outcome.failure, .captureTimedOut)
        let busy = await pipeline.capture(from: .rear, mode: .photo, illumination: .off)
        XCTAssertEqual(busy.failure, .cameraBusy)
        XCTAssertEqual(camera.stills.count, 1)
        camera.releaseStills()
        try? await Task.sleep(for: .milliseconds(30))
        let next = await pipeline.capture(from: .rear, mode: .photo, illumination: .off)
        XCTAssertNotNil(next.capture)
        XCTAssertEqual(camera.stills.count, 2)
    }

    func testDisarmRearmDuringLightQueryDoesNotStartCaptureOrResumeNewAudio() async {
        let gate = InvestigationCaptureGate()
        let rig = makeRig { $0.lowLightProbeForTesting = { await gate.wait(); return true } }
        let task = Task { await rig.pipeline.capture(from: .front, mode: .clip3, illumination: .auto) }
        let end = Date().addingTimeInterval(1)
        while !(await gate.entered), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        rig.pipeline.cancelUntilClear()
        rig.host.captureSessionIsOver = false
        let resumes = rig.host.audioResumes
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result.failure, .disarmed)
        XCTAssertTrue(rig.camera.clips.isEmpty)
        XCTAssertTrue(rig.host.flashStates.isEmpty)
        XCTAssertEqual(rig.host.audioResumes, resumes)
    }

    func testDeadlineStillRunsWhileDisarmShutdownConfirmationIsBlocked() async {
        let gate = InvestigationCaptureGate()
        let camera = FakeCamera()
        camera.quarantineFinishProbeForTesting = { await gate.wait() }
        var timing = Self.fastTiming
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        camera.onWarmUpForTesting = { pipeline.cancelUntilClear() }
        let safety = Task { try? await Task.sleep(for: .seconds(2)); await gate.release() }
        let start = ContinuousClock.now
        let outcome = await pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1), "shutdown confirmation is part of the bounded caller")
        XCTAssertEqual(outcome.failure, .disarmed)
        await gate.release()
        safety.cancel()
        await safety.value
    }

    func testSoundDoesNotResumeUntilCameraShutdownIsConfirmed() async {
        let finalization = InvestigationCaptureGate()
        let shutdown = InvestigationCaptureGate()
        let camera = FakeCamera()
        camera.endClipProbeForTesting = { await finalization.wait() }
        camera.quarantineFinishProbeForTesting = { await shutdown.wait() }
        var timing = Self.fastTiming
        timing.untilClearIdle = 0.02
        timing.untilClearMax = 0.04
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        host.audioHandoffNeeded = true
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        let outcome = await pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertEqual(outcome.failure, .captureTimedOut)
        XCTAssertEqual(host.audioResumes, 0)
        await finalization.release()
        let end = Date().addingTimeInterval(2)
        while !(await shutdown.entered), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        let entered = await shutdown.entered
        XCTAssertTrue(entered)
        XCTAssertEqual(host.audioResumes, 0)
        await shutdown.release()
        let resumeEnd = Date().addingTimeInterval(1)
        while host.audioResumes == 0, Date() < resumeEnd { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(host.audioResumes, 1)
    }

    func testBothMoviesMeasureEachLensIndependently() async throws {
        let front = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let rear = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: front); try? FileManager.default.removeItem(at: rear) }
        try await EventTests.playableClip(at: front, frames: 4)
        try await EventTests.playableClip(at: rear, frames: 7)
        let rig = makeRig { $0.finalizedBothForTesting = (front, rear) }
        let result = await rig.pipeline.captureBoth(mode: .untilClear, illumination: .off)
        XCTAssertEqual(try XCTUnwrap(result.front?.duration), 0.4, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(result.rear?.duration), 0.7, accuracy: 0.05)
        XCTAssertNil(result.front?.issue)
        XCTAssertNil(result.rear?.issue)
    }

    func testBothKeepsFinishedFrontEvenWhileRearDelegateIsStillHeld() async throws {
        let gate = InvestigationCaptureGate()
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await EventTests.playableClip(at: movie, frames: 4)
        let camera = FakeCamera()
        camera.finalizedBothForTesting = (movie, nil)
        camera.rearFinalizeProbeForTesting = { await gate.wait() }
        var timing = Self.fastTiming
        timing.untilClearIdle = 0.02
        timing.untilClearMax = 0.05
        timing.captureFinalizationDeadline = 0.1
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        store.add(event)
        let outcome = await pipeline.captureBoth(mode: .untilClear, illumination: .off,
                                                 preservation: .init(event: event, store: store))
        XCTAssertEqual(outcome.failure, .captureTimedOut)
        let deadline = Date().addingTimeInterval(2)
        while store.events.first?.mediaFilename == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.events.first?.mediaFilename, "finished lens must be attached before the other callback answers")
        XCTAssertNil(store.events.first?.secondaryMediaFilename)
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
    }

    func testValidMovieWithIncompleteDelegateOutcomeIsKeptAsPartial() async throws {
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await EventTests.playableClip(at: movie, frames: 4)
        let rig = makeRig { $0.finalizedClipForTesting = movie; $0.recordingSuccessForTesting = false }
        let result = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertEqual(result.capture?.issue, .clipPartial)
        XCTAssertEqual(try XCTUnwrap(result.capture?.duration), 0.4, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    }

    func testOpaqueFileIsPreservedWithoutInventingDuration() async throws {
        let rig = makeRig()
        let outcome = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        let capture = try XCTUnwrap(outcome.capture)
        XCTAssertNil(capture.duration)
        XCTAssertEqual(capture.issue, .clipUnverified)
        guard case .clip(let url) = capture.source else { return XCTFail("expected preserved file") }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), Data("fake-clip-payload".utf8))
    }

    func testDelegateSuccessFlagDoesNotDiscardUsableErrorOutput() {
        XCTAssertTrue(CameraController.recordingSucceeded(error: nil))
        XCTAssertTrue(CameraController.recordingSucceeded(error: NSError(domain: AVFoundationErrorDomain,
            code: -11818, userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])))
        XCTAssertFalse(CameraController.recordingSucceeded(error: NSError(domain: AVFoundationErrorDomain,
            code: -11818, userInfo: [AVErrorRecordingSuccessfullyFinishedKey: false])))
        XCTAssertFalse(CameraController.recordingSucceeded(error: NSError(domain: AVFoundationErrorDomain, code: -11818)))
    }

    // MARK: - Illumination

    /// A front still lights the scene with the screen, never the LED; the flash is raised
    /// before the shot and dropped after it.
    func testAFrontStillFlashesTheScreenNotTheLED() async throws {
        let rig = makeRig()
        let captured = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .on)
        let capture = try XCTUnwrap(captured.capture)
        XCTAssertEqual(capture.camera, .front)
        XCTAssertEqual(capture.ext, "jpg")
        XCTAssertEqual(capture.duration, 0, "stills have no clip length")
        XCTAssertEqual(rig.camera.stills, [false], "no hardware flash on the front camera")
        XCTAssertEqual(rig.host.flashStates, [true, false], "screen flash raised, then dropped")
        XCTAssertEqual(rig.camera.warmUps.map(\.camera), [.front])
        XCTAssertEqual(rig.host.visionSyncs, 1)
        XCTAssertEqual(rig.host.visionSuppressions, [4])
    }

    // MARK: - A capture cut short by the disarm (item 63 leg 6)

    /// The owner's disarm stops the camera; the still that was in flight fails. That is not a
    /// camera fault: the record says "disarmed" and Home gets no notice.
    func testAStillThatFailsAfterTheDisarmIsClassifiedAsDisarmedAndPostsNoNotice() async {
        let rig = makeRig { $0.stillError = CameraController.CameraError.captureFailed }
        rig.host.captureSessionIsOver = true
        let outcome = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertNil(outcome.capture)
        XCTAssertEqual(outcome.failure, .disarmed)
        XCTAssertTrue(rig.host.notices.isEmpty, "no Home notice for a capture the owner ended")
        XCTAssertFalse(CaptureFailureReason.disarmed.isInterruption, "nothing to retry after a disarm")
        XCTAssertEqual(CaptureFailureReason.disarmed.summary, "monitoring was disarmed during the capture")
    }

    /// The same failure while the session is live is the fault it always was.
    func testAStillThatFailsWhileArmedStillPostsTheNotice() async {
        let rig = makeRig { $0.stillError = CameraController.CameraError.captureFailed }
        let outcome = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertEqual(outcome.failure, .captureFailed)
        XCTAssertEqual(rig.host.notices.count, 1)
    }

    /// A warm-up that fails because the disarm shut the session down is "disarmed" too.
    func testAWarmUpThatFailsAfterTheDisarmIsDisarmedNotUnavailable() async {
        let rig = makeRig { $0.warmUpError = CameraController.CameraError.unavailable }
        rig.host.captureSessionIsOver = true
        let outcome = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertEqual(outcome.failure, .disarmed)
        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    /// A rear still uses the hardware flash and leaves the screen alone.
    func testARearStillUsesTheHardwareFlashNotTheScreen() async {
        let rig = makeRig()
        let capture = await rig.pipeline.capture(from: .rear, mode: .photo, illumination: .on).capture
        XCTAssertEqual(capture?.camera, .rear)
        XCTAssertEqual(rig.camera.stills, [true], "hardware flash on the rear camera")
        XCTAssertTrue(rig.host.flashStates.isEmpty, "the screen is not flashed for a rear shot")
    }

    /// Auto lights only a dim scene.
    func testAutoIlluminationFollowsTheLightReading() async {
        let dark = makeRig { $0.lowLight = true }
        _ = await dark.pipeline.capture(from: .front, mode: .photo, illumination: .auto)
        XCTAssertEqual(dark.host.flashStates, [true, false], "dim scene → lit")

        let bright = makeRig { $0.lowLight = false }
        _ = await bright.pipeline.capture(from: .front, mode: .photo, illumination: .auto)
        XCTAssertTrue(bright.host.flashStates.isEmpty, "bright scene → unlit")
    }

    /// Off never lights, however dark.
    func testIlluminationOffNeverLights() async {
        let rig = makeRig { $0.lowLight = true }
        _ = await rig.pipeline.capture(from: .rear, mode: .photo, illumination: .off)
        XCTAssertEqual(rig.camera.stills, [false])
        XCTAssertTrue(rig.host.flashStates.isEmpty)
    }

    /// The host can forbid the screen flash (PIN pad up, alert already on screen): the shot
    /// is still taken, unlit.
    func testTheScreenFlashYieldsToTheHost() async {
        let rig = makeRig()
        rig.host.mayFlashScreen = false
        let outcome = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .on)
        XCTAssertNotNil(outcome.capture)
        XCTAssertEqual(rig.host.flashStates, [false], "only the trailing drop — nothing was raised")
    }

    // MARK: - Warm-up

    /// A camera that cannot be warmed fails the capture cleanly, with the owner's notice and
    /// no attempt to shoot from whatever was configured.
    func testAWarmUpFailureFailsTheCaptureWithANotice() async {
        let rig = makeRig { $0.warmUpError = CameraController.CameraError.unauthorized }
        let outcome = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .on)
        XCTAssertNil(outcome.capture)
        XCTAssertEqual(outcome.failure, .unauthorized, "the reason travels with the failure (54)")
        XCTAssertTrue(rig.camera.stills.isEmpty, "nothing shot")
        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertTrue(rig.host.notices.first??.contains("Camera unavailable") == true)
    }

    /// A warm-up that outlives the deadline is abandoned: the capture fails promptly instead
    /// of wedging the trigger path (34's H10).
    func testAWarmUpPastTheDeadlineFailsTheCapturePromptly() async {
        let rig = makeRig { $0.warmUpDelay = 3 }
        let started = Date()
        let outcome = await rig.pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertNil(outcome.capture)
        XCTAssertEqual(outcome.failure, .warmUpTimedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "gave up at the deadline, not after the warm-up")
        XCTAssertTrue(rig.host.notices.first??.contains("Camera unavailable") == true)
    }

    // MARK: - Build52: warm camera must reacquire audio after Sound yields it

    func testSoundHandoffStopsTheWarmCameraBeforeRewarmingForAClip() async {
        let rig = makeRig()
        rig.host.audioHandoffNeeded = true
        rig.camera.shutDownDelay = 0.02
        rig.camera.onWarmUpForTesting = { [weak host = rig.host, weak camera = rig.camera] in
            XCTAssertEqual(host?.audioPauses, 1, "Sound yields before the capture session starts")
            XCTAssertEqual(camera?.shutDowns, 1, "wait for the old session to stop before rewarming")
        }
        let outcome = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertNotNil(outcome.capture)
        XCTAssertEqual(rig.host.audioResumes, 1)
    }

    func testSoundResumesWhenHandoffWarmupFails() async {
        let rig = makeRig { $0.warmUpError = CameraController.CameraError.unavailable }
        rig.host.audioHandoffNeeded = true
        let outcome = await rig.pipeline.capture(from: .front, mode: .clip3, illumination: .off)
        XCTAssertEqual(outcome.failure, .cameraUnavailable)
        XCTAssertEqual(rig.host.audioPauses, 1)
        XCTAssertEqual(rig.host.audioResumes, 1)
        XCTAssertTrue(rig.camera.clips.isEmpty)
    }

    func testSoundHandoffShutdownSharesTheWarmupDeadline() async {
        let rig = makeRig { $0.shutDownDelay = 0.5 }
        rig.host.audioHandoffNeeded = true
        let outcome = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertEqual(outcome.failure, .warmUpTimedOut)
        XCTAssertTrue(rig.camera.clips.isEmpty)
        XCTAssertEqual(rig.host.audioResumes, 0, "the microphone stays quarantined until shutdown confirms")
        try? await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(rig.host.audioResumes, 1)
        XCTAssertTrue(rig.camera.warmUps.isEmpty, "a late shutdown must not restart an abandoned capture")
    }

    func testVideoOnlyCaptureDoesNotRestartTheCameraForAudio() async {
        let rig = makeRig()
        let outcome = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertNotNil(outcome.capture)
        XCTAssertEqual(rig.camera.shutDowns, 0)
    }

    func testDisarmDuringAnExpiredAudioHandoffCannotRestartCamera() async {
        let rig = makeRig { $0.shutDownDelay = 0.5 }
        rig.host.audioHandoffNeeded = true
        let disarm = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            rig.host.captureSessionIsOver = true
        }
        let outcome = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        await disarm.value
        XCTAssertEqual(outcome.failure, .disarmed)
        try? await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertTrue(rig.camera.warmUps.isEmpty)
        XCTAssertTrue(rig.camera.clips.isEmpty)
        XCTAssertEqual(rig.host.audioResumes, 0, "unconfirmed shutdown must not resume Sound, even after disarm")
    }

    // MARK: - Until clear

    /// A quiet scene ends the clip after the idle window: audio was freed for the clip and
    /// handed back, the tripwires were re-armed while it rolled, and the flag cleared.
    func testUntilClearEndsWhenTheSceneGoesQuiet() async throws {
        let rig = makeRig()
        let started = Date()
        let captured = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        let capture = try XCTUnwrap(captured.capture)
        XCTAssertEqual(capture.ext, "mov")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15, "held at least the idle window")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6, "and not much longer — the scene was quiet")
        XCTAssertEqual(rig.camera.clips, [false])
        XCTAssertEqual(rig.camera.clipEnds, 1)
        XCTAssertEqual(rig.host.audioPauses, 1)
        XCTAssertEqual(rig.host.audioResumes, 1)
        XCTAssertGreaterThan(rig.host.rearms, 0, "tripwires re-armed during the recording")
        XCTAssertFalse(rig.pipeline.isCapturingUntilClear)
    }

    /// Continued activity holds the clip open until the ceiling.
    func testUntilClearHoldsWhileActivityContinuesUntilTheCeiling() async throws {
        let rig = makeRig()
        let feeder = Task { @MainActor in
            for _ in 0..<40 {   // 40 × 50 ms = 2 s of activity, past the 1 s ceiling
                try? await Task.sleep(nanoseconds: 50_000_000)
                rig.pipeline.noteActivity()
            }
        }
        let started = Date()
        let captured = await rig.pipeline.capture(from: .rear, mode: .untilClear, illumination: .off)
        _ = try XCTUnwrap(captured.capture)
        feeder.cancel()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9, "held to the ceiling")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.6)
    }

    /// An interrupted camera session (the app backgrounded) finalizes the clip at once,
    /// keeping the partial, instead of waiting out the ceiling.
    func testUntilClearFinalizesWhenTheCameraSessionIsInterrupted() async throws {
        let rig = makeRig { $0.clipInterrupted = true }
        let started = Date()
        let captured = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        _ = try XCTUnwrap(captured.capture)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15, "finalized at the first poll")
        XCTAssertEqual(rig.camera.clipEnds, 1, "the partial is kept")
    }

    /// The session ending mid-recording finalizes the clip at the next poll.
    func testUntilClearFinalizesWhenTheSessionEnds() async throws {
        let rig = makeRig()
        let ender = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            rig.host.captureSessionIsOver = true
            rig.pipeline.cancelUntilClear()
        }
        // Keep the scene "active" so only the session's end can stop it.
        let feeder = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                rig.pipeline.noteActivity()
            }
        }
        let started = Date()
        let captured = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        _ = try XCTUnwrap(captured.capture)
        ender.cancel(); feeder.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "stopped when the session ended, well before the ceiling")
    }

    // MARK: - Failure reasons (item 54)

    /// A clip that fails while the session was interrupted names the interruption; one that
    /// fails with no interruption is a plain capture failure.
    func testAFailedClipReportsTheInterruptionReason() async {
        let interrupted = makeRig {
            $0.clipEndError = CameraController.CameraError.captureFailed
            $0.interruptionReasonValue = .background
        }
        let outcome = await interrupted.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertEqual(outcome.failure, .interruptedInBackground)
        XCTAssertEqual(interrupted.host.audioResumes, 1, "the microphone is handed back even on failure")
        XCTAssertTrue(interrupted.host.notices.first??.contains("capture failed") == true)

        let plain = makeRig { $0.clipEndError = CameraController.CameraError.captureFailed }
        let plainOutcome = await plain.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        XCTAssertEqual(plainOutcome.failure, .captureFailed)
    }

    /// A still that fails classifies the same way.
    func testAFailedStillReportsItsReason() async {
        let rig = makeRig {
            $0.stillError = CameraController.CameraError.captureFailed
            $0.interruptionReasonValue = .anotherApp
        }
        let outcome = await rig.pipeline.capture(from: .rear, mode: .photo, illumination: .off)
        XCTAssertEqual(outcome.failure, .interruptedByAnotherApp)
        XCTAssertEqual(rig.camera.stills.count, 1, "the shot was attempted")
    }

    /// The pure classifiers, as truth tables, plus the wording every reason must carry.
    func testFailureReasonClassifiersAndWording() {
        XCTAssertEqual(CaptureFailureReason.forWarmUpFailure(CameraController.CameraError.unauthorized), .unauthorized)
        XCTAssertEqual(CaptureFailureReason.forWarmUpFailure(CameraController.CameraError.timedOut), .warmUpTimedOut)
        XCTAssertEqual(CaptureFailureReason.forWarmUpFailure(CameraController.CameraError.unavailable), .cameraUnavailable)
        XCTAssertEqual(CaptureFailureReason.forWarmUpFailure(NSError(domain: "AVFoundation", code: -11800)), .cameraUnavailable)
        XCTAssertEqual(CaptureFailureReason.forCaptureFailure(interruption: nil), .captureFailed)
        XCTAssertEqual(CaptureFailureReason.forCaptureFailure(interruption: .background), .interruptedInBackground)
        XCTAssertEqual(CaptureFailureReason.forCaptureFailure(interruption: .anotherApp), .interruptedByAnotherApp)
        XCTAssertEqual(CaptureFailureReason.forCaptureFailure(interruption: .audioClient), .interruptedByAudioClient)
        XCTAssertEqual(CaptureFailureReason.forCaptureFailure(interruption: .systemPressure), .interruptedBySystemPressure)
        XCTAssertEqual(CaptureFailureReason.forCaptureFailure(interruption: .unknown), .interrupted)
        let interruptions = CaptureFailureReason.allCases.filter(\.isInterruption)
        XCTAssertEqual(Set(interruptions), [.interruptedInBackground, .interruptedByAnotherApp, .interruptedByAudioClient,
                                            .interruptedBySystemPressure, .interrupted])
        let summaries = CaptureFailureReason.allCases.map(\.summary)
        XCTAssertEqual(Set(summaries).count, summaries.count, "every reason reads differently")
        XCTAssertTrue(summaries.allSatisfy { !$0.isEmpty && $0.first!.isLowercase }, "each is a clause that follows a dash")
    }

    // MARK: - Both cameras

    /// When the multi-cam session cannot come up, the capture falls back to the front camera
    /// alone and says so.
    func testBothCamerasFallBackToFrontOnlyWhenMultiCamFails() async {
        let rig = makeRig { $0.warmUpError = CameraController.CameraError.captureFailed }
        let both = await rig.pipeline.captureBoth(mode: .photo, illumination: .off)
        XCTAssertNil(both.front, "the fallback's own warm-up fails too on this camera")
        XCTAssertNil(both.rear)
        XCTAssertEqual(both.failure, .cameraUnavailable, "the fallback's reason is the record's reason")
        XCTAssertTrue(rig.host.notices.first??.contains("Multi-cam capture unavailable") == true)
        XCTAssertEqual(rig.camera.bothStills, 0)

        // A camera whose multi-cam alone is unavailable is not fakeable here (one error knob
        // covers both warm-ups); the front-only path itself is pinned above.
    }

    /// Both stills, each lit its own way: the screen for the front lens, the LED for the rear.
    func testBothCamerasCaptureStillsWithPerCameraIllumination() async throws {
        let rig = makeRig { $0.supportsMultiCam = true }
        let both = await rig.pipeline.captureBoth(mode: .photo, illumination: .on)
        XCTAssertEqual(both.front?.camera, .front)
        XCTAssertEqual(both.rear?.camera, .rear)
        XCTAssertEqual(rig.camera.multiCamWarmUps, 1)
        XCTAssertEqual(rig.camera.bothStills, 1)
        XCTAssertEqual(rig.host.flashStates, [true, false], "screen flash for the front lens")
        XCTAssertEqual(rig.host.notices, [nil], "a working multi-cam clears any earlier notice")
    }

    func testBothCaptureReportsMissingFrontWhileKeepingRear() async {
        let rig = makeRig { $0.omittedBothCameras = ["front"] }
        let result = await rig.pipeline.captureBoth(mode: .photo, illumination: .off)
        XCTAssertNil(result.front)
        XCTAssertNotNil(result.rear)
        XCTAssertNil(result.failure, "surviving evidence must not be presented as a total failure")
        XCTAssertEqual(result.failuresByCamera, ["front": .captureFailed])
        XCTAssertNotNil(rig.host.notices.last ?? nil)
    }

    func testBothCaptureReportsMissingRearClipWhileKeepingFront() async {
        let rig = makeRig { $0.omittedBothCameras = ["rear"] }
        let result = await rig.pipeline.captureBoth(mode: .clip3, illumination: .off)
        defer { if case .clip(let url) = result.front?.source { try? FileManager.default.removeItem(at: url) } }
        XCTAssertNotNil(result.front)
        XCTAssertNil(result.rear)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.failuresByCamera, ["rear": .captureFailed])
        XCTAssertNotNil(rig.host.notices.last ?? nil)
    }

    func testBothCaptureKeepsTheInterruptionReasonForEachMissingLens() async {
        let rig = makeRig {
            $0.omittedBothCameras = ["front", "rear"]
            $0.interruptionReasonValue = .anotherApp
        }
        let result = await rig.pipeline.captureBoth(mode: .photo, illumination: .off)
        XCTAssertEqual(result.failure, .interruptedByAnotherApp)
        XCTAssertEqual(result.failuresByCamera,
                       ["front": .interruptedByAnotherApp, "rear": .interruptedByAnotherApp])
    }

    func testBothFallbackKeepsTheReasonRearCoverageWasUnavailable() async {
        let rig = makeRig { $0.multiCamWarmUpError = CameraController.CameraError.unavailable }
        let result = await rig.pipeline.captureBoth(mode: .photo, illumination: .off)
        XCTAssertNotNil(result.front)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.failuresByCamera, ["rear": .cameraUnavailable])
    }

    // MARK: - Item 108 (the 1.6 reviews): late evidence is uploaded; Both clips keep Sound listening

    /// CE-01: evidence stored after the capture deadline asks the host to upload it, since the
    /// response's own upload ran before it existed.
    func testLateEvidenceAsksTheHostToUploadIt() async throws {
        let gate = InvestigationCaptureGate()
        let camera = FakeCamera()
        camera.supportsMultiCam = true
        camera.heldBothPhotoLensForTesting = .rear
        camera.bothPhotoProbeForTesting = { await gate.wait() }
        var timing = Self.fastTiming
        timing.captureFinalizationDeadline = 0.03
        let host = FakeCaptureHost()
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: timing)
        pipeline.host = host
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
        store.add(event)
        let result = await pipeline.captureBoth(mode: .photo, illumination: .off,
                                                preservation: .init(event: event, store: store))
        XCTAssertEqual(result.failure, .captureTimedOut)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(store.events.first { $0.id == event.id }?.mediaFilename, "the finished lens was stored late")
        XCTAssertGreaterThan(host.lateEvidenceStored, 0, "and the host was asked to upload it")
        await gate.release()
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// F14: a Both-camera clip records no audio, so the Sound tripwire keeps listening through it.
    func testBothCameraClipsKeepTheSoundTripwireListening() async {
        let rig = makeRig { $0.omittedBothCameras = ["rear"] }
        rig.host.audioHandoffNeeded = true
        let result = await rig.pipeline.captureBoth(mode: .clip3, illumination: .off)
        defer { if case .clip(let url) = result.front?.source { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(rig.host.audioPauses, 0, "nothing to hand the microphone to")
        XCTAssertEqual(rig.host.audioResumes, 0)
    }

}

/// Test-only one-shot gate. Every caller installs a safety release and drains its capture.
private actor InvestigationCaptureGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
