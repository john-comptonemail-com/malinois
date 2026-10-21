import SwiftUI
import XCTest
@testable import Malinois

/// Item 140's codex-1 (Codex's look at 1.8 (74)): whenever this installation's iCloud access was not current, Home's
/// orange line said "events recorded before then stay on this iPhone" and its iCloud row said "iCloud verification
/// needed". True before the installation's first verification and after another account was seen. Not for a verified
/// installation that has not reached iCloud since a relaunch, or that lost it for a while (offline): what it records
/// is tied to the verified account and uploads once iCloud names that account again, with no new verification. Home
/// then says "Waiting for iCloud" and shows no orange line. With iCloud backup off the backup-off line says it all.
///
/// Each test runs a real enrollment and iCloud service, with an engine, and only iOS's two answers stood in for: the
/// account's name and its status (the Simulator has no iCloud container). The row is read off the real Home screen.
/// The orange line is read from the function Home shows it with: without a container, Home has the "isn't available
/// in this build" line in its place.
@MainActor
final class Item140HomePauseTests: XCTestCase {
    private static let needed = "iCloud verification needed"
    private static let waiting = "Waiting for iCloud"

    private final class Prompts { var count = 0 }

    private struct Rig {
        let gate: CloudEnrollment
        let cloud: CloudExfiltrator
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
        let entitlements: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem140Home")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - States that keep new events on this iPhone

    /// Never verified: the row asks for verification and the line says events stay here, which they do.
    func testNeverVerifiedHomeAsksForVerificationAndSaysEventsStayHere() async throws {
        let rig = await makeRig(file: Self.file(), prompts: Prompts())
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let lease = await rig.cloud.acquireCloudLease()
        XCTAssertNil(lease, "not verified on this installation")
        XCTAssertFalse(rig.gate.newEventsBindToVerifiedAccount)
        let recorded = Self.event()
        rig.gate.registerLocalEvent(recorded)
        XCTAssertEqual(rig.gate.uploadHoldReason(for: recorded), .unknownAccount)
        let shown = try home(rig)
        XCTAssertTrue(shown.contains(Self.needed), "\(shown)")
        XCTAssertFalse(shown.contains(Self.waiting), "\(shown)")
        XCTAssertEqual(line(rig), HomeView.iCloudPausedNotice)
        XCTAssertTrue(HomeView.iCloudPausedNotice.contains("stay on this iPhone"))
    }

    /// Verified for one account, then another seen: new events are held, also after a relaunch.
    func testAnotherAccountSeenHomeAsksForVerificationAndSaysEventsStayHere() async throws {
        let path = Self.file()
        let rig = await makeRig(file: path, prompts: Prompts())
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let enrolled = await rig.cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled)
        rig.cloud.accountIdentityForTesting = { "account-b" }
        let lease = await rig.cloud.acquireCloudLease()
        XCTAssertNil(lease, "another account")
        XCTAssertFalse(rig.gate.newEventsBindToVerifiedAccount)
        let recorded = Self.event()
        rig.gate.registerLocalEvent(recorded)
        XCTAssertNotNil(rig.gate.uploadHoldReason(for: recorded))
        let shown = try home(rig)
        XCTAssertTrue(shown.contains(Self.needed), "\(shown)")
        XCTAssertFalse(shown.contains(Self.waiting), "\(shown)")
        XCTAssertEqual(line(rig), HomeView.iCloudPausedNotice)
        let relaunched = CloudEnrollment(file: path, authenticate: { _ in false })
        XCTAssertFalse(relaunched.newEventsBindToVerifiedAccount, "the other account is remembered")
    }

    // MARK: - A verified installation waiting for iCloud

