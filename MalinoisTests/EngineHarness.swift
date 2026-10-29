//
//  EngineHarness.swift
//  MalinoisTests
//
//  The characterization harness (1.3 consolidation, step 3): a camera the engine can drive on
//  a simulator that has none. It records every call and answers with canned data, so a test
//  observes the capture pipeline's BEHAVIOR — what the engine asked for, in what order, and
//  what it did with the answer — rather than AVFoundation's. Production conformer of the same
//  seam: `CameraController`.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

/// Calls arrive from the engine's deadline-racing tasks off the main actor, so every recorded
/// value sits behind a lock; the knobs are set before the engine runs.
final class FakeCamera: EvidenceCamera, @unchecked Sendable {
    struct WarmUp: Equatable {
        let forClips: Bool
        let camera: CameraChoice
    }

    // MARK: Knobs (set before driving the engine)

    var supportsMultiCam = false
    /// The camera permission the engine reads (item 129, T1): allowed unless a test says
    /// otherwise, whatever the simulator has been granted.
    var videoPermission: AVAuthorizationStatus = .authorized
    /// The answer to the camera question (item 162's G1): the permission once asked.
    var videoAccessAnswer: AVAuthorizationStatus = .authorized
    /// Run while the camera question is open, before its answer: a test reads the engine there.
    var duringVideoAccessRequest: (@MainActor () -> Void)?
    var omittedBothCameras: Set<String> = []
    var invalidBothClipFiles: Set<String> = []
    var multiCamWarmUpError: Error?
    var onBothCaptureEnd: (@MainActor () -> Void)?
    var clipAudio = false
    var visionTapActive: Bool?
    var micUnavailableForClips = false
    /// Item 112: the store that holds clips until the log takes them has no room.
    var clipStorageFull = false
    /// What every low-light probe answers — front, rear, or the active camera alike.
    var lowLight = false
    /// Thrown by every warm-up while set: a camera that cannot come up.
    var warmUpError: Error?
    var onWarmUpForTesting: (@MainActor () -> Void)?
    var shutDownDelay: TimeInterval = 0
    /// Seconds a warm-up takes before answering — lets a test outlast the pipeline's deadline.
    var warmUpDelay: TimeInterval = 0
    /// The bytes every still returns. A JPEG start/end marker pair: enough to be "a still"
    /// for the store, which writes it as-is and tolerates a thumbnail it cannot decode.
    var stillData = Data([0xFF, 0xD8, 0xFF, 0xD9])
    var clipInterrupted = false
    /// Investigation-only gates, configured before capture; absent in all ordinary tests.
    var lowLightProbeForTesting: (@Sendable () async -> Bool)?
    var interruptionProbeForTesting: (@Sendable () async -> Bool)?
    var finalizedClipForTesting: URL?
    var finalizedBothForTesting: (front: URL?, rear: URL?)?
    var quarantineFinishProbeForTesting: (@Sendable () async -> Void)?
    private var finalizedHandler: (@Sendable (URL, CameraChoice) -> Void)?
    var heldBothPhotoLensForTesting: CameraChoice = .rear
    var bothPhotoProbeForTesting: (@Sendable () async -> Void)?
    var onStillCapturedForTesting: (@MainActor () -> Void)?
    var rearFinalizeProbeForTesting: (@Sendable () async -> Void)?
    var endClipProbeForTesting: (@Sendable () async -> Void)?
    var recordingSuccessForTesting: Bool? = true
    /// Item 54 knobs: the session's interruption reason, and errors for the shot or clip.
    var interruptionReasonValue: CaptureInterruptionReason?
    var clipEndError: Error?
    var stillError: Error?
    /// Item 65: how many stills FAIL before the camera answers normally — the first attempt is
    /// the interruption's casualty, the retry lands.
    var stillFailuresRemaining = 0
    var onVisionFrame: (@MainActor (VisionFrame) -> Void)?
    var onSessionEvent: (@MainActor (CameraSessionEvent) -> Void)?

    // MARK: The recording indicator

    private let recording = CurrentValueSubject<Bool, Never>(false)
    var isRecordingActive: Bool { recording.value }
    var isRecordingActivePublisher: AnyPublisher<Bool, Never> { recording.eraseToAnyPublisher() }
    /// Tests flip this to observe what the engine does when a session goes live / ends.
    func setRecordingActive(_ on: Bool) { recording.send(on) }

