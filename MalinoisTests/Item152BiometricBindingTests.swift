//
//  Item152BiometricBindingTests.swift
//  MalinoisTests
//
//  BACKLOG 152's lead 4, item 145 step 13 (ADR 0056). Face ID or Touch ID unlock (off by default) opened the Event
//  Log and Test Sensors on any face or finger enrolled on the iPhone, including one added later with the iPhone
//  passcode by someone who does not know the Malinois PIN. Now turning the unlock on in Settings binds it to the
//  biometrics enrolled at that moment (iOS's domain state, kept in the Keychain, this device only); the pad offers
//  the biometric only while the current state matches, and otherwise turns the unlock off and says why, so the PIN
//  stands until the owner turns it on again in Settings, behind the PIN. iOS's state is injected through a Debug seam:
//  the simulator enrolls nothing. Written before the change, red at that commit (against compile-only stubs).
//

import LocalAuthentication
import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item152BiometricBindingTests: XCTestCase {

    private let stateA = Data("enrolled-A".utf8)
    private let stateB = Data("enrolled-B".utf8)

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152Binding")
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
        BiometricBinding.stateForTesting = nil
        BiometricBinding.canEvaluateForTesting = nil
    }

    override func tearDown() {
        BiometricBinding.stateForTesting = nil
        BiometricBinding.canEvaluateForTesting = nil
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// The Keychain tests skip on an unsigned build, as the suite's others do (a run script counts a skip as a failure).
    private func requireKeychain() throws {
        try XCTSkipUnless(KeychainService.recordEnrolledBiometricState(Data("probe".utf8)), "Keychain unavailable")
        KeychainService.clearEnrolledBiometricState()
    }

    // MARK: - The rule

    /// Bound while the state iOS reports now equals the one stored at opt-in; unbound with none stored; changed when
    /// they differ or iOS reports none.
    func testTheRuleTellsBoundFromUnboundAndChanged() {
        XCTAssertEqual(BiometricBinding.verdict(stored: nil, current: stateA), .unbound, "nothing stored: never bound")
        XCTAssertEqual(BiometricBinding.verdict(stored: Data(), current: stateA), .unbound, "an empty record is none")
        XCTAssertEqual(BiometricBinding.verdict(stored: stateA, current: stateA), .bound)
        XCTAssertEqual(BiometricBinding.verdict(stored: stateA, current: stateB), .changed, "a face or finger added or removed")
        XCTAssertEqual(BiometricBinding.verdict(stored: stateA, current: nil), .changed, "iOS reports no enrolment now")
        XCTAssertEqual(BiometricBinding.verdict(stored: stateA, current: Data()), .changed)
    }

    // MARK: - The Keychain

    /// The binding is kept in the Keychain: written, updated in place, read back and cleared.
    func testTheKeychainKeepsTheBinding() throws {
        try requireKeychain()
        XCTAssertNil(KeychainService.enrolledBiometricState, "none on record to begin with")
        XCTAssertTrue(KeychainService.recordEnrolledBiometricState(stateA))
        XCTAssertEqual(KeychainService.enrolledBiometricState, stateA)
        XCTAssertTrue(KeychainService.recordEnrolledBiometricState(stateB), "updated in place")
        XCTAssertEqual(KeychainService.enrolledBiometricState, stateB)
        KeychainService.clearEnrolledBiometricState()
        XCTAssertNil(KeychainService.enrolledBiometricState)
    }

    // MARK: - Settings

    /// Turning the unlock on binds it to the state iOS reports now; turning it off clears the binding. With no state to
    /// read (no biometric enrolled), it turns on unbound, and the first offer then turns it off again.
    func testTurningTheUnlockOnBindsItAndOffClearsIt() throws {
        try requireKeychain()
        let settings = AppSettings()
        BiometricBinding.canEvaluateForTesting = true
        BiometricBinding.stateForTesting = { [stateA] in stateA }
        BiometricBinding.setUnlock(true, settings: settings)
        XCTAssertTrue(settings.biometricUnlock)
        XCTAssertEqual(KeychainService.enrolledBiometricState, stateA, "bound to what is enrolled now")
        BiometricBinding.setUnlock(false, settings: settings)
        XCTAssertFalse(settings.biometricUnlock)
        XCTAssertNil(KeychainService.enrolledBiometricState, "off clears the binding")
        BiometricBinding.canEvaluateForTesting = false
        BiometricBinding.setUnlock(true, settings: settings)
        XCTAssertTrue(settings.biometricUnlock, "on, with nothing to bind to")
        XCTAssertNil(KeychainService.enrolledBiometricState)
    }

    /// Settings' toggle goes through the binding, not straight to the setting (the harness cannot flip a toggle: read
    /// from the screen's source).
    func testSettingsToggleGoesThroughTheBinding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Malinois/Views/SettingsView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "get: { settings.biometricUnlock },"), "the toggle not found")
        let setter = source[start.upperBound...].prefix(160)
        XCTAssertTrue(setter.contains("BiometricBinding.setUnlock("), "the toggle's setter does not bind: \(setter)")
    }

    // MARK: - The pad

    /// Before any offer: a changed enrolment, or none on record, turns the unlock off and clears the binding, with the
    /// verdict for the caption; a matching one leaves everything as it is.
    func testAChangedEnrolmentTurnsTheUnlockOffBeforeAnyOffer() throws {
        try requireKeychain()
        let settings = AppSettings()
        settings.biometricUnlock = true
        KeychainService.recordEnrolledBiometricState(stateA)
        BiometricBinding.stateForTesting = { [stateB] in stateB }
        XCTAssertEqual(BiometricBinding.checkBeforeOffer(context: LAContext(), settings: settings), .changed)
        XCTAssertFalse(settings.biometricUnlock, "off until Settings turns it on again")
        XCTAssertNil(KeychainService.enrolledBiometricState, "the binding is cleared with it")

        settings.biometricUnlock = true
        KeychainService.recordEnrolledBiometricState(stateA)
        BiometricBinding.stateForTesting = { [stateA] in stateA }
        XCTAssertEqual(BiometricBinding.checkBeforeOffer(context: LAContext(), settings: settings), .bound)
        XCTAssertTrue(settings.biometricUnlock, "a match changes nothing")
        XCTAssertEqual(KeychainService.enrolledBiometricState, stateA)

        KeychainService.clearEnrolledBiometricState()
        XCTAssertEqual(BiometricBinding.checkBeforeOffer(context: LAContext(), settings: settings), .unbound,
                       "an install updating with the unlock on: nothing on record")
        XCTAssertFalse(settings.biometricUnlock)
    }

    /// The pad itself, on the real path: appearing with the unlock on and a changed enrolment, it turns the unlock off,
    /// shows the caption and leaves the PIN pad standing; with none on record, the other caption.
    func testThePadSaysWhyAndKeepsThePIN() throws {
        try requireKeychain()
        let settings = AppSettings()
        settings.biometricUnlock = true
        KeychainService.recordEnrolledBiometricState(stateA)
        BiometricBinding.canEvaluateForTesting = true
        BiometricBinding.stateForTesting = { [stateB] in stateB }
        var shown = try shownOnScreen(pad(settings)).shown
        XCTAssertTrue(shown.contains(BiometricKind.current.bindingCaption(for: .changed)), "shown: \(shown)")
        XCTAssertTrue(shown.contains("Enter PIN"), "the pad stands")
        XCTAssertFalse(settings.biometricUnlock, "the unlock is off")
        XCTAssertNil(KeychainService.enrolledBiometricState)

        settings.biometricUnlock = true   // an install updating with the unlock on, nothing on record
        shown = try shownOnScreen(pad(settings)).shown
        XCTAssertTrue(shown.contains(BiometricKind.current.bindingCaption(for: .unbound)), "shown: \(shown)")
        XCTAssertFalse(settings.biometricUnlock)
    }

    private func pad(_ settings: AppSettings) -> some View {
        PINEntryView(title: "Enter PIN", allowBiometrics: true, onSuccess: {}, onCancel: {})
            .environmentObject(settings)
    }

    // MARK: - The captions

    /// Each caption names the phone's biometric, says what happened and what to do, and never blocks the PIN.
    func testTheCaptionsNameTheBiometricAndSayWhatToDo() {
        XCTAssertEqual(BiometricKind.faceID.bindingCaption(for: .changed),
                       "Face ID unlock turned off: a face or finger was added or removed on this iPhone since you turned "
                       + "it on. Enter your PIN; to use Face ID again, turn it on in Settings.")
        XCTAssertEqual(BiometricKind.touchID.bindingCaption(for: .changed),
                       "Touch ID unlock turned off: a face or finger was added or removed on this iPhone since you turned "
                       + "it on. Enter your PIN; to use Touch ID again, turn it on in Settings.")
        XCTAssertEqual(BiometricKind.faceID.bindingCaption(for: .unbound),
                       "Face ID unlock is off until you turn it on again in Settings, which now ties it to the faces "
                       + "enrolled on this iPhone. Enter your PIN.")
        XCTAssertEqual(BiometricKind.touchID.bindingCaption(for: .unbound),
                       "Touch ID unlock is off until you turn it on again in Settings, which now ties it to the fingers "
                       + "enrolled on this iPhone. Enter your PIN.")
        XCTAssertEqual(BiometricKind.none.bindingCaption(for: .unbound),
                       "Face ID or Touch ID unlock is off until you turn it on again in Settings, which now ties it to "
                       + "the faces or fingers enrolled on this iPhone. Enter your PIN.")
        XCTAssertEqual(BiometricKind.faceID.bindingCaption(for: .bound), "", "nothing to say while bound")
    }
}
