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
@preconcurrency import AVFoundation

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
    /// An until-clear recording has run for `EngineTiming.untilClearWarningAfter`: the host may show the first warning
    /// now rather than when the clip ends (item 152's hardening (c)). Called once per clip.
    func untilClearClipReachedWarningTime()
    /// Pause Sound for a clip; true means its recorder yielded microphone ownership. Resume afterwards.
    @discardableResult func pauseAudioForCapture() -> Bool
    func resumeAudioAfterCapture()
    /// The vision tripwire must not judge the scene being recorded, the screen flash, or a
    /// camera reconfigure; it re-anchors when the window lapses.
    func suppressVision(for seconds: TimeInterval)
    func syncVisionTap()
    /// Surface — or clear — the owner-facing camera notice.
    func report(cameraNotice: String?)
    /// Clear only the notice owned by this capture; preserve unrelated camera warnings.
    func clearCaptureNotice(matching notice: String)
    /// The prior operation and its required shutdown have drained; deferred work may retry.
    func captureCameraBecameAvailable()
    /// Camera evidence finished after the capture deadline was stored on its event, and the
    /// event reopened for upload (item 108, CE-01): the response's own upload ran before the
    /// evidence existed, so the host starts another.
    func captureEvidenceStoredLate()
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
/// lives in Models/CaptureFailureReason.swift, with nothing but Foundation.
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
    /// Original evidence, its physical camera, measured movie duration (nil if unknown),
    /// and any saved-file issue. A still has duration zero; no duration is inferred from waits.
    struct Capture {
        let source: EventStore.MediaSource
        let ext: String
        let duration: Double?
        let camera: CameraChoice
        var issue: CaptureFailureReason?
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

    /// Destination captured before suspension: late evidence may only join this original event.
    struct Preservation {
        let event: Event
        let store: EventStore
    }

    @MainActor private final class Attempt {
        var stopped = false
        var sessionCancelled = false
        var microphoneYielded = false
        var notice: String?
        var expired = false
        var quarantined = false
        var warming = true
        var recordingInterrupted = false
        var audioBorrowed = false
        var flashed = false
        var cleaned = false
        var completed = false
        var preservation: Preservation?
        var both = false
        var finalized: [String: Capture] = [:]
        var inspections: [URL: Task<Capture, Never>] = [:]
        var lateHandled: Set<String> = []
    }
    private var attempt: Attempt?
    #if DEBUG
    var beforeAttemptWorkForTesting: (@MainActor () async -> Void)?
    #endif
    var isBusy: Bool { attempt != nil }

    /// A trip during an until-clear recording refreshes the activity clock.
    func noteActivity() { lastActivity = Date() }

    /// Invalidates this capture's session identity immediately, even if the host re-arms
    /// before a queued operation answers. The worker may finish existing media only.
    func cancelUntilClear() {
        isCapturingUntilClear = false
        if let attempt {
            attempt.stopped = true
            attempt.sessionCancelled = true
            attempt.quarantined = true
            camera.quarantineCapture()
            cleanUp(attempt)
        }
    }

    private var sessionIsOver: Bool { attempt?.stopped == true || host?.captureSessionIsOver != false }

    private func cleanUp(_ token: Attempt) {
        guard !token.cleaned else { return }
        token.cleaned = true
        isCapturingUntilClear = false
        if token.flashed { host?.setCaptureFlash(false) }
        if token.audioBorrowed && !token.quarantined { host?.resumeAudioAfterCapture() }
    }

    /// Races the entire attempt, including camera queries and finalization, against an
    /// independent clock. The lease remains held until the real worker drains; cancellation
    /// is never treated as proof that AVFoundation has stopped.
    private func run(mode: CaptureMode, preservation: Preservation?, both: Bool = false,
                     work: @escaping @MainActor () async -> BothOutcome) async -> BothOutcome {
        guard attempt == nil else { return BothOutcome(front: nil, rear: nil, failure: .cameraBusy) }
        let token = Attempt()
        token.preservation = preservation
        token.both = both
        attempt = token
        if mode.isClip {
            camera.setFinalizedClipHandler { [self] url, lens in
                Task { @MainActor in await receiveFinalized(url, lens: lens, mode: mode, token: token) }
            }
        }
        let budget = timing.warmUpDeadline + timing.reconfigureSettle + timing.autoExposureSettle
            + timing.flashSettle + (mode.fixedDuration ?? (mode.isClip ? timing.untilClearMax : 0))
            + timing.captureFinalizationDeadline
        return await withCheckedContinuation { continuation in
            @MainActor func finish(_ value: BothOutcome) {
                guard !token.completed else { return }
                token.completed = true
                continuation.resume(returning: value)
            }
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(budget)) } catch { return }
                guard !token.completed else { return }
                let reason: CaptureFailureReason = endedByDisarm ? .disarmed : .captureTimedOut
                expire(token)
                finish(BothOutcome(front: nil, rear: nil, failure: reason))
            }
            let warmDeadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(timing.warmUpDeadline)) } catch { return }
                guard !token.completed, token.warming else { return }
                let reason: CaptureFailureReason = endedByDisarm ? .disarmed : .warmUpTimedOut
                expire(token)
                finish(BothOutcome(front: nil, rear: nil, failure: reason))
            }
            Task { @MainActor in
                #if DEBUG
                await beforeAttemptWorkForTesting?()
                #endif
                let value: BothOutcome
                if token.stopped || attempt !== token || host?.captureSessionIsOver != false {
                    value = BothOutcome(front: nil, rear: nil, failure: .disarmed)
                } else {
                    value = await work()
                }
                // Cache completed stills as well as movies before waiting for shutdown.
                // The independent clock may expire during that await and must retain them.
                if let front = value.front { token.finalized[front.camera.rawValue] = front }
                if let rear = value.rear { token.finalized[rear.camera.rawValue] = rear }
                if token.expired {
                    // No UI/session side effects after expiry. Preserve only to the destination
                    // captured by this caller; never hand old footage to the next response.
                    await preserveLate(value, for: token)
                }
                if token.quarantined {
                    await camera.finishCaptureQuarantine()
                    if token.expired { await preserveLate(value, for: token) }
                    if !token.sessionCancelled, host?.captureSessionIsOver == false {
                        if token.audioBorrowed { host?.resumeAudioAfterCapture() }
                        if let notice = token.notice { host?.clearCaptureNotice(matching: notice) }
                    }
                }
                deadline.cancel()
                warmDeadline.cancel()
                cleanUp(token)
                camera.setFinalizedClipHandler(nil)
                if attempt === token {
                    attempt = nil
                    host?.captureCameraBecameAvailable()
                }
                finish(value)
            }
        }
    }

    private func expire(_ token: Attempt) {
        let wasDisarmed = token.stopped || host?.captureSessionIsOver == true
        token.expired = true
        token.quarantined = true
        token.stopped = true
        camera.quarantineCapture()
        cleanUp(token)
        Task { @MainActor in
            let front = token.both ? token.finalized["front"] : token.finalized.values.first
            await preserveLate(BothOutcome(front: front, rear: token.both ? token.finalized["rear"] : nil, failure: nil), for: token)
        }
        if !wasDisarmed {
            let sound = token.microphoneYielded ? " Sound detection stays paused until camera shutdown is confirmed." : ""
            let notice = "Camera unavailable - response timed out; recovery is pending. The event was logged." + sound
            token.notice = notice
            host?.report(cameraNotice: notice)
        }
    }

    private func preserveLate(_ value: BothOutcome, for token: Attempt) async {
        guard let destination = token.preservation else { return }
        var storedAny = false
        defer { if storedAny { host?.captureEvidenceStoredLate() } }   // item 108, CE-01
        for (capture, secondary) in [(value.front, false), (value.rear, true)] {
            guard let capture, token.lateHandled.insert(capture.camera.rawValue).inserted else { continue }
            guard let stored = await destination.store.store(capture.source, ext: capture.ext,
                    attachingTo: destination.event, secondary: secondary,
                    camera: capture.camera.rawValue, duration: capture.ext == "mov" ? capture.duration : nil,
                    captureIssue: (capture.issue ?? (token.sessionCancelled ? .disarmed : .captureTimedOut)).rawValue),
                  var current = destination.store.events.first(where: { $0.id == destination.event.id }) else { continue }
            if secondary {
                current.secondaryMediaFilename = stored.filename
                current.secondaryCamera = capture.camera.rawValue
                current.secondaryDuration = capture.ext == "mov" ? capture.duration : nil   // a still has none (item 152's lead 21)
            } else {
                current.mediaFilename = stored.filename
                current.primaryCamera = capture.camera.rawValue
                current.primaryDuration = capture.ext == "mov" ? capture.duration : nil
                current.thumbnailData = stored.thumbnail
            }
            var issues = current.captureFailuresByCamera ?? [:]
            issues[capture.camera.rawValue] = (capture.issue ?? (token.sessionCancelled ? .disarmed : .captureTimedOut)).rawValue
            current.captureFailuresByCamera = issues
            destination.store.updateAndReopenForReupload(current)   // one write (item 155's S1)
            storedAny = true
        }
    }

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
    private var endedByDisarm: Bool { sessionIsOver }
    private var mayAffectSession: Bool { attempt?.cleaned != true }

    /// Home's notice while the store that holds clips until the log takes them is full (item 112).
    static let clipStorageFullNotice = "Clip storage is full - new clips can't be recorded. See the event for details."

    func capture(from position: CameraChoice, mode: CaptureMode,
                 illumination: IlluminationMode, preservation: Preservation? = nil) async -> Outcome {
        let value = await run(mode: mode, preservation: preservation) {
            let single = await self.captureSingle(from: position, mode: mode, illumination: illumination)
            return BothOutcome(front: single.capture, rear: nil, failure: single.failure)
        }
        return value.front.map(Outcome.captured) ?? .failed(value.failure ?? .captureFailed)
    }

    private func captureSingle(from position: CameraChoice, mode: CaptureMode,
                               illumination: IlluminationMode) async -> Outcome {
        host?.syncVisionTap()
        host?.suppressVision(for: 4)
        camera.beginCaptureAttempt()   // this attempt's failure is classified by THIS attempt (item 65, finding 5)
        // Review 3, R3.1: a disarm that lands anywhere in this attempt leaves the camera to the
        // pipeline. Every stand-down in the engine needs an armed state or a cold policy, so a
        // session the warm-up below restarted would otherwise stay up on a disarmed phone —
        // green dot on, no badge on Home — until the next arm.
        defer { if endedByDisarm && mayAffectSession { camera.shutDown() } }

        // A clip needs room in the store that holds clips until the log takes them (item 112).
        // Asked before the camera starts: refused later, the clip lit the screen flash, took the
        // microphone from Sound and waited out its whole length recording nothing.
        if mode.isClip {
            guard camera.hasRoomForClips(outputs: 1) else {
                host?.report(cameraNotice: Self.clipStorageFullNotice)
                return .failed(.storageFull)
            }
            host?.clearCaptureNotice(matching: Self.clipStorageFullNotice)
        }

        // Sound must yield before a microphone-bearing session starts. A camera that was
        // kept warm alongside its recorder must restart to reacquire audio cleanly.
        let audioHandoff = mode.isClip && (host?.pauseAudioForCapture() ?? false)
        attempt?.microphoneYielded = audioHandoff
        if mode.isClip { attempt?.audioBorrowed = true }
        let warmDeadline = Date().addingTimeInterval(timing.warmUpDeadline)

        // Point the session at the requested camera. If that fails, return nil — never
        // silently capture from whatever camera happened to be configured (that produced
        // duplicate/wrong-camera "old" captures).
        let reconfigured: Bool
        do {
            // The outer attempt owns the warm-up clock and retains its lease until this
            // real operation drains. Do not nest a race here that loses the worker lifetime.
            if audioHandoff {
                reconfigured = try await camera.warmUpForAudioHandoff(camera: position, deadline: warmDeadline)
            } else {
                reconfigured = try await camera.warmUp(forClips: mode.isClip, camera: position)
            }
            attempt?.warming = false
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

        if endedByDisarm { return .failed(.disarmed) }
        let illuminate = await shouldIlluminate(illumination)   // read AFTER settle, BEFORE flashing
        let useScreenFlash = illuminate && position == .front
        let useHardwareLight = illuminate && position == .rear
        if useScreenFlash { await illuminateForCapture() }
        defer { if useScreenFlash { endIllumination() } }
        if endedByDisarm { return .failed(.disarmed) }   // the settle and the light check took time: ask once more before the lens

        if mode.isClip {
            camera.beginClip(torch: useHardwareLight)
            await recordClipDuration(mode)
            do {
                let url = try await camera.endClip()
                guard let token = attempt else { return .failed(.captureFailed) }
                await receiveFinalized(url, lens: position, mode: mode, token: token)
                return token.finalized[position.rawValue].map(Outcome.captured) ?? .failed(.captureFailed)
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
            // The whole-attempt clock bounds this await independently of the camera queue.
            // A late delegate retains its original destination while the camera is quarantined.
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
    func captureBoth(mode: CaptureMode, illumination: IlluminationMode,
                     preservation: Preservation? = nil) async -> BothOutcome {
        await run(mode: mode, preservation: preservation, both: true) {
            await self.captureBothOwned(mode: mode, illumination: illumination)
        }
    }

    private func captureBothOwned(mode: CaptureMode, illumination: IlluminationMode) async -> BothOutcome {
        host?.suppressVision(for: 4)
        camera.beginCaptureAttempt()   // item 65, finding 5
        defer { if endedByDisarm && mayAffectSession { camera.shutDown() } }   // review 3, R3.1 — see capture(from:)
        if mode.isClip {   // two clips' room, before the multi-cam session starts (item 112)
            guard camera.hasRoomForClips(outputs: 2) else {
                host?.report(cameraNotice: Self.clipStorageFullNotice)
                return BothOutcome(front: nil, rear: nil, failure: .storageFull)
            }
            host?.clearCaptureNotice(matching: Self.clipStorageFullNotice)
        }
        do {
            let coldStarted = try await camera.warmUpMultiCam(forClips: mode.isClip)
            attempt?.warming = false
            if endedByDisarm { return BothOutcome(front: nil, rear: nil, failure: .disarmed) }
            host?.report(cameraNotice: nil)   // multi-cam is working
            // Cold start (battery saver / Auto on battery): let exposure ramp before capture.
            if coldStarted { try? await Task.sleep(nanoseconds: UInt64(timing.reconfigureSettle * 1_000_000_000)) }
        } catch {
            if endedByDisarm { return BothOutcome(front: nil, rear: nil, failure: .disarmed) }
            host?.report(cameraNotice: "Multi-cam capture unavailable - recorded the front camera only. (\((error as NSError).localizedDescription))")
            Log.engine.error("Multi-cam warm-up failed, falling back to front only: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            let rearFailure = CaptureFailureReason.forWarmUpFailure(error)
            let fallback = await captureSingle(from: .front, mode: mode, illumination: illumination)
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
            if endedByDisarm { return BothOutcome(front: nil, rear: nil, failure: .disarmed) }
            rearLight = await camera.isLowLightRear()
        }

        if screenFlash { await illuminateForCapture() }
        defer { if screenFlash { endIllumination() } }
        if endedByDisarm { return BothOutcome(front: nil, rear: nil, failure: .disarmed) }

        if mode.isClip {
            // The multi-cam session has no microphone input: a Both clip records no audio, so the
            // Sound tripwire keeps listening through it (item 108, F14). It used to be paused
            // for nothing, deaf for the length of every Both clip.
            camera.beginBothClips(rearTorch: rearLight)
            await recordClipDuration(mode)
            guard let token = attempt else { return BothOutcome(front: nil, rear: nil, failure: .captureFailed) }
            _ = await camera.endBothClips { [self] url, lens in
                await receiveFinalized(url, lens: lens, mode: mode, token: token)
            }
            return await bothOutcome(token.finalized["front"], token.finalized["rear"])
        } else {
            guard let token = attempt else { return BothOutcome(front: nil, rear: nil, failure: .captureFailed) }
            _ = await camera.captureBothStills(rearHardwareFlash: rearLight) { [self] data, lens in
                let capture = Capture(source: .still(data), ext: "jpg", duration: 0, camera: lens)
                await receivePhoto(capture, token: token)
            }
            return await bothOutcome(token.finalized["front"], token.finalized["rear"])
        }
    }

    private func receivePhoto(_ capture: Capture, token: Attempt) async {
        token.finalized[capture.camera.rawValue] = capture
        if token.expired {
            await preserveLate(BothOutcome(front: capture.camera == .front ? capture : nil,
                                           rear: capture.camera == .rear ? capture : nil, failure: nil), for: token)
        }
    }

    private func receiveFinalized(_ url: URL, lens: CameraChoice, mode: CaptureMode, token: Attempt) async {
        let inspection: Task<Capture, Never>
        if let running = token.inspections[url] { inspection = running }
        else {
            inspection = Task { @MainActor in await measuredClip(url, camera: lens, mode: mode) }
            token.inspections[url] = inspection
        }
        let capture = await inspection.value
        token.finalized[lens.rawValue] = capture
        if token.expired {
            await preserveLate(BothOutcome(front: !token.both || lens == .front ? capture : nil,
                rear: token.both && lens == .rear ? capture : nil, failure: nil), for: token)
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
            let end = ContinuousClock.now.advanced(by: .seconds(fixed))
            while !sessionIsOver, ContinuousClock.now < end {
                try? await Task.sleep(for: .seconds(min(timing.untilClearPoll, 0.1)))
            }
            return
        }
        // Until-clear: sensor trips during recording refresh the activity clock.
        isCapturingUntilClear = true
        lastActivity = Date()
        let start = Date()
        let idleThreshold = timing.untilClearIdle
        let maxDuration = timing.untilClearMax
        var warningDue = true   // the host hears once per clip (item 152's hardening (c))
        while !sessionIsOver {
            try? await Task.sleep(nanoseconds: UInt64(timing.untilClearPoll * 1_000_000_000))
            // If the app was backgrounded, the capture session is interrupted and the
            // recording already stopped — finalize now (keeping the partial) instead of
            // waiting up to the ceiling on a dead session.
            if await camera.clipWasInterrupted() {
                attempt?.recordingInterrupted = true
                break
            }
            if sessionIsOver { break }
            // Re-arm the tripwires so continued tampering keeps registering.
            host?.rearmTripwiresDuringCapture()
            // Alert mode's first warning need not wait for the clip to end (item 152's hardening (c)).
            if warningDue, Date().timeIntervalSince(start) >= timing.untilClearWarningAfter {
                warningDue = false
                host?.untilClearClipReachedWarningTime()
            }
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
        guard !sessionIsOver, host?.mayFlashScreen == true else { return }
        attempt?.flashed = true
        host?.setCaptureFlash(true)
        try? await Task.sleep(nanoseconds: UInt64(timing.flashSettle * 1_000_000_000))   // ~0.35 s to light + settle
    }

    private func endIllumination() {
        guard mayAffectSession else { return }
        attempt?.flashed = false
        host?.setCaptureFlash(false)
    }

    /// Inspects each finalized movie independently. Waiting time is never a footage length.
    /// Unknown/unreadable media remains preserved, but is explicitly unverified and has no
    /// invented duration. A thumbnail is neither required nor used as a validity test.
    private func measuredClip(_ url: URL, camera position: CameraChoice, mode: CaptureMode) async -> Capture {
        let measured = try? await Self.withDeadline(2) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let playable = try await asset.load(.isPlayable)
            guard duration.isFinite, duration > 0, !tracks.isEmpty, playable else { throw CameraController.CameraError.captureFailed }
            return duration
        }
        let finished = camera.recordingFinishedSuccessfully(at: url)
        let issue: CaptureFailureReason?
        if measured == nil { issue = .clipUnverified }
        else if attempt?.expired == true { issue = .captureTimedOut }
        else if endedByDisarm { issue = .disarmed }
        else if finished == false || attempt?.recordingInterrupted == true
                    || mode.fixedDuration.map({ (measured ?? 0) + 0.25 < $0 }) == true {
            issue = .clipPartial
        } else if finished == nil { issue = .clipUnverified }
        else { issue = nil }
        return Capture(source: .clip(url), ext: "mov", duration: measured, camera: position, issue: issue)
    }
}
