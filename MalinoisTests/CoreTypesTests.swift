//
//  CoreTypesTests.swift
//  MalinoisTests
//

import XCTest
import UIKit
@testable import Malinois

final class CoreTypesTests: XCTestCase {

    func testClockStringFormatting() {
        XCTAssertEqual(TimeInterval(9).clockString, "0:09")
        XCTAssertEqual(TimeInterval(65).clockString, "1:05")
        XCTAssertEqual(TimeInterval(3661).clockString, "1:01:01")
    }

    func testCaptureModeClipProperties() {
        XCTAssertFalse(CaptureMode.photo.isClip)
        XCTAssertTrue(CaptureMode.clip3.isClip)
        XCTAssertTrue(CaptureMode.untilClear.isClip)
        XCTAssertEqual(CaptureMode.clip3.fixedDuration, 3)
        XCTAssertEqual(CaptureMode.clip5.fixedDuration, 5)
        XCTAssertNil(CaptureMode.untilClear.fixedDuration, "until-clear length is dynamic")
        XCTAssertNil(CaptureMode.photo.fixedDuration)
    }

    func testTripwiresExcludeCamera() {
        XCTAssertFalse(SensorType.tripwires.contains(.camera), "camera is the capture device, not a tripwire")
        XCTAssertTrue(SensorType.tripwires.contains(.motion))
        XCTAssertTrue(SensorType.tripwires.contains(.touch))
    }

    // MARK: - Trigger correlation (the central "should we fire?" logic)

    func testAnyModeFiresOnAnySingleSensor() {
        XCTAssertFalse(TriggerMode.any.shouldFire(for: []))
        XCTAssertTrue(TriggerMode.any.shouldFire(for: [.motion]))
        XCTAssertTrue(TriggerMode.any.shouldFire(for: [.audio]))
    }

    /// Every tripwire fires on its own now that "Motion-confirmed" is gone — no sensor
    /// requires corroboration.
    func testEverySensorFiresSoloInAnyMode() {
        for sensor in SensorType.tripwires {
            XCTAssertTrue(TriggerMode.any.shouldFire(for: [sensor]),
                          "\(sensor.rawValue) must fire on its own")
        }
        XCTAssertFalse(TriggerMode.any.shouldFire(for: []), "no trips, no trigger")
    }

    // MARK: - Sensor threshold / sensitivity mappings (pin the README table)

    @MainActor
    func testMotionThresholdsMatchReadme() {
        let m = MotionMonitor()
        m.sensitivity = .high
        XCTAssertEqual(m.tiltThresholdDegrees, 1.5); XCTAssertEqual(m.spikeMultiplier, 3.0)
        m.sensitivity = .medium
        XCTAssertEqual(m.tiltThresholdDegrees, 3.0); XCTAssertEqual(m.spikeMultiplier, 5.0)
        m.sensitivity = .low
        XCTAssertEqual(m.tiltThresholdDegrees, 6.0); XCTAssertEqual(m.spikeMultiplier, 9.0)
    }

    @MainActor
    func testAudioMarginsMatchReadme() {
        let a = AudioMonitor()
        a.sensitivity = .high;   XCTAssertEqual(a.marginDB, 8)
        a.sensitivity = .medium; XCTAssertEqual(a.marginDB, 14)
        a.sensitivity = .low;    XCTAssertEqual(a.marginDB, 22)
    }

    func testAudioBaselineClampCapsPoisoning() {
        // Below the cap, the proposed value passes through.
        XCTAssertEqual(AudioMonitor.clampedRolling(-45, baseline: -50, maxDrift: 12), -45)
        // A ramp trying to walk the baseline far above calibrated is capped.
        XCTAssertEqual(AudioMonitor.clampedRolling(-10, baseline: -50, maxDrift: 12), -38)
        // Exactly at the cap.
        XCTAssertEqual(AudioMonitor.clampedRolling(-38, baseline: -50, maxDrift: 12), -38)
    }

