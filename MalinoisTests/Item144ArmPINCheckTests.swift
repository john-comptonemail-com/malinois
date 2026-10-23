//
//  Item144ArmPINCheckTests.swift
//  MalinoisTests
//
//  BACKLOG 144 (c), item 145 step 8 (ADR 0054; the owner's ruling 2026-10-22: "options as recommended", 14 days and
//  option A). A forgotten Malinois PIN was found only at the disarm pad, after Guided Access had locked the phone in
//  the app. Now Home's ARM tap asks for the PIN first when it has not been entered correctly for 14 days, or when no
//  entry is on record (so an install updating to 1.8.1 is asked once). Every correct entry and every PIN set writes the
//  time beside the hash in the Keychain; a Face ID open never counts. PIN only, under the usual lockout; never in
//  front of the automatic re-arm. The Keychain tests skip on an unsigned build, as the suite's others do (a run script
//  counts a skip as a failure). Home's tap is checked through its rule and its source, since the harness renders
//  screens but cannot tap them; the pad itself is rendered. Written before the change, red at that commit (against
//  compile-only stubs).
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item144ArmPINCheckTests: XCTestCase {

    private let day: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem144ArmPIN")
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { KeychainService.wipeStalePINData() }
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeEngine() -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: EventStore(), cloud: CloudExfiltrator(),
                                             camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                             timing: EngineCharacterizationTests.fastTiming))
    }

    private func plant(_ date: Date) {
        KeychainService.writeLastEntryForTesting(String(date.timeIntervalSince1970))
    }

    // MARK: - The rule

    /// Due with no correct entry on record, once 14 days have passed since the last one, or when the stored time lies
    /// ahead of the clock (it went back: ask rather than trust).
    func testTheRuleAsksWithNoEntryAfterFourteenDaysOrWithATimeAhead() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(MonitoringEngine.armPINCheckInterval, 14 * day, "the owner's ruling: 14 days")
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: nil, now: now), "none on record: asked once (option A)")
        XCTAssertFalse(MonitoringEngine.armPINCheckDue(lastEntry: now, now: now), "just entered")
        XCTAssertFalse(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-13 * day), now: now))
        XCTAssertFalse(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-14 * day + 1), now: now))
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-14 * day), now: now),
                      "14 days to the second")
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(-400 * day), now: now))
        XCTAssertTrue(MonitoringEngine.armPINCheckDue(lastEntry: now.addingTimeInterval(60), now: now),
                      "a time ahead of the clock")
    }

    // MARK: - The time of the last correct entry

    /// Setting the PIN and a correct entry write the time; a wrong entry leaves it alone.
    func testANewPINAndACorrectEntryWriteTheTimeAndAWrongOneDoesNot() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let set = try XCTUnwrap(KeychainService.lastCorrectEntry, "setting the PIN writes the time")
        XCTAssertLessThan(abs(set.timeIntervalSinceNow), 5)
        let old = Date().addingTimeInterval(-20 * day)
        plant(old)
        XCTAssertFalse(KeychainService.verify("1111"), "a wrong PIN")
        let afterWrong = try XCTUnwrap(KeychainService.lastCorrectEntry)
        XCTAssertLessThan(abs(afterWrong.timeIntervalSince(old)), 1, "a wrong entry leaves the time alone")
        XCTAssertTrue(KeychainService.verify("4821"))
        let afterRight = try XCTUnwrap(KeychainService.lastCorrectEntry, "a correct entry writes the time")
        XCTAssertLessThan(abs(afterRight.timeIntervalSinceNow), 5)
    }

    /// The engine's answer from the real Keychain: not due with a fresh time; due with a stale, missing, unreadable,
    /// non-finite or future one.
    func testTheEngineAsksWhenTheTimeIsStaleMissingDamagedOrAheadAndNotWhenFresh() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        let engine = makeEngine()
        XCTAssertFalse(engine.armPINCheckIsDue, "the PIN was just set")
        plant(Date().addingTimeInterval(-15 * day))
        XCTAssertTrue(engine.armPINCheckIsDue, "15 days without a correct entry")
        KeychainService.removeLastEntryForTesting()
        XCTAssertTrue(engine.armPINCheckIsDue, "none on record: an install updating to 1.8.1")
        KeychainService.writeLastEntryForTesting("not a time")
        XCTAssertTrue(engine.armPINCheckIsDue, "an unreadable time")
        KeychainService.writeLastEntryForTesting("inf")
        XCTAssertTrue(engine.armPINCheckIsDue, "a time that is not finite")
        plant(Date().addingTimeInterval(3 * day))
        XCTAssertTrue(engine.armPINCheckIsDue, "a time ahead of the clock")
    }

    // MARK: - Home

    /// The ARM tap's gate: PIN only, with its own prompt, opened only when the check is due.
    func testTheArmGateIsPINOnlyWithItsOwnPrompt() {
        XCTAssertEqual(HomeView.Gate.arm.prompt, "Enter PIN to arm")
        XCTAssertFalse(HomeView.Gate.arm.allowsBiometrics, "no Face ID: it proves nothing about remembering the PIN")
        XCTAssertEqual(HomeView.armTapGate(pinCheckDue: true), .arm)
        XCTAssertNil(HomeView.armTapGate(pinCheckDue: false), "otherwise the tap arms at once")
    }

    /// The pad the gate opens shows the arm prompt.
    func testThePadShowsTheArmPrompt() throws {
        let settings = AppSettings()
        settings.biometricUnlock = true   // the owner's Face ID unlock on: the arm gate still never offers it
        let pad = PINEntryView(title: HomeView.Gate.arm.prompt, allowBiometrics: HomeView.Gate.arm.allowsBiometrics,
                               onSuccess: {}, onCancel: {})
            .environmentObject(settings)
        let shown = try shownOnScreen(pad).shown
        XCTAssertTrue(shown.contains("Enter PIN to arm"), "shown: \(shown)")
    }

    /// Home's ARM tap consults the check and, when due, opens the arm gate; a correct PIN then arms.
    func testHomesARMTapGoesThroughTheCheckAndACorrectPINArms() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Malinois/Views/HomeView.swift"), encoding: .utf8)
        let tap = try body(of: "private func armTapped() {", in: source)
        XCTAssertTrue(tap.contains("Self.armTapGate(pinCheckDue: engine.armPINCheckIsDue)"),
                      "the ARM tap does not consult the check: \(tap)")
        let open = try body(of: "private func openUnlocked() {", in: source)
        XCTAssertTrue(open.contains("case .arm:") && open.contains("armAfterChecks()"), "a correct PIN does not arm: \(open)")
    }

    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) not found")
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    // MARK: - The automatic re-arm

    /// With no correct entry on record the ARM tap would ask, but the owed re-arm after a crash arms by itself: it calls
    /// the countdown directly and never meets the check.
    func testTheAutomaticReArmNeverMeetsTheCheck() {
        KeychainService.removeLastEntryForTesting()
        UserDefaults.standard.set(true, forKey: "com.malinois.recovery.pendingReArm")
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
        XCTAssertEqual(engine.state, .arming, "the owed re-arm starts its countdown without a PIN")
        engine.disarm()
    }
}
