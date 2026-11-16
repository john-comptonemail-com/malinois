//
//  Item240OnboardingTests.swift
//  MalinoisTests
//
//  1.13's onboarding (BACKLOG items 221 and 240; docs/design/onboarding.md, APPROVED 2026-11-12: "D1-D3 and V1-V3
//  (a), wording approved", then "(a), (i), 1 to 4 approved"). The first batch: the welcome screen on an install with no
//  PIN, and what the first launch routes to; Home's card after the first disarm; one wording for the hold; "armed
//  session" in place of the noun "watch" in the app's words; the line on iOS's "Guided Access is unavailable"; Home's
//  neutral dot for Guided Access off; the lawful-use line under "Record audio in clips". The second batch: the Volume
//  Buttons step only in Siren mode, the setup steps folded after the first armed session under Guided Access, and "Before
//  you arm"'s "Nothing is deleted". Then the paths, written after the two fixes and held to them by the round's undo
//  check: the launch's seeding, the arming flow, and each screen as laid out, its buttons pressed.
//

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item240OnboardingTests: XCTestCase {

    /// Every onboarding flag these tests write: the five parts of "Before you arm", then the rest.
    nonisolated private static let keys = ["com.malinois.onboarding.acknowledgedDisarmBriefing",
                                           "com.malinois.onboarding.acknowledgedGuidedAccessBriefing",
                                           "com.malinois.onboarding.acknowledgedVoiceControlBriefing",
                                           "com.malinois.onboarding.acknowledgedSideButtonBriefing",
                                           "com.malinois.onboarding.acknowledgedNoDeleteBriefing",
                                           "com.malinois.onboarding.hasArmedOnce",
                                           "com.malinois.onboarding.hasDisarmedOnce",
                                           "com.malinois.onboarding.firstSessionCardDismissed",
                                           "com.malinois.onboarding.hasArmedUnderGuidedAccess"]
    nonisolated private static let cardKey = "com.malinois.onboarding.firstSessionCardDismissed"
    nonisolated private static let noDeleteKey = "com.malinois.onboarding.acknowledgedNoDeleteBriefing"
    private static let shortScreen = CGSize(width: 375, height: 667)
    private static let noCamera = Just(false).eraseToAnyPublisher()
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The simulator's own onboarding values, put back after each test.
    nonisolated(unsafe) private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem240")
        for key in Self.keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in Self.keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The welcome screen

    /// The welcome screen's words are approved text: the App Store description's first sentence, SECURITY.md's
    /// own-device sentence, and the two buttons the owner approved.
    func testTheWelcomeWordsAreTheOwnersApprovedOnes() {
        XCTAssertEqual(Welcome.summary,
                       "Malinois detects when someone handles your unattended iPhone, even someone who knows your iPhone passcode.")
        XCTAssertEqual(Welcome.ownDevice,
                       "Use Malinois only on your own device. It is intended to help you notice and record someone handling your unattended phone, not to monitor other people without their knowledge.")
        XCTAssertEqual(Welcome.seeItWork, "See it work")
        XCTAssertEqual(Welcome.setAPIN, "Set a PIN")
    }

    /// An install with no PIN opens on the welcome screen; "Set a PIN" leads to the PIN's setup.
    func testAnInstallWithNoPINOpensOnTheWelcomeScreenAndSetAPINLeadsToSetup() {
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: false, disarmed: true, recovery: false,
                                            needsPINSetup: true, pinSetupChosen: false), .welcome)
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: false, disarmed: true, recovery: false,
                                            needsPINSetup: true, pinSetupChosen: true), .pinSetup)
    }

    /// A reinstall still has its PIN: it goes to PIN continuity, never to the welcome screen, whatever else is set.
    func testAReinstallGoesToPINContinuityNeverToTheWelcome() {
        for needsSetup in [false, true] {
            for chosen in [false, true] {
                XCTAssertEqual(Welcome.launchScreen(pinUnresolved: false, disarmed: true, recovery: true,
                                                    needsPINSetup: needsSetup, pinSetupChosen: chosen), .recovery)
            }
        }
    }

    /// An install with a PIN opens the app; a PIN store that cannot be read yet, while disarmed, shows the screen that
    /// says so, as before.
    func testAnInstallWithAPINOpensTheAppAndASealedStoreSaysSo() {
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: false, disarmed: true, recovery: false,
                                            needsPINSetup: false, pinSetupChosen: false), .app)
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: true, disarmed: true, recovery: false,
                                            needsPINSetup: false, pinSetupChosen: false), .pinStorageUnavailable)
        XCTAssertEqual(Welcome.launchScreen(pinUnresolved: true, disarmed: false, recovery: false,
                                            needsPINSetup: false, pinSetupChosen: false), .app)
    }

    // MARK: - Home's card after the first disarm (D1 (a))

    /// The card shows once the owner has disarmed once, until either button is tapped.
    func testTheFirstSessionCardShowsAfterTheFirstDisarmUntilDismissed() {
        XCTAssertFalse(FirstSessionCard.shows(hasDisarmedOnce: false, dismissed: false))
        XCTAssertTrue(FirstSessionCard.shows(hasDisarmedOnce: true, dismissed: false))
        XCTAssertFalse(FirstSessionCard.shows(hasDisarmedOnce: true, dismissed: true))
    }

    /// An install that armed before this build starts with the card dismissed: only a new install sees it. A stored
    /// value always wins.
    func testAnInstallThatArmedBeforeStartsWithTheCardDismissed() {
        XCTAssertTrue(FirstSessionCard.initialDismissed(stored: nil, hasArmedOnce: true))
        XCTAssertFalse(FirstSessionCard.initialDismissed(stored: nil, hasArmedOnce: false))
        XCTAssertFalse(FirstSessionCard.initialDismissed(stored: false, hasArmedOnce: true))
        XCTAssertTrue(FirstSessionCard.initialDismissed(stored: true, hasArmedOnce: false))
    }

    func testTheCardsWordsAreTheOwnersApprovedOnes() {
        XCTAssertEqual(FirstSessionCard.text, "Your first armed session is over. The Event Log has what it recorded.")
        XCTAssertEqual(FirstSessionCard.openLog, "Open the Event Log")
        XCTAssertEqual(FirstSessionCard.notNow, "Not now")
    }

    // MARK: - The arming flow's words

    /// One wording for the 5-second hold on the arming card, the countdown and the tamper warning.
    func testTheHoldHasOneWordingOnTheThreeScreens() {
        XCTAssertEqual(DisarmTip.holdHeadline, "Press and hold anywhere on the screen for 5 seconds")
        XCTAssertEqual(DisarmTip.countdownReminder,
                       "To disarm later: press and hold anywhere on the screen for 5 seconds, then enter your Malinois PIN.")
        XCTAssertEqual(DisarmTip.alertTipText,
                       "To disarm: press and hold anywhere on the screen for 5 seconds, then enter your Malinois PIN.")
    }

    /// "Armed session" in place of the noun "watch", in each of the app's texts that had it.
    func testTheAppsWordsSayArmedSessionNotWatch() {
        XCTAssertEqual(ArmingView.guidedAccessOnSubtitle,
                       "The device is locked to Malinois - a snoop can't switch apps or use the power-off slider. A forced restart still ends the armed session.")
        XCTAssertTrue(ArmingView.passcodeStep.hasSuffix("A forced restart still ends the armed session, and that code then unlocks the phone."),
                      ArmingView.passcodeStep)
        XCTAssertTrue(GuidedAccessPromptView.passcodeStep.hasSuffix("A forced restart still ends the armed session."),
                      GuidedAccessPromptView.passcodeStep)
        XCTAssertEqual(SettingsView.armingDelayCaption,
                       "Any enabled tripwire fires on its own. Time to set the device down and step away before monitoring starts.")
        var guidedAccessEnded = Event(startDate: Date(), endDate: Date(), triggeredSensors: [])
        guidedAccessEnded.stateChange = "guidedAccessEnded"
        XCTAssertEqual(guidedAccessEnded.sensorSummary, "Guided Access ended while armed; monitoring went on")
        for text in [ArmingView.guidedAccessOnSubtitle, ArmingView.passcodeStep, GuidedAccessPromptView.passcodeStep,
                     SettingsView.armingDelayCaption, guidedAccessEnded.sensorSummary] {
            XCTAssertNil(text.range(of: "the watch"), text)
        }
    }

    /// The arming screen says what to do when iOS reports Guided Access unavailable (from the support page).
    func testTheArmingScreenSaysWhatToDoWhenGuidedAccessIsUnavailable() {
        XCTAssertEqual(ArmingView.guidedAccessUnavailable,
                       "If iOS says Guided Access is unavailable, wait 3 to 5 minutes or restart the iPhone. This is an iOS bug, not Malinois.")
    }

    /// Home's "Guided Access off" has a neutral dot: Guided Access is started on the arming screen, so off is the
    /// normal state at Home. On, the dot is ready, as before.
    func testGuidedAccessOffAtHomeIsNeutral() {
        XCTAssertEqual(HomeView.guidedAccessDot(enabled: false), .neutral)
        XCTAssertEqual(HomeView.guidedAccessDot(enabled: true), .ready)
    }

    /// The lawful-use line under "Record audio in clips" (the owner's words).
    func testTheLawfulUseLineUnderRecordAudio() {
        XCTAssertEqual(SettingsView.audioLawfulUse,
                       "Recording people's voices without their consent is against the law in some places. Check the rules where you use Malinois before turning this on.")
    }

    // MARK: - Batch 2: the arming screen's steps and "Nothing is deleted"

    /// The Volume Buttons step shows only in Siren mode, and the steps are numbered without a gap either way; without
    /// it, the Side Button step no longer opens with "Also", which pointed back at it.
    func testTheVolumeButtonsStepShowsOnlyInSirenMode() {
        let siren = ArmingView.guidedAccessSteps(siren: true)
        let other = ArmingView.guidedAccessSteps(siren: false)
        XCTAssertEqual(siren.count, 7)
        XCTAssertEqual(other.count, 6)
        XCTAssertTrue(siren.contains { $0.contains("Volume Buttons") })
        XCTAssertFalse(other.contains { $0.contains("Volume Buttons") })
        // A wrong count is the failure above: reading past the end would stop the whole test run (the round's undo check).
        guard siren.count == 7, other.count == 6 else { return }
        XCTAssertTrue(siren[6].hasPrefix("Also in Guided Access → Options, turn OFF Side Button"), siren[6])
        XCTAssertTrue(other[5].hasPrefix("In Guided Access → Options, turn OFF Side Button"), other[5])
        XCTAssertEqual(Array(other[0..<5]), Array(siren[0..<5]))
        XCTAssertEqual(siren[1], ArmingView.passcodeStep)
    }

    /// After the first armed session under Guided Access, the arming screen folds its setup steps into one line.
    func testTheSetupStepsFoldAfterTheFirstArmedSessionUnderGuidedAccess() {
        XCTAssertFalse(ArmingView.foldsSetupSteps(hasArmedUnderGuidedAccess: false))
        XCTAssertTrue(ArmingView.foldsSetupSteps(hasArmedUnderGuidedAccess: true))
        XCTAssertEqual(ArmingView.foldedSteps, "Triple-click the side (or Home) button, then tap Start.")
        XCTAssertEqual(ArmingView.showSetupSteps, "Show the setup steps")
    }

    /// "Nothing is deleted" shows before an arm the owner starts until it is acknowledged; an arm the owner did not
    /// start (the re-arm after a crash) shows nothing; an install that armed before starts acknowledged (D2 (a)).
    func testTheNothingIsDeletedPartIsDueUntilAcknowledged() {
        let due = FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: false, disarmAcknowledged: true,
                                            guidedAccessAcknowledged: true, voiceControlAcknowledged: true,
                                            sideButtonAcknowledged: true, noDeleteAcknowledged: false)
        XCTAssertTrue(due.noDelete)
        XCTAssertFalse(due.isEmpty)
        let done = FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: false, disarmAcknowledged: true,
                                             guidedAccessAcknowledged: true, voiceControlAcknowledged: true,
                                             sideButtonAcknowledged: true, noDeleteAcknowledged: true)
        XCTAssertFalse(done.noDelete)
        XCTAssertTrue(done.isEmpty)
        let recovered = FirstArmBriefing.partsDue(ownerStarted: false, guidedAccessOn: false, disarmAcknowledged: false,
                                                  guidedAccessAcknowledged: false, voiceControlAcknowledged: false,
                                                  sideButtonAcknowledged: false, noDeleteAcknowledged: false)
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertNotEqual(due.id, done.id)
    }

    /// The part's words as the owner approved them again after 1.13's full review (item 241's B1, 2026-11-13: "as you
    /// recommend, wording approved"): the log's limit and a set-aside log's Delete named, which "Nothing is deleted" left
    /// out.
    func testTheNothingIsDeletedWordsAreTheOwnersApprovedOnes() {
        XCTAssertEqual(FirstArmBriefing.noDeleteHeading, "No one can delete an entry")
        XCTAssertEqual(FirstArmBriefing.noDeleteText,
                       "Every arm, disarm and trip goes in the Event Log, and no one can delete an entry, not even with your PIN. When the log is full, its oldest entries make way for new ones, and a log Malinois had to set aside can be deleted whole, with your PIN. To try the sensors without recording anything, use Test sensors on Home.")
    }

    // MARK: - The paths: the launch

    /// The launch writes the card's and "Nothing is deleted"'s starting values, through the app's own launch (as item
    /// 107's test runs it): a new install sees both, an install that armed before this build neither (D1 (a), D2 (a)). A
    /// later launch keeps what is stored: going live does not dismiss the card, a button does.
    func testTheLaunchShowsTheCardAndNothingIsDeletedToANewInstallOnly() {
        for armedBefore in [false, true] {
            let label = armedBefore ? "an install that armed before this build" : "a new install"
            UserDefaults.standard.removeObject(forKey: Self.cardKey)
            UserDefaults.standard.removeObject(forKey: Self.noDeleteKey)
            OnboardingState.hasArmedOnce = armedBefore
            let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                    relaySend: { _ in })   // no WatchConnectivity in a test
            TestIsolation.track(services.engine)
            XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.cardKey), "the launch writes the card's value: \(label)")
            XCTAssertEqual(OnboardingState.firstSessionCardDismissed, armedBefore, "the card: \(label)")
            XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.noDeleteKey), "and the part's: \(label)")
            XCTAssertEqual(OnboardingState.acknowledgedNoDeleteBriefing, armedBefore, "Nothing is deleted: \(label)")
        }
        OnboardingState.firstSessionCardDismissed = false   // a new install's card, waiting for its first disarm
        OnboardingState.hasArmedOnce = true                 // its first armed session went live
        OnboardingState.seedFirstSessionCard()              // the next launch
        XCTAssertFalse(OnboardingState.firstSessionCardDismissed, "going live does not dismiss the card")
    }

    /// RootView routes by `Welcome.launchScreen` with its own state, and only the welcome screen opens Test sensors
    /// before a PIN. Read from the source, as item 148's test reads RootView's: a test cannot give RootView a Keychain and
    /// a log of its own (both are the test host's, shared by every test). A reinstall's recovery passed as anything else
    /// would take a phone that still has its PIN to the welcome screen and a new PIN's setup.
    func testRootViewRoutesByTheRuleAndOnlyTheWelcomeOpensTestSensors() throws {
        let root = try flatSource("Malinois/Views/RootView.swift")
        XCTAssertTrue(root.contains("switch Welcome.launchScreen(pinUnresolved: pinStateUnresolved, disarmed: engine.state == .disarmed, recovery: recovery != nil, needsPINSetup: needsPINSetup, pinSetupChosen: pinSetupChosen) {"),
                      "RootView routes by the rule, with its own state")
        XCTAssertTrue(root.contains("case .welcome: WelcomeView(onSeeItWork: { showWelcomeTest = true }, onSetAPIN: { pinSetupChosen = true })"),
                      "the welcome screen's two ways on")
        XCTAssertTrue(root.contains(".sheet(isPresented: $showWelcomeTest) { DryRunView() }"), "See it work opens Test sensors")
        XCTAssertEqual(root.components(separatedBy: "showWelcomeTest = true").count, 2, "only the welcome screen opens it")
        XCTAssertEqual(root.components(separatedBy: "pinSetupChosen = true").count, 2, "only Set a PIN leads to the setup")
        let welcome = try flatSource("Malinois/Views/OnboardingViews.swift")
        XCTAssertTrue(welcome.contains("Button(action: onSeeItWork) {"), "See it work's button runs the closure it reports")
        XCTAssertTrue(welcome.contains("Button(action: onSetAPIN) {"), "Set a PIN's button runs the closure it reports")
    }

    // MARK: - The paths: the arming flow

    /// A new install's first arm: Start countdown brings "Before you arm" with "Nothing is deleted" among its parts, and
    /// the countdown waits; "I understand" acknowledges every part shown and starts the countdown; the next arm goes on
    /// with no screen (D2 (a)).
    func testANewInstallsFirstArmShowsNothingIsDeletedAndIUnderstandAcknowledgesIt() {
        acknowledged(false)
        let rig = makeRig()
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck, "the countdown waits for the screen's button")
        XCTAssertEqual(rig.engine.firstArmBriefing,
                       FirstArmBriefing.Parts(disarm: true, guidedAccess: false, voiceControl: true, noDelete: true))
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming, "I understand starts the countdown")
        XCTAssertTrue(OnboardingState.acknowledgedNoDeleteBriefing, "and acknowledges the part")
        rig.engine.cancelArming()

        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertNil(rig.engine.firstArmBriefing, "acknowledged: the screen does not come back")
        XCTAssertEqual(rig.engine.state, .arming)
        rig.engine.cancelArming()
    }

    /// The setup steps fold once an armed session goes live under Guided Access, and not for one without it, nor for a
    /// countdown cancelled under it (D3 (a)).
    func testOnlyAnArmedSessionUnderGuidedAccessFoldsTheSetupSteps() {
        acknowledged(true)
        let rig = makeRig()
        XCTAssertFalse(OnboardingState.hasArmedUnderGuidedAccess, "a new install's steps are unfolded")
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming, "counting down under Guided Access")
        rig.engine.cancelArming()
        XCTAssertFalse(OnboardingState.hasArmedUnderGuidedAccess, "a countdown cancelled under Guided Access never went live")

        rig.settings.gracePeriodSeconds = 0
        rig.engine.simulateGuidedAccessForTesting(on: false)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "live without Guided Access")
        rig.engine.disarm()
        XCTAssertFalse(OnboardingState.hasArmedUnderGuidedAccess, "an armed session without Guided Access folds nothing")

        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "live under Guided Access")
        XCTAssertTrue(OnboardingState.hasArmedUnderGuidedAccess, "the first armed session under Guided Access folds them")
        rig.engine.disarm()
    }

    // MARK: - The paths: the screens as laid out

    /// "Before you arm" shows "Nothing is deleted" alone, or last of all five parts (item 242's round q: the owner put it
    /// last, 2026-11-14) at the largest text size on a short screen, with every word there to scroll through and the
    /// button in view (D2 (a)).
    func testTheScreenShowsNothingIsDeletedLastAndAllFivePartsAtTheLargestTextSize() throws {
        let alone = try shownOnScreen(FirstArmBriefingView(parts: .init(disarm: false, guidedAccess: false, noDelete: true),
                                                           recording: Self.noCamera) {}, in: Self.shortScreen).shown
        for text in [FirstArmBriefing.title, FirstArmBriefing.noDeleteHeading, FirstArmBriefing.noDeleteText,
                     FirstArmBriefing.footnote, FirstArmBriefing.button] {
            XCTAssertTrue(alone.contains(text), "missing: \(text)")
        }
        for text in [FirstArmBriefing.disarmText, FirstArmBriefing.guidedAccessText, FirstArmBriefing.voiceControlText,
                     FirstArmBriefing.sideButtonText] {
            XCTAssertFalse(alone.contains(text), "a part acknowledged: \(text)")
        }

        let all = FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: true, voiceControl: true, sideButton: true,
                                                    noDelete: true), recording: Self.noCamera) {}
            .environment(\.dynamicTypeSize, .accessibility5)
        let layout = try shownOnScreen(all, in: Self.shortScreen)
        for text in [FirstArmBriefing.noDeleteHeading, FirstArmBriefing.noDeleteText, FirstArmBriefing.disarmText,
                     FirstArmBriefing.guidedAccessText, FirstArmBriefing.voiceControlText, FirstArmBriefing.sideButtonText,
                     FirstArmBriefing.button] {
            XCTAssertTrue(layout.shown.contains(text), "missing at the largest size: \(text)")
        }
        let last = try XCTUnwrap(layout.frames[FirstArmBriefing.noDeleteHeading], "the part's heading")
        let voiceControl = try XCTUnwrap(layout.frames[FirstArmBriefing.voiceControlHeading], "the Voice Control part's heading")
        XCTAssertGreaterThan(last.minY, voiceControl.minY, "Nothing is deleted comes last")
        let button = try XCTUnwrap(layout.frames[FirstArmBriefing.button], "the button's frame")
        XCTAssertGreaterThanOrEqual(button.minY, 0, "the button is above the top: \(button)")
        XCTAssertLessThanOrEqual(button.maxY, Self.shortScreen.height, "the button is below the screen: \(button)")
    }

    /// The arming screen with Guided Access off: every setup step, the Volume Buttons step only in Siren mode, and the
    /// line on "Guided Access is unavailable"; after an armed session under Guided Access, the one folded line in place
    /// of the steps, until "Show the setup steps" brings them back (D3 (a)). With Guided Access on, neither.
    func testTheArmingScreensStepsFollowTheModeAndFoldUntilAsked() async throws {
        let rig = makeRig()
        rig.settings.responseMode = .siren
        rig.engine.beginArming()
        defer { rig.engine.cancelArming() }
        let siren = try shownOnScreen(arming(rig)).shown
        for step in ArmingView.guidedAccessSteps(siren: true) { XCTAssertTrue(siren.contains(step), "Siren mode: \(step)") }
        XCTAssertTrue(siren.contains(ArmingView.guidedAccessUnavailable), "the line on unavailable: \(siren)")
        XCTAssertFalse(siren.contains(ArmingView.foldedSteps), "a new install's steps are unfolded")

        rig.settings.responseMode = .alert
        let steps = ArmingView.guidedAccessSteps(siren: false)
        let alert = try shownOnScreen(arming(rig)).shown
        for step in steps { XCTAssertTrue(alert.contains(step), "Alert mode: \(step)") }
        XCTAssertFalse(alert.contains { $0.contains("Volume Buttons") }, "no Volume Buttons step outside Siren mode: \(alert)")

        OnboardingState.hasArmedUnderGuidedAccess = true
        let screen = try layOut(arming(rig))
        defer { screen.close() }
        let folded = await settles {
            screen.recorder.shown.contains(ArmingView.foldedSteps) && screen.recorder.actions[ArmingView.showSetupSteps] != nil
        }
        XCTAssertTrue(folded, "the folded line and its button: \(screen.recorder.shown)")
        XCTAssertFalse(steps.contains { screen.recorder.shown.contains($0) }, "no step while folded: \(screen.recorder.shown)")
        XCTAssertTrue(screen.recorder.shown.contains(ArmingView.guidedAccessUnavailable), "the line stays")
        screen.recorder.actions[ArmingView.showSetupSteps]?()
        let unfolded = await settles { steps.allSatisfy { screen.recorder.shown.contains($0) } }
        XCTAssertTrue(unfolded, "Show the setup steps brings every step back: \(screen.recorder.shown)")
        XCTAssertFalse(screen.recorder.shown.contains(ArmingView.foldedSteps), "and the folded line goes")

        rig.engine.simulateGuidedAccessForTesting(on: true)
        let on = try shownOnScreen(arming(rig)).shown
        XCTAssertFalse(on.contains(ArmingView.guidedAccessUnavailable) || on.contains(ArmingView.foldedSteps),
                       "Guided Access on: neither the line nor the folded steps: \(on)")
    }

    /// Home's card after the first disarm, on Home as laid out: not before the first disarm; after it, until "Not now"
    /// takes it away for good (D1 (a)).
    func testHomeShowsTheCardAfterTheFirstDisarmUntilNotNow() async throws {
        let rig = makeRig()
        OnboardingState.firstSessionCardDismissed = false
        OnboardingState.hasDisarmedOnce = false
        XCTAssertFalse(try shownOnScreen(home(rig)).shown.contains(FirstSessionCard.text), "not before the first disarm")

        OnboardingState.hasDisarmedOnce = true
        let screen = try layOut(home(rig))
        defer { screen.close() }
        let up = await settles {
            screen.recorder.shown.contains(FirstSessionCard.text) && screen.recorder.actions[FirstSessionCard.notNow] != nil
        }
        XCTAssertTrue(up, "the card after the first disarm: \(screen.recorder.shown)")
        screen.recorder.actions[FirstSessionCard.notNow]?()
        let gone = await settles { !screen.recorder.shown.contains(FirstSessionCard.text) }
        XCTAssertTrue(gone, "Not now takes it away: \(screen.recorder.shown)")
        XCTAssertTrue(OnboardingState.firstSessionCardDismissed, "for good")
        XCTAssertFalse(try shownOnScreen(home(rig)).shown.contains(FirstSessionCard.text), "Home again: no card")
    }

    /// The card's "Open the Event Log" opens the log's own PIN gate, as Home's Event Log button does, never the log
    /// itself, and the card goes for good (D1 (a)).
    func testTheCardsOpenTheEventLogAsksForTheLogsPIN() async throws {
        let rig = makeRig()
        OnboardingState.firstSessionCardDismissed = false
        OnboardingState.hasDisarmedOnce = true
        let screen = try layOut(home(rig))
        defer { screen.close() }
        let offered = await settles { screen.recorder.actions[FirstSessionCard.openLog] != nil }
        XCTAssertTrue(offered, "the card offers Open the Event Log: \(screen.recorder.shown)")
        screen.recorder.actions[FirstSessionCard.openLog]?()
        let pad = await settles(within: 10) { screen.recorder.shown.contains(HomeView.Gate.log.prompt) }
        XCTAssertTrue(pad, "the log's PIN pad: \(screen.recorder.shown)")
        XCTAssertTrue(OnboardingState.firstSessionCardDismissed, "the card goes for good")
    }

    /// The welcome screen as laid out: the summary, the own-device sentence, and its two buttons, each doing its own
    /// thing.
    func testTheWelcomeScreenShowsItsWordsAndEachButtonLeadsOn() async throws {
        let seeItWork = TestFlag(), setAPIN = TestFlag()
        let screen = try layOut(WelcomeView(onSeeItWork: { seeItWork.value = true }, onSetAPIN: { setAPIN.value = true }))
        defer { screen.close() }
        let up = await settles {
            screen.recorder.actions[Welcome.seeItWork] != nil && screen.recorder.actions[Welcome.setAPIN] != nil
        }
        XCTAssertTrue(up, "both buttons: \(screen.recorder.shown)")
        XCTAssertTrue(screen.recorder.shown.contains(Welcome.summary), "\(screen.recorder.shown)")
        XCTAssertTrue(screen.recorder.shown.contains(Welcome.ownDevice), "\(screen.recorder.shown)")
        screen.recorder.actions[Welcome.seeItWork]?()
        XCTAssertTrue(seeItWork.value && !setAPIN.value, "See it work opens Test sensors and nothing else")
        screen.recorder.actions[Welcome.setAPIN]?()
        XCTAssertTrue(setAPIN.value, "Set a PIN leads to the setup")
    }

    /// The lawful-use line shows under "Record audio in clips", which Settings shows only with clips.
    func testTheLawfulUseLineShowsUnderRecordAudioInClips() throws {
        let clips = try settingsShownOnScreen { $0.captureMode = .clip5 }
        XCTAssertTrue(clips.contains(SettingsView.audioLawfulUse), "with clips: \(clips)")
        let photos = try settingsShownOnScreen { $0.captureMode = .photo }
        XCTAssertFalse(photos.contains(SettingsView.audioLawfulUse), "no clips, no audio switch, no line")
    }

    // MARK: - Helpers

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
        let cloud: CloudExfiltrator
        let entitlements: ProEntitlements
    }

    /// An engine as the arming tests build one: Guided Access not required, a countdown of a minute.
    private func makeRig() -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, settings: settings, store: store, cloud: cloud, entitlements: entitlements)
    }

    /// The five parts of "Before you arm", all acknowledged or none, as an install has them.
    private func acknowledged(_ value: Bool) {
        for key in Self.keys.prefix(5) { UserDefaults.standard.set(value, forKey: key) }
    }

    private func home(_ rig: Rig) -> some View {
        HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(rig.cloud)
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)
    }

    private func arming(_ rig: Rig) -> some View {
        ArmingView()
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
            .environmentObject(rig.settings)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// Waits, releasing the main actor for SwiftUI, until `condition` holds or `seconds` pass.
    private func settles(within seconds: Int = 5, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// A screen laid out in a window that stays up until `close()`, with what it reports, so a test can press its
    /// buttons through their reported actions (item 122's pattern).
    private struct Screen {
        let recorder: OnScreenRecorder
        let host: UIViewController
        let window: UIWindow

        /// Whatever the screen still has up goes with it.
        @MainActor func close() {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func layOut<V: View>(_ view: V) throws -> Screen {
        let recorder = OnScreenRecorder()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        return Screen(recorder: recorder, host: host, window: window)
    }

    /// A source file's text with every run of spaces and line breaks made one space.
    private func flatSource(_ path: String) throws -> String {
        let text = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
