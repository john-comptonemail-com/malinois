//
//  Item57WatchReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 57, the independent review of the 1.6 (61) candidate (owner's request, 2026-10-12).
//  Four of its findings are bugs in the iPhone-to-watch relay (ADR 0043):
//  1. After a launch while the phone was locked, the log is read at unlock in one go, and the relay
//     took every old incident and disarm for news: a flood of stale alerts on the wrist.
//  2. An alert sent before the watch link finished activating, such as the interruption record a
//     relaunch writes within milliseconds, was dropped.
//  5. One event could alert twice when the watch app restarted between its live and queued copies.
//  6. A held background wake had no end if activation failed or time ran out.
//  Written before the fixes, red at that commit (against compile-only stubs).
//  Item 155's A10 (BACKLOG 163's step 30): when the iPhone's link to its watch failed to activate, the alerts waiting for
//  it were dropped and every later one with them, until the app launched again. Now they keep waiting, and a later send
//  or a foreground asks WatchConnectivity to activate again, after a wait that doubles from 5 seconds up to 10 minutes.
//  Written before the change, red at that commit (against stubs that keep the old behaviour).
//

import UIKit
import WatchConnectivity
import XCTest
@testable import Malinois

@MainActor
final class Item57WatchReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem57Review")
    }

    override func tearDown() {
        unseal()
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - A sealed log (Item86RegressionTests' method: no read permission stands in for Data Protection)

    nonisolated private var logURL: URL? { EventStore.rootOverrideForTesting?.appendingPathComponent("events.json") }

    private func plantLog(_ events: [Event]) throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: root.appendingPathComponent("events.json"))
    }

    private func seal() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: XCTUnwrap(logURL).path)
    }

    nonisolated private func unseal() {
        guard let path = logURL?.path, FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func event(stateChange: String? = nil, secondsAgo: TimeInterval = 0) -> Event {
        let at = Date().addingTimeInterval(-secondsAgo)
        return Event(startDate: at, endDate: at, triggeredSensors: stateChange == nil ? [.motion] : [],
                     stateChange: stateChange)
    }

    private func message() -> WatchAlertMessage {
        WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date())
    }

    // MARK: - Finding 1: the log read at unlock is history

    /// A launch while the phone is locked defers the log; at unlock the whole history arrives at
    /// once. Only what happened meanwhile is news: an old incident or disarm is not relayed again.
    func testTheLogReadAtUnlockIsHistoryNotNews() throws {
        let oldTrip = event(secondsAgo: 3600)
        let oldDisarm = event(stateChange: "disarmed", secondsAgo: 3500)
        try plantLog([oldDisarm, oldTrip])
        try seal()
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        let settings = AppSettings()
        settings.notifyOtherDevices = true
        var sent: [WatchAlertMessage] = []
        let relay = WatchAlertRelay(store: store, settings: settings,
                                    entitlements: ProEntitlements(resolvedAs: .trial), send: { sent.append($0) })
        relay.start()
        let meanwhile = event()
        store.add(meanwhile)   // a trip while the log is still sealed: news
        unseal()
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.events.contains { $0.id == oldTrip.id } }, timeout: 3), "the log is read at unlock")
        XCTAssertEqual(sent.map(\.eventID), [meanwhile.id], "the history read at unlock is not relayed")
        let later = event()
        store.add(later)
        XCTAssertEqual(sent.map(\.eventID), [meanwhile.id, later.id], "news after the unlock still goes out")
    }

    // MARK: - Finding 2: alerts wait for the link to activate

    /// Alerts sent while the link is activating wait, and go out when it activates with a watch.
    func testAlertsSentWhileTheLinkIsActivatingGoOutAtActivation() {
        var outbox = WatchLinkOutbox()
        let first = message(), second = message()
        XCTAssertTrue(outbox.holdIfActivating(first))
        XCTAssertTrue(outbox.holdIfActivating(second))
        XCTAssertEqual(outbox.activationCompleted(watchReady: true), [first, second])
        XCTAssertFalse(outbox.holdIfActivating(message()), "once activated, an alert goes out at once")
    }

    /// Without a paired watch running Malinois the waiting alerts are dropped, and later ones are
    /// not held.
    func testWithoutAWatchTheWaitingAlertsAreDropped() {
        var outbox = WatchLinkOutbox()
        XCTAssertTrue(outbox.holdIfActivating(message()))
        XCTAssertEqual(outbox.activationCompleted(watchReady: false), [])
        XCTAssertFalse(outbox.holdIfActivating(message()))
    }

    /// At most `limit` wait, the newest kept; while the owner switches watches alerts wait again.
    func testTheOutboxIsBoundedAndWaitsAgainWhileSwitchingWatches() {
        var outbox = WatchLinkOutbox()
        let messages = (0..<(WatchLinkOutbox.limit + 5)).map { _ in message() }
        messages.forEach { _ = outbox.holdIfActivating($0) }
        XCTAssertEqual(outbox.activationCompleted(watchReady: true), Array(messages.suffix(WatchLinkOutbox.limit)))
        outbox.sessionBecameInactive()
        let waiting = message()
        XCTAssertTrue(outbox.holdIfActivating(waiting), "between watches: held")
        XCTAssertEqual(outbox.activationCompleted(watchReady: true), [waiting])
    }

    /// The link holds an alert sent while it activates and sends it once activation completes with a
    /// watch ready; later alerts go at once; while the owner switches watches they wait again. Run
    /// through the link with a stand-in session: reading the source, this passed with a held alert
    /// also sent at once (the test-suite audit's probe W341; P4).
    func testTheLinkHoldsAlertsUntilActivationCompletes() {
        let session = StandInWatchSession()
        let link = WatchLink(session: { session })
        func alert() -> WatchAlertMessage { WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date()) }
        let early = alert()
        link.send(early)
        XCTAssertTrue(session.queued.isEmpty, "held while the link activates")
        session.ready = true
        link.activationCompleted(.activated, on: session)
        XCTAssertEqual(session.queued, [early.eventID], "sent when activation completes")
        let next = alert()
        link.send(next)
        XCTAssertEqual(session.queued, [early.eventID, next.eventID], "sent at once from then on")
        link.becameInactive()   // the owner switches watches
        let during = alert()
        link.send(during)
        XCTAssertEqual(session.queued.count, 2, "held again")
        link.activationCompleted(.activated, on: session)
        XCTAssertEqual(session.queued.last, during.eventID)
    }

    /// With no watch ready when activation completes, what waited is dropped, not sent later.
    func testAlertsThatWaitedForNoWatchAreDropped() {
        let session = StandInWatchSession()
        let link = WatchLink(session: { session })
        link.send(WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date()))
        link.activationCompleted(.activated, on: session)   // not paired
        session.ready = true
        link.activationCompleted(.activated, on: session)
        XCTAssertTrue(session.queued.isEmpty)
    }

    // MARK: - Item 155's A10: a failed activation

    /// A failed activation keeps the alerts waiting for the next one, instead of dropping them.
    func testAFailedActivationKeepsTheAlertsWaiting() {
        var outbox = WatchLinkOutbox()
        let first = message()
        XCTAssertTrue(outbox.holdIfActivating(first))
        outbox.activationFailed(at: Date())
        let second = message()
        XCTAssertTrue(outbox.holdIfActivating(second), "still held after the failure")
        XCTAssertEqual(outbox.activationCompleted(watchReady: true), [first, second])
    }

    /// A retry is due only after a failure, and no sooner than its wait: 5 s after the first failure, doubling with each
    /// failure up to ten minutes; an attempt starts the wait again, and an activation ends the retries.
    func testARetryIsDueOnlyAfterAFailureAndItsWait() {
        var outbox = WatchLinkOutbox()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        XCTAssertFalse(outbox.retryDue(now: at(100)), "no failure, no retry")
        outbox.activationFailed(at: at(0))
        XCTAssertFalse(outbox.retryDue(now: at(4)), "not before its wait")
        XCTAssertTrue(outbox.retryDue(now: at(5)))
        XCTAssertFalse(outbox.retryDue(now: at(6)), "the attempt starts the wait again")
        outbox.activationFailed(at: at(6))
        XCTAssertFalse(outbox.retryDue(now: at(15)))
        XCTAssertTrue(outbox.retryDue(now: at(16)), "the wait doubles: 10 s")
        for failure in 1...12 { outbox.activationFailed(at: at(1_000 * Double(failure))) }
        XCTAssertFalse(outbox.retryDue(now: at(12_000 + 599)))
        XCTAssertTrue(outbox.retryDue(now: at(12_000 + 600)), "at most ten minutes")
        _ = outbox.activationCompleted(watchReady: true)
        XCTAssertFalse(outbox.retryDue(now: at(100_000)), "an activation ends the retries")
    }

    /// Through the link: alerts sent around a failed activation wait; the next send after the wait asks WatchConnectivity
    /// to activate again, and when it does, every waiting alert goes out.
    func testAFailedActivationIsRetriedOnTheNextSendAndTheAlertsGoOut() {
        let session = StandInWatchSession()
        session.ready = true
        var reactivations = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let link = WatchLink(session: { session }, reactivate: { reactivations += 1 }, now: { clock })
        func alert() -> WatchAlertMessage { WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date()) }
        let early = alert()
        link.send(early)
        session.state = .notActivated
        link.activationCompleted(.notActivated, on: session)   // the activation failed
        XCTAssertTrue(session.queued.isEmpty, "nothing goes out")
        clock = clock.addingTimeInterval(6)
        let later = alert()
        link.send(later)
        XCTAssertEqual(reactivations, 1, "the send after the wait asks again")
        XCTAssertTrue(session.queued.isEmpty, "held until the link activates")
        session.state = .activated
        link.activationCompleted(.activated, on: session)
        XCTAssertEqual(session.queued, [early.eventID, later.eventID], "both go out")
    }

    /// The app coming to the foreground asks again too, once the wait has passed.
    func testAForegroundRetriesAFailedActivation() {
        let session = StandInWatchSession()
        var reactivations = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let center = NotificationCenter()
        let link = WatchLink(session: { session }, reactivate: { reactivations += 1 }, now: { clock })
        link.observeForeground(center: center)
        session.state = .notActivated
        link.activationCompleted(.notActivated, on: session)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(reactivations, 0, "not before the wait")
        clock = clock.addingTimeInterval(5)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(reactivations, 1)
    }

    // MARK: - Finding 5: once per event across restarts

    /// The watch remembers the relayed alerts it showed, the newest `rememberedRelayLimit`, so a copy
    /// arriving after the app restarted is recognized.
    func testTheWatchRemembersTheAlertsItShowed() {
        var ids: [String] = []
        for number in 0..<(WatchAlertStatus.rememberedRelayLimit + 10) {
            ids = WatchAlertStatus.remembering("id\(number)", in: ids)
        }
        XCTAssertEqual(ids.count, WatchAlertStatus.rememberedRelayLimit)
        XCTAssertEqual(ids.last, "id\(WatchAlertStatus.rememberedRelayLimit + 9)")
        XCTAssertFalse(ids.contains("id0"), "the oldest give way")
        XCTAssertEqual(WatchAlertStatus.remembering(ids[3], in: ids), ids, "one already remembered changes nothing")
    }

    // The memory across launches: since 1.8 (73) the watch's `WatchRelayInbox` holds it (ADR 0051),
    // and relaunches are run through the inbox (Item134WatchSummaryTests
    // .testASummaryCarriesOnAcrossWakesAndRelaunches, .testTheRecordTakesTheAlertsAnEarlierBuildRemembered).

    // MARK: - Finding 6: a held wake always ends

    /// A failed activation ends the wake: nothing more can arrive.
    func testAFailedActivationEndsTheWake() {
        XCTAssertTrue(WatchAlertStatus.mayEndLinkWake(activated: false, contentPending: false, alertsInFlight: 0,
                                                      activationFailed: true))
        XCTAssertFalse(WatchAlertStatus.mayEndLinkWake(activated: false, contentPending: false, alertsInFlight: 0,
                                                       activationFailed: false), "still activating: held")
    }

    /// Each held wake gets an expiration handler, and the activation result reaches the rule.
    func testEachHeldWakeCanExpire() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        XCTAssertTrue(delegate.contains("linkTask.expirationHandler"))
        XCTAssertTrue(delegate.contains("activationFailed:"))
    }
}

/// A WatchConnectivity session for tests (the test-suite audit's P4): `ready` means a paired watch
/// with the app installed; `queued` and `sentNow` are what the link handed it, by event.
final class StandInWatchSession: WatchSessionPort {
    var ready = false
    /// The session's activation state: activated unless a test says otherwise (item 155's A10).
    var state: WCSessionActivationState = .activated
    private(set) var queued: [UUID] = []
    private(set) var sentNow: [UUID] = []
    var activationState: WCSessionActivationState { state }
    var isPaired: Bool { ready }
    var isWatchAppInstalled: Bool { ready }
    var isReachable: Bool { ready }
    func sendNow(_ userInfo: [String: Any]) {
        if let message = WatchAlertMessage(userInfo: userInfo) { sentNow.append(message.eventID) }
    }
    func queue(_ userInfo: [String: Any]) {
        if let message = WatchAlertMessage(userInfo: userInfo) { queued.append(message.eventID) }
    }
}
