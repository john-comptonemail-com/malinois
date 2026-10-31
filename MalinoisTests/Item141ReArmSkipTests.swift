//
//  Item141ReArmSkipTests.swift
//  MalinoisTests
//
//  Fable's fable-3 on 1.8 (75) (BACKLOG 141; item 132, from the owner's TestFlight 1.7.1 question): when the
//  crash-loop guard declines an automatic re-arm (two attempts within 90 seconds), nothing said so; Home showed at most
//  "Recovered an interrupted armed session". Now Home says the re-arm was skipped, and why; a re-arm that runs says
//  nothing of the kind, and the owner's next arm clears it. Driven through a real engine's launch recovery. Written
//  before the change, red at that commit (against compile-only stubs). Item 132's remainder and item 153's MAL-10
//  (1.8.2's step 20): the skip also leaves a silent record in the Event Log, read back on the owner's other devices
//  with no alert; those tests too were red at their commit.
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item141ReArmSkipTests: XCTestCase {
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let lastAttemptKey = "com.malinois.recovery.lastAt"

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
        let entitlements: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem141ReArm")
    }

    override func tearDown() {
        TestIsolation.tearDown()   // the recovery flags go with it
        super.tearDown()
    }

    /// Owed less than 90 seconds after the last attempt: the guard declines it, and Home says so.
    func testASkippedReArmSaysSoOnHome() throws {
        owe(lastAttemptSecondsAgo: 10)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.reArmSkipped }, timeout: 3), "Home is not told")
        XCTAssertEqual(rig.engine.state, .disarmed, "not re-armed")
        XCTAssertTrue(try home(rig).contains(HomeView.reArmSkippedNotice))
    }

    /// A re-arm that runs says nothing of the kind.
    func testAReArmThatRunsLeavesNoNotice() throws {
        owe(lastAttemptSecondsAgo: 600)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3), "the owed re-arm starts its countdown")
        XCTAssertFalse(rig.engine.reArmSkipped)
        rig.engine.disarm()
        XCTAssertFalse(try home(rig).contains(HomeView.reArmSkippedNotice))
    }

    /// The owner's own next arm clears it.
    func testTheNextArmClearsIt() {
        owe(lastAttemptSecondsAgo: 10)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.reArmSkipped }, timeout: 3))
        rig.engine.beginArming()
        XCTAssertFalse(rig.engine.reArmSkipped)
        rig.engine.cancelArming()
    }

    /// It gives the rule and what to do.
    func testTheNoticeGivesTheRule() {
        XCTAssertTrue(HomeView.reArmSkippedNotice.contains("90 seconds"), HomeView.reArmSkippedNotice)
        XCTAssertTrue(HomeView.reArmSkippedNotice.contains("Arm it again"), HomeView.reArmSkippedNotice)
    }

    // MARK: - The Event Log's record (item 132's remainder; item 153's MAL-10)

    /// The skip leaves a quiet status entry, in Home's words.
    func testASkippedReArmLeavesARecordInTheLog() {
        owe(lastAttemptSecondsAgo: 10)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.reArmSkipped }, timeout: 3))
        let record = rig.store.events.first { $0.stateChange == "reArmSkipped" }
        XCTAssertNotNil(record, "the skip is in the log")
        XCTAssertEqual(record?.sensorSummary,
                       "Not re-armed automatically: Malinois was closed again within 90 seconds of re-arming itself")
    }

    /// A re-arm that runs leaves no such record.
    func testAReArmThatRunsLeavesNoRecord() {
        owe(lastAttemptSecondsAgo: 600)
        let rig = launch()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3))
        XCTAssertFalse(rig.store.events.contains { $0.stateChange == "reArmSkipped" })
        rig.engine.disarm()
    }

    /// The owner's other devices read it back from iCloud, with no alert there or on the watch; it has an icon of its own.
    func testTheRecordIsReadBackElsewhereWithNoAlert() {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "reArmSkipped")
        let record = CloudExfiltrator.makeStateRecord(event, kind: "reArmSkipped", deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "reArmSkipped")
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "reArmSkipped"), "no disarm alert through iCloud")
        XCTAssertTrue(WatchAlertRelay.alerts(for: [event], alertsOn: true, proActive: true).isEmpty, "nothing to the watch")
        XCTAssertEqual(EventRow.placeholderIcon(for: "reArmSkipped"), "exclamationmark.arrow.triangle.2.circlepath",
                       "Home's notice's own symbol")
    }

    // MARK: - Helpers

    private func owe(lastAttemptSecondsAgo seconds: TimeInterval) {
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970 - seconds, forKey: Self.lastAttemptKey)
    }

    /// A launch with a re-arm owed: the recovery runs once the Pro check has resolved, as on the phone.
    private func launch() -> Rig {
        let entitlements = ProEntitlements.unresolvedForTesting()
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        entitlements.resolveForTesting(as: .trial)
        return Rig(engine: engine, settings: settings, store: store, entitlements: entitlements)
    }

    /// What the real Home shows.
    private func home(_ rig: Rig) throws -> [String] {
        try shownOnScreen(HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(CloudExfiltrator())
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)).shown
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}