    // MARK: Recorded calls

    private let lock = NSLock()
    private var _warmUps: [WarmUp] = []
    private var _multiCamWarmUps = 0
    private var _stills: [Bool] = []          // hardwareFlash per still
    private var _clips: [Bool] = []           // torch per clip
    private var _bothStills = 0
    private var _bothClips = 0
    private var _clipEnds = 0
    private var _bothClipEnds = 0
    private var _shutDowns = 0
    private var _micDrops = 0
    private var _visionTapRequests: [Bool] = []
    private var _attemptBegins = 0
    private var _roomChecks: [Int] = []
    private var _videoAccessRequests = 0
    private var _holdStills = false
    private var stillWaiters: [CheckedContinuation<Void, Never>] = []

    var warmUps: [WarmUp] { lock.withLock { _warmUps } }
    var multiCamWarmUps: Int { lock.withLock { _multiCamWarmUps } }
    var stills: [Bool] { lock.withLock { _stills } }
    var clips: [Bool] { lock.withLock { _clips } }
    var bothStills: Int { lock.withLock { _bothStills } }
    var bothClips: Int { lock.withLock { _bothClips } }
    /// How many clips' room each storage check asked for (item 116).
    var roomChecks: [Int] { lock.withLock { _roomChecks } }
    var clipEnds: Int { lock.withLock { _clipEnds } }
    /// Both cameras' clips ended: `clipEnds` counts the single camera's only (Codex's note on codex-1's test, 1.8.2).
    var bothClipEnds: Int { lock.withLock { _bothClipEnds } }
    /// Item 65, finding 5: how many attempts announced themselves before touching the lens.
    var attemptBegins: Int { lock.withLock { _attemptBegins } }
    /// How many times the camera question was asked (item 162's G1).
    var videoAccessRequests: Int { lock.withLock { _videoAccessRequests } }

    // MARK: Holding a capture open

    /// While true, every `captureStill` suspends until `releaseStills()` — the window in which a
    /// test observes what the engine did BEFORE the capture answered (the fact-first rule, and
    /// trips folding into an in-flight event).
    var holdStills: Bool {
        get { lock.withLock { _holdStills } }
        set { lock.withLock { _holdStills = newValue } }
    }

