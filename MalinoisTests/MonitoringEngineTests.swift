//
//  MonitoringEngineTests.swift
//  MalinoisTests
//
//  Synchronous state-machine coverage for the central coordinator. These run
//  against the real object graph (no hardware needed) and assert the immediate
//  state after each entry point — the transitions that don't depend on sensors,
//  camera, or the network.
//

import XCTest
import AVFoundation
@testable import Malinois

@MainActor
final class MonitoringEngineTests: XCTestCase {

    private func makeEngine(_ configure: (AppSettings) -> Void = { _ in }) -> MonitoringEngine {
        let settings = AppSettings()
        configure(settings)
        return MonitoringEngine(settings: settings,
                                eventStore: EventStore(),
                                cloud: CloudExfiltrator(),
                                camera: CameraController(),
                                // Pre-resolved: arming waits for the entitlement check, and
                                // these tests are not testing StoreKit.
                                entitlements: ProEntitlements(resolvedAs: .trial))
    }

    func testStartsDisarmed() {
        XCTAssertEqual(makeEngine().state, .disarmed)
    }

    func testBeginArmingEntersGuidedAccessCheck() {
        let engine = makeEngine()
        engine.beginArming()
        XCTAssertEqual(engine.state, .guidedAccessCheck)
        engine.disarm()
    }

    func testBeginArmingIgnoredUnlessDisarmed() {
        let engine = makeEngine()
        engine.beginArming()
        engine.beginArming()   // no-op — already past .disarmed
        XCTAssertEqual(engine.state, .guidedAccessCheck)
        engine.disarm()
    }

    func testCancelArmingReturnsToDisarmed() {
        let engine = makeEngine()
        engine.beginArming()
        engine.cancelArming()
        XCTAssertEqual(engine.state, .disarmed)
    }

    /// Guided Access is recommended, not enforced — confirming always starts the
    /// grace countdown, even with Guided Access off (as it is in the test host).
    func testConfirmingStartsGrace() {
        let engine = makeEngine()
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(engine.state, .arming, "grace countdown begins")
        engine.disarm()   // cancels the grace timer
    }

    func testDisarmReturnsToDisarmed() {
        let engine = makeEngine()
        engine.beginArming()
        engine.disarm()
        XCTAssertEqual(engine.state, .disarmed)
    }

    // MARK: - Refractory re-arm (motionCorroborated deafness fix)

    /// A latched sensor stays "in play" during the correlation window, then becomes
    /// due for re-arm once its trip ages out without firing — so a stray early trip
    /// can't latch a one-shot monitor forever (which made motionCorroborated deaf).
    func testRefractoryFreesLatchedSensorOnlyAfterWindow() {
        let t0 = Date()
        let latched: Set<SensorType> = [.motion]
        let trips: [SensorType: Date] = [.motion: t0]

        // Within the window: motion can still corroborate a later trip → not due.
        XCTAssertTrue(MonitoringEngine.refractoryDueSensors(
            latched: latched, trips: trips, now: t0.addingTimeInterval(1), window: 2).isEmpty)

        // Past the window with no corroboration: free it so it can trip again.
        XCTAssertEqual(MonitoringEngine.refractoryDueSensors(
            latched: latched, trips: trips, now: t0.addingTimeInterval(2.1), window: 2), [.motion])
    }

    /// The "stray bump, then real pick-up" sequence: a motion bump latches motion;
    /// by the time the thief actually lifts the phone (well after the window), the
    /// refractory pass has freed motion so it — plus audio — can corroborate.
    /// F-02: the flood threshold must sit well above a plausible human tamper rate
    /// (~6/min) so ordinary sustained handling isn't misread as a synthetic attack.
    func testFloodThresholdIsAboveHumanTamperRate() {
        XCTAssertGreaterThan(MonitoringEngine.floodTripThreshold, 6,
                             "6 trips/min is a normal tamper rate, not an attack rate")
        XCTAssertFalse(MonitoringEngine.isFloodCount(MonitoringEngine.floodTripThreshold),
                       "exactly at the threshold is not yet a flood")
        XCTAssertTrue(MonitoringEngine.isFloodCount(MonitoringEngine.floodTripThreshold + 1))
    }