    /// F-07: the WARM-UP baseline is now clamped too, so a noisy warm-up window (or the
    /// window that recurs after a siren) can't set the trip bar past calibrated + drift.
    func testWarmupBaselineIsClamped() {
        let baseline = -50.0, drift = 12.0
        // A loud warm-up: median well above the calibrated quiet.
        let noisyMedian = AudioMonitor.median([-20, -18, -22, -19, -21]) ?? baseline
        XCTAssertEqual(AudioMonitor.clampedRolling(noisyMedian, baseline: baseline, maxDrift: drift),
                       baseline + drift, accuracy: 0.001, "warm-up baseline capped at calibrated + drift")
    }

    /// F-06: a noisy calibration can't set an unreachable audio baseline.
    func testAudioCalibratedBaselineCeiling() {
        XCTAssertEqual(AudioMonitor.clampedCalibratedBaseline(-55), -55, "a quiet room passes through")
        XCTAssertEqual(AudioMonitor.clampedCalibratedBaseline(-10),
                       AudioMonitor.maxCalibratedBaselineDB, "a loud room is capped")
    }

    /// F-06: the learned motion noise floor is clamped both below (never zero) and above
    /// (a shaky calibration can't set an unreachable spike threshold).
    func testMotionNoiseFloorClamp() {
        XCTAssertEqual(MotionMonitor.clampedNoiseFloor(0.001), 0.005, accuracy: 1e-9, "floor")
        XCTAssertEqual(MotionMonitor.clampedNoiseFloor(0.2),
                       MotionMonitor.maxNoiseFloor, accuracy: 1e-9, "ceiling")
        XCTAssertEqual(MotionMonitor.clampedNoiseFloor(0.02), 0.02, accuracy: 1e-9, "in-range")
    }

    /// R-01: after a post-trigger re-baseline moves BOTH anchors to the device's current
    /// pose, a stationary device must NOT keep tripping — but a slow ratchet (anchors left
    /// at calibration while the pose drifts) must still fire.
    func testTiltTripsSettlesAfterRebaselineButStillCatchesRatchet() {
        let flat = (x: 0.0, y: 0.0, z: -1.0)
        let leaned = (x: 0.0, y: -0.5, z: -0.8660254)   // 30° from flat
        XCTAssertEqual(MotionMonitor.tiltDegrees(leaned, flat), 30, accuracy: 0.01)

        // The R-01 bug: resting re-baselined to `leaned`, but the session anchor still at
        // `flat` → trips forever while perfectly stationary.
        XCTAssertTrue(MotionMonitor.tiltTrips(current: leaned, resting: leaned, session: flat,
                                              tiltThreshold: 8, sessionLimit: 15))
        // The fix: both anchors advanced to the resting pose → a stationary device settles.
        XCTAssertFalse(MotionMonitor.tiltTrips(current: leaned, resting: leaned, session: leaned,
                                               tiltThreshold: 8, sessionLimit: 15))
        // Anti-ratchet preserved: anchors held at calibration, pose drifted → still trips.
        XCTAssertTrue(MotionMonitor.tiltTrips(current: leaned, resting: flat, session: flat,
                                              tiltThreshold: 8, sessionLimit: 15))
    }

