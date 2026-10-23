//
//  Item152TwoGuardsTests.swift
//  MalinoisTests
//
//  BACKLOG 152's leads 6 and 18, item 145 step 15: two small guards. The siren waited without limit for the camera to
//  release the microphone (a continuation on the camera's session queue, which the app treats as able to block), so a
//  stalled queue left the alarm silent for the rest of the watch; now it waits at most about 1.5 s, then sounds, and
//  a release that lands late makes the alarm sound again if the session's deactivation silenced it (the test host
//  plays nothing, so the tests count the requests to sound, not AVAudioPlayer's state). The automatic
//  re-arm after a crash never checked for a usable PIN, so a backup restored onto another iPhone (its markers come
//  along, its PIN does not) could start a watch behind the PIN-recovery screen that nobody could stop; now no re-arm
//  runs while a PIN recovery is pending, and the owed re-arm runs once the recovery finishes. Written before the
//  change, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

@MainActor
final class Item152TwoGuardsTests: XCTestCase {

    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let lastAttemptKey = "com.malinois.recovery.lastAt"
    private static let setupCompletedKey = "com.malinois.setupCompleted"

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152Guards")
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRig(timing: EngineTiming = EngineCharacterizationTests.fastTiming,
                         entitlements: ProEntitlements = ProEntitlements(resolvedAs: .trial),
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera, entitlements: entitlements, timing: timing))
        return Rig(engine: engine, camera: camera, store: store)
    }

    /// Arms through grace (0 s), calibration and the review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "should reach .armed", file: file, line: line)
    }

    /// A re-arm owed from a watch that ended without a disarm, well clear of the crash-loop guard.
    private func owe() {
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970 - 600, forKey: Self.lastAttemptKey)
    }

    /// A launch with the re-arm owed: the recovery runs once the Pro check has resolved, as on the phone (item 141's rig).
    private func launch() -> Rig {
        let entitlements = ProEntitlements.unresolvedForTesting()
        let rig = makeRig(entitlements: entitlements) { $0.gracePeriodSeconds = 60 }
        entitlements.resolveForTesting(as: .trial)
        return rig
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - The siren's wait (lead 6)

    /// A camera queue that never answers still lets the siren sound, after the bound; the release landing late leaves
    /// the alarm sounding.
    func testASirenSoundsWhileTheCameraQueueIsHeld() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sirenMicReleaseWait = 0.3
        timing.alertDuration = 5   // the fast clock's 0.3 s alert would end before the wait does, and a siren is never started for an alert that is over
        let rig = makeRig(timing: timing) {
            $0.responseMode = .siren; $0.captureMode = .clip3; $0.cameraPosition = .front; $0.sirenRampUp = false
        }
        rig.camera.holdMicDrop = true   // the session queue does not answer
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 3), "the alert starts")
        XCTAssertTrue(pump(until: { rig.engine.siren.soundRequestsForTesting >= 1 }, timeout: 3),
                      "the siren is sounded although the camera never released the microphone")
        XCTAssertEqual(rig.camera.micDrops, 1, "the release was asked for, once")
        rig.engine.siren.silenceForTesting()   // what the session's deactivation does to a running alarm
        rig.camera.releaseMicDrop()            // the late release lands
        XCTAssertTrue(pump(until: { rig.engine.siren.soundRequestsForTesting >= 2 }, timeout: 3),
                      "sounded again after the late release silenced it")
        rig.engine.disarm()
    }

    /// A camera that answers in time: the siren waits for the release, as before, and sounds once it has landed.
    func testASirenStillWaitsForAReleaseThatComesInTime() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sirenMicReleaseWait = 2
        timing.alertDuration = 5   // as above: the alert must still be up when the release lands
        let rig = makeRig(timing: timing) {
            $0.responseMode = .siren; $0.captureMode = .clip3; $0.cameraPosition = .front; $0.sirenRampUp = false
        }
        rig.camera.holdMicDrop = true
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 3), "the alert starts")
        settle(0.3)
        XCTAssertEqual(rig.engine.siren.soundRequestsForTesting, 0, "waiting for the release: it would kill a just-started alarm")
        rig.camera.releaseMicDrop()
        XCTAssertTrue(pump(until: { rig.engine.siren.soundRequestsForTesting >= 1 }, timeout: 2), "sounded once released")
        XCTAssertEqual(rig.engine.siren.soundRequestsForTesting, 1, "once: the release came in time, no restart")
        rig.engine.disarm()
    }

    /// The production bound: about a second and a half.
    func testTheBoundIsAboutASecondAndAHalf() {
        XCTAssertEqual(EngineTiming.production.sirenMicReleaseWait, 1.5)
    }

    // MARK: - No re-arm behind the PIN recovery (lead 18)

    /// An owed re-arm with a PIN recovery pending (setup completed before, no usable PIN now: a backup restored onto
    /// another iPhone) stays owed: no countdown starts behind the recovery screen, and Home is not told of a skip. Once
    /// the recovery finishes with a usable PIN, the owed re-arm runs.
    func testNoReArmWhileAPINRecoveryIsPending() throws {
        MonitoringEngine.recoveryPendingForTesting = nil   // the Keychain's own answer, not the isolation's "none"
        try XCTSkipUnless(KeychainService.pinPresence == .absent, "Keychain unavailable")
        UserDefaults.standard.set(true, forKey: Self.setupCompletedKey)
        XCTAssertEqual(KeychainService.pendingRecovery, .lostHash, "the restored phone's state")
        owe()
        let rig = launch()
        settle(1.0)
        XCTAssertEqual(rig.engine.state, .disarmed, "no watch behind the PIN-recovery screen")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.pendingReArmKey), "still owed")
        XCTAssertFalse(rig.engine.reArmSkipped, "deferred, not skipped")
        XCTAssertTrue(KeychainService.setPIN("4821"), "the recovery: a new PIN after device authentication")
        XCTAssertNil(KeychainService.pendingRecovery)
        rig.engine.noteRecoveryFinished(.lostHash)
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3), "the owed re-arm runs once a PIN exists")
        rig.engine.disarm()
    }

    /// With no recovery pending, the owed re-arm runs as before.
    func testTheReArmRunsWhenNoRecoveryIsPending() throws {
        MonitoringEngine.recoveryPendingForTesting = nil   // the Keychain's own answer
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        UserDefaults.standard.set(true, forKey: Self.setupCompletedKey)
        XCTAssertNil(KeychainService.pendingRecovery)
        owe()
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3), "the owed re-arm starts its countdown")
        rig.engine.disarm()
    }

    // MARK: - Item 155's A5 (step 22): no automatic re-arm while PIN storage is unreadable

    /// Codex's P6. The re-arm is owed and setup is complete, but the Keychain answers "not now" (sealed): nothing is
    /// known about the PIN, so the watch waits and the re-arm stays owed; once the Keychain answers, the missing PIN
    /// is the recovery it was. Red at the step's red commit: an unreadable Keychain read as "no recovery pending",
    /// and the watch started behind the recovery screen with the owed marker consumed.
    func testAnUnreadablePINStorageDefersTheRecoveryReArm() throws {
        MonitoringEngine.recoveryPendingForTesting = nil   // the real answer, not the isolation's
        XCTAssertEqual(KeychainService.pinPresence, .absent, "the isolation wiped the PIN")
        UserDefaults.standard.set(true, forKey: Self.setupCompletedKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.setupCompletedKey) }
        KeychainService.readStatusForTesting = -25308   // errSecInteractionNotAllowed: sealed
        defer { KeychainService.readStatusForTesting = nil }
        XCTAssertEqual(KeychainService.pinPresence, .sealedByLock)
        owe()
        let rig = launch()
        rig.engine.handleScenePhase(true)
        settle(0.5)
        XCTAssertEqual(rig.engine.state, .disarmed, "no watch while the PIN cannot be read")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.pendingReArmKey), "the re-arm stays owed")
        KeychainService.readStatusForTesting = nil
        XCTAssertEqual(KeychainService.pendingRecovery, .lostHash, "readable again: the recovery it was")
        rig.engine.disarm()
    }
}
