import CloudKit
import Combine
import XCTest
@testable import Malinois

@MainActor
final class MonitoringCloudCoordinatorTests: XCTestCase {
    @MainActor private final class Gate {
        var entered = false
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    @MainActor private final class Observations {
        var lookups = 0
        var saves = 0
        var uploads = 0
        var healthUpdates = 0
        var trace: [String] = []
        var notices: [String?] = []
        var noticeGetterAtEmission: [String?] = []
        var progressGetterAtEmission: [Bool?] = []
        var componentProgressAtEmission: [Bool] = []
    }

    @MainActor private final class WeakEngine {
        weak var value: MonitoringEngine?
    }

    @MainActor private final class Host: MonitoringCloudHost {
        var cloudHostState: MonitoringState = .disarmed
        var cloudHostAllowsUpload = true
        var cloudHostArmedPro = true
        var cloudHostArmedSince: Date?
        var cloudHostHadConnectivityAtArm = true
        var cloudHostIsCharging = true
        var cloudHostLiveFloodAnchorID: UUID?
        var mergedCount: Int?
        var escalations = 0
        var notificationRefreshes = 0
        var backupRecords: [String] = []
        var reinstallWrites = 0
        func cloudEventCountDidChange(to count: Int) { mergedCount = count }
        func cloudUploadInterferenceDetected() { escalations += 1 }
        func cloudRefreshNotificationHealth() async { notificationRefreshes += 1 }
        func cloudRecordBackupChange(_ kind: String) { backupRecords.append(kind) }
        func cloudWriteOwedReinstallRecord() { reinstallWrites += 1 }
    }

    @MainActor private final class EngineRig {
        // Only this optional retains the engine. The coordinator is deliberately retained
        // separately so a missing finite-work token exposes its weak-host lifetime bug.
        var engine: MonitoringEngine?
        let weakEngine: WeakEngine
        let coordinator: MonitoringCloudCoordinator
        let cloud: CloudExfiltrator
        let store: EventStore
        init(_ engine: MonitoringEngine) {
            self.engine = engine
            weakEngine = WeakEngine()
            weakEngine.value = engine
            coordinator = engine.cloudCoordinator
            cloud = engine.cloud
            store = engine.eventStore
        }
    }

    private struct ComponentRig {
        let coordinator: MonitoringCloudCoordinator
        let host: Host
        let store: EventStore
    }

    // XCTest calls synchronous setup/teardown on the main thread. All mutations below
    // happen in MainActor test methods or MainActor.assumeIsolated in teardown.
    nonisolated(unsafe) private var engines: [EngineRig] = []
    nonisolated(unsafe) private var stores: [EventStore] = []
    nonisolated(unsafe) private var gates: [Gate] = []

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisCloudCoordinator")
    }

