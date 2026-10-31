import CloudKit
import Combine
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class MonitoringTripResponderTests: XCTestCase {
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
        var health = 0
        var setupBegan = 0
        var setupFinished = 0
        var beats = 0
        var saves = 0
        var uploaded: [Event] = []
        var richGate: Gate?
        var richID: UUID?
        var trace: [String] = []
        var triggerGetters: [MonitoringState?] = []
        var handlingAtTrigger: [Bool] = []
        var handlingAtRearm: [Bool] = []
        var countGetters: [Int?] = []
        var publishedCounts: [Int] = []
        var factPresentAtCount: [Bool] = []
        var bindingPresentAtCount: [Bool] = []
        var mediaAbsentAtCount: [Bool] = []
    }

    @MainActor private final class WeakEngine {
        weak var value: MonitoringEngine?
    }

    @MainActor private final class Rig {
        // No TestIsolation.track: only this optional owns the engine. Separately retaining
        // the collaborators exposes weak-host loss and permanent host/callback cycles.
        var engine: MonitoringEngine?
        let weakEngine = WeakEngine()
        let responder: MonitoringTripResponder
        let pipeline: EvidenceCapturePipeline
        let coordinator: MonitoringCloudCoordinator
        let camera: FakeCamera
        let cloud: CloudExfiltrator
        let store: EventStore
        let observations: Observations
        var subscriptions: [AnyCancellable] = []

        init(_ engine: MonitoringEngine, camera: FakeCamera, observations: Observations) {
            self.engine = engine
            weakEngine.value = engine
            responder = engine.tripResponder
            pipeline = engine.capturePipeline
            coordinator = engine.cloudCoordinator
            cloud = engine.cloud
            store = engine.eventStore
            self.camera = camera
            self.observations = observations
        }
    }

    // XCTest calls synchronous setup/teardown on the main thread. MainActor tests own
    // these collections; teardown copies actor-bound values before assumeIsolated.
    nonisolated(unsafe) private var rigs: [Rig] = []
    nonisolated(unsafe) private var gates: [Gate] = []
    nonisolated(unsafe) private var workers: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisTripResponder")
    }

    override func tearDown() {
        let heldRigs = rigs
        let heldGates = gates
        MainActor.assumeIsolated {
            for gate in heldGates { gate.open() }
            for rig in heldRigs {
                rig.camera.releaseStills()
                rig.weakEngine.value?.disarm()
                rig.engine = nil
                rig.store.drainIOForTesting()
            }
        }
        rigs = []
        gates = []
        workers = []
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static var timing: EngineTiming {
        var value = EngineCharacterizationTests.fastTiming
        value.sustainedIdleClear = 30
        value.floodCaptureInterval = 30
        value.sweepWaitFloor = 0.05
        value.sweepWaitCeiling = 0.05
        return value
    }

    private func gate() -> Gate {
        let value = Gate()
        gates.append(value)
        return value
    }

    private func until(_ condition: () -> Bool, timeout: Duration = .seconds(4)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func require(_ condition: () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let reached = await until(condition)
        XCTAssertTrue(reached, message, file: file, line: line)
        if !reached { throw FixtureFailure.unreached }
    }

    private enum FixtureFailure: Error { case unreached }

    private func makeRig(named name: String) async throws -> Rig {
        let previous = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let root = previous.appendingPathComponent(name, isDirectory: true)
        EventStore.rootOverrideForTesting = root
        let store = EventStore()
        EventStore.rootOverrideForTesting = previous
        let policy = CloudEnrollment(file: root.appendingPathComponent("binding.json"), authenticate: { _ in true })
        let enrolled = await policy.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: policy)
        let observations = Observations()
        cloud.accountIdentityForTesting = { observations.lookups += 1; return nil }
        cloud.automaticSetupBeganForTesting = { observations.setupBegan += 1 }
        cloud.automaticSetupFinishedForTesting = { observations.setupFinished += 1 }
        cloud.saveAttemptForTesting = { records in
            observations.saves += 1
            for record in records where record.recordType == CloudExfiltrator.metaRecordTypeV2 {
                guard let event = CloudExfiltrator.event(from: record) else {
                    XCTFail("a real incident metadata save must decode")
                    continue
                }
                observations.uploaded.append(event)
                // Only completed-capture metadata waits. The earlier sparse fact and
                // status saves finish through the same real per-event uploader queue.
                if event.primaryCamera != nil,
                   observations.richID == nil || observations.richID == event.id {
                    await observations.richGate?.wait()
                }
            }
        }
        let settings = AppSettings()
        settings.enabledSensors = [.touch, .camera]
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .stealth
        settings.captureMode = .photo
        settings.cameraPosition = .front
        settings.cameraReadiness = .batterySaver
        settings.illumination = .off
        settings.jammingResponse = false
        settings.notifyOtherDevices = false
        settings.cloudBackup = true
        let camera = FakeCamera()
        camera.stillData = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            .jpegData(withCompressionQuality: 0.8) { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: cloud, camera: camera,
            entitlements: ProEntitlements(resolvedAs: .trial), timing: Self.timing,
            protectedDataAvailable: { true }, thermalState: { .nominal })
        let rig = Rig(engine, camera: camera, observations: observations)
        rigs.append(rig)
        rig.subscriptions.append(engine.$notificationAskDue.dropFirst().sink { _ in observations.health += 1 })
        engine.simulateConnectivityForTesting(online: true)
        try await require({
            observations.lookups >= 2 && observations.health >= 1
                && !rig.coordinator.pendingSweepActive && !rig.coordinator.cloudRestoreInProgress
                && observations.setupBegan == observations.setupFinished
        }, "launch restore, sweep, notification health and setup finished")
        cloud.accountIdentityForTesting = { "account-a" }
        rig.coordinator.beatSendForTesting = { _ in observations.beats += 1; return true }
        return rig
    }

    private func arm(_ rig: Rig) async throws {
        let healthBefore = rig.observations.health
        let setupBefore = rig.observations.setupFinished
        rig.engine?.beginArming()
        rig.engine?.confirmGuidedAccessAndStartGrace()
        try await require({
            rig.engine?.state == .armed && rig.observations.health > healthBefore
                && rig.observations.setupFinished > setupBefore
                && rig.observations.setupBegan == rig.observations.setupFinished
                && rig.observations.beats > 0 && rig.coordinator.bindingsInUse.isEmpty
                && rig.store.uploadsUnderWay.isEmpty && !rig.coordinator.pendingSweepActive
        }, "the real arm and its finite setup work finished")
        rig.engine?.stopHeartbeat()
        rig.subscriptions.forEach { $0.cancel() }
        rig.subscriptions.removeAll()
    }

    private func withRigs(_ names: [String], body: ([Rig]) async throws -> Void) async throws {
        do {
            var created: [Rig] = []
            for name in names { created.append(try await makeRig(named: name)) }
            // Construct every engine before either arm plants a process-wide recovery marker.
            for rig in created { try await arm(rig) }
            try await body(created)
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    private func finish() async {
        for gate in gates { gate.open() }
        for rig in rigs { rig.camera.releaseStills() }
        for worker in workers { await worker.value }
        for rig in rigs {
            rig.weakEngine.value?.disarm()
            let drained = await until({
                !rig.pipeline.isBusy && rig.coordinator.bindingsInUse.isEmpty
                    && rig.store.uploadsUnderWay.isEmpty && !rig.coordinator.pendingSweepActive
                    && !rig.coordinator.cloudRestoreInProgress
            }, timeout: .seconds(16))
            XCTAssertTrue(drained, "capture, queue, store and binding work drained before teardown")
            rig.subscriptions.forEach { $0.cancel() }
            rig.subscriptions.removeAll()
            rig.cloud.saveAttemptForTesting = nil
            rig.engine = nil
            rig.store.drainIOForTesting()
        }
    }

    private func incident(in rig: Rig) -> Event? { rig.store.events.first { !$0.isStateChange } }

    private func assertStoredFile(_ event: Event, in rig: Rig,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(rig.store.mediaURL(for: event), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), rig.camera.stillData, "the captured bytes reached the real store", file: file, line: line)
    }

    private func completed(_ id: UUID, in rig: Rig) -> Bool {
        rig.store.events.first { $0.id == id }?.cloudSyncState == .synced
            && rig.coordinator.bindingsInUse[id] == nil && !rig.store.uploadsUnderWay.contains(id)
            && !rig.pipeline.isBusy
    }

    private func failedCapture(in rig: Rig) async throws -> UUID {
        rig.camera.stillError = CameraController.CameraError.captureFailed
        rig.camera.interruptionReasonValue = .background
        rig.camera.onSessionEvent?(.interrupted(.background))
        rig.engine?.handleTrip(.touch)
        try await require({
            rig.engine?.state == .armed && self.incident(in: rig)?.captureFailure != nil
                && rig.coordinator.bindingsInUse.isEmpty && rig.store.uploadsUnderWay.isEmpty
                && !rig.pipeline.isBusy
        }, "the interrupted incident finished and parked its real retry")
        let event = try XCTUnwrap(incident(in: rig))
        XCTAssertNil(event.mediaFilename)
        XCTAssertEqual(event.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
        rig.camera.stillError = nil
        rig.camera.interruptionReasonValue = nil
        return event.id
    }

    func testTwoRespondersWithTheSameSessionKeepTripsAndPINsInTheirOwnStoredEvents() async throws {
        try await withRigs(["first", "second"]) { created in
            let first = created[0], second = created[1]
            XCTAssertEqual(first.engine?.armSession, second.engine?.armSession)
            first.camera.holdStills = true
            second.camera.holdStills = true
            first.responder.handleTrip(.touch)
            second.responder.handleTrip(.motion)
            try await self.require({ first.camera.stills.count == 1 && second.camera.stills.count == 1 },
                                   "both responders own their actual capture windows")
            first.responder.handleTrip(.power)
            first.responder.noteWrongDisarmPIN()
            first.responder.noteWrongDisarmPIN()
            second.responder.handleTrip(.audio)
            second.responder.noteWrongDisarmPIN()
            let firstID = try XCTUnwrap(self.incident(in: first)?.id)
            let secondID = try XCTUnwrap(self.incident(in: second)?.id)
            XCTAssertNotEqual(firstID, secondID)
            first.camera.releaseStills()
            try await self.require({ self.completed(firstID, in: first) }, "first capture and upload finished")
            let firstEvent = try XCTUnwrap(first.store.events.first { $0.id == firstID })
            XCTAssertEqual(Set(firstEvent.triggeredSensors), [.touch, .power])
            XCTAssertEqual(firstEvent.wrongPINCount, 2)
            XCTAssertNil(second.store.events.first { $0.id == secondID }?.mediaFilename)
            XCTAssertTrue(second.pipeline.isBusy, "releasing the first camera did not release the second")
            second.camera.releaseStills()
            try await self.require({ self.completed(secondID, in: second) }, "second capture and upload finished")
            let secondEvent = try XCTUnwrap(second.store.events.first { $0.id == secondID })
            XCTAssertEqual(Set(secondEvent.triggeredSensors), [.motion, .audio, .touch])
            XCTAssertEqual(secondEvent.wrongPINCount, 1)
            for (rig, event) in [(first, firstEvent), (second, secondEvent)] {
                try self.assertStoredFile(event, in: rig)
                let uploaded = try XCTUnwrap(rig.observations.uploaded.last { $0.id == event.id && $0.primaryCamera != nil })
                XCTAssertEqual(Set(uploaded.triggeredSensors), Set(event.triggeredSensors))
                XCTAssertEqual(uploaded.wrongPINCount, event.wrongPINCount)
                XCTAssertTrue(rig.responder.tripsDuringCapture.isEmpty)
                XCTAssertTrue(rig.responder.wrongPINsDuringCapture.isEmpty)
            }
            XCTAssertFalse(first.store.events.contains { $0.id == secondID })
            XCTAssertFalse(second.store.events.contains { $0.id == firstID })
        }
    }

    func testTriggerAndFactPublicationsObserveTheOriginalStateAndBindingOrder() async throws {
        try await withRigs(["publication"]) { created in
            let rig = created[0]
            let observations = rig.observations
            let probe = rig.weakEngine
            let responder = rig.responder
            let store = rig.store
            let coordinator = rig.coordinator
            let oldCount = try XCTUnwrap(rig.engine).eventCount
            rig.subscriptions = [
                try XCTUnwrap(rig.engine).$state.dropFirst().sink { state in
                    if state == .triggered {
                        observations.trace.append("triggered")
                        observations.triggerGetters.append(probe.value?.state)
                        observations.handlingAtTrigger.append(responder.isHandlingTrigger)
                    } else if state == .armed {
                        observations.trace.append("armed")
                        observations.handlingAtRearm.append(responder.isHandlingTrigger)
                    }
                },
                try XCTUnwrap(rig.engine).$lastTriggerDate.dropFirst().sink { _ in observations.trace.append("stamp") },
                try XCTUnwrap(rig.engine).$eventCount.dropFirst().sink { count in
                    guard let fact = store.events.first(where: { !$0.isStateChange }) else { return }
                    observations.trace.append("fact")
                    observations.countGetters.append(probe.value?.eventCount)
                    observations.publishedCounts.append(count)
                    observations.factPresentAtCount.append(store.events.contains { $0.id == fact.id })
                    observations.bindingPresentAtCount.append((coordinator.bindingsInUse[fact.id] ?? 0) > 0)
                    observations.mediaAbsentAtCount.append(fact.mediaFilename == nil)
                }
            ]
            rig.camera.holdStills = true
            rig.engine?.handleTrip(.touch)
            // Deliberately before any actor yield: root publication cannot be a later mirror.
            XCTAssertEqual(observations.trace, ["triggered", "stamp"])
            XCTAssertEqual(observations.triggerGetters, [.armed])
            XCTAssertEqual(observations.handlingAtTrigger, [true])
            try await self.require({ rig.camera.stills.count == 1 }, "the real fact precedes the held capture")
            XCTAssertEqual(observations.trace, ["triggered", "stamp", "fact"])
            XCTAssertEqual(observations.countGetters, [oldCount])
            XCTAssertEqual(observations.publishedCounts, [oldCount + 1])
            XCTAssertEqual(observations.factPresentAtCount, [true])
            XCTAssertEqual(observations.bindingPresentAtCount, [true])
            XCTAssertEqual(observations.mediaAbsentAtCount, [true])
            let id = try XCTUnwrap(self.incident(in: rig)?.id)
            rig.camera.releaseStills()
            try await self.require({ self.completed(id, in: rig) }, "the real response and upload finished")
            XCTAssertEqual(observations.handlingAtRearm, [false])
            XCTAssertEqual(observations.trace.last, "armed")
            try self.assertStoredFile(try XCTUnwrap(rig.store.events.first { $0.id == id }), in: rig)
        }
    }

    func testQueuedTripRetainsItsPipelineHostUntilStoredEvidenceAndCloudBindingFinish() async throws {
        try await withRigs(["queued-trip"]) { created in
            let rig = created[0]
            let held = self.gate()
            rig.observations.richGate = held
            rig.camera.holdStills = true
            rig.engine?.handleTrip(.touch)
            rig.engine = nil
            XCTAssertNotNil(rig.weakEngine.value, "the response owns root before its task's first turn")
            try await self.require({ rig.camera.stills.count == 1 }, "the real capture began")
            let id = try XCTUnwrap(self.incident(in: rig)?.id)
            XCTAssertNotNil(rig.pipeline.host)
            XCTAssertGreaterThan(rig.coordinator.bindingsInUse[id] ?? 0, 0)
            rig.camera.releaseStills()
            try await self.require({ held.entered }, "completed-capture metadata reached the actual save queue")
            let event = try XCTUnwrap(rig.store.events.first { $0.id == id })
            try self.assertStoredFile(event, in: rig)
            XCTAssertEqual(event.primaryCamera, CameraChoice.front.rawValue)
            XCTAssertTrue(rig.observations.uploaded.contains { $0.id == id && $0.primaryCamera == CameraChoice.front.rawValue })
            XCTAssertNotNil(rig.weakEngine.value, "cloud handoff keeps the original host alive")
            XCTAssertGreaterThan(rig.coordinator.bindingsInUse[id] ?? 0, 0)
            XCTAssertTrue(rig.store.uploadsUnderWay.contains(id))
            held.open()
            try await self.require({ self.completed(id, in: rig) }, "stored evidence completed the upload")
            try await self.require({ rig.weakEngine.value == nil }, "finished work has no permanent host cycle")
        }
    }

    func testARetryQueuedForAnOwnerThatDisappearsBeforeAdmissionDoesNotCapture() async throws {
        try await withRigs(["weak-retry"]) { created in
            let rig = created[0]
            let id = try await self.failedCapture(in: rig)
            let attempts = rig.camera.attemptBegins
            let saves = rig.observations.saves
            rig.camera.onSessionEvent?(.interruptionEnded)
            rig.engine = nil
            XCTAssertNil(rig.weakEngine.value, "a queued weak retry must not acquire root before admission")
            // Allow the queued opportunity and three real refractory intervals to execute.
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertNil(rig.weakEngine.value)
            XCTAssertNil(rig.pipeline.host)
            XCTAssertEqual(rig.camera.attemptBegins, attempts)
            XCTAssertEqual(rig.observations.saves, saves)
            XCTAssertNil(rig.store.events.first { $0.id == id }?.mediaFilename)
            XCTAssertEqual(rig.store.events.first { $0.id == id }?.captureFailure,
                           CaptureFailureReason.interruptedInBackground.rawValue)
            XCTAssertFalse(rig.pipeline.isBusy)
        }
    }

    func testAnAdmittedRetryRetainsItsHostThroughTheStoredFileAndUploadHandoff() async throws {
        try await withRigs(["admitted-retry"]) { created in
            let rig = created[0]
            let id = try await self.failedCapture(in: rig)
            let attempts = rig.camera.stills.count
            let held = self.gate()
            rig.observations.richGate = held
            rig.observations.richID = id
            rig.camera.holdStills = true
            rig.camera.onSessionEvent?(.interruptionEnded)
            try await self.require({ rig.camera.stills.count == attempts + 1 && rig.pipeline.isBusy },
                                   "the actual retry has passed its weak admission and owns capture")
            rig.engine = nil
            XCTAssertNotNil(rig.weakEngine.value)
            XCTAssertNotNil(rig.pipeline.host)
            rig.camera.releaseStills()
            try await self.require({ held.entered }, "the retried file reached the actual uploader")
            let event = try XCTUnwrap(rig.store.events.first { $0.id == id })
            try self.assertStoredFile(event, in: rig)
            XCTAssertNotNil(event.thumbnailData)
            XCTAssertEqual(event.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
            XCTAssertNotNil(rig.weakEngine.value)
            XCTAssertGreaterThan(rig.coordinator.bindingsInUse[id] ?? 0, 0)
            XCTAssertTrue(rig.store.uploadsUnderWay.contains(id))
            held.open()
            try await self.require({ self.completed(id, in: rig) }, "the retry's actual upload completed")
            try await self.require({ rig.weakEngine.value == nil }, "the admitted retry releases its host")
            XCTAssertEqual(rig.camera.stills.count, attempts + 1, "one parked incident spends one attempt")
        }
    }

    func testBlackoutAndFloodCadenceShareOneOwnerAcrossTheRootAndComponentEntries() async throws {
        try await withRigs(["cadence"]) { created in
            let rig = created[0]
            rig.camera.holdStills = true
            let flood = Task { await rig.engine?.captureCadenceForTesting(blackout: false) }
            let floodWorker = Task { _ = await flood.value }
            self.workers.append(floodWorker)
            try await self.require({ rig.camera.stills.count == 1 }, "the root flood route holds a real still")
            XCTAssertTrue(rig.responder.cadenceCaptureBusy)
            let floodID = try XCTUnwrap(self.incident(in: rig)?.id)
            let blackout = try XCTUnwrap(rig.engine).logBlackoutRecord()
            await rig.responder.captureBlackoutEvidence(for: blackout, cloudAllowed: true)
            XCTAssertEqual(rig.camera.stills.count, 1, "blackout yields its optional frame to the same cadence owner")
            try await self.require({ self.completed(blackout.id, in: rig) ||
                (rig.store.events.first { $0.id == blackout.id }?.cloudSyncState == .synced
                    && rig.coordinator.bindingsInUse[blackout.id] == nil
                    && !rig.store.uploadsUnderWay.contains(blackout.id))
            }, "the blackout fact uploads while flood capture is held")
            XCTAssertNil(rig.store.events.first { $0.id == blackout.id }?.mediaFilename)
            XCTAssertNil(rig.store.events.first { $0.id == blackout.id }?.captureFailure,
                         "shared cadence admission skips the frame before asking the busy pipeline")
            rig.camera.releaseStills()
            await floodWorker.value
            try await self.require({ self.completed(floodID, in: rig) }, "flood capture and upload completed")
            XCTAssertFalse(rig.responder.cadenceCaptureBusy)
            try self.assertStoredFile(try XCTUnwrap(rig.store.events.first { $0.id == floodID }), in: rig)
            // Opposite direction: direct blackout owns the lock; the root flood route skips.
            let next = try XCTUnwrap(rig.engine).logBlackoutRecord()
            rig.camera.holdStills = true
            let blackoutWorker = Task { await rig.responder.captureBlackoutEvidence(for: next, cloudAllowed: true) }
            self.workers.append(blackoutWorker)
            try await self.require({ rig.camera.stills.count == 2 }, "blackout may capture after flood released")
            XCTAssertTrue(rig.responder.cadenceCaptureBusy)
            let before = Set(rig.store.events.map(\.id))
            await rig.engine?.captureCadenceForTesting(blackout: false)
            XCTAssertEqual(rig.camera.stills.count, 2)
            XCTAssertEqual(Set(rig.store.events.map(\.id)), before, "skipped optional flood work mints no new record")
            rig.camera.releaseStills()
            await blackoutWorker.value
            try await self.require({ self.completed(next.id, in: rig) }, "blackout file and upload completed")
            try self.assertStoredFile(try XCTUnwrap(rig.store.events.first { $0.id == next.id }), in: rig)
            XCTAssertFalse(rig.responder.cadenceCaptureBusy)
            XCTAssertTrue(rig.coordinator.bindingsInUse.isEmpty)
            XCTAssertTrue(rig.observations.uploaded.contains { $0.id == blackout.id })
        }
    }

    func testIdleTripTimersAndCameraCallbacksDoNotKeepTheirOwnerAlive() async throws {
        try await withRigs(["idle-owner"]) { created in
            let rig = created[0]
            // Red characterization reads the original owner's timer; the real extraction
            // must expose the actual moved timer to reflection, never a shadow or proxy.
            let timer = try XCTUnwrap(self.timer(named: "refractoryTimer", on: rig.responder)
                ?? rig.engine.flatMap { self.timer(named: "refractoryTimer", on: $0) })
            XCTAssertTrue(timer.isValid, "the live watch has its actual recurring trip timer")
            XCTAssertNotNil(rig.camera.onSessionEvent)
            let records = rig.store.events
            let attempts = rig.camera.attemptBegins
            let saves = rig.observations.saves
            rig.engine = nil
            XCTAssertNil(rig.weakEngine.value, "active weak timer/camera routes do not own the engine")
            rig.camera.onSessionEvent?(.runtimeError("test after owner release"))
            rig.camera.onSessionEvent?(.interrupted(.background))
            timer.fire()
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertNil(rig.weakEngine.value)
            XCTAssertNil(rig.pipeline.host)
            XCTAssertEqual(rig.store.events, records)
            XCTAssertEqual(rig.camera.attemptBegins, attempts)
            XCTAssertEqual(rig.observations.saves, saves)
            XCTAssertTrue(rig.coordinator.bindingsInUse.isEmpty)
            timer.invalidate() // test retains the real timer after its owner has gone
        }
    }

    private func timer(named name: String, on owner: Any) -> Timer? {
        guard let value = Mirror(reflecting: owner).children.first(where: { $0.label == name })?.value else { return nil }
        return (value as? Timer) ?? (Mirror(reflecting: value).children.first?.value as? Timer)
    }
}
