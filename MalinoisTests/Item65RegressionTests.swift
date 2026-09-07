//
//  Item65RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for the 1.3 (36) respin (BACKLOG 65): each pins a finding of the 2026-09-04
//  code review as a behavior the engine must have. Written before the fixes — red at that
//  commit — and each fix turns its own test green. Driven through the characterization
//  harness (EngineHarness.swift): the real engine, the real store on a throwaway root, the
//  fake camera, and, new here, a fake tripwire, so the Sound monitor's start/stop can be
//  observed on a simulator that has no microphone to ask for.
//

import XCTest
@testable import Malinois

/// A tripwire that records what the engine does to it. `isWatching` is finding 1's question:
/// is the monitor running again after the engine paused it for a clip?
@MainActor
final class FakeSensorMonitor: SensorMonitor {
    let type: SensorType
    var isEnabled = true
    var sensitivity: Sensitivity = .high
    var onTrip: ((SensorType) -> Void)?
    private(set) var isWatching = false
    private(set) var starts = 0
    private(set) var stops = 0

    init(type: SensorType) { self.type = type }

    func start() { isWatching = true; starts += 1 }
    func stop() { isWatching = false; stops += 1 }
    func rearm() {}
}

@MainActor
final class Item65RegressionTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
    }

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem65-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        super.tearDown()
    }

    private func makeRig(_ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                      camera: camera,
                                      entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: EngineCharacterizationTests.fastTiming)
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

    // MARK: - Finding 1: the Sound tripwire after a clip capture

    /// Alert response + a clip + the Sound tripwire (Pro): the pipeline pauses the Sound monitor
    /// for the clip — the capture session needs the microphone — and resumes it the moment the
    /// clip ends, while the engine is still `.triggered`. The resume must restart the monitor.
    /// It used to check for `.armed`, restart nothing, and leave the tripwire silently dead from
    /// the first clip capture until disarm (shipped that way in 1.2).
    func testTheSoundTripwireWatchesAgainAfterAClipCapture() {
        let rig = makeRig {
            $0.captureMode = .untilClear
            $0.cameraPosition = .front
            $0.responseMode = .alert
            $0.enabledSensors = [.motion, .audio, .camera]
        }
        let audio = FakeSensorMonitor(type: .audio)
        rig.engine.replaceMonitorForTesting(audio)
        arm(rig)
        XCTAssertTrue(audio.isWatching, "the Sound tripwire runs from the moment the watch starts")
        // Item 73, review 1 R2 (a): only a clip that takes the microphone pauses the tripwire;
        // this test is about the resume, so give the clip a mic (the engine set it from the
        // settings at arm — off by default since item 69).
        rig.camera.clipAudio = true

        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        XCTAssertFalse(audio.isWatching, "paused for the clip — the capture session needs the microphone")
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 && rig.engine.state == .armed }, timeout: 5),
                      "the clip ends on quiet and the engine re-arms")
        XCTAssertTrue(audio.isWatching,
                      "the Sound tripwire is watching again — it used to stay dead until disarm")
        rig.engine.disarm()
    }

    // MARK: - Finding 2: an interruption that ends during the attempt

    /// An interruption that begins during the attempt and ends before the doomed shot gives up:
    /// the record must carry the interruption's reason, and the one bounded retry must run —
    /// nothing else will fire it, because the end it waits for has already come.
    func testAnInterruptionThatEndsDuringTheAttemptStillGetsTheReasonAndTheRetry() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        rig.camera.warmUpDelay = 0.4            // stretch the attempt so the interruption can come and go inside it
        rig.camera.stillFailuresRemaining = 1   // the first shot fails (the interruption's casualty); the retry lands
        arm(rig)

        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 2), "the response is in flight")
        pump(until: { false }, timeout: 0.1)
        rig.camera.onSessionEvent?(.interrupted(.anotherApp))
        rig.camera.onSessionEvent?(.interruptionEnded)   // over before the attempt returns
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && rig.camera.stills.count >= 1 }, timeout: 5),
                      "the failed attempt completes and the engine re-arms")
        guard let id = rig.store.events.first(where: { !$0.isStateChange })?.id else {
            return XCTFail("no event was minted for the trip")
        }
        XCTAssertTrue(pump(until: { rig.store.events.first { $0.id == id }?.mediaFilename != nil }, timeout: 4),
                      "the retry ran at once and attached a still — it used to wait for an end that had already come")
        let event = rig.store.events.first { $0.id == id }
        XCTAssertEqual(event?.captureFailure, CaptureFailureReason.interruptedByAnotherApp.rawValue,
                       "the record names the interruption, not 'the camera failed'")
        XCTAssertEqual(rig.camera.stills.count, 2, "one failed shot, one retry")
        rig.engine.disarm()
    }

    // MARK: - Finding 4: the capture-failure notice outlives the interruption

    /// A capture-failure notice raised while an interruption is showing must outlive the
    /// interruption's end — ADR 0008 §4 promises the interruption text never overwrites it.
    func testACaptureFailureNoticeOutlivesTheEndOfTheInterruption() {
        let rig = makeRig()
        arm(rig)
        rig.camera.onSessionEvent?(.interrupted(.anotherApp))
        XCTAssertTrue(pump(until: {
            rig.engine.cameraNotice == MonitoringEngine.interruptionNotice(.anotherApp)
        }, timeout: 2), "the interruption is surfaced while it lasts")

        let failure = "A camera capture failed - an event may be missing its photo or clip."
        rig.engine.report(cameraNotice: failure)   // what the pipeline says when a shot fails meanwhile
        rig.camera.onSessionEvent?(.interruptionEnded)
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.engine.cameraNotice, failure,
                       "the end of the interruption must not wipe the capture-failure notice")
        rig.engine.disarm()
    }

    // MARK: - Finding 1, the rule itself

    /// The Sound tripwire may resume while the watch is live — armed or mid-response — and never
    /// on the way to disarmed, where the monitors are being stopped.
    func testAudioMayResumeWhileArmedOrTriggeredOnly() {
        XCTAssertTrue(MonitoringEngine.audioMayResume(state: .armed))
        XCTAssertTrue(MonitoringEngine.audioMayResume(state: .triggered), "every capture runs in .triggered")
        for state in [MonitoringState.disarmed, .guidedAccessCheck, .arming, .calibrating] {
            XCTAssertFalse(MonitoringEngine.audioMayResume(state: state), "\(state)")
        }
    }

    // MARK: - Finding 5: every attempt starts with a clean interruption slate

    /// The pipeline tells the camera when an attempt begins, so the latch a previous clip's
    /// interruption left cannot label this attempt's failure.
    func testEveryCaptureAttemptBeginsWithACleanSlate() async {
        let camera = FakeCamera()
        camera.supportsMultiCam = true
        let pipeline = EvidenceCapturePipeline(camera: camera, timing: EngineCharacterizationTests.fastTiming)
        let host = FakeCaptureHost()
        pipeline.host = host
        _ = await pipeline.capture(from: .front, mode: .photo, illumination: .off)
        XCTAssertEqual(camera.attemptBegins, 1, "a single-camera attempt announces itself")
        _ = await pipeline.captureBoth(mode: .photo, illumination: .off)
        XCTAssertEqual(camera.attemptBegins, 2, "so does a both-cameras attempt")
    }

    /// The real controller clears the clip latch on a new attempt — the reason a clip's
    /// interruption planted no longer answers for a later still.
    func testTheControllerForgetsAClipInterruptionWhenANewAttemptBegins() async {
        let controller = CameraController()
        controller.latchClipInterruptionForTesting(.background)
        let before = await controller.interruptionReason()
        XCTAssertEqual(before, .background, "the latch answers until a new attempt begins")
        controller.beginCaptureAttempt()
        let after = await controller.interruptionReason()
        XCTAssertNil(after, "a new attempt starts with no inherited reason")
    }

    // MARK: - Finding 2, the rules themselves

    func testAFailureIsReclassifiedByAnInterruptionThatBeganDuringTheAttempt() {
        let start = Date()
        let during = start.addingTimeInterval(0.5)
        let before = start.addingTimeInterval(-0.5)
        XCTAssertEqual(MonitoringEngine.reclassifiedCaptureFailure(.captureFailed, attemptStartedAt: start,
                                                                    interruptedAt: during, reason: .anotherApp),
                       .interruptedByAnotherApp, "an interruption inside the attempt names the failure")
        XCTAssertEqual(MonitoringEngine.reclassifiedCaptureFailure(.captureFailed, attemptStartedAt: start,
                                                                    interruptedAt: before, reason: .anotherApp),
                       .captureFailed, "one from before the attempt does not")
        XCTAssertEqual(MonitoringEngine.reclassifiedCaptureFailure(.warmUpTimedOut, attemptStartedAt: start,
                                                                    interruptedAt: during, reason: .anotherApp),
                       .warmUpTimedOut, "only the unexplained failure is reclassified")
        XCTAssertNil(MonitoringEngine.reclassifiedCaptureFailure(nil, attemptStartedAt: start,
                                                                  interruptedAt: during, reason: .anotherApp),
                     "a capture that succeeded stays a success")
    }

    func testTheRetryIsDueNowOnlyWhenTheInterruptionAlreadyEnded() {
        let began = Date()
        XCTAssertFalse(MonitoringEngine.retryIsDueNow(interruptedAt: began, interruptionEndedAt: nil),
                       "still live: wait for the end")
        XCTAssertTrue(MonitoringEngine.retryIsDueNow(interruptedAt: began, interruptionEndedAt: began.addingTimeInterval(1)),
                      "over: nothing else will fire the retry")
        XCTAssertFalse(MonitoringEngine.retryIsDueNow(interruptedAt: began.addingTimeInterval(2),
                                                      interruptionEndedAt: began.addingTimeInterval(1)),
                       "a newer interruption is live: wait for its end")
        XCTAssertFalse(MonitoringEngine.retryIsDueNow(interruptedAt: nil, interruptionEndedAt: began),
                       "no interruption, nothing to retry for")
    }

    // MARK: - Finding 3: the retry's photo must be able to reach iCloud

    /// A record marked `.synced` without media is reopened when the retry attaches a photo, so
    /// a failed upload of that photo is retried by the sweep instead of being dropped forever.
    func testTheRetryReopensASyncedRecordForUpload() {
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
        store.add(event)
        store.setSyncState(.synced, for: event.id)
        XCTAssertEqual(store.events.first?.cloudSyncState, .synced)
        store.setSyncState(.pending, for: event.id)
        XCTAssertEqual(store.events.first?.cloudSyncState, .synced, "synced is terminal for an ordinary transition")
        store.reopenForReupload(event.id)
        XCTAssertEqual(store.events.first?.cloudSyncState, .pending, "the retry's reopening is the sanctioned exception")
        store.setSyncState(.localOnly, for: event.id)
        XCTAssertEqual(store.events.first?.cloudSyncState, .localOnly,
                       "a failed upload can now be recorded, so the sweep retries it")
    }
}
