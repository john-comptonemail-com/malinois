//
//  Item155NotificationAskTests.swift
//  MalinoisTests
//
//  BACKLOG 155's A11 (1.8.2's step 25; the owner's ruling: yes). Home's "Allow notifications" line waited for a record
//  stamped with another device's name (item 69), so two devices with one name, or an account with no events yet, never
//  saw it. Home now also offers it once this installation has been verified for iCloud (its durable grant), every other
//  condition kept: Pro, iCloud ready, Cross-device alerts on, iOS never asked, Hide not tapped. The engine case needs
//  iOS never to have asked this simulator for notifications, as item 143's does. Written before the change, red at that
//  commit (against a stub that ignores the verification).
//

import XCTest
import UserNotifications
@testable import Malinois

@MainActor
final class Item155NotificationAskTests: XCTestCase {

    // Set in setUp and restored in tearDown, which XCTest runs without main-actor isolation (item 97).
    nonisolated(unsafe) private var wasHidden = false

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem155Ask")
        wasHidden = OnboardingState.notificationAskHidden
        OnboardingState.notificationAskHidden = false
    }

    override func tearDown() {
        OnboardingState.notificationAskHidden = wasHidden
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The rule

    /// Due once this installation is verified, with no other device's record; every other condition still applies.
    func testTheAskIsDueOnceVerifiedWithNoOtherDevicesRecord() {
        func due(auth: Bool = true, alerts: Bool = true, pro: Bool = true, cloud: Bool = true, other: Bool = false,
                 verified: Bool = true, hidden: Bool = false) -> Bool {
            MonitoringEngine.notificationAskIsDue(authUndetermined: auth, notifyOtherDevices: alerts, pro: pro,
                                                  cloudReady: cloud, otherDeviceSeen: other, verified: verified,
                                                  hidden: hidden)
        }
        XCTAssertTrue(due(), "verified, no other device yet: offered")
        XCTAssertTrue(due(other: true, verified: false), "another device's record, as before")
        XCTAssertFalse(due(verified: false), "neither: not offered")
        XCTAssertFalse(due(auth: false), "already answered")
        XCTAssertFalse(due(alerts: false), "Cross-device alerts off")
        XCTAssertFalse(due(pro: false), "no Pro, no alerts")
        XCTAssertFalse(due(cloud: false), "no iCloud, nothing to receive")
        XCTAssertFalse(due(hidden: true), "the owner tapped Hide")
    }

    // MARK: - The engine

    /// A Pro install with iCloud ready and an empty log: the line once verified, not before.
    private func makeEngine(verifiedFor account: String?) async -> MonitoringEngine {
        let root = EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("enrollment-155/state.json"),
                                         authenticate: { _ in true })
        if let account {
            let enrolled = await enrollment.enroll(account: account, resolve: { account })
            XCTAssertTrue(enrolled, "verified")
        }
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountStatusForTesting = .available
        await cloud.refreshAccountState()
        return TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: EventStore(), cloud: cloud,
                                                    camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                    timing: EngineCharacterizationTests.fastTiming))
    }

    /// Codex's note on c75f223: Home does not offer the line under Guided Access, where iOS shows no permission
    /// question (ADR 0011: the camera's blocked question was taken as a refusal); once Guided Access ends, it does.
    func testHomeDoesNotOfferTheLineUnderGuidedAccess() async throws {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        XCTAssertEqual(status, .notDetermined, "precondition: iOS has never asked this simulator for notifications")
        let engine = await makeEngine(verifiedFor: "account-A")
        await engine.refreshNotificationHealth()
        XCTAssertTrue(engine.notificationAskDue, "due")
        func home() throws -> [String] {
            try shownOnScreen(HomeView()
                .environmentObject(engine)
                .environmentObject(engine.settings)
                .environmentObject(engine.cloud)
                .environmentObject(engine.eventStore)
                .environmentObject(engine.entitlements)).shown
        }
        engine.simulateGuidedAccessForTesting(on: true)
        XCTAssertFalse(try home().contains(HomeView.notificationAskLine), "not under Guided Access")
        engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertTrue(try home().contains(HomeView.notificationAskLine), "again once it ends")
    }

    func testAVerifiedInstallationIsOfferedTheLine() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        XCTAssertEqual(status, .notDetermined, "precondition: iOS has never asked this simulator for notifications")
        let engine = await makeEngine(verifiedFor: "account-A")
        await engine.refreshNotificationHealth()
        XCTAssertTrue(engine.notificationAskDue, "verified: Home offers Allow notifications")
    }

    /// Control: not verified, no other device's record: no line, as before.
    func testAnUnverifiedInstallationIsNotOffered() async {
        let engine = await makeEngine(verifiedFor: nil)
        await engine.refreshNotificationHealth()
        XCTAssertFalse(engine.notificationAskDue)
    }
}
