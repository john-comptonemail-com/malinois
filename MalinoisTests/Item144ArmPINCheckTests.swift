//
//  Item144ArmPINCheckTests.swift
//  MalinoisTests
//
//  BACKLOG 144 (c), item 145 step 8 (ADR 0054; the owner's ruling 2026-10-22: "options as recommended", 14 days and
//  option A). A forgotten Malinois PIN was found only at the disarm pad, after Guided Access had locked the phone in
//  the app. Now Home's ARM tap asks for the PIN first when it has not been entered correctly for 14 days, or when no
//  entry is on record (so an install updating to 1.8.1 is asked once). Every correct entry and every PIN set writes the
//  time beside the hash in the Keychain; a Face ID open never counts. PIN only, under the usual lockout; never in
//  front of the automatic re-arm. The Keychain tests skip on an unsigned build, as the suite's others do (a run script
//  counts a skip as a failure). The pad itself is rendered. Written before the change, red at that commit (against
//  compile-only stubs).
//
//  Item 162's G1 (1.8.2's step 21): Home's tap was checked through its rule and HomeView's source, since the harness
//  renders screens but cannot tap them. The tap's decision and its work (the camera question, then the arming screen)
//  are now the engine's (`armTapped`, `armAfterPINCheck`), driven here; Home only opens the pad the answer names.
//  Written before that change, red at its commit (against compile-only stubs).
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item144ArmPINCheckTests: XCTestCase {

    private let day: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem144ArmPIN")
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeEngine(camera: FakeCamera = FakeCamera(), settings: AppSettings = AppSettings()) -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                             camera: camera, entitlements: ProEntitlements(resolvedAs: .trial),
                                             timing: EngineCharacterizationTests.fastTiming))
    }

    private func plant(_ date: Date) {
        KeychainService.writeLastEntryForTesting(String(date.timeIntervalSince1970))
    }

    // MARK: - The rule

    /// Due with no correct entry on record, once 14 days have passed since the last one, or when the stored time lies
    /// ahead of the clock (it went back: ask rather than trust).
    func testTheRuleAsksWithNoEntryAfterFourteenDaysOrWithATimeAhead() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(MonitoringEngine.armPINCheckInterval, 14 * day, "the owner's ruling: 14 days")
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: nil, now: now), "none on record: asked once (option A)")
        XCTAssertFalse(MonitoringEngine.armPINCheckDue(lastEntry: now, now: now), "just entered")
        XCTAssertFalse(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-13 * day), now: now))
        XCTAssertFalse(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-14 * day + 1), now: now))
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-14 * day), now: now),
                      "14 days to the second")
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-400 * day), now: now))
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(60), now: now),
                      "a time ahead of the clock")
    }

    // MARK: - The time of the last correct entry

    /// Setting the PIN and a correct entry write the time; a wrong entry leaves it alone.
    func testANewPINAndACorrectEntryWriteTheTimeAndAWrongOneDoesNot() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let set = try XCTUnwrap(KeychainService.lastCorrectEntry, "setting the PIN writes the time")
        XCTAssertLessThan(abs(set.timeIntervalSinceNow), 5)
        let old = Date().addingTimeInterval(-20 * day)
        plant(old)
        XCTAssertFalse(KeychainService.verify("1111"), "a wrong PIN")
        let afterWrong = try XCTUnwrap(KeychainService.lastCorrectEntry)
        XCTAssertLessThan(abs(afterWrong.timeIntervalSince(old)), 1, "a wrong entry leaves the time alone")
        XCTAssertTrue(KeychainService.verify("4821"))
        let afterRight = try XCTUnwrap(KeychainService.lastCorrectEntry, "a correct entry writes the time")
        XCTAssertLessThan(abs(afterRight.timeIntervalSinceNow), 5)
    }

    /// The engine's answer from the real Keychain: not due with a fresh time; due with a stale, missing, unreadable,
    /// non-finite or future one.
    func testTheEngineAsksWhenTheTimeIsStaleMissingDamagedOrAheadAndNotWhenFresh() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let engine = makeEngine()
        XCTAssertFalse(engine.armPINCheckIsDue, "the PIN was just set")
        plant(Date().addingTimeInterval(-15 * day))
        XCTAssertTrue(engine.armPINCheckIsDue, "15 days without a correct entry")
        KeychainService.removeLastEntryForTesting()
        XCTAssertTrue(engine.armPINCheckIsDue, "none on record: an install updating to 1.8.1")
        KeychainService.writeLastEntryForTesting("not a time")
        XCTAssertTrue(engine.armPINCheckIsDue, "an unreadable time")
        KeychainService.writeLastEntryForTesting("inf")
        XCTAssertTrue(engine.armPINCheckIsDue, "a time that is not finite")
        plant(Date().addingTimeInterval(3 * day))
        XCTAssertTrue(engine.armPINCheckIsDue, "a time ahead of the clock")
    }

    // MARK: - Home

    /// The ARM tap's gate: PIN only, with its own prompt, opened only when the engine asks for the PIN.
    func testTheArmGateIsPINOnlyWithItsOwnPrompt() {
        XCTAssertEqual(HomeView.Gate.arm.prompt, "Enter PIN to arm")
        XCTAssertFalse(HomeView.Gate.arm.allowsBiometrics, "no Face ID: it proves nothing about remembering the PIN")
        XCTAssertEqual(HomeView.armTapGate(.askForPIN), .arm)
        XCTAssertNil(HomeView.armTapGate(.arming), "otherwise the tap arms at once")
    }

    /// The pad the gate opens shows the arm prompt.
    func testThePadShowsTheArmPrompt() throws {
        let settings = AppSettings()
        settings.biometricUnlock = true   // the owner's Face ID unlock on: the arm gate still never offers it
        let pad = PINEntryView(title: HomeView.Gate.arm.prompt, allowBiometrics: HomeView.Gate.arm.allowsBiometrics,
                               onSuccess: {}, onCancel: {})
            .environmentObject(settings)
        let shown = try shownOnScreen(pad).shown
        XCTAssertTrue(shown.contains("Enter PIN to arm"), "shown: \(shown)")
    }

    // MARK: - Home's ARM tap, in the engine (item 162's G1)

    /// What the engine's state was while the camera question was open.
    @MainActor
    private final class Seen {
        var state: MonitoringState?
    }

    /// Waits until `condition` holds, turning the main run loop meanwhile: the tap's work runs on a task.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// The check due: the tap asks for the PIN and starts nothing.
    func testTheARMTapAsksForThePINWhenTheCheckIsDueAndStartsNothing() {
        KeychainService.removeLastEntryForTesting()   // none on record: due
        let camera = FakeCamera()
        camera.videoPermission = .notDetermined
        let engine = makeEngine(camera: camera)
        XCTAssertEqual(engine.armTapped(), .askForPIN)
        XCTAssertFalse(waitUntil({ engine.state != .disarmed }, timeout: 0.5), "nothing starts before the PIN")
        XCTAssertEqual(camera.videoAccessRequests, 0, "not even the camera question")
    }

    /// The check not due: the tap begins the arming at once.
    func testTheARMTapArmsAtOnceWhenTheCheckIsNotDue() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")   // just set: not due
        let engine = makeEngine()
        XCTAssertEqual(engine.armTapped(), .arming)
        XCTAssertTrue(waitUntil({ engine.state != .disarmed }), "the arming begins")
        XCTAssertEqual(engine.state, .guidedAccessCheck, "the arming screen")
    }

    /// The arm gate's correct PIN begins the arming (Home's pad calls `armAfterPINCheck` on success).
    func testACorrectPINAtTheArmGateBeginsTheArming() {
        KeychainService.removeLastEntryForTesting()
        let engine = makeEngine()
        XCTAssertEqual(engine.armTapped(), .askForPIN)
        engine.armAfterPINCheck()
        XCTAssertTrue(waitUntil({ engine.state != .disarmed }), "the arming begins")
        XCTAssertEqual(engine.state, .guidedAccessCheck, "the arming screen")
    }

    /// The first ARM tap that needs the camera asks for it while still on Home (item 69), then arms.
    func testTheFirstARMTapAsksForTheCameraBeforeTheArming() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let camera = FakeCamera()
        camera.videoPermission = .notDetermined
        let engine = makeEngine(camera: camera)
        let seen = Seen()
        camera.duringVideoAccessRequest = { seen.state = engine.state }
        engine.armTapped()
        XCTAssertTrue(waitUntil({ engine.state != .disarmed }), "the arming begins")
        XCTAssertEqual(camera.videoAccessRequests, 1, "asked once")
        XCTAssertEqual(seen.state, .disarmed, "asked before the arming screen")
    }

    /// A refused camera still arms, with the existing "Camera access is denied" notice.
    func testARefusedCameraStillArms() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let camera = FakeCamera()
        camera.videoPermission = .notDetermined
        camera.videoAccessAnswer = .denied
        let engine = makeEngine(camera: camera)
        engine.armTapped()
        XCTAssertTrue(waitUntil({ engine.state != .disarmed }), "the arming begins")
        XCTAssertEqual(camera.videoAccessRequests, 1)
    }

    /// No camera question under Guided Access, where iOS would record it as a refusal; the tap arms.
    func testNoCameraQuestionUnderGuidedAccess() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let camera = FakeCamera()
        camera.videoPermission = .notDetermined
        let engine = makeEngine(camera: camera)
        engine.simulateGuidedAccessForTesting(on: true)
        engine.armTapped()
        XCTAssertTrue(waitUntil({ engine.state != .disarmed }), "arms under Guided Access")
        XCTAssertEqual(camera.videoAccessRequests, 0, "not asked under Guided Access")
    }

    /// No camera question with capture and Vision both off: nothing needs the camera; the tap arms.
    func testNoCameraQuestionWithoutACameraUse() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let camera = FakeCamera()
        camera.videoPermission = .notDetermined
        let settings = AppSettings()
        settings.enabledSensors.subtract([.camera, .vision])
        let engine = makeEngine(camera: camera, settings: settings)
        engine.armTapped()
        XCTAssertTrue(waitUntil({ engine.state != .disarmed }), "arms without a camera use")
        XCTAssertEqual(camera.videoAccessRequests, 0, "not asked: nothing needs the camera")
    }

    // MARK: - The automatic re-arm

    /// With no correct entry on record the ARM tap would ask, but the owed re-arm after a crash arms by itself: it calls
    /// the countdown directly and never meets the check.
    func testTheAutomaticReArmNeverMeetsTheCheck() {
        KeychainService.removeLastEntryForTesting()
        UserDefaults.standard.set(true, forKey: "com.malinois.recovery.pendingReArm")
        let entitlements = ProEntitlements.unresolvedForTesting()
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        entitlements.resolveForTesting(as: .free)
        let deadline = Date().addingTimeInterval(3)
        while engine.state != .arming && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(engine.state, .arming, "the owed re-arm starts its countdown without a PIN")
        engine.disarm()
    }
}