    /// F-20: unplug detection fails CLOSED across an intermediate `.unknown`.
    func testPowerChangeTripsBothDirectionsAndFailsClosedAcrossUnknown() {
        // Unplugged: powered (charging/full) → on battery.
        XCTAssertTrue(PowerMonitor.powerChangeTrips(state: .unplugged, lastKnownPowered: true))
        // Plugged in: on battery → powered. This is the new direction (a laptop / forensic
        // tool connected to a device that was armed on battery).
        XCTAssertTrue(PowerMonitor.powerChangeTrips(state: .charging, lastKnownPowered: false))
        XCTAssertTrue(PowerMonitor.powerChangeTrips(state: .full, lastKnownPowered: false))

        // Fail closed across an intermediate `.unknown`: the caller keeps `lastKnownPowered`
        // at the last KNOWN value, so `.full → .unknown → .unplugged` still trips because
        // the `.unknown` sample never overwrote the `true` baseline (F-20).
        XCTAssertFalse(PowerMonitor.powerChangeTrips(state: .unknown, lastKnownPowered: true),
                       "an .unknown sample itself never trips")

        // No baseline yet (arming resolve) → establishing it isn't a change.
        XCTAssertFalse(PowerMonitor.powerChangeTrips(state: .unplugged, lastKnownPowered: nil))
        XCTAssertFalse(PowerMonitor.powerChangeTrips(state: .charging, lastKnownPowered: nil))
        // No powered-ness change → no trip (unplugged↔unplugged, or charging→full).
        XCTAssertFalse(PowerMonitor.powerChangeTrips(state: .unplugged, lastKnownPowered: false))
        XCTAssertFalse(PowerMonitor.powerChangeTrips(state: .full, lastKnownPowered: true))

        // poweredness classification.
        XCTAssertEqual(PowerMonitor.poweredness(.charging), true)
        XCTAssertEqual(PowerMonitor.poweredness(.full), true)
        XCTAssertEqual(PowerMonitor.poweredness(.unplugged), false)
        XCTAssertNil(PowerMonitor.poweredness(.unknown))
    }

    /// BACKLOG 5: motion is the only continuous-stream tripwire, so silence past the threshold
    /// means it has stalled — measured from the last sample, or from the watch start if nothing
    /// has ever arrived (a stream that never starts is as deaf as one that stopped).
    func testMotionStallDetection() {
        let t0 = Date()
        XCTAssertFalse(MotionMonitor.isStalled(lastSample: nil, startedAt: t0, now: t0.addingTimeInterval(2)),
                       "fresh watch inside the threshold is not a stall")
        XCTAssertTrue(MotionMonitor.isStalled(lastSample: nil, startedAt: t0, now: t0.addingTimeInterval(3.5)),
                      "no first sample past the threshold is a stall")
        XCTAssertFalse(MotionMonitor.isStalled(lastSample: t0.addingTimeInterval(100), startedAt: t0,
                                               now: t0.addingTimeInterval(101)),
                       "a recent sample is healthy no matter how long the watch has run")
        XCTAssertTrue(MotionMonitor.isStalled(lastSample: t0.addingTimeInterval(100), startedAt: t0,
                                              now: t0.addingTimeInterval(104)),
                      "last sample past the threshold is a stall")
    }

    // MARK: - Vision detector (BACKLOG 16)

    private func flat(_ v: UInt8) -> VisionFrame {
        VisionFrame(luma: [UInt8](repeating: v, count: VisionFrame.width * VisionFrame.height))
    }
    /// A flat frame with a rectangular region set to a different value.
    private func blob(base: UInt8, value: UInt8, fraction: Double) -> VisionFrame {
        var px = [UInt8](repeating: base, count: VisionFrame.width * VisionFrame.height)
        for i in 0..<Int(Double(px.count) * fraction) { px[i] = value }
        return VisionFrame(luma: px)
    }
    private func calibrated(on frame: VisionFrame, frames: Int = 5) -> VisionDetector {
        var d = VisionDetector()
        d.beginCalibration()
        for _ in 0..<frames { d.calibrate(frame) }
        d.endCalibration()
        return d
    }

    func testVisionCalibrationAndStillSceneIsQuiet() {
        var d = calibrated(on: flat(100))
        XCTAssertTrue(d.hasBaseline)
        XCTAssertEqual(d.noise, VisionDetector.minNoise, "a dead-still calibration clamps to the noise floor, not zero")
        XCTAssertEqual(d.evaluate(flat(100), tripFraction: 0.05), .ok(changed: 0))
    }

