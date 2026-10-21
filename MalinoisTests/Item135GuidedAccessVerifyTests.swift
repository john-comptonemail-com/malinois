import XCTest
@testable import Malinois

/// Item 135 (the owner's report, 2026-10-19; ruled "1 b"): under Guided Access iOS holds the Face ID / passcode sheet
/// until Guided Access ends (BACKLOG 44), so `CloudEnrollment.deviceAuthentication` refuses at once, and Settings'
/// Verify iCloud access did nothing visible. While Guided Access is on, the button is greyed out and its caption says
/// why; a verification that still fails with Guided Access on says so, instead of "retry while disarmed".
@MainActor
final class Item135GuidedAccessVerifyTests: XCTestCase {
    private final class GuidedAccess { var on = false }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem135")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func file() -> URL {
        (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
    }

    // MARK: The button

    func testVerifyIsGreyedOutWhileGuidedAccessIsOn() {
        XCTAssertFalse(SettingsView.verifyAvailable(guidedAccess: true, busy: false, disarmed: true))
    }

    func testVerifyIsOfferedWhenDisarmedIdleAndGuidedAccessIsOff() {
        XCTAssertTrue(SettingsView.verifyAvailable(guidedAccess: false, busy: false, disarmed: true))
    }

    func testVerifyStaysGreyedOutWhileBusyOrArmed() {
        for guidedAccess in [false, true] {
            XCTAssertFalse(SettingsView.verifyAvailable(guidedAccess: guidedAccess, busy: true, disarmed: true))
            XCTAssertFalse(SettingsView.verifyAvailable(guidedAccess: guidedAccess, busy: false, disarmed: false))
        }
    }

    // MARK: The caption under it

    func testTheCaptionSaysWhyWhileGuidedAccessIsOn() {
        XCTAssertEqual(SettingsView.verifyCaption(guidedAccess: true),
                       "End Guided Access to verify: iOS holds Face ID and passcode prompts until it ends.")
    }

    func testTheCaptionIsUnchangedWhileGuidedAccessIsOff() {
        XCTAssertEqual(SettingsView.verifyCaption(guidedAccess: false),
                       "Uses Face ID, Touch ID, or your device passcode. End Guided Access before verifying. Evidence already tied to another or unknown account stays local.")
    }

    // MARK: A verification that fails, through `CloudEnrollment.enroll`

    func testAVerificationThatFailsWithGuidedAccessOnSaysSo() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in false }, guidedAccess: { true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
        XCTAssertFalse(gate.verified)
        XCTAssertEqual(gate.notice, "Verification did not complete: Guided Access was on. Local monitoring remains available.")
        XCTAssertEqual(gate.notice, CloudEnrollment.guidedAccessNotice)
    }

    func testAVerificationThatFailsWithGuidedAccessOffKeepsItsNotice() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in false }, guidedAccess: { false })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertFalse(enrolled)
        XCTAssertEqual(gate.notice, "Verification did not complete. Local monitoring remains available; retry while disarmed.")
    }

    /// The tap came before Guided Access started (the button was still offered); Guided Access is read when the
    /// verification fails, not when it began.
    func testGuidedAccessThatStartsDuringTheVerificationIsNamed() async {
        let guidedAccess = GuidedAccess()
        let gate = CloudEnrollment(file: file(), authenticate: { _ in guidedAccess.on = true; return false },
                                   guidedAccess: { guidedAccess.on })
        _ = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertEqual(gate.notice, CloudEnrollment.guidedAccessNotice)
    }

    /// The check changes only what a failure says: it never stops a verification that succeeds.
    func testASuccessfulVerificationIsUnaffected() async {
        let gate = CloudEnrollment(file: file(), authenticate: { _ in true }, guidedAccess: { true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        XCTAssertTrue(gate.verified)
        XCTAssertEqual(gate.notice, "This installation is verified for iCloud. Evidence from an unknown or different account stays local.")
    }
}
