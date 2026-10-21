//
//  Item107DisarmTipTests.swift
//  MalinoisTests
//
//  BACKLOG 107 (1.6; owner's request 2026-10-12). Owners missed how to disarm: the arming
//  screen's card was small and the 5-second hold sat inside its first step. The card now leads
//  with the hold in large type, the countdown repeats it, and until the owner has disarmed once
//  from the black screen the tamper warning shows it too. An install that had armed before this
//  build counts as having disarmed, so existing owners never show the hold to an intruder.
//  Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

final class Item107DisarmTipTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The tip under the warning

    /// The warning carries the tip until the first disarm, then never.
    func testTheWarningShowsTheTipOnlyUntilTheFirstDisarm() {
        XCTAssertEqual(DisarmTip.alertTip(hasDisarmedOnce: false), DisarmTip.alertTipText)
        XCTAssertNil(DisarmTip.alertTip(hasDisarmedOnce: true), "after the first disarm the warning shows no hold")
    }

    /// Each text names the hold and its length; the tip and the reminder name the PIN. They are
    /// alert-screen and arming-screen copy, so no em-dash (B16).
    func testTheTextsNameTheHoldAndThePIN() {
        for copy in [DisarmTip.holdHeadline, DisarmTip.countdownReminder, DisarmTip.alertTipText] {
            XCTAssertTrue(copy.localizedCaseInsensitiveContains("hold"), copy)
            XCTAssertTrue(copy.contains("5 seconds"), copy)
        }
        XCTAssertTrue(DisarmTip.alertTipText.contains("PIN"))
        XCTAssertTrue(DisarmTip.countdownReminder.contains("PIN"))
        XCTAssertFalse(DisarmTip.alertTipFootnote.isEmpty)
        for copy in [DisarmTip.holdHeadline, DisarmTip.countdownReminder, DisarmTip.alertTipText,
                     DisarmTip.alertTipFootnote] {
            XCTAssertFalse(copy.contains("\u{2014}"), "no em-dash (B16): \(copy)")
        }
    }

    // MARK: - Who starts with the tip

    /// A new install starts with the tip; an install that armed before this build does not; a
    /// stored value always wins, so a new install's first watch going live does not end the tip.
    func testANewInstallStartsWithTheTipAndAnEarlierOwnerDoesNot() {
        XCTAssertFalse(DisarmTip.initialHasDisarmedOnce(stored: nil, hasArmedOnce: false), "new install: tip due")
        XCTAssertTrue(DisarmTip.initialHasDisarmedOnce(stored: nil, hasArmedOnce: true), "armed before this build: no tip")
        XCTAssertFalse(DisarmTip.initialHasDisarmedOnce(stored: false, hasArmedOnce: true), "the stored value wins")
        XCTAssertTrue(DisarmTip.initialHasDisarmedOnce(stored: true, hasArmedOnce: false), "the stored value wins")
    }

    /// Live defaults: the starting value is written once, a first watch going live does not end the
    /// tip, the first disarm does, and an install that armed before this build starts without it.
    func testTheStartingValueIsWrittenOnceAndTheFirstDisarmEndsTheTip() {
        let defaults = UserDefaults.standard
        let disarmedKey = "com.malinois.onboarding.hasDisarmedOnce"
        let armedKey = "com.malinois.onboarding.hasArmedOnce"
        let saved = (disarmed: defaults.object(forKey: disarmedKey), armed: defaults.object(forKey: armedKey))
        defer {
            defaults.set(saved.disarmed, forKey: disarmedKey)   // nil removes the key
            defaults.set(saved.armed, forKey: armedKey)
        }

        defaults.removeObject(forKey: disarmedKey)
        OnboardingState.hasArmedOnce = false
        OnboardingState.seedHasDisarmedOnce()                  // first launch of a new install
        XCTAssertNotNil(defaults.object(forKey: disarmedKey), "the starting value is stored")
        XCTAssertFalse(OnboardingState.hasDisarmedOnce, "a new install starts with the tip")

        OnboardingState.hasArmedOnce = true                    // the first watch went live
        OnboardingState.seedHasDisarmedOnce()                  // a later launch
        XCTAssertFalse(OnboardingState.hasDisarmedOnce, "going live does not end the tip; a disarm does")

        OnboardingState.hasDisarmedOnce = true                 // the first disarm
        OnboardingState.seedHasDisarmedOnce()
        XCTAssertTrue(OnboardingState.hasDisarmedOnce)

        defaults.removeObject(forKey: disarmedKey)             // an install that armed before this build
        OnboardingState.seedHasDisarmedOnce()
        XCTAssertTrue(OnboardingState.hasDisarmedOnce, "an earlier owner never shows the tip")
    }

    // MARK: - Wiring (source checks)

    /// The armed screen's warning shows the tip while it is due, and not after the first disarm, as
    /// laid out (item 124's test housekeeping: this read the screen's source before).
    @MainActor
    func testTheArmedScreensWarningShowsTheTipUntilTheFirstDisarm() throws {
        TestIsolation.setUp(folderPrefix: "Item107DisarmTipTests-armed")
        let firstDisarm = OnboardingState.hasDisarmedOnce
        defer {
            OnboardingState.hasDisarmedOnce = firstDisarm
            TestIsolation.tearDown()
        }
        var timing = EngineCharacterizationTests.fastTiming
        timing.alertDuration = 60
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while engine.state != .armed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        engine.reportTouch()
        let alertBy = Date().addingTimeInterval(5)
        while !engine.alertActive && Date() < alertBy { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(engine.alertActive, "the warning is up")
        let armed = ArmedView().environmentObject(engine).environmentObject(settings).environmentObject(CameraController())
        let tip = try XCTUnwrap(DisarmTip.alertTip(hasDisarmedOnce: false))
        OnboardingState.hasDisarmedOnce = false
        XCTAssertTrue(try shownOnScreen(armed).shown.contains(tip), "the warning gets the tip while it is due")
        OnboardingState.hasDisarmedOnce = true
        XCTAssertFalse(try shownOnScreen(armed).shown.contains(tip), "and not after the first disarm")
        engine.disarm()
    }

    /// A correct PIN on the black screen records the first disarm; the app writes the starting value
    /// at launch. Read from the source: no unit test can type a PIN on the pad or launch the app.
    func testTheArmedScreenRecordsTheFirstDisarm() throws {
        let armed = try text("Malinois/Views/ArmedView.swift")
        let success = try XCTUnwrap(armed.range(of: "onSuccess: {"))
        let handler = armed[success.upperBound...].prefix(400)
        XCTAssertTrue(handler.contains("OnboardingState.hasDisarmedOnce = true"),
                      "a correct PIN on the black screen ends the tip")
        let app = try text("Malinois/MalinoisApp.swift")
        XCTAssertTrue(app.contains("OnboardingState.seedHasDisarmedOnce()"), "the starting value is written at launch")
    }

    /// The arming screen's card leads with the hold, above Start countdown, and the countdown
    /// repeats it: checked on the screens as laid out (item 124's test housekeeping: this read the
    /// screens' source before).
    @MainActor
    func testTheArmingScreenLeadsWithTheHoldAndTheCountdownRepeatsIt() throws {
        TestIsolation.setUp(folderPrefix: "Item107DisarmTipTests-arming")
        defer { TestIsolation.tearDown() }
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.beginArming()
        let screen = ArmingView().environmentObject(engine).environmentObject(entitlements).environmentObject(settings)
        let step = try shownOnScreen(screen)
        let hold = try XCTUnwrap(step.frames[DisarmTip.holdHeadline], "the card's headline is the hold")
        let start = try XCTUnwrap(step.frames["Start countdown"], "the Guided Access step's Start countdown")
        XCTAssertLessThan(hold.minY, start.minY, "the card comes before Start countdown")
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(engine.state, .arming, "counting down")
        XCTAssertTrue(try shownOnScreen(screen).shown.contains(DisarmTip.countdownReminder), "the countdown repeats the hold")
        engine.cancelArming()
    }

    // MARK: - The owner's follow-up for 1.6 (65)

    /// The owner (2026-10-13): the armed screen is not always black (on a charger it is dimmed,
    /// and Alert mode shows the warning), so the hold names "the screen", and the countdown's
    /// reminder is red so that it stands out, above all under Guided Access, where the hold and
    /// the PIN are the only way back in.
    func testTheHoldNamesTheScreenAndTheCountdownShowsItInRed() throws {
        for copy in [DisarmTip.holdHeadline, DisarmTip.countdownReminder] {
            XCTAssertFalse(copy.contains("black"), copy)
        }
        XCTAssertTrue(DisarmTip.countdownReminder.contains("press and hold the screen for 5 seconds"))
        let arming = try text("Malinois/Views/ArmingView.swift")
        let reminder = try XCTUnwrap(arming.range(of: "Label(DisarmTip.countdownReminder"))
        XCTAssertTrue(arming[reminder.upperBound...].prefix(240).contains(".foregroundStyle(.red)"), "the reminder is red")
        let grace = try XCTUnwrap(arming.range(of: "private var graceStep: some View {"))
        XCTAssertFalse(arming[grace.upperBound...].prefix(900).contains("The screen will go black."),
                       "the countdown does not promise a black screen either")
    }
}
