//
//  Item155PasscodeLineTests.swift
//  MalinoisTests
//
//  1.8.2's step 34 (item 155's F3, the fresh review's fable-4): on an iPhone without a device passcode a forced restart
//  opens the phone and ends Guided Access, and the app never said so. The arming screen now says it in one line, worded
//  as the owner approved (2026-10-23, the plan's "agree all"), naming this phone's Settings screen, whenever iOS
//  answers that no passcode is set: read when the screen appears, and again when the app is back on it from Settings.
//

import XCTest
import LocalAuthentication
@testable import Malinois

@MainActor
final class Item155PasscodeLineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem155Passcode")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func engine() -> (MonitoringEngine, AppSettings, ProEntitlements) {
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let entitlements = ProEntitlements(resolvedAs: .free)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, settings, entitlements)
    }

    /// Only iOS's "no passcode is set" counts: a check that runs, or one that cannot for another reason (Face ID locked
    /// out, no screen to show it on), says nothing about the passcode.
    func testOnlyNoPasscodeSetCounts() {
        func laError(_ code: LAError.Code) -> NSError { NSError(domain: LAErrorDomain, code: code.rawValue) }
        XCTAssertTrue(MonitoringEngine.passcodeMissing(canEvaluate: false, error: laError(.passcodeNotSet)))
        XCTAssertFalse(MonitoringEngine.passcodeMissing(canEvaluate: true, error: nil))
        XCTAssertFalse(MonitoringEngine.passcodeMissing(canEvaluate: false, error: nil))
        XCTAssertFalse(MonitoringEngine.passcodeMissing(canEvaluate: false, error: laError(.biometryLockout)))
        XCTAssertFalse(MonitoringEngine.passcodeMissing(canEvaluate: false, error: laError(.notInteractive)))
        XCTAssertFalse(MonitoringEngine.passcodeMissing(
            canEvaluate: false, error: NSError(domain: NSCocoaErrorDomain, code: LAError.Code.passcodeNotSet.rawValue)),
            "the number alone, from another domain, is not iOS's answer")
    }

    /// The line as the owner approved it, naming this phone's Settings screen.
    func testTheLineReadsAsApproved() {
        XCTAssertEqual(BiometricKind.faceID.noPasscodeWarning, "This iPhone has no passcode, so a forced restart opens it "
                       + "and ends Guided Access. Set one in Settings → Face ID & Passcode.")
        XCTAssertEqual(BiometricKind.touchID.noPasscodeWarning, "This iPhone has no passcode, so a forced restart opens it "
                       + "and ends Guided Access. Set one in Settings → Touch ID & Passcode.")
    }

    /// The arming screen shows the line on a phone without a passcode, and not on one with.
    func testTheArmingScreenShowsTheLineOnlyWithoutAPasscode() throws {
        for missing in [true, false] {
            let (engine, settings, entitlements) = engine()
            engine.devicePasscodeMissingForTesting = missing
            engine.beginArming()
            XCTAssertEqual(engine.state, .guidedAccessCheck)
            let shown = try shownOnScreen(ArmingView()
                .environmentObject(engine)
                .environmentObject(entitlements)
                .environmentObject(settings)).shown
            XCTAssertEqual(shown.contains(BiometricKind.current.noPasscodeWarning), missing,
                           "without a passcode: \(missing); shown: \(shown)")
            engine.cancelArming()
        }
    }

    /// Back on the arming screen from Settings with a passcode set, the line goes: the check runs again when the app
    /// is active again, there.
    func testTheCheckRunsAgainWhenTheAppIsBackOnTheArmingScreen() {
        let (engine, _, _) = engine()
        engine.devicePasscodeMissingForTesting = true
        engine.beginArming()
        engine.refreshDevicePasscode()
        XCTAssertTrue(engine.devicePasscodeMissing, "no passcode")
        engine.devicePasscodeMissingForTesting = false   // set in Settings meanwhile
        engine.handleScenePhase(true)
        XCTAssertFalse(engine.devicePasscodeMissing, "the line goes on the way back")
        engine.cancelArming()
    }
}
