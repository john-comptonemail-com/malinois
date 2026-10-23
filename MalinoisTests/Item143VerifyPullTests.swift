//
//  Item143VerifyPullTests.swift
//  MalinoisTests
//
//  BACKLOG 143, item 145 step 6 (the owner's ruling 2026-10-20: "1.8.1 or later"). On a new device, Home's "Allow
//  notifications" line appeared only after iCloud was verified AND Malinois was reopened: the line waits for another
//  device's records, which arrive with the launch pull, and Verify iCloud access ran only the upload retry and a plain
//  pull, which neither refreshes the line nor settles the restore owed since the install. Now a successful
//  verification runs what a relaunch would have (`cloudAccessVerified()`: the retry, then the launch pull), still
//  asking for everything the log can hold, as the button's pull did. The button's wiring is checked in its source:
//  `enrollCloudAccess()` needs Face ID or the passcode, which a test cannot give. The notifications line also needs
//  iOS never to have asked this simulator for notifications (the app never asks at launch, and the test runs use a
//  simulator of their own). Written before the change, red at that commit (against a stub that does what the button
//  did).
//

import XCTest
import UserNotifications
@testable import Malinois

@MainActor
final class Item143VerifyPullTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let entitlements: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem143")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// A new install: an empty log (so a restore is owed), Pro still being checked, iOS reporting an iCloud account.
    private func makeRig() async -> Rig {
        let store = EventStore()
        let cloud = CloudExfiltrator()
        cloud.accountStatusForTesting = .available
        await cloud.refreshAccountState()
        let entitlements = ProEntitlements.unresolvedForTesting()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, store: store, entitlements: entitlements)
    }

    /// Another device's tamper, as a pull from iCloud brings it.
    private func otherDevicesTamper() -> Event {
        let at = Date().addingTimeInterval(-60)
        return Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .synced,
                     sourceDevice: "iPhone Air")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - The pull

    /// Verified, the other device's record comes down and Home offers "Allow notifications" at once, without a relaunch.
    func testVerifyingShowsTheNotificationsLineWithoutARelaunch() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        XCTAssertEqual(status, .notDetermined, "precondition: iOS has never asked this simulator for notifications")
        let wasHidden = OnboardingState.notificationAskHidden
        OnboardingState.notificationAskHidden = false
        defer { OnboardingState.notificationAskHidden = wasHidden }

        let rig = await makeRig()
        let tamper = otherDevicesTamper()
        var verified = false
        var asked = 0
        rig.engine.cloudFetchForTesting = { _ in
            asked += 1
            return verified ? ([tamper], true) : ([], false)   // before verifying, a pull cannot reach iCloud
        }
        rig.entitlements.resolveForTesting(as: .trial)   // the launch: the retry and the launch pull
        await waitUntil { asked > 0 && !rig.engine.cloudRestoreInProgress }
        try? await Task.sleep(nanoseconds: 300_000_000)   // the launch pull's notifications refresh lands
        XCTAssertFalse(rig.engine.notificationAskDue, "no other device's record yet: no line")

        verified = true
        await rig.engine.cloudAccessVerified()
        await waitUntil { rig.engine.notificationAskDue }
        XCTAssertTrue(rig.store.events.contains { $0.id == tamper.id }, "the other device's record is in the log")
        XCTAssertTrue(rig.engine.notificationAskDue, "Home offers Allow notifications at once")
    }

    /// Verified, the pull reaches iCloud and runs to the end, which settles the restore owed since the install: what
    /// later pulls bring counts as news on Home.
    func testVerifyingSettlesTheRestoreOwedSinceTheInstall() async {
        let rig = await makeRig()
        XCTAssertNotNil(rig.store.restoreOwedSince, "a new install owes a restore")
        let tamper = otherDevicesTamper()
        var verified = false
        var asked = 0
        rig.engine.cloudFetchForTesting = { _ in
            asked += 1
            return verified ? ([tamper], true) : ([], false)
        }
        rig.entitlements.resolveForTesting(as: .trial)
        await waitUntil { asked > 0 && !rig.engine.cloudRestoreInProgress }
        XCTAssertNotNil(rig.store.restoreOwedSince, "the launch pull could not reach iCloud: the restore is still owed")

        verified = true
        await rig.engine.cloudAccessVerified()
        XCTAssertNil(rig.store.restoreOwedSince, "the verified pull reached iCloud and ran to the end")
    }

    /// A device verifying again with a log already (a newly selected account) is not cut down to the launch rule's one
    /// page: Verify still asks for everything the log can hold, as the button's pull did.
    func testVerifyingAsksForEverythingTheLogCanHold() async {
        let rig = await makeRig()
        let tamper = otherDevicesTamper()
        var asked: [Int] = []
        rig.engine.cloudFetchForTesting = { limit in
            asked.append(limit)
            return ([tamper], true)
        }
        rig.entitlements.resolveForTesting(as: .trial)
        await waitUntil { !asked.isEmpty && !rig.engine.cloudRestoreInProgress }
        XCTAssertNil(rig.store.restoreOwedSince, "the launch pull reached iCloud: nothing owed")
        XCTAssertEqual(MonitoringEngine.launchSyncLimit(localEventCount: rig.store.events.count, restoreOwed: false,
                                                        cap: EventStore.maxEvents, page: CloudExfiltrator.fetchPageSize),
                       CloudExfiltrator.fetchPageSize, "the launch rule alone would ask for one page now")

        await rig.engine.cloudAccessVerified()
        XCTAssertEqual(asked.last, EventStore.maxEvents, "Verify asks for everything the log can hold")
    }

    // MARK: - The button

    /// Settings' Verify iCloud access runs the verified pull, and only that, once the verification succeeds.
    func testTheVerifyButtonRunsTheVerifiedPull() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Malinois/Views/SettingsView.swift"), encoding: .utf8)
        guard let start = source.range(of: "if await cloud.enrollCloudAccess() {"),
              let end = source.range(of: "}", range: start.upperBound..<source.endIndex) else {
            return XCTFail("the Verify button's success branch was not found")
        }
        let branch = source[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "await engine.cloudAccessVerified()")
    }
}