    /// Verified, then iCloud out of reach (offline): what it records waits for the same account, with no new prompt.
    func testAVerifiedInstallationOfflineIsWaitingAndItsEventsUploadAfter() async throws {
        let prompts = Prompts()
        let rig = await makeRig(file: Self.file(), prompts: prompts)
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let enrolled = await rig.cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled)
        XCTAssertEqual(prompts.count, 1)
        rig.cloud.accountIdentityForTesting = { nil }   // fetching the account fails, as it does offline
        let offline = await rig.cloud.acquireCloudLease()
        XCTAssertNil(offline)
        XCTAssertFalse(rig.gate.verified)
        XCTAssertTrue(rig.cloud.accountState.isReady, "iOS still reports the account")
        XCTAssertTrue(rig.gate.newEventsBindToVerifiedAccount)
        let recorded = Self.event()
        rig.gate.registerLocalEvent(recorded)
        XCTAssertNil(rig.gate.uploadHoldReason(for: recorded), "tied to the verified account")
        let shown = try home(rig)
        XCTAssertTrue(shown.contains("Waiting for iCloud"), "\(shown)")
        XCTAssertFalse(shown.contains(Self.needed), "\(shown)")
        XCTAssertNil(line(rig))
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let back = await rig.cloud.acquireCloudLease()
        let lease = try XCTUnwrap(back, "the same account resumes")
        XCTAssertTrue(rig.gate.authorizeUpload(event: recorded, lease: lease))
        XCTAssertEqual(prompts.count, 1, "no new verification")
    }

    /// Verified, then relaunched before iCloud answers: the same, from the grant on file.
    func testAVerifiedInstallationRelaunchedIsWaitingUntilICloudAnswers() async throws {
        let path = Self.file()
        let first = CloudEnrollment(file: path, authenticate: { _ in true })
        let enrolled = await first.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let prompts = Prompts()
        let rig = await makeRig(file: path, prompts: prompts)
        XCTAssertFalse(rig.gate.verified, "not current until iCloud names the account")
        XCTAssertTrue(rig.gate.newEventsBindToVerifiedAccount)
        let recorded = Self.event()
        rig.gate.registerLocalEvent(recorded)
        XCTAssertNil(rig.gate.uploadHoldReason(for: recorded))
        let shown = try home(rig)
        XCTAssertTrue(shown.contains(Self.waiting), "\(shown)")
        XCTAssertFalse(shown.contains(Self.needed), "\(shown)")
        XCTAssertNil(line(rig))
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let answered = await rig.cloud.acquireCloudLease()
        let lease = try XCTUnwrap(answered)
        XCTAssertTrue(rig.gate.authorizeUpload(event: recorded, lease: lease))
        XCTAssertEqual(prompts.count, 0, "no new verification")
    }

    // MARK: - Controls

    /// Verified and current: "iCloud ready" and no line.
    func testAVerifiedInstallationOnlineShowsICloudReadyAndNoLine() async throws {
        let rig = await makeRig(file: Self.file(), prompts: Prompts())
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let enrolled = await rig.cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled)
        let shown = try home(rig)
        XCTAssertTrue(shown.contains("iCloud ready"), "\(shown)")
        XCTAssertNil(line(rig))
    }

    /// iCloud backup off: new events stay here whatever the account, and the backup-off line says so; no orange
    /// iCloud line under it asks for a verification that would back nothing up.
    func testBackupOffHomeShowsNoPauseLine() async throws {
        let rig = await makeRig(file: Self.file(), prompts: Prompts())
        rig.cloud.accountIdentityForTesting = { "account-a" }
        let enrolled = await rig.cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled)
        XCTAssertTrue(rig.engine.setCloudBackup(false), "turned off the Settings way, while disarmed")
        rig.cloud.accountIdentityForTesting = { nil }
        _ = await rig.cloud.acquireCloudLease()
        XCTAssertFalse(rig.gate.verified)
        XCTAssertFalse(rig.gate.newEventsBindToVerifiedAccount, "held while backup is off")
        let shown = try home(rig)
        XCTAssertTrue(shown.contains(MonitoringEngine.backupOffNotice), "\(shown)")
        XCTAssertNil(line(rig))
        XCTAssertNil(HomeView.iCloudPauseLine(proActive: true, backupOn: false, verified: false, newEventsBound: false,
                                              cloudUnavailable: false), "never verified, backup off")
    }

    // MARK: - Rig

    private func makeRig(file: URL, prompts: Prompts) async -> Rig {
        let gate = CloudEnrollment(file: file, authenticate: { _ in prompts.count += 1; return true })
        CloudEnrollment.sharedForTesting = gate   // the one Home observes
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let store = EventStore()
        let cloud = CloudExfiltrator(enrollment: gate)
        cloud.accountStatusForTesting = .available   // iOS reports an account, also to Home's own check
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        try? await Task.sleep(nanoseconds: 200_000_000)   // the launch sweep finds no identity and ends
        XCTAssertTrue(settings.cloudBackup)
        return Rig(gate: gate, cloud: cloud, engine: engine, settings: settings, store: store, entitlements: entitlements)
    }

    /// What the real Home shows.
    private func home(_ rig: Rig) throws -> [String] {
        try shownOnScreen(HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(rig.cloud)
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)).shown
    }

    /// Home's orange iCloud line for the rig's state, on a device whose build has its iCloud container.
    private func line(_ rig: Rig) -> String? {
        HomeView.iCloudPauseLine(proActive: rig.entitlements.proActive, backupOn: rig.settings.cloudBackup,
                                 verified: rig.gate.verified, newEventsBound: rig.gate.newEventsBindToVerifiedAccount,
                                 cloudUnavailable: false)
    }

    private static func file() -> URL {
        (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
    }

    private static func event() -> Event { Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]) }
}
