import Combine
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class MonitoringArmingFlowTests: XCTestCase {
    private struct LiftEmission {
        let value: Bool
        let facade: Bool?
        let owner: Bool
        let blocked: Bool?
    }

    private struct GraceEmission {
        let value: Int
        let facade: Int?
        let owner: Int
        let state: MonitoringState?
        let marker: Bool
    }

    private struct ProgressEmission {
        let value: Double
        let facade: Double?
        let owner: Double
        let state: MonitoringState?
    }

    private struct ReviewEmission {
        let value: Bool
        let facade: Bool?
        let owner: Bool
        let state: MonitoringState?
        let summary: Bool
        let watch: Bool
        let armedMarker: Bool
        let starts: Int
        let armedRows: Int
    }

    @MainActor private final class Observations {
        var lookups = 0
        var health = 0
        var setupBegan = 0
        var setupFinished = 0
        var sawGuidedAccessCheck = false
        var preparations = 0
        var launchHealth = 0
        var launchSetupFinished = 0
        var calibrationTimer: Timer?
        var milestones: [String] = []
        var lifts: [LiftEmission] = []
        var grace: [GraceEmission] = []
        var progress: [ProgressEmission] = []
        var reviews: [ReviewEmission] = []
        var summaryOldValueWasNil: [Bool] = []
        var summaryBeforeWatch: [Bool] = []
        var summaryEndedCalibration: [Bool] = []
        var briefingValues: [FirstArmBriefing.Parts?] = []
        var briefingGetters: [FirstArmBriefing.Parts?] = []
        var briefingIdleFlags: [Bool] = []
        var briefingTimers: [Timer?] = []
        var briefingTimersWereValid: [Bool] = []
    }

    @MainActor private final class WeakEngine {
        weak var value: MonitoringEngine?
    }

    @MainActor private final class Rig {
        // Only this optional owns root; separately retaining flow exposes a weak-host
        // lifetime failure or a permanent host cycle. Never TestIsolation.track this rig.
        var engine: MonitoringEngine?
        let weakEngine = WeakEngine()
        let flow: MonitoringArmingFlow
        let camera: FakeCamera
        let store: EventStore
        let cloud: CloudExfiltrator
        let coordinator: MonitoringCloudCoordinator
        let observations: Observations
        var subscriptions: [AnyCancellable] = []

        init(_ engine: MonitoringEngine, camera: FakeCamera, observations: Observations) {
            self.engine = engine
            weakEngine.value = engine
            flow = engine.armingFlow
            self.camera = camera
            store = engine.eventStore
            cloud = engine.cloud
            coordinator = engine.cloudCoordinator
            self.observations = observations
        }
    }

    nonisolated private static let onboardingKeys = [
        "com.malinois.onboarding.hasArmedOnce",
        "com.malinois.onboarding.acknowledgedDisarmBriefing",
        "com.malinois.onboarding.acknowledgedGuidedAccessBriefing",
        "com.malinois.onboarding.acknowledgedVoiceControlBriefing"
    ]
    // XCTest's synchronous setup/teardown run on the main thread. Only those methods
    // touch saved defaults; MainActor tests own rigs, copied before teardown's actor hop.
    nonisolated(unsafe) private var savedDefaults: [String: Any] = [:]
    nonisolated(unsafe) private var rigs: [Rig] = []

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisArmingFlow")
        for key in Self.onboardingKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)
        }
        UserDefaults.standard.set(true, forKey: Self.onboardingKeys[0])
    }

    override func tearDown() {
        let heldRigs = rigs
        MainActor.assumeIsolated {
            for rig in heldRigs {
                rig.camera.releaseVideoAccess()
                rig.camera.releaseStills()
                rig.weakEngine.value?.firstArmBriefing = nil
                rig.weakEngine.value?.disarm()
                rig.engine = nil
                rig.store.drainIOForTesting()
            }
        }
        rigs = []
        TestIsolation.tearDown()
        for key in Self.onboardingKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    private static var timing: EngineTiming {
        var value = EngineCharacterizationTests.fastTiming
        value.calibrationDuration = 0.3
        value.calibrationReview = 60
        value.firstArmBriefingTimeout = 60
        value.sweepWaitFloor = 0.05
        value.sweepWaitCeiling = 0.05
        return value
    }

    private func until(_ condition: () -> Bool, timeout: Duration = .seconds(4)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private enum FixtureFailure: Error { case unreached }

    private func require(_ condition: () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let reached = await until(condition)
        XCTAssertTrue(reached, message, file: file, line: line)
        if !reached { throw FixtureFailure.unreached }
    }

    private func makeRig(permissionQuestion: Bool = false,
                         configure: (AppSettings) -> Void = { _ in }) async throws -> Rig {
        let previous = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let root = previous.appendingPathComponent(UUID().uuidString, isDirectory: true)
        EventStore.rootOverrideForTesting = root
        let store = EventStore()
        EventStore.rootOverrideForTesting = previous
        let policy = CloudEnrollment(file: root.appendingPathComponent("binding.json"), authenticate: { _ in true })
        let enrolled = await policy.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let observations = Observations()
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { observations.lookups += 1; return nil }
        cloud.saveAttemptForTesting = { _ in }
        cloud.automaticSetupBeganForTesting = { observations.setupBegan += 1 }
        cloud.automaticSetupFinishedForTesting = { observations.setupFinished += 1 }
        let settings = AppSettings()
        settings.enabledSensors = permissionQuestion ? [.touch, .camera] : [.touch]
        settings.gracePeriodSeconds = 1
        settings.requireGuidedAccess = false
        settings.cloudBackup = true
        settings.notifyOtherDevices = false
        settings.cameraReadiness = .batterySaver
        settings.responseMode = .stealth
        settings.jammingResponse = false
        configure(settings)
        let camera = FakeCamera()
        if permissionQuestion {
            camera.videoPermission = .notDetermined
            camera.videoAccessAnswer = .authorized
            camera.holdVideoAccess = true
        }
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: cloud, camera: camera,
            entitlements: ProEntitlements(resolvedAs: .trial), timing: Self.timing,
            protectedDataAvailable: { true }, thermalState: { .nominal })
        let rig = Rig(engine, camera: camera, observations: observations)
        rigs.append(rig)
        rig.subscriptions = [
            engine.$notificationAskDue.dropFirst().sink { _ in observations.health += 1 },
            engine.$state.dropFirst().sink { state in
                if state == .guidedAccessCheck {
                    observations.sawGuidedAccessCheck = true
                    observations.preparations += 1
                }
            }
        ]
        engine.simulateGuidedAccessForTesting(on: false)
        engine.simulateConnectivityForTesting(online: true)
        try await require({
            observations.lookups >= 2 && observations.health >= 1
                && !rig.coordinator.pendingSweepActive && !rig.coordinator.cloudRestoreInProgress
                && observations.setupBegan == observations.setupFinished
        }, "actual launch restore, sweep, setup and notification health finished")
        observations.launchHealth = observations.health
        observations.launchSetupFinished = observations.setupFinished
        cloud.accountIdentityForTesting = { "account-a" }
        rig.coordinator.beatSendForTesting = { _ in true }
        return rig
    }

    private func withRig(permissionQuestion: Bool = false, configure: (AppSettings) -> Void = { _ in },
                         body: (Rig) async throws -> Void) async throws {
        do {
            let rig = try await makeRig(permissionQuestion: permissionQuestion, configure: configure)
            try await body(rig)
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    private func finish() async {
        for rig in rigs {
            rig.camera.releaseVideoAccess()
            rig.camera.releaseStills()
            if rig.camera.videoAccessRequests > 0 {
                let answered = await until {
                    rig.observations.sawGuidedAccessCheck || rig.weakEngine.value == nil
                }
                XCTAssertTrue(answered, "the permission task answered before cleanup")
            }
            if rig.observations.preparations > 0 {
                let setupEnded = await until {
                    rig.observations.health >= rig.observations.launchHealth + rig.observations.preparations
                        && rig.observations.setupFinished >= rig.observations.launchSetupFinished + rig.observations.preparations
                        && rig.observations.setupBegan == rig.observations.setupFinished
                }
                XCTAssertTrue(setupEnded, "the actually queued arm health/setup tasks finished before cleanup")
            }
            rig.weakEngine.value?.firstArmBriefing = nil
            rig.weakEngine.value?.disarm()
            let drained = await until {
                rig.coordinator.bindingsInUse.isEmpty && rig.store.uploadsUnderWay.isEmpty
                    && !rig.coordinator.pendingSweepActive && !rig.coordinator.cloudRestoreInProgress
                    && rig.observations.setupBegan == rig.observations.setupFinished
                    && rig.camera.videoAccessWaiterCount == 0
            }
            XCTAssertTrue(drained, "finite camera/cloud/store work drained before teardown")
            rig.subscriptions.forEach { $0.cancel() }
            rig.subscriptions.removeAll()
            rig.engine = nil
            rig.store.drainIOForTesting()
        }
    }

    func testLiftPublicationRetainsCurrentGuardAndEqualAssignmentSemantics() async throws {
        try await withRig(configure: { $0.requireGuidedAccess = true }, body: { rig in
            rig.engine?.beginArming()
            XCTAssertEqual(rig.engine?.state, .guidedAccessCheck)
            XCTAssertEqual(rig.engine?.armingBlockedByGuidedAccess, true)
            let probe = rig.weakEngine
            let flow = rig.flow
            let observations = rig.observations
            rig.subscriptions.append(try XCTUnwrap(rig.engine).$guidedAccessLiftedThisArm.dropFirst().sink { value in
                observations.lifts.append(LiftEmission(value: value, facade: probe.value?.guidedAccessLiftedThisArm,
                    owner: flow.guidedAccessLiftedThisArm, blocked: probe.value?.armingBlockedByGuidedAccess))
            })
            rig.engine?.liftGuidedAccessRequirementForThisArm()
            // No yield: a didSet bridge exposes new policy early; a scheduled bridge arrives late.
            XCTAssertEqual(observations.lifts.count, 1)
            XCTAssertEqual(observations.lifts.first?.value, true)
            XCTAssertEqual(observations.lifts.first?.facade, false)
            XCTAssertEqual(observations.lifts.first?.owner, false)
            XCTAssertEqual(observations.lifts.first?.blocked, true)
            XCTAssertEqual(rig.engine?.guidedAccessLiftedThisArm, true)
            XCTAssertTrue(flow.guidedAccessLiftedThisArm)
            XCTAssertEqual(rig.engine?.armingBlockedByGuidedAccess, false)
            rig.engine?.clearGuidedAccessLift()
            rig.engine?.clearGuidedAccessLift()
            XCTAssertEqual(observations.lifts.map(\.value), [true, false, false])
            XCTAssertEqual(observations.lifts.map(\.facade), [false, true, false])
            XCTAssertEqual(observations.lifts.map(\.owner), [false, true, false])
            XCTAssertEqual(observations.lifts.map(\.blocked), [true, false, true])
            XCTAssertFalse(flow.guidedAccessLiftedThisArm)
            XCTAssertEqual(rig.engine?.armingBlockedByGuidedAccess, true)
        })
    }

    func testCountdownCalibrationAndReviewPublishAtExistingSessionBoundaries() async throws {
        try await withRig(configure: { $0.enabledSensors = [.touch, .motion] }, body: { rig in
            let monitor = FakeCalibratingMonitor(type: .motion)
            rig.engine?.replaceMonitorForTesting(monitor)
            rig.engine?.beginArming()
            let probe = rig.weakEngine
            let flow = rig.flow
            let observations = rig.observations
            let store = rig.store
            rig.subscriptions += [
                try XCTUnwrap(rig.engine).$graceRemaining.dropFirst().sink { value in
                    observations.grace.append(GraceEmission(value: value, facade: probe.value?.graceRemaining,
                        owner: flow.graceRemaining, state: probe.value?.state,
                        marker: UserDefaults.standard.bool(forKey: MonitoringEngine.armingInProgressKey)))
                },
                try XCTUnwrap(rig.engine).$calibrationProgress.dropFirst().sink { value in
                    observations.progress.append(ProgressEmission(value: value, facade: probe.value?.calibrationProgress,
                        owner: flow.calibrationProgress, state: probe.value?.state))
                    if observations.calibrationTimer == nil {
                        observations.calibrationTimer = Self.timer(named: "calibrationTimer", on: flow)
                    }
                },
                try XCTUnwrap(rig.engine).$lastCalibration.dropFirst().sink { summary in
                    guard summary != nil else { return }
                    observations.milestones.append("summary")
                    observations.summaryOldValueWasNil.append(probe.value?.lastCalibration == nil)
                    observations.summaryBeforeWatch.append(probe.value?.armedSince == nil
                        && UserDefaults.standard.object(forKey: MonitoringEngine.armedMarkerKey) == nil
                        && monitor.starts == 0)
                    observations.summaryEndedCalibration.append(monitor.endCalibrations == 1)
                },
                try XCTUnwrap(rig.engine).$showingCalibrationReview.dropFirst().sink { value in
                    observations.milestones.append("review:\(value)")
                    observations.reviews.append(ReviewEmission(value: value, facade: probe.value?.showingCalibrationReview,
                        owner: flow.showingCalibrationReview, state: probe.value?.state,
                        summary: probe.value?.lastCalibration != nil, watch: probe.value?.armedSince != nil,
                        armedMarker: UserDefaults.standard.object(forKey: MonitoringEngine.armedMarkerKey) != nil,
                        starts: monitor.starts, armedRows: store.events.filter { $0.stateChange == "armed" }.count))
                },
                try XCTUnwrap(rig.engine).$state.dropFirst().sink { state in
                    if state == .armed { observations.milestones.append("armed") }
                }
            ]
            rig.engine?.confirmGuidedAccessAndStartGrace()
            XCTAssertEqual(observations.grace.first?.value, 1)
            XCTAssertEqual(observations.grace.first?.facade, 0)
            XCTAssertEqual(observations.grace.first?.owner, 0)
            XCTAssertEqual(observations.grace.first?.state, .arming)
            XCTAssertEqual(observations.grace.first?.marker, true)
            XCTAssertEqual(flow.graceRemaining, 1)
            XCTAssertNotNil(Self.timer(named: "graceTimer", on: flow), "flow owns the actual scheduled grace timer")
            try await self.require({ rig.engine?.state == .calibrating }, "the real grace timer began calibration")
            XCTAssertEqual(observations.progress.first?.value, 0, "equal initial zero still publishes")
            try await self.require({ rig.engine?.showingCalibrationReview == true }, "the actual calibration timer completed")
            XCTAssertNotNil(observations.calibrationTimer, "the progress callback reads the actual flow timer")
            XCTAssertEqual(observations.calibrationTimer?.isValid, false, "finish invalidates the real timer before review")
            var previousRemaining = 0
            for emission in observations.grace {
                XCTAssertEqual(emission.facade, previousRemaining)
                XCTAssertEqual(emission.owner, previousRemaining)
                previousRemaining = emission.value
            }
            var previousProgress = 0.0
            XCTAssertGreaterThan(observations.progress.count, 1)
            for emission in observations.progress {
                XCTAssertEqual(emission.facade, previousProgress)
                XCTAssertEqual(emission.owner, previousProgress)
                XCTAssertEqual(emission.state, .calibrating)
                previousProgress = emission.value
            }
            XCTAssertEqual(previousProgress, 1)
            XCTAssertEqual(flow.calibrationProgress, 1)
            XCTAssertEqual(observations.summaryOldValueWasNil, [true])
            XCTAssertEqual(observations.summaryBeforeWatch, [true])
            XCTAssertEqual(observations.summaryEndedCalibration, [true])
            XCTAssertEqual(observations.milestones, ["summary", "review:true"])
            let review = try XCTUnwrap(observations.reviews.first)
            XCTAssertFalse(review.owner)
            XCTAssertEqual(review.facade, false)
            XCTAssertEqual(review.state, .calibrating)
            XCTAssertTrue(review.summary && review.watch && review.armedMarker)
            XCTAssertEqual(review.starts, 1)
            XCTAssertEqual(review.armedRows, 1)
            XCTAssertTrue(flow.showingCalibrationReview)
            rig.engine?.goCovert()
            XCTAssertEqual(observations.milestones, ["summary", "review:true", "review:false", "armed"])
            let ending = try XCTUnwrap(observations.reviews.last)
            XCTAssertFalse(ending.value)
            XCTAssertEqual(ending.facade, true)
            XCTAssertTrue(ending.owner)
            XCTAssertEqual(ending.state, .calibrating)
            XCTAssertEqual(rig.engine?.state, .armed)
            XCTAssertFalse(flow.showingCalibrationReview)
        })
    }

    func testWritableBriefingBindingOwnsItsSynchronousTimeoutAndIdleEffects() async throws {
        try await withRig { rig in
            rig.engine?.beginArming()
            XCTAssertEqual(rig.engine?.state, .guidedAccessCheck)
            XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
            let observations = rig.observations
            let flow = rig.flow
            let probe = rig.weakEngine
            rig.subscriptions.append(try XCTUnwrap(rig.engine).$firstArmBriefing.dropFirst().sink { value in
                observations.briefingValues.append(value)
                observations.briefingGetters.append(probe.value?.firstArmBriefing)
                observations.briefingIdleFlags.append(UIApplication.shared.isIdleTimerDisabled)
                let timer = Self.timer(named: "firstArmBriefingTimer", on: flow)
                observations.briefingTimers.append(timer)
                observations.briefingTimersWereValid.append(timer?.isValid == true)
            })
            let rowsBefore = rig.store.events
            let parts = FirstArmBriefing.Parts(disarm: true, guidedAccess: false)
            rig.engine?.firstArmBriefing = parts
            XCTAssertEqual(rig.engine?.firstArmBriefing, parts)
            XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
            let first = try XCTUnwrap(Self.timer(named: "firstArmBriefingTimer", on: flow), "flow owns the real briefing timeout")
            XCTAssertTrue(first.isValid)
            rig.engine?.firstArmBriefing = parts
            let second = try XCTUnwrap(Self.timer(named: "firstArmBriefingTimer", on: flow))
            XCTAssertFalse(first.isValid, "same-value assignment invalidates the preceding physical timer")
            XCTAssertFalse(first === second)
            XCTAssertTrue(second.isValid)
            rig.engine?.firstArmBriefing = nil
            XCTAssertFalse(second.isValid, "binding dismissal cancels its physical timer before returning")
            XCTAssertNil(Self.timer(named: "firstArmBriefingTimer", on: flow))
            XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
            XCTAssertEqual(observations.briefingValues, [parts, parts, nil])
            XCTAssertEqual(observations.briefingGetters, [nil, parts, parts])
            XCTAssertEqual(observations.briefingIdleFlags, [true, false, false])
            XCTAssertEqual(observations.briefingTimersWereValid, [false, true, true])
            XCTAssertTrue((observations.briefingTimers.dropFirst().first ?? nil) === first)
            XCTAssertTrue((observations.briefingTimers.dropFirst(2).first ?? nil) === second)
            XCTAssertEqual(rig.engine?.state, .guidedAccessCheck)
            XCTAssertEqual(rig.store.events, rowsBefore)
            XCTAssertFalse(OnboardingState.acknowledgedDisarmBriefing)
            XCTAssertFalse(OnboardingState.acknowledgedGuidedAccessBriefing)
            XCTAssertFalse(OnboardingState.acknowledgedVoiceControlBriefing)
        }
    }

    func testQueuedPermissionWorkRetainsItsOwnerThroughTheAnswerThenReleasesIt() async throws {
        try await withRig(permissionQuestion: true) { rig in
            let healthBefore = rig.observations.health
            let setupBefore = rig.observations.setupFinished
            rig.engine?.armAfterPINCheck()
            rig.engine = nil
            XCTAssertNotNil(rig.weakEngine.value, "permission work owns root before its first task turn")
            try await self.require({ rig.camera.videoAccessWaiterCount == 1 }, "the actual permission request is suspended")
            XCTAssertEqual(rig.camera.videoAccessRequests, 1)
            XCTAssertEqual(rig.weakEngine.value?.state, .disarmed)
            XCTAssertFalse(rig.observations.sawGuidedAccessCheck)
            XCTAssertNotNil(rig.weakEngine.value, "the question keeps the same root through its answer")
            rig.camera.releaseVideoAccess()
            try await self.require({ rig.observations.sawGuidedAccessCheck }, "the answer resumes actual arm preparation")
            try await self.require({
                rig.observations.health > healthBefore && rig.observations.setupFinished > setupBefore
                    && rig.observations.setupBegan == rig.observations.setupFinished
                    && rig.coordinator.bindingsInUse.isEmpty && rig.store.uploadsUnderWay.isEmpty
            }, "root's finite arm preparation also finished")
            XCTAssertEqual(rig.camera.videoAccessWaiterCount, 0)
            try await self.require({ rig.weakEngine.value == nil }, "completed permission work has no permanent flow/host cycle")
            XCTAssertNil(Self.timer(named: "graceTimer", on: rig.flow), "permission answer stops at the arming screen")
            XCTAssertNil(Self.timer(named: "firstArmBriefingTimer", on: rig.flow))
        }
    }

    private static func timer(named name: String, on owner: Any) -> Timer? {
        guard let value = Mirror(reflecting: owner).children.first(where: { $0.label == name })?.value else { return nil }
        return (value as? Timer) ?? (Mirror(reflecting: value).children.first?.value as? Timer)
    }
}
