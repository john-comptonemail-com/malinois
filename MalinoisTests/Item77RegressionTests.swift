//
//  Item77RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for the 1.3.2 batch (BACKLOG 77): each pins one of item 65's findings that
//  the 1.3 (36) respin left for later, as a behavior the engine must have. Written before the
//  fixes — red at that commit — and each fix turns its own test green. Driven through the
//  characterization harness (EngineHarness.swift): the real engine, the real store on a
//  throwaway root, the fake camera, and the Debug-only seams the engine already exposes for
//  tests, plus one new one — the connectivity monitor driven by hand, because the simulator's
//  network path never drops and the jamming canary's behavior around a loss is exactly what two
//  of these tests pin.
//

import XCTest
import Combine
@testable import Malinois

/// A calibrating tripwire that counts what the engine asks of it (item 65, finding 17): a
/// calibration that completes behind a re-calibration's back shows up here as an extra
/// `endCalibration` and an extra `start`.
@MainActor
final class FakeCalibratingMonitor: SensorMonitor {
    let type: SensorType
    var isEnabled = true
    var sensitivity: Sensitivity = .high
    var onTrip: ((SensorType) -> Void)?
    var requiresCalibration: Bool { true }
    private(set) var calibrating = false
    private(set) var beginCalibrations = 0
    private(set) var endCalibrations = 0
    private(set) var starts = 0
    private(set) var stops = 0

    init(type: SensorType) { self.type = type }

    func beginCalibration() { calibrating = true; beginCalibrations += 1 }
    func endCalibration() { calibrating = false; endCalibrations += 1 }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func rearm() {}
}

