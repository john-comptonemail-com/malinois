//
//  EvidenceCapturePipeline.swift
//  Malinois
//
//  The capture mechanism, extracted from MonitoringEngine (1.3 consolidation, step 5):
//  warm the requested camera under a deadline, settle, decide illumination, shoot a still
//  or hold a clip — for a fixed length or until the scene goes quiet — for one camera or
//  both. Policy stays in the engine: WHAT to record, WHEN to shoot, and what to do with
//  the result. The engine is also this pipeline's host, answering the few questions the
//  mechanism has to ask mid-capture and doing the few things it has to do to the session
//  (flash the screen, free the microphone, re-arm the other tripwires).
//

import Foundation

/// What a capture needs from the session it runs inside (1.3 step 5). Kept small on
/// purpose: everything else travels in as a parameter of the capture call.
@MainActor
protocol CapturePipelineHost: AnyObject {
    /// True once the session has ended — an until-clear clip stops being held open.
    var captureSessionIsOver: Bool { get }
    /// Whether the screen may be flashed for a front capture: not during PIN entry, and not
    /// while the tamper alert is already on screen — the first (pre-alert) capture got the
    /// lit shot, and a re-flash would tell the thief a photo is being taken right now.
    var mayFlashScreen: Bool { get }
    /// Raise or drop the screen flash (the host folds it into its brightness priority).
    func setCaptureFlash(_ on: Bool)
    /// Re-arm the enabled tripwires so continued tampering keeps registering during an
    /// until-clear recording.
    func rearmTripwiresDuringCapture()
    /// Pause Sound for a clip; true means its recorder yielded microphone ownership. Resume afterwards.
    @discardableResult func pauseAudioForCapture() -> Bool
    func resumeAudioAfterCapture()
    /// The vision tripwire must not judge the scene being recorded, the screen flash, or a
    /// camera reconfigure; it re-anchors when the window lapses.
    func suppressVision(for seconds: TimeInterval)
    func syncVisionTap()
    /// Surface — or clear — the owner-facing camera notice.
    func report(cameraNotice: String?)
}

/// Why the system interrupted a capture session — `AVCaptureSession.InterruptionReason` as
/// this app names it (item 54). Folded into `CaptureFailureReason` when a capture fails.
enum CaptureInterruptionReason: String, Sendable, CaseIterable {
    /// The app left the foreground: a lock, the power slider, a swipe home.
    case background
    /// Another app holds the camera, or two apps share the screen.
    case anotherApp
    /// Another app holds the audio device — the microphone a clip needs.
    case audioClient
    /// iOS shed the camera under thermal or system pressure.
    case systemPressure
    /// A reason this build does not know.
    case unknown
}

/// What the capture session told the engine while it lived (item 54): an interruption with
/// the system's reason, its end, and a runtime error.
enum CameraSessionEvent: Sendable {
    case interrupted(CaptureInterruptionReason)
    case interruptionEnded
    case runtimeError(String)
}

/// The two mappings that know the camera's own types stay beside the pipeline; the enum itself
/// lives in Models/CaptureFailureReason.swift, where the alert extension can compile it (item 76).
extension CaptureFailureReason {
    /// Pure (unit-tested). The reason a failed warm-up maps to.
    static func forWarmUpFailure(_ error: Error) -> CaptureFailureReason {
        switch error as? CameraController.CameraError {
        case .unauthorized: return .unauthorized
        case .timedOut:     return .warmUpTimedOut
        default:            return .cameraUnavailable
        }
    }

    /// Pure (unit-tested). The reason a failed shot or clip maps to, given whether the
    /// session was interrupted meanwhile — and why.
    static func forCaptureFailure(interruption: CaptureInterruptionReason?) -> CaptureFailureReason {
        switch interruption {
        case nil:             return .captureFailed
        case .background:     return .interruptedInBackground
        case .anotherApp:     return .interruptedByAnotherApp
        case .audioClient:    return .interruptedByAudioClient
        case .systemPressure: return .interruptedBySystemPressure
        case .unknown:        return .interrupted
        }
    }
}