    func releaseStills() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdStills = false
            let w = stillWaiters
            stillWaiters = []
            return w
        }
        waiting.forEach { $0.resume() }
    }
    var shutDowns: Int { lock.withLock { _shutDowns } }
    var micDrops: Int { lock.withLock { _micDrops } }

    // MARK: Holding the microphone's release

    private var _holdMicDrop = false
    private var micDropWaiters: [CheckedContinuation<Void, Never>] = []

    /// While true, every `dropMicAndWait` suspends until `releaseMicDrop()`: a camera session queue that does not
    /// answer (item 152's lead 6).
    var holdMicDrop: Bool {
        get { lock.withLock { _holdMicDrop } }
        set { lock.withLock { _holdMicDrop = newValue } }
    }

    func releaseMicDrop() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdMicDrop = false
            let w = micDropWaiters
            micDropWaiters = []
            return w
        }
        waiting.forEach { $0.resume() }
    }
    var visionTapRequests: [Bool] { lock.withLock { _visionTapRequests } }

    // MARK: EvidenceCamera

    func requestVideoAccess() async -> Bool {
        lock.withLock { _videoAccessRequests += 1 }
        await duringVideoAccessRequest?()
        videoPermission = videoAccessAnswer
        return videoAccessAnswer == .authorized
    }

    func setVisionTapEnabled(_ enabled: Bool) { lock.withLock { _visionTapRequests.append(enabled) } }

    func warmUp(forClips: Bool, camera: CameraChoice) async throws -> Bool {
        await onWarmUpForTesting?()
        if warmUpDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(warmUpDelay * 1_000_000_000)) }
        if let warmUpError { throw warmUpError }
        lock.withLock { _warmUps.append(WarmUp(forClips: forClips, camera: camera)) }
        return true   // "reconfigured" — a cold camera pointed at a lens, like the real one
    }

    func warmUpMultiCam(forClips: Bool) async throws -> Bool {
        if let multiCamWarmUpError { throw multiCamWarmUpError }
        if warmUpDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(warmUpDelay * 1_000_000_000)) }
        if let warmUpError { throw warmUpError }
        lock.withLock { _multiCamWarmUps += 1 }
        return true
    }

    func hasRoomForClips(outputs: Int) -> Bool {
        lock.withLock { _roomChecks.append(outputs) }
        return !clipStorageFull
    }
    func shutDown() { lock.withLock { _shutDowns += 1 } }
    func warmUpForAudioHandoff(camera: CameraChoice, deadline: Date) async throws -> Bool {
        if shutDownDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(shutDownDelay * 1_000_000_000)) }
        shutDown()
        guard Date() < deadline else { throw CameraController.CameraError.timedOut }
        return try await warmUp(forClips: true, camera: camera)
    }
    func dropMicAndWait() async {
        lock.withLock { _micDrops += 1 }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if _holdMicDrop { micDropWaiters.append(cont); return false }
                return true
            }
            if resumeNow { cont.resume() }
        }
    }
    func isLowLight() async -> Bool {
        if let probe = lowLightProbeForTesting { return await probe() }
        return lowLight
    }
    func isLowLightFront() async -> Bool { lowLight }
    func isLowLightRear() async -> Bool { lowLight }

    func captureStill(hardwareFlash: Bool) async throws -> Data {
        lock.withLock { _stills.append(hardwareFlash) }
        if let stillError { throw stillError }
        if stillFailuresRemaining > 0 {
            stillFailuresRemaining -= 1
            throw CameraController.CameraError.captureFailed
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let held = lock.withLock { () -> Bool in
                guard _holdStills else { return false }
                stillWaiters.append(cont)
                return true
            }
            if !held { cont.resume() }
        }
        if let stillError { throw stillError }   // a failure injected while the still was held (a disarm stopping the camera)
        await onStillCapturedForTesting?()
        return stillData
    }

    func beginClip(torch: Bool) { lock.withLock { _clips.append(torch) } }
    func endClip() async throws -> URL {
        lock.withLock { _clipEnds += 1 }
        if let endClipProbeForTesting { await endClipProbeForTesting() }
        if let clipEndError { throw clipEndError }
        if let finalizedClipForTesting { return finalizedClipForTesting }
        return try Self.placeholderClipFile()
    }

    func captureBothStills(rearHardwareFlash: Bool) async throws -> (front: Data?, rear: Data?) {
        lock.withLock { _bothStills += 1 }
        if let bothPhotoProbeForTesting { await bothPhotoProbeForTesting() }
        return (omittedBothCameras.contains("front") ? nil : stillData,
                omittedBothCameras.contains("rear") ? nil : stillData)
    }

    func captureBothStills(rearHardwareFlash: Bool,
                           onFinalized: @escaping @Sendable (Data, CameraChoice) async -> Void) async -> (front: Data?, rear: Data?) {
        lock.withLock { _bothStills += 1 }
        let first: CameraChoice = heldBothPhotoLensForTesting == .rear ? .front : .rear
        if !omittedBothCameras.contains(first.rawValue) { await onFinalized(stillData, first) }
        if let bothPhotoProbeForTesting { await bothPhotoProbeForTesting() }
        if !omittedBothCameras.contains(heldBothPhotoLensForTesting.rawValue) {
            await onFinalized(stillData, heldBothPhotoLensForTesting)
        }
        return (omittedBothCameras.contains("front") ? nil : stillData,
                omittedBothCameras.contains("rear") ? nil : stillData)
    }

    func beginBothClips(rearTorch: Bool) { lock.withLock { _bothClips += 1 } }
    func endBothClips() async throws -> (front: URL?, rear: URL?) {
        lock.withLock { _bothClipEnds += 1 }
        await onBothCaptureEnd?()
        if let finalizedBothForTesting { return finalizedBothForTesting }
        func file(_ lens: String) throws -> URL? {
            guard !omittedBothCameras.contains(lens) else { return nil }
            if invalidBothClipFiles.contains(lens) {
                return FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            }
            return try Self.placeholderClipFile()
        }
        return (try file("front"), try file("rear"))
    }

    func endBothClips(onFinalized: @escaping @Sendable (URL, CameraChoice) async -> Void) async -> (front: URL?, rear: URL?) {
        guard let result = try? await endBothClips() else { return (nil, nil) }
        if let front = result.front { await onFinalized(front, .front) }
        if let rearFinalizeProbeForTesting { await rearFinalizeProbeForTesting() }
        if let rear = result.rear { await onFinalized(rear, .rear) }
        return result
    }

    func clipWasInterrupted() async -> Bool {
        if let probe = interruptionProbeForTesting { return await probe() }
        return clipInterrupted
    }
    func interruptionReason() async -> CaptureInterruptionReason? { interruptionReasonValue }
    func beginCaptureAttempt() { lock.withLock { _attemptBegins += 1 } }
    func quarantineCapture() { shutDown() }
    func finishCaptureQuarantine() async {
        if let quarantineFinishProbeForTesting { await quarantineFinishProbeForTesting() }
        shutDown()
    }
    func setFinalizedClipHandler(_ handler: (@Sendable (URL, CameraChoice) -> Void)?) {
        lock.withLock { finalizedHandler = handler }
    }
    func emitFinalizedClipForTesting(_ url: URL, camera: CameraChoice) {
        let callback = lock.withLock { finalizedHandler }
        callback?(url, camera)
    }
    func recordingFinishedSuccessfully(at url: URL) -> Bool? { recordingSuccessForTesting }

    /// A nonempty opaque placeholder for storage/control-flow tests, not playable footage.
    /// Zero bytes represent an incomplete save and are deliberately rejected by recovery.
    private static func placeholderClipFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("fake-clip-payload".utf8).write(to: url)
        return url
    }
}