    override func tearDown() {
        // Copy Sendable actor-bound objects before entering assumeIsolated, avoiding
        // capture of XCTest's nonisolated self. Async tests drain their finite work first.
        let heldEngines = engines
        let heldStores = stores
        let heldGates = gates
        MainActor.assumeIsolated {
            for gate in heldGates { gate.open() }
            for rig in heldEngines { rig.engine?.disarm(); rig.engine = nil }
            for store in heldStores { store.drainIOForTesting() }
        }
        engines = []
        stores = []
        gates = []
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static var timing: EngineTiming {
        var value = EngineCharacterizationTests.fastTiming
        value.sweepWaitFloor = 0.05
        value.sweepWaitCeiling = 0.05
        return value
    }

    private func gate() -> Gate {
        let value = Gate()
        gates.append(value)
        return value
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func store(named name: String) throws -> (EventStore, URL) {
        let previous = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let root = previous.appendingPathComponent(name, isDirectory: true)
        EventStore.rootOverrideForTesting = root
        defer { EventStore.rootOverrideForTesting = previous }
        let value = EventStore()
        stores.append(value)
        return (value, root)
    }

    private func component(named name: String) throws -> ComponentRig {
        let (store, root) = try store(named: name)
        let settings = AppSettings()
        settings.cloudBackup = true
        let cloud = CloudExfiltrator(enrollment: CloudEnrollment(file: root.appendingPathComponent("binding.json"),
                                                               authenticate: { _ in false }))
        cloud.accountIdentityForTesting = { nil }
        let connectivity = ConnectivityMonitor()
        connectivity.simulateForTesting(online: true)
        let coordinator = MonitoringCloudCoordinator(settings: settings, eventStore: store, cloud: cloud,
            entitlements: ProEntitlements(resolvedAs: .trial), timing: Self.timing, connectivity: connectivity,
            thermalState: { .nominal })
        let host = Host()
        coordinator.host = host
        coordinator.watchBackupSetting()
        coordinator.handTheUploaderTheLog()
        return ComponentRig(coordinator: coordinator, host: host, store: store)
    }

    private func engine(named name: String) async throws -> EngineRig {
        let (store, root) = try store(named: name)
        let policy = CloudEnrollment(file: root.appendingPathComponent("binding.json"), authenticate: { _ in true })
        let enrolled = await policy.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: policy)
        let observations = Observations()
        cloud.accountIdentityForTesting = { observations.lookups += 1; return nil }
        let settings = AppSettings()
        settings.cloudBackup = true
        settings.requireGuidedAccess = false
        // Deliberately NOT TestIsolation.track: that static array retains engines strongly.
        let value = MonitoringEngine(settings: settings, eventStore: store, cloud: cloud, camera: FakeCamera(),
            entitlements: ProEntitlements(resolvedAs: .trial), timing: Self.timing,
            protectedDataAvailable: { true }, thermalState: { .nominal })
        value.simulateConnectivityForTesting(online: true)
        let rig = EngineRig(value)
        engines.append(rig)
        let health = value.$notificationAskDue.dropFirst().sink { _ in observations.healthUpdates += 1 }
        let settled = await until {
            observations.lookups >= 2 && observations.healthUpdates >= 1
                && rig.engine?.pendingSweepActive == false && rig.engine?.cloudRestoreInProgress == false
        }
        XCTAssertTrue(settled, "the normal launch sweep, restore and notification-health task completed")
        // notificationAskDue is the final assignment after that task's only suspension.
        // Observe the real launch task, rather than start a second refresh or guess a delay.
        health.cancel()
        cloud.accountIdentityForTesting = { "account-a" }
        value.disarm() // already disarmed; keep every lifetime scenario timer-free
        return rig
    }

    private func evidence(in store: EventStore, id: UUID = UUID()) -> Event {
        let at = Date().addingTimeInterval(-60)
        let event = Event(id: id, startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .pending)
        store.add(event)
        return event
    }

    private func finish(_ rig: EngineRig) async {
        for gate in gates { gate.open() }
        rig.engine?.disarm()
        let ended = await until {
            let owner = rig.weakEngine.value
            return !(owner?.pendingSweepActive ?? rig.coordinator.pendingSweepActive)
                && (owner?.bindingsInUse.isEmpty ?? rig.coordinator.bindingsInUse.isEmpty)
        }
        XCTAssertTrue(ended, "the test's finite work drained before teardown")
        rig.coordinator.evidencePushForTesting = nil
        rig.coordinator.sweepUploadForTesting = nil
        rig.coordinator.cloudFetchForTesting = nil
        rig.cloud.saveAttemptForTesting = nil
        rig.engine = nil
        rig.store.drainIOForTesting()
    }

    func testTwoComponentsOwnSeparateSweepBindingAndStoreState() async throws {
        let first = try component(named: "first")
        let second = try component(named: "second")
        let sharedID = UUID()
        _ = evidence(in: first.store, id: sharedID)
        _ = evidence(in: second.store, id: sharedID)
        let held = gate()
        let firstTrace = Observations()
        let secondTrace = Observations()
        first.coordinator.onPendingSweepActiveChange = { firstTrace.trace.append("active:\($0)") }
        second.coordinator.onPendingSweepActiveChange = { secondTrace.trace.append("active:\($0)") }
        first.coordinator.sweepUploadForTesting = { _ in await held.wait(); return (.synced, nil) }
        second.coordinator.sweepUploadForTesting = { _ in (.synced, nil) }
        first.coordinator.beginBindingUse(sharedID)
        first.coordinator.beginBindingUse(sharedID)
        second.coordinator.beginBindingUse(sharedID)
        let running = Task { await first.coordinator.retryPendingSync() }
        let entered = await until { held.entered }
        XCTAssertTrue(entered)
        XCTAssertTrue(first.coordinator.pendingSweepActive)
        XCTAssertFalse(second.coordinator.pendingSweepActive)
        await second.coordinator.retryPendingSync()
        XCTAssertEqual(second.store.events.first?.cloudSyncState, .synced)
        XCTAssertEqual(first.store.events.first?.cloudSyncState, .pending)
        first.coordinator.captureEvidenceStoredLate()
        XCTAssertTrue(first.coordinator.sweepRerunOwed)
        XCTAssertFalse(second.coordinator.sweepRerunOwed)
        first.coordinator.endBindingUse(sharedID)
        second.coordinator.endBindingUse(sharedID)
        XCTAssertEqual(first.coordinator.bindingsInUse[sharedID], 1)
        XCTAssertNil(second.coordinator.bindingsInUse[sharedID])
        held.open()
        await running.value
        let rerunEnded = await until { firstTrace.trace.count == 4 && !first.coordinator.pendingSweepActive }
        XCTAssertTrue(rerunEnded)
        XCTAssertEqual(firstTrace.trace, ["active:true", "active:false", "active:true", "active:false"])
        XCTAssertEqual(secondTrace.trace, ["active:true", "active:false"])
        XCTAssertEqual(first.store.events.first?.cloudSyncState, .synced)
        first.coordinator.endBindingUse(sharedID)
        let at = Date()
        let mirror = Event(startDate: at, endDate: at, triggeredSensors: [.motion],
                           cloudSyncState: .synced, sourceDevice: "Another phone", cloudRevision: 2)
        second.coordinator.cloudFetchForTesting = { _ in ([mirror], true) }
        let added = await second.coordinator.syncFromCloud()
        XCTAssertEqual(added, 1)
        XCTAssertEqual(second.host.mergedCount, second.store.events.count)
        XCTAssertNil(first.host.mergedCount)
        XCTAssertFalse(first.store.events.contains { $0.id == mirror.id })
        first.store.drainIOForTesting()
        second.store.drainIOForTesting()
    }

    func testNoticeFacadePublishesSynchronouslyIncludingEqualAssignments() async throws {
        let rig = try await engine(named: "notice")
        let observations = Observations()
        let probe = rig.weakEngine
        let subscription = try XCTUnwrap(rig.engine).$cloudResetNotice.dropFirst().sink { notice in
            observations.notices.append(notice)
            observations.noticeGetterAtEmission.append(probe.value?.cloudResetNotice)
        }
        rig.engine?.cloudReuploadCount = 3
        rig.engine?.refreshCloudReuploadNotice()
        let expected = MonitoringEngine.cloudReuploadNotice(requeued: 3, backupOn: true)
        // No await/run-loop turn: a scheduled mirror cannot satisfy these assertions.
        XCTAssertEqual(rig.coordinator.cloudReuploadCount, 3)
        XCTAssertEqual(rig.engine?.cloudResetNotice, expected)
        XCTAssertEqual(observations.notices, [expected])
        XCTAssertEqual(observations.noticeGetterAtEmission, [nil], "projected publisher retains will-set semantics")
        rig.engine?.refreshCloudReuploadNotice()
        XCTAssertEqual(observations.notices, [expected, expected], "the bridge must not deduplicate assignments")
        XCTAssertEqual(observations.noticeGetterAtEmission, [nil, expected])
        subscription.cancel()
        await finish(rig)
    }

    func testLaunchAndSweepKeepTheirExistingPublisherOrder() async throws {
        let rig = try await engine(named: "publication")
        let owner = try XCTUnwrap(rig.engine)
        let coordinator = rig.coordinator
        let observations = Observations()
        let probe = rig.weakEngine
        let subscriptions = [
            owner.$currentLaunchPull.dropFirst().sink { _ in observations.trace.append("kind") },
            owner.$cloudRestoreInProgress.dropFirst().sink { active in
                observations.trace.append("restore:\(active)")
                observations.progressGetterAtEmission.append(probe.value?.cloudRestoreInProgress)
                observations.componentProgressAtEmission.append(coordinator.cloudRestoreInProgress)
            },
            owner.$pendingSweepActive.dropFirst().sink { observations.trace.append("active:\($0)") },
            owner.$pendingSweepWaiting.dropFirst().sink { observations.trace.append("waiting:\($0)") }
        ]
        owner.cloudFetchForTesting = { _ in
            XCTAssertEqual(observations.trace, ["kind", "restore:true"])
            return ([], true)
        }
        await owner.restoreFromCloudAtLaunch()
        XCTAssertEqual(observations.trace, ["kind", "restore:true", "restore:false"])
        XCTAssertEqual(observations.progressGetterAtEmission, [false, true])
        XCTAssertEqual(observations.componentProgressAtEmission, [false, true],
                       "synchronous subscriber reentry sees the original pre-assignment cloud state")
        observations.trace = []
        _ = evidence(in: rig.store)
        owner.sweepUploadForTesting = { _ in
            observations.uploads += 1
            return observations.uploads == 1
                ? (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: 0.05)) : (.synced, nil)
        }
        await owner.retryPendingSync()
        XCTAssertEqual(observations.trace, ["active:true", "waiting:true"])
        XCTAssertTrue(owner.pendingSweepWaiting)
        let ended = await until { !rig.coordinator.pendingSweepActive }
        XCTAssertTrue(ended)
        XCTAssertEqual(observations.trace, ["active:true", "waiting:true", "waiting:false", "active:false"])
        for subscription in subscriptions { subscription.cancel() }
        await finish(rig)
    }