@MainActor
final class EvidenceCapturePipeline {
    /// A captured piece of evidence tagged with its camera and recorded length.
    struct Capture {
        let source: EventStore.MediaSource
        let ext: String
        let duration: Double
        let camera: CameraChoice
    }

    /// What one capture produced — the evidence, or the reason there is none (item 54).
    enum Outcome {
        case captured(Capture)
        case failed(CaptureFailureReason)
        var capture: Capture? { if case .captured(let c) = self { return c } else { return nil } }
        var failure: CaptureFailureReason? { if case .failed(let r) = self { return r } else { return nil } }
    }

    /// Preserves every successful capture. Global failure is only for a total failure;
    /// per-camera reasons also describe partial capture and front-only fallback coverage.
    struct BothOutcome {
        let front: Capture?
        let rear: Capture?
        let failure: CaptureFailureReason?
        var failuresByCamera: [String: CaptureFailureReason] = [:]
    }

    private let camera: any EvidenceCamera
    private let timing: EngineTiming
    /// The session this pipeline captures for. Weak: the engine owns the pipeline. With no
    /// host the mechanism behaves as if the session were over and nothing may be flashed.
    weak var host: (any CapturePipelineHost)?

    /// True while an until-clear clip is being held open. The engine's trip handler routes
    /// trips into `noteActivity()` instead of firing a new trigger while this is set, and
    /// its standby and cadence-capture gates read it.
    private(set) var isCapturingUntilClear = false
    /// The last trip seen during an until-clear recording — decides when the clip ends.
    private var lastActivity: Date?

    init(camera: any EvidenceCamera, timing: EngineTiming) {
        self.camera = camera
        self.timing = timing
    }

    /// A trip during an until-clear recording refreshes the activity clock.
    func noteActivity() { lastActivity = Date() }

    /// The session ended mid-recording: drop the flag now, so nothing reads a stale "still
    /// recording" before the loop notices at its next poll.
    func cancelUntilClear() { isCapturingUntilClear = false }

    private var sessionIsOver: Bool { host?.captureSessionIsOver ?? true }

    // MARK: - Bounded camera warm-up (34's warmUp hardening)

    /// First-resume-wins latch for racing an un-cancellable operation against its deadline
    /// (the `PerRecordResults` pattern: a class because two unstructured tasks share it).
    private final class DeadlineLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Races an un-cancellable operation against a wall-clock deadline. Deliberately NOT a
    /// task group: a group awaits every child before returning, and session-queue work
    /// ignores cancellation — so a group-shaped timeout would still hang exactly as long as
    /// the thing it exists to cut short. The loser is abandoned instead: on timeout the
    /// operation keeps running unstructured, which is why the engine guards late
    /// side-effects with `cameraWarmGeneration` — a stale completion must not join a newer
    /// warm intent. The deadline itself is `EngineTiming.warmUpDeadline`.
    nonisolated static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let latch = DeadlineLatch()
            Task {
                do { let value = try await operation(); if latch.claim() { cont.resume(returning: value) } }
                catch { if latch.claim() { cont.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if latch.claim() { cont.resume(throwing: CameraController.CameraError.timedOut) }
            }
        }
    }

    // MARK: - Single camera

    /// Captures one still or clip from a concrete camera (`.front` or `.rear`), handling
    /// illumination — screen flash for front, LED flash/torch for rear. `mode` is the mode
    /// for THIS capture: the engine collapses clips to stills under a siren, and cadence
    /// captures are stills by construction (ADR 0003). A failure carries its reason (item
    /// 54) — the notice goes to the host, and the event stands with its metadata, traces,
    /// fact push, and now the reason, like any capture failure.
    /// A capture that fails after the owner has disarmed is not a fault: the disarm stopped
    /// the camera (item 63 leg 6). The record says so and Home gets no notice.
    private var endedByDisarm: Bool { host?.captureSessionIsOver == true }

