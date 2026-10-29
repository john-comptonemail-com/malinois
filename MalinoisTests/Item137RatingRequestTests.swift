//
//  Item137RatingRequestTests.swift
//  MalinoisTests
//
//  BACKLOG 137 (1.8.2's step 27; the owner's ruling: yes). Malinois never asked for a rating. It now makes Apple's
//  standard request (StoreKit's; guideline 5.6.1 allows no other) at a calm moment: after a disarm that ended a live
//  watch with no incident in it (the owner's own handling at the pad, marked as the owner's, does not count), from the
//  third such disarm on; never while arming, after a tamper, on Home's PIN pad or under Guided Access. iOS decides
//  whether to show it, at most three times a year. The engine counts and flags; Home makes the request through
//  SwiftUI's environment, which a test cannot press, so Home's rule is tested pure. Written before the change, red at
//  that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

@MainActor
final class Item137RatingRequestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem137Rating")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEngine(grace: Int = 0) -> (engine: MonitoringEngine, store: EventStore) {
        let settings = AppSettings()
        settings.gracePeriodSeconds = grace
        settings.requireGuidedAccess = false
        settings.responseMode = .stealth
        settings.captureMode = .photo
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, store)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private func goLive(_ engine: MonitoringEngine) async {
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let live = await waitFor({ engine.state == .armed }, timeout: 5)
        XCTAssertTrue(live, "the watch went live")
    }

    /// A watch that goes live and is disarmed with nothing in it.
    private func calmWatch(_ engine: MonitoringEngine) async {
        await goLive(engine)
        engine.disarm()
    }

    // MARK: - The rules

    func testTheThirdCalmDisarmIsTheFirstToAsk() {
        XCTAssertEqual(MonitoringEngine.calmDisarmsBeforeRatingRequest, 3)
        for count in 0...2 { XCTAssertFalse(MonitoringEngine.ratingRequestDue(calmDisarms: count), "\(count): not yet") }
        for count in [3, 4, 9] { XCTAssertTrue(MonitoringEngine.ratingRequestDue(calmDisarms: count), "\(count): asks") }
    }

    /// Home asks only when something is due, no PIN pad is up and Guided Access is off.
    func testHomeAsksOnlyWhenNothingElseIsOnScreen() {
        XCTAssertTrue(HomeView.mayAskForRating(pending: true, pinGateOpen: false, guidedAccessOn: false))
        XCTAssertFalse(HomeView.mayAskForRating(pending: false, pinGateOpen: false, guidedAccessOn: false), "nothing due")
        XCTAssertFalse(HomeView.mayAskForRating(pending: true, pinGateOpen: true, guidedAccessOn: false), "a PIN pad is up")
        XCTAssertFalse(HomeView.mayAskForRating(pending: true, pinGateOpen: false, guidedAccessOn: true),
                       "under Guided Access")
    }

    // MARK: - The engine

    /// Three calm watches: the third disarm asks; handled, the next calm disarm asks again (iOS limits how often it
    /// shows).
    func testTheThirdCalmWatchAsksAtItsDisarm() async {
        let (engine, _) = makeEngine()
        await calmWatch(engine)
        await calmWatch(engine)
        XCTAssertFalse(engine.ratingRequestPending, "two calm disarms: not yet")
        await calmWatch(engine)
        XCTAssertTrue(engine.ratingRequestPending, "the third asks")
        engine.ratingRequestHandled()
        XCTAssertFalse(engine.ratingRequestPending)
        await calmWatch(engine)
        XCTAssertTrue(engine.ratingRequestPending, "each calm disarm from the third on")
    }

    /// A watch with an incident in it never counts.
    func testAWatchWithATamperDoesNotCount() async {
        let (engine, store) = makeEngine()
        for _ in 0..<3 {
            await goLive(engine)
            let before = store.events.filter { !$0.isStateChange }.count
            engine.handleTrip(.motion)
            let recorded = await waitFor({ engine.state == .armed && store.events.filter { !$0.isStateChange }.count > before },
                                         timeout: 3)
            XCTAssertTrue(recorded, "the incident is in the log")
            engine.disarm()
        }
        XCTAssertFalse(engine.ratingRequestPending, "tampered watches never ask")
    }

    /// The owner's own handling at the pad (records the disarm marks as the owner's) leaves a watch calm.
    func testTheOwnersOwnHandlingAtThePadLeavesAWatchCalm() async {
        let (engine, store) = makeEngine()
        for _ in 0..<3 {
            await goLive(engine)
            store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], ownerAttributed: true))
            engine.disarm()
        }
        XCTAssertTrue(engine.ratingRequestPending, "the owner's handling is not a tamper")
    }

    /// A countdown cancelled before it goes live is not a watch.
    func testACancelledCountdownDoesNotCount() async {
        let (engine, _) = makeEngine(grace: 30)
        for _ in 0..<3 {
            engine.beginArming()
            engine.confirmGuidedAccessAndStartGrace()
            let counting = await waitFor({ engine.state == .arming }, timeout: 3)
            XCTAssertTrue(counting, "the countdown")
            engine.disarm()
        }
        XCTAssertFalse(engine.ratingRequestPending, "no watch went live")
    }

    /// codex-16 on c75f223: a request left waiting (Guided Access kept Home from asking) does not outlive a later watch
    /// with an incident: after it, Home has nothing to ask, once Guided Access ends or not.
    func testAWaitingRequestDoesNotOutliveAWatchWithAnIncident() async {
        let (engine, store) = makeEngine()
        for _ in 0..<3 { await calmWatch(engine) }
        XCTAssertTrue(engine.ratingRequestPending, "the third calm disarm asks; Guided Access keeps Home from it")
        await goLive(engine)
        let before = store.events.filter { !$0.isStateChange }.count
        engine.handleTrip(.motion)
        let recorded = await waitFor({ engine.state == .armed && store.events.filter { !$0.isStateChange }.count > before },
                                     timeout: 3)
        XCTAssertTrue(recorded, "the incident is in the log")
        engine.disarm()
        XCTAssertFalse(engine.ratingRequestPending, "nothing to ask after a watch with an incident")
        XCTAssertFalse(HomeView.mayAskForRating(pending: engine.ratingRequestPending, pinGateOpen: false,
                                                guidedAccessOn: false), "Guided Access ended: Home does not ask")
    }
}
