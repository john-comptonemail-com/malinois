//
//  EvidenceCapturePipelineTests.swift
//  MalinoisTests
//
//  The capture mechanism on its own (1.3 step 5): a fake camera answers the lens, a fake
//  host answers the session. No engine in the loop — the engine's side is pinned by the
//  characterization tests, which drive the real engine through this same pipeline.
//

import XCTest
@testable import Malinois

/// Records what a capture asked of the session, and answers with knobs.
@MainActor
final class FakeCaptureHost: CapturePipelineHost {
    var captureSessionIsOver = false
    var mayFlashScreen = true
    private(set) var flashStates: [Bool] = []
    private(set) var rearms = 0
    private(set) var audioPauses = 0
    private(set) var audioResumes = 0
    private(set) var visionSuppressions: [TimeInterval] = []
    private(set) var visionSyncs = 0
    private(set) var notices: [String?] = []
    func setCaptureFlash(_ on: Bool) { flashStates.append(on) }
    func rearmTripwiresDuringCapture() { rearms += 1 }
    func pauseAudioForCapture() { audioPauses += 1 }
    func resumeAudioAfterCapture() { audioResumes += 1 }
    func suppressVision(for seconds: TimeInterval) { visionSuppressions.append(seconds) }
    func syncVisionTap() { visionSyncs += 1 }
    func report(cameraNotice: String?) { notices.append(cameraNotice) }
}

@MainActor
final class EvidenceCapturePipelineTests: XCTestCase {

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

    // MARK: - Until clear

    /// A quiet scene ends the clip after the idle window: audio was freed for the clip and
    /// handed back, the tripwires were re-armed while it rolled, and the flag cleared.
    func testUntilClearEndsWhenTheSceneGoesQuiet() async throws {
        let rig = makeRig()
        let captured = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        let capture = try XCTUnwrap(captured.capture)
        XCTAssertEqual(capture.ext, "mov")
        XCTAssertGreaterThanOrEqual(capture.duration, 0.15, "held at least the idle window")
        XCTAssertLessThan(capture.duration, 0.6, "and not much longer — the scene was quiet")
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
        let captured = await rig.pipeline.capture(from: .rear, mode: .untilClear, illumination: .off)
        let capture = try XCTUnwrap(captured.capture)
        feeder.cancel()
        XCTAssertGreaterThanOrEqual(capture.duration, 0.9, "held to the ceiling")
        XCTAssertLessThan(capture.duration, 1.6)
    }

    /// An interrupted camera session (the app backgrounded) finalizes the clip at once,
    /// keeping the partial, instead of waiting out the ceiling.
    func testUntilClearFinalizesWhenTheCameraSessionIsInterrupted() async throws {
        let rig = makeRig { $0.clipInterrupted = true }
        let captured = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        let capture = try XCTUnwrap(captured.capture)
        XCTAssertLessThan(capture.duration, 0.15, "finalized at the first poll")
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
        let captured = await rig.pipeline.capture(from: .front, mode: .untilClear, illumination: .off)
        let capture = try XCTUnwrap(captured.capture)
        ender.cancel(); feeder.cancel()
        XCTAssertLessThan(capture.duration, 0.5, "stopped when the session ended, well before the ceiling")
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
}