    func capture(from position: CameraChoice, mode: CaptureMode,
                 illumination: IlluminationMode) async -> Outcome {
        host?.syncVisionTap()
        host?.suppressVision(for: 4)
        camera.beginCaptureAttempt()   // this attempt's failure is classified by THIS attempt (item 65, finding 5)
        // Review 3, R3.1: a disarm that lands anywhere in this attempt leaves the camera to the
        // pipeline. Every stand-down in the engine needs an armed state or a cold policy, so a
        // session the warm-up below restarted would otherwise stay up on a disarmed phone —
        // green dot on, no badge on Home — until the next arm.
        defer { if endedByDisarm { camera.shutDown() } }

        // Sound must yield before a microphone-bearing session starts. A camera that was
        // kept warm alongside its recorder must restart to reacquire audio cleanly.
        let audioHandoff = mode.isClip && (host?.pauseAudioForCapture() ?? false)
        defer { if mode.isClip { host?.resumeAudioAfterCapture() } }
        let warmDeadline = Date().addingTimeInterval(timing.warmUpDeadline)

        // Point the session at the requested camera. If that fails, return nil — never
        // silently capture from whatever camera happened to be configured (that produced
        // duplicate/wrong-camera "old" captures).
        let reconfigured: Bool
        do {
            // Bounded (34's warmUp hardening): this await sits on the trigger path, where a
            // blocked `startRunning()` used to wedge the engine's response with its
            // trigger-handling flag stuck — detection dead until disarm. On timeout the
            // capture fails cleanly; the stale warm-up finishing later is harmless here (the
            // response is over) and the engine's stand-down still runs after it.
            reconfigured = try await Self.withDeadline(timing.warmUpDeadline) { [camera] in
                if audioHandoff {
                    return try await camera.warmUpForAudioHandoff(camera: position, deadline: warmDeadline)
                }
                return try await camera.warmUp(forClips: mode.isClip, camera: position)
            }
        } catch {
            if endedByDisarm {
                Log.engine.info("Warm-up ended by the disarm")
                return .failed(.disarmed)
            }
            Log.engine.error("Camera warm-up failed (\(position.rawValue, privacy: .public)): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            // F7: the cold-start path (Auto-on-battery / Battery saver) was the one place a
            // dead camera stayed invisible — surfaced only in the log, never to the owner.
            host?.report(cameraNotice: "Camera unavailable - an evidence capture failed. Check camera permission in iOS Settings.")
            return .failed(CaptureFailureReason.forWarmUpFailure(error))
        }
        // The warm-up answered — but did the watch end meanwhile? Its success path never
        // asked, so a disarm whose shutdown queued BEFORE the warm-up's start had the session
        // restarted under it and a capture taken on a disarmed engine (review 3, R3.1).
        if endedByDisarm {
            Log.engine.info("Warm-up outlived the disarm — not capturing")
            return .failed(.disarmed)
        }
        // After switching cameras, wait for the new sensor to deliver a fresh, exposed
        // frame — otherwise the first capture can be stale or black. A reconfigure already
        // gives auto-exposure time to settle; a warm camera gets a shorter settle so the
        // Auto light check reflects the current scene (the device may have been resting
        // face-down to a dark surface) rather than the stale resting reading.
        if reconfigured {
            try? await Task.sleep(nanoseconds: UInt64(timing.reconfigureSettle * 1_000_000_000))
        } else if illumination == .auto {
            try? await Task.sleep(nanoseconds: UInt64(timing.autoExposureSettle * 1_000_000_000))
        }

        let illuminate = await shouldIlluminate(illumination)   // read AFTER settle, BEFORE flashing
        let useScreenFlash = illuminate && position == .front
        let useHardwareLight = illuminate && position == .rear
        if useScreenFlash { await illuminateForCapture() }
        defer { if useScreenFlash { endIllumination() } }
        if endedByDisarm { return .failed(.disarmed) }   // the settle and the light check took time: ask once more before the lens

        if mode.isClip {
            let recordStart = Date()
            camera.beginClip(torch: useHardwareLight)
            await recordClipDuration(mode)
            do {
                let url = try await camera.endClip()
                let elapsed = Date().timeIntervalSince(recordStart)
                // Hand the clip file on by URL — no in-memory read here.
                return .captured(Capture(source: .clip(url), ext: "mov", duration: elapsed, camera: position))
            } catch {
                if endedByDisarm {
                    Log.engine.info("Clip ended by the disarm")
                    return .failed(.disarmed)
                }
                Log.engine.error("Clip capture failed (\(position.rawValue, privacy: .public)): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                // A capture that fails on a session that warmed up fine used to be console-only
                // (42.H1) — the owner learned about missing evidence from the event row, if ever.
                host?.report(cameraNotice: "A camera capture failed - an event may be missing its photo or clip.")
                return .failed(CaptureFailureReason.forCaptureFailure(interruption: await camera.interruptionReason()))
            }
        } else {
            // captureStill is internally bounded (see CameraController) so a stalled photo
            // delegate can never hang the pipeline or leak.
            do {
                let data = try await camera.captureStill(hardwareFlash: useHardwareLight)
                return .captured(Capture(source: .still(data), ext: "jpg", duration: 0, camera: position))   // stills have no clip length
            } catch {
                if endedByDisarm {
                    Log.engine.info("Still ended by the disarm")
                    return .failed(.disarmed)
                }
                Log.engine.error("Still capture failed or timed out (\(position.rawValue, privacy: .public)): \(Log.ref(error), privacy: .public)")
                host?.report(cameraNotice: "A camera capture failed - an event may be missing its photo or clip.")
                return .failed(CaptureFailureReason.forCaptureFailure(interruption: await camera.interruptionReason()))
            }
        }
    }

    // MARK: - Both cameras

    /// Captures front AND rear simultaneously via the multi-cam session. Front is lit by
    /// the screen flash, rear by its LED / torch. Falls back to a front-only single capture
    /// if the multi-cam session can't be brought up.
    func captureBoth(mode: CaptureMode, illumination: IlluminationMode) async -> BothOutcome {
        host?.suppressVision(for: 4)
        camera.beginCaptureAttempt()   // item 65, finding 5
        defer { if endedByDisarm { camera.shutDown() } }   // review 3, R3.1 — see capture(from:)
        do {
            let coldStarted = try await Self.withDeadline(timing.warmUpDeadline) { [camera] in
                try await camera.warmUpMultiCam(forClips: mode.isClip)
            }
            host?.report(cameraNotice: nil)   // multi-cam is working
            // Cold start (battery saver / Auto on battery): let exposure ramp before capture.
            if coldStarted { try? await Task.sleep(nanoseconds: UInt64(timing.reconfigureSettle * 1_000_000_000)) }
        } catch {
            host?.report(cameraNotice: "Multi-cam capture unavailable - recorded the front camera only. (\((error as NSError).localizedDescription))")
            Log.engine.error("Multi-cam warm-up failed, falling back to front only: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            let rearFailure = CaptureFailureReason.forWarmUpFailure(error)
            let fallback = await capture(from: .front, mode: mode, illumination: illumination)
            var failures = ["rear": rearFailure]
            if let reason = fallback.failure { failures["front"] = reason }
            if !endedByDisarm { host?.report(cameraNotice: "Rear camera unavailable - see the event for capture details.") }
            return BothOutcome(front: fallback.capture, rear: nil, failure: fallback.failure,
                               failuresByCamera: failures)
        }
        if endedByDisarm { return BothOutcome(front: nil, rear: nil, failure: .disarmed) }   // R3.1, as in capture(from:)

        // Decide illumination per camera (Auto reads each lens' light level).
        let screenFlash: Bool
        let rearLight: Bool
        switch illumination {
        case .off:  screenFlash = false;                     rearLight = false
        case .on:   screenFlash = true;                      rearLight = true
        case .auto:
            // Let auto-exposure re-meter the current scene before the light check.
            try? await Task.sleep(nanoseconds: UInt64(timing.autoExposureSettle * 1_000_000_000))
            screenFlash = await camera.isLowLightFront()
            rearLight = await camera.isLowLightRear()
        }

        if screenFlash { await illuminateForCapture() }
        defer { if screenFlash { endIllumination() } }
        if endedByDisarm { return BothOutcome(front: nil, rear: nil, failure: .disarmed) }

        if mode.isClip {
            let start = Date()
            host?.pauseAudioForCapture()                 // free the mic for the clip (F-14)
            defer { host?.resumeAudioAfterCapture() }
            camera.beginBothClips(rearTorch: rearLight)
            await recordClipDuration(mode)
            let urls = try? await camera.endBothClips()
            let elapsed = Date().timeIntervalSince(start)
            // Carry the clip files by URL — the store MOVES them off-main; we never read a
            // (potentially huge) clip into memory here.
            let front = urls?.front.map { Capture(source: .clip($0), ext: "mov", duration: elapsed, camera: .front) }
            let rear = urls?.rear.map { Capture(source: .clip($0), ext: "mov", duration: elapsed, camera: .rear) }
            return await bothOutcome(front, rear)
        } else {
            let both = try? await camera.captureBothStills(rearHardwareFlash: rearLight)
            let front = both?.front.map { Capture(source: .still($0), ext: "jpg", duration: 0, camera: .front) }
            let rear = both?.rear.map { Capture(source: .still($0), ext: "jpg", duration: 0, camera: .rear) }
            return await bothOutcome(front, rear)
        }
    }

    /// Records missing coverage without discarding a surviving capture or classifying it as a retry.
    private func bothOutcome(_ front: Capture?, _ rear: Capture?) async -> BothOutcome {
        guard front == nil || rear == nil else { return BothOutcome(front: front, rear: rear, failure: nil) }
        let reason: CaptureFailureReason = endedByDisarm ? .disarmed
            : CaptureFailureReason.forCaptureFailure(interruption: await camera.interruptionReason())
        var failures: [String: CaptureFailureReason] = [:]
        if front == nil { failures["front"] = reason }
        if rear == nil { failures["rear"] = reason }
        if !endedByDisarm {
            host?.report(cameraNotice: "A camera capture failed - see the event for missing camera coverage.")
        }
        return BothOutcome(front: front, rear: rear, failure: front == nil && rear == nil ? reason : nil,
                           failuresByCamera: failures)
    }

    // MARK: - Clip length and illumination

    /// Holds the clip open for the configured length: a fixed number of seconds, or — for
    /// "until clear" — until no tamper activity for `untilClearIdle` (capped at
    /// `untilClearMax`).
    private func recordClipDuration(_ mode: CaptureMode) async {
        if let fixed = mode.fixedDuration {
            try? await Task.sleep(nanoseconds: UInt64(fixed * 1_000_000_000))
            return
        }
        // Until-clear: sensor trips during recording refresh the activity clock.
        isCapturingUntilClear = true
        lastActivity = Date()
        let start = Date()
        let idleThreshold = timing.untilClearIdle
        let maxDuration = timing.untilClearMax
        while !sessionIsOver {
            try? await Task.sleep(nanoseconds: UInt64(timing.untilClearPoll * 1_000_000_000))
            // If the app was backgrounded, the capture session is interrupted and the
            // recording already stopped — finalize now (keeping the partial) instead of
            // waiting up to the ceiling on a dead session.
            if await camera.clipWasInterrupted() { break }
            // Re-arm the tripwires so continued tampering keeps registering.
            host?.rearmTripwiresDuringCapture()
            let idle = Date().timeIntervalSince(lastActivity ?? start)
            if idle >= idleThreshold || Date().timeIntervalSince(start) >= maxDuration { break }
        }
        isCapturingUntilClear = false
    }

    /// Whether to light the current capture, honouring the illumination mode (Auto only
    /// fires when the active camera reports a dim scene).
    private func shouldIlluminate(_ illumination: IlluminationMode) async -> Bool {
        switch illumination {
        case .off:  return false
        case .on:   return true
        case .auto: return await camera.isLowLight()
        }
    }

    /// Light the scene for a front-camera capture by flashing the screen white — when the
    /// host allows it (see `CapturePipelineHost.mayFlashScreen`).
    private func illuminateForCapture() async {
        guard host?.mayFlashScreen == true else { return }
        host?.setCaptureFlash(true)
        try? await Task.sleep(nanoseconds: UInt64(timing.flashSettle * 1_000_000_000))   // ~0.35 s to light + settle
    }

    private func endIllumination() {
        host?.setCaptureFlash(false)
    }
}