    /// The illegible-false-positive guard: a global brightness change (exposure settling, lights
    /// dimming, the capture flash) changes every pixel by the same amount — and must NOT trip.
    func testVisionIgnoresGlobalBrightnessChange() {
        var d = calibrated(on: flat(100))
        XCTAssertEqual(d.evaluate(flat(160), tripFraction: 0.02), .ok(changed: 0), "+60 everywhere is not motion")
        XCTAssertEqual(d.evaluate(flat(30), tripFraction: 0.02), .ok(changed: 0), "-70 everywhere is not motion")
    }

    /// A local change — something entering part of the view — trips by sensitivity.
    func testVisionTripsOnLocalChangeBySensitivity() {
        var d = calibrated(on: flat(100))
        let small = blob(base: 100, value: 200, fraction: 0.03)   // 3% of the view
        if case .trip = d.evaluate(small, tripFraction: VisionDetector.tripFraction(for: .high)) {} else {
            XCTFail("3% of the view changing trips at HIGH sensitivity")
        }
        var d2 = calibrated(on: flat(100))
        if case .ok = d2.evaluate(small, tripFraction: VisionDetector.tripFraction(for: .medium)) {} else {
            XCTFail("3% does not trip at MEDIUM (5%)")
        }
        let big = blob(base: 100, value: 200, fraction: 0.20)
        var d3 = calibrated(on: flat(100))
        if case .trip = d3.evaluate(big, tripFraction: VisionDetector.tripFraction(for: .low)) {} else {
            XCTFail("20% of the view changing trips even at LOW (12%)")
        }
    }

    /// Anti-ratchet: creeping into frame below the per-frame threshold must not walk the
    /// rolling baseline along with you — the session anchor catches the cumulative change.
    func testVisionSessionAnchorCatchesSlowRatchet() {
        var d = calibrated(on: flat(100))
        var tripped = false
        // Raise 40% of the view by 2 luma per frame: each step is far below the pixel threshold
        // (>= 12), so the rolling comparison never sees motion — but after enough steps the
        // region differs from the calibrated anchor by more than the threshold.
        for step in 1...40 {
            let f = blob(base: 100, value: UInt8(100 + 2 * step), fraction: 0.40)
            if case .trip = d.evaluate(f, tripFraction: 0.05) { tripped = true; break }
        }
        XCTAssertTrue(tripped, "sub-threshold creep over 40% of the view must eventually trip via the session anchor")
    }

    /// The rolling baseline never drifts past the anchor's budget, even under sustained push.
    func testVisionRollingBaselineIsClamped() {
        XCTAssertEqual(VisionDetector.clampedRolling(90, anchor: 0, maxDrift: 30), 30)
        XCTAssertEqual(VisionDetector.clampedRolling(-90, anchor: 0, maxDrift: 30), -30)
        XCTAssertEqual(VisionDetector.clampedRolling(10, anchor: 0, maxDrift: 30), 10)
    }

    /// After a real trigger the scene is adopted (someone now stands there) so it doesn't trip
    /// forever — their next movement trips again. Mirrors motion's re-pose on trigger.
    func testVisionRebaselineAdoptsChangedScene() {
        var d = calibrated(on: flat(100))
        let changed = blob(base: 100, value: 200, fraction: 0.20)
        if case .trip = d.evaluate(changed, tripFraction: 0.05) {} else { XCTFail("should trip first") }
        d.rebaseline()
        XCTAssertEqual(d.evaluate(changed, tripFraction: 0.05), .ok(changed: 0), "same scene after rebaseline is quiet")
        if case .trip = d.evaluate(flat(100), tripFraction: 0.05) {} else { XCTFail("leaving the scene is movement again") }
    }

    /// With no calibration frames (camera was cold), the first watched frame seeds the baseline.
    func testVisionSeedsFromFirstFrameWithoutCalibration() {
        var d = VisionDetector()
        d.beginCalibration(); d.endCalibration()
        XCTAssertFalse(d.hasBaseline)
        XCTAssertEqual(d.evaluate(flat(100), tripFraction: 0.05), .calibrating)
        XCTAssertTrue(d.hasBaseline)
        XCTAssertEqual(d.evaluate(flat(100), tripFraction: 0.05), .ok(changed: 0))
    }

