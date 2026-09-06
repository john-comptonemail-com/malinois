//
//  EngineCharacterizationTests.swift
//  MalinoisTests
//
//  Characterization of the engine's stateful paths (1.3 consolidation, step 3), driven end
//  to end against the real store and the fake camera, so the refactors that follow — the
//  capture-pipeline seam, the disarm-entry seam, Swift 6 — have a net. Each test states what
//  the engine does TODAY; a failure here after a refactor means behavior changed, not that
//  the test was wrong. Real timers run against a compressed `EngineTiming` (the timing seam),
//  so a full cycle takes well under a second; every test owns a throwaway store directory
//  (the isolation seam), so nothing leaks between tests or into the simulator's real log.
//

import XCTest
@testable import Malinois

@MainActor
final class EngineCharacterizationTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
    }

    /// Production values compressed ~10–100×: long enough for the run loop to observe each
    /// phase, short enough that the whole file runs in seconds.
    static let fastTiming: EngineTiming = {
        var t = EngineTiming.production
        t.calibrationDuration = 0.2
        t.calibrationReview = 0.1
        t.correlationWindow = 0.2
        t.refractorySweepInterval = 0.05
        t.autoExposureSettle = 0.02
        t.reconfigureSettle = 0.02
        t.flashSettle = 0.01
        t.cameraStandbyDelay = 0.1
        t.sustainedIdleClear = 0.5
        t.floodCaptureInterval = 0.3
        t.untilClearIdle = 0.3
        t.untilClearMax = 3
        t.untilClearPoll = 0.05
        t.disarmEntryTimeout = 0.5
        t.disarmEntryCeiling = 2
        t.disarmCandidateWindow = 1
        t.disarmActivityGrace = 0.5
        t.alertDuration = 0.3
        return t
    }()

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisCharacterization-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        super.tearDown()
    }

    private func makeRig(timing: EngineTiming = EngineCharacterizationTests.fastTiming,
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                      camera: camera,
                                      entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: timing)
        return Rig(engine: engine, camera: camera, store: store, settings: settings)
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

    /// Arms through grace (0 s), calibration, and the calibration review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    // MARK: - The trigger response

    /// The seam's first proof: a trip on an armed engine warms the CONFIGURED camera, takes
    /// one still in photo mode, attaches it to the event it minted, and re-arms.
    func testATripWarmsTheConfiguredCameraAndAttachesItsStill() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        let known = Set(rig.store.events.map(\.id))
        arm(rig)

        rig.engine.handleTrip(.motion)

        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed
                && rig.store.events.contains { !known.contains($0.id) && $0.mediaFilename != nil }
        }, timeout: 5), "the trigger response should capture, attach the still, and re-arm")
        guard let event = rig.store.events.first(where: { !known.contains($0.id) && !$0.isStateChange }) else {
            return XCTFail("no event was minted for the trip")
        }
        XCTAssertEqual(event.triggeredSensors, [.motion])
        XCTAssertEqual(event.primaryCamera, "front")
        XCTAssertNotNil(event.mediaFilename)
        XCTAssertEqual(rig.camera.warmUps.last?.camera, .front, "the configured camera is what gets warmed")
        XCTAssertEqual(rig.camera.stills.count, 1, "one still for one trip in photo mode")
        XCTAssertTrue(rig.camera.clips.isEmpty, "photo mode never starts a clip")
        rig.engine.disarm()
    }

    // MARK: - Arming

    /// Grace (0 s) → calibration → the review card → covert, armed. `lastCalibration` is the
    /// review's payload, so its presence pins that calibration actually ran; arming and
    /// disarming each write their audit record.
    func testArmingPassesThroughGraceCalibrationAndReviewToArmed() {
        let rig = makeRig()
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming, "the grace countdown is the first stop")
        XCTAssertTrue(pump(until: { rig.engine.state == .calibrating }, timeout: 3),
                      "grace 0 hands straight to calibration")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        XCTAssertNotNil(rig.engine.lastCalibration, "the review card had a calibration to show")
        XCTAssertTrue(rig.store.events.contains { $0.stateChange == "armed" }, "arming writes its audit record")
        rig.engine.disarm()
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertTrue(rig.store.events.contains { $0.stateChange == "disarmed" }, "so does disarming")
    }

    /// First-arm Guided Access auto-lift (BACKLOG 68): with the requirement on and Guided Access
    /// off (the simulator has none), a fresh install's first arm is not blocked — it auto-lifts,
    /// logs the gaLifted record like a manual lift, and going live spends it, so the next arm
    /// blocks again.
    func testTheFirstArmAutoLiftsGuidedAccessAndTheNextArmRequiresIt() {
        let key = "com.malinois.onboarding.hasArmedOnce"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)   // a fresh install
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let rig = makeRig { $0.requireGuidedAccess = true }
        rig.engine.beginArming()
        XCTAssertTrue(rig.engine.guidedAccessLiftedThisArm, "the first arm auto-lifts the requirement")
        XCTAssertFalse(rig.engine.armingBlockedByGuidedAccess, "so the countdown is available with no tap")
        XCTAssertTrue(rig.store.events.contains { $0.stateChange == "gaLifted" },
                      "and the lift is on the record, like a manual one")
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "the first arm goes live")
        XCTAssertTrue(OnboardingState.hasArmedOnce, "the first watch going live spends the auto-lift")
        rig.engine.disarm()

        rig.engine.beginArming()
        XCTAssertTrue(rig.engine.armingBlockedByGuidedAccess, "the second arm requires Guided Access again")
        XCTAssertFalse(rig.engine.guidedAccessLiftedThisArm, "no auto-lift the second time")
        rig.engine.cancelArming()
    }

    // MARK: - The fact-first rule and folding

    /// The fact exists before the capture answers (ADR 0005's promise, seen from the engine):
    /// with the still held open, the event is already in the store, still media-less.
    func testTheFactIsRecordedBeforeTheCaptureAnswers() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3), "the capture was requested")
        XCTAssertEqual(rig.engine.state, .triggered, "the response owns the pipeline while the still is open")
        guard let pending = rig.store.events.first(where: { !$0.isStateChange }) else {
            rig.camera.releaseStills()
            return XCTFail("the fact should already be in the store")
        }
        XCTAssertNil(pending.mediaFilename, "no media yet — the still has not answered")
        XCTAssertEqual(pending.triggeredSensors, [.motion])
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed
                && rig.store.events.first(where: { $0.id == pending.id })?.mediaFilename != nil
        }, timeout: 3), "then the still lands on the same record and the engine re-arms")
        rig.engine.disarm()
    }

    /// A trip that lands while a capture is in flight joins THAT record (34-review M1): no
    /// second event, no second still, both sensors on the one record.
    func testTripsDuringACaptureFoldIntoTheInFlightEvent() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3))
        rig.engine.handleTrip(.power)
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        let events = rig.store.events.filter { !$0.isStateChange }
        XCTAssertEqual(events.count, 1, "one in-flight record absorbs the second trip")
        XCTAssertEqual(events.first?.triggeredSensors, [.motion, .power])
        XCTAssertEqual(rig.camera.stills.count, 1, "and no second capture")
        rig.engine.disarm()
    }

    /// A disarm while a still is in flight (item 63 leg 6): the record closes with "disarmed",
    /// not a camera fault, and the disarmed Home carries no camera notice — the notice used to
    /// be posted after the disarm and sat there until the next arm.
    func testADisarmDuringACaptureLeavesNoNoticeAndTheRecordSaysDisarmed() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        // The test host has no camera permission, so the arm-time permission notice may be on
        // Home already; that one is meant to outlive the disarm. What must not appear is a NEW
        // notice from the capture that the disarm cut short.
        let noticeAtArm = rig.engine.cameraNotice
        let captureFailedNotice = "A camera capture failed - an event may be missing its photo or clip."
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3))
        rig.engine.disarm()
        rig.camera.stillError = CameraController.CameraError.captureFailed   // the stopped session fails the shot
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: {
            rig.store.events.contains { !$0.isStateChange && $0.captureFailure != nil }
        }, timeout: 3), "the in-flight record closes with a reason")
        let event = rig.store.events.first { !$0.isStateChange }
        XCTAssertEqual(event?.captureFailure, CaptureFailureReason.disarmed.rawValue)
        XCTAssertNil(event?.mediaFilename)
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertEqual(rig.engine.cameraNotice, noticeAtArm, "the disarmed Home shows no new camera warning")
        XCTAssertNotEqual(rig.engine.cameraNotice, captureFailedNotice)

        // Belt: a late notice from any path is ignored while disarmed.
        rig.engine.report(cameraNotice: captureFailedNotice)
        XCTAssertEqual(rig.engine.cameraNotice, noticeAtArm)
    }

    /// Rear with a screen touch among the trips captures from the FRONT lens (item 69): a
    /// touched screen faces the toucher. A plain motion trip on Rear stays rear.
    func testRearSwitchesToTheFrontLensWhenTheScreenIsTouched() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .rear; $0.enabledSensors.insert(.vision) }
        arm(rig)
        rig.engine.handleTrip(.touch)
        XCTAssertTrue(pump(until: {
            rig.store.events.contains { !$0.isStateChange && $0.mediaFilename != nil }
        }, timeout: 5))
        XCTAssertEqual(rig.store.events.first { !$0.isStateChange }?.primaryCamera, "front")
        XCTAssertEqual(rig.camera.warmUps.last?.camera, .front)
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))

        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 2 }, timeout: 5))
        XCTAssertEqual(rig.camera.warmUps.last?.camera, .rear, "a plain motion trip keeps the rear lens")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        rig.engine.disarm()
    }

    /// Item 69: the engine hands the camera its mic decision at arm — the setting AND the
    /// permission. With the setting off the clip session carries no mic whatever iOS granted.
    func testAClipSessionCarriesNoMicWhileClipAudioIsOff() {
        let rig = makeRig { $0.captureMode = .clip3; $0.clipAudio = false; $0.cameraReadiness = .instant }
        arm(rig)
        XCTAssertFalse(rig.camera.clipAudio, "no mic without the owner's say-so")
        rig.engine.disarm()
    }

    /// Leg 8 on 40: with Auto readiness on battery the camera is not pre-warmed, and the
    /// decision used to live only on the pre-warm path — so it never reached the camera. It is
    /// pushed on every arm now: a stale value on the camera is overwritten.
    func testTheClipAudioDecisionReachesACameraThatIsNotPreWarmed() {
        let rig = makeRig { $0.captureMode = .clip3; $0.clipAudio = false; $0.cameraReadiness = .batterySaver }
        rig.camera.clipAudio = true   // stale, as if a previous session had left it on
        arm(rig)
        XCTAssertFalse(rig.camera.clipAudio, "overwritten at arm even though nothing pre-warmed the camera")
        rig.engine.disarm()
    }

    /// ADR 0012: without the Vision tripwire a stored Rear captures from the front — the rear
    /// lens serves only the watching-the-room setup.
    func testWithoutVisionAStoredRearCapturesFromTheFront() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .rear }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 5))
        XCTAssertEqual(rig.camera.warmUps.last?.camera, .front)
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        rig.engine.disarm()
    }

    // MARK: - Disarm

    /// The owner's own handling — the touch that starts the hold, captured while the
    /// attribution window was open — is attributed to them by a correct PIN rather than left
    /// standing as tamper (R-02), and the disarm is its own audit record.
    func testOwnerDisarmAttributesTheHandlingCapturedWhileThePadWasOpen() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.noteDisarmCandidate()   // press-down opens the attribution window …
        rig.engine.reportTouch()           // … and the same press-down is a touch trip
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed
                && rig.store.events.contains { $0.triggeredSensors == [.touch] && $0.mediaFilename != nil }
        }, timeout: 3), "the touch trip captured like any other")
        rig.engine.beginDisarmEntry()
        XCTAssertTrue(rig.engine.disarmEntryActive)
        rig.engine.disarm()
        XCTAssertEqual(rig.engine.state, .disarmed)
        let touch = rig.store.events.first { $0.triggeredSensors == [.touch] }
        XCTAssertEqual(touch?.ownerAttributed, true, "a correct PIN attributes the handling to the owner")
        XCTAssertTrue(rig.store.events.contains { $0.stateChange == "disarmed" })
    }

    /// A pad opened and abandoned — the snoop who held 5 s and walked away — leaves whatever
    /// was captured standing as evidence, and the watch continues.
    func testAnAbandonedPadLeavesTheEvidenceStandingAndStaysArmed() {
        let rig = makeRig { $0.captureMode = .photo }
        arm(rig)
        rig.engine.noteDisarmCandidate()
        rig.engine.reportTouch()
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && rig.store.events.contains { $0.triggeredSensors == [.touch] }
        }, timeout: 3))
        rig.engine.beginDisarmEntry()
        rig.engine.endDisarmEntry()   // cancelled / abandoned
        XCTAssertFalse(rig.engine.disarmEntryActive)
        XCTAssertEqual(rig.engine.state, .armed, "abandoning the pad never disarms")
        let touch = rig.store.events.first { $0.triggeredSensors == [.touch] }
        XCTAssertNotEqual(touch?.ownerAttributed, true, "no PIN, no attribution")
        rig.engine.disarm()
    }

    /// The pad closes on its own after the inactivity timeout (compressed here), and the engine
    /// returns to covert, still armed.
    func testThePadTimesOutOnInactivityAndTheWatchContinues() {
        let rig = makeRig()
        arm(rig)
        rig.engine.beginDisarmEntry()
        XCTAssertTrue(rig.engine.disarmEntryActive)
        XCTAssertTrue(pump(until: { !rig.engine.disarmEntryActive }, timeout: 3),
                      "the inactivity timeout closes the pad")
        XCTAssertEqual(rig.engine.state, .armed)
        rig.engine.disarm()
    }

    // MARK: - Interruption

    /// An active session sent to the background is protection stopping: it is logged as an
    /// interruption record rather than vanishing silently (32.R6).
    func testBackgroundingAnArmedSessionLogsAnInterruption() {
        defer { UserDefaults.standard.removeObject(forKey: "com.malinois.armed.backgroundLapseLogged") }
        let rig = makeRig()
        arm(rig)
        rig.engine.handleEnteredBackground()
        XCTAssertTrue(rig.store.events.contains { $0.interrupted == true }, "the lapse leaves a record")
        XCTAssertEqual(rig.store.events.first { $0.interrupted == true }?.interruptionCause,
                       InterruptionCause.backgrounded.rawValue, "and the record says it was backgrounded (53)")
        rig.engine.disarm()
    }

    // MARK: - Flood

    /// Sustained trips past the per-sensor bar stop minting events: one coalesced record carries
    /// the count, so a motor against the table leg cannot push genuine evidence out of the log.
    func testAFloodCoalescesIntoOneSustainedRecord() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        // Each trip must be its own TRIGGER (not folded into an in-flight capture), so wait for
        // the engine to re-arm between them. Past `floodTripThreshold` trips of one sensor inside
        // the flood window, the rest coalesce.
        let trips = MonitoringEngine.floodTripThreshold + 4
        for _ in 0..<trips {
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        }
        let events = rig.store.events.filter { !$0.isStateChange }
        XCTAssertLessThan(events.count, trips, "coalescing kicked in")
        XCTAssertTrue(events.contains { ($0.sustainedCount ?? 0) >= 2 }, "one record carries the sustained count")
        rig.engine.disarm()
    }

    // MARK: - Until clear

    /// Until-clear keeps the clip open while trips keep coming and ends it once the scene has
    /// been quiet for the idle threshold. Today's behavior, pinned as it is: a trip that
    /// extends the recording refreshes the activity clock but is NOT folded into the record's
    /// sensor list — that is what "until clear" has always done.
    func testUntilClearRecordsWhileTripsContinueAndEndsWhenQuiet() {
        let rig = makeRig { $0.captureMode = .untilClear; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        rig.engine.handleTrip(.power)   // activity while recording extends it
        XCTAssertEqual(rig.camera.clipEnds, 0, "still recording while trips continue")
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 5),
                      "quiet for the idle threshold ends the clip")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        let event = rig.store.events.first { !$0.isStateChange }
        // Item 54's fold: a trip that extended the recording is on the record, not just in
        // the clip's length (it used to be dropped — pinned as [.motion] until 1.3 step 6).
        XCTAssertEqual(event?.triggeredSensors, [.motion, .power], "the extending trip is folded into the record")
        XCTAssertEqual(rig.camera.clips.count, 1, "one clip for the whole episode")
        rig.engine.disarm()
    }

    // MARK: - Capture-failure honesty (item 54)

    /// A clip that fails while the session is interrupted leaves a record that says why and
    /// carries no media; when the interruption ends, the one bounded retry attaches a photo
    /// to that same record, which keeps its reason.
    func testAFailedClipRecordsItsReasonAndTheRetryAttachesAPhotoWhenTheCameraReturns() {
        let rig = makeRig { $0.captureMode = .untilClear; $0.cameraPosition = .front }
        rig.camera.clipEndError = CameraController.CameraError.captureFailed
        rig.camera.interruptionReasonValue = .background
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 5), "the clip was attempted and ended")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        let failed = rig.store.events.first { !$0.isStateChange }
        XCTAssertEqual(failed?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
        XCTAssertNil(failed?.mediaFilename, "no media, and the record says why")
        XCTAssertTrue(rig.camera.stills.isEmpty, "no retry until the interruption ends")

        // The camera comes back.
        rig.camera.clipEndError = nil
        rig.camera.interruptionReasonValue = nil
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.store.events.first { !$0.isStateChange }?.mediaFilename != nil }, timeout: 3),
                      "the one bounded retry attached a still to the failed event")
        let retried = rig.store.events.first { !$0.isStateChange }
        XCTAssertEqual(rig.camera.stills.count, 1, "exactly one retry")
        XCTAssertEqual(retried?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue,
                       "the record keeps its reason — the photo is labelled as the second attempt")
        XCTAssertEqual(retried?.primaryCamera, "front")

        // A second end-of-interruption does nothing: one retry, never a loop.
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertFalse(pump(until: { rig.camera.stills.count > 1 }, timeout: 0.5), "no second retry")
        rig.engine.disarm()
    }

    /// A runtime error under an armed session leaves an audit record and re-warms the camera
    /// when the readiness policy keeps it warm (32.R9, absorbed by item 54) — and a storm of
    /// them (a session that cannot start emits one per attempt) is one record, one re-warm.
    func testACameraRuntimeErrorLeavesAnAuditRecordAndRewarmsOncePerStorm() {
        let rig = makeRig { $0.cameraPosition = .front; $0.cameraReadiness = .instant }   // always warm
        arm(rig)
        let warmUpsBefore = rig.camera.warmUps.count
        rig.camera.onSessionEvent?(.runtimeError("media services were reset"))
        XCTAssertTrue(pump(until: { rig.store.events.contains { $0.stateChange == "cameraError" } }, timeout: 3),
                      "the failure is on the record")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmUpsBefore }, timeout: 3), "and the camera was re-warmed")
        XCTAssertTrue(rig.engine.cameraNotice?.contains("camera session failed") == true)

        let warmUpsAfterFirst = rig.camera.warmUps.count
        for _ in 0..<5 { rig.camera.onSessionEvent?(.runtimeError("media services were reset")) }
        XCTAssertFalse(pump(until: { rig.store.events.filter { $0.stateChange == "cameraError" }.count > 1 }, timeout: 0.5),
                       "repeats inside the debounce add no record")
        XCTAssertEqual(rig.camera.warmUps.count, warmUpsAfterFirst, "and trigger no further re-warm")
        rig.engine.disarm()
    }

    /// An interruption while armed is surfaced for as long as it lasts, and cleared when it ends.
    func testAnInterruptionIsSurfacedWhileItLasts() {
        let rig = makeRig()
        arm(rig)
        rig.camera.onSessionEvent?(.interrupted(.anotherApp))
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2))
        XCTAssertEqual(rig.engine.cameraNotice, MonitoringEngine.interruptionNotice(.anotherApp))
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice == nil }, timeout: 2), "cleared when it ends")
        rig.engine.disarm()
    }
}
