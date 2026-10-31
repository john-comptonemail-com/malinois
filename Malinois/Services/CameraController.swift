//
//  CameraController.swift
//  Malinois
//
//  Owns the capture pipeline. Two session types share the physical cameras (only
//  one runs at a time):
//    • `session`   – a normal AVCaptureSession for a single camera (front / rear
//                    / auto).
//    • `mcSession` – an AVCaptureMultiCamSession for the "Both" option, capturing
//                    front AND rear simultaneously on supported devices. When the
//                    device doesn't support multi-cam, the engine falls back to
//                    the front camera only.
//
//  iOS constraint: capture can't run in the true background. Malinois stays
//  foregrounded with a forced-black screen (see ArmedView / MonitoringEngine).
//
//  Threading: all pipeline work is confined to `sessionQueue`; the pipeline
//  objects are `nonisolated(unsafe)` and the methods are `nonisolated`.
//

import Foundation
import Combine
@preconcurrency import AVFoundation
import UIKit

/// The engine's view of the camera — everything `MonitoringEngine` asks of the capture
/// pipeline, and nothing else (1.3 consolidation, step 3: the first seam). `CameraController`
/// is the only production conformer; tests stand in a fake so the trigger response, the
/// until-clear loop, and the both-camera path can be driven on a simulator that has no
/// camera at all. Behavior-neutral by construction: the engine calls the same methods with
/// the same signatures, through a protocol instead of the concrete class.
///
/// `Sendable` because the engine hands the camera to unstructured tasks racing a deadline
/// (`withDeadline`); the controller is `@unchecked Sendable` (session-queue confinement), and
/// a fake must promise the same.
protocol EvidenceCamera: AnyObject, Sendable {
    /// Whether this device can capture both cameras at once.
    var supportsMultiCam: Bool { get }
    /// The camera permission as iOS reports it. The engine reads it here rather than from
    /// AVFoundation, so a test's fake camera answers for itself whatever the simulator has been
    /// granted (item 129, T1: on a fresh simulator, never asked, the engine skipped the warm-up
    /// and seven tests failed).
    var videoPermission: AVAuthorizationStatus { get }
    /// The camera question of the first ARM tap (item 69, ADR 0011): asks iOS when it has never been asked, and answers
    /// whether the camera is granted afterwards. Here for the same reason as `videoPermission`: a test's fake answers
    /// for itself, and no real alert stops a test (item 162's G1).
    func requestVideoAccess() async -> Bool
    /// Whether a clip session attaches the microphone. The engine sets it at arm from the
    /// owner's "Record audio in clips" setting AND the microphone permission; the controller
    /// never attaches an unauthorized mic, so iOS never raises the permission prompt on its own.
    var clipAudio: Bool { get set }
    /// True while any capture session is live — the REC badge's source of truth.
    var isRecordingActive: Bool { get }
    /// `isRecordingActive` as a stream, so the engine can lift the covert screen on change.
    var isRecordingActivePublisher: AnyPublisher<Bool, Never> { get }
    /// Whether the vision tap is delivering after a warm-up: nil = cold, false = asked for
    /// and not up, true = live.
    var visionTapActive: Bool? { get }
    /// A clip session asked for the microphone and could not attach it (item 73, review 1 R7):
    /// clips will be silent although the owner asked for sound. False whenever no mic was asked for.
    var micUnavailableForClips: Bool { get }
    /// Frames from the vision tap, delivered on the main actor.
    var onVisionFrame: (@MainActor (VisionFrame) -> Void)? { get set }
    func setVisionTapEnabled(_ enabled: Bool)
    func warmUp(forClips: Bool, camera: CameraChoice) async throws -> Bool
    func warmUpMultiCam(forClips: Bool) async throws -> Bool
    /// Whether the store that holds clips until the log takes them has room for `outputs` new
    /// clips (item 112): the same budget a clip reserves from when it starts.
    func hasRoomForClips(outputs: Int) -> Bool
    func shutDown()
    /// Restart and warm on the camera queue after Sound yields its microphone. The deadline
    /// prevents delayed queued work from starting a capture after the caller has given up.
    func warmUpForAudioHandoff(camera: CameraChoice, deadline: Date) async throws -> Bool
    func dropMicAndWait() async
    func isLowLight() async -> Bool
    func isLowLightFront() async -> Bool
    func isLowLightRear() async -> Bool
    func captureStill(hardwareFlash: Bool) async throws -> Data
    func beginClip(torch: Bool)
    func endClip() async throws -> URL
    func captureBothStills(rearHardwareFlash: Bool) async throws -> (front: Data?, rear: Data?)
    /// Deliver each photo independently while the other camera may still be waiting.
    func captureBothStills(rearHardwareFlash: Bool,
                           onFinalized: @escaping @Sendable (Data, CameraChoice) async -> Void) async -> (front: Data?, rear: Data?)
    func beginBothClips(rearTorch: Bool)
    func endBothClips() async throws -> (front: URL?, rear: URL?)
    /// Deliver each lens independently so one stalled delegate cannot hide the other movie.
    func endBothClips(onFinalized: @escaping @Sendable (URL, CameraChoice) async -> Void) async -> (front: URL?, rear: URL?)
    func clipWasInterrupted() async -> Bool
    /// Whether a recording of the current clip has finished on its own since the clip began: iOS ended it at the clip's
    /// size limit, on a full disk or on a session error, before the clip was ended (BACKLOG 180's A1).
    func clipRecordingEndedOnItsOwn() async -> Bool
    /// The session's life as the engine sees it — interruptions with the system's reason,
    /// their end, and runtime errors (item 54). Delivered on the main actor.
    var onSessionEvent: (@MainActor (CameraSessionEvent) -> Void)? { get set }
    /// Why the session is interrupted right now — or, while a clip is in progress, why it
    /// was interrupted since it began; nil when neither.
    func interruptionReason() async -> CaptureInterruptionReason?
    /// A new capture attempt begins (item 65, finding 5): clear the interruption latch a
    /// previous clip left behind, so this attempt's failure is classified by what happens to
    /// IT — never by an interruption from an earlier capture.
    func beginCaptureAttempt()
    /// Immediately prevents queued/new starts after expiry; does not claim hardware stopped.
    func quarantineCapture()
    /// Clears quarantine only after the worker drained and a queued shutdown actually ran.
    func finishCaptureQuarantine() async
    /// Delegate completion evidence for one exact file; nil means not established.
    func recordingFinishedSuccessfully(at url: URL) -> Bool?
    /// Receives completed bytes independently of the session queue, bound to the handler
    /// captured when that exact movie began. Clearing does not change an existing file owner.
    func setFinalizedClipHandler(_ handler: (@Sendable (URL, CameraChoice) -> Void)?)
}

extension EvidenceCamera {
    func setFinalizedClipHandler(_ handler: (@Sendable (URL, CameraChoice) -> Void)?) {}
    func endBothClips(onFinalized: @escaping @Sendable (URL, CameraChoice) async -> Void) async -> (front: URL?, rear: URL?) {
        guard let urls = try? await endBothClips() else { return (nil, nil) }
        if let front = urls.front { await onFinalized(front, .front) }
        if let rear = urls.rear { await onFinalized(rear, .rear) }
        return urls
    }
}