@MainActor
final class Item77RegressionTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
        let entitlements: ProEntitlements
    }

    // The persisted recovery keys, spelled out (the item 73 precedent): a renamed key on disk
    // is a behavior change these tests must catch, not absorb.
    private static let armedMarkerKey = "com.malinois.armedSession.brightness"
    private static let armedBootTimeKey = "com.malinois.armedSession.bootTime"
    private static let armedBootStampAtKey = "com.malinois.armedSession.bootStampAt"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let recoveryInProgressKey = "com.malinois.recovery.inProgress"
    private static let armingInProgressKey = "com.malinois.arming.inProgress"
    private static let backgroundLapseLoggedKey = "com.malinois.armed.backgroundLapseLogged"

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem77-" + UUID().uuidString, isDirectory: true)
        clearPersistedMarkers()
    }

    override func tearDown() {
        clearPersistedMarkers()
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        super.tearDown()
    }

    private func clearPersistedMarkers() {
        for key in [Self.armedMarkerKey, Self.armedBootTimeKey, Self.armedBootStampAtKey,
                    Self.pendingReArmKey, Self.recoveryInProgressKey, Self.armingInProgressKey,
                    Self.backgroundLapseLoggedKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeRig(timing: EngineTiming = EngineCharacterizationTests.fastTiming,
                         entitlements: ProEntitlements? = nil,
                         protectedDataAvailable: @escaping @MainActor () -> Bool = { true },
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let entitlements = entitlements ?? ProEntitlements(resolvedAs: .trial)
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                      camera: camera, entitlements: entitlements, timing: timing,
                                      protectedDataAvailable: protectedDataAvailable)
        return Rig(engine: engine, camera: camera, store: store, settings: settings, entitlements: entitlements)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Spins the main run loop for `seconds` — the wait a test needs when the thing it is
    /// checking is that nothing happens.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Arms through grace (0 s), calibration, and the calibration review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    /// Trips one sensor past the per-sensor flood bar. Every trip below the bar is its own
    /// trigger, so the engine re-arms between them; the trip past the bar is the flood ONSET —
    /// with `holdingTheOnset`, the camera holds that capture open until the test releases it.
    private func flood(_ rig: Rig, holdingTheOnset: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<MonitoringEngine.floodTripThreshold {
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3),
                          "each trip below the bar re-arms", file: file, line: line)
        }
        if holdingTheOnset { rig.camera.holdStills = true }
        rig.engine.handleTrip(.motion)
    }

    private func sustainedRecords(_ rig: Rig) -> [Event] {
        rig.store.events.filter { $0.sustainedCount != nil }
    }

    // MARK: - Finding 16: the record exists before the escalation

    /// SECURITY.md promises "evidence precedes response": the record is written before any
    /// alert or siren. The jamming canary used to siren first and write the interference record
    /// in a task afterwards — milliseconds, but the promise is the point.
    func testTheBlackoutRecordExistsBeforeTheEscalation() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.blackoutDebounce = 0.2
        let rig = makeRig(timing: timing) {
            $0.jammingResponse = true; $0.captureMode = .photo; $0.cameraPosition = .front
        }
        rig.engine.simulateConnectivityForTesting(online: true)   // a path at arm: the canary's baseline
        arm(rig)
        var recordsWhenEscalated: Int?
        let sub = rig.engine.$escalation.sink { reason in
            guard reason == .blackout, recordsWhenEscalated == nil else { return }
            MainActor.assumeIsolated {
                recordsWhenEscalated = rig.store.events
                    .filter { ($0.capturedOffline ?? false) && $0.triggeredSensors.isEmpty && !$0.isStateChange }.count
            }
        }
        rig.engine.simulateConnectivityForTesting(online: false)
        XCTAssertTrue(pump(until: { rig.engine.escalation == .blackout }, timeout: 3), "the debounced canary fires")
        XCTAssertEqual(recordsWhenEscalated, 1, "the interference record is in the log before the siren sounds")
        sub.cancel()
        rig.engine.disarm()
    }

    /// The same promise for a flood: the onset record comes first, then the visible warning.
    func testTheFloodOnsetRecordExistsBeforeTheEscalation() {
        let rig = makeRig { $0.jammingResponse = true; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        var onsetRecordsWhenEscalated: Int?
        let sub = rig.engine.$escalation.sink { reason in
            guard reason == .flood, onsetRecordsWhenEscalated == nil else { return }
            MainActor.assumeIsolated {
                onsetRecordsWhenEscalated = rig.store.events.filter { $0.sustainedCount != nil }.count
            }
        }
        flood(rig, holdingTheOnset: false)
        XCTAssertTrue(pump(until: { onsetRecordsWhenEscalated != nil }, timeout: 3), "the onset escalates")
        XCTAssertEqual(onsetRecordsWhenEscalated, 1, "the onset record is in the log before the flood warning shows")
        sub.cancel()
        pump(until: { rig.engine.state == .armed }, timeout: 3)
        rig.engine.disarm()
    }

    // MARK: - Finding 8: the jamming canary around a capture

    /// The blackout check used to be scheduled only on the online → offline transition and only
    /// while `.armed`. A path that died during a capture — the engine is `.triggered` then — was
    /// never re-examined when the engine re-armed: no pre-emptive siren, no interference record.
    func testABlackoutThatBeginsDuringACaptureIsStillCaught() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.blackoutDebounce = 0.2
        let rig = makeRig(timing: timing) {
            $0.jammingResponse = true; $0.captureMode = .photo; $0.cameraPosition = .front
        }
        rig.engine.simulateConnectivityForTesting(online: true)
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.touch)
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 3))
        rig.engine.simulateConnectivityForTesting(online: false)   // the path dies mid-capture
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertTrue(pump(until: { rig.engine.escalation == .blackout }, timeout: 2),
                      "a loss that began during the capture is treated as jamming once the watch is armed again")
        rig.engine.disarm()
    }

    /// The same gap during the calibration review: the sensors are live, the state is not yet
    /// `.armed`, and a loss then was never examined after the review ended.
    func testABlackoutThatBeginsDuringTheCalibrationReviewIsStillCaught() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.blackoutDebounce = 0.2
        timing.calibrationReview = 0.5
        let rig = makeRig(timing: timing) { $0.jammingResponse = true }
        rig.engine.simulateConnectivityForTesting(online: true)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.showingCalibrationReview }, timeout: 3), "the review card is up")
        rig.engine.simulateConnectivityForTesting(online: false)   // the path dies during the review
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertTrue(pump(until: { rig.engine.escalation == .blackout }, timeout: 2),
                      "a loss that began during the review is treated as jamming once covert")
        rig.engine.disarm()
    }

    /// Pure: the re-check on return to `.armed` owes the rest of the debounce — now if the loss
    /// has already lasted that long, never a negative or zero interval.
    func testTheBlackoutRecheckOwesTheRestOfTheDebounce() {
        XCTAssertEqual(MonitoringEngine.blackoutRecheckDelay(offlineFor: 10, debounce: 30), 20)
        XCTAssertEqual(MonitoringEngine.blackoutRecheckDelay(offlineFor: 30, debounce: 30), 0.05)
        XCTAssertEqual(MonitoringEngine.blackoutRecheckDelay(offlineFor: 45, debounce: 30), 0.05)
    }

    /// The guard that must survive the fix: a path that returns before the debounce elapses was
    /// an outage, not a jam — no escalation, whatever state the engine was in when it dropped.
    func testAPathThatReturnsBeforeTheDebounceIsNotABlackout() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.blackoutDebounce = 0.4
        let rig = makeRig(timing: timing) {
            $0.jammingResponse = true; $0.captureMode = .photo; $0.cameraPosition = .front
        }
        rig.engine.simulateConnectivityForTesting(online: true)
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.touch)
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 3))
        rig.engine.simulateConnectivityForTesting(online: false)
        settle(0.05)
        rig.engine.simulateConnectivityForTesting(online: true)    // back before the debounce
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        settle(0.6)
        XCTAssertNil(rig.engine.escalation, "a blip is not a blackout")
        rig.engine.disarm()
    }

    // MARK: - Finding 11: the flood anchor across sessions and clears

    /// A disarm during the flood's onset capture used to leave the coalescing anchor behind: the
    /// late capture wrote it after `disarm()` had cleared it, and the next watch never reset it,
    /// so the next watch's first flood extended a record from the previous session.
    func testADisarmDuringTheFloodOnsetLeavesNoAnchorForTheNextWatch() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front; $0.jammingResponse = false }
        arm(rig)
        flood(rig, holdingTheOnset: true)
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 3), "the onset capture is in flight")
        rig.engine.disarm()                                   // the owner grabs the phone mid-capture
        rig.camera.releaseStills()
        settle(0.3)                                           // the late capture finishes after the disarm
        XCTAssertEqual(sustainedRecords(rig).count, 1)
        arm(rig)
        flood(rig, holdingTheOnset: false)
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertEqual(sustainedRecords(rig).count, 2,
                       "the second watch's flood mints its own record instead of extending the first watch's")
        rig.engine.disarm()
    }

    /// The clear timer used to be scheduled at the onset, before the anchor existed. An onset
    /// capture longer than the idle-clear interval therefore installed an anchor with no timer,
    /// and a flood hours later coalesced into it. The anchor must expire once the flood is quiet.
    func testAFloodAnchorInstalledAfterTheClearTimerStillExpires() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sustainedIdleClear = 0.3
        let rig = makeRig(timing: timing) { $0.captureMode = .photo; $0.cameraPosition = .front; $0.jammingResponse = false }
        arm(rig)
        flood(rig, holdingTheOnset: true)
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 3))
        settle(0.5)                                           // the onset capture outlasts the clear interval
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertEqual(sustainedRecords(rig).count, 1)
        settle(0.6)                                           // quiet past the clear interval: the flood is over
        rig.engine.handleTrip(.motion)                        // still past the bar inside the flood window
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertEqual(sustainedRecords(rig).count, 2,
                       "a flood after the quiet period is a new record, not a continuation of a cleared one")
        rig.engine.disarm()
    }

    // MARK: - Finding 17: re-calibrating during the calibration

    /// Test Sensors: Recalibrate is reachable during the 3 s calibration, and the abandoned
    /// calibration's completion used to fire anyway — ending the NEW calibration early and
    /// starting the monitors in the middle of the new settle countdown.
    func testRecalibratingDuringTheCalibrationCancelsTheAbandonedCompletion() {
        let rig = makeRig()
        let motion = FakeCalibratingMonitor(type: .motion)
        rig.engine.replaceMonitorForTesting(motion)
        rig.engine.startDryRun()
        XCTAssertTrue(pump(until: { motion.calibrating }, timeout: 6), "the settle countdown ends in calibration")
        rig.engine.recalibrateDryRun()                         // during the calibration
        settle(0.5)                                           // the abandoned completion would fire in here
        XCTAssertEqual(motion.endCalibrations, 0, "the abandoned calibration must not complete behind the new countdown")
        XCTAssertEqual(motion.starts, 0, "nor start the monitors mid-settle")
        rig.engine.stopDryRun()
    }

    // MARK: - Finding 15: the vision caveat on the arming screen

    /// `visionTapUnavailable` was written only by the warm-up completions and never reset, so a
    /// session whose tap failed left "no vision on this device" on the next arming screen even
    /// when that arm skipped the pre-warm and could not know.
    func testTheVisionCaveatResetsAtTheNextArm() {
        let rig = makeRig {
            $0.enabledSensors = [.motion, .camera, .vision]
            $0.cameraReadiness = .instant
            $0.cameraPosition = .front
        }
        rig.camera.visionTapActive = false                   // attached, and stayed inactive
        arm(rig)
        XCTAssertTrue(pump(until: { rig.engine.visionTapUnavailable }, timeout: 3), "the pre-warm reports the dead tap")
        rig.engine.disarm()
        rig.settings.cameraReadiness = .batterySaver          // the next arm skips the pre-warm
        rig.camera.visionTapActive = true
        rig.engine.beginArming()
        XCTAssertFalse(rig.engine.visionTapUnavailable, "last session's caveat must not show on this arming screen")
        rig.engine.cancelArming()
    }

    // MARK: - Finding 10: a cold push launch and the entitlement check

    /// A push that cold-launches the app arrives while the entitlement check is still running;
    /// deciding "free tier, nothing to pull" on the unresolved default skipped the fetch, and the
    /// mirrored record landed only when the owner next opened the app.
    func testAColdPushLaunchWaitsForTheEntitlementBeforeDecidingToFetch() async {
        var timing = EngineCharacterizationTests.fastTiming
        timing.pushResolveWait = 1.0
        let entitlements = ProEntitlements.unresolvedForTesting()
        let rig = makeRig(timing: timing, entitlements: entitlements)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            entitlements.resolveForTesting(as: .earlyAccess)
        }
        _ = await rig.engine.handleRemotePush()
        XCTAssertTrue(rig.entitlements.hasResolved, "the push handler must not decide on an unresolved entitlement")
    }

    /// The wait is bounded: an entitlement that never resolves must not hold the push handler
    /// past iOS's patience.
    func testAColdPushLaunchGivesUpWaitingAfterTheBound() async {
        var timing = EngineCharacterizationTests.fastTiming
        timing.pushResolveWait = 0.3
        let rig = makeRig(timing: timing, entitlements: ProEntitlements.unresolvedForTesting())
        let started = Date()
        let result = await rig.engine.handleRemotePush()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "waited for the bound")
        XCTAssertEqual(result, .noData, "still unresolved after the bound: nothing to pull")
    }

    // MARK: - Finding 9: the vision tap's bookkeeping across the two camera sessions

    /// The tap moves between the single-camera and multi-cam sessions. The session that loses
    /// it must stop claiming it was configured with it — otherwise the next warm-up reused
    /// that session unchanged, tapless, while the flag said the tripwire was live. Pure rule;
    /// device leg 4 (Both + Vision, a cadence still, then movement) is the proof on hardware.
    func testTheSessionThatLosesTheVisionTapStopsClaimingIt() {
        let fromMultiCam = CameraController.configuredVisionAfterRelease(fromMultiCam: true, single: true, multiCam: true)
        XCTAssertEqual(fromMultiCam.multiCam, false, "the multi-cam session lost the tap")
        XCTAssertEqual(fromMultiCam.single, true, "the single session's answer is untouched")
        let fromSingle = CameraController.configuredVisionAfterRelease(fromMultiCam: false, single: true, multiCam: true)
        XCTAssertEqual(fromSingle.single, false, "the single session lost the tap")
        XCTAssertEqual(fromSingle.multiCam, true, "the multi-cam session's answer is untouched")
    }

    // MARK: - Finding 12: a clip whose session stop beat the pipeline's stop

    /// A disarm shuts the camera down ahead of the pipeline's `endClip`. The output then reads
    /// "not recording" with the delegate's finalize still on the way; failing at once lost the
    /// usable partial clip. The stop must wait for the callback — bounded, and shorter than
    /// the stop timeout — and fail at once only when no callback is expected at all. Pure
    /// rule; device leg 3 (a disarm during a clip) is the proof on hardware.
    func testAStopWaitsForAPendingFinalizeInsteadOfFailingTheClip() {
        XCTAssertEqual(CameraController.recordingStopWait(isRecording: true, callbackPending: true,
                                                          stopTimeout: 8, pendingFinalizeWait: 2), 8,
                       "still recording: the ordinary stop and its timeout")
        XCTAssertEqual(CameraController.recordingStopWait(isRecording: false, callbackPending: true,
                                                          stopTimeout: 8, pendingFinalizeWait: 2), 2,
                       "stopped from under us, callback pending: wait for the file")
        XCTAssertNil(CameraController.recordingStopWait(isRecording: false, callbackPending: false,
                                                        stopTimeout: 8, pendingFinalizeWait: 2),
                     "nothing recording and nothing expected: fail now")
        XCTAssertLessThan(CameraController.pendingFinalizeWait, 8, "the finalize wait is short by design")
    }

    // MARK: - Finding 13: a sealed Keychain never mints a trial

    /// On a locked device the Keychain answers "not now" for the trial start, which the old
    /// read collapsed to "absent": after a reinstall (no UserDefaults mirror yet) a locked
    /// background launch minted a start of now — a fresh trial for one launch, and a sweep of
    /// a lapsed user's local-only evidence into iCloud on its strength. The decision is pure:
    /// found is the answer; missing is the first launch, minted unless the mirror has it;
    /// sealed is unknown — the mirror or nothing, never a mint.
    func testASealedTrialStartIsNeverMintedFrom() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let found = KeychainService.ItemRead.found(Data("\(date.timeIntervalSince1970)".utf8))
        let readable = ProEntitlements.trialStartDecision(keychain: found, mirror: nil)
        XCTAssertEqual(readable.start, date)
        XCTAssertFalse(readable.mint)
        let first = ProEntitlements.trialStartDecision(keychain: .missing, mirror: nil)
        XCTAssertNil(first.start)
        XCTAssertTrue(first.mint, "the first launch records the install date")
        let mirrored = ProEntitlements.trialStartDecision(keychain: .missing, mirror: date)
        XCTAssertEqual(mirrored.start, date)
        XCTAssertFalse(mirrored.mint, "the mirror still holds it: nothing to mint")
        let sealedWithMirror = ProEntitlements.trialStartDecision(keychain: .sealed, mirror: date)
        XCTAssertEqual(sealedWithMirror.start, date)
        XCTAssertFalse(sealedWithMirror.mint)
        let sealedAlone = ProEntitlements.trialStartDecision(keychain: .sealed, mirror: nil)
        XCTAssertNil(sealedAlone.start)
        XCTAssertFalse(sealedAlone.mint, "locked and no mirror: unknown, never a fresh trial")
    }

    // MARK: - Finding 18: the interruption record on a locked launch

    /// A push can launch the app in the background while the device is locked. The recovery
    /// consumed the armed marker and logged the interruption into a store that cannot persist
    /// until the unlock — so if iOS ended the process first, the record was gone for good (the
    /// owed re-arm survived; the evidence of the interruption did not). The recovery must wait
    /// for the unlock, marker untouched, then run once.
    func testALockedLaunchKeepsTheMarkerUntilTheDeviceUnlocksThenRecovers() {
        UserDefaults.standard.set(0.5, forKey: Self.armedMarkerKey)   // an armed session the process died out of
        var unlocked = false
        let rig = makeRig(protectedDataAvailable: { unlocked })
        XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey),
                        "locked: the marker stays until the record can be persisted")
        XCTAssertFalse(rig.store.events.contains { $0.interrupted ?? false },
                       "no record yet — written now, it would die with the process")
        unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { rig.store.events.contains { $0.interrupted ?? false } }, timeout: 3),
                      "the unlock runs the deferred recovery")
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey), "which consumes the marker")
        rig.engine.disarm()   // the recovery re-arm, if it started
    }

    // MARK: - Item 74, line 6: a swipe-away during the countdown

    /// The countdown never went live, and a swipe-away used to leave two records: the lapse,
    /// worded "while armed", at background time, and "Arming did not complete" at the relaunch.
    /// One record, and it says when: during the countdown.
    func testABackgroundDuringTheCountdownIsRecordedOnceAndSaysSo() {
        let rig = makeRig { $0.gracePeriodSeconds = 5 }
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming, "the countdown is running")
        rig.engine.handleEnteredBackground()   // the swipe-away's first effect, before the kill
        let lapse = rig.store.events.first { $0.interrupted ?? false }
        XCTAssertEqual(lapse?.interruptionCause, "backgroundedDuringCountdown", "the record says when")
        XCTAssertTrue(lapse?.sensorSummary.contains("during the countdown") ?? false, "in words, too")
        // The relaunch: a fresh engine over the same store and defaults finds the countdown's
        // marker. It used to add "Arming did not complete" on top of the lapse.
        let relaunched = MonitoringEngine(settings: rig.settings, eventStore: rig.store, cloud: CloudExfiltrator(),
                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                          timing: EngineCharacterizationTests.fastTiming)
        XCTAssertEqual(relaunched.state, .disarmed)
        let countdownRecords = rig.store.events.filter { ($0.interrupted ?? false) || $0.stateChange == "armingInterrupted" }
        XCTAssertEqual(countdownRecords.count, 1, "one interruption, one record")
        rig.engine.cancelArming()
    }

    /// Pure: the countdown names its own lapse, ahead of the Guided Access lock naming — the
    /// watch was not live, whatever backgrounded it.
    func testTheCountdownNamesItsOwnLapse() {
        XCTAssertEqual(MonitoringEngine.backgroundInterruptionCause(guidedAccessOn: false, duringCountdown: true),
                       .backgroundedDuringCountdown)
        XCTAssertEqual(MonitoringEngine.backgroundInterruptionCause(guidedAccessOn: true, duringCountdown: true),
                       .backgroundedDuringCountdown)
        XCTAssertEqual(MonitoringEngine.backgroundInterruptionCause(guidedAccessOn: true, duringCountdown: false), .locked)
        XCTAssertEqual(MonitoringEngine.backgroundInterruptionCause(guidedAccessOn: false, duringCountdown: false), .backgrounded)
    }

    // MARK: - Finding 3, the attribution half: a failed re-push must not be final

    /// A correct PIN attributes the pad's captures to the owner and re-pushes their meta so the
    /// cloud copy says so too. The re-push used to be fire-and-forget: a record already `.synced`
    /// stayed `.synced` when it failed, and the sweep never retried it. Here the push fails by
    /// construction (no iCloud on the simulator), so the record must reopen for the sweep.
    func testAFailedAttributionRePushReopensTheRecordForTheSweep() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.disarmEntryTimeout = 3
        let rig = makeRig(timing: timing) { $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.noteDisarmCandidate()   // press-down opens the attribution window …
        rig.engine.reportTouch()           // … and the same press-down is a touch trip
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed
                && rig.store.events.contains { $0.triggeredSensors == [.touch] && $0.mediaFilename != nil }
        }, timeout: 3))
        let id = rig.store.events.first { $0.triggeredSensors == [.touch] }!.id
        rig.store.setSyncState(.synced, for: id)   // as if the upload had landed
        rig.engine.beginDisarmEntry()
        rig.engine.disarm()
        XCTAssertEqual(rig.store.events.first { $0.id == id }?.ownerAttributed, true)
        XCTAssertTrue(pump(until: { rig.store.events.first { $0.id == id }?.cloudSyncState == .pending }, timeout: 3),
                      "a failed attribution re-push reopens the record so the sweep carries the attribution up")
    }
}
