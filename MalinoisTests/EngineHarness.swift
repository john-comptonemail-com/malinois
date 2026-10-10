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

import Foundation
import Combine
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
    var omittedBothCameras: Set<String> = []
    var invalidBothClipFiles: Set<String> = []
    var multiCamWarmUpError: Error?
    var onBothCaptureEnd: (@MainActor () -> Void)?
    var clipAudio = false
    var visionTapActive: Bool?
    var micUnavailableForClips = false
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
    private var _shutDowns = 0
    private var _micDrops = 0
    private var _visionTapRequests: [Bool] = []
    private var _attemptBegins = 0
    private var _holdStills = false
    private var stillWaiters: [CheckedContinuation<Void, Never>] = []

    var warmUps: [WarmUp] { lock.withLock { _warmUps } }
    var multiCamWarmUps: Int { lock.withLock { _multiCamWarmUps } }
    var stills: [Bool] { lock.withLock { _stills } }
    var clips: [Bool] { lock.withLock { _clips } }
    var bothStills: Int { lock.withLock { _bothStills } }
    var bothClips: Int { lock.withLock { _bothClips } }
    var clipEnds: Int { lock.withLock { _clipEnds } }
    /// Item 65, finding 5: how many attempts announced themselves before touching the lens.
    var attemptBegins: Int { lock.withLock { _attemptBegins } }

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
    var visionTapRequests: [Bool] { lock.withLock { _visionTapRequests } }

    // MARK: EvidenceCamera

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

    func shutDown() { lock.withLock { _shutDowns += 1 } }
    func warmUpForAudioHandoff(camera: CameraChoice, deadline: Date) async throws -> Bool {
        if shutDownDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(shutDownDelay * 1_000_000_000)) }
        shutDown()
        guard Date() < deadline else { throw CameraController.CameraError.timedOut }
        return try await warmUp(forClips: true, camera: camera)
    }
    func dropMicAndWait() async { lock.withLock { _micDrops += 1 } }
    func isLowLight() async -> Bool { lowLight }
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
        return stillData
    }

    func beginClip(torch: Bool) { lock.withLock { _clips.append(torch) } }
    func endClip() async throws -> URL {
        lock.withLock { _clipEnds += 1 }
        if let clipEndError { throw clipEndError }
        return try Self.emptyClipFile()
    }

    func captureBothStills(rearHardwareFlash: Bool) async throws -> (front: Data?, rear: Data?) {
        lock.withLock { _bothStills += 1 }
        return (omittedBothCameras.contains("front") ? nil : stillData,
                omittedBothCameras.contains("rear") ? nil : stillData)
    }

    func beginBothClips(rearTorch: Bool) { lock.withLock { _bothClips += 1 } }
    func endBothClips() async throws -> (front: URL?, rear: URL?) {
        await onBothCaptureEnd?()
        func file(_ lens: String) throws -> URL? {
            guard !omittedBothCameras.contains(lens) else { return nil }
            if invalidBothClipFiles.contains(lens) {
                return FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            }
            return try Self.emptyClipFile()
        }
        return (try file("front"), try file("rear"))
    }

    func clipWasInterrupted() async -> Bool { clipInterrupted }
    func interruptionReason() async -> CaptureInterruptionReason? { interruptionReasonValue }
    func beginCaptureAttempt() { lock.withLock { _attemptBegins += 1 } }

    /// A zero-byte movie the store can move into place — the clip path's behavior is what a
    /// test observes, not the footage.
    private static func emptyClipFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data().write(to: url)
        return url
    }
}

// MARK: - Test isolation (item 84)

/// What one test leaves behind must not reach the next (item 84). Every test class that builds
/// an engine or a store calls `setUp(folderPrefix:)` and `tearDown()` (or, off the main actor,
/// `tearDownFolderAndFlags()`) from its own, and wraps each engine it builds in `track`: the
/// test gets a store folder of its own, its engines are disarmed afterwards, and the flags
/// engines keep in UserDefaults are cleared on both sides — every engine in the process shares
/// them, the test host's own included, and a flag left behind changes the next test's recovery.
enum TestIsolation {
    /// Every key an engine keeps about a session and its recovery, matched by prefix so a flag
    /// added later is covered without editing a list: the armed marker and boot stamp, the
    /// lapse-logged flag, the countdown marker, the owed re-arm and the crash-loop timestamp.
    nonisolated static let recoveryFlagPrefixes = ["com.malinois.armedSession.", "com.malinois.armed.",
                                                   "com.malinois.arming.", "com.malinois.recovery.",
                                                   "com.malinois.protection."]   // item 91's recorded settings

    @MainActor private static var engines: [MonitoringEngine] = []

    /// A fresh store folder for the test, and no flags left by the one before.
    nonisolated static func setUp(folderPrefix: String) {
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderPrefix + "-" + UUID().uuidString, isDirectory: true)
        clearRecoveryFlags()
    }

    /// The test's engines disarmed, then its flags cleared and its folder removed.
    @MainActor static func tearDown() {
        disarmTrackedEngines()
        tearDownFolderAndFlags()
    }

    /// The flags cleared and the folder removed — for a class that builds stores but no engines.
    nonisolated static func tearDownFolderAndFlags() {
        clearRecoveryFlags()
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
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