    /// N-01: a running alert/siren must never be silenced by a screen touch. A trigger
    /// while it's active always extends it (even in the disarm flow); only STARTING a
    /// fresh alert is gated on not being in the owner's disarm.
    func testAlertActionNeverLetsAScreenTouchStarveARunningSiren() {
        // Start fresh unless the PIN pad is actually open.
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: true, alertActive: false, activeEntry: false), .present)
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: true, alertActive: false, activeEntry: true), .none,
                       "the owner's own disarm stays quiet once the pad is up")
        // A running alarm is kept alive regardless of a screen touch — the N-01 fix.
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: true, alertActive: true, activeEntry: true), .extend,
                       "holding the screen can't starve a running siren")
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: true, alertActive: true, activeEntry: false), .extend)
        // Stealth / no-message mode does nothing either way.
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: false, alertActive: true, activeEntry: false), .none)
    }

    /// 2.5.14: while any capture session is live, the covert screen must never be fully
    /// dark — the REC indicator has to be legible ("the app cannot go blank during
    /// recording"). True black is reserved for the genuinely-not-recording armed idle.
    func testBrightnessNeverFullyDarkWhileRecording() {
        // The ladder, top to bottom: flash > pad > alert > recording > covert black.
        XCTAssertEqual(MonitoringEngine.brightnessLevel(captureFlash: true, padOpen: true,
                                                        alertActive: true, recording: true,
                                                        previous: 0.2), 1.0)
        XCTAssertEqual(MonitoringEngine.brightnessLevel(captureFlash: false, padOpen: true,
                                                        alertActive: true, recording: true,
                                                        previous: 0.2), 0.6,
                       "pad brightness floors at 0.6 even from a dim previous level")
        XCTAssertEqual(MonitoringEngine.brightnessLevel(captureFlash: false, padOpen: true,
                                                        alertActive: false, recording: false,
                                                        previous: 0.9), 0.9,
                       "a brighter previous level is preserved for the pad")
        XCTAssertEqual(MonitoringEngine.brightnessLevel(captureFlash: false, padOpen: false,
                                                        alertActive: true, recording: true,
                                                        previous: 0.2),
                       MonitoringEngine.alertScreenBrightness)

        // The 2.5.14 rung: recording alone lifts the screen out of black…
        let recording = MonitoringEngine.brightnessLevel(captureFlash: false, padOpen: false,
                                                         alertActive: false, recording: true,
                                                         previous: 0.2)
        XCTAssertEqual(recording, MonitoringEngine.recordingScreenBrightness)
        XCTAssertGreaterThan(recording, 0, "screen must never be blank while the camera is live")
        XCTAssertLessThan(recording, MonitoringEngine.alertScreenBrightness,
                          "the alert remains the visually louder state")

        // …and only with the camera off does covert reach true black.
        XCTAssertEqual(MonitoringEngine.brightnessLevel(captureFlash: false, padOpen: false,
                                                        alertActive: false, recording: false,
                                                        previous: 0.2), 0)
    }

    /// A-02: opening the disarm pad is not the same as using it.
    ///
    /// The pad stays up for 30 s of inactivity (to a 120 s ceiling), so suppressing the alert
    /// and the capture flash on mere openness handed anyone willing to do the 5-second hold
    /// 30–150 s of guaranteed silence, renewable by re-holding. Suppression now requires a
    /// recent keypress, so an idle open pad alerts normally while an owner mid-entry doesn't
    /// get an alert fighting the raised pad brightness.
    func testSuppressionRequiresActiveEntryNotMerelyAnOpenPad() {
        let now = Date()
        let grace: TimeInterval = 20

        // Never typed → not entry in progress, even though the pad is open.
        XCTAssertFalse(MonitoringEngine.entryIsActive(lastKeypress: nil, now: now, grace: grace),
                       "an open pad with no keypress must not suppress the response")
        // Typing right now → the owner is mid-entry.
        XCTAssertTrue(MonitoringEngine.entryIsActive(lastKeypress: now, now: now, grace: grace))
        // Still within the grace: slow owner reading a dim screen between digits.
        XCTAssertTrue(MonitoringEngine.entryIsActive(lastKeypress: now.addingTimeInterval(-19),
                                                     now: now, grace: grace))
        // Idle past the grace: the pad is open but nobody is entering a PIN.
        XCTAssertFalse(MonitoringEngine.entryIsActive(lastKeypress: now.addingTimeInterval(-21),
                                                      now: now, grace: grace),
                       "an abandoned open pad must stop suppressing once the grace lapses")
        // The pad's own 150 s worst-case lifetime far outlives the suppression grace — that
        // gap is the point of the fix.
        XCTAssertFalse(MonitoringEngine.entryIsActive(lastKeypress: now.addingTimeInterval(-150),
                                                      now: now, grace: grace))
    }

    /// Regression: a ramped siren must not be dismissed before it has ever been loud.
    ///
    /// The ramp holds the alarm quiet for 10s and then rises over 10s, but the alert window
    /// was a flat 8s — so the siren was stopped two seconds *before* it began to rise, played
    /// inaudibly for its whole life, and Siren mode appeared completely broken.
    func testRampedSirenOutlivesItsRampBeforeDismissing() {
        let base: TimeInterval = 8, hold: TimeInterval = 10, fade: TimeInterval = 10

        let ramped = MonitoringEngine.alertDismissInterval(base: base, sirenRamping: true,
                                                           rampHold: hold, rampFade: fade)
        XCTAssertGreaterThan(ramped, hold + fade,
                             "the alarm must still be sounding after it reaches full volume")
        XCTAssertEqual(ramped, 28, "full ramp plus the base window at full volume")

        // Un-ramped siren and the silent alert modes keep the plain window.
        XCTAssertEqual(MonitoringEngine.alertDismissInterval(base: base, sirenRamping: false,
                                                             rampHold: hold, rampFade: fade), base)
    }

    /// "Require Guided Access" blocks a user-initiated arm only when the owner asked for it
    /// *and* Guided Access is actually off. Default-off means the out-of-the-box flow — and
    /// App Review — can always arm.
    func testGuidedAccessRequirementBlocksOnlyWhenAskedForAndAbsent() {
        XCTAssertTrue(MonitoringEngine.armingBlocked(requireGuidedAccess: true, guidedAccessOn: false))
        XCTAssertFalse(MonitoringEngine.armingBlocked(requireGuidedAccess: true, guidedAccessOn: true))
        XCTAssertFalse(MonitoringEngine.armingBlocked(requireGuidedAccess: false, guidedAccessOn: false),
                       "the default configuration must never refuse to arm")
        XCTAssertFalse(MonitoringEngine.armingBlocked(requireGuidedAccess: false, guidedAccessOn: true))
    }

    /// Eighth review M2 (option A): the arming screen's escape is a ONE-ARM lift, not a
    /// setting change — it unblocks exactly the lifted arm, and the stored requirement
    /// stands for every future one.
    func testGuidedAccessLiftUnblocksOneArmWithoutTouchingTheRequirement() {
        XCTAssertFalse(MonitoringEngine.armingBlocked(requireGuidedAccess: true,
                                                      guidedAccessOn: false, liftedThisArm: true),
                       "the lifted arm proceeds")
        XCTAssertTrue(MonitoringEngine.armingBlocked(requireGuidedAccess: true,
                                                     guidedAccessOn: false, liftedThisArm: false),
                      "with the lift expired, the same configuration blocks again")
    }

    /// Eighth review M1 (option A): Settings is a WRITE surface — it must never open by
    /// Face ID, whatever the owner's opt-in says. The two read surfaces may.
    func testSettingsGateNeverAllowsBiometrics() {
        XCTAssertFalse(HomeView.Gate.settings.allowsBiometrics,
                       "a presented face must not be able to reconfigure the protection posture")
        XCTAssertTrue(HomeView.Gate.log.allowsBiometrics)
        XCTAssertTrue(HomeView.Gate.test.allowsBiometrics)
    }

    /// BACKLOG 44: iOS defers the biometric sheet under Guided Access without erroring —
    /// pre-fix the queued request left the privacy cover stuck over the pad (owner-reported
    /// on device, build 31). The offer rule: all four gates must agree, and an active GA
    /// session vetoes the offer so the pad simply stands.
    func testBiometricOfferVetoedUnderGuidedAccess() {
        XCTAssertTrue(PINEntryView.shouldOfferBiometrics(allow: true, optedIn: true,
                                                         locked: false, guidedAccess: false))
        XCTAssertFalse(PINEntryView.shouldOfferBiometrics(allow: true, optedIn: true,
                                                          locked: false, guidedAccess: true),
                       "under GA the sheet would queue, not present — never fire the request (44)")
        XCTAssertFalse(PINEntryView.shouldOfferBiometrics(allow: false, optedIn: true,
                                                          locked: false, guidedAccess: false),
                       "write surfaces never offer, whatever the toggle says")
        XCTAssertFalse(PINEntryView.shouldOfferBiometrics(allow: true, optedIn: false,
                                                          locked: false, guidedAccess: false),
                       "no opt-in, no offer")
        XCTAssertFalse(PINEntryView.shouldOfferBiometrics(allow: true, optedIn: true,
                                                          locked: true, guidedAccess: false),
                       "a face must not open a locked gate — the lockout is not decorative")
    }

    /// The lift is auditable: its state record renders as itself, never as "Signal loss"
    /// (the unknown-kind fallback that asserts an attack).
    func testGuidedAccessLiftRecordRendersHonestly() {
        let e = Event(startDate: Date(), endDate: Date(), triggeredSensors: [],
                      stateChange: "gaLifted")
        XCTAssertTrue(e.isStateChange)
        XCTAssertEqual(e.sensorSummary, "Guided Access requirement lifted for one arm")
    }

    /// Crash recovery must re-arm even with the requirement on and Guided Access off — a
    /// crash can end Guided Access, and refusing there would leave the device unprotected,
    /// which is the exact failure the auto re-arm exists to prevent (F-12).
    @MainActor
    func testCrashRecoveryReArmsEvenWhenGuidedAccessIsRequiredAndOff() {
        let engine = makeEngine { $0.requireGuidedAccess = true }
        XCTAssertTrue(engine.armingBlockedByGuidedAccess,
                      "a user-initiated arm would be refused in this state")

        // The recovery path drives the grace countdown directly rather than through the
        // gated entry point, so it still reaches the armed flow.
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(engine.state, .guidedAccessCheck,
                       "the gated path refuses while blocked")
        engine.disarm()
    }

    /// The crash-recovery re-arm is timed against actual attempts: two within the window
    /// mean arming is crash-looping, so it stops. A first-ever attempt (no prior timestamp,
    /// stored as 0) and a spaced-out attempt both proceed.
    func testCrashLoopGuardOnlyTripsOnRapidRepeatAttempts() {
        XCTAssertFalse(MonitoringEngine.isCrashLoop(lastAttempt: 0, now: 1000),
                       "first attempt ever (no prior timestamp) is not a loop")
        XCTAssertTrue(MonitoringEngine.isCrashLoop(lastAttempt: 1000, now: 1030),
                      "a second attempt 30s later is a crash loop")
        XCTAssertFalse(MonitoringEngine.isCrashLoop(lastAttempt: 1000, now: 1200),
                       "200s later is a fresh, legitimate recovery")
        XCTAssertFalse(MonitoringEngine.isCrashLoop(lastAttempt: 1000, now: 1090),
                       "exactly at the 90s window is not yet a loop")
    }

    /// A phone call posts an audio interruption that stops the siren's player. When the
    /// interruption ENDS, the alarm must come back iff it should still be sounding — a
    /// siren the owner disarmed meanwhile must stay silent, one merely interrupted must
    /// resume. (Deliberately independent of the system's `.shouldResume` hint.)
    func testSirenResumesAfterInterruptionOnlyIfStillSounding() {
        XCTAssertTrue(SirenPlayer.shouldResumeAfterInterruption(shouldBeSounding: true),
                      "a call must not permanently silence a running siren")
        XCTAssertFalse(SirenPlayer.shouldResumeAfterInterruption(shouldBeSounding: false),
                       "a siren stopped by disarm must not resurrect when the call ends")
    }

    /// Eighth-review M5: activation exhaustion must not outlast the contention that caused
    /// it. Every alert-window extension re-asks "should the alarm be sounding but isn't?" —
    /// true re-arms the attempt budget; a sounding or stopped siren is left alone.
    func testSirenReattemptOwedExactlyWhenOwedAndSilent() {
        XCTAssertTrue(SirenPlayer.reattemptNeeded(shouldBeSounding: true, isPlaying: false),
                      "owed and silent — the exhausted budget re-arms on fresh tampering")
        XCTAssertFalse(SirenPlayer.reattemptNeeded(shouldBeSounding: true, isPlaying: true),
                       "already sounding — never restart a running alarm")
        XCTAssertFalse(SirenPlayer.reattemptNeeded(shouldBeSounding: false, isPlaying: false),
                       "not owed (stopped/disarmed) — extensions must not resurrect it")
    }

    /// Fourth-pass SR-1: the exhaustion flag is consumed when noted. One real failure must
    /// not resurrect the "siren couldn't sound" notice after every later quiet session —
    /// pre-fix, the flag was cleared only by a later SUCCESSFUL play, so it survived
    /// arm/disarm cycles indefinitely.
    func testActivationExhaustionIsConsumedOnce() {
        let siren = SirenPlayer()
        XCTAssertFalse(siren.consumeActivationExhausted(), "clean player: nothing to report")
        siren.setActivationExhaustedForTesting()
        XCTAssertTrue(siren.consumeActivationExhausted(), "the exhaustion is reported once")
        XCTAssertFalse(siren.consumeActivationExhausted(),
                       "and never again — a quiet later session must not re-raise the notice")
    }

    /// F1: a bare touch must NOT be able to hold the alarm off. The disarm-*candidate*
    /// window opens on any touch-down (for owner attribution), so if presentation were
    /// gated on it, a snoop tapping and swiping the screen — exactly what snooping is —
    /// would keep the siren from ever starting. Only the PIN pad genuinely being open
    /// (a deliberate 5-second hold) may suppress a fresh alert.
    func testTouchAloneCannotSuppressTheFirstAlert() {
        // The snoop case: screen being touched, no pad open yet → the alarm still fires.
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: true, alertActive: false, activeEntry: false), .present,
                       "a touch alone must never hold off the first alert")
        // Only an open pad — which costs a deliberate 5s hold — stays quiet.
        XCTAssertEqual(MonitoringEngine.alertAction(showsMessage: true, alertActive: false, activeEntry: true), .none)
    }

    func testStrayBumpDoesNotPermanentlyLatchMotion() {
        let bump = Date()
        // Motion tripped once and is still latched; its trip has long since aged out.
        let due = MonitoringEngine.refractoryDueSensors(
            latched: [.motion], trips: [.motion: bump],
            now: bump.addingTimeInterval(30), window: 2)
        XCTAssertEqual(due, [.motion], "motion must be re-armable, not latched forever")
    }

    /// A sensor still latched but already pruned from the trip window is due at once.
    func testLatchedSensorWithNoRecordedTripIsDue() {
        XCTAssertEqual(MonitoringEngine.refractoryDueSensors(
            latched: [.audio], trips: [:], now: Date(), window: 2), [.audio])
    }

    // MARK: - Jamming blackout escalation decision

    func testBlackoutEscalatesOnlyWhenEveryConditionHolds() {
        // Happy path: armed, on, offline now, had a path at arm, stationary, fresh.
        XCTAssertTrue(MonitoringEngine.shouldEscalateBlackout(
            armed: true, enabled: true, online: false,
            hadConnectivityAtArm: true, stationary: true, alreadyEscalated: false))

        // Each missing gate suppresses it.
        XCTAssertFalse(MonitoringEngine.shouldEscalateBlackout(
            armed: false, enabled: true, online: false, hadConnectivityAtArm: true, stationary: true, alreadyEscalated: false), "not armed")
        XCTAssertFalse(MonitoringEngine.shouldEscalateBlackout(
            armed: true, enabled: false, online: false, hadConnectivityAtArm: true, stationary: true, alreadyEscalated: false), "feature off")
        XCTAssertFalse(MonitoringEngine.shouldEscalateBlackout(
            armed: true, enabled: true, online: true, hadConnectivityAtArm: true, stationary: true, alreadyEscalated: false), "still online")
        XCTAssertFalse(MonitoringEngine.shouldEscalateBlackout(
            armed: true, enabled: true, online: false, hadConnectivityAtArm: false, stationary: true, alreadyEscalated: false), "never had a path — probably a dead zone")
        XCTAssertFalse(MonitoringEngine.shouldEscalateBlackout(
            armed: true, enabled: true, online: false, hadConnectivityAtArm: true, stationary: false, alreadyEscalated: false), "moved — that's the tamper-carried-away path, not pre-emptive jamming")
        XCTAssertFalse(MonitoringEngine.shouldEscalateBlackout(
            armed: true, enabled: true, online: false, hadConnectivityAtArm: true, stationary: true, alreadyEscalated: true), "already escalated once this session")
    }

    /// F3: an attacker can stay under the per-sensor flood bar by alternating sources, so
    /// the aggregate *trigger* rate is also checked. The threshold must sit clear of a real
    /// tamperer's rate (~6/min) — a genuine burglary must never be coalesced — while still
    /// catching sustained synthetic noise.
    func testAggregateFloodThresholdSpansHumanAndSyntheticRates() {
        XCTAssertGreaterThan(MonitoringEngine.aggregateFloodThreshold, 6,
                             "a human tamper rate must never be treated as a flood")
        XCTAssertFalse(MonitoringEngine.isAggregateFlood(6), "frantic but human — still real evidence")
        XCTAssertFalse(MonitoringEngine.isAggregateFlood(MonitoringEngine.aggregateFloodThreshold),
                       "exactly at the threshold is not yet a flood")
        XCTAssertTrue(MonitoringEngine.isAggregateFlood(MonitoringEngine.aggregateFloodThreshold + 1))
        // The attack this exists for: two sources at ~8/min each stay under the per-sensor
        // bar of 10 but total 16 triggers/min.
        XCTAssertFalse(MonitoringEngine.isFloodCount(8), "8/min on one sensor is under the per-sensor bar")
        XCTAssertTrue(MonitoringEngine.isAggregateFlood(16), "but 16/min in aggregate is a flood")
    }

    /// V-03: the trigger-time "can't exfiltrate → go loud" decision must apply the same
    /// `hadConnectivityAtArm` gate as the canary path — so a Stealth device armed in a
    /// dead zone doesn't force-siren on an ordinary tamper, while a device that HAD a path
    /// and lost it still escalates.
    func testGoLoudOnFailedExfilNeedsConnectivityAtArm() {
        // Had a path at arm, now offline well past the blip filter → suspected jamming → go loud.
        XCTAssertTrue(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: true, online: false, hadConnectivityAtArm: true, offlineFor: 60))
        // Armed offline to begin with → benign dead zone → stay covert (Stealth honored).
        XCTAssertFalse(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: true, online: false, hadConnectivityAtArm: false, offlineFor: 60),
            "a dead-zone arm is not jamming — don't break Stealth")
        // Still online → the evidence escapes → no need to go loud.
        XCTAssertFalse(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: true, online: true, hadConnectivityAtArm: true, offlineFor: 60))
        // Feature off → never force it.
        XCTAssertFalse(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: false, online: false, hadConnectivityAtArm: true, offlineFor: 60))
    }

    /// 39.R2.2: `connectivity.isOnline` is an instantaneous sample, and a WiFi↔cellular
    /// handoff can leave the path unsatisfied for well under a second — so a trigger landing
    /// inside that instant read as "jammed" and sounded the persistent blackout siren on a
    /// coincidence (`jammingResponse` defaults ON, so the opt-in is soft). A genuine
    /// jam-then-grab timeline runs seconds to minutes; the 2 s floor filters the flap while
    /// barely delaying the deterrent, and the 30 s canary plus the observed-failure path
    /// stand behind it for the corner the floor gives up.
    func testGoLoudIgnoresSubSecondHandoffBlips() {
        XCTAssertFalse(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: true, online: false, hadConnectivityAtArm: true, offlineFor: 0.5),
            "a handoff blip plus a coincidental trigger is not jamming")
        XCTAssertTrue(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: true, online: false, hadConnectivityAtArm: true,
            offlineFor: MonitoringEngine.offlineBlipFilter),
            "exactly at the floor counts — the filter is for blips, not a second debounce")
        XCTAssertTrue(MonitoringEngine.shouldGoLoudOnFailedExfil(
            jammingResponse: true, online: false, hadConnectivityAtArm: true, offlineFor: 5))
    }

    /// F4: in Siren mode the FIRST capture must already be a still — the old gate collapsed
    /// clips only once the alarm was sounding, so the first trigger of a Siren + until-clear
    /// session recorded up to 120 s of clip (extended by the tampering itself) before the
    /// alarm ever started, and the quiet ramp began only after that.
    func testSirenModeCapturesStillsFromTheFirstTrigger() {
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .untilClear, sirenResponse: true,
                                                          sirenSounding: false, escalationForcesSiren: false),
                       .photo, "the very first siren-mode capture is a still — alarm within ~2 s")
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .clip3, sirenResponse: true,
                                                          sirenSounding: false, escalationForcesSiren: false),
                       .photo)
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .untilClear, sirenResponse: false,
                                                          sirenSounding: false, escalationForcesSiren: false),
                       .untilClear, "Alert/Stealth keep the configured clip — no alarm is waiting on it")
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .clip5, sirenResponse: false,
                                                          sirenSounding: true, escalationForcesSiren: false),
                       .photo, "a sounding alarm always collapses clips (the mic would silence it)")
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .untilClear, sirenResponse: false,
                                                          sirenSounding: false, escalationForcesSiren: true),
                       .photo, "a forced-siren escalation collapses clips too")
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .photo, sirenResponse: true,
                                                          sirenSounding: true, escalationForcesSiren: true),
                       .photo, "photo passes through untouched")
    }

    // MARK: - Guided Access across a disarm (BACKLOG 24b)

    /// Only ON→OFF is reported. OFF→ON is the owner setting protection up, and an unknown
    /// prior state (first run, or a disarm recorded before this shipped) is not evidence of
    /// anything — reporting either would train the owner to dismiss the warning that matters.
    func testGuidedAccessChangeAcrossDisarmReportsOnlyTheOffDirection() {
        XCTAssertTrue(MonitoringEngine.guidedAccessWentOffWhileDisarmed(atLastDisarm: true, now: false),
                      "on at disarm, off now — something turned it off while nobody was watching")
        XCTAssertFalse(MonitoringEngine.guidedAccessWentOffWhileDisarmed(atLastDisarm: true, now: true),
                       "unchanged and still on")
        XCTAssertFalse(MonitoringEngine.guidedAccessWentOffWhileDisarmed(atLastDisarm: false, now: false),
                       "off at disarm and off now — the owner's own configuration, unchanged")
        XCTAssertFalse(MonitoringEngine.guidedAccessWentOffWhileDisarmed(atLastDisarm: false, now: true),
                       "off to on is the owner improving things, never a warning")
        XCTAssertFalse(MonitoringEngine.guidedAccessWentOffWhileDisarmed(atLastDisarm: nil, now: false),
                       "no recorded disarm yet — a first arm must not look like a change")
    }

    // MARK: - Mic-less warm session during the siren (BACKLOG 17)

    private func needsReconfig(clips: Bool = true, wantClips: Bool = true,
                               micDropped: Bool = false, vision: Bool = true,
                               wantVision: Bool = true) -> Bool {
        CameraController.needsReconfiguration(isConfigured: true,
                                              configuredPosition: .front, wantPosition: .front,
                                              configuredForClips: clips, wantClips: wantClips,
                                              configuredVision: vision, wantVision: wantVision,
                                              micDropped: micDropped)
    }

    /// The failure this guards is silent and durable: a session whose mic was dropped for a
    /// siren matches a correct clip session on every other field, so without the `micDropped`
    /// check the reconfiguration is skipped and **every clip for the rest of the armed session
    /// records silently** — no error, no badge, nothing in the log. The evidence looks fine
    /// until someone plays it back.
    func testASessionThatLostItsMicMustRebuildBeforeRecordingClipsAgain() {
        XCTAssertFalse(needsReconfig(), "an untouched clip session is already correct")
        XCTAssertTrue(needsReconfig(micDropped: true),
                      "the mic has to come back before the next clip")
    }

    /// A stills session never held a mic, so a dropped mic is not a reason to tear it down —
    /// that would mean an extra reconfiguration on every still capture after an alarm.
    func testStillsDoNotRebuildJustBecauseTheMicWasDropped() {
        XCTAssertFalse(needsReconfig(clips: false, wantClips: false, micDropped: true))
    }

    /// The pre-existing reasons to rebuild must keep working alongside the new one.
    func testPositionModeAndVisionChangesStillForceAReconfiguration() {
        XCTAssertTrue(CameraController.needsReconfiguration(isConfigured: false,
                                                            configuredPosition: .front, wantPosition: .front,
                                                            configuredForClips: true, wantClips: true,
                                                            configuredVision: true, wantVision: true,
                                                            micDropped: false),
                      "an unconfigured session always needs building")
        XCTAssertTrue(CameraController.needsReconfiguration(isConfigured: true,
                                                            configuredPosition: .front, wantPosition: .back,
                                                            configuredForClips: true, wantClips: true,
                                                            configuredVision: true, wantVision: true,
                                                            micDropped: false),
                      "camera position")
        XCTAssertTrue(needsReconfig(clips: false, wantClips: true), "stills -> clips")
        XCTAssertTrue(needsReconfig(vision: false, wantVision: true), "vision tap toggled on")
    }

    // MARK: - Bounded camera warm-up (34's warmUp hardening)

    /// `AVCaptureSession.startRunning()` can block with no bound, and the trigger path
    /// awaits warm-up — so an unbounded wait is the H10 wedge shape: `isHandlingTrigger`
    /// stuck, detection dead until disarm. The deadline helper is deliberately not a task
    /// group (a group awaits every child, so it would hang exactly as long as the stuck
    /// operation it exists to cut); the second assertion is the test that matters — the
    /// timeout must return promptly even though the operation never does.
    func testWithDeadlineReturnsFastResultsAndCutsHungOperations() async {
        let value = try? await MonitoringEngine.withDeadline(1.0) { 42 }
        XCTAssertEqual(value, 42, "a prompt operation passes through untouched")

        let started = Date()
        do {
            _ = try await MonitoringEngine.withDeadline(0.05) { () -> Int in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // a warm-up that hangs
                return 0
            }
            XCTFail("a hung operation must not return a value")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                              "the deadline cuts the wait — the pipeline never wedges on it")
        }
    }

    // MARK: - Late clip callbacks are discarded, never re-homed (39.R1.3)

    /// The net the recording-timeout cleanup routes into: a delegate callback for a file the
    /// slot is not currently recording to is a straggler from a recording that already timed
    /// out — its capture was failed long ago, and letting it through would hand its footage
    /// to whatever event is stopping the slot NOW. The timeout path itself (a hardware stall
    /// whose callback never comes, then comes late) is not locally constructible — no
    /// simulator recording exists to stall — recorded per the testing rule; this pins the
    /// discard branch the fix forgets the URL into: the stale file is deleted, never parked.
    func testALateClipCallbackForAnUnexpectedFileIsDiscardedAndDeleted() throws {
        let controller = CameraController()
        let stray = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        try Data("stale clip".utf8).write(to: stray)

        controller.fileOutput(AVCaptureMovieFileOutput(), didFinishRecordingTo: stray,
                              from: [], error: nil)

        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: stray.path) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path),
                       "a callback nothing expects must be discarded and its file deleted")
    }

    /// The reason the mic can go without losing evidence: an alarm that is sounding — or that
    /// this trigger is about to sound — already forces stills, so the movie output is idle.
    /// If this ever stopped being true, dropping the mic would start producing silent clips.
    func testAnAlarmAlreadyMeansStillsSoTheMovieOutputIsIdle() {
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .clip5, sirenResponse: true,
                                                          sirenSounding: false, escalationForcesSiren: false),
                       .photo, "siren mode collapses clips from the first trigger")
        XCTAssertEqual(MonitoringEngine.captureModeForNow(configured: .clip5, sirenResponse: false,
                                                          sirenSounding: true, escalationForcesSiren: false),
                       .photo, "and while one is already sounding")
    }

    /// The device failure of 2026-08-26, pinned as the invariant it broke: the shape the
    /// session is *warmed* to and the shape a capture *uses* must agree, or every trigger
    /// rebuilds the session twice. That rebuild attaches a mic, attaching a mic seizes the
    /// app's audio session, and seizing it interrupts the siren — heard as an alarm dying
    /// every few seconds and restarting itself. No single function was wrong; the two
    /// decisions simply disagreed, which is why nothing local could have caught it.
    func testTheWarmedShapeMatchesTheShapeACaptureWillUseDuringAnAlarm() {
        let configured = CaptureMode.clip5
        let duringAlarm = MonitoringEngine.captureModeForNow(configured: configured,
                                                             sirenResponse: true, sirenSounding: true,
                                                             escalationForcesSiren: false)
        XCTAssertEqual(duringAlarm, .photo, "an alarm always captures stills")

        func rebuildNeeded(warmedForClips: Bool) -> Bool {
            CameraController.needsReconfiguration(isConfigured: true,
                                                  configuredPosition: .front, wantPosition: .front,
                                                  configuredForClips: warmedForClips,
                                                  wantClips: duringAlarm.isClip,
                                                  configuredVision: true, wantVision: true,
                                                  micDropped: false)
        }
        XCTAssertTrue(rebuildNeeded(warmedForClips: configured.isClip),
                      "warming for the configured mode means a rebuild on every single trigger")
        XCTAssertFalse(rebuildNeeded(warmedForClips: duringAlarm.isClip),
                       "warming for the mode the capture will use means no rebuild at all")
    }

    /// Reported on device 2026-08-26: a phone set face down during the 15 s grace countdown
    /// locked itself, suspended the app, and left calibration half-finished — it resumed only
    /// when picked up again. Auto-lock was only disabled once the watch went live, and the
    /// arming flow is precisely when the owner is told to put the phone down and walk away.
    /// The countdown is wall-clock driven and self-corrects, but calibration samples
    /// continuously and needs the process alive, so the watch simply never started while the
    /// owner believed it had. Guided Access doesn't help — it pins the app to the foreground,
    /// not the display on.
    func testEveryStateBeforeArmedAlsoKeepsTheDeviceAwake() {
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.arming),
                      "the grace countdown is exactly when the phone is set down untouched")
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.calibrating),
                      "calibration cannot survive the app being suspended")
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.guidedAccessCheck))
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.armed))
        XCTAssertTrue(MonitoringEngine.keepsDeviceAwake(.triggered))
    }

    /// And the other half: disarmed must hand auto-lock back, or the app quietly holds the
    /// display awake for the rest of the day.
    func testDisarmedReleasesTheDevice() {
        XCTAssertFalse(MonitoringEngine.keepsDeviceAwake(.disarmed))
    }

    // MARK: - Arming must not snapshot an unresolved entitlement (review finding 2)

    /// `beginArming` snapshots `armedPro` for the whole session, and `ProEntitlements.status`
    /// starts `.free` while StoreKit resolves. Arming inside that window produced a session with
    /// no Sound, no Vision, no multi-cam and short clips — for its entire duration, even though
    /// entitlement resolved milliseconds later, and with nothing on screen to say so. The owner
    /// had paid for features that simply did not run that night.
    func testArmingWaitsForTheEntitlementCheck() {
        XCTAssertTrue(MonitoringEngine.armingBlockedByEntitlementCheck(entitlementResolved: false),
                      "a session must never be snapshotted from a half-known entitlement")
        XCTAssertFalse(MonitoringEngine.armingBlockedByEntitlementCheck(entitlementResolved: true))
    }

    /// The two arming gates are independent: Guided Access enforcement is the owner's own
    /// requirement, the entitlement check is a race. Neither should mask the other.
    func testTheGuidedAccessGateIsUnaffectedByTheEntitlementGate() {
        XCTAssertTrue(MonitoringEngine.armingBlocked(requireGuidedAccess: true, guidedAccessOn: false))
        XCTAssertFalse(MonitoringEngine.armingBlocked(requireGuidedAccess: true, guidedAccessOn: true))
        XCTAssertFalse(MonitoringEngine.armingBlocked(requireGuidedAccess: false, guidedAccessOn: false))
    }

    // MARK: - Background push reports what actually happened (review finding 6)

    /// The AppDelegate used to post a notification and call the completion handler with
    /// `.newData` in the same breath, before the fetch had started. Two problems: it claimed
    /// success for work that might fail, and it told iOS the background work was finished while
    /// it was still running — leaving the system free to suspend the app mid-copy, which is the
    /// one thing this push exists to prevent.
    func testPushReportsFailureOnlyForAQueryThatActuallyFailed() {
        XCTAssertEqual(MonitoringEngine.pushResult(pro: true, fetchFailed: true, added: 0), .failed,
                       "a query that could not run is not 'no data'")
        XCTAssertEqual(MonitoringEngine.pushResult(pro: true, fetchFailed: false, added: 2), .newData)
        XCTAssertEqual(MonitoringEngine.pushResult(pro: true, fetchFailed: false, added: 0), .noData,
                       "a successful pull that found nothing new is not a failure")
    }

    /// A free-tier device never pulls, so there is nothing to report as failed — reporting
    /// `.failed` there would train iOS to back off a push that is working exactly as intended.
    func testFreeTierPushIsNoDataRatherThanAFailure() {
        XCTAssertEqual(MonitoringEngine.pushResult(pro: false, fetchFailed: true, added: 0), .noData)
        XCTAssertEqual(MonitoringEngine.pushResult(pro: false, fetchFailed: false, added: 0), .noData)
    }

    // MARK: - Notification-tap routing (owner ask, 2026-08-30)

    /// Only tamper alerts deep-link to the Event Log. Every CloudKit push carries the "ck"
    /// payload; the trial-end local notification does not, and routing it to a PIN gate
    /// over the log would be a confusing answer to "your trial ended".
    func testOnlyCloudKitPushesRouteToTheEventLog() {
        XCTAssertTrue(AppDelegate.isTamperAlert(userInfo: ["ck": ["ce": 2]]),
                      "a CloudKit push is a tamper alert")
        XCTAssertFalse(AppDelegate.isTamperAlert(userInfo: [:]),
                       "the trial-end local notification opens the app normally")
        XCTAssertFalse(AppDelegate.isTamperAlert(userInfo: ["aps": ["alert": "x"]]))
    }

    // MARK: - Push-failure response (32.R1 / ADR 0001)

    /// Go loud only on evidence of interference; a refusal (iCloud answered: quota, auth,
    /// schema, key reset) is surfaced, never sirened — a full iCloud used to sound the
    /// permanent blackout siren in the owner's absence.
    func testPushFailureGoesLoudOnlyForNetworkClassFailures() {
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .localOnly, isStateChange: false, interference: true,
            jammingResponse: true, hadConnectivityAtArm: true, online: true, watching: true),
            .goLoud)
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .localOnly, isStateChange: false, interference: false,
            jammingResponse: true, hadConnectivityAtArm: true, online: true, watching: true),
            .surfaceRefusal, "a refusal reached the server — nothing is jammed")
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .localOnly, isStateChange: false, interference: false,
            jammingResponse: false, hadConnectivityAtArm: false, online: true, watching: false),
            .surfaceRefusal, "a disarmed retry that finds a full iCloud still tells the owner")
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .localOnly, isStateChange: false, interference: true,
            jammingResponse: true, hadConnectivityAtArm: false, online: true, watching: true),
            .stayQuiet, "the canary conditions still gate the network class")
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .pending, isStateChange: false, interference: nil,
            jammingResponse: true, hadConnectivityAtArm: true, online: true, watching: true),
            .stayQuiet, "anything short of a terminal local-only failure is not observed failure")
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .localOnly, isStateChange: true, interference: true,
            jammingResponse: true, hadConnectivityAtArm: true, online: true, watching: true),
            .stayQuiet, "state-change records never drive the tamper response")
        XCTAssertEqual(MonitoringEngine.pushFailureResponse(
            syncState: .localOnly, isStateChange: false, interference: nil,
            jammingResponse: true, hadConnectivityAtArm: true, online: true, watching: true),
            .stayQuiet, "no classification, no escalation — only evidence may go loud")
    }

    // MARK: - One not-yet-synced lifecycle for evidence and audit rows (BACKLOG 37)

    /// Owner's decision, 2026-08-29: offline, a media event walks Syncing… → Local only →
    /// synced on reconnect, while an arm/disarm row parked on Syncing… forever — the same
    /// underlying truth, two renderings. Audit records adopt the media lifecycle: a failed
    /// push lands `.localOnly`; `.pending` stays the birth/in-flight state. The Event Log's
    /// "not yet synced" banner is the aggregate reassurance and keys on `!= .synced`, which
    /// spans both states — and the go-loud exclusion for state records is pinned separately
    /// (see "state-change records never drive the tamper response" above).
    func testAFailedStatePushLandsLocalOnlyLikeEvidenceDoes() {
        XCTAssertEqual(MonitoringEngine.stateChangeSyncState(pushed: true), .synced)
        XCTAssertEqual(MonitoringEngine.stateChangeSyncState(pushed: false), .localOnly,
                       "an offline audit row goes red like the media row beside it — never parked on Syncing… forever")
    }

    // MARK: - Microphone-warning scope (34-review H12)

    /// The mic-denied warning must fire for clip capture too, not only for the Sound
    /// tripwire — with Sound off and clips on, a denied mic used to mean silent clips with
    /// no warning anywhere.
    func testMicWarningCoversClipCaptureNotOnlyTheSoundTripwire() {
        XCTAssertTrue(MonitoringEngine.micPermissionMatters(audioSensorOn: true,
                                                            cameraOn: false, captureIsClip: false))
        XCTAssertTrue(MonitoringEngine.micPermissionMatters(audioSensorOn: false,
                                                            cameraOn: true, captureIsClip: true),
                      "clips record audio; a denied mic makes them silent")
        XCTAssertFalse(MonitoringEngine.micPermissionMatters(audioSensorOn: false,
                                                             cameraOn: true, captureIsClip: false),
                       "photo capture never needs the microphone")
        XCTAssertFalse(MonitoringEngine.micPermissionMatters(audioSensorOn: false, cameraOn: true,
                                                             captureIsClip: true, multiCam: true),
                       "Both-mode clips carry no audio by design (31.F10) — a denied mic is not why, and the warning would mislead (eighth review, L9)")
        XCTAssertTrue(MonitoringEngine.micPermissionMatters(audioSensorOn: true, cameraOn: true,
                                                            captureIsClip: true, multiCam: true),
                      "the Sound tripwire's claim on the mic stands in every camera mode")
        XCTAssertFalse(MonitoringEngine.micPermissionMatters(audioSensorOn: false,
                                                             cameraOn: false, captureIsClip: true),
                       "no camera, no clip — nothing to warn about")
    }

    // MARK: - Cadence-capture ownership (34-review H10)

    /// Blackout and flood-cadence captures are the expendable side of the pipeline: they
    /// yield to a running trigger capture — and to each other — never the reverse.
    func testCadenceCapturesYieldToTriggerCapturesAndToEachOther() {
        XCTAssertTrue(MonitoringEngine.mayRunCadenceCapture(handlingTrigger: false,
                                                            capturingUntilClear: false,
                                                            cadenceBusy: false))
        XCTAssertFalse(MonitoringEngine.mayRunCadenceCapture(handlingTrigger: true,
                                                             capturingUntilClear: false,
                                                             cadenceBusy: false))
        XCTAssertFalse(MonitoringEngine.mayRunCadenceCapture(handlingTrigger: false,
                                                             capturingUntilClear: true,
                                                             cadenceBusy: false))
        XCTAssertFalse(MonitoringEngine.mayRunCadenceCapture(handlingTrigger: false,
                                                             capturingUntilClear: false,
                                                             cadenceBusy: true),
                       "a blackout escalating mid-flood must not fire alongside the flood's still")
    }

    // MARK: - Capture-window trips (34-review M1)

    /// A tripwire firing while a photo/fixed-clip capture is running joins the in-flight
    /// event's record instead of being dropped — a grab-then-unplug must show the unplug.
    func testCaptureWindowTripsFoldInSortedAndDeduplicated() {
        XCTAssertEqual(MonitoringEngine.foldedSensors([.motion], adding: [.power, .motion]),
                       [.motion, .power], "new sensors join; duplicates don't")
        XCTAssertEqual(MonitoringEngine.foldedSensors([.motion], adding: []), [.motion])
        XCTAssertEqual(MonitoringEngine.foldedSensors([], adding: [.touch]), [.touch])
        XCTAssertEqual(MonitoringEngine.foldedSensors([.power, .motion], adding: [.audio]),
                       [.audio, .motion, .power], "result keeps the canonical sorted order")
    }

    // MARK: - Device-label bounds (34 review, 1.2)

    /// The label rides in every cloud record and alert, so it is bounded at the source.
    func testDeviceLabelIsTrimmedBoundedAndFallsBack() {
        XCTAssertEqual(MonitoringEngine.sanitizedDeviceLabel("  Desk iPhone  ", fallback: "iPhone"),
                       "Desk iPhone")
        XCTAssertEqual(MonitoringEngine.sanitizedDeviceLabel("", fallback: "iPhone"), "iPhone")
        XCTAssertEqual(MonitoringEngine.sanitizedDeviceLabel(String(repeating: "x", count: 200),
                                                             fallback: "iPhone").count, 40)
    }

    // MARK: - Notification health (34.H7)

    /// A device that cannot SHOW the cross-device alert must say so — but only when the
    /// feature is in play: the sending side needs no notification permission at all.
    func testNotificationNoticeFiresOnlyWhenAlertsAreInPlayAndBroken() {
        XCTAssertNotNil(MonitoringEngine.notificationNotice(
            authDenied: true, registrationFailed: false, notifyOtherDevices: true, pro: true))
        XCTAssertNotNil(MonitoringEngine.notificationNotice(
            authDenied: false, registrationFailed: true, notifyOtherDevices: true, pro: true))
        XCTAssertNil(MonitoringEngine.notificationNotice(
            authDenied: false, registrationFailed: false, notifyOtherDevices: true, pro: true),
            "healthy is silent")
        XCTAssertNil(MonitoringEngine.notificationNotice(
            authDenied: true, registrationFailed: true, notifyOtherDevices: false, pro: true),
            "feature off — there is no alert to miss")
        XCTAssertNil(MonitoringEngine.notificationNotice(
            authDenied: true, registrationFailed: true, notifyOtherDevices: true, pro: false),
            "free tier has no cross-device push")
        XCTAssertTrue(MonitoringEngine.notificationNotice(
            authDenied: true, registrationFailed: true, notifyOtherDevices: true, pro: true)!
            .contains("Notifications are off"),
            "denied permission outranks a registration failure — it is the one the owner can fix")
    }

    // MARK: - Cloud-retention cadence (32.R2)

    func testAutoPurgeRunsAtMostDaily() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(MonitoringEngine.autoPurgeDue(lastRun: nil, now: now), "first run is due")
        XCTAssertFalse(MonitoringEngine.autoPurgeDue(lastRun: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(MonitoringEngine.autoPurgeDue(lastRun: now.addingTimeInterval(-21 * 3600), now: now))
    }

    // MARK: - Dry-run entitlement snapshot (32.R3)

    /// `startDryRun` snapshots Pro (so an in-trial user's Pro rows work in Test Sensors), but
    /// nothing cleared it — and a dry run requires being disarmed, so no `disarm()` follows to
    /// clear it either. The stale snapshot kept `cloudAllowed` true after a trial lapsed,
    /// letting a connectivity flap re-establish the push subscription for a now-free user —
    /// the same class of leak the disarm path already closed (P-01).
    func testTestSensorsReleasesItsProSnapshotWhenItEnds() {
        let engine = makeEngine()
        engine.startDryRun()
        XCTAssertTrue(engine.armedPro, "the dry run runs with the session's real entitlement")
        engine.stopDryRun()
        XCTAssertFalse(engine.armedPro, "the Pro snapshot must not outlive the dry run")
    }

    // MARK: - The entitlement-resolution hook (fifth review, round 3)

    // The persisted recovery contract, spelled out deliberately: renaming a key on disk would
    // strand real users' owed re-arms, so a test that breaks on a rename is a feature.
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let recoveryTimeKey = "com.malinois.recovery.lastAt"
    private static let recoveryInProgressKey = "com.malinois.recovery.inProgress"

    private func clearRecoveryDefaults() {
        for key in [Self.pendingReArmKey, Self.recoveryTimeKey, Self.recoveryInProgressKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Round 3 of the fifth review: the engine is built inside the app's synchronous
    /// construction chain, so the entitlement check has NEVER resolved when the crash-recovery
    /// re-arm first runs — the 31.F2 gate defers it, and nothing deterministic re-ran it (the
    /// scene-activation pass merely races StoreKit; the sure path was an app switch). The hook
    /// releases the owed re-arm the moment the check resolves, so SECURITY.md's promise —
    /// "re-protects itself with a visible, cancellable grace countdown" — holds on the launch
    /// that matters, with the app simply left foregrounded.
    func testAnOwedReArmFiresOnceTheEntitlementCheckResolves() {
        clearRecoveryDefaults()
        defer { clearRecoveryDefaults() }
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)

        let entitlements = ProEntitlements.unresolvedForTesting()
        let engine = MonitoringEngine(settings: AppSettings(), eventStore: EventStore(),
                                      cloud: CloudExfiltrator(), camera: CameraController(),
                                      entitlements: entitlements)
        XCTAssertEqual(engine.state, .disarmed,
                       "unresolved check — the launch-time attempt defers behind the 31.F2 gate")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.pendingReArmKey),
                      "a deferred attempt must not consume the owed flag")

        entitlements.resolveForTesting(as: .free)   // recovery is not Pro-gated

        let deadline = Date().addingTimeInterval(2)
        while engine.state == .disarmed && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(engine.state, .arming,
                       "the countdown starts the moment the gate opens — no app switch needed")
        XCTAssertTrue(engine.armWasAutoRecovered,
                      "it is the crash-recovery arm, so cancelling it requires the PIN (R-04)")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.pendingReArmKey),
                       "the attempt consumes the owed flag")
        engine.disarm()   // cancelArming() correctly refuses an auto-recovered arm (R-04)
    }

    /// The hook's guard, pinned: resolution with nothing owed must change nothing — it can
    /// never become "arm on every launch". (Its other job, the pending-evidence retry, is
    /// deliberately kicked either way and no-ops off Pro.)
    func testResolutionWithNoReArmOwedDoesNotArm() {
        clearRecoveryDefaults()
        defer { clearRecoveryDefaults() }
        let entitlements = ProEntitlements.unresolvedForTesting()
        let engine = MonitoringEngine(settings: AppSettings(), eventStore: EventStore(),
                                      cloud: CloudExfiltrator(), camera: CameraController(),
                                      entitlements: entitlements)
        entitlements.resolveForTesting(as: .free)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(engine.state, .disarmed, "no owed re-arm — resolution alone must not arm")
    }

    // MARK: - Covert black must not reach the arming countdown (device pass, 2026-08-29)

    /// Found on device the first time the entitlement-resolution hook made the recovery
    /// countdown actually appear at cold launch: the scene-activation refresh landed
    /// mid-countdown and applied the covert ladder's black — `refreshBrightness` gated on
    /// `state.isActive`, which includes `.arming` — so the "visible, cancellable" cancel
    /// window (V-04) rendered at minimum backlight. Latent on the app-switch recovery path
    /// all along; a manual arm never hits it only because nothing happens to trigger the
    /// refresh mid-countdown (a slow camera warm-up finishing after the Guided Access
    /// confirmation could). Covert enforcement belongs to the covert screen.
    ///
    /// Pinned as a pure rule, deliberately narrower than `isActive` (which drives the
    /// app-switcher cover and answers a different question) — conflating the two is exactly
    /// what dimmed the countdown. An end-to-end simulator test is not constructible:
    /// `UIScreen.main.brightness` is inert there (the setter no-ops and the getter reads a
    /// constant 0.5), so the device observation above is the failing case of record, per the
    /// house rule for surfaces the OS owns.
    func testCovertBrightnessEnforcementAppliesOnlyToTheCovertScreen() {
        XCTAssertTrue(MonitoringEngine.enforcesCovertBrightness(.armed))
        XCTAssertTrue(MonitoringEngine.enforcesCovertBrightness(.triggered))
        XCTAssertFalse(MonitoringEngine.enforcesCovertBrightness(.disarmed))
        XCTAssertFalse(MonitoringEngine.enforcesCovertBrightness(.guidedAccessCheck))
        XCTAssertFalse(MonitoringEngine.enforcesCovertBrightness(.arming),
                       "the grace countdown is the owner's cancel window (V-04)")
        XCTAssertFalse(MonitoringEngine.enforcesCovertBrightness(.calibrating))
    }
}