    func testQueuedBackgroundUploadKeepsItsOwnerUntilStoreAndBindingComplete() async throws {
        let rig = try await engine(named: "queued")
        let event = evidence(in: rig.store)
        rig.cloud.enrollment.registerLocalEvent(event)
        let held = gate()
        let cloud = rig.cloud
        let blocker = Task { await cloud.enqueue(event.id) { await held.wait(); return true } }
        let entered = await until { held.entered }
        XCTAssertTrue(entered)
        let observations = Observations()
        cloud.saveAttemptForTesting = { _ in observations.saves += 1 }
        rig.engine?.exfiltrateInBackground(event)
        XCTAssertEqual(rig.coordinator.bindingsInUse[event.id], 1, "the pin precedes task scheduling")
        rig.engine = nil
        // No actor yield: taking ownership inside the later task is already too late.
        XCTAssertNotNil(rig.weakEngine.value, "the original owner survives before the task's first turn")
        let uploadEntered = await until { rig.store.uploadsUnderWay.contains(event.id) }
        XCTAssertTrue(uploadEntered)
        XCTAssertNotNil(rig.weakEngine.value, "the queued operation still owns its engine")
        XCTAssertEqual(observations.saves, 0, "the real event queue is still blocked")
        XCTAssertEqual(rig.coordinator.bindingsInUse[event.id], 1)
        held.open()
        _ = await blocker.value
        let completed = await until {
            rig.store.events.first { $0.id == event.id }?.cloudSyncState == .synced
                && rig.coordinator.bindingsInUse[event.id] == nil && !rig.store.uploadsUnderWay.contains(event.id)
        }
        XCTAssertTrue(completed)
        XCTAssertGreaterThan(observations.saves, 0)
        let released = await until { rig.weakEngine.value == nil }
        XCTAssertTrue(released, "the finished upload does not make a permanent engine/coordinator cycle")
        await finish(rig)
    }

