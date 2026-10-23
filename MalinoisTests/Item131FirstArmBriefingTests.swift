//
//  Item131FirstArmBriefingTests.swift
//  MalinoisTests
//
//  BACKLOG 131 (the owner's idea and word, 2026-10-18): a one-time screen before the first arm, how to disarm
//  and, when Guided Access is on for the arm, how to end it. The countdown waits for its "I understand"; it never
//  comes in front of the automatic re-arm after a crash; only new installs see it (the owner's choice, as the
//  disarm tip, item 107); and it scrolls at the largest text sizes with its button in view.
//

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item131FirstArmBriefingTests: XCTestCase {

    nonisolated private static let disarmAckKey = "com.malinois.onboarding.acknowledgedDisarmBriefing"   // read by the nonisolated hooks
    nonisolated private static let guidedAccessAckKey = "com.malinois.onboarding.acknowledgedGuidedAccessBriefing"
    /// Part 3, Voice Control (item 144 (e)), has tests of its own (Item144VoiceControlBriefingTests): here it is
    /// acknowledged, so these tests see parts 1 and 2 as before.
    nonisolated private static let voiceControlAckKey = "com.malinois.onboarding.acknowledgedVoiceControlBriefing"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let shortScreen = CGSize(width: 375, height: 667)

    /// The simulator's own values of the two acknowledgments, put back after each test.
    nonisolated(unsafe) private var savedAcks: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem131")
        for key in [Self.disarmAckKey, Self.guidedAccessAckKey, Self.voiceControlAckKey] {
            savedAcks[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: Self.voiceControlAckKey)
    }

    override func tearDown() {
        for key in [Self.disarmAckKey, Self.guidedAccessAckKey, Self.voiceControlAckKey] {
            if let value = savedAcks[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// A new install's acknowledgments: neither part seen yet.
    private func newInstall() {
        UserDefaults.standard.set(false, forKey: Self.disarmAckKey)
        UserDefaults.standard.set(false, forKey: Self.guidedAccessAckKey)
    }

    private func acknowledged() -> (disarm: Bool, guidedAccess: Bool) {
        (UserDefaults.standard.bool(forKey: Self.disarmAckKey), UserDefaults.standard.bool(forKey: Self.guidedAccessAckKey))
    }

    private func engine(gracePeriod: Int = 60) -> (engine: MonitoringEngine, camera: FakeCamera, settings: AppSettings,
                                                    entitlements: ProEntitlements) {
        let settings = AppSettings()
        settings.gracePeriodSeconds = gracePeriod
        settings.requireGuidedAccess = false
        let camera = FakeCamera()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: camera,
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, camera, settings, entitlements)
    }

    // MARK: - The rule

    /// Which parts the screen shows: nothing for an arm the owner did not start; the disarm part until it is
    /// acknowledged; the Guided Access part only under Guided Access, until it is acknowledged.
    func testThePartsDueFollowTheAcknowledgmentsAndGuidedAccess() {
        typealias Parts = FirstArmBriefing.Parts
        for guidedAccessOn in [false, true] {
            for disarmAck in [false, true] {
                for guidedAccessAck in [false, true] {
                    XCTAssertTrue(FirstArmBriefing.partsDue(ownerStarted: false, guidedAccessOn: guidedAccessOn,
                                                            disarmAcknowledged: disarmAck,
                                                            guidedAccessAcknowledged: guidedAccessAck,
                                                            voiceControlAcknowledged: true).isEmpty,
                                  "an automatic re-arm never waits for a tap")
                    let due = FirstArmBriefing.partsDue(ownerStarted: true, guidedAccessOn: guidedAccessOn,
                                                        disarmAcknowledged: disarmAck,
                                                        guidedAccessAcknowledged: guidedAccessAck,
                                                        voiceControlAcknowledged: true)
                    XCTAssertEqual(due, Parts(disarm: !disarmAck, guidedAccess: guidedAccessOn && !guidedAccessAck),
                                   "Guided Access \(guidedAccessOn), acknowledged \(disarmAck), \(guidedAccessAck)")
                }
            }
        }
    }

    /// The owner's choice: new installs only. A stored acknowledgment always wins; without one, an install that has
    /// armed before starts acknowledged (it never sees the screen), and one that has not starts with both parts due.
    func testOnlyANewInstallStartsWithTheScreenDue() {
        XCTAssertFalse(FirstArmBriefing.initialAcknowledged(stored: nil, hasArmedOnce: false), "a new install")
        XCTAssertTrue(FirstArmBriefing.initialAcknowledged(stored: nil, hasArmedOnce: true), "an update")
        XCTAssertTrue(FirstArmBriefing.initialAcknowledged(stored: true, hasArmedOnce: false), "acknowledged before")
        XCTAssertFalse(FirstArmBriefing.initialAcknowledged(stored: false, hasArmedOnce: true),
                       "seeded before the first arm: the first arm's own go-live does not end it")
    }

    // MARK: - The arming flow

    /// A new install's first arm: Start countdown brings the screen (the disarm part only, Guided Access off) and
    /// the countdown waits; "I understand" acknowledges it and starts the countdown. The next arm goes straight on.
    func testTheFirstArmWaitsForTheScreenAndTheNextDoesNot() {
        newInstall()
        let rig = engine()
        rig.engine.beginArming()
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck)
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.state, .guidedAccessCheck, "the countdown waits for the screen's button")
        XCTAssertEqual(rig.engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: true, guidedAccess: false))
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming, "I understand starts the countdown")
        XCTAssertNil(rig.engine.firstArmBriefing)
        XCTAssertTrue(acknowledged().disarm)
        XCTAssertFalse(acknowledged().guidedAccess, "the Guided Access part was not shown, so it is still due")
        rig.engine.cancelArming()

        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.state, .arming, "an acknowledged screen does not come back")
        XCTAssertNil(rig.engine.firstArmBriefing)
        rig.engine.cancelArming()
    }

    /// The first arm under Guided Access shows both parts on the one screen; a later Guided Access arm after the
    /// disarm part alone was acknowledged shows only the Guided Access part.
    func testAFirstArmUnderGuidedAccessShowsBothPartsOnce() {
        newInstall()
        let rig = engine()
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: true, guidedAccess: true))
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming)
        XCTAssertTrue(acknowledged().disarm && acknowledged().guidedAccess)
        rig.engine.cancelArming()

        UserDefaults.standard.set(false, forKey: Self.guidedAccessAckKey)   // the disarm part seen without Guided Access
        rig.engine.beginArming()
        rig.engine.startCountdownTapped()
        XCTAssertEqual(rig.engine.firstArmBriefing, FirstArmBriefing.Parts(disarm: false, guidedAccess: true))
        rig.engine.acknowledgeFirstArmBriefing()
        XCTAssertEqual(rig.engine.state, .arming)
        rig.engine.cancelArming()
    }

    /// The automatic re-arm after a crash runs with nobody watching: on a new install it still goes straight to its
    /// countdown, with no screen and nothing acknowledged.
    func testTheAutomaticReArmNeverShowsTheScreen() {
        newInstall()
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        let entitlements = ProEntitlements.unresolvedForTesting()
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        entitlements.resolveForTesting(as: .free)
        XCTAssertTrue(pump(until: { engine.state == .arming }, timeout: 3), "the owed re-arm starts its countdown")
        XCTAssertTrue(engine.armWasAutoRecovered)
        XCTAssertNil(engine.firstArmBriefing, "no screen in front of an automatic re-arm")
        XCTAssertFalse(acknowledged().disarm || acknowledged().guidedAccess, "and nothing acknowledged for the owner")
        engine.disarm()
    }

    // MARK: - The screen

    /// Both parts, in the owner's words, with the forgotten-passcode line and the button.
    private static let everyText = [FirstArmBriefing.title, FirstArmBriefing.disarmHeading, FirstArmBriefing.disarmText,
                                    FirstArmBriefing.guidedAccessHeading, FirstArmBriefing.guidedAccessText,
                                    FirstArmBriefing.forgotPasscodeText, FirstArmBriefing.footnote,
                                    FirstArmBriefing.button]

    /// At the largest text size on a short screen the whole text is there to scroll through, and the button stays in
    /// view; with Guided Access off the Guided Access part is left out.
    func testTheScreenShowsItsWordsAndKeepsItsButtonInViewAtTheLargestTextSize() throws {
        let both = FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: true), recording: Self.noCamera) {}
            .environment(\.dynamicTypeSize, .accessibility5)
        let layout = try shownOnScreen(both, in: Self.shortScreen)
        for text in Self.everyText {
            XCTAssertTrue(layout.shown.contains(text), "missing: \(text)")
        }
        let button = try XCTUnwrap(layout.frames[FirstArmBriefing.button], "the button's frame")
        XCTAssertGreaterThanOrEqual(button.minY, 0, "the button is above the top: \(button)")
        XCTAssertLessThanOrEqual(button.maxY, Self.shortScreen.height, "the button is below the screen: \(button)")

        let disarmOnly = try shownOnScreen(FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: false),
                                                                recording: Self.noCamera) {},
                                           in: Self.shortScreen).shown
        XCTAssertTrue(disarmOnly.contains(FirstArmBriefing.disarmText))
        XCTAssertFalse(disarmOnly.contains(FirstArmBriefing.guidedAccessText), "Guided Access off: no Guided Access part")
        XCTAssertFalse(disarmOnly.contains(FirstArmBriefing.forgotPasscodeText))
    }

    /// On the Guided Access step, once Start countdown has asked for it, the arming screen shows it over the step.
    func testTheArmingScreenShowsItOnceStartCountdownAsksForIt() throws {
        newInstall()
        let rig = engine()
        rig.engine.beginArming()
        func arming() throws -> [String] {
            try shownOnScreen(ArmingView()
                .environmentObject(rig.engine)
                .environmentObject(rig.entitlements)
                .environmentObject(rig.settings)).shown
        }
        XCTAssertFalse(try arming().contains(FirstArmBriefing.disarmText), "not before Start countdown")
        rig.engine.startCountdownTapped()
        let shown = try arming()
        XCTAssertTrue(shown.contains(FirstArmBriefing.disarmText), "the screen is not shown: \(shown)")
        XCTAssertTrue(shown.contains(FirstArmBriefing.button))
        rig.engine.acknowledgeFirstArmBriefing()
        rig.engine.cancelArming()
    }

    /// While a camera runs (on a charger, or in Instant mode, the camera starts at the ARM tap) the screen shows the
    /// REC badge, as the arming screens do; it goes with the camera.
    func testTheScreenShowsTheRECBadgeWhileACameraRuns() throws {
        let camera = FakeCamera()
        let screen = FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: false),
                                          recording: camera.isRecordingActivePublisher) {}
        camera.setRecordingActive(true)
        XCTAssertTrue(try shownOnScreen(screen).shown.contains("REC"), "no REC badge while the camera runs")
        camera.setRecordingActive(false)
        XCTAssertFalse(try shownOnScreen(screen).shown.contains("REC"), "the badge outlives the camera")
    }

    private static let noCamera = Just(false).eraseToAnyPublisher()

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}
