import XCTest
@testable import Malinois

/// Item 140's in-app wording (B1 to B4 and B6, from the top-down review of 1.8 (73)): the app's own words state as
/// outcomes what the code attempts (an upload, an alert), promise what Guided Access does not guarantee, describe
/// Vision as charging-only, and call a permanent hold "paused". The words now say what the code does.
@MainActor
final class Item140WordingTests: XCTestCase {
    /// Words that state an attempt as an outcome: an upload or an alert can fail, and SECURITY.md says so.
    private let outcomeWords = ["instant", "the moment", "survives"]

    private func promisesAnOutcome(_ text: String) -> Bool {
        let lower = text.lowercased()
        return outcomeWords.contains { lower.contains($0) }
    }

    func testThePaywallStatesAttemptsNotOutcomes() {
        for benefit in PaywallView.benefits {
            XCTAssertFalse(promisesAnOutcome(benefit.title + " " + benefit.detail), benefit.title)
        }
    }

    func testTheFirstRunProScreenStatesAttemptsNotOutcomes() {
        for row in TrialWelcomeView.proRows {
            XCTAssertFalse(promisesAnOutcome(row.1 + " " + row.2), row.1)
        }
    }

    /// Vision runs whenever the camera is warm: on a charger in the default Auto readiness, always in Instant.
    func testVisionIsDescribedAsRunningWhileTheCameraIsReady() throws {
        let paywall = try XCTUnwrap(PaywallView.benefits.first { $0.feature == .visionSensor })
        XCTAssertTrue(paywall.detail.contains("camera is ready"), paywall.detail)
        let firstRun = try XCTUnwrap(TrialWelcomeView.proRows.first { $0.1 == "The Vision tripwire" })
        XCTAssertTrue(firstRun.2.contains("camera is ready"), firstRun.2)
    }

    /// SECURITY.md: call and Siri behaviour has varied across the owner's tests; neither is an unconditional
    /// no-interruption guarantee. And the event's record is pushed before the photo, so "nothing would have reached
    /// your iCloud" was not so.
    func testTheGuidedAccessScreenPromisesNoUninterruptedMonitoring() {
        XCTAssertFalse(GuidedAccessPromptView.callsAndSiri.contains("can interrupt monitoring"))
        XCTAssertFalse(GuidedAccessPromptView.sessionNotice.contains("nothing would have reached your iCloud"))
    }

    /// The camera permission covers Vision too: with it on, the camera watches its view while it is ready.
    func testTheCameraPermissionNamesVision() throws {
        let text = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)
        XCTAssertTrue(text.contains("Vision"), text)
    }

    /// Events recorded before the install's first verification never upload (item 140's A2): not "paused".
    /// Since 1.8.2 in what Malinois does, not where the events stay (item 168's deepseek-flash-3).
    func testHomeSaysMalinoisWontUploadEventsRecordedBeforeVerification() {
        XCTAssertTrue(HomeView.iCloudPausedNotice.contains("Malinois won't upload events recorded before then"),
                      HomeView.iCloudPausedNotice)
    }

    // MARK: - Item 162's B1 (1.8.2's step 7)

    /// Stealth's caption promised an upload whatever the iCloud backup switch said; an upload needs the switch, Pro and
    /// the install's verification. The owner's wording. Red at the step's red commit: "Evidence is still captured and
    /// uploaded."
    func testStealthsCaptionSaysUploadsNeedICloudBackup() {
        let caption = SettingsView.responseHint(for: .stealth)
        XCTAssertTrue(caption.hasSuffix("Evidence is still captured, and uploaded when iCloud backup is on (Pro)."), caption)
        XCTAssertFalse(caption.contains("captured and uploaded."), caption)
    }
}