// MARK: - Test isolation (item 84)

/// What one test leaves behind must not reach the next (item 84). Every test class that builds
/// an engine or a store calls `setUp(folderPrefix:)` and `tearDown()` (or, off the main actor,
/// `tearDownFolderAndFlags()`) from its own, and wraps each engine it builds in `track`: the
/// test gets a store folder of its own, its engines are disarmed afterwards (once what they
/// queued for the main run loop has landed), and the flags engines keep in UserDefaults are
/// cleared on both sides — every engine in the process shares them, the test host's own
/// included, and a flag left behind changes the next test's recovery.
enum TestIsolation {
    /// Every key an engine keeps about a session and its recovery, matched by prefix so a flag
    /// added later is covered without editing a list: the armed marker and boot stamp, the
    /// lapse-logged flag, the countdown marker, the owed re-arm and the crash-loop timestamp; and
    /// the heartbeat's watches waiting for their trails to be trimmed (item 52's follow-up 2).
    nonisolated static let recoveryFlagPrefixes = ["com.malinois.armedSession.", "com.malinois.armed.",
                                                   "com.malinois.arming.", "com.malinois.recovery.",
                                                   "com.malinois.protection.",   // item 91's recorded settings
                                                   "com.malinois.beats.",
                                                   "com.malinois.retention.",   // item 116's marker limit
                                                   "com.malinois.rating.",   // item 137: the calm disarms
                                                   "com.malinois.settings.resetPending"]   // codex-10's residual: owed

    @MainActor private static var engines: [MonitoringEngine] = []

