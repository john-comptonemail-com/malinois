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

import AVFoundation
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

    /// Item 162's A1 (1.8.2's step 8): a ramping siren that the late release silenced inside its quiet start comes back
    /// where the ramp was, quiet, not at full volume: the owner's quiet window is not cut short (nor started again, which
    /// would lengthen it). Red at the step's red commit: it came back at full volume.
    func testALateReleaseRestartsARampingSirenWhereTheRampWas() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sirenMicReleaseWait = 0.3
        timing.alertDuration = 5   // as above
        let rig = makeRig(timing: timing) {
            $0.responseMode = .siren; $0.captureMode = .clip3; $0.cameraPosition = .front; $0.sirenRampUp = true
        }
        rig.camera.holdMicDrop = true
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.siren.soundRequestsForTesting >= 1 }, timeout: 3), "the siren is sounded")
        XCTAssertEqual(rig.engine.siren.startLevelForTesting, SirenPlayer.rampStartVolume, "a ramped start, quiet")
        rig.engine.siren.silenceForTesting()
        rig.camera.releaseMicDrop()
        XCTAssertTrue(pump(until: { rig.engine.siren.soundRequestsForTesting >= 2 }, timeout: 3), "sounded again")
        XCTAssertEqual(rig.engine.siren.startLevelForTesting, SirenPlayer.rampStartVolume,
                       "back inside the quiet start, at its quiet level")
        rig.engine.disarm()
    }

    /// The same restart further on, in the rise (15 s after a ramped start, the rise half done): it comes back at the
    /// level the rise had reached.
    func testARestartInTheRiseComesBackAtTheRisesLevel() {
        let siren = SirenPlayer()
        var now: TimeInterval = 1_000
        siren.uptimeForTesting = { now }
        siren.start(rampUp: true)
        defer { siren.stop() }
        now += SirenPlayer.rampHoldSeconds + SirenPlayer.rampFadeSeconds / 2
        siren.silenceForTesting()
        siren.ensureSounding()
        let halfway = SirenPlayer.rampStartVolume + (1 - SirenPlayer.rampStartVolume) / 2
        XCTAssertEqual(siren.startLevelForTesting ?? -1, halfway, accuracy: 0.001)
    }

    /// Past the ramp, or after an escalation sent it loud, or with no ramp at all, a restart is at full volume, as
    /// before.
    func testARestartAfterTheRampOrAnEscalationIsAtFullVolume() {
        let siren = SirenPlayer()
        var now: TimeInterval = 1_000
        siren.uptimeForTesting = { now }
        siren.start(rampUp: true)
        defer { siren.stop() }
        now += SirenPlayer.rampHoldSeconds + SirenPlayer.rampFadeSeconds + 1
        siren.silenceForTesting()
        siren.ensureSounding()
        XCTAssertEqual(siren.startLevelForTesting, 1, "past the ramp")
        siren.stop()
        siren.start(rampUp: true)
        siren.goFullVolume()
        siren.silenceForTesting()
        siren.ensureSounding()
        XCTAssertEqual(siren.startLevelForTesting, 1, "an escalation ended the ramp")
        siren.stop()
        siren.start(rampUp: false)
        siren.silenceForTesting()
        siren.ensureSounding()
        XCTAssertEqual(siren.startLevelForTesting, 1, "no ramp")
    }

    /// The ramp's level: quiet through the hold, then rising evenly to full over the fade; a restart past the ramp, or
    /// with none, has no ramp to continue.
    func testTheRampsLevelRisesEvenlyAfterTheQuietHold() {
        let hold = SirenPlayer.rampHoldSeconds, fade = SirenPlayer.rampFadeSeconds
        XCTAssertEqual(SirenPlayer.rampLevel(afterSeconds: 0), SirenPlayer.rampStartVolume)
        XCTAssertEqual(SirenPlayer.rampLevel(afterSeconds: hold), SirenPlayer.rampStartVolume)
        XCTAssertEqual(SirenPlayer.rampLevel(afterSeconds: hold + fade / 2), 0.575, accuracy: 0.001)
        XCTAssertEqual(SirenPlayer.rampLevel(afterSeconds: hold + fade), 1)
        XCTAssertEqual(SirenPlayer.rampLevel(afterSeconds: 100), 1)
        XCTAssertEqual(SirenPlayer.rampElapsed(anchor: 1_000, now: 1_005), 5)
        XCTAssertNil(SirenPlayer.rampElapsed(anchor: 1_000, now: 1_000 + hold + fade), "the ramp is over")
        XCTAssertNil(SirenPlayer.rampElapsed(anchor: nil, now: 1_005), "no ramp")
        XCTAssertEqual(SirenPlayer.rampElapsed(anchor: 1_000, now: 990), 0, "a clock read before the anchor is the start")
    }

    // MARK: - Hardening (c) (1.8.2's step 10): Alert with Until clear warns while the clip records

    /// In Alert mode an Until clear clip ran up to 2 minutes before the first warning, and the tampering itself kept it
    /// recording. The warning now shows once the clip has recorded as long as the default 3-second clip, and the clip goes
    /// on recording. Red at the step's red commit: no warning until the clip ended.
    func testAlertWithUntilClearWarnsWhileTheClipStillRecords() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.untilClearIdle = 1.5
        timing.untilClearWarningAfter = 0.3
        timing.alertDuration = 5
        let rig = makeRig(timing: timing) { $0.responseMode = .alert; $0.captureMode = .untilClear; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 1.2), "the warning shows while the clip records")
        XCTAssertEqual(rig.camera.clipEnds, 0, "and the clip is still recording")
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 5), "the clip ends when quiet")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertTrue(rig.engine.alertActive, "the response's own decision extends the warning, which stays")
        rig.engine.disarm()
    }

    /// Stealth shows no warning, early or late: the early warning follows the response mode.
    func testStealthWithUntilClearStillShowsNoWarning() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.untilClearIdle = 1.0
        timing.untilClearWarningAfter = 0.3
        let rig = makeRig(timing: timing) { $0.responseMode = .stealth; $0.captureMode = .untilClear; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 5), "the clip records and ends")
        XCTAssertFalse(rig.engine.alertActive)
        rig.engine.disarm()
    }

    // MARK: - codex-1 on step 10: a lit clip's white screen covered the warning

    private func litUntilClearRig(_ mode: ResponseMode, camera position: CameraChoice,
                                  warningAfter: TimeInterval = 0.3, padQuietFor: TimeInterval? = nil) -> Rig {
        var timing = EngineCharacterizationTests.fastTiming
        timing.untilClearIdle = 1.5
        timing.untilClearWarningAfter = warningAfter
        timing.alertDuration = 5
        if let padQuietFor {   // the pad stays open, and its quiet window lasts, past the test's check (item 167's A1)
            timing.disarmActivityGrace = padQuietFor
            timing.disarmEntryTimeout = padQuietFor * 2
        }
        let rig = makeRig(timing: timing) {
            $0.responseMode = mode; $0.captureMode = .untilClear; $0.cameraPosition = position; $0.illumination = .on
        }
        rig.camera.supportsMultiCam = position == .both
        return rig
    }

    /// The armed screen draws a lit clip's white screen over the warning, so the early warning ended nothing and
    /// nobody saw it (front camera, or Both, with the light on). The warning now ends the light, and the clip goes on
    /// recording. Red at the codex-1 red commit: the light stayed on over the warning. Both's clips end through
    /// `endBothClips`, counted apart; the count reaching 1 later shows it was live when it read 0 (Codex's note).
    func testTheEarlyWarningEndsTheCaptureLightSoItCanBeSeen() {
        for position in [CameraChoice.front, .both] {
            let rig = litUntilClearRig(.alert, camera: position)
            let clipEnds = { position == .both ? rig.camera.bothClipEnds : rig.camera.clipEnds }
            arm(rig)
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { rig.engine.captureFlash }, timeout: 3), "\(position): the clip is lit")
            XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 1.5), "\(position): the warning shows")
            XCTAssertFalse(rig.engine.captureFlash, "\(position): and the light that would cover it is off")
            XCTAssertEqual(clipEnds(), 0, "\(position): while the clip still records")
            XCTAssertTrue(pump(until: { clipEnds() == 1 }, timeout: 6), "\(position): the clip ends later, once")
            XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 6))
            rig.engine.disarm()
        }
    }

    /// The same for an escalation's warning during a lit clip (a sensor flood): it ended no light either.
    func testAnEscalationsWarningEndsTheCaptureLight() {
        let rig = litUntilClearRig(.alert, camera: .front, warningAfter: 60)
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.captureFlash }, timeout: 3), "the clip is lit")
        rig.engine.escalate(.flood)
        XCTAssertTrue(rig.engine.alertActive)
        XCTAssertFalse(rig.engine.captureFlash, "the flood's warning can be seen")
        rig.engine.disarm()
    }

    /// Controls: Stealth shows no warning, so its clip keeps its light; with the disarm pad up and in use no warning
    /// starts. The pad's quiet window outlasts the check: with the compressed timing's 0.5 s the pad had closed before
    /// it, and the check passed only because a warning the pad held back was dropped (item 167's A1).
    func testStealthKeepsItsLightAndThePadHoldsTheWarningBack() {
        let stealth = litUntilClearRig(.stealth, camera: .front)
        arm(stealth)
        stealth.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { stealth.engine.captureFlash }, timeout: 3), "the clip is lit")
        pump(until: { false }, timeout: 0.6)
        XCTAssertTrue(stealth.engine.captureFlash, "Stealth keeps the light: no warning to show")
        XCTAssertFalse(stealth.engine.alertActive)
        stealth.engine.disarm()
        let padUp = litUntilClearRig(.alert, camera: .front, padQuietFor: 3)
        arm(padUp)
        padUp.engine.beginDisarmEntry()
        padUp.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { padUp.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        pump(until: { false }, timeout: 0.6)
        XCTAssertFalse(padUp.engine.alertActive, "no warning over the owner's typing")
        padUp.engine.disarm()
    }

    /// The production setting: the default clip's 3 seconds.
    func testAnUntilClearWarningComesAfterTheDefaultClipsLength() {
        XCTAssertEqual(EngineTiming.production.untilClearWarningAfter, CaptureMode.clip3.fixedDuration)
    }

    // MARK: - codex-4 on step 8: a waiting retry against a newer request

    /// A restart's activation retry carried the ramp it was continuing. An escalation that came while that retry waited,
    /// its own start failing too, could lose to it: the older retry started the siren at the ramp's quiet level, and the
    /// escalation's retry, finding it playing, gave up. Each retry now acts only for the request that made it. Red at
    /// the codex-4 red commit: the siren came back at the ramp's 0.15.
    func testAnEscalationIsNotLostToAnOlderRestartsRetry() {
        let siren = SirenPlayer()
        var now: TimeInterval = 1_000
        siren.uptimeForTesting = { now }
        siren.start(rampUp: true)
        defer { siren.stop() }
        now += 2
        siren.silenceForTesting()
        siren.activationFailuresForTesting = 2   // the ramp's restart and the escalation each fail once
        siren.ensureSounding()
        siren.goFullVolume()
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "sounding again after the retries")
        settle(0.6)   // any later retry has had its turn
        XCTAssertEqual(siren.startLevelForTesting, 1, "the escalation's full volume")
    }

    /// An interruption's end brings the siren back at full volume, never re-granting the ramp's quiet window, and a
    /// restart after it (the alert window's extension) must not take up the old ramp, even when the interruption's own
    /// restart failed. Red at the codex-4 red commit: the extension resumed the ramp's quiet level.
    func testAnInterruptionsFullVolumeIsNotUndoneByALaterRestart() {
        let siren = SirenPlayer()
        var now: TimeInterval = 1_000
        siren.uptimeForTesting = { now }
        siren.start(rampUp: true)
        defer { siren.stop() }
        now += 2
        siren.silenceForTesting()
        siren.activationFailuresForTesting = 1   // the interruption's restart fails its first attempt
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        settle(0.1)   // the observer's hop to the main actor
        siren.ensureSounding()
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3))
        settle(0.6)
        XCTAssertEqual(siren.startLevelForTesting, 1, "full volume after the interruption")
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
