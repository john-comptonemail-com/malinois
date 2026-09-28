//
//  Item85RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for BACKLOG 85 (1.3.3). Since 1.3.2 the launch recovery waits for the unlock
//  when the launch reads the device as locked (item 65, finding 18). But UIKit answers
//  `isProtectedDataAvailable` false while the app is still being built (the engine is constructed
//  inside `MalinoisApp.init`) even on an unlocked phone, and an unlocked phone sends no unlock
//  notice. Found on the owner's phone 2026-09-26: reopening Malinois after it was killed while
//  armed started no countdown, and a lock and unlock with the app open then did. The app becoming
//  active means the phone is unlocked, so a recovery that is still waiting runs then.
//
//  The engine's `protectedDataAvailable` seam answers false here, the way UIKit answers during
//  that early construction.
//

import XCTest
@testable import Malinois

@MainActor
final class Item85RegressionTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    // The persisted recovery keys, spelled out (the item 73 precedent): a renamed key on disk is a
    // behavior change these tests must catch, not absorb. The last re-arm attempt's time too: left
    // over from another class's recovery, the crash-loop guard would decline the re-arm here.
    private static let armedMarkerKey = "com.malinois.armedSession.brightness"
    private static let armedBootTimeKey = "com.malinois.armedSession.bootTime"
    private static let armedBootStampAtKey = "com.malinois.armedSession.bootStampAt"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let recoveryInProgressKey = "com.malinois.recovery.inProgress"
    private static let recoveryTimeKey = "com.malinois.recovery.lastAt"
    private static let armingInProgressKey = "com.malinois.arming.inProgress"
    private static let backgroundLapseLoggedKey = "com.malinois.armed.backgroundLapseLogged"

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem85-" + UUID().uuidString, isDirectory: true)
        clearPersistedMarkers()
    }

    override func tearDown() {
        clearPersistedMarkers()
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        super.tearDown()
    }

    private func clearPersistedMarkers() {
        for key in [Self.armedMarkerKey, Self.armedBootTimeKey, Self.armedBootStampAtKey,
                    Self.pendingReArmKey, Self.recoveryInProgressKey, Self.recoveryTimeKey,
                    Self.armingInProgressKey, Self.backgroundLapseLoggedKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// An engine built the way the app builds one at launch, with the answer about the lock
    /// injected. A grace period keeps the recovery's countdown open for the tests that need it.
    private func makeRig(protectedDataAvailable: @escaping @MainActor () -> Bool,
                         gracePeriodSeconds: Int = 0) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = gracePeriodSeconds
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                      camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: EngineCharacterizationTests.fastTiming,
                                      protectedDataAvailable: protectedDataAvailable)
        return Rig(engine: engine, store: store)
    }

    private func interruptionRecords(_ rig: Rig) -> Int {
        rig.store.events.filter { $0.interrupted ?? false }.count
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Spins the main run loop for `seconds`: the wait a test needs when what it checks is that
    /// nothing more happens.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - The owner's check

    /// A launch that reads locked on an unlocked phone: the recovery waits, then runs the moment
    /// the app is active (the record, the marker consumed, the automatic re-arm), with no unlock
    /// notice at all.
    func testALaunchThatReadsLockedRecoversOnceTheAppIsActive() {
        UserDefaults.standard.set(0.5, forKey: Self.armedMarkerKey)   // an armed session the process died out of
        let rig = makeRig(protectedDataAvailable: { false })          // UIKit's answer inside MalinoisApp.init
        XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey),
                        "the launch reads locked: the recovery waits, the marker untouched")
        XCTAssertEqual(interruptionRecords(rig), 0, "nothing recorded yet")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { interruptionRecords(rig) == 1 }, timeout: 3),
                      "the app is on screen, so the phone is unlocked: the waiting recovery runs")
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey), "which consumes the marker")
        XCTAssertTrue(pump(until: { rig.engine.state != .disarmed }, timeout: 3),
                      "and starts the automatic re-arm")
        rig.engine.disarm()
    }

    // MARK: - Once only

    /// Run because the app became active, the recovery does not run again at the next unlock. A
    /// second run would find the recovery countdown's own marker and record a second interruption.
    func testARecoveryRunByTheActiveAppDoesNotRunAgainAtTheNextUnlock() {
        UserDefaults.standard.set(0.5, forKey: Self.armedMarkerKey)
        var unlocked = false
        let rig = makeRig(protectedDataAvailable: { unlocked }, gracePeriodSeconds: 5)   // the countdown stays open
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3),
                      "the active app ran the recovery, and its countdown is open")
        unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        settle(0.3)
        XCTAssertEqual(interruptionRecords(rig), 1, "one interruption, one record")
        rig.engine.disarm()
    }

    /// And the other way round: run at the unlock, the recovery does not run again when the app
    /// becomes active.
    func testARecoveryRunAtTheUnlockDoesNotRunAgainWhenTheAppBecomesActive() {
        UserDefaults.standard.set(0.5, forKey: Self.armedMarkerKey)
        var unlocked = false
        let rig = makeRig(protectedDataAvailable: { unlocked }, gracePeriodSeconds: 5)
        unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3),
                      "the unlock ran the recovery, and its countdown is open")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        settle(0.3)
        XCTAssertEqual(interruptionRecords(rig), 1, "one interruption, one record")
        rig.engine.disarm()
    }

    // MARK: - A normal launch

    /// Nothing was interrupted: the app becoming active records nothing and starts no countdown.
    func testALaunchWithNothingInterruptedStaysQuietWhenTheAppBecomesActive() {
        let rig = makeRig(protectedDataAvailable: { false })
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        settle(0.3)
        XCTAssertTrue(rig.store.events.isEmpty, "no record")
        XCTAssertEqual(rig.engine.state, .disarmed, "no countdown")
    }
}
