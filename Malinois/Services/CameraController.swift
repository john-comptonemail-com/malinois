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
@preconcurrency import AVFoundation
import UIKit

// @unchecked Sendable: all mutable state is confined to `sessionQueue`.
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {

    enum CameraError: Error { case unauthorized, unavailable, captureFailed, timedOut }
    private enum Lens { case front, rear }

    /// Whether this device can capture both cameras at once.
    static var supportsMultiCam: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    private let sessionQueue = DispatchQueue(label: "com.malinois.camera.session")

    // MARK: Single-camera session
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var isConfigured = false
    nonisolated(unsafe) private var videoDevice: AVCaptureDevice?
    nonisolated(unsafe) private var configuredPosition: AVCaptureDevice.Position = .front
    nonisolated(unsafe) private var configuredForClips = false
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
    /// Photo continuations keyed by the capture's settings uniqueID, so a delegate
    /// callback always resumes exactly its own capture — even if an earlier still
    /// timed out and a new one started (no cross-wiring, no leaked continuation).
    nonisolated(unsafe) private var photoConts: [Int64: CheckedContinuation<Data, Error>] = [:]
    /// Movie-recording continuations keyed by slot. A monotonic token per start
    /// lets a timeout cancel only the recording it was scheduled for (never a
    /// newer one that happened to reuse the slot).
    nonisolated(unsafe) private var movieConts: [Slot: CheckedContinuation<URL, Error>] = [:]
    nonisolated(unsafe) private var movieTokens: [Slot: Int] = [:]
    /// The file each slot is currently recording to.
    ///
    /// The delegate callback is keyed only by slot, and a slot is reused by the next recording.
    /// So a callback arriving late — after its own recording timed out and a new one started —
    /// would resume the **new** recording's continuation with the **old** clip's URL, attaching
    /// one event's footage to a different event. In an evidence app that is worse than losing
    /// the clip. Matching on the URL is what makes a callback provably its own.
    nonisolated(unsafe) private var movieExpectedURLs: [Slot: URL] = [:]
    nonisolated(unsafe) private var movieTokenCounter = 0
    /// Partial clips finalized by an interruption (e.g. the app was backgrounded)
    /// before `endRecording` was called — stashed so the pending stop can still
    /// return the salvaged file instead of failing.
    nonisolated(unsafe) private var movieFinalizedURLs: [Slot: URL] = [:]
    /// Set when the active clip's session is interrupted, so the until-clear loop
    /// stops waiting on a dead session and finalizes the partial now.
    nonisolated(unsafe) private var clipInterrupted = false

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
                           object: s, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { self?.clipInterrupted = true }
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

    // MARK: - Permissions

    static func requestAccess() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)   // for clip audio
        return camera
    }

    // MARK: - Single-camera warm-up

    /// Configures and starts the single-camera session. Returns true if the caller
    /// should let exposure settle — either it reconfigured, or it started a *cold*
    /// session (battery-saver / Auto-on-battery), whose first frames are still
    /// ramping. Switching cameras is a clean stop → reconfigure → start, which
    /// avoids blank/stale frames that come from mutating a live session.
    @discardableResult
    nonisolated func warmUp(forClips: Bool, camera: CameraChoice) async throws -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.unauthorized
        }
        let position: AVCaptureDevice.Position = camera == .rear ? .back : .front
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            sessionQueue.async {
                do {
                    if self.mcSession.isRunning { self.mcSession.stopRunning() }
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
                        micDropped: self.micDropped)
                    if needsReconfig && wasRunning { self.session.stopRunning() }
                    let didReconfigure = try self.configure(forClips: forClips, position: position)
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
        guard Self.supportsMultiCam else { throw CameraError.unavailable }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.unauthorized
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            sessionQueue.async {
                do {
                    if self.session.isRunning { self.session.stopRunning() }
                    let wasRunning = self.mcSession.isRunning
                    try self.configureMultiCam(forClips: forClips)
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
                                                 micDropped: Bool) -> Bool {
        guard isConfigured else { return true }
        if configuredPosition != wantPosition { return true }
        if configuredForClips != wantClips { return true }
        if configuredVision != wantVision { return true }
        // Only clips need the mic back; a stills session never had one.
        if micDropped && wantClips { return true }
        return false
    }

    /// Returns true if it actually (re)configured the session. Assumes the caller
    /// stopped the session first when switching.
    @discardableResult
    private func configure(forClips: Bool, position: AVCaptureDevice.Position) throws -> Bool {
        guard Self.needsReconfiguration(isConfigured: isConfigured,
                                        configuredPosition: configuredPosition, wantPosition: position,
                                        configuredForClips: configuredForClips, wantClips: forClips,
                                        configuredVision: configuredVision, wantVision: visionTapEnabled,
                                        micDropped: micDropped) else { return false }

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

        if forClips {
            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                // Logged because the failure it guards is otherwise invisible: after a siren
                // drops the mic, a clip session that is never rebuilt records silently, and
                // nothing surfaces it until someone plays the evidence back (BACKLOG 17).
                Log.camera.info("Mic attached for clip capture")
            } else {
                Log.camera.error("Clip session configured WITHOUT a mic — clips will be silent")
            }
            // A refused PRIMARY output must fail the configuration, not be shrugged off
            // (34.H12): accepting it marked the session configured while every capture on it
            // was doomed to time out — "configured" must mean "can capture".
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
        Log.camera.info("Vision tap released from the previous session")
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
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            self.clipInterrupted = false
            self.movieFinalizedURLs[.single] = nil
            if torch { self.setTorch(true, device: self.videoDevice) }
            let url = Self.tempMovieURL()
            self.movieExpectedURLs[.single] = url
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
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

    /// Begins a clip on BOTH cameras at once.
    nonisolated func beginBothClips(rearTorch: Bool) {
        sessionQueue.async {
            self.clipInterrupted = false
            self.movieFinalizedURLs[.front] = nil
            self.movieFinalizedURLs[.rear] = nil
            if rearTorch { self.setTorch(true, device: self.rearDevice) }
            if !self.frontMovieOutput.isRecording {
                let url = Self.tempMovieURL()
                self.movieExpectedURLs[.front] = url
                self.frontMovieOutput.startRecording(to: url, recordingDelegate: self)
            }
            if !self.rearMovieOutput.isRecording {
                let url = Self.tempMovieURL()
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

    private func capturePhoto(slot: Slot, flash: Bool, timeout: Double = 6) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                let output = self.photoOutput(for: slot)
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.flashMode = (flash && output.supportedFlashModes.contains(.on)) ? .on : .off
                let id = settings.uniqueID
                self.photoConts[id] = cont
                output.capturePhoto(with: settings, delegate: self)
                // Bound the wait: if the delegate never fires, resume with an
                // error and remove the entry so it can't leak or cross-wire.
                self.sessionQueue.asyncAfter(deadline: .now() + timeout) {
                    if let stale = self.photoConts.removeValue(forKey: id) {
                        stale.resume(throwing: CameraError.captureFailed)
                    }
                }
            }
        }
    }

    /// Stops a recording and waits for the delegate to deliver the file. Bounded:
    /// `stopRecording()` normally finalizes in well under a second, so if the
    /// delegate never fires (interrupted session, hardware stall) the wait is cut
    /// after `timeout` and the caller gets an error instead of hanging forever —
    /// which would otherwise wedge the whole trigger pipeline (`isHandlingTrigger`
    /// would stay set and no further tampering would ever be caught). The per-start
    /// token ensures a late timeout can't cancel a newer recording on the same slot.
    private func endRecording(slot: Slot, timeout: Double = 8) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                // An interruption may have already finalized this clip before we
                // asked it to stop — return that salvaged partial rather than failing.
                if let finalized = self.movieFinalizedURLs.removeValue(forKey: slot) {
                    cont.resume(returning: finalized)
                    return
                }
                let output = self.movieOutput(for: slot)
                guard output.isRecording else {
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                // One stop per recording (34.H10): a second concurrent wait on this slot
                // would OVERWRITE the first continuation and its timeout token — the first
                // caller then never resumes, and the trigger pipeline that awaits it wedges
                // with `isHandlingTrigger` stuck, detection dead until disarm. Refuse the
                // newcomer instead; the recording still belongs to whoever is stopping it.
                guard self.movieConts[slot] == nil else {
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                self.movieTokenCounter += 1
                let token = self.movieTokenCounter
                self.movieConts[slot] = cont
                self.movieTokens[slot] = token
                output.stopRecording()
                self.sessionQueue.asyncAfter(deadline: .now() + timeout) {
                    guard self.movieTokens[slot] == token,
                          let stale = self.movieConts.removeValue(forKey: slot) else { return }
                    self.movieTokens[slot] = nil
                    stale.resume(throwing: CameraError.captureFailed)
                    // The capture is failed — now make the RECORDING provably over too
                    // (39.R1.3). Left alone, the expected-URL entry still matched a late
                    // callback, which PARKED the stale file for the next stop on this slot
                    // to consume — one event's footage attached to another event's record,
                    // the exact cross-wiring the URL matching exists to prevent — and a
                    // stalled output still "recording" blocked the next beginClip outright.
                    // Forgetting the URL routes any late callback into the delegate's
                    // discard-and-delete branch; the stop unwedges the output.
                    self.movieExpectedURLs[slot] = nil
                    let output = self.movieOutput(for: slot)
                    if output.isRecording { output.stopRecording() }
                }
            }
        }
    }

    // MARK: - Torch

    private func setTorch(_ on: Bool, device: AVCaptureDevice?) {
        guard let device, device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    private static func tempMovieURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    }

    /// Deletes clip temp files the event store never took ownership of. `EventStore.store`
    /// *moves* a recorded clip out of `tmp/`, so anything left behind is a move that failed —
    /// realistically a full disk during a long "until clear" recording. The event correctly
    /// records no filename in that case, so the file is unreferenced and pure leak.
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

    static func thumbnail(from imageData: Data, maxDimension: CGFloat = 200) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return thumb.jpegData(compressionQuality: 0.4)
    }

    static func videoThumbnail(from url: URL, maxDimension: CGFloat = 200) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Prefer a frame ~1s in — exposure/illumination have settled and the subject
        // is more likely in frame than at 0.2s — falling back for very short clips.
        for seconds in [1.0, 0.3, 0.0] {
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                   actualTime: nil) {
                return UIImage(cgImage: cg).jpegData(compressionQuality: 0.5)
            }
        }
        return nil
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
        sessionQueue.async {
            // Only this slot's CURRENT recording may resume anything. A callback for a file the
            // slot is no longer recording to is a straggler from a recording that already timed
            // out; its own capture has been failed already, and letting it through would hand
            // its footage to whatever event is waiting now.
            guard self.movieExpectedURLs[slot] == outputFileURL else {
                Log.camera.error("Discarded a late clip callback for a previous recording")
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            self.movieExpectedURLs[slot] = nil
            self.movieTokens[slot] = nil
            // A very short or interrupted recording can "fail" but still produce a
            // usable file — treat a file that exists as success.
            let usableURL = FileManager.default.fileExists(atPath: outputFileURL.path) ? outputFileURL : nil
            if let cont = self.movieConts.removeValue(forKey: slot) {
                if let usableURL { cont.resume(returning: usableURL) }
                else if let failure { cont.resume(throwing: failure) }
                else { cont.resume(throwing: CameraError.captureFailed) }
            } else if let usableURL {
                // No one is waiting yet: an interruption finalized this clip before
                // endRecording ran. Stash it so the pending stop returns it.
                self.movieFinalizedURLs[slot] = usableURL
            }
        }
    }
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