// MARK: - Recovery marker handoffs (item 175, codex-4)

/// Observe the real launch/foreground transition immediately after each predecessor is retired.
/// Launch starts locked so the observer is installed before recovery runs; unresolved entitlements
/// keep the first handoff owed until a test explicitly permits the countdown.
@MainActor
final class Item175RecoveryMarkerTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let lastAttemptKey = "com.malinois.recovery.lastAt"
    // The MainActor tests and XCTest's synchronous main-thread tearDown are the only accesses.
    // The local snapshot passed into assumeIsolated is an array of MainActor (Sendable) stores, never self.
    nonisolated(unsafe) private var storesForTeardown: [EventStore] = []
    // Only the synchronous test and its main-thread tearDown access these scratch directory names.
    nonisolated(unsafe) private var snapshotFolders: [URL] = []

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let pro: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem175Recovery")
    }

    override func tearDown() {
        let stores = storesForTeardown
        MainActor.assumeIsolated {
            TestIsolation.letQueuedWorkLand()
            TestIsolation.disarmTrackedEngines()
            stores.forEach { $0.drainIOForTesting() }
        }
        storesForTeardown.removeAll()
        TestIsolation.tearDown()
        for folder in snapshotFolders { try? FileManager.default.removeItem(at: folder) }
        snapshotFolders.removeAll()
        super.tearDown()
    }

    private func launch(settings: AppSettings? = nil, store: EventStore? = nil) -> Rig {
        let settings = settings ?? AppSettings()
        settings.gracePeriodSeconds = 60
        let store = store ?? EventStore()
        storesForTeardown.append(store)
        let pro = ProEntitlements.unresolvedForTesting()
        let cloud = CloudExfiltrator()
        cloud.accountIdentityForTesting = { nil }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: pro,
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          protectedDataAvailable: { false }))
        return Rig(engine: engine, store: store, pro: pro)
    }

    func testArmedMarkerRetiresAfterTheInterruptionAndOwedReArm() {
        defaults.set(0.5, forKey: MonitoringEngine.armedMarkerKey)
        let rig = launch()
        var sawRetirement = false
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            guard key == MonitoringEngine.armedMarkerKey else { return }
            sawRetirement = true
            XCTAssertNil(self.defaults.object(forKey: key))
            XCTAssertTrue(rig.store.events.contains { $0.interrupted == true })
            XCTAssertTrue(self.defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(sawRetirement)
        XCTAssertEqual(rig.engine.state, .disarmed, "The unresolved Pro check keeps recovery owed.")
    }

    func testInterruptedRecoveryRetiresAfterItsInterruptionAndOwedReArm() {
        defaults.set(true, forKey: MonitoringEngine.recoveryInProgressKey)
        defaults.set(true, forKey: MonitoringEngine.armingInProgressKey)
        let rig = launch()
        var retired: Set<String> = []
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            guard [MonitoringEngine.recoveryInProgressKey, MonitoringEngine.armingInProgressKey].contains(key) else { return }
            retired.insert(key)
            XCTAssertTrue(rig.store.events.contains { $0.interrupted == true })
            XCTAssertTrue(self.defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(retired, [MonitoringEngine.recoveryInProgressKey, MonitoringEngine.armingInProgressKey])
        XCTAssertEqual(rig.store.events.filter { $0.interrupted == true }.count, 1)
        XCTAssertFalse(rig.store.events.contains { $0.stateChange == "armingInterrupted" }, "Recovery owns this countdown.")
    }

    func testOwedReArmRetiresOnlyAfterRecoveryProgressExists() {
        defaults.set(true, forKey: MonitoringEngine.pendingReArmKey)
        let rig = launch()
        var sawRetirement = false
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            guard key == MonitoringEngine.pendingReArmKey else { return }
            sawRetirement = true
            XCTAssertTrue(self.defaults.bool(forKey: MonitoringEngine.recoveryInProgressKey))
        }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.pro.resolveForTesting(as: .free)
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(sawRetirement)
        XCTAssertEqual(rig.engine.state, .arming)
    }

    func testCrashLoopRetiresTheOwedAttemptOnlyAfterItsSkipRecord() {
        defaults.set(true, forKey: MonitoringEngine.pendingReArmKey)
        defaults.set(Date().timeIntervalSince1970 - 10, forKey: lastAttemptKey)
        let rig = launch()
        var sawRetirement = false
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            guard key == MonitoringEngine.pendingReArmKey else { return }
            sawRetirement = true
            XCTAssertTrue(rig.engine.reArmSkipped)
            XCTAssertTrue(rig.store.events.contains { $0.stateChange == "reArmSkipped" })
        }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.pro.resolveForTesting(as: .free)
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(sawRetirement)
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertFalse(defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(rig.store.events.filter { $0.stateChange == "reArmSkipped" }.count, 1, "A declined attempt is consumed once.")
    }

    func testOrdinaryCountdownRetiresOnlyAfterItsInterruptionRecord() {
        defaults.set(true, forKey: MonitoringEngine.armingInProgressKey)
        let rig = launch()
        var sawRetirement = false
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            guard key == MonitoringEngine.armingInProgressKey else { return }
            sawRetirement = true
            XCTAssertTrue(rig.store.events.contains { $0.stateChange == "armingInterrupted" })
        }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(sawRetirement)
        XCTAssertFalse(defaults.bool(forKey: MonitoringEngine.pendingReArmKey), "An aborted ordinary countdown never auto re-arms.")
    }

    func testEntitlementDeferralKeepsReArmOwed() {
        defaults.set(true, forKey: MonitoringEngine.pendingReArmKey)
        let rig = launch()
        var retired: [String] = []
        rig.engine.recoveryMarkerRetiredForTesting = { retired.append($0) }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        XCTAssertFalse(retired.contains(MonitoringEngine.pendingReArmKey))
        XCTAssertEqual(rig.engine.state, .disarmed)
    }

    func testPINRecoveryDeferralKeepsReArmOwed() {
        defaults.set(true, forKey: MonitoringEngine.pendingReArmKey)
        let rig = launch()
        MonitoringEngine.recoveryPendingForTesting = true
        rig.pro.resolveForTesting(as: .free)
        var retired: [String] = []
        rig.engine.recoveryMarkerRetiredForTesting = { retired.append($0) }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        XCTAssertFalse(retired.contains(MonitoringEngine.pendingReArmKey))
        XCTAssertEqual(rig.engine.state, .disarmed)
    }

    func testLockedSettingsDeferralKeepsReArmOwed() throws {
        let folder = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canary = folder.appendingPathComponent("settings-canary")
        try Data([1]).write(to: canary)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: canary.path)
        let previous = AppSettings.canaryURLOverrideForTesting
        AppSettings.canaryURLOverrideForTesting = canary
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: canary.path)
            AppSettings.canaryURLOverrideForTesting = previous
        }
        let settings = AppSettings.load()
        settings.useProtectedDataAnswerForTesting { false }
        XCTAssertTrue(settings.awaitingUnlock)
        defaults.set(true, forKey: MonitoringEngine.pendingReArmKey)
        let rig = launch(settings: settings)
        rig.pro.resolveForTesting(as: .free)
        var retired: [String] = []
        rig.engine.recoveryMarkerRetiredForTesting = { retired.append($0) }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.handleScenePhase(true)
        XCTAssertTrue(defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        XCTAssertFalse(retired.contains(MonitoringEngine.pendingReArmKey))
        XCTAssertEqual(rig.engine.state, .disarmed)
    }

    func testAlreadyLoggedLapseIsNotDuplicatedDuringMarkerHandoff() {
        let store = EventStore()
        let lapse = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], interrupted: true)
        store.add(lapse)
        defaults.set(0.5, forKey: MonitoringEngine.armedMarkerKey)
        defaults.set(true, forKey: MonitoringEngine.backgroundLapseLoggedKey)
        let rig = launch(store: store)
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(store.events.filter { $0.interrupted == true }.map(\.id), [lapse.id])
        XCTAssertTrue(defaults.bool(forKey: MonitoringEngine.pendingReArmKey))
        XCTAssertNil(defaults.object(forKey: MonitoringEngine.armedMarkerKey))
    }

    func testFreshLaunchFromArmedRetirementSnapshotStillHasItsRecordAndOwedReArm() throws {
        defaults.set(0.5, forKey: MonitoringEngine.armedMarkerKey)
        let sourceRoot = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let snapshotRoot = sourceRoot.deletingLastPathComponent().appendingPathComponent("RecoverySnapshot-" + UUID().uuidString)
        snapshotFolders.append(snapshotRoot)
        let rig = launch()
        var markerSnapshot: [String: Any]?
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            guard key == MonitoringEngine.armedMarkerKey else { return }
            rig.store.drainIOForTesting()
            markerSnapshot = self.defaults.dictionaryRepresentation().filter { entry in
                TestIsolation.recoveryFlagPrefixes.contains { entry.key.hasPrefix($0) }
            }
            do { try FileManager.default.copyItem(at: sourceRoot, to: snapshotRoot) }
            catch { XCTFail("Could not take the real recovery boundary snapshot: \(error)") }
        }
        rig.engine.handleScenePhase(true)
        rig.engine.recoveryMarkerRetiredForTesting = nil
        let markers = try XCTUnwrap(markerSnapshot)
        TestIsolation.clearRecoveryFlags()
        for (key, value) in markers { defaults.set(value, forKey: key) }
        EventStore.rootOverrideForTesting = snapshotRoot
        defer { EventStore.rootOverrideForTesting = sourceRoot }
        let relaunched = launch()
        relaunched.engine.handleScenePhase(true)
        XCTAssertEqual(relaunched.store.events.filter { $0.interrupted == true }.count, 1)
        XCTAssertTrue(defaults.bool(forKey: MonitoringEngine.pendingReArmKey), "A kill at retirement cannot lose the owed recovery.")
        relaunched.pro.resolveForTesting(as: .free)
        relaunched.engine.handleScenePhase(true)
        XCTAssertEqual(relaunched.engine.state, .arming)
    }

    func testGoingLiveInstallsArmedBeforeRetiringRecoveryProgress() {
        let rig = launch()
        defaults.set(true, forKey: MonitoringEngine.recoveryInProgressKey)
        defaults.set(true, forKey: MonitoringEngine.armingInProgressKey)
        var retired: Set<String> = []
        rig.engine.recoveryMarkerRetiredForTesting = { key in
            retired.insert(key)
            XCTAssertNotNil(self.defaults.object(forKey: MonitoringEngine.armedMarkerKey))
        }
        defer { rig.engine.recoveryMarkerRetiredForTesting = nil }
        rig.engine.markWatchLive()
        XCTAssertEqual(retired, [MonitoringEngine.recoveryInProgressKey, MonitoringEngine.armingInProgressKey])
    }
}
