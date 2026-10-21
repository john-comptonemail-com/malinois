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
//

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

    /// The link holds through the outbox and releases it when activation completes.
    func testTheLinkHoldsAlertsUntilActivationCompletes() throws {
        let relay = try text("Malinois/Services/WatchAlertRelay.swift")
        XCTAssertTrue(relay.contains("holdIfActivating(message)"))
        XCTAssertTrue(relay.contains("activationCompleted(watchReady:"))
        XCTAssertTrue(relay.contains("sessionBecameInactive()"))
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

    /// The memory is kept on the watch across launches and consulted before an alert is shown.
    /// Since 1.6 (65) it lives in `WatchAlertStatus.RelayLedger`, which remembers an alert only once
    /// posted (item 108, CE-03; its rule is tested in Item108ReviewTests). Since 1.8 (73) the watch's
    /// `WatchRelayInbox` holds it (ADR 0051), and a relaunch is driven through the inbox in
    /// Item134WatchSummaryTests.
    func testTheWatchKeepsThatMemoryAcrossLaunches() throws {
        let inbox = try text("MalinoisWatch/WatchRelayInbox.swift")
        XCTAssertTrue(inbox.contains("stringArray(forKey: Self.shownRelayIDsKey)"), "read at launch")
        XCTAssertTrue(inbox.contains("defaults.set(ledger.shown, forKey: Self.shownRelayIDsKey)"), "kept after a post")
        XCTAssertTrue(inbox.contains("ledger.begin("), "consulted before an alert is shown")
        XCTAssertTrue(try text("MalinoisWatch/WatchAppDelegate.swift").contains("relayInbox.receive(message)"),
                      "the watch app hands each relayed alert to the inbox")
    }

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