    func testVisionDownsampleAverages() {
        let w = 64, h = 48
        var plane = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { plane[y * w + x] = x < 32 ? 40 : 200 } }   // left half dark
        let frame = plane.withUnsafeBufferPointer {
            VisionDetector.downsample(plane: $0, width: w, height: h, bytesPerRow: w)
        }
        XCTAssertEqual(frame.count, VisionFrame.width * VisionFrame.height)
        XCTAssertEqual(frame.luma[0], 40, "left edge is dark")
        XCTAssertEqual(frame.luma[VisionFrame.width - 1], 200, "right edge is bright")
    }

    /// The per-row "on but not running" warning fires only for an enabled Pro tripwire on the
    /// free tier. Getting any of the three conditions wrong is a visible bug: warning on a
    /// free sensor is noise, and failing to warn is the original defect — a toggle that reads
    /// ON while the sensor is clamped off at arm time.
    func testIsInertWithoutProRequiresEnabledProTripwireAndNoEntitlement() {
        XCTAssertTrue(SensorType.audio.isInertWithoutPro(enabled: true, pro: false),
                      "enabled Pro tripwire without Pro is inert and must be surfaced")
        XCTAssertTrue(SensorType.vision.isInertWithoutPro(enabled: true, pro: false))
        XCTAssertFalse(SensorType.audio.isInertWithoutPro(enabled: true, pro: true),
                       "entitled — it actually runs")
        XCTAssertFalse(SensorType.audio.isInertWithoutPro(enabled: false, pro: false),
                       "switched off — nothing to warn about")
        for free in SensorType.tripwires where !SensorType.proTripwires.contains(free) {
            XCTAssertFalse(free.isInertWithoutPro(enabled: true, pro: false),
                           "\(free.rawValue) is free and must never be reported inert")
        }
    }

    // MARK: - The vision row must not blame the wrong thing (BACKLOG 16)

    /// "No frames" has two very different causes, and the app already had copy for only one of
    /// them. With the camera cold, telling the owner to plug in is correct. With the camera
    /// warm and the tap not delivering — the multi-cam session, or a connection that attached
    /// and went inactive — the same words are a wrong answer to the question they are actually
    /// asking, which is "is the tripwire I turned on running?"
    @MainActor
    func testVisionRowDistinguishesAColdCameraFromATapThatIsNotRunning() {
        let monitor = VisionMonitor()
        XCTAssertEqual(monitor.liveReading()?.value, "No frames",
                       "camera cold — the arming screen already explains this case")

        monitor.tapActive = false
        XCTAssertEqual(monitor.liveReading()?.value, "Not running",
                       "a tripwire the owner enabled and is not getting must not read as a battery hint")
        XCTAssertEqual(monitor.liveReading()?.hot, false)
    }

    /// The geometry the detector actually receives on device: the tap takes whatever the
    /// session delivers — 1920×1080 on the 17 Pro — because asking for scaled buffers broke
    /// still capture (see `CameraController`'s note). Pinned because `downsample` returns an
    /// all-black frame for any source smaller than its 32×24 grid, and a black grid reads as
    /// "nothing ever moves" rather than as a failure.
    func testVisionDownsamplesFullSizeSessionBuffers() {
        let w = 1920, h = 1080
        XCTAssertGreaterThanOrEqual(w, VisionFrame.width)
        XCTAssertGreaterThanOrEqual(h, VisionFrame.height)

        var plane = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { plane[y * w + x] = x < w / 2 ? 40 : 200 } }
        let frame = plane.withUnsafeBufferPointer {
            VisionDetector.downsample(plane: $0, width: w, height: h, bytesPerRow: w)
        }
        XCTAssertEqual(frame.count, VisionFrame.width * VisionFrame.height)
        XCTAssertEqual(frame.luma[0], 40, "left edge is dark")
        XCTAssertEqual(frame.luma[VisionFrame.width - 1], 200, "right edge is bright")
        XCTAssertFalse(frame.luma.allSatisfy { $0 == 0 }, "a black grid would silently never trip")
    }

    // MARK: - Vision in multi-cam "Both" mode (BACKLOG 16 follow-up)

    /// The direction of this decision is the whole point, so it is pinned rather than left to
    /// a reader of the call site: when the multi-cam session can't afford a third output, the
    /// **tripwire** is dropped and the capture is kept. Never the reverse. An over-budget
    /// session drops connections or refuses to run, so getting this backwards would trade a
    /// shipped capture feature — the actual product — for one of several ways to start one.
    func testAnOverBudgetMultiCamSessionKeepsTheCaptureAndDropsTheTripwire() {
        XCTAssertTrue(CameraController.visionTapFitsMultiCam(hardwareCost: 0.5))
        XCTAssertTrue(CameraController.visionTapFitsMultiCam(hardwareCost: 1.0),
                      "exactly at budget is runnable")
        XCTAssertFalse(CameraController.visionTapFitsMultiCam(hardwareCost: 1.01),
                       "over budget the session can't run — drop the tap, keep Both working")
        XCTAssertFalse(CameraController.visionTapFitsMultiCam(hardwareCost: 2.0))
    }

    // MARK: - Proximity trips on the transition, not the state (BACKLOG 29)

    /// Found on device 2026-08-26: a phone placed face down — an ordinary covert placement —
    /// fired this tripwire the instant the watch went live, every time, on nothing. The sensor
    /// was permanently covered, and "covered" was being read as "an object just arrived".
    func testAlreadyCoveredAtRestIsNotATrip() {
        XCTAssertFalse(ProximityMonitor.shouldTrip(previous: true, current: true),
                       "a phone face down is at rest, and rest is not an intrusion")
        XCTAssertFalse(ProximityMonitor.shouldTrip(previous: false, current: false))
    }

    /// The gesture the sensor exists for: a hand arriving over a phone that was clear.
    func testSomethingComingNearIsATrip() {
        XCTAssertTrue(ProximityMonitor.shouldTrip(previous: false, current: true))
    }

    /// A pickup goes near→far. This sensor has never tripped on that and still doesn't — worth
    /// pinning so the asymmetry is a decision on the record rather than an oversight.
    func testSomethingLeavingIsNotATrip() {
        XCTAssertFalse(ProximityMonitor.shouldTrip(previous: true, current: false))
    }

    /// Until a resting state is seeded there is nothing to compare against, and the only honest
    /// answer is that nothing has changed. This is what stops a face-down phone tripping on the
    /// first notification after monitoring is enabled.
    func testNothingTripsBeforeARestingStateIsKnown() {
        XCTAssertFalse(ProximityMonitor.shouldTrip(previous: nil, current: true))
        XCTAssertFalse(ProximityMonitor.shouldTrip(previous: nil, current: false))
    }

    // MARK: - External review findings 9 and 12 (2026-08-26)

    /// F12: a calibration during which no frames arrive must leave the detector with NO
    /// baseline, not with the previous session's. `endCalibration` returns early when it has no
    /// frames, so clearing had to move to `beginCalibration` — otherwise the first frame of the
    /// new session is judged against a scene from a different session in a different place,
    /// which either trips instantly on nothing or sets a baseline so wrong it never trips.
    /// The camera failing to come up during the calibration window is an ordinary occurrence,
    /// not an exotic one.
    func testACalibrationThatGotNoFramesLeavesNoBaselineFromTheOldOne() {
        var d = VisionDetector()
        d.beginCalibration()
        for _ in 0..<5 { d.calibrate(VisionFrame(luma: [UInt8](repeating: 40, count: 32 * 24))) }
        d.endCalibration()
        XCTAssertTrue(d.hasBaseline, "a normal calibration does set one")

        d.beginCalibration()          // new session…
        d.endCalibration()            // …and not a single frame arrived
        XCTAssertFalse(d.hasBaseline, "the previous session's scene must not survive")

        let verdict = d.evaluate(VisionFrame(luma: [UInt8](repeating: 200, count: 32 * 24)),
                                 tripFraction: 0.1)
        XCTAssertEqual(verdict, .calibrating,
                       "with no baseline the honest verdict is 'not ready', not a trip")
    }

    /// F9: the multi-cam reuse decision forgot Vision, so turning the tripwire on without also
    /// changing capture mode reused a session that had no tap — the tripwire silently dead.
    /// Same divergence as the single-camera path had, found the same day the tap was added.
    func testMultiCamRebuildsWhenTheVisionTripwireIsTurnedOn() {
        func needed(configuredVision: Bool, wantVision: Bool) -> Bool {
            CameraController.multiCamNeedsReconfiguration(isConfigured: true,
                                                          configuredForClips: true, wantClips: true,
                                                          configuredVision: configuredVision,
                                                          wantVision: wantVision)
        }
        XCTAssertFalse(needed(configuredVision: false, wantVision: false), "nothing changed")
        XCTAssertTrue(needed(configuredVision: false, wantVision: true), "tap must be attached")
        XCTAssertTrue(needed(configuredVision: true, wantVision: false), "tap must be released")
        XCTAssertTrue(CameraController.multiCamNeedsReconfiguration(isConfigured: false,
                                                                    configuredForClips: true, wantClips: true,
                                                                    configuredVision: true, wantVision: true),
                      "an unconfigured session always needs building")
        XCTAssertTrue(CameraController.multiCamNeedsReconfiguration(isConfigured: true,
                                                                    configuredForClips: false, wantClips: true,
                                                                    configuredVision: true, wantVision: true),
                      "capture mode still forces a rebuild")
    }

    // MARK: - SF Symbol names must exist (fifth review R1.4, 2026-08-29)

    /// Every sensor icon must resolve in the system symbol set. An invalid name is not an error
    /// anywhere — SwiftUI renders nothing and the runtime logs once — so a test is the only guard.
    func testEverySensorIconNameResolves() {
        for sensor in SensorType.allCases {
            XCTAssertNotNil(UIImage(systemName: sensor.iconName),
                            "\(sensor.rawValue): '\(sensor.iconName)' is not an SF Symbol on this runtime")
        }
    }

    /// R1.4: Home's settings-reset warning named `gearshape.badge.xmark`, which does not exist —
    /// the icon silently rendered as nothing, on the one row that fires exactly when the owner
    /// most needs to notice a problem. Sweep every `systemImage:`/`systemName:` string literal
    /// in the app sources and fail on any name this runtime's symbol set doesn't know, so the
    /// next typo'd symbol fails a test instead of a user. The two floor assertions keep the
    /// sweep honest: a broken path or regex must fail loudly, never pass by finding nothing.
    func testEverySymbolLiteralInTheAppResolves() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)   // …/MalinoisTests/CoreTypesTests.swift
            .deletingLastPathComponent()                    // …/MalinoisTests
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("Malinois", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot,
                                                                 includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "the sweep did not find the app sources — path assumption broke")

        // `[^"\\]` keeps interpolated and escape-bearing strings out; only plain literals are judged.
        let symbolArgument = #/(?:systemImage|systemName):\s*"([^"\\]+)"/#
        var checked = 0
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in source.matches(of: symbolArgument) {
                let name = String(match.1)
                checked += 1
                XCTAssertNotNil(UIImage(systemName: name),
                                "\(file.lastPathComponent): '\(name)' is not an SF Symbol on this runtime")
            }
        }
        XCTAssertGreaterThan(checked, 20, "the sweep stopped matching symbol literals — regex or layout drift")
    }
}