    func testAwaitedFacadeKeepsItsOwnerThroughTheUploadCompletion() async throws {
        let rig = try await engine(named: "awaited")
        let event = evidence(in: rig.store)
        let held = gate()
        rig.coordinator.evidencePushForTesting = { _ in
            await held.wait()
            return CloudExfiltrator.ExfilOutcome(syncState: .synced, metaFailureWasInterference: nil)
        }
        let probe = rig.weakEngine
        let running = Task { await probe.value?.exfiltrate(event) }
        let entered = await until { held.entered }
        XCTAssertTrue(entered)
        rig.engine = nil
        XCTAssertNotNil(probe.value)
        XCTAssertTrue(rig.store.uploadsUnderWay.contains(event.id))
        held.open()
        let landed = await running.value
        XCTAssertEqual(landed, true)
        XCTAssertEqual(rig.store.events.first { $0.id == event.id }?.cloudSyncState, .synced)
        XCTAssertFalse(rig.store.uploadsUnderWay.contains(event.id))
        let released = await until { probe.value == nil }
        XCTAssertTrue(released)
        await finish(rig)
    }

    func testDelayedSweepAndItsOwedRerunOutliveTheOriginalCaller() async throws {
        let rig = try await engine(named: "continuation")
        let initial = evidence(in: rig.store)
        let at = Date()
        let late = Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .pending)
        let held = gate()
        let rerunHeld = gate()
        let observations = Observations()
        let store = rig.store
        let coordinator = rig.coordinator
        coordinator.sweepUploadForTesting = { [weak coordinator] event in
            observations.uploads += 1
            if observations.uploads == 1 { return (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: 0.05)) }
            if event.id == initial.id {
                store.add(late) // the current pass already chose its rows
                coordinator?.captureEvidenceStoredLate()
                await held.wait()
            } else if event.id == late.id {
                await rerunHeld.wait()
            }
            return (.synced, nil)
        }
        await rig.engine?.retryPendingSync()
        XCTAssertTrue(coordinator.pendingSweepWaiting)
        rig.engine = nil
        XCTAssertNotNil(rig.weakEngine.value, "the continuation owns the engine after the first caller returned")
        let entered = await until { held.entered }
        XCTAssertTrue(entered)
        XCTAssertTrue(coordinator.sweepRerunOwed)
        XCTAssertNotNil(rig.weakEngine.value)
        held.open()
        let rerunEntered = await until { rerunHeld.entered }
        XCTAssertTrue(rerunEntered, "the separately owed sweep reached the late event")
        XCTAssertNotNil(rig.weakEngine.value, "the owed rerun retains its owner through its own upload")
        rerunHeld.open()
        let completed = await until {
            observations.uploads == 3 && !coordinator.pendingSweepActive && !coordinator.sweepRerunOwed
                && store.events.filter { $0.id == initial.id || $0.id == late.id }.allSatisfy { $0.cloudSyncState == .synced }
        }
        XCTAssertTrue(completed, "the late evidence gets its separately owed sweep")
        let released = await until { rig.weakEngine.value == nil }
        XCTAssertTrue(released)
        await finish(rig)
    }

    func testPersistentCloudHooksDoNotKeepAnIdleOwnerAlive() async throws {
        let rig = try await engine(named: "weak-hooks")
        // The rig keeps the coordinator, cloud, store and their installed callbacks alive.
        rig.engine = nil
        let released = await until { rig.weakEngine.value == nil }
        XCTAssertTrue(released)
        XCTAssertNil(rig.coordinator.host)
        await finish(rig)
    }

    func testUploadFailureReadsCurrentWatchFactsAfterSuspension() async throws {
        let rig = try component(named: "fresh-watch")
        rig.coordinator.settings.jammingResponse = true
        rig.host.cloudHostState = .armed
        let event = evidence(in: rig.store)
        let held = gate()
        rig.coordinator.evidencePushForTesting = { _ in
            await held.wait()
            return CloudExfiltrator.ExfilOutcome(syncState: .localOnly, metaFailureWasInterference: true)
        }
        let upload = Task { await rig.coordinator.exfiltrate(event) }
        let entered = await until { held.entered }
        XCTAssertTrue(entered)
        rig.host.cloudHostState = .disarmed
        held.open()
        _ = await upload.value
        XCTAssertEqual(rig.host.escalations, 0, "a cached armed state must not sound after disarm")
        rig.host.cloudHostState = .armed
        let secondHold = gate()
        rig.coordinator.evidencePushForTesting = { _ in
            await secondHold.wait()
            return CloudExfiltrator.ExfilOutcome(syncState: .localOnly, metaFailureWasInterference: true)
        }
        let secondUpload = Task { await rig.coordinator.exfiltrate(event) }
        let secondEntered = await until { secondHold.entered }
        XCTAssertTrue(secondEntered)
        rig.host.cloudHostHadConnectivityAtArm = false
        secondHold.open()
        _ = await secondUpload.value
        XCTAssertEqual(rig.host.escalations, 0, "the post-await watch has no previously observed connection")
        rig.host.cloudHostHadConnectivityAtArm = true
        _ = await rig.coordinator.exfiltrate(event)
        XCTAssertEqual(rig.host.escalations, 1, "the current armed watch still receives its normal interference response")
        rig.store.drainIOForTesting()
    }
}