extension CameraController: EvidenceCamera {
    var supportsMultiCam: Bool { Self.supportsMultiCam }
    var videoPermission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    func requestVideoAccess() async -> Bool { await Self.requestCameraAccessIfUndetermined() }
    /// The mic is attached only when the owner asked for clip audio AND iOS has granted it.
    private var wantsMic: Bool { clipAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var isRecordingActivePublisher: AnyPublisher<Bool, Never> { $isRecordingActive.eraseToAnyPublisher() }
}

// @unchecked Sendable: session state is confined to `sessionQueue`; clipAudio uses its own lock.
// Published state and callbacks retain their documented delivery rules.
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {

    enum CameraError: Error { case unauthorized, unavailable, captureFailed, timedOut, sessionNotRunning }
    private enum Lens { case front, rear }

    /// Whether this device can capture both cameras at once.
    static var supportsMultiCam: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    private let sessionQueue = DispatchQueue(label: "com.malinois.camera.session")
    private let ownershipLock = NSLock()
    // These fields are protected by ownershipLock, not the potentially blocked session queue.
    nonisolated(unsafe) private var quarantined = false
    nonisolated(unsafe) private var ownershipEpoch = 0
    nonisolated(unsafe) private var recordingCompletions: [URL: Bool] = [:]
    nonisolated(unsafe) private var finalizedClipHandler: (@Sendable (URL, CameraChoice) -> Void)?
    nonisolated(unsafe) private var fileHandlers: [URL: (@Sendable (URL, CameraChoice) -> Void)] = [:]
    nonisolated(unsafe) private var fileCameras: [URL: CameraChoice] = [:]

    nonisolated func setFinalizedClipHandler(_ handler: (@Sendable (URL, CameraChoice) -> Void)?) {
        ownershipLock.withLock {
            finalizedClipHandler = handler
            if handler != nil { recordingCompletions.removeAll() }
        }
    }

    private func registerFile(_ url: URL, camera: CameraChoice) {
        ownershipLock.withLock {
            fileHandlers[url] = finalizedClipHandler
            fileCameras[url] = camera
        }
    }

    nonisolated func recordingFinishedSuccessfully(at url: URL) -> Bool? {
        ownershipLock.withLock { recordingCompletions[url] }
    }

    /// Apple's delegate can report an error for a recording which nevertheless finished.
    nonisolated static func recordingSucceeded(error: Error?) -> Bool {
        guard let error else { return true }
        return (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
    }

    nonisolated func quarantineCapture() {
        ownershipLock.withLock { quarantined = true; ownershipEpoch &+= 1 }
        shutDown()
    }

    nonisolated func finishCaptureQuarantine() async {
        await shutDownAndWait()
        ownershipLock.withLock { quarantined = false }
    }

    nonisolated private func admittedEpoch() -> Int? {
        ownershipLock.withLock { quarantined ? nil : ownershipEpoch }
    }

    nonisolated private func owns(_ epoch: Int) -> Bool {
        ownershipLock.withLock { !quarantined && ownershipEpoch == epoch }
    }

    // MARK: Single-camera session
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var isConfigured = false
    nonisolated(unsafe) private var videoDevice: AVCaptureDevice?
    nonisolated(unsafe) private var configuredPosition: AVCaptureDevice.Position = .front
    nonisolated(unsafe) private var configuredForClips = false
    /// Whether the configured session carries the mic input (a clip session may not, item 69).
    nonisolated(unsafe) private var configuredWithMic = false
    /// See `EvidenceCamera.micUnavailableForClips`.
    nonisolated(unsafe) private(set) var micUnavailableForClips = false
    /// Shared by the engine and the session queue. Lock both reads and writes so an arm or
    /// readiness change cannot race camera configuration; the engine also reads it to pause audio.
    private let clipAudioLock = NSLock()
    nonisolated(unsafe) private var clipAudioValue = false   // protected by clipAudioLock
    var clipAudio: Bool {
        get { clipAudioLock.withLock { clipAudioValue } }
        set { clipAudioLock.withLock { clipAudioValue = newValue } }
    }
    nonisolated(unsafe) private var configuredVision = false

    // MARK: Vision tripwire tap (BACKLOG 16)
    /// Attached to the single-camera session only when the engine asks for it. Delivers
    /// ~2 fps of 32×24 luminance to `onVisionFrame`; nothing is written anywhere.
    nonisolated(unsafe) private let visionOutput = AVCaptureVideoDataOutput()
    private let visionQueue = DispatchQueue(label: "com.malinois.camera.vision", qos: .utility)
    nonisolated(unsafe) private var visionFrameCounter = 0
    /// Whether the vision tap's connection actually came up on the last configuration.
    /// `nil` = no tap was requested (or the camera is cold).
    ///
    /// Checked because the documented failure mode of running an `AVCaptureVideoDataOutput`
    /// alongside the movie file output is **not** a refused `addOutput` — it is an output that
    /// attaches and then delivers nothing, because the movie output won the connection. That
    /// looks identical from the app's side to "the camera is cold", which is the wrong thing
    /// to tell the owner about a tripwire they enabled.
    nonisolated(unsafe) private(set) var visionTapActive: Bool?
    /// True once the microphone input has been surgically removed for a sounding siren
    /// (BACKLOG 17). The next clip configuration must rebuild rather than conclude the
    /// session is already correct — otherwise every clip for the rest of the session records
    /// silently, and nothing anywhere would report it.
    nonisolated(unsafe) private(set) var micDropped = false
    /// First-frame timestamp and processed-frame count, for the rate line in the log. The
    /// verification question for this feature is literally "do frames arrive, and how fast",
    /// and nothing in the UI can answer it.
    nonisolated(unsafe) private var visionFirstFrameAt: Date?
    nonisolated(unsafe) private var visionWindowStart: Date?
    nonisolated(unsafe) private var visionProcessed = 0
    /// There is no per-output frame-rate throttle on iOS (the device setting would slow
    /// clip recording too), so decimate in the delegate: every Nth frame of a 30 fps stream.
    nonisolated static let visionDecimation = 15
    /// ⚠️ **Do not ask this output for a scaled buffer size.** Tried and reverted on device
    /// (2026-08-26). Setting `kCVPixelBufferWidthKey`/`HeightKey` to 320×180 delivered exactly
    /// the frames requested — and then still capture started failing: `Still capture failed or
    /// timed out (front)` on both builds that carried it (8 and 9), on a path that had captured
    /// cleanly on build 7 without the keys.
    ///
    /// The trade isn't close. The saving was speculative — full-size frames cost ~2 MP of reads
    /// per processed frame at 2 fps, which was never a measured problem — and the cost is a
    /// tamper capture that doesn't happen. Evidence beats CPU. The session delivers 1920×1080
    /// and `VisionDetector.downsample` reduces it, which is what shipped and what works.
    /// Set by the engine BEFORE a warm-up. A change reconfigures the session.
    /// Confined to `sessionQueue` for real as of seventh-review #4: it was written on the
    /// main actor (`syncVisionTap`) and read here during configure — an actual data race
    /// under this class's "confined to sessionQueue" promise. External writers go through
    /// `setVisionTapEnabled`, which hands the value across on the serial queue, ordering it
    /// before any warm-up dispatched after it.
    nonisolated(unsafe) private var visionTapEnabled = false

    /// The one sanctioned external write (seventh review, #4).
    func setVisionTapEnabled(_ enabled: Bool) {
        sessionQueue.async { self.visionTapEnabled = enabled }
    }
    /// Receives downsampled frames on the main actor.
    nonisolated(unsafe) var onVisionFrame: (@MainActor (VisionFrame) -> Void)?
    /// Item 54: the session's interruptions, their end, and runtime errors, for the engine.
    nonisolated(unsafe) var onSessionEvent: (@MainActor (CameraSessionEvent) -> Void)?
    /// Photo continuations keyed by the capture's settings uniqueID, so a delegate
    /// callback always resumes exactly its own capture — even if an earlier still
    /// timed out and a new one started (no cross-wiring, no leaked continuation).
    nonisolated(unsafe) private var photoConts: [Int64: CheckedContinuation<Data, Error>] = [:]
    /// Movie waiters keep their exact file association through deadline expiry.
    /// Quarantine prevents slot reuse until the prior waiter and shutdown drain.
    nonisolated(unsafe) private var movieConts: [Slot: CheckedContinuation<URL, Error>] = [:]
    /// The file each slot is currently recording to.
    ///
    /// The delegate callback is keyed only by slot, and a slot is reused by the next recording.
    /// So a callback arriving late — after its own recording timed out and a new one started —
    /// would resume the **new** recording's continuation with the **old** clip's URL, attaching
    /// one event's footage to a different event. In an evidence app that is worse than losing
    /// the clip. Matching on the URL is what makes a callback provably its own.
    nonisolated(unsafe) private var movieExpectedURLs: [Slot: URL] = [:]
    /// Partial clips finalized by an interruption (e.g. the app was backgrounded)
    /// before `endRecording` was called — stashed so the pending stop can still
    /// return the salvaged file instead of failing.
    nonisolated(unsafe) private var movieFinalizedURLs: [Slot: URL] = [:]
    /// Set when the active clip's session is interrupted, so the until-clear loop
    /// stops waiting on a dead session and finalizes the partial now.
    nonisolated(unsafe) private var clipInterrupted = false
    /// Set when a recording of the active clip finished before the clip was ended (iOS ended it at its size limit, on a
    /// full disk or a session error), so the until-clear loop stops waiting on a recording that has stopped (BACKLOG
    /// 180's A1). Read and written only on `sessionQueue`, as `clipInterrupted`.
    nonisolated(unsafe) private var clipRecordingEnded = false
    /// Why the clip in progress was interrupted (item 54); reset with `clipInterrupted`.
    nonisolated(unsafe) private var clipInterruptionReasonValue: CaptureInterruptionReason?
    /// Why the session is interrupted right now — set on the interruption, cleared when it ends.
    nonisolated(unsafe) private var currentInterruption: CaptureInterruptionReason?

    // MARK: Multi-cam session
    nonisolated(unsafe) private let mcSession = AVCaptureMultiCamSession()
    nonisolated(unsafe) private let frontPhotoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let rearPhotoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let frontMovieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private let rearMovieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var mcConfigured = false
    nonisolated(unsafe) private var mcForClips = false
    /// Whether the live multi-cam configuration includes the vision tap. Part of the reuse
    /// decision for the same reason `configuredVision` is on the single-camera side: without
    /// it, turning the tripwire on without also changing capture mode reuses a session that
    /// has no tap, and the tripwire is silently dead.
    nonisolated(unsafe) private var mcConfiguredVision = false
    nonisolated(unsafe) private var frontDevice: AVCaptureDevice?
    nonisolated(unsafe) private var rearDevice: AVCaptureDevice?

    // MARK: - Recording indicator state

    /// True while ANY capture session is live. Drives the on-screen recording indicator
    /// (App Review Guideline 2.5.14: a clear, non-disableable visual indication whenever the
    /// app is recording — the armed screen must not be blank while the camera is running).
    ///
    /// Derived from the sessions' own lifecycle notifications, NOT from warm-up/shut-down
    /// call sites — so no future code path can start the camera without lighting the
    /// indicator. There is deliberately no setting that gates it.
    @Published private(set) var isRecordingActive = false

    /// Recompute from the sessions' actual state (on the session queue, where it's owned)
    /// and publish on the main actor for SwiftUI.
    private func refreshRecordingActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let running = self.session.isRunning || self.mcSession.isRunning
            Task { @MainActor in
                if self.isRecordingActive != running { self.isRecordingActive = running }
            }
        }
    }

