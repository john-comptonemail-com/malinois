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

import UIKit
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
        TestIsolation.setUp(folderPrefix: "MalinoisCharacterization")
    }

    override func tearDown() {
        TestIsolation.tearDown()
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
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera,
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
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

    // MARK: - Test Sensors keeps the camera as the armed watch would (item 190's codex-2, the owner's "A6 a")

    /// Codex's codex-2 on aa71756: Test Sensors warmed the camera for its Vision row whatever the camera-readiness
    /// setting, so with Battery saver, or Auto on battery, the test showed Vision tripping where the armed watch keeps the
    /// camera cold and sees nothing. Now it keeps the camera as the watch would: never with Battery saver, always with
    /// Instant, and with Auto as the charging state says.
    func testTestSensorsWarmsTheCameraOnlyWhereTheWatchWould() {
        let charging = MonitoringEngine.isChargingState(UIDevice.current.batteryState)
        for readiness in [CameraReadiness.batterySaver, .instant, .auto] {
            let rig = makeRig { $0.cameraReadiness = readiness; $0.enabledSensors.insert(.vision) }
            rig.engine.startDryRun()
            let wanted = readiness.keepsCameraWarm(charging: charging)
            // The warm-up runs in a task of its own: wait for it, or long enough that it would have come.
            pump(until: { !rig.camera.warmUps.isEmpty }, timeout: wanted ? 2 : 0.5)
            XCTAssertEqual(!rig.camera.warmUps.isEmpty, wanted, "\(readiness), charging \(charging)")
            rig.engine.stopDryRun()
        }
        // Without Vision there is no row to warm the camera for, whatever the setting.
        let still = makeRig { $0.cameraReadiness = .instant; $0.enabledSensors.remove(.vision) }
        still.engine.startDryRun()
        pump(until: { !still.camera.warmUps.isEmpty }, timeout: 0.5)
        XCTAssertTrue(still.camera.warmUps.isEmpty, "no Vision, no camera")
        still.engine.stopDryRun()
    }

    /// And a charger plugged in or out during the test, with Auto, warms the camera or stands it down, as during a watch.
    func testTestSensorsFollowsTheChargerWithAuto() {
        let rig = makeRig { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        rig.engine.startDryRun()
        rig.engine.handleBatteryStateChange(charging: false)   // on battery, whatever this machine says
        pump(until: { false }, timeout: 0.5)   // what the start owed has come
        let warmed = rig.camera.warmUps.count
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 2), "plugged in: warmed for the Vision row")
        let stoodDown = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > stoodDown }, timeout: 2), "unplugged: stood down")
        rig.engine.stopDryRun()
        // Without Vision, plugging in warms nothing.
        let still = makeRig { $0.cameraReadiness = .auto; $0.enabledSensors.remove(.vision) }
        still.engine.startDryRun()
        still.engine.handleBatteryStateChange(charging: false)
        pump(until: { false }, timeout: 0.3)
        let before = still.camera.warmUps.count
        still.engine.handleBatteryStateChange(charging: true)
        pump(until: { still.camera.warmUps.count > before }, timeout: 0.5)
        XCTAssertEqual(still.camera.warmUps.count, before, "no Vision, no camera")
        still.engine.stopDryRun()
    }

    /// Codex's codex-5 on 29d6501: unplugged during the test with Auto, the camera stood down, but Vision's row kept its
    /// last reading, WOULD TRIP when it was hot, where README and the test's hint promise "No frames". Once the camera
    /// stands down the row says "No frames"; once it warms and frames come again, it reads them.
    func testVisionsRowSaysNoFramesOnceAutoStandsTheCameraDown() throws {
        let rig = makeRig { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        rig.engine.startDryRun()
        rig.engine.handleBatteryStateChange(charging: false)
        rig.engine.handleBatteryStateChange(charging: true)   // plugged in: the camera warm for the Vision row
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        // After the settle countdown and the calibration, the row reads frames: the scene, then a hand across it.
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the test is watching")
        vision.ingest(Self.scene)
        vision.ingest(Self.handAcross)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision]?.hot == true }, timeout: 2), "a hot reading")
        let warm = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged: Auto stands the camera down
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > warm }, timeout: 2), "stood down")
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision]?.value == "No frames" }, timeout: 2),
                      "the row says no frames come: \(String(describing: rig.engine.dryRunReadings[.vision]))")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.hot, false)
        // A frame already on its way when the camera stood down changes nothing (codex-3 on b7702f5, the owner's "a").
        vision.ingest(Self.handAcross)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a late frame changes nothing")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.hot, false)
        // Plugged in again: once the warm-up has finished, frames come, and the row reads them.
        rig.engine.handleBatteryStateChange(charging: true)
        pump(until: { false }, timeout: 0.4)
        vision.ingest(Self.scene)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision].map { $0.value != "No frames" } ?? false }, timeout: 2),
                      "reading frames again")
        rig.engine.stopDryRun()
    }

    /// codex-3 and deepseek-3 on 424d8ce: the engine told Vision the camera warmed as it asked for the warm-up, before
    /// any frame, so the row read its last reading from before the stand-down, WOULD TRIP when that was hot, and kept it
    /// when the warm-up failed. The row says "No frames" until the warmed camera reads a frame; a warm-up that fails, or
    /// a stand-down before any frame came, leaves it so, whatever frame was already on its way.
    func testVisionsRowSaysNoFramesUntilTheWarmedCameraReads() throws {
        let rig = makeRig { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        rig.engine.startDryRun()
        rig.engine.handleBatteryStateChange(charging: false)
        rig.engine.handleBatteryStateChange(charging: true)
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the test is watching")
        vision.ingest(Self.scene)
        vision.ingest(Self.handAcross)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision]?.hot == true }, timeout: 2), "a hot reading")
        var down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged: Auto stands the camera down
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down")
        // Plugged in again, and no frame yet.
        rig.engine.handleBatteryStateChange(charging: true)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "no reading before the warmed camera's first")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.hot, false)
        // Unplugged before any frame came: a frame already on its way changes nothing.
        down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down again")
        vision.ingest(Self.handAcross)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a late frame changes nothing")
        // Plugged in again, and the warm-up fails: no frame comes.
        rig.camera.warmUpError = CameraController.CameraError.unavailable
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "the warm-up failed")
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a failed warm-up reads nothing")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.hot, false)
        rig.engine.stopDryRun()
    }

    /// The same in Vision alone (codex-3 on 424d8ce): asked to warm again, the camera's first frame that only re-anchors
    /// (around a capture, or the first after a long cold spell) makes no reading, and the row still says no frames come;
    /// the first frame it reads ends that.
    func testVisionsRowWaitsForTheWarmedCamerasFirstReading() {
        let vision = VisionMonitor()
        vision.beginCalibration()
        vision.ingest(Self.scene)
        vision.endCalibration()
        vision.start()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(vision.liveReading()?.hot, true, "a hot reading")
        vision.cameraStoodDown()
        vision.cameraWarming()
        XCTAssertEqual(vision.liveReading()?.value, "No frames", "asked to warm, no frame yet")
        vision.cameraWarmed()   // and the warm-up finished (codex-2 on 63e77b0)
        vision.suppress(for: 0)
        vision.ingest(Self.scene)   // re-anchors only
        XCTAssertEqual(vision.liveReading()?.value, "No frames", "a frame that only re-anchors reads nothing")
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // the settle countdown, then a reading
        XCTAssertNotEqual(vision.liveReading()?.value, "No frames", "the warmed camera's first reading")
        XCTAssertEqual(vision.liveReading()?.hot, false)
    }

    /// codex-2 on 63e77b0: a frame read after the engine asked for the camera warm, before that warm-up had finished, as a
    /// frame from the camera standing down can be, ended "No frames", and a warm-up that then failed left its reading.
    /// Only a frame read once the warm-up the engine asked for has finished ends it; a stand-down cancels the request, a
    /// warm-up finishing after it included, and one that finished before it counts for nothing after it.
    func testVisionsRowWaitsForTheWarmUpItAskedFor() {
        let vision = VisionMonitor()
        vision.beginCalibration()
        vision.ingest(Self.scene)
        vision.endCalibration()
        vision.start()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(vision.liveReading()?.hot, true, "a hot reading")
        vision.cameraStoodDown()
        vision.cameraWarming()
        vision.ingest(Self.handAcross)   // the camera standing down, its last frame late
        XCTAssertEqual(vision.liveReading()?.value, "No frames", "read before the warm-up finished")
        vision.cameraStoodDown()
        vision.cameraWarmed()   // a warm-up finishing after the stand-down that cancelled it
        vision.ingest(Self.handAcross)
        XCTAssertEqual(vision.liveReading()?.value, "No frames", "a cancelled warm-up")
        vision.cameraWarming()
        vision.cameraWarmed()
        vision.cameraStoodDown()   // warmed, and stood down again before any frame
        vision.cameraWarming()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(vision.liveReading()?.value, "No frames", "a warm-up before the stand-down")
        vision.cameraWarmed()
        vision.ingest(Self.scene)
        XCTAssertNotEqual(vision.liveReading()?.value, "No frames", "the warmed camera's first frame read")
    }

    /// The same through the engine (codex-2 on 63e77b0): it tells Vision when the warm-up it asked for has finished, and
    /// a warm-up that fails tells it nothing.
    func testVisionsRowReadsOnlyOnceTheWarmUpItAskedForHasFinished() throws {
        try checkVisionWaitsForTheWarmUp(makeRig { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) })
    }

    /// And with both cameras, whose warm-up is the engine's other path (codex-2 on 63e77b0).
    func testVisionsRowReadsOnlyOnceTheWarmUpItAskedForHasFinishedWithBothCameras() throws {
        let rig = makeRig { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision); $0.cameraPosition = .both }
        rig.camera.supportsMultiCam = true
        try checkVisionWaitsForTheWarmUp(rig)
        XCTAssertGreaterThan(rig.camera.multiCamWarmUps, 0, "both cameras warmed")
    }

    /// A hot reading; the camera stood down; plugged in again at once, a frame from the camera standing down read before
    /// the warm-up has finished, then a frame once it has; stood down again, and a frame after a warm-up that failed.
    private func checkVisionWaitsForTheWarmUp(_ rig: Rig) throws {
        rig.engine.startDryRun()
        rig.engine.handleBatteryStateChange(charging: false)
        rig.engine.handleBatteryStateChange(charging: true)
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the test is watching")
        vision.ingest(Self.scene)
        vision.ingest(Self.handAcross)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision]?.hot == true }, timeout: 2), "a hot reading")
        var down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged: Auto stands the camera down
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down")
        rig.engine.handleBatteryStateChange(charging: true)
        vision.ingest(Self.handAcross)   // the camera standing down, its last frame late
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "read before the warm-up finished")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.hot, false)
        vision.ingest(Self.scene)   // the warm-up has finished
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision].map { $0.value != "No frames" } ?? false }, timeout: 2),
                      "reading frames once the warm-up has finished")
        down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down again")
        rig.camera.warmUpError = CameraController.CameraError.unavailable
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "the warm-up failed")
        vision.ingest(Self.handAcross)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a failed warm-up's frames read nothing")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.hot, false)
        rig.engine.stopDryRun()
    }

    /// codex-1 on 6223aae: the engine told Vision a warm-up finished only when it finished within its deadline, whose
    /// wait abandons a warm-up rather than stopping it, so one that succeeded after it left the row at "No frames" while
    /// the warmed camera's frames were read. A warm-up that succeeds late reaches Vision too.
    func testVisionsRowReadsTheFramesOfAWarmUpThatSucceededAfterItsDeadline() throws {
        try checkVisionReadsAfterALateWarmUp(makeRig(timing: Self.lateWarmUpTiming) {
            $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision)
        })
    }

    /// And with both cameras (codex-1 on 6223aae).
    func testVisionsRowReadsTheFramesOfAWarmUpThatSucceededAfterItsDeadlineWithBothCameras() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) {
            $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision); $0.cameraPosition = .both
        }
        rig.camera.supportsMultiCam = true
        try checkVisionReadsAfterALateWarmUp(rig)
        XCTAssertGreaterThan(rig.camera.multiCamWarmUps, 0, "both cameras warmed")
    }

    /// The rig's timing with a warm-up deadline the test camera can outlast (`FakeCamera.warmUpDelay`).
    private static var lateWarmUpTiming: EngineTiming {
        var timing = fastTiming
        timing.warmUpDeadline = 0.2
        return timing
    }

    /// A warm-up that succeeds after its deadline, once a stand-down has cancelled its request, counts for nothing
    /// (codex-1 on 6223aae).
    func testALateWarmUpAfterAStandDownCountsForNothing() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        let vision = try hotThenStoodDown(rig)
        rig.camera.warmUpDelay = 0.6   // longer than the deadline
        let warmed = rig.camera.warmUps.count
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "the deadline passed")
        let down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged again before the warm-up succeeds
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down again")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 2), "the warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "its request was cancelled")
        rig.engine.stopDryRun()
    }

    /// A warm-up that succeeds after its deadline, once a newer warm request has superseded it, counts for nothing: the
    /// row waits for the newer one's (codex-1 on 6223aae; the undo check's need).
    func testALateWarmUpANewerRequestSupersededCountsForNothing() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        let vision = try hotThenStoodDown(rig)
        rig.camera.warmUpDelay = 0.6   // longer than the deadline
        let warmed = rig.camera.warmUps.count
        rig.engine.handleBatteryStateChange(charging: true)   // the first warm request
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "its deadline passed")
        rig.camera.warmUpDelay = 1.5
        rig.engine.warmActiveCamera()   // a newer warm request, its warm-up slower still
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 2), "the first warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a superseded warm-up counts for nothing")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed + 1 }, timeout: 3), "the newer warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision].map { $0.value != "No frames" } ?? false }, timeout: 2),
                      "the newer one's frames read")
        rig.engine.stopDryRun()
    }

    /// codex-1 on b08c1f8: closing Test Sensors shut the camera down without telling Vision, so a warm-up still running
    /// past its deadline then, succeeding after a cold reopen (unplugged while closed), was accepted, and a frame from
    /// it showed a reading in a test whose camera is cold. Closing the test stands Vision down as Auto's stand-down does,
    /// and the frames that come before the engine has the camera up again count for nothing: no reading, no would-trip,
    /// no count (deepseek-1 and deepseek-2 on 1c083ab: the row said "No frames" while they tripped), and the tap's state
    /// at the deadline, a camera's now cold, says nothing either. The reopening is cold by the setting, whatever this
    /// machine's charger says.
    func testAWarmUpAClosedTestAskedForCountsForNothingInTheNext() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        let vision = try hotThenStoodDown(rig)
        rig.camera.warmUpDelay = 1.5   // outlasts the deadline, the closing and the reopening
        rig.camera.visionTapActive = false   // and its tap not up when the deadline passes
        let warmed = rig.camera.warmUps.count
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "the deadline passed")
        rig.engine.stopDryRun()   // closed while charging
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged while closed: no stand-down
        rig.settings.cameraReadiness = .batterySaver   // and the reopening cold, whatever this machine's charger says
        rig.engine.startDryRun()   // reopened: no warm request
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the reopened test is watching")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 3), "the closed test's warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)   // frames from that warm-up's session
        vision.ingest(Self.handAcross)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a closed test's warm-up counts for nothing")
        XCTAssertNil(rig.engine.dryRunTrips[.vision], "its frames trip nothing")
        XCTAssertNil(rig.engine.dryRunCounts[.vision], "and count nothing")
        rig.engine.stopDryRun()
    }

    /// deepseek-1 on 1c083ab: the same warm-up's frames tripped a watch armed after the test on a camera kept cold, and
    /// fired a real tamper event. The watch counts them for nothing too.
    func testAWarmUpAClosedTestAskedForTripsNothingInAWatchArmedAfterIt() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        let vision = try hotThenStoodDown(rig)
        rig.camera.warmUpDelay = 1.5   // outlasts the deadline, the closing and the arming
        let warmed = rig.camera.warmUps.count
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "the deadline passed")
        rig.engine.stopDryRun()
        rig.settings.cameraReadiness = .batterySaver   // the watch asks for no warm-up of its own
        arm(rig)
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 3), "the closed test's warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)   // frames from that warm-up's session
        vision.ingest(Self.handAcross)
        XCTAssertFalse(pump(until: { rig.store.events.contains { $0.triggeredSensors.contains(.vision) } }, timeout: 1),
                       "no tamper event from a closed test's warm-up")
        XCTAssertEqual(rig.engine.state, .armed)
        rig.engine.disarm()
    }

    /// deepseek-1 on 1c083ab: closing Test Sensors left its warm request current, so a warm-up still running then, whose
    /// deadline passed after the close, put its failure notice on Home and its tap's state on the reopened test's row and
    /// the arming screen. Closing the test makes the request stale, as the disarm does: its late answer writes nothing.
    func testAClosedTestsWarmUpWritesNothingAfterTheClose() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .auto; $0.enabledSensors.insert(.vision) }
        _ = try hotThenStoodDown(rig)
        rig.camera.warmUpDelay = 1.5   // outlasts the deadline
        rig.camera.visionTapActive = false   // and its tap not up when the deadline passes
        let warmed = rig.camera.warmUps.count
        rig.engine.handleBatteryStateChange(charging: true)
        rig.engine.stopDryRun()   // closed before the deadline
        rig.settings.cameraReadiness = .batterySaver
        rig.engine.startDryRun()   // reopened cold
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the reopened test is watching")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 3), "the closed test's warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        XCTAssertNil(rig.engine.cameraNotice, "no notice from a closed test's warm-up")
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "nor its tap's state on the row")
        XCTAssertFalse(rig.engine.visionTapUnavailable, "or on the arming screen")
        rig.engine.stopDryRun()
    }

    // MARK: Every stand-down the engine makes stands Vision down (item 190's deepseek-1 on 1c083ab, the owner's "a")

    /// A watch whose camera was warmed at the arming's start (Instant then) and is cold at go-live (Battery saver by then):
    /// going live shut the camera down without telling Vision, so frames from the warm-up still running then were
    /// judged, and tripped. Going live on a cold camera stands Vision down.
    func testAWatchGoingLiveOnAColdCameraCountsItsArmingsWarmUpForNothing() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .instant; $0.enabledSensors.insert(.vision) }
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        rig.camera.warmUpDelay = 1.5   // outlasts the deadline and the arming
        let warmed = rig.camera.warmUps.count
        rig.engine.beginArming()   // Instant: the camera warmed for the watch
        rig.settings.cameraReadiness = .batterySaver   // and cold by go-live
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5))
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 3), "the arming's warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)   // frames from that warm-up's session
        vision.ingest(Self.handAcross)
        XCTAssertFalse(pump(until: { rig.store.events.contains { $0.triggeredSensors.contains(.vision) } }, timeout: 1),
                       "no tamper event from the arming's warm-up")
        rig.engine.disarm()
    }

    /// A capture on a cold camera (Battery saver) has the camera up for its frames; the stand-down after it shut the
    /// camera down without telling Vision, so a frame from the camera standing down, read late, was judged, and tripped.
    /// The stand-down after a capture stands Vision down too.
    func testTheStandDownAfterACaptureOnAColdCameraCountsItsLateFramesForNothing() throws {
        let rig = makeRig {
            $0.cameraReadiness = .batterySaver; $0.captureMode = .photo; $0.cameraPosition = .front
            $0.enabledSensors.insert(.vision)
        }
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        arm(rig)
        let down = rig.camera.shutDowns
        let begun = rig.camera.attemptBegins
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.attemptBegins > begun }, timeout: 3), "the capture began, Vision suppressed")
        // Measured from the capture's start, which suppressed Vision just before it (deepseek-2 on f476178: from the trip,
        // the wait could end inside the suppression on a loaded machine, and the test pass without the fix).
        let suppressionEnds = Date().addingTimeInterval(4.1)
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && !rig.camera.stills.isEmpty && rig.camera.shutDowns > down },
                           timeout: 5), "the capture taken, and the camera stood down after it")
        pump(until: { Date() >= suppressionEnds }, timeout: 5)   // past the capture's suppression (4 s)
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // frames from the camera standing down
        vision.ingest(Self.handAcross)
        XCTAssertFalse(pump(until: { rig.store.events.contains { $0.triggeredSensors.contains(.vision) } }, timeout: 1),
                       "no tamper event from the stood-down camera's frames")
        rig.engine.disarm()
    }

    /// A disarm shut the camera down without telling Vision, so a warm-up still running then, read in a Test Sensors
    /// opened cold after it, was judged, and tripped. The disarm stands Vision down too.
    func testADisarmCountsAWarmUpStillRunningForNothingInTheNextTest() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) { $0.cameraReadiness = .instant; $0.enabledSensors.insert(.vision) }
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        rig.camera.warmUpDelay = 1.5   // outlasts the deadline, the watch and the disarm
        let warmed = rig.camera.warmUps.count
        arm(rig)
        rig.engine.disarm()   // its warm-ups still running
        rig.settings.cameraReadiness = .batterySaver
        rig.engine.startDryRun()   // opened cold
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the test is watching")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmed }, timeout: 3), "the watch's warm-up succeeded, late")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)   // frames from that warm-up's session
        vision.ingest(Self.handAcross)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.engine.dryRunReadings[.vision]?.value, "No frames", "a disarmed watch's warm-up counts for nothing")
        XCTAssertNil(rig.engine.dryRunTrips[.vision], "its frames trip nothing")
        XCTAssertNil(rig.engine.dryRunCounts[.vision], "and count nothing")
        rig.engine.stopDryRun()
    }

    /// codex-1 on f476178 (from Codex's probe): a capture's timeout quarantines the camera, which shuts it down without
    /// telling the engine, and the timed-out response's own stand-down is refused while the stalled capture still holds
    /// the camera, so on a cold camera Vision, which the capture's start had let read frames, judged the frames that
    /// came then, during the stall and after it, and tripped. A timeout is a stand-down too.
    func testATimedOutCaptureOnAColdCameraCountsItsFramesForNothing() throws {
        var timing = Self.fastTiming
        timing.warmUpDeadline = 0.5
        timing.captureFinalizationDeadline = 0.05
        let rig = makeRig(timing: timing) {
            $0.cameraReadiness = .batterySaver; $0.captureMode = .photo; $0.cameraPosition = .front
            $0.illumination = .off; $0.enabledSensors.insert(.vision)
        }
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        rig.camera.holdStills = true
        defer {
            rig.engine.disarm()
            rig.camera.releaseStills()
            XCTAssertTrue(pump(until: { !rig.engine.capturePipeline.isBusy }, timeout: 5), "every held capture drained")
            rig.store.drainIOForTesting()
        }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3), "the cold capture's still, held")
        let suppressionEnds = Date().addingTimeInterval(4.1)   // the capture suppressed Vision before asking for the still
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && rig.store.events.contains {
                !$0.isStateChange && $0.captureFailure == CaptureFailureReason.captureTimedOut.rawValue
            }
        }, timeout: 3), "the capture timed out, and the watch is armed again")
        XCTAssertTrue(rig.engine.capturePipeline.isBusy, "the stalled capture still holds the camera")
        let visionTripped = { rig.store.events.contains { $0.triggeredSensors.contains(.vision) } }
        pump(until: { Date() >= suppressionEnds }, timeout: 5)
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // frames during the stall
        vision.ingest(Self.handAcross)
        XCTAssertFalse(pump(until: visionTripped, timeout: 1), "no tamper event from the stalled camera's frames")
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { !rig.engine.capturePipeline.isBusy }, timeout: 5), "the stalled capture drained")
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // and after the drain
        vision.ingest(Self.handAcross)
        XCTAssertFalse(pump(until: visionTripped, timeout: 1), "nor from its frames after the drain")
    }

    /// deepseek-1 on f476178: the same through the capture's own warm-up, whose deadline expires the capture as the
    /// attempt's does: frames from the late warm-up, once the response had ended, tripped. That timeout is a stand-down
    /// too.
    func testACaptureWhoseWarmUpTimedOutOnAColdCameraCountsItsFramesForNothing() throws {
        let rig = makeRig(timing: Self.lateWarmUpTiming) {
            $0.cameraReadiness = .batterySaver; $0.captureMode = .photo; $0.cameraPosition = .front
            $0.illumination = .off; $0.enabledSensors.insert(.vision)
        }
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        arm(rig)
        rig.camera.warmUpDelay = 1.5   // the capture's warm-up outlasts its deadline
        let begun = rig.camera.attemptBegins
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.attemptBegins > begun }, timeout: 3), "the capture began, Vision suppressed")
        let suppressionEnds = Date().addingTimeInterval(4.1)
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && rig.store.events.contains {
                !$0.isStateChange && $0.captureFailure == CaptureFailureReason.warmUpTimedOut.rawValue
            }
        }, timeout: 3), "the capture's warm-up timed out, and the watch is armed again")
        pump(until: { Date() >= suppressionEnds }, timeout: 5)   // the late warm-up has finished by then
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // frames from that warm-up
        vision.ingest(Self.handAcross)
        XCTAssertFalse(pump(until: { rig.store.events.contains { $0.triggeredSensors.contains(.vision) } }, timeout: 1),
                       "no tamper event from a timed-out capture's warm-up")
        rig.engine.disarm()
    }

    /// The stand-downs' rule leaves a capture's frames read. A capture warms the camera itself, without the engine's warm
    /// request, so a Vision that waited for that request would be blind for the whole of a capture once Auto had stood
    /// the camera down: its trips would neither lengthen an until-clear clip nor reach the record. A capture has the
    /// camera up, so its frames are read once its suppression ends, after a stand-down too. (Green before the round: it
    /// fails only without the capture's part of the fix.)
    func testVisionReadsACapturesFramesAfterAutoStandsTheCameraDown() throws {
        var timing = Self.fastTiming
        timing.untilClearIdle = 5   // the clip outlasts the capture's suppression of Vision (4 s)
        timing.untilClearMax = 7
        let rig = makeRig(timing: timing) {
            $0.cameraReadiness = .auto; $0.captureMode = .untilClear; $0.cameraPosition = .front
            $0.enabledSensors.insert(.vision)
        }
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        arm(rig)
        rig.engine.handleBatteryStateChange(charging: true)   // warm, whatever this machine's charger said at go-live
        pump(until: { false }, timeout: 0.3)
        let down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged: Auto stands the camera down
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down")
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        let started = Date()
        pump(until: { Date().timeIntervalSince(started) >= 4.2 }, timeout: 5)   // past the capture's suppression
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // re-anchored and settled
        vision.ingest(Self.handAcross)   // movement in the capture's frames
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 8), "the clip ends")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        let event = rig.store.events.first { !$0.isStateChange }
        XCTAssertEqual(event?.triggeredSensors, [.motion, .vision], "Vision's trip during the capture is on the record")
        rig.engine.disarm()
    }

    /// The same in Vision alone (deepseek-1 on 1c083ab): frames while the camera stands down were judged and tripped,
    /// whatever the row said. Until the engine has the camera up again, the warm-up it asked for finished or a capture
    /// started, they count for nothing.
    func testVisionCountsFramesForNothingWhileTheCameraStandsDown() {
        let vision = VisionMonitor()
        var trips = 0
        vision.onTrip = { _ in trips += 1 }
        vision.beginCalibration()
        vision.ingest(Self.scene)
        vision.endCalibration()
        vision.start()
        vision.cameraStoodDown()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 0, "stood down")
        vision.cameraWarming()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 0, "asked to warm, the warm-up not finished")
        vision.cameraWarmed()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 1, "the warm-up it asked for finished")
        vision.rearm()
        vision.cameraStoodDown()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 1, "stood down again")
        vision.suppress(for: 0)   // a capture has the camera up
        for _ in 0...VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // re-anchored and settled
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 2, "a capture's frames are read")
    }

    /// The Test Sensors run started, a hot reading made, and the camera stood down (Auto, unplugged): Vision's monitor.
    private func hotThenStoodDown(_ rig: Rig) throws -> VisionMonitor {
        rig.engine.startDryRun()
        rig.engine.handleBatteryStateChange(charging: false)
        rig.engine.handleBatteryStateChange(charging: true)
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision] != nil }, timeout: 8), "the test is watching")
        vision.ingest(Self.scene)
        vision.ingest(Self.handAcross)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision]?.hot == true }, timeout: 2), "a hot reading")
        let down = rig.camera.shutDowns
        rig.engine.handleBatteryStateChange(charging: false)   // unplugged: Auto stands the camera down
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > down }, timeout: 2), "stood down")
        return vision
    }

    /// A hot reading; the camera stood down; plugged in again, a warm-up that outlasts its deadline and then succeeds;
    /// then a frame, which the row reads with no other warm request.
    private func checkVisionReadsAfterALateWarmUp(_ rig: Rig) throws {
        let vision = try hotThenStoodDown(rig)
        rig.camera.warmUpDelay = 0.6   // longer than the deadline
        let warmed = rig.camera.warmUps.count + rig.camera.multiCamWarmUps
        rig.engine.handleBatteryStateChange(charging: true)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2), "the deadline passed")
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count + rig.camera.multiCamWarmUps > warmed }, timeout: 2),
                      "then the warm-up succeeded")
        pump(until: { false }, timeout: 0.2)
        vision.ingest(Self.scene)
        XCTAssertTrue(pump(until: { rig.engine.dryRunReadings[.vision].map { $0.value != "No frames" } ?? false }, timeout: 2),
                      "the warmed camera's frames read, with no other warm request")
        rig.engine.stopDryRun()
    }

    /// A still scene, and the same with a hand across half of it, as the camera's frame tap gives them.
    private static let scene = VisionFrame(luma: [UInt8](repeating: 100, count: VisionFrame.width * VisionFrame.height))
    private static let handAcross = VisionFrame(luma: (0..<(VisionFrame.width * VisionFrame.height)).map {
        $0 % VisionFrame.width < VisionFrame.width / 2 ? UInt8(20) : UInt8(220)
    })

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

    /// A capture's photo can be recovered from disk as soon as it is saved, before the engine
    /// attaches it: on time, the engine's own save; late, after the capture's deadline, the
    /// pipeline's save to the recovery destination the engine supplied, once the engine has
    /// given up waiting. Only a late capture uses that destination, so the on-time check alone
    /// passed without it (test-suite audit, EC02 and EC03).
    func testFrontCaptureHasRecoveryDestinationBeforeEngineAttachment() {
        assertRecoverableCapture(camera: .front, expected: 1)
        assertRecoverableCapture(camera: .front, expected: 1, late: true)
    }

    func testBothCapturesHaveRecoveryDestinationsBeforeEngineAttachment() {
        assertRecoverableCapture(camera: .both, expected: 2)
        assertRecoverableCapture(camera: .both, expected: 2, late: true)
    }

    /// `late`: the camera holds the photo (for Both, the second lens) past a short capture
    /// deadline, then delivers it; the late run gets its own log folder.
    private func assertRecoverableCapture(camera: CameraChoice, expected: Int, late: Bool = false,
                                          file: StaticString = #filePath, line: UInt = #line) {
        var timing = Self.fastTiming
        let testRoot = EventStore.rootOverrideForTesting
        defer { EventStore.rootOverrideForTesting = testRoot }
        if late {
            timing.warmUpDeadline = 0.3   // the fake camera warms at once
            timing.captureFinalizationDeadline = 0.3
            EventStore.rootOverrideForTesting = testRoot?.appendingPathComponent("late", isDirectory: true)
        }
        let rig = makeRig(timing: timing) { $0.captureMode = .photo; $0.cameraPosition = camera }
        rig.camera.supportsMultiCam = true
        if late {
            rig.camera.holdStills = true
            let held = rig.camera
            rig.camera.bothPhotoProbeForTesting = {
                while held.holdStills { try? await Task.sleep(for: .milliseconds(10)) }
            }
        }
        var observed = 0
        rig.store.attachmentPublishedForTesting = { eventID, filename in
            observed += 1
            guard let originalRoot = EventStore.rootOverrideForTesting else { return XCTFail("missing isolated root") }
            let copiedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                EventStore.rootOverrideForTesting = originalRoot
                try? FileManager.default.removeItem(at: copiedRoot)
            }
            do {
                // A separate snapshot stops the live engine from repairing the simulated
                // crash window before the new store has demonstrated its own recovery. The live
                // store's pending saves finish first: an atomic save writes a temporary file and
                // renames it, so a copy taken meanwhile can list a file that is gone a moment later
                // (seen once, item 145's step 9 run). The engine's write-back comes after this hook.
                rig.store.drainIOForTesting()
                try FileManager.default.copyItem(at: originalRoot, to: copiedRoot)
                EventStore.rootOverrideForTesting = copiedRoot
                let relaunched = EventStore()
                let recovered = try XCTUnwrap(relaunched.events.first { $0.id == eventID })
                XCTAssertTrue([recovered.mediaFilename, recovered.secondaryMediaFilename].contains(filename),
                              "restart attaches already-saved evidence without engine write-back", file: file, line: line)
                if late {
                    // The engine has already settled the record (local only here, with no iCloud).
                    XCTAssertNotEqual(recovered.cloudSyncState, .synced, "never read as already uploaded", file: file, line: line)
                } else {
                    XCTAssertEqual(recovered.cloudSyncState, .pending)
                }
                relaunched.flush()
                relaunched.drainIOForTesting()
            } catch { XCTFail("snapshot recovery failed: \(error)", file: file, line: line) }
        }
        arm(rig)
        rig.engine.handleTrip(.motion)
        if late {
            XCTAssertTrue(pump(until: { rig.engine.state == .armed && rig.store.events.contains { $0.captureFailure != nil } },
                               timeout: 5), "the engine gave up on the held capture", file: file, line: line)
            rig.camera.releaseStills()
            XCTAssertTrue(pump(until: { observed >= expected }, timeout: 5),
                          "the late photo is saved at the engine's recovery destination", file: file, line: line)
            let event = rig.store.events.first { !$0.isStateChange }
            XCTAssertNotNil(event?.mediaFilename, "and attached to its event", file: file, line: line)
            if expected == 2 { XCTAssertNotNil(event?.secondaryMediaFilename, file: file, line: line) }
        } else {
            XCTAssertTrue(pump(until: { rig.engine.state == .armed && rig.camera.stills.count + rig.camera.bothStills * 2 >= expected }, timeout: 5))
        }
        XCTAssertEqual(observed, expected, "each real capture path supplies its recoverable destination", file: file, line: line)
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
    /// sensor list — that is what "until clear" has always done. The extending trip comes late
    /// in the quiet time and the clip is checked after the first quiet time would have ended:
    /// checked at once, a clip is still recording whether or not the trip extended it
    /// (test-suite audit, EC11).
    func testUntilClearRecordsWhileTripsContinueAndEndsWhenQuiet() {
        var timing = Self.fastTiming
        timing.untilClearIdle = 1.5
        let rig = makeRig(timing: timing) { $0.captureMode = .untilClear; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        let started = Date()
        pump(until: { Date().timeIntervalSince(started) >= 1.0 }, timeout: 2)
        rig.engine.handleTrip(.power)   // activity while recording extends it
        pump(until: { Date().timeIntervalSince(started) >= 1.9 }, timeout: 2)
        XCTAssertEqual(rig.camera.clipEnds, 0, "still recording 0.4 s after the first quiet time would have ended")
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

    // MARK: - Until clear on the real tripwires (item 204)

    /// A gravity vector `degrees` from flat on a table, as CoreMotion reads it.
    private static func pose(tilted degrees: Double) -> (x: Double, y: Double, z: Double) {
        let radians = degrees * .pi / 180
        return (sin(radians), 0, -cos(radians))
    }

    /// An Until clear clip started by the real motion tripwire on a phone lying flat, with a ceiling no test here reaches, so
    /// only quiet can end it. The clip has started when this returns.
    private func clipStartedByTheMotionTripwire(idle: TimeInterval = 0.3) throws -> (rig: Rig, motion: MotionMonitor) {
        var timing = Self.fastTiming
        timing.untilClearIdle = idle
        timing.untilClearMax = 30
        let rig = makeRig(timing: timing) { $0.captureMode = .untilClear; $0.cameraPosition = .front }
        arm(rig)
        let motion = try XCTUnwrap(rig.engine.monitors[.motion] as? MotionMonitor)
        motion.startWatchingForTesting(at: Date(), restingGravity: Self.pose(tilted: 0))
        motion.sampleForTesting(gravity: Self.pose(tilted: 60), accel: 1, at: Date())   // picked up
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        return (rig, motion)
    }

    /// Item 204 (TestFlight 83: "the clip didn't stop for a very long time after I stopped handling the phone"): a phone left
    /// in a new pose is not being handled. Each look of the clip's loop re-armed the tripwires against the pose learned
    /// at arming, so a phone left a few degrees off it tripped again at every look, each trip counted as activity, and the
    /// clip ran to its ceiling with nothing moving. Here, past the tilt threshold and under the session limit.
    func testAnUntilClearClipEndsWhenThePhoneIsLeftAFewDegreesFromWhereItWasArmed() throws {
        let (rig, motion) = try clipStartedByTheMotionTripwire()
        XCTAssertTrue(pump(until: {
            motion.sampleForTesting(gravity: Self.pose(tilted: 5), at: Date())
            return rig.camera.clipEnds == 1
        }, timeout: 5), "left there: quiet for the idle threshold ends the clip")
        rig.engine.disarm()
    }

    /// The same past the session limit, the other anchor the tilt is measured from.
    func testAnUntilClearClipEndsWhenThePhoneIsLeftFarFromWhereItWasArmed() throws {
        let (rig, motion) = try clipStartedByTheMotionTripwire()
        XCTAssertTrue(pump(until: {
            motion.sampleForTesting(gravity: Self.pose(tilted: 40), at: Date())
            return rig.camera.clipEnds == 1
        }, timeout: 5), "left there: quiet for the idle threshold ends the clip")
        rig.engine.disarm()
    }

    /// Guard: handling still holds the clip open: a phone that keeps turning, then a phone being knocked about in one pose,
    /// each for longer than the idle threshold; then quiet ends it. Each look measures from the last, not from nothing.
    func testAnUntilClearClipStaysOpenWhileThePhoneKeepsMoving() throws {
        let (rig, motion) = try clipStartedByTheMotionTripwire(idle: 0.6)   // room for a slow look on a busy machine
        var angle = 60.0, started = Date()
        pump(until: {
            angle += 6
            motion.sampleForTesting(gravity: Self.pose(tilted: angle), at: Date())
            return Date().timeIntervalSince(started) >= 1
        }, timeout: 2)
        XCTAssertEqual(rig.camera.clipEnds, 0, "a phone that keeps turning holds the clip open")
        started = Date()
        pump(until: {
            motion.sampleForTesting(gravity: Self.pose(tilted: angle), accel: 1, at: Date())
            return Date().timeIntervalSince(started) >= 1
        }, timeout: 2)
        XCTAssertEqual(rig.camera.clipEnds, 0, "bumps in one pose hold the clip open")
        XCTAssertTrue(pump(until: {
            motion.sampleForTesting(gravity: Self.pose(tilted: angle), at: Date())
            return rig.camera.clipEnds == 1
        }, timeout: 5), "then quiet ends it")
        rig.engine.disarm()
    }

    /// The camera tripwire, the same: at each look of the clip's loop a scene that changed and stayed changed stops counting
    /// as activity, and the next change counts.
    func testAChangedSceneStopsCountingAsActivityDuringAClip() throws {
        let rig = makeRig()
        let vision = try XCTUnwrap(rig.engine.monitors[.vision] as? VisionMonitor)
        vision.isEnabled = true
        var trips = 0
        vision.onTrip = { _ in trips += 1 }
        vision.beginCalibration()
        for _ in 0..<5 { vision.ingest(Self.scene) }
        vision.endCalibration()
        vision.start()
        vision.ingest(Self.scene)
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 1, "the scene changed")
        rig.engine.rearmTripwiresDuringCapture()
        vision.ingest(Self.handAcross)
        XCTAssertEqual(trips, 1, "a scene that stayed changed is no further activity")
        rig.engine.rearmTripwiresDuringCapture()
        vision.ingest(Self.scene)
        XCTAssertEqual(trips, 2, "the next change is")
    }

    // MARK: - Until clear with Sound on (item 204's codex-1)

    /// The room the real Sound tripwire hears, and the trips it reports.
    @MainActor private final class Room {
        var level = -60.0
        var soundTrips = 0
    }

    /// A watch with Sound on, in a room that has grown louder slowly: over the bar as measured from the calibrated quiet, reached
    /// under the bar at every tick, so Sound adapted as far as its limit and never tripped. The room stays at `steady`.
    private func watchInARoomGrownLouder(mode: CaptureMode, idle: TimeInterval = 0.3) throws
        -> (rig: Rig, audio: AudioMonitor, room: Room, steady: Double) {
        var timing = Self.fastTiming
        timing.untilClearIdle = idle
        timing.untilClearMax = 30
        let rig = makeRig(timing: timing) {
            $0.captureMode = mode
            $0.cameraPosition = .front
            $0.enabledSensors.insert(.audio)
        }
        let audio = try XCTUnwrap(rig.engine.monitors[.audio] as? AudioMonitor)
        let room = Room()
        audio.currentLevelForTesting = { room.level }
        audio.recordingForTesting = { true }
        audio.deactivateAudioSessionForTesting = {}
        let engineHears = audio.onTrip
        audio.onTrip = {
            room.soundTrips += 1
            engineHears?($0)
        }
        arm(rig)
        let quiet = audio.calibratedBaselineDB
        let steady = quiet + audio.marginDB + 4
        let tick = audio.queuedMeterTickForTesting(calibration: false)
        room.level = quiet
        while room.level < steady {
            room.level += 0.05
            tick()
        }
        for _ in 0..<500 { tick() }
        XCTAssertEqual(room.soundTrips, 0, "a slow rise is no trip")
        return (rig, audio, room, steady)
    }

    /// The real motion tripwire fires on a phone picked up.
    private func tripMotion(_ rig: Rig) throws {
        let motion = try XCTUnwrap(rig.engine.monitors[.motion] as? MotionMonitor)
        motion.startWatchingForTesting(at: Date(), restingGravity: Self.pose(tilted: 0))
        motion.sampleForTesting(gravity: Self.pose(tilted: 60), accel: 1, at: Date())
    }

    /// Codex's codex-1 on 08931e5: Sound's re-arm threw away the level it had adapted to, so each look of the clip's loop made
    /// an unchanged room that had grown louder slowly trip, and a still phone's clip ran to its ceiling. A room at a level Sound
    /// has taken in is quiet.
    func testAnUntilClearClipEndsInARoomThatGrewLouderSlowly() throws {
        let (rig, _, room, _) = try watchInARoomGrownLouder(mode: .untilClear)
        try tripMotion(rig)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 5), "a steady room is quiet: the idle threshold ends the clip")
        XCTAssertEqual(room.soundTrips, 0, "the unchanged room never tripped")
        rig.engine.disarm()
    }

    /// Guard: a sound above the bar still holds the clip open, for as long as it lasts: something is audibly going on. Back at the
    /// steady level, the idle threshold ends the clip.
    func testASoundAboveTheBarStillHoldsAClipOpen() throws {
        let (rig, audio, room, steady) = try watchInARoomGrownLouder(mode: .untilClear, idle: 0.6)
        try tripMotion(rig)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        room.level = audio.calibratedBaselineDB + 12 + audio.marginDB + 6   // over the bar at its adapted limit of 12 dB
        let started = Date()
        pump(until: { Date().timeIntervalSince(started) >= 1.5 }, timeout: 3)
        XCTAssertEqual(rig.camera.clipEnds, 0, "a sound over the bar holds the clip open")
        XCTAssertGreaterThan(room.soundTrips, 1, "it counts as activity at look after look")
        room.level = steady
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 }, timeout: 5), "back at the steady level, the clip ends")
        rig.engine.disarm()
    }

    /// The response's end re-armed Sound the same way, so the unchanged room raised another event once the watch was back.
    func testARoomThatGrewLouderSlowlyRaisesNothingAfterAResponse() throws {
        let (rig, _, room, _) = try watchInARoomGrownLouder(mode: .photo)
        try tripMotion(rig)
        XCTAssertTrue(pump(until: { !rig.camera.stills.isEmpty }, timeout: 3), "the photo")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3), "the response ends")
        let back = Date()
        pump(until: { Date().timeIntervalSince(back) >= 1 }, timeout: 2)
        XCTAssertEqual(room.soundTrips, 0, "the unchanged room raised nothing")
        rig.engine.disarm()
    }

    /// Guard: the refractory sweep's re-arm still resets what Sound adapted to: no trigger has fired there, and a slow ramp
    /// walked up under the bar must not keep its gain through a trip that aged out.
    func testTheRefractorySweepsReArmStillResetsWhatSoundAdaptedTo() throws {
        let (rig, audio, room, _) = try watchInARoomGrownLouder(mode: .photo)
        audio.rearm()
        XCTAssertTrue(pump(until: { room.soundTrips >= 1 }, timeout: 2), "the level is over the calibrated bar, and the reset shows it")
        rig.engine.disarm()
    }

    /// Codex's note on 08931e5: nothing pinned what the fix's own comment says of a slow mover. Turning too slowly to count as
    /// activity ends the clip, and the armed watch then measures from where the clip left the phone, and trips on the same drift.
    func testASlowMoverEndsAClipAndTheArmedWatchTripsOnThemAfresh() throws {
        let (rig, motion) = try clipStartedByTheMotionTripwire()
        var angle = 60.0
        XCTAssertTrue(pump(until: {
            angle += 0.02
            motion.sampleForTesting(gravity: Self.pose(tilted: angle), at: Date())
            return rig.camera.clipEnds == 1
        }, timeout: 5), "too slow to count as activity, the clip ends")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3), "the response ends")
        var trips = 0
        let engineHears = motion.onTrip
        motion.onTrip = {
            trips += 1
            engineHears?($0)
        }
        XCTAssertTrue(pump(until: {
            angle += 0.1
            motion.sampleForTesting(gravity: Self.pose(tilted: angle), at: Date())
            return trips > 0
        }, timeout: 5), "the armed watch trips on the same drift")
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

    /// A re-warm after a runtime error waits while a flood, blackout or retry capture holds the camera, as it already
    /// waits for a trip's own capture (item 180's A12). The re-warm when nothing holds it: the test above.
    func testARuntimeErrorDoesNotRewarmWhileACadenceCaptureHoldsTheCamera() {
        let rig = makeRig { $0.cameraPosition = .front; $0.cameraReadiness = .instant }   // always warm
        arm(rig)
        rig.engine.tripResponder.cadenceCaptureBusy = true   // a flood, blackout or retry capture in flight
        let warmUpsBefore = rig.camera.warmUps.count
        rig.camera.onSessionEvent?(.runtimeError("media services were reset"))
        XCTAssertTrue(pump(until: { rig.store.events.contains { $0.stateChange == "cameraError" } }, timeout: 3),
                      "the failure is on the record")
        XCTAssertFalse(pump(until: { rig.camera.warmUps.count > warmUpsBefore }, timeout: 0.5),
                       "and no re-warm while the capture holds the camera")
        rig.engine.tripResponder.cadenceCaptureBusy = false
        rig.engine.disarm()
    }

    /// The end of an interruption re-warms the camera, but not while a flood, blackout or retry capture holds it (item
    /// 180's A12).
    func testAnInterruptionsEndDoesNotRewarmWhileACadenceCaptureHoldsTheCamera() {
        let rig = makeRig { $0.cameraPosition = .front; $0.cameraReadiness = .instant }   // always warm
        arm(rig)
        rig.camera.onSessionEvent?(.interrupted(.anotherApp))
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2))
        var warmUpsBefore = rig.camera.warmUps.count
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.camera.warmUps.count > warmUpsBefore }, timeout: 3),
                      "the control: with nothing holding the camera, the end of an interruption re-warms it")

        rig.engine.tripResponder.cadenceCaptureBusy = true   // a flood, blackout or retry capture in flight
        rig.camera.onSessionEvent?(.interrupted(.anotherApp))
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice != nil }, timeout: 2))
        warmUpsBefore = rig.camera.warmUps.count
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.engine.cameraNotice == nil }, timeout: 2), "the interruption ended")
        XCTAssertFalse(pump(until: { rig.camera.warmUps.count > warmUpsBefore }, timeout: 0.5),
                       "and no re-warm while the capture holds the camera")
        rig.engine.tripResponder.cadenceCaptureBusy = false
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

    private func bothRig(mode: CaptureMode = .photo, supportsBoth: Bool = true) -> Rig {
        let rig = makeRig { $0.captureMode = mode; $0.cameraPosition = .both; $0.illumination = .off }
        rig.camera.supportsMultiCam = supportsBoth
        return rig
    }

    private func bothEvent(_ rig: Rig) throws -> Event {
        arm(rig)
        rig.engine.handleTrip(.touch)
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && rig.store.events.contains { !$0.isStateChange }
        }, timeout: 8))
        return try XCTUnwrap(rig.store.events.first { !$0.isStateChange })
    }

    func testPartialBothCapturePersistsMissingFrontAndKeepsRear() throws {
        let rig = bothRig()
        rig.camera.omittedBothCameras = ["front"]
        let event = try bothEvent(rig)
        XCTAssertNil(event.mediaFilename)
        XCTAssertNotNil(event.secondaryMediaFilename)
        XCTAssertNil(event.captureFailure)
        XCTAssertEqual(event.captureFailuresByCamera, ["front": "captureFailed"])
        XCTAssertFalse(event.captureFailureMessages.contains { $0.contains("came back") })
    }

    func testPartialBothCapturePersistsMissingRearAndKeepsFront() throws {
        let rig = bothRig()
        rig.camera.omittedBothCameras = ["rear"]
        let event = try bothEvent(rig)
        XCTAssertNotNil(event.mediaFilename)
        XCTAssertNil(event.secondaryMediaFilename)
        XCTAssertEqual(event.captureFailuresByCamera, ["rear": "captureFailed"])
    }

    func testBothCaptureReportsSecondaryStorageFailureWithoutLosingPrimary() throws {
        let rig = bothRig(mode: .clip3)
        rig.camera.invalidBothClipFiles = ["rear"]
        let event = try bothEvent(rig)
        XCTAssertNotNil(event.mediaFilename)
        XCTAssertNil(event.secondaryMediaFilename)
        XCTAssertNil(event.captureFailure)
        XCTAssertEqual(event.captureFailuresByCamera, ["rear": "storageFailed", "front": "clipUnverified"])
        XCTAssertNotNil(rig.engine.cameraNotice)
    }

    func testBothCaptureReportsPrimaryStorageFailureWithoutCallingRearARetry() throws {
        let rig = bothRig(mode: .clip3)
        rig.camera.invalidBothClipFiles = ["front"]
        let event = try bothEvent(rig)
        XCTAssertNil(event.mediaFilename)
        XCTAssertNotNil(event.secondaryMediaFilename)
        XCTAssertNil(event.captureFailure, "the rear succeeded on the original attempt")
        XCTAssertEqual(event.captureFailuresByCamera, ["front": "storageFailed", "rear": "clipUnverified"])
        XCTAssertFalse(event.captureFailureMessages.contains { $0.contains("came back") })
    }

    func testBothUnsupportedDeviceRecordsMissingRearCoverage() throws {
        let rig = bothRig(supportsBoth: false)
        let event = try bothEvent(rig)
        XCTAssertNotNil(event.mediaFilename)
        XCTAssertEqual(event.captureFailuresByCamera, ["rear": "cameraUnavailable"])
    }

    func testBothFailureHistorySurvivesRetryAndCoalescedCount() throws {
        let rig = bothRig()
        rig.camera.omittedBothCameras = ["front", "rear"]
        rig.camera.interruptionReasonValue = .anotherApp
        let original = try bothEvent(rig)
        var updated = original
        updated.sustainedCount = 7
        rig.store.update(updated)
        rig.camera.interruptionReasonValue = nil
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: {
            rig.store.events.first { $0.id == original.id }?.mediaFilename != nil
        }, timeout: 3))
        let retried = try XCTUnwrap(rig.store.events.first { $0.id == original.id })
        XCTAssertEqual(retried.sustainedCount, 7)
        XCTAssertEqual(retried.captureFailuresByCamera,
                       ["front": "interruptedByAnotherApp", "rear": "interruptedByAnotherApp"])
    }

    func testStorageWarningOutlivesTheInterruptionItReplaces() throws {
        let rig = bothRig(mode: .clip3)
        rig.camera.invalidBothClipFiles = ["rear"]
        rig.camera.onBothCaptureEnd = { [weak camera = rig.camera] in
            camera?.onSessionEvent?(.interrupted(.anotherApp))
        }
        _ = try bothEvent(rig)
        XCTAssertTrue(rig.engine.cameraNotice?.contains("saved") == true)
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(rig.engine.cameraNotice?.contains("saved") == true,
                      "ending an interruption must not erase the later storage warning")
    }

    func testStorageFailureFinishingAfterDisarmDoesNotWarnOnHome() throws {
        let rig = bothRig(mode: .clip3)
        rig.camera.invalidBothClipFiles = ["rear"]
        rig.camera.onBothCaptureEnd = { [weak engine = rig.engine] in engine?.disarm() }
        arm(rig)
        rig.engine.handleTrip(.touch)
        XCTAssertTrue(pump(until: {
            rig.engine.state == .disarmed && rig.store.events.contains { !$0.isStateChange && $0.mediaFilename != nil }
        }, timeout: 8))
        let event = try XCTUnwrap(rig.store.events.first { !$0.isStateChange })
        XCTAssertEqual(event.captureFailuresByCamera, ["rear": "storageFailed", "front": "clipUnverified"])
        XCTAssertNil(rig.engine.cameraNotice, "the durable event records it; disarmed Home stays clear")
    }

    // MARK: - Wiring: the engine hands each rule its real inputs (test-suite audit, P5)

    // Each rule below is tested as a pure function elsewhere; these drive the engine, so that
    // passing a rule a fixed or wrong input is noticed too (the audit's wiring mutants).

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// F4: in Siren mode the first capture is a still even with clips chosen, so the alarm does
    /// not wait behind a clip (captureModeForNow; ME90).
    func testSirenModesFirstCaptureIsAStillEvenWithClipsChosen() {
        let rig = makeRig { $0.responseMode = .siren; $0.captureMode = .clip3; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count + rig.camera.clips.count >= 1 }, timeout: 3), "a capture starts")
        XCTAssertEqual(rig.camera.stills.count, 1, "a still")
        XCTAssertTrue(rig.camera.clips.isEmpty, "not a clip")
        rig.engine.disarm()
    }

    /// The blackout canary reads a signal loss as jamming only while the phone lies still: one
    /// that has just moved is being carried away, the tamper path's case (shouldEscalateBlackout's
    /// `stationary`; ME91).
    func testASignalLossRightAfterThePhoneMovedIsNotJamming() {
        var timing = Self.fastTiming
        timing.blackoutDebounce = 0.2
        let rig = makeRig(timing: timing) { $0.captureMode = .photo; $0.cameraPosition = .front }
        rig.engine.evidencePushForTesting = { _ in .init(syncState: .synced, metaFailureWasInterference: nil) }
        rig.engine.simulateConnectivityForTesting(online: true)
        arm(rig)
        rig.engine.handleTrip(.motion)   // the phone moves
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 && rig.engine.state == .armed }, timeout: 3))
        rig.engine.simulateConnectivityForTesting(online: false)
        settle(1)   // five times the debounce
        XCTAssertNil(rig.engine.escalation, "moved inside the stationary window: not jamming")
        rig.engine.disarm()
    }

    /// A trip in the first two seconds of a signal loss does not go loud: a Wi-Fi to cellular
    /// hand-off can drop the path for well under a second (shouldGoLoudOnFailedExfil's
    /// `offlineFor`; ME92).
    func testATripInTheFirstSecondsOfASignalLossDoesNotGoLoud() {
        var timing = Self.fastTiming
        timing.blackoutDebounce = 60   // keeps the canary out of it
        let rig = makeRig(timing: timing) {
            $0.captureMode = .photo; $0.cameraPosition = .front; $0.cameraReadiness = .batterySaver
        }
        rig.engine.evidencePushForTesting = { _ in .init(syncState: .localOnly, metaFailureWasInterference: nil) }
        rig.engine.simulateConnectivityForTesting(online: true)
        arm(rig)
        rig.engine.simulateConnectivityForTesting(online: false)
        rig.engine.handleTrip(.touch)   // at once: inside the hand-off filter
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 && rig.engine.state == .armed }, timeout: 3))
        settle(0.3)
        XCTAssertNil(rig.engine.escalation, "a signal loss under two seconds old is not yet jamming")
        rig.engine.disarm()
    }

    /// An upload that fails with interference after the owner has disarmed never goes loud: the
    /// watch is over (pushFailureResponse's `watching`; ME104).
    func testAnInterferedUploadThatEndsAfterTheDisarmStaysQuiet() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        var entered = false
        var release = false
        rig.engine.evidencePushForTesting = { _ in
            entered = true
            while !release { try? await Task.sleep(for: .milliseconds(10)) }
            return .init(syncState: .localOnly, metaFailureWasInterference: true)
        }
        rig.engine.simulateConnectivityForTesting(online: true)
        arm(rig)
        rig.engine.handleTrip(.touch)
        XCTAssertTrue(pump(until: { entered }, timeout: 3), "the upload is under way")
        rig.engine.disarm()
        release = true
        settle(0.5)
        XCTAssertNil(rig.engine.escalation, "no alarm after the disarm")
        XCTAssertFalse(rig.engine.alertActive)
    }

    /// A ramping siren keeps the alert up through its hold and fade on top of the alert time, so
    /// the alarm is not cut off while it is still building (alertDismissInterval's
    /// `sirenRamping`; ME105).
    func testARampingSirenKeepsTheAlertUpPastTheAlertTime() {
        let rig = makeRig { $0.responseMode = .siren; $0.sirenRampUp = true; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 3), "the alarm starts")
        settle(Self.fastTiming.alertDuration + 0.7)
        XCTAssertTrue(rig.engine.alertActive, "still up: the ramp adds its 20 s")
        rig.engine.disarm()
    }

    /// With an empty log, the launch pull asks for the whole log (its limit), not one page
    /// (launchSyncLimit's `localEventCount`; ME106). A fresh store also owes a restore, which asks
    /// for the whole log by itself, so the restore is marked done first: the empty log decides.
    func testTheLaunchPullOfAnEmptyLogAsksForTheWholeLog() {
        let rig = makeRig()
        rig.store.completeRestore()   // before the Pro check's answer starts the pull
        XCTAssertNil(rig.store.restoreOwedSince)
        var limits: [Int] = []
        rig.engine.cloudFetchForTesting = { limit in limits.append(limit); return ([], true) }
        XCTAssertTrue(pump(until: { !limits.isEmpty }, timeout: 3), "the launch pull runs once the Pro check answers")
        XCTAssertEqual(limits.first, EventStore.maxEvents)
    }

    /// The automatic purge waits an hour after an attempt: a launch ten minutes after one does not
    /// start another (autoPurgeDue; ME107).
    func testTheAutomaticPurgeDoesNotRunAgainSoonAfterAnAttempt() async {
        let attemptKey = "com.malinois.cloudRetention.lastAttempt"
        let runKey = "com.malinois.cloudRetention.lastRun"
        let attempted = Date().addingTimeInterval(-600)
        UserDefaults.standard.removeObject(forKey: runKey)
        UserDefaults.standard.set(attempted, forKey: attemptKey)
        defer {
            UserDefaults.standard.removeObject(forKey: attemptKey)
            UserDefaults.standard.removeObject(forKey: runKey)
        }
        let rig = makeRig { $0.cloudRetention = .months3 }
        await rig.engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(UserDefaults.standard.object(forKey: attemptKey) as? Date, attempted,
                       "ten minutes after an attempt, no new attempt is stamped")
    }

    /// A failed push registration matters only while Cross-device alerts are on: with them off,
    /// Home says nothing (notificationNotice's `notifyOtherDevices`; ME99).
    func testThePushRegistrationNoticeFollowsTheCrossDeviceSwitch() async {
        RemotePushCoordinator.shared.registrationFailed = true
        defer { RemotePushCoordinator.shared.registrationFailed = false }
        let rig = makeRig { $0.notifyOtherDevices = false }
        await rig.engine.refreshNotificationHealth()
        XCTAssertNil(rig.engine.notificationNotice, "alerts off: a failed registration is not worth a notice")
        rig.settings.notifyOtherDevices = true
        await rig.engine.refreshNotificationHealth()
        XCTAssertNotNil(rig.engine.notificationNotice, "alerts on: it is")
    }

    /// A background push on the free tier reports "no data", never "failed", whatever the last
    /// fetch did: the free tier has no iCloud to pull from (pushResult's `pro`; ME100).
    func testABackgroundPushOnTheFreeTierNeverReportsAFailedFetch() async {
        let cloud = CloudExfiltrator()
        _ = await cloud.fetchRecentEvents()   // no account here: the fetch fails
        XCTAssertTrue(cloud.lastFetchFailed)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: EventStore(), cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: Self.fastTiming))
        let result = await engine.handleRemotePush()
        XCTAssertEqual(result, .noData)
    }

    /// Sixteen triggers inside the flood window, from four tripwires taking turns so none passes
    /// its own bar, are a flood: an attacker alternating sources cannot stay under the
    /// per-tripwire count (isAggregateFlood; ME97).
    func testSixteenTriggersFromAlternatingTripwiresAreAFlood() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front }
        rig.engine.evidencePushForTesting = { _ in .init(syncState: .synced, metaFailureWasInterference: nil) }
        arm(rig)
        let sensors: [SensorType] = [.motion, .power, .proximity, .touch]
        for index in 0..<MonitoringEngine.aggregateFloodThreshold {   // fifteen ordinary triggers
            rig.engine.handleTrip(sensors[index % sensors.count])
            XCTAssertTrue(pump(until: { rig.engine.state == .armed && rig.camera.stills.count == index + 1 }, timeout: 3),
                          "trigger \(index + 1) is handled on its own")
        }
        XCTAssertNil(rig.engine.escalation, "fifteen is not yet a flood")
        rig.engine.handleTrip(.motion)   // the sixteenth
        XCTAssertTrue(pump(until: { rig.engine.escalation == .flood }, timeout: 3), "the sixteenth starts a flood")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        rig.engine.handleTrip(.power)   // the seventeenth joins it
        settle(0.2)
        let incidents = rig.store.events.filter { !$0.isStateChange && !$0.triggeredSensors.isEmpty }
        XCTAssertEqual(incidents.count, 16, "the seventeenth is counted into the flood's record, not a record of its own")
        rig.engine.disarm()
    }

    /// Arming under Guided Access with the camera never asked for says so: iOS cannot show its
    /// question while Guided Access is on (cameraAskBlocked's `guidedAccessOn`; ME110).
    func testArmingUnderGuidedAccessWithTheCameraNeverAskedSaysSo() {
        let rig = makeRig()
        rig.camera.videoPermission = .notDetermined
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        XCTAssertTrue(rig.engine.cameraAskBlockedByGuidedAccess)
        rig.engine.disarm()
    }
}
