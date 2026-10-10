//
//  Item88RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for BACKLOG 88, found by the 2026-09-28 review of item 85 (shipped in 1.3.3).
//  Since 1.3.2 the launch recovery can wait (for the unlock, and since 1.3.3 for the app becoming
//  active). The two other activation-time paths that act on the same persisted flags, the
//  entitlement hook's owed re-arm and the foreground pass, were written when the recovery always
//  ran inside `init`, before either, and nothing orders them now:
//   - the entitlement hook re-arms an owed session first; the recovery then reads that
//     countdown's own marker as a killed countdown and records a false interruption;
//   - the foreground pass clears the "lapse already logged" flag first; the recovery then records
//     the same lapse a second time.
//  The waiting launch recovery now runs at the start of the foreground pass, and the entitlement
//  hook leaves an owed re-arm to it while it waits.
//

import XCTest
@testable import Malinois

@MainActor
final class Item88RegressionTests: XCTestCase {

    // The persisted keys these tests plant, spelled out (the item 73 precedent): a renamed key on
    // disk is a behavior change the tests must catch. TestIsolation clears every recovery flag.
    private static let armedMarkerKey = "com.malinois.armedSession.brightness"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let backgroundLapseLoggedKey = "com.malinois.armed.backgroundLapseLogged"

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem88")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// An engine built the way the app builds one at launch, reading the phone as locked (UIKit's
    /// answer inside `MalinoisApp.init`), so its recovery waits. The entitlement is resolved at
    /// construction, so its hook runs on the next turn of the run loop. A grace period keeps the
    /// recovery's countdown open.
    private func makeRig() -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 5
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          protectedDataAvailable: { false }))
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

    /// Spins the main run loop for `seconds`.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - The entitlement hook first

    /// A re-arm owed by an earlier launch, with the entitlement resolving before the app is
    /// active: the re-arm runs once, and no interruption is recorded, because none happened in
    /// this launch.
    func testAnOwedReArmIsNotRecordedAsAnInterruptionWhenTheEntitlementResolvesFirst() {
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        let rig = makeRig()
        settle(0.3)   // the entitlement hook's turn, before the app is active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 3), "the owed re-arm's countdown")
        settle(0.3)
        XCTAssertEqual(interruptionRecords(rig), 0, "nothing was interrupted in this launch")
        rig.engine.disarm()
    }

    // MARK: - The foreground pass first

    /// Guided Access on, a side-button lock logged the lapse, and iOS ended the suspended app
    /// overnight. When the owner opens it, the foreground pass runs before the waiting recovery:
    /// the lapse is not recorded a second time.
    func testALapseAlreadyLoggedIsNotRecordedAgainWhenTheForegroundPassRunsFirst() {
        UserDefaults.standard.set(0.5, forKey: Self.armedMarkerKey)
        UserDefaults.standard.set(true, forKey: Self.backgroundLapseLoggedKey)
        let rig = makeRig()
        rig.engine.handleScenePhase(true)   // SwiftUI's scene activation, ahead of the notice's hop
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { UserDefaults.standard.object(forKey: Self.armedMarkerKey) == nil }, timeout: 3),
                      "the recovery ran: the marker is consumed")
        settle(0.3)
        XCTAssertEqual(interruptionRecords(rig), 0, "the lapse's own record already says it")
        rig.engine.disarm()
    }

    /// The same launch in the other order (the notice's hop first) records nothing more either:
    /// the order no longer matters.
    func testALapseAlreadyLoggedIsNotRecordedAgainWhenTheNoticeRunsFirst() {
        UserDefaults.standard.set(0.5, forKey: Self.armedMarkerKey)
        UserDefaults.standard.set(true, forKey: Self.backgroundLapseLoggedKey)
        let rig = makeRig()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { UserDefaults.standard.object(forKey: Self.armedMarkerKey) == nil }, timeout: 3))
        rig.engine.handleScenePhase(true)
        settle(0.3)
        XCTAssertEqual(interruptionRecords(rig), 0)
        rig.engine.disarm()
    }
}
