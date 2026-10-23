//
//  Item144VoiceControlBriefingTests.swift
//  MalinoisTests
//
//  BACKLOG 144 (e), item 145 step 7 (the owner's "approved", 2026-10-21; ADR 0050 amended for 1.8.1). Voice Control is
//  the one accessibility feature Guided Access leaves running, and it can be told to close Malinois; the arming
//  screen's card says to turn it off, but nothing made an owner read it. The one-time screen before the first arm
//  ("Before you arm") gains a third part, Voice Control, in the owner's approved words: due at every arm the owner
//  starts until acknowledged, with or without Guided Access, and never seeded at launch, so every install sees it once,
//  updated ones included (an install that acknowledged parts 1 and 2 sees it alone). Never in front of the automatic
//  re-arm. Written before the change, red at that commit (against compile-only stubs).
//

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item144VoiceControlBriefingTests: XCTestCase {

    nonisolated private static let keys = ["com.malinois.onboarding.acknowledgedDisarmBriefing",
                                           "com.malinois.onboarding.acknowledgedGuidedAccessBriefing",
                                           "com.malinois.onboarding.acknowledgedVoiceControlBriefing",
                                           "com.malinois.onboarding.hasArmedOnce"]
    nonisolated private static let voiceControlKey = "com.malinois.onboarding.acknowledgedVoiceControlBriefing"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let shortScreen = CGSize(width: 375, height: 667)
    private static let noCamera = Just(false).eraseToAnyPublisher()

    /// The simulator's own onboarding values, put back after each test.
    nonisolated(unsafe) private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem144Voice")
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

    /// The three acknowledgments as an install has them.
    private func acknowledgments(disarm: Bool, guidedAccess: Bool, voiceControl: Bool) {
        UserDefaults.standard.set(disarm, forKey: Self.keys[0])
        UserDefaults.standard.set(guidedAccess, forKey: Self.keys[1])
        UserDefaults.standard.set(voiceControl, forKey: Self.keys[2])
    }

    private var voiceControlAcknowledged: Bool { UserDefaults.standard.bool(forKey: Self.voiceControlKey) }

    private func engine() -> (engine: MonitoringEngine, entitlements: ProEntitlements, settings: AppSettings) {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, entitlements, settings)
    }

    // MARK: - The rule

    /// Part 3 is due at every arm the owner starts until it is acknowledged, whatever Guided Access and the other two
    /// parts say; never for an arm the owner did not start.
    func testTheVoiceControlPartIsDueUntilAcknowledgedWithOrWithoutGuidedAccess() {
        for guidedAccessOn in [false, true] {
            for disarmAck in [false, true] {
                for guidedAccessAck in [false, true] {
                    for voiceControlAck in [false, true] {
                        let label = "Guided Access \(guidedAccessOn), acknowledged \(disarmAck) \(guidedAccessAck) \(voiceControlAck)"
                        XCTAssertTrue(FirstArmBriefing.partsDue(ownerStarted: false, guidedAccessOn: guidedAccessOn,
                                                                disarmAcknowledged: disarmAck,
                                                                guidedAccessAcknowledged: guidedAccessAck,
                                                                voiceControlAcknowledged: voiceControlAck).isEmpty,
                                      "an automatic re-arm never waits for a tap: \(label)")
                        let due = FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: guidedAccessOn,
                                                            disarmAcknowledged: disarmAck,
                                                            guidedAccessAcknowledged: guidedAccessAck,
                                                            voiceControlAcknowledged: voiceControlAck)
                        XCTAssertEqual(due, FirstArmBriefing.Parts(disarm: !disarmAck,
                                                                   guidedAccess: guidedAccessOn && !guidedAccessAck,
                                                                   voiceControl: !voiceControlAck), label)
                    }
                }
            }
        }
    }

    /// The launch seeding leaves part 3 alone: an install updating from 1.8 (it has armed before) starts with parts 1
    /// and 2 acknowledged and part 3 due.
    func testTheLaunchSeedingLeavesTheVoiceControlPartDueForAnUpdatedInstall() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        OnboardingState.hasArmedOnce = true   // an install that armed under 1.8
        OnboardingState.seedFirstArmBriefing()
        XCTAssertTrue(OnboardingState.acknowledgedDisarmBriefing && OnboardingState.acknowledgedGuidedAccessBriefing,
                      "parts 1 and 2: new installs only, as before")
        XCTAssertFalse(voiceControlAcknowledged, "part 3 is never seeded")
        XCTAssertEqual(FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: true,
                                                 disarmAcknowledged: OnboardingState.acknowledgedDisarmBriefing,
                                                 guidedAccessAcknowledged: OnboardingState.acknowledgedGuidedAccessBriefing,
                                                 voiceControlAcknowledged: voiceControlAcknowledged),
                       FirstArmBriefing.Parts(disarm: false, guidedAccess: false, voiceControl: true))
    }

    // MARK: - The arming flow

    /// An updated install's first arm on this build: Start countdown brings the screen with the Voice Control part
    /// alone and the countdown waits; "I understand" acknowledges it and starts the countdown; the next arm goes on.
    func testAnUpdatedInstallSeesThePartAloneOnceAndIUnderstandAcknowledgesIt() {
        acknowledgments(disarm: true, guidedAccess: true, voiceControl: false)
        let rig = engine()
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck, "the countdown waits for the screen's button")
        XCTAssertEqual(rig.engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: false, guidedAccess: false, voiceControl: true))
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming, "I understand starts the countdown")
        XCTAssertTrue(voiceControlAcknowledged)
        rig.engine.cancelArming()

        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.state, .arming, "acknowledged: the screen does not come back, Guided Access or not")
        XCTAssertNil(rig.engine.firstArmBriefing)
        rig.engine.cancelArming()
    }

    /// A new install's first arm shows the Voice Control part with the others: with the disarm part without Guided
    /// Access, with both under it; one "I understand" acknowledges every part it showed.
    func testANewInstallSeesTheVoiceControlPartWithTheOthers() {
        acknowledgments(disarm: false, guidedAccess: false, voiceControl: false)
        let rig = engine()
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: true, guidedAccess: false, voiceControl: true))
        rig.engine.cancelArming()

        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: true, guidedAccess: true, voiceControl: true))
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertTrue(OnboardingState.acknowledgedDisarmBriefing && OnboardingState.acknowledgedGuidedAccessBriefing
                      && voiceControlAcknowledged, "every part shown is acknowledged")
        rig.engine.cancelArming()
    }

    /// The automatic re-arm after a crash runs with nobody watching: no screen, and part 3 stays due for the owner.
    func testTheAutomaticReArmNeverShowsTheVoiceControlPart() {
        acknowledgments(disarm: true, guidedAccess: true, voiceControl: false)
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
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
        XCTAssertEqual(engine.state, .arming, "the owed re-arm starts its countdown")
        XCTAssertNil(engine.firstArmBriefing, "no screen in front of an automatic re-arm")
        XCTAssertFalse(voiceControlAcknowledged, "and part 3 still due for the owner")
        engine.disarm()
    }

    // MARK: - The screen

    /// The owner's approved words.
    func testThePartUsesTheApprovedWords() {
        XCTAssertEqual(FirstArmBriefing.voiceControlHeading, "Voice Control")
        XCTAssertEqual(FirstArmBriefing.voiceControlText,
                       "If you use Voice Control, turn it OFF before you arm (Settings → Accessibility → Voice Control). "
                        + "It keeps working under Guided Access and can be told to close Malinois. Malinois can't see "
                        + "whether it is on, so this is up to you.")
    }

    /// The part alone shows its heading and text under the screen's title, footnote and button, and nothing of the
    /// other two; all three at the largest text size on a short screen keep every word there to scroll through and the
    /// button in view.
    func testTheScreenShowsThePartAloneOrWithTheOthersAtTheLargestTextSize() throws {
        let alone = try shownOnScreen(FirstArmBriefingView(parts: .init(disarm: false, guidedAccess: false, voiceControl: true),
                                                           recording: Self.noCamera) {}, in: Self.shortScreen).shown
        for text in [FirstArmBriefing.title, FirstArmBriefing.voiceControlHeading, FirstArmBriefing.voiceControlText,
                     FirstArmBriefing.footnote, FirstArmBriefing.button] {
            XCTAssertTrue(alone.contains(text), "missing: \(text)")
        }
        XCTAssertFalse(alone.contains(FirstArmBriefing.disarmText), "the disarm part was acknowledged")
        XCTAssertFalse(alone.contains(FirstArmBriefing.guidedAccessText), "the Guided Access part was acknowledged")

        let all = FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: true, voiceControl: true),
                                       recording: Self.noCamera) {}
            .environment(\.dynamicTypeSize, .accessibility5)
        let layout = try shownOnScreen(all, in: Self.shortScreen)
        for text in [FirstArmBriefing.disarmText, FirstArmBriefing.guidedAccessText, FirstArmBriefing.voiceControlHeading,
                     FirstArmBriefing.voiceControlText, FirstArmBriefing.button] {
            XCTAssertTrue(layout.shown.contains(text), "missing at the largest size: \(text)")
        }
        let button = try XCTUnwrap(layout.frames[FirstArmBriefing.button], "the button's frame")
        XCTAssertGreaterThanOrEqual(button.minY, 0, "the button is above the top: \(button)")
        XCTAssertLessThanOrEqual(button.maxY, Self.shortScreen.height, "the button is below the screen: \(button)")
    }
}