    /// A fresh store folder for the test, and no flags left by the one before.
    nonisolated static func setUp(folderPrefix: String) {
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderPrefix + "-" + UUID().uuidString, isDirectory: true)
        MainActor.assumeIsolated {
            if let root = EventStore.rootOverrideForTesting {
                CloudEnrollment.sharedForTesting = CloudEnrollment(file: root.appendingPathComponent("enrollment/state.json"),
                                                                   authenticate: { _ in false })
            }
        }
        clearRecoveryFlags()
        // No PIN recovery pending for this test's engines (item 152's lead 18): the Keychain and the test host's own
        // log are shared by every test in the process, so the real answer depends on what ran before.
        MonitoringEngine.recoveryPendingForTesting = false
    }

    /// What the test's engines queued landed, the engines disarmed, then the test's flags cleared
    /// and its folder removed. Called from XCTest's `tearDown`, which is not main-actor isolated
    /// but runs on the main thread (item 97). Keep the callers' setUp and tearDown synchronous:
    /// XCTest runs the async forms on another thread, where `MainActor.assumeIsolated` would stop
    /// the test.
    nonisolated static func tearDown() {
        MainActor.assumeIsolated {
            letQueuedWorkLand()
            disarmTrackedEngines()
        }
        tearDownFolderAndFlags()
    }

    /// Turns the main run loop briefly after a test that built engines, so what they queued for
    /// it lands in that test, before they are disarmed and its flags cleared. An engine hears its
    /// Pro check through the loop (`.receive(on: RunLoop.main)`), and many tests never turn it:
    /// the answer used to wait for the next test that did, where the engine acted on that test's
    /// flags and took the re-arm owed to that test's own engine (the test-suite audit's ME206).
    @MainActor static func letQueuedWorkLand() {
        guard !engines.isEmpty else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// The flags cleared and the folder removed — for a class that builds stores but no engines.
    nonisolated static func tearDownFolderAndFlags() {
        clearRecoveryFlags()
        MonitoringEngine.recoveryPendingForTesting = nil
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        MainActor.assumeIsolated {
            EventStore.checkpointObserverForTesting = nil   // item 155's S1: no test's observer outlives it
            CloudEnrollment.sharedForTesting = nil
            BackgroundAssertion.providerForTesting = nil   // item 153's MAL-01: UIKit's assertions again
        }
    }

    /// Keeps `engine` for the tearDown's disarm, and returns it, so a rig can wrap its constructor.
    @MainActor @discardableResult
    static func track(_ engine: MonitoringEngine) -> MonitoringEngine {
        engines.append(engine)
        return engine
    }

    /// Disarms every tracked engine: one a failing test left armed stops here instead of
    /// running into the next test.
    @MainActor static func disarmTrackedEngines() {
        for engine in engines { engine.disarm() }
        engines.removeAll()
    }

    nonisolated static func clearRecoveryFlags() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where recoveryFlagPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// A phone's lock state that a test flips while the code under test reads it through a closure
/// (items 77, 85 and 86). A holder rather than a local `var`: Swift 6 warns when a `var` is changed
/// after a Sendable closure captured it (item 97).
@MainActor
final class LockState {
    var unlocked = false
}

/// A yes or no a test sets on one thread and reads on another, behind a lock. A test's stand-ins (an
/// upload held open, a step entered) run off the main actor, where a captured local `var` is "mutated
/// after capture by sendable closure" under Swift 6 (item 124's test housekeeping).
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ value: Bool = false) { flag = value }

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// What a real screen shows when laid out in a window of `size` (item 82's pattern: at the origin, safe
/// areas ignored): the texts its reporting views show (`OnScreenText.swift`, Debug only) and where each
/// is laid out, read before the window closes. For tests that check a screen, rather than its source.
@MainActor
func shownOnScreen<V: View>(_ view: V, in size: CGSize = CGSize(width: 402, height: 874))
    throws -> (shown: [String], frames: [String: CGRect]) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                              "the test host has no window scene")
    let recorder = OnScreenRecorder()
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let controller = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
    controller.safeAreaRegions = []
    window.rootViewController = controller
    window.isHidden = false
    defer {
        window.isHidden = true
        window.rootViewController = nil
    }
    controller.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    controller.view.layoutIfNeeded()
    return (recorder.shown, recorder.frames)
}

/// What Settings shows, laid out with a test's own services in a window tall enough for every row
/// (the test-suite audit's P4: these checks read the screen's source before). `configure` sets the
/// settings first; the Pro check answers `status` (Pro by default: the iCloud rows show only with it).
@MainActor
func settingsShownOnScreen(status: ProEntitlements.Status = .trial,
                           _ configure: (AppSettings) -> Void = { _ in }) throws -> [String] {
    let settings = AppSettings()
    configure(settings)
    let entitlements = ProEntitlements(resolvedAs: status)
    let cloud = CloudExfiltrator()
    let store = EventStore()
    let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                      camera: FakeCamera(), entitlements: entitlements,
                                                      timing: EngineCharacterizationTests.fastTiming))
    let screen = SettingsView()
        .environmentObject(settings).environmentObject(cloud)
        .environmentObject(entitlements).environmentObject(engine)
        .environmentObject(store).environmentObject(CameraController())   // the Debug rows read the log
    return try shownOnScreen(screen, in: CGSize(width: 402, height: 12_000)).shown
}