    // MARK: - Init / interruption observation

    override init() {
        super.init()
        // A capture session is interrupted when the app is backgrounded, a call
        // arrives, or another app takes the camera. Note it (per session) so an
        // in-progress clip stops waiting and keeps whatever it recorded.
        let nc = NotificationCenter.default
        for s in [session, mcSession] as [AVCaptureSession] {
            nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                           object: s, queue: nil) { [weak self] note in
                // Read the reason here, on the notification's thread — `Notification` does
                // not cross into the session queue or the main actor.
                let reason = Self.interruptionReason(fromUserInfo: note.userInfo)
                self?.sessionQueue.async { [weak self] in
                    self?.clipInterrupted = true
                    self?.clipInterruptionReasonValue = reason
                    self?.currentInterruption = reason
                }
                self?.deliverSessionEvent(.interrupted(reason))
            }
            // Item 54: the end of an interruption is the engine's cue to re-warm and to take
            // its one bounded retry; a runtime error (32.R9) is its cue to say so and re-warm.
            nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                           object: s, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in self?.currentInterruption = nil }
                self?.deliverSessionEvent(.interruptionEnded)
            }
            nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                           object: s, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.deliverSessionEvent(.runtimeError(error?.localizedDescription ?? "unknown error"))
            }
        }
        // Track live-ness for the recording indicator through every lifecycle edge the
        // session can take — including interruptions, which stop capture without a
        // stopRunning() call from us.
        for name in [AVCaptureSession.didStartRunningNotification,
                     AVCaptureSession.didStopRunningNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            for s in [session, mcSession] as [AVCaptureSession] {
                nc.addObserver(forName: name, object: s, queue: nil) { [weak self] _ in
                    self?.refreshRecordingActive()
                }
            }
        }
    }

    /// Whether the current clip's session has been interrupted since it began.
    nonisolated func clipWasInterrupted() async -> Bool {
        await withCheckedContinuation { cont in
            sessionQueue.async { cont.resume(returning: self.clipInterrupted) }
        }
    }

    /// Whether a recording of the current clip finished on its own since the clip began (BACKLOG 180's A1).
    nonisolated func clipRecordingEndedOnItsOwn() async -> Bool {
        await withCheckedContinuation { cont in
            sessionQueue.async { cont.resume(returning: self.clipRecordingEnded) }
        }
    }

    /// Item 54: the current interruption's reason, else the reason that hit the clip in
    /// progress, else nil.
    nonisolated func interruptionReason() async -> CaptureInterruptionReason? {
        await withCheckedContinuation { cont in
            sessionQueue.async {
                cont.resume(returning: self.currentInterruption
                            ?? (self.clipInterrupted ? self.clipInterruptionReasonValue : nil))
            }
        }
    }

    /// Item 65, finding 5: the clip latch belongs to the clip that set it. A still attempted
    /// later in a session that once saw an interruption used to inherit that reason — and park
    /// a retry — for a failure that had nothing to do with it.
    nonisolated func beginCaptureAttempt() {
        sessionQueue.async {
            self.clipInterrupted = false
            self.clipRecordingEnded = false
            self.clipInterruptionReasonValue = nil
        }
    }

    #if DEBUG
    /// Test-only: plant the latch a clip interruption leaves, so `beginCaptureAttempt` can be
    /// shown to clear it. Debug-only, like the other seams.
    nonisolated func latchClipInterruptionForTesting(_ reason: CaptureInterruptionReason) {
        sessionQueue.sync {
            self.clipInterrupted = true
            self.clipInterruptionReasonValue = reason
        }
    }
    #endif

    /// Hands a session event to the engine on the main actor.
    nonisolated private func deliverSessionEvent(_ event: CameraSessionEvent) {
        guard let handler = onSessionEvent else { return }
        Task { @MainActor in handler(event) }
    }

    /// Pure (unit-tested). The system's interruption reason, as this app names it. Two
    /// system reasons — another client holds the video device, or several foreground apps
    /// share the screen — read the same to the owner: another app has the camera.
    nonisolated static func interruptionReason(fromUserInfo userInfo: [AnyHashable: Any]?) -> CaptureInterruptionReason {
        guard let raw = userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else { return .unknown }
        switch reason {
        case .videoDeviceNotAvailableInBackground:               return .background
        case .audioDeviceInUseByAnotherClient:                   return .audioClient
        case .videoDeviceInUseByAnotherClient,
             .videoDeviceNotAvailableWithMultipleForegroundApps: return .anotherApp
        case .videoDeviceNotAvailableDueToSystemPressure:        return .systemPressure
        // iOS 26: raised only by Apple's sensitive-content analyzer, which the app never uses
        // (the 1.4 audit); named so the switch is complete, read as `.unknown` as before.
        case .sensitiveContentMitigationActivated:               return .unknown
        @unknown default:                                        return .unknown
        }
    }

    // MARK: - Permissions

    /// The camera prompt, asked on the first ARM tap (item 69) rather than at launch — before
    /// the arming screen, so it never has to appear under Guided Access. Returns whether the
    /// camera is granted afterwards.
    static func requestCameraAccessIfUndetermined() async -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Pure (unit-tested): the ARM tap asks for the camera only when something needs it, iOS
    /// has never been asked, and Guided Access is OFF. Under Guided Access iOS cannot show the
    /// alert and records the blocked request as a refusal (1.3 (42), item 69 leg 7: Home read
    /// "Camera access is denied" afterwards) — so the ask is skipped and the arming screen says
    /// how to get it instead.
    static func cameraPromptIsDue(cameraNeeded: Bool, undetermined: Bool, guidedAccessOn: Bool) -> Bool {
        cameraNeeded && undetermined && !guidedAccessOn
    }

    enum MicrophonePermission { case undetermined, granted, denied }

    /// The microphone permission as the Settings captions read it.
    static var microphonePermission: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied:  return .denied
        default:       return .undetermined
        }
    }

    /// The microphone prompt, asked when the Sound tripwire or clip audio is switched on
    /// (item 69), never at launch. Returns whether the mic is granted afterwards.
    static func requestMicrophoneAccessIfUndetermined() async -> Bool {
        guard AVAudioApplication.shared.recordPermission == .undetermined else {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Single-camera warm-up

    /// Configures and starts the single-camera session. Returns true if the caller
    /// should let exposure settle — either it reconfigured, or it started a *cold*
    /// session (battery-saver / Auto-on-battery), whose first frames are still
    /// ramping. Switching cameras is a clean stop → reconfigure → start, which
    /// avoids blank/stale frames that come from mutating a live session.
    @discardableResult
    nonisolated func warmUp(forClips: Bool, camera: CameraChoice) async throws -> Bool {
        try await warmUp(forClips: forClips, camera: camera, audioHandoffDeadline: nil)
    }

    /// Stop/configure/start is one queue operation, so disarm's shutdown cannot run between
    /// the stop and restart. Recheck the deadline after blocking stop/configuration work.
    nonisolated func warmUpForAudioHandoff(camera: CameraChoice, deadline: Date) async throws -> Bool {
        try await warmUp(forClips: true, camera: camera, audioHandoffDeadline: deadline)
    }

    nonisolated private func warmUp(forClips: Bool, camera: CameraChoice,
                                    audioHandoffDeadline: Date?) async throws -> Bool {
        guard let epoch = admittedEpoch() else { throw CameraError.timedOut }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.unauthorized
        }
        let position: AVCaptureDevice.Position = camera == .rear ? .back : .front
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            sessionQueue.async {
                do {
                    guard self.owns(epoch) else { throw CameraError.timedOut }
                    if let deadline = audioHandoffDeadline, Date() >= deadline { throw CameraError.timedOut }
                    if self.mcSession.isRunning { self.mcSession.stopRunning() }
                    if audioHandoffDeadline != nil, self.session.isRunning { self.session.stopRunning() }
                    guard self.owns(epoch) else { throw CameraError.timedOut }
                    if let deadline = audioHandoffDeadline, Date() >= deadline { throw CameraError.timedOut }
                    let wasRunning = self.session.isRunning
                    // The SAME rule `configure` applies — deliberately not a second copy of
                    // it. This was an inline duplicate, and when `micDropped` was added to the
                    // rule only one copy learned about it, so a session that had lost its mic
                    // would be rebuilt without being stopped first.
                    let needsReconfig = Self.needsReconfiguration(
                        isConfigured: self.isConfigured,
                        configuredPosition: self.configuredPosition, wantPosition: position,
                        configuredForClips: self.configuredForClips, wantClips: forClips,
                        configuredVision: self.configuredVision, wantVision: self.visionTapEnabled,
                        micDropped: self.micDropped,
                        configuredWithMic: self.configuredWithMic, wantMic: forClips && self.wantsMic)
                    if needsReconfig && wasRunning { self.session.stopRunning() }
                    let didReconfigure = try self.configure(forClips: forClips, position: position)
                    guard self.owns(epoch) else { throw CameraError.timedOut }
                    if let deadline = audioHandoffDeadline, Date() >= deadline { throw CameraError.timedOut }
                    if !self.session.isRunning { self.session.startRunning() }
                    // Settle on a reconfigure OR a cold start — a session that wasn't
                    // running needs the same exposure ramp as a freshly-configured one.
                    cont.resume(returning: didReconfigure || !wasRunning)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Multi-cam warm-up

    /// Configures and starts the multi-cam session (front + rear). Returns true if it
    /// started a cold session (so the caller can let exposure settle). Throws if the
    /// device can't support the requested multi-cam configuration.
    @discardableResult
    nonisolated func warmUpMultiCam(forClips: Bool) async throws -> Bool {
        guard let epoch = admittedEpoch() else { throw CameraError.timedOut }
        guard Self.supportsMultiCam else { throw CameraError.unavailable }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.unauthorized
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            sessionQueue.async {
                do {
                    guard self.owns(epoch) else { throw CameraError.timedOut }
                    if self.session.isRunning { self.session.stopRunning() }
                    let wasRunning = self.mcSession.isRunning
                    try self.configureMultiCam(forClips: forClips)
                    guard self.owns(epoch) else { throw CameraError.timedOut }
                    if !self.mcSession.isRunning { self.mcSession.startRunning() }
                    cont.resume(returning: !wasRunning)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    nonisolated func shutDown() {
        sessionQueue.async {
            self.setTorch(false, device: self.videoDevice)
            self.setTorch(false, device: self.rearDevice)
            if self.session.isRunning { self.session.stopRunning() }
            if self.mcSession.isRunning { self.mcSession.stopRunning() }
        }
    }

    /// `shutDown`, but waits until the sessions have actually stopped.
    ///
    /// Needed before sounding the siren. A clip-configured session holds the microphone and
    /// *manages the app's audio session*, so it deactivates that session when it stops —
    /// which silences an alarm already playing. `stopRunning` on a warm session can take a
    /// second or two, so fire-and-forget shutdown races the siren and the alarm dies shortly
    /// after starting. Await this, then start the siren.
    /// Releases the microphone — and only the microphone — from the running session, then
    /// waits (BACKLOG 17).
    ///
    /// The siren's conflict was never with the camera; it is with the **mic**. A
    /// clip-configured session holds a mic input and with it the app's audio session, so the
    /// siren's `.playback` activation fails with `insufficientPriority` (`'!pri'`). Shutting
    /// the whole camera down fixes that and costs more than the conflict requires: the vision
    /// tripwire goes blind for the entire alarm — exactly when someone is most likely to be
    /// moving in front of the lens — and the next trigger cold-starts the camera.
    ///
    /// Dropping just the audio input leaves the video pipeline running, so the tripwire keeps
    /// watching through the alarm. Nothing is lost on the capture side: `captureModeForNow`
    /// already collapses clips to stills whenever an alarm is sounding or about to (F4), so
    /// the movie output is idle during an alarm regardless.
    ///
    /// Awaited for the same reason `shutDownAndWait` is — the audio session has to be released
    /// before the siren tries to take it, or the alarm starts and dies moments later.
    nonisolated func dropMicAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                let mics = self.session.inputs
                    .compactMap { $0 as? AVCaptureDeviceInput }
                    .filter { $0.device.hasMediaType(.audio) }
                guard !mics.isEmpty else { cont.resume(); return }
                self.session.beginConfiguration()
                mics.forEach { self.session.removeInput($0) }
                self.session.commitConfiguration()
                self.micDropped = true
                Log.camera.info("Mic released for the siren; video session still running")
                cont.resume()
            }
        }
    }

    nonisolated func shutDownAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.setTorch(false, device: self.videoDevice)
                self.setTorch(false, device: self.rearDevice)
                if self.session.isRunning { self.session.stopRunning() }
                if self.mcSession.isRunning { self.mcSession.stopRunning() }
                cont.resume()
            }
        }
    }

    // MARK: - Low-light checks (for illumination "Auto")

    nonisolated func isLowLight() async -> Bool { await lowLight(.active) }
    nonisolated func isLowLightFront() async -> Bool { await lowLight(.front) }
    nonisolated func isLowLightRear() async -> Bool { await lowLight(.rear) }

    private enum LightMeter { case active, front, rear }

    /// Reads the device's exposure on the sessionQueue — which owns the device
    /// references and reconfigures them — so neither the reference nor its ISO can
    /// race a concurrent reconfiguration.
    private func lowLight(_ which: LightMeter) async -> Bool {
        await withCheckedContinuation { cont in
            sessionQueue.async {
                let device: AVCaptureDevice?
                switch which {
                case .active: device = self.videoDevice
                case .front:  device = self.frontDevice
                case .rear:   device = self.rearDevice
                }
                guard let device else { cont.resume(returning: false); return }
                let maxISO = device.activeFormat.maxISO
                cont.resume(returning: maxISO > 0 && device.iso / maxISO > 0.5)
            }
        }
    }

    // MARK: - Single-camera configuration

    /// Whether the single-camera session has to be rebuilt to satisfy the requested shape.
    ///
    /// Pure and `static` so the one condition that silently degrades evidence can be tested:
    /// **a session whose mic was dropped for a siren looks identical to a correct
    /// clip-configured session** on every other field. Miss `micDropped` here and every clip
    /// after the first alarm records silently for the rest of the armed session, with nothing
    /// in the UI or the log to say so.
    nonisolated static func needsReconfiguration(isConfigured: Bool,
                                                 configuredPosition: AVCaptureDevice.Position,
                                                 wantPosition: AVCaptureDevice.Position,
                                                 configuredForClips: Bool, wantClips: Bool,
                                                 configuredVision: Bool, wantVision: Bool,
                                                 micDropped: Bool,
                                                 configuredWithMic: Bool? = nil, wantMic: Bool? = nil) -> Bool {
        // Before item 69 a clip session always carried the mic, so the mic dimension defaults
        // to the clip dimension; now the two can differ (clip audio off, or the mic not granted).
        let configuredWithMic = configuredWithMic ?? configuredForClips
        let wantMic = wantMic ?? wantClips
        guard isConfigured else { return true }
        if configuredPosition != wantPosition { return true }
        if configuredForClips != wantClips { return true }
        if configuredWithMic != wantMic { return true }
        if configuredVision != wantVision { return true }
        // Only a session that wants the mic needs it back; a stills session never had one.
        if micDropped && wantMic { return true }
        return false
    }

    /// Returns true if it actually (re)configured the session. Assumes the caller
    /// stopped the session first when switching.
    /// What a capture session is built from. Pure (unit-tested) because 1.3 (41) crashed on
    /// exactly this: a restructuring left the movie output inside the "clip without a mic"
    /// branch, so a clip session WITH the mic had no capture output at all and the first
    /// `startRecording` threw. A clip session always carries the movie output; the mic is an
    /// addition to it, never a substitute; a stills session carries the photo output only.
    struct SessionShape: Equatable {
        let movieOutput: Bool
        let micInput: Bool
        let photoOutput: Bool
    }

    nonisolated static func sessionShape(forClips: Bool, wantsMic: Bool) -> SessionShape {
        SessionShape(movieOutput: forClips, micInput: forClips && wantsMic, photoOutput: !forClips)
    }

    @discardableResult
    private func configure(forClips: Bool, position: AVCaptureDevice.Position) throws -> Bool {
        let shape = Self.sessionShape(forClips: forClips, wantsMic: wantsMic)
        let attachMic = shape.micInput
        guard Self.needsReconfiguration(isConfigured: isConfigured,
                                        configuredPosition: configuredPosition, wantPosition: position,
                                        configuredForClips: configuredForClips, wantClips: forClips,
                                        configuredVision: configuredVision, wantVision: visionTapEnabled,
                                        micDropped: micDropped,
                                        configuredWithMic: configuredWithMic, wantMic: attachMic) else { return false }

        // Take the tap back from the multi-cam session before trying to add it here.
        if visionTapEnabled { releaseVisionOutput(from: mcSession) }

        session.beginConfiguration()
        // The session is stripped bare below, so from here "configured" is only true again
        // once a rebuild COMPLETES. Left standing across a throw, these flags described the
        // previous working setup — and the next warm-up that happened to match them reused a
        // gutted session, timing out every capture for the rest of the armed session (42.H1).
        isConfigured = false
        visionTapActive = nil
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            throw CameraError.unavailable
        }
        session.addInput(input)
        videoDevice = device

        if shape.movieOutput {
            if shape.micInput {
                if let mic = AVCaptureDevice.default(for: .audio),
                   let micInput = try? AVCaptureDeviceInput(device: mic),
                   session.canAddInput(micInput) {
                    session.addInput(micInput)
                    micUnavailableForClips = false
                    // Logged because the failure it guards is otherwise invisible: after a siren
                    // drops the mic, a clip session that is never rebuilt records silently, and
                    // nothing surfaces it until someone plays the evidence back (BACKLOG 17).
                    Log.camera.info("Mic attached for clip capture")
                } else {
                    // The request stands (`configuredWithMic` records what was asked, so the next
                    // warm-up does not rebuild the session over it); the OUTCOME is what the owner
                    // needs to hear, at arm, not on playback (item 73, review 1 R7).
                    micUnavailableForClips = true
                    Log.camera.error("Clip session configured WITHOUT a mic — clips will be silent")
                }
            } else {
                micUnavailableForClips = false
                // By choice, not by accident: clip audio is off, or the mic was never granted —
                // an unauthorized mic is never attached, so iOS never prompts from here (item 69).
                Log.camera.info("Clip session built without a mic (clip audio off or not allowed)")
            }
            // A refused PRIMARY output must fail the configuration, not be shrugged off
            // (34.H12): accepting it marked the session configured while every capture on it
            // was doomed to time out — "configured" must mean "can capture". The movie output
            // is added for EVERY clip session, mic or not (the 41 crash, item 69).
            guard session.canAddOutput(movieOutput) else {
                session.commitConfiguration()
                Log.camera.error("Movie output refused — clip capture cannot run on this session")
                throw CameraError.unavailable
            }
            session.addOutput(movieOutput)
        } else {
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                Log.camera.error("Photo output refused — still capture cannot run on this session")
                throw CameraError.unavailable
            }
            session.addOutput(photoOutput)
        }
        // Vision tap: allowed alongside the movie output for apps linked on iOS 16+ (we're
        // 17+); native biplanar format so the Y plane is read directly, no conversion.
        var visionAttached = false
        if visionTapEnabled {
            if session.canAddOutput(visionOutput) {
                visionOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
                visionOutput.alwaysDiscardsLateVideoFrames = true
                visionOutput.setSampleBufferDelegate(self, queue: visionQueue)
                session.addOutput(visionOutput)
                visionAttached = true
            } else {
                // A refusal here is not an error anywhere in AVFoundation — it is a `false`
                // that reads exactly like "nothing to do". Say it out loud instead.
                Log.camera.error("Vision tap: the session REFUSED the output — the tripwire will not run")
            }
        }

        session.commitConfiguration()
        // The connection only exists after the configuration is committed, and an INACTIVE one
        // is the whole risk of sharing a session with the movie output — so check it here and
        // record it, rather than letting the tripwire go quiet with no explanation.
        //
        // Gated on `visionAttached` because `visionOutput.connection(with:)` answers for
        // whatever session currently owns the output. Asking it after a refused add reported
        // the *other* session's connection as active — which is how a tap that never attached
        // came out as "No frames" (attached, none arriving) instead of "Not running", and sent
        // an evening's debugging at the rear camera.
        if visionTapEnabled {
            let active = visionAttached && (visionOutput.connection(with: .video)?.isActive ?? false)
            visionTapActive = active
            if active {
                Log.camera.info("Vision tap active (decimation 1/\(Self.visionDecimation, privacy: .public))")
            } else if visionAttached {
                Log.camera.error("Vision tap attached but its connection is INACTIVE — no frames will arrive")
            }
        } else {
            visionTapActive = nil
        }
        resetVisionCounters()
        micDropped = false
        isConfigured = true
        configuredPosition = position
        configuredForClips = forClips
        configuredWithMic = attachMic
        configuredVision = visionTapEnabled
        return true
    }

    // MARK: - Multi-cam configuration

    private func configureMultiCam(forClips: Bool) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { throw CameraError.unavailable }
        guard Self.multiCamNeedsReconfiguration(isConfigured: mcConfigured,
                                                configuredForClips: mcForClips, wantClips: forClips,
                                                configuredVision: mcConfiguredVision,
                                                wantVision: visionTapEnabled) else { return }

        // …and the same in the other direction, or the multi-cam attach is refused instead.
        if visionTapEnabled { releaseVisionOutput(from: session) }

        mcSession.beginConfiguration()
        // Same rule as `configure` (42.H1): stripped means unconfigured until the rebuild
        // completes, so a throw below can never leave the flags claiming a working session.
        mcConfigured = false
        visionTapActive = nil

        mcSession.connections.forEach { mcSession.removeConnection($0) }
        mcSession.inputs.forEach { mcSession.removeInput($0) }
        mcSession.outputs.forEach { mcSession.removeOutput($0) }

        guard let fDev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let fIn = try? AVCaptureDeviceInput(device: fDev), mcSession.canAddInput(fIn),
              let rDev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let rIn = try? AVCaptureDeviceInput(device: rDev), mcSession.canAddInput(rIn)
        else {
            mcSession.commitConfiguration()
            throw CameraError.unavailable
        }
        mcSession.addInputWithNoConnections(fIn)
        mcSession.addInputWithNoConnections(rIn)
        frontDevice = fDev
        rearDevice = rDev

        guard let fPort = fIn.ports(for: .video, sourceDeviceType: fDev.deviceType,
                                    sourceDevicePosition: .front).first,
              let rPort = rIn.ports(for: .video, sourceDeviceType: rDev.deviceType,
                                    sourceDevicePosition: .back).first
        else {
            mcSession.commitConfiguration()
            throw CameraError.unavailable
        }

        do {
            if forClips {
                try connect(frontMovieOutput, to: fPort)
                try connect(rearMovieOutput, to: rPort)
            } else {
                try connect(frontPhotoOutput, to: fPort)
                try connect(rearPhotoOutput, to: rPort)
            }
        } catch {
            mcSession.commitConfiguration()
            throw error
        }

        // The vision tripwire in Both mode (BACKLOG 16 follow-up). A multi-cam session has a
        // hardware cost budget and this is a *third* output, so it may not fit — and an
        // over-budget session drops connections or refuses to run, which would take the Both
        // capture down with it. Trading a shipped capture feature for a tripwire is not the
        // deal, so this attaches, measures, and backs out if it doesn't fit.
        if visionTapEnabled { attachVisionTapToMultiCam(frontPort: fPort) } else { visionTapActive = nil }

        mcSession.commitConfiguration()

        // `isActive` is only meaningful once the configuration is committed — and an attached
        // output whose connection is inactive is the failure mode that looks exactly like a
        // working one from the app's side.
        if visionTapEnabled, visionTapActive == true {
            let live = visionOutput.connection(with: .video)?.isActive ?? false
            visionTapActive = live
            if live {
                Log.camera.info("Vision tap active on the front camera (multi-cam)")
            } else {
                Log.camera.error("Vision tap attached to multi-cam but its connection is INACTIVE")
            }
        }
        resetVisionCounters()
        mcConfigured = true
        mcForClips = forClips
        mcConfiguredVision = visionTapEnabled
    }

    /// Clears the frame counters **on the queue that owns them**.
    ///
    /// They are written by the sample-buffer delegate on `visionQueue` and were being zeroed
    /// here on `sessionQueue` — two serial queues touching the same memory with nothing ordering
    /// them, under a `nonisolated(unsafe)` that says the synchronisation is handled. It wasn't.
    /// The stakes are low (these drive frame decimation and the fps log line, not any evidence
    /// path), but "low stakes" is not the same as "defined", and under Swift 6 it stops
    /// compiling. Dispatching the reset puts every access on one queue, which is what the
    /// annotation was claiming all along.
    private func resetVisionCounters() {
        visionQueue.async {
            self.visionFirstFrameAt = nil
            self.visionWindowStart = nil
            self.visionProcessed = 0
        }
    }

    /// Hands the shared vision output back from whichever session isn't about to use it.
    ///
    /// An `AVCaptureVideoDataOutput` belongs to exactly one session at a time, and
    /// `canAddOutput` just returns **false** while another session still owns it — no error, no
    /// exception, the tap simply never attaches. Each path clears its *own* outputs when it
    /// reconfigures, which is exactly why neither noticed it was still holding the other's:
    /// after a Both-mode session, every single-camera configuration skipped the tap and the
    /// tripwire went quiet with nothing logged. (Found on device 2026-08-26, as "No frames"
    /// on Rear — and it was never rear-specific.)
    private func releaseVisionOutput(from other: AVCaptureSession) {
        guard other.outputs.contains(visionOutput) else { return }
        other.beginConfiguration()
        other.removeOutput(visionOutput)
        other.commitConfiguration()
        // The session that lost the tap is no longer configured WITH it. Left claiming it
        // was, the next warm-up whose shape otherwise matched reused that session unchanged —
        // running with no tap while `visionTapActive` still read true from the other one, and
        // the Vision tripwire was silently dead in Both mode after any single-camera cadence
        // still (item 65, finding 9).
        let flags = Self.configuredVisionAfterRelease(fromMultiCam: other === mcSession,
                                                      single: configuredVision, multiCam: mcConfiguredVision)
        configuredVision = flags.single
        mcConfiguredVision = flags.multiCam
        Log.camera.info("Vision tap released from the previous session")
    }

    /// Pure (unit-tested): the configured-vision bookkeeping after the tap leaves one session
    /// for the other — the side that lost it is cleared, the other side keeps its answer.
    nonisolated static func configuredVisionAfterRelease(fromMultiCam: Bool, single: Bool,
                                                         multiCam: Bool) -> (single: Bool, multiCam: Bool) {
        fromMultiCam ? (single, false) : (false, multiCam)
    }

    /// Whether the multi-cam session has to be rebuilt to satisfy the requested shape.
    ///
    /// The mirror of `needsReconfiguration` for the other session, separate only because
    /// multi-cam has no camera position to match. It exists as its own named rule because the
    /// inline version of it forgot about Vision: a session configured with the tripwire off was
    /// reused when the tripwire was later turned on, as long as capture mode had not changed,
    /// and the tap never attached. Found by external review the same day the tap was added.
    nonisolated static func multiCamNeedsReconfiguration(isConfigured: Bool,
                                                         configuredForClips: Bool, wantClips: Bool,
                                                         configuredVision: Bool, wantVision: Bool) -> Bool {
        guard isConfigured else { return true }
        if configuredForClips != wantClips { return true }
        if configuredVision != wantVision { return true }
        return false
    }

    /// Ceiling for `AVCaptureMultiCamSession.hardwareCost`. Apple's contract: above 1.0 the
    /// session cannot run the requested configuration.
    nonisolated static let multiCamHardwareCostCeiling: Float = 1.0

    /// Whether a measured multi-cam hardware cost leaves room for the vision tap.
    ///
    /// Pure so the *direction* of the decision is pinned by a test: over budget means drop the
    /// tripwire and keep the capture, never the reverse. Capture is the product; the tripwire
    /// is one of several ways to start one.
    nonisolated static func visionTapFitsMultiCam(hardwareCost: Float) -> Bool {
        hardwareCost <= multiCamHardwareCostCeiling
    }

    /// Attaches the frame tap to the **front** camera of the multi-cam session — one camera is
    /// enough for a tripwire, and the front is the one this app already treats as primary
    /// (it's the capture the screen flash lights). Must be called inside a configuration block.
    private func attachVisionTapToMultiCam(frontPort: AVCaptureInput.Port) {
        visionTapActive = false
        visionOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        visionOutput.alwaysDiscardsLateVideoFrames = true
        visionOutput.setSampleBufferDelegate(self, queue: visionQueue)

        guard mcSession.canAddOutput(visionOutput) else {
            Log.camera.error("Vision tap: multi-cam refused the output")
            return
        }
        mcSession.addOutputWithNoConnections(visionOutput)
        let conn = AVCaptureConnection(inputPorts: [frontPort], output: visionOutput)
        guard mcSession.canAddConnection(conn) else {
            mcSession.removeOutput(visionOutput)
            Log.camera.error("Vision tap: multi-cam refused the connection")
            return
        }
        mcSession.addConnection(conn)

        let cost = mcSession.hardwareCost
        guard Self.visionTapFitsMultiCam(hardwareCost: cost) else {
            mcSession.removeConnection(conn)
            mcSession.removeOutput(visionOutput)
            Log.camera.error("Vision tap removed: multi-cam hardware cost \(cost, privacy: .public) exceeds budget — keeping the Both capture")
            return
        }
        Log.camera.info("Vision tap fits multi-cam (hardware cost \(cost, privacy: .public))")
        visionTapActive = true
    }

    private func connect(_ output: AVCaptureOutput, to port: AVCaptureInput.Port) throws {
        guard mcSession.canAddOutput(output) else { throw CameraError.unavailable }
        mcSession.addOutputWithNoConnections(output)
        let conn = AVCaptureConnection(inputPorts: [port], output: output)
        guard mcSession.canAddConnection(conn) else { throw CameraError.unavailable }
        mcSession.addConnection(conn)
    }

    // MARK: - Single-camera capture

    /// A still from the active single camera. `hardwareFlash` fires the LED
    /// (rear only; front is lit by the app's screen flash).
    nonisolated func captureStill(hardwareFlash: Bool) async throws -> Data {
        try await capturePhoto(slot: .single, flash: hardwareFlash)
    }

    /// Begins a clip on the single-camera movie output.
    nonisolated func beginClip(torch: Bool) {
        guard let epoch = admittedEpoch() else { return }
        sessionQueue.async {
            guard self.owns(epoch) else { return }
            guard !self.movieOutput.isRecording else { return }
            guard self.session.isRunning else { return }   // nothing starts on a stopped session; endClip then fails fast (R3.1)
            self.clipInterrupted = false
            self.clipRecordingEnded = false
            self.clipInterruptionReasonValue = nil
            self.discardParkedClip(.single)
            guard let destination = Self.pendingMovieDestinations(outputs: 1)?.first else { return }
            // Lit only once there is somewhere to record (item 108, F8): lit before, a refused
            // clip left the torch on, recording nothing, until the clip's end turned it off.
            if torch { self.setTorch(true, device: self.videoDevice) }
            let url = destination.url
            self.movieOutput.maxRecordedFileSize = destination.limit
            self.registerFile(url, camera: self.configuredPosition == .back ? .rear : .front)
            self.movieExpectedURLs[.single] = url
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// The pending store's admission budget, read without reserving anything (item 112), so the
    /// pipeline can refuse a clip before the camera starts or any light comes on.
    nonisolated func hasRoomForClips(outputs: Int) -> Bool {
        Self.pendingMovieDestinations(outputs: outputs) != nil
    }

    /// Stops the single-camera clip and returns its file URL.
    nonisolated func endClip() async throws -> URL {
        defer { sessionQueue.async { self.setTorch(false, device: self.videoDevice) } }
        return try await endRecording(slot: .single)
    }

    // MARK: - Multi-cam capture (both cameras at once)

    /// Captures a still from front AND rear simultaneously.
    nonisolated func captureBothStills(rearHardwareFlash: Bool) async throws -> (front: Data?, rear: Data?) {
        async let front = capturePhoto(slot: .front, flash: false)
        async let rear = capturePhoto(slot: .rear, flash: rearHardwareFlash)
        let f = try? await front
        let r = try? await rear
        return (f, r)
    }

    /// Each completed photo leaves its sibling's wait immediately, with its physical lens.
    nonisolated func captureBothStills(rearHardwareFlash: Bool,
                                       onFinalized: @escaping @Sendable (Data, CameraChoice) async -> Void) async -> (front: Data?, rear: Data?) {
        async let front = finalizePhoto(slot: .front, flash: false, lens: .front, onFinalized: onFinalized)
        async let rear = finalizePhoto(slot: .rear, flash: rearHardwareFlash, lens: .rear, onFinalized: onFinalized)
        return await (front, rear)
    }

    nonisolated private func finalizePhoto(slot: Slot, flash: Bool, lens: CameraChoice,
                                           onFinalized: @escaping @Sendable (Data, CameraChoice) async -> Void) async -> Data? {
        guard let data = try? await capturePhoto(slot: slot, flash: flash) else { return nil }
        await onFinalized(data, lens)
        return data
    }

    /// Begins a clip on BOTH cameras at once.
    nonisolated func beginBothClips(rearTorch: Bool) {
        guard let epoch = admittedEpoch() else { return }
        sessionQueue.async {
            guard self.owns(epoch) else { return }
            guard self.mcSession.isRunning else { return }   // as beginClip (R3.1)
            self.clipInterrupted = false
            self.clipRecordingEnded = false
            self.clipInterruptionReasonValue = nil
            self.discardParkedClip(.front)
            self.discardParkedClip(.rear)
            guard !self.frontMovieOutput.isRecording, !self.rearMovieOutput.isRecording,
                  let destinations = Self.pendingMovieDestinations(outputs: 2) else { return }
            if rearTorch { self.setTorch(true, device: self.rearDevice) }   // as beginClip (item 108, F8)
            if !self.frontMovieOutput.isRecording {
                let url = destinations[0].url
                self.frontMovieOutput.maxRecordedFileSize = destinations[0].limit
                self.registerFile(url, camera: .front)
                self.movieExpectedURLs[.front] = url
                self.frontMovieOutput.startRecording(to: url, recordingDelegate: self)
            }
            if !self.rearMovieOutput.isRecording {
                let url = destinations[1].url
                self.rearMovieOutput.maxRecordedFileSize = destinations[1].limit
                self.registerFile(url, camera: .rear)
                self.movieExpectedURLs[.rear] = url
                self.rearMovieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    /// Stops both clips and returns their URLs.
    nonisolated func endBothClips() async throws -> (front: URL?, rear: URL?) {
        async let front = endRecording(slot: .front)
        async let rear = endRecording(slot: .rear)
        let f = try? await front
        let r = try? await rear
        sessionQueue.async { self.setTorch(false, device: self.rearDevice) }
        return (f, r)
    }

    /// Stop both outputs concurrently, publishing each exact file as soon as its delegate
    /// answers. The other lens may still be stalled; the pipeline can already preserve this one.
    nonisolated func endBothClips(onFinalized: @escaping @Sendable (URL, CameraChoice) async -> Void) async -> (front: URL?, rear: URL?) {
        async let front = finalize(slot: .front, camera: .front, onFinalized: onFinalized)
        async let rear = finalize(slot: .rear, camera: .rear, onFinalized: onFinalized)
        let result = await (front, rear)
        sessionQueue.async { self.setTorch(false, device: self.rearDevice) }
        return result
    }

    nonisolated private func finalize(slot: Slot, camera: CameraChoice,
                                      onFinalized: @escaping @Sendable (URL, CameraChoice) async -> Void) async -> URL? {
        guard let url = try? await endRecording(slot: slot) else { return nil }
        await onFinalized(url, camera)
        return url
    }

    // MARK: - Capture primitives

    private enum Slot: Hashable { case single, front, rear }

    private func photoOutput(for slot: Slot) -> AVCapturePhotoOutput {
        switch slot {
        case .single: return photoOutput
        case .front:  return frontPhotoOutput
        case .rear:   return rearPhotoOutput
        }
    }

    private func movieOutput(for slot: Slot) -> AVCaptureMovieFileOutput {
        switch slot {
        case .single: return movieOutput
        case .front:  return frontMovieOutput
        case .rear:   return rearMovieOutput
        }
    }

    private func capturePhoto(slot: Slot, flash: Bool) async throws -> Data {
        guard let epoch = admittedEpoch() else { throw CameraError.timedOut }
        return try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                guard self.owns(epoch) else { cont.resume(throwing: CameraError.timedOut); return }
                // A stopped session never answers (review 3, R3.1): the disarm's shutdown can land
                // between the pipeline's last check and this hop, and AVFoundation's reaction to a
                // capture on a stopped session is not something to rely on. Refuse here, on the
                // queue where the order of the two is settled.
                let owner: AVCaptureSession = slot == .single ? self.session : self.mcSession
                guard owner.isRunning else {
                    cont.resume(throwing: CameraError.sessionNotRunning)
                    return
                }
                let output = self.photoOutput(for: slot)
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.flashMode = (flash && output.supportedFlashModes.contains(.on)) ? .on : .off
                let id = settings.uniqueID
                self.photoConts[id] = cont
                output.capturePhoto(with: settings, delegate: self)
                // The pipeline's independent clock bounds its caller. Retain this unique-ID
                // waiter for late evidence; quarantine prevents new work until it drains.

            }
        }
    }

    /// Stops this exact recording and preserves its callback/file ownership. The pipeline
    /// independently bounds the waiting response. A stalled delegate quarantines the camera;
    /// retaining at most the active slots prevents late footage being handed to another event.
    private func endRecording(slot: Slot) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                // An interruption may have already finalized this clip before we
                // asked it to stop — return that salvaged partial rather than failing.
                if let finalized = self.movieFinalizedURLs.removeValue(forKey: slot) {
                    cont.resume(returning: finalized)
                    return
                }
                let output = self.movieOutput(for: slot)
                // A recording the session stop already ended — a disarm's `shutDown()` racing
                // the pipeline's stop — reads `isRecording == false` with its delegate callback
                // still on the way. Failing it here lost the usable partial clip: the callback
                // then parked the file for the next clip to discard, and the record said the
                // camera failed (item 65, finding 12). Keep its callback; the pipeline bounds the caller.
                guard Self.shouldAwaitRecording(isRecording: output.isRecording,
                                                callbackPending: self.movieExpectedURLs[slot] != nil) else {
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                // One stop per recording (34.H10): a second concurrent wait on this slot
                // would OVERWRITE the first continuation — the first
                // caller then never resumes, and the trigger pipeline that awaits it wedges
                // with `isHandlingTrigger` stuck, detection dead until disarm. Refuse the
                // newcomer instead; the recording still belongs to whoever is stopping it.
                guard self.movieConts[slot] == nil else {
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                self.movieConts[slot] = cont
                if output.isRecording { output.stopRecording() }   // else the session stop did; the delegate is on its way
                // The pipeline owns the independent deadline. Keep this file's waiter after
                // expiry: quarantine refuses another recording until the delegate drains.
                // A callback that never arrives leaves one bounded waiter, not a live trigger.

            }
        }
    }

    /// A stopped recording may still owe its final delegate callback. Wait for that exact
    /// file; only fail immediately when nothing was started. The pipeline bounds the caller.
    nonisolated static func shouldAwaitRecording(isRecording: Bool, callbackPending: Bool) -> Bool {
        isRecording || callbackPending
    }

    /// Retire an unclaimed slot association without destroying the bytes. New recordings
    /// have unique URLs; an unclaimed file can never be mistaken for their output.
    private func discardParkedClip(_ slot: Slot) {
        if let parked = movieFinalizedURLs.removeValue(forKey: slot) {
            // Preserve unclaimed bytes; never delete footage merely to reuse a capture slot.
            Log.camera.error("Retained unclaimed clip: \(parked.lastPathComponent, privacy: .private)")
        }
    }

    // MARK: - Torch

    private func setTorch(_ on: Bool, device: AVCaptureDevice?) {
        guard let device, device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    /// Admission budget for retained, not-yet-attached movies. Refuse unreadable or linked
    /// entries instead of deleting evidence to make room. Separate from the event-log budget.
    nonisolated static func pendingMovieAllowance(in root: URL, outputs: Int = 1) -> Int64? {
        let fm = FileManager.default
        guard outputs > 0, outputs <= 2,
              let rootAttributes = try? fm.attributesOfItem(atPath: root.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory,
              let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
              files.count + outputs <= 1_200 else { return nil }
        var remaining = EventStore.maxMediaBytes
        for file in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.referenceCount] as? NSNumber)?.intValue == 1,
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size >= 0, size < remaining else { return nil }
            remaining -= size
        }
        let limit = remaining / Int64(outputs)
        return limit > 0 ? limit : nil
    }

    /// Reserve all requested output slots from one snapshot before either recording starts.
    nonisolated static func pendingMovieDestinations(in root: URL, outputs: Int) -> [(url: URL, limit: Int64)]? {
        guard let limit = pendingMovieAllowance(in: root, outputs: outputs) else { return nil }
        return (0..<outputs).map { _ in (root.appendingPathComponent(UUID().uuidString + ".mov"), limit) }
    }

    /// Where recordings wait until the event log takes them: the log moves each clip out as it
    /// attaches it.
    nonisolated static var pendingClipsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingCameraEvidence", isDirectory: true)
    }

    private static func pendingMovieDestinations(outputs: Int) -> [(url: URL, limit: Int64)]? {
        let root = pendingClipsFolder
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch { return nil }
        guard let destinations = pendingMovieDestinations(in: root, outputs: outputs) else {
            Log.camera.error("Pending camera evidence storage is full or unreadable; retaining existing files")
            return nil
        }
        return destinations
    }

    /// Removes recordings no event took from `pendingClipsFolder` once they are `age` old (item
    /// 108, F8), except the clips named in `keeping`. The event log moves every clip it attaches
    /// out of that folder at once; the one other path that reads it is a save iOS refused (1.8.2's
    /// step 63), whose clip waits there, named by its attachment intent, for the next launch.
    /// Any other clip still there after a month is one no path will ever attach: a recording whose
    /// response ended without it, or whose app was ended mid-recording. Kept, they counted against
    /// the folder's admission budget (`pendingMovieAllowance`), and enough of them refused every
    /// new clip. Only this class's own `<UUID>.mov` files are touched. `root` and `now` are for tests.
    nonisolated static func sweepOrphanedPendingClips(in root: URL? = nil, olderThan age: TimeInterval = 30 * 86_400,
                                                      now: Date = Date(), keeping: Set<String> = []) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root ?? pendingClipsFolder,
                                                                      includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return }
        let cutoff = now.addingTimeInterval(-age)
        for url in urls where url.pathExtension == "mov"
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            && !keeping.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The launch's sweep of `pendingClipsFolder`, run off the main thread (BACKLOG 180's A3). It keeps every clip an
    /// attachment intent names: a save iOS refused leaves its clip waiting there for the next unlocked launch, and a
    /// month without one used to cost the incident its recording. While the intents cannot all be read (they are sealed
    /// while the phone is locked, as in a launch in the background), it cannot tell which clips are waiting, and removes
    /// nothing; a later launch with the phone unlocked sweeps.
    nonisolated static func sweepPendingClipsAtLaunch(in root: URL? = nil, now: Date = Date()) {
        guard let waiting = EventStore.waitingClipNamesClaimedByIntents() else { return }
        sweepOrphanedPendingClips(in: root, now: now, keeping: waiting)
    }

    /// Sweeps legacy temporary movies created before protected pending evidence storage.
    /// Current recordings live in PendingCameraEvidence and are never swept by age here.
    ///
    /// iOS does purge `tmp/` under storage pressure, but that is exactly the moment it is least
    /// able to help, so sweep at launch too. Only our own `<UUID>.mov` files are touched, and
    /// only once they're old enough that no in-flight recording can own them.
    nonisolated static func sweepOrphanedClips(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(at: tmp,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in names where url.pathExtension.lowercased() == "mov" {
            // Only files this class named — a UUID basename. The doc comment always claimed
            // this; the code deleted every old .mov in tmp (34 review P3).
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Thumbnails

    /// A JPEG thumbnail at most `maxDimension` pixels on its longer side, orientation applied.
    /// Decoded through `BoundedImageDecoder` (item 105, F-10): an image over its pixel cap gets
    /// no thumbnail and is never decoded at full size.
    static func thumbnail(from imageData: Data, maxDimension: CGFloat = 200) -> Data? {
        guard let image = BoundedImageDecoder.image(from: imageData, maxPixelSize: Int(maxDimension)) else { return nil }
        return image.jpegData(compressionQuality: 0.4)
    }

    /// A clip's thumbnail: its frame most likely to show something, chosen by what changed in it, or else its frame
    /// about 1 s in, where exposure and the light have settled (BACKLOG 154, 1.8.2's step 35;
    /// `CameraController+ClipThumbnail.swift`); none once AVFoundation runs out of time (codex-14). `duration` is the
    /// clip's measured length when the caller has it, which spares a read of it.
    static func videoThumbnail(from url: URL, duration: Double? = nil, maxDimension: CGFloat = 200) -> Data? {
        clipThumbnailImage(of: url, duration: duration, maxDimension: maxDimension)
            .flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.5) }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        let id = photo.resolvedSettings.uniqueID
        let failure = error
        sessionQueue.async {
            guard let cont = self.photoConts.removeValue(forKey: id) else { return }
            if let failure { cont.resume(throwing: failure) }
            else if let data { cont.resume(returning: data) }
            else { cont.resume(throwing: CameraError.captureFailed) }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        let slot: Slot = output === frontMovieOutput ? .front
                       : output === rearMovieOutput  ? .rear : .single
        let failure = error
        let delivery = ownershipLock.withLock { () -> ((@Sendable (URL, CameraChoice) -> Void)?, CameraChoice?) in
            recordingCompletions[outputFileURL] = Self.recordingSucceeded(error: error)
            return (fileHandlers.removeValue(forKey: outputFileURL), fileCameras.removeValue(forKey: outputFileURL))
        }
        // Publish only to the owner captured before startRecording, even if stopRunning or
        // another camera call has wedged the session queue. The finished file is immutable.
        if let handler = delivery.0, let lens = delivery.1, FileManager.default.fileExists(atPath: outputFileURL.path) {
            handler(outputFileURL, lens)
        }
        sessionQueue.async { self.recordingFinished(slot: slot, at: outputFileURL, failure: failure) }
    }

    /// The delegate's part on `sessionQueue`, once a recording has finished.
    nonisolated private func recordingFinished(slot: Slot, at outputFileURL: URL, failure: Error?) {
        // Only this slot's CURRENT recording may resume anything. A callback for a file the
        // slot is no longer recording to is a straggler from a recording that already timed
        // out; its own capture has been failed already, and letting it through would hand
        // its footage to whatever event is waiting now.
        guard movieExpectedURLs[slot] == outputFileURL else {
            Log.camera.error("Retained an unmatched clip callback; it cannot join another event")
            return
        }
        movieExpectedURLs[slot] = nil
        // Return existing bytes for inspection, not as a claim that recording succeeded.
        // The pipeline measures playability/duration and consults this URL's delegate outcome.
        let usableURL = FileManager.default.fileExists(atPath: outputFileURL.path) ? outputFileURL : nil
        if let cont = movieConts.removeValue(forKey: slot) {
            if let usableURL { cont.resume(returning: usableURL) }
            else if let failure { cont.resume(throwing: failure) }
            else { cont.resume(throwing: CameraError.captureFailed) }
        } else {
            // No one is waiting yet: an interruption, or iOS itself (the clip's size limit, a full
            // disk, a session error), finished this recording before endRecording ran. Stash a file it
            // left so the pending stop returns it, and say the recording has stopped, file or none
            // (BACKLOG 180's A1 and codex-3).
            if let usableURL { movieFinalizedURLs[slot] = usableURL }
            clipRecordingEnded = true
        }
    }

    #if DEBUG
    /// Test-only (BACKLOG 180's codex-3): the single slot's recording, expected at `url`, finishes before its stop, as
    /// the delegate reports it, with or without a file there.
    nonisolated func finishRecordingBeforeItsStopForTesting(at url: URL, failure: Error?) {
        sessionQueue.sync {
            movieExpectedURLs[.single] = url
            recordingFinished(slot: .single, at: url, failure: failure)
        }
    }
    #endif
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (vision tripwire tap)

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        visionFrameCounter &+= 1
        guard visionFrameCounter % Self.visionDecimation == 0,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let frame = VisionDetector.downsample(plane: UnsafeBufferPointer(start: ptr, count: bpr * h),
                                              width: w, height: h, bytesPerRow: bpr)
        let now = Date()
        if visionFirstFrameAt == nil {
            visionFirstFrameAt = now
            visionWindowStart = now
            Log.camera.info("Vision tap: first frame, source \(w, privacy: .public)x\(h, privacy: .public)")
        }
        visionProcessed &+= 1
        // A rate line every ~30s, measured over **that window** rather than since the first
        // frame. A cumulative average is permanently dragged down by the session's ramp-up —
        // on 2026-08-25 it read 1.27 fps while the tap was in fact delivering exactly 2.00,
        // which is the kind of number that gets a healthy feature investigated.
        if visionProcessed % 60 == 0, let windowStart = visionWindowStart {
            let fps = 60 / max(now.timeIntervalSince(windowStart), 0.001)
            visionWindowStart = now
            Log.camera.info("Vision tap: \(self.visionProcessed, privacy: .public) frames, \(fps, format: .fixed(precision: 2), privacy: .public) fps")
        }
        Task { @MainActor in self.onVisionFrame?(frame) }
    }
}
