//
//  Item82BiometricWordingTests.swift
//  MalinoisTests
//
//  BACKLOG 82, fix 3 (1.4): four on-screen texts named Face ID on every iPhone, wrong on the
//  Touch ID iPhones the app supports (iPhone SE, 2nd and 3rd generation). They now name what
//  LocalAuthentication reports. The unlock itself already covered Touch ID. The Touch ID prompt's
//  reason line also claimed "settings", which never opens by Face ID or Touch ID. Written before
//  the change, red at that commit.
//

import XCTest
import LocalAuthentication
@testable import Malinois

final class Item82BiometricWordingTests: XCTestCase {

    /// Each biometric is named as iOS names it, and so is its iOS Settings screen.
    func testEachBiometricIsNamedAsIOSNamesIt() {
        XCTAssertEqual(BiometricKind(.faceID), .faceID)
        XCTAssertEqual(BiometricKind(.touchID), .touchID)
        XCTAssertEqual(BiometricKind(.opticID), .opticID)
        XCTAssertEqual(BiometricKind(.none), .none)

        XCTAssertEqual(BiometricKind.faceID.name, "Face ID")
        XCTAssertEqual(BiometricKind.touchID.name, "Touch ID")
        XCTAssertEqual(BiometricKind.opticID.name, "Optic ID")
        XCTAssertEqual(BiometricKind.none.name, "Face ID or Touch ID")

        XCTAssertEqual(BiometricKind.faceID.settingsScreen, "Face ID & Passcode")
        XCTAssertEqual(BiometricKind.touchID.settingsScreen, "Touch ID & Passcode")
        XCTAssertEqual(BiometricKind.opticID.settingsScreen, "Optic ID & Passcode")
        // Item 89 C2: no supported iPhone has a screen called only "Passcode"; both real ones are named.
        XCTAssertEqual(BiometricKind.none.settingsScreen, "Face ID & Passcode (or Touch ID & Passcode)")
    }

    /// The four texts on a Touch ID iPhone.
    func testATouchIDIPhoneIsToldAboutTouchID() {
        let kind = BiometricKind.touchID
        XCTAssertEqual(kind.unlockToggleTitle, "Touch ID unlock")
        XCTAssertEqual(kind.unlockToggleCaption,
                       "Open the Event Log and Test Sensors with Touch ID instead of the PIN. Settings, disarming, "
                       + "and changing the PIN always require the PIN: a finger can be presented; a PIN has to be given.")
        XCTAssertEqual(kind.recoveryNeedsPasscode,
                       "Recovery requires a device passcode. Set one in iOS Settings → Touch ID & Passcode, then tap Try Again.")
        XCTAssertEqual(kind.guidedAccessCaption, "Touch ID is unavailable during Guided Access - enter your PIN.")
    }

    /// A Face ID iPhone keeps today's words.
    func testAFaceIDIPhoneKeepsTodaysWords() {
        let kind = BiometricKind.faceID
        XCTAssertEqual(kind.unlockToggleTitle, "Face ID unlock")
        XCTAssertEqual(kind.unlockToggleCaption,
                       "Open the Event Log and Test Sensors with Face ID instead of the PIN. Settings, disarming, "
                       + "and changing the PIN always require the PIN: a face can be presented; a PIN has to be given.")
        XCTAssertEqual(kind.recoveryNeedsPasscode,
                       "Recovery requires a device passcode. Set one in iOS Settings → Face ID & Passcode, then tap Try Again.")
        XCTAssertEqual(kind.guidedAccessCaption, "Face ID is unavailable during Guided Access - enter your PIN.")
    }

    /// The Touch ID prompt shows its reason line (Face ID's does not): it names only what a
    /// biometric can open, never Settings. And no text on screen carries an em-dash.
    func testThePromptReasonNamesOnlyWhatABiometricOpensAndNoTextHasAnEmDash() {
        XCTAssertEqual(BiometricKind.unlockPromptReason, "Open the Event Log or Test Sensors")
        for kind in BiometricKind.allCases {
            for text in [kind.unlockToggleTitle, kind.unlockToggleCaption, kind.recoveryNeedsPasscode,
                         kind.guidedAccessCaption, BiometricKind.unlockPromptReason] {
                XCTAssertFalse(text.contains("\u{2014}"), "\(kind): \(text)")
            }
        }
    }

    /// The recovery text sends the owner to a Settings screen that exists (item 89, C2). With no
    /// biometry reported (a phone without a passcode can read that way), "Passcode" alone named a
    /// screen no supported iPhone has; the fallback names both real ones.
    func testThePasscodeFallbackNamesAScreenThatExists() {
        XCTAssertEqual(BiometricKind.faceID.settingsScreen, "Face ID & Passcode")
        XCTAssertEqual(BiometricKind.touchID.settingsScreen, "Touch ID & Passcode")
        XCTAssertEqual(BiometricKind.none.settingsScreen, "Face ID & Passcode (or Touch ID & Passcode)")
        XCTAssertTrue(BiometricKind.none.recoveryNeedsPasscode.contains("iOS Settings → Face ID & Passcode (or Touch ID & Passcode)"))
    }
}
