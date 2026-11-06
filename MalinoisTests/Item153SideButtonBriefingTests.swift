//
//  Item153SideButtonBriefingTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-02 (ruled 2026-10-22 for 1.8.2 and never built; item 192's step 5, the owner's "approved, b",
//  2026-11-04; ADR 0072). With Guided Access's Side Button option on, one press locks the screen and nothing is watched
//  until the owner unlocks; the arming screen's step 7 says to turn it off, but nothing made an owner read it. The
//  one-time screen before an arm ("Before you arm") gains a fourth part, the Side Button, in the owner's approved
//  words: due at every arm the owner starts with Guided Access on, until acknowledged, and never seeded at launch, so
//  every install sees it once, updated ones included (an install that acknowledged parts 1 to 3 sees it alone). Never
//  without Guided Access (the option is Guided Access's own) and never in front of the automatic re-arm. Written
//  before the change, red at that commit (against compile-only stubs).
//

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item153SideButtonBriefingTests: XCTestCase {

    nonisolated private static let keys = ["com.malinois.onboarding.acknowledgedDisarmBriefing",
                                           "com.malinois.onboarding.acknowledgedGuidedAccessBriefing",
                                           "com.malinois.onboarding.acknowledgedVoiceControlBriefing",
                                           "com.malinois.onboarding.acknowledgedSideButtonBriefing",
                                           "com.malinois.onboarding.hasArmedOnce"]
    nonisolated private static let sideButtonKey = "com.malinois.onboarding.acknowledgedSideButtonBriefing"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let shortScreen = CGSize(width: 375, height: 667)
    private static let noCamera = Just(false).eraseToAnyPublisher()
    private static let approvedText = "In Guided Access's Options, turn Side Button OFF (Sleep/Wake Button on older "
        + "phones). If it is on, one press locks the screen, and nothing is watched until you unlock. Malinois can't "
        + "see this setting, so this is up to you."

    /// The simulator's own onboarding values, put back after each test.
    nonisolated(unsafe) private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Side")
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

    /// The four acknowledgments as an install has them.
    private func acknowledgments(disarm: Bool, guidedAccess: Bool, voiceControl: Bool, sideButton: Bool) {
        for (key, value) in zip(Self.keys.prefix(4), [disarm, guidedAccess, voiceControl, sideButton]) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private var sideButtonAcknowledged: Bool { UserDefaults.standard.bool(forKey: Self.sideButtonKey) }

    private func engine() -> MonitoringEngine {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        return TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                    cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                    entitlements: ProEntitlements(resolvedAs: .trial),
                                                    timing: EngineCharacterizationTests.fastTiming))
    }

    // MARK: - The rule

    /// Part 4 is due at every arm the owner starts with Guided Access on, until it is acknowledged, whatever the other
    /// three parts say; never without Guided Access, and never for an arm the owner did not start.
    func testTheSideButtonPartIsDueUnderGuidedAccessUntilAcknowledged() {
        for guidedAccessOn in [false, true] {
            for acks in 0..<16 {
                let (disarmAck, guidedAccessAck) = (acks & 1 != 0, acks & 2 != 0)
                let (voiceControlAck, sideButtonAck) = (acks & 4 != 0, acks & 8 != 0)
                let label = "Guided Access \(guidedAccessOn), acknowledged \(disarmAck) \(guidedAccessAck) "
                    + "\(voiceControlAck) \(sideButtonAck)"
                XCTAssertTrue(FirstArmBriefing.partsDue(ownerStarted: false, guidedAccessOn: guidedAccessOn,
                                                        disarmAcknowledged: disarmAck, guidedAccessAcknowledged: guidedAccessAck,
                                                        voiceControlAcknowledged: voiceControlAck,
                                                        sideButtonAcknowledged: sideButtonAck).isEmpty,
                              "an automatic re-arm never waits for a tap: \(label)")
                let due = FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: guidedAccessOn,
                                                    disarmAcknowledged: disarmAck, guidedAccessAcknowledged: guidedAccessAck,
                                                    voiceControlAcknowledged: voiceControlAck,
                                                    sideButtonAcknowledged: sideButtonAck)
                XCTAssertEqual(due, FirstArmBriefing.Parts(disarm: !disarmAck,
                                                           guidedAccess: guidedAccessOn && !guidedAccessAck,
                                                           voiceControl: !voiceControlAck,
                                                           sideButton: guidedAccessOn && !sideButtonAck), label)
            }
        }
    }

    /// The launch seeding leaves part 4 alone: an install updating from 1.10 (it has armed before, and saw the Voice
    /// Control part) starts with parts 1 to 3 acknowledged and part 4 due at its next arm under Guided Access.
    func testTheLaunchSeedingLeavesTheSideButtonPartDueForAnUpdatedInstall() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        OnboardingState.hasArmedOnce = true
        OnboardingState.acknowledgedVoiceControlBriefing = true
        OnboardingState.seedFirstArmBriefing()
        XCTAssertTrue(OnboardingState.acknowledgedDisarmBriefing && OnboardingState.acknowledgedGuidedAccessBriefing,
                      "parts 1 and 2: new installs only, as before")
        XCTAssertFalse(sideButtonAcknowledged, "part 4 is never seeded")
        XCTAssertEqual(FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: true,
                                                 disarmAcknowledged: OnboardingState.acknowledgedDisarmBriefing,
                                                 guidedAccessAcknowledged: OnboardingState.acknowledgedGuidedAccessBriefing,
                                                 voiceControlAcknowledged: OnboardingState.acknowledgedVoiceControlBriefing,
                                                 sideButtonAcknowledged: sideButtonAcknowledged),
                       FirstArmBriefing.Parts(disarm: false, guidedAccess: false, sideButton: true))
    }

    // MARK: - The arming flow

    /// An updated install's first arm under Guided Access on this build: Start countdown brings the screen with the
    /// Side Button part alone and the countdown waits; "I understand" acknowledges it and starts the countdown; the
    /// next arm under Guided Access goes on.
    func testAnUpdatedInstallSeesThePartAloneOnceUnderGuidedAccessAndIUnderstandAcknowledgesIt() {
        acknowledgments(disarm: true, guidedAccess: true, voiceControl: true, sideButton: false)
        let engine = engine()
        engine.simulateGuidedAccessForTesting(on: true)
        engine.beginArming()
        engine.startCountdownTapped()
        XCTAssertEqual(engine.state, .guidedAccessCheck, "the countdown waits for the screen's button")
        XCTAssertEqual(engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: false, guidedAccess: false, sideButton: true))
        engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(engine.state, .arming, "I understand starts the countdown")
        XCTAssertTrue(sideButtonAcknowledged)
        engine.cancelArming()

        engine.beginArming()
        engine.startCountdownTapped()
        XCTAssertEqual(engine.state, .arming, "acknowledged: the screen does not come back")
        XCTAssertNil(engine.firstArmBriefing)
        engine.cancelArming()
    }

    /// Without Guided Access the part waits: the arm goes on with no screen and the part stays due, then comes at the
    /// first arm under Guided Access.
    func testWithoutGuidedAccessThePartWaitsForAnArmUnderIt() {
        acknowledgments(disarm: true, guidedAccess: true, voiceControl: true, sideButton: false)
        let engine = engine()
        engine.beginArming()
        engine.startCountdownTapped()
        XCTAssertEqual(engine.state, .arming, "no Guided Access: nothing due, the countdown starts")
        XCTAssertNil(engine.firstArmBriefing)
        XCTAssertFalse(sideButtonAcknowledged, "still due for an arm under Guided Access")
        engine.cancelArming()

        engine.simulateGuidedAccessForTesting(on: true)
        engine.beginArming()
        engine.startCountdownTapped()
        XCTAssertEqual(engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: false, guidedAccess: false, sideButton: true))
        engine.cancelArming()
    }

    /// A new install's first arm under Guided Access shows every part on the one screen; one "I understand"
    /// acknowledges all four. Without Guided Access it shows the disarm and Voice Control parts only.
    func testANewInstallSeesTheSideButtonPartWithTheOthersUnderGuidedAccess() {
        acknowledgments(disarm: false, guidedAccess: false, voiceControl: false, sideButton: false)
        let engine = engine()
        engine.beginArming()
        engine.startCountdownTapped()
        XCTAssertEqual(engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: true, guidedAccess: false, voiceControl: true))
        engine.cancelArming()

        engine.simulateGuidedAccessForTesting(on: true)
        engine.beginArming()
        engine.startCountdownTapped()
        XCTAssertEqual(engine.firstArmBriefing,
                       FirstArmBriefing.Parts(disarm: true, guidedAccess: true, voiceControl: true, sideButton: true))
        engine.acknowledgeFirstArmBriefing()
        XCTAssertTrue(OnboardingState.acknowledgedDisarmBriefing && OnboardingState.acknowledgedGuidedAccessBriefing
                      && OnboardingState.acknowledgedVoiceControlBriefing && sideButtonAcknowledged,
                      "every part shown is acknowledged")
        engine.cancelArming()
    }

    /// The automatic re-arm after a crash runs with nobody watching: no screen, Guided Access on or not, and part 4
    /// stays due for the owner.
    func testTheAutomaticReArmNeverShowsTheSideButtonPart() {
        acknowledgments(disarm: true, guidedAccess: true, voiceControl: true, sideButton: false)
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        let entitlements = ProEntitlements.unresolvedForTesting()
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.simulateGuidedAccessForTesting(on: true)
        entitlements.resolveForTesting(as: .free)
        let deadline = Date().addingTimeInterval(3)
        while engine.state != .arming && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(engine.state, .arming, "the owed re-arm starts its countdown")
        XCTAssertNil(engine.firstArmBriefing, "no screen in front of an automatic re-arm")
        XCTAssertFalse(sideButtonAcknowledged, "and part 4 still due for the owner")
        engine.disarm()
    }

    // MARK: - The screen

    /// The owner's approved words (2026-11-04).
    func testThePartUsesTheApprovedWords() {
        XCTAssertEqual(FirstArmBriefing.sideButtonHeading, "Side Button")
        XCTAssertEqual(FirstArmBriefing.sideButtonText, Self.approvedText)
    }

    /// The part alone shows its heading and text under the screen's title, footnote and button, and nothing of the
    /// other three; all four at the largest text size on a short screen keep every word there to scroll through and
    /// the button in view.
    func testTheScreenShowsThePartAloneOrWithTheOthersAtTheLargestTextSize() throws {
        let alone = try shownOnScreen(FirstArmBriefingView(parts: .init(disarm: false, guidedAccess: false, sideButton: true),
                                                           recording: Self.noCamera) {}, in: Self.shortScreen).shown
        for text in [FirstArmBriefing.title, FirstArmBriefing.sideButtonHeading, FirstArmBriefing.sideButtonText,
                     FirstArmBriefing.footnote, FirstArmBriefing.button] {
            XCTAssertTrue(alone.contains(text), "missing: \(text)")
        }
        for text in [FirstArmBriefing.disarmText, FirstArmBriefing.guidedAccessText, FirstArmBriefing.voiceControlText] {
            XCTAssertFalse(alone.contains(text), "a part acknowledged: \(text)")
        }

        let all = FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: true, voiceControl: true, sideButton: true),
                                       recording: Self.noCamera) {}
            .environment(\.dynamicTypeSize, .accessibility5)
        let layout = try shownOnScreen(all, in: Self.shortScreen)
        for text in [FirstArmBriefing.disarmText, FirstArmBriefing.guidedAccessText, FirstArmBriefing.voiceControlText,
                     FirstArmBriefing.sideButtonHeading, FirstArmBriefing.sideButtonText, FirstArmBriefing.button] {
            XCTAssertTrue(layout.shown.contains(text), "missing at the largest size: \(text)")
        }
        let button = try XCTUnwrap(layout.frames[FirstArmBriefing.button], "the button's frame")
        XCTAssertGreaterThanOrEqual(button.minY, 0, "the button is above the top: \(button)")
        XCTAssertLessThanOrEqual(button.maxY, Self.shortScreen.height, "the button is below the screen: \(button)")
    }
}
