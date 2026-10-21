//
//  Item57WatchDeliveryTests.swift
//  MalinoisTests
//
//  BACKLOG 57, after TestFlight 1.6 (60) (owner, 2026-10-12). With the watch's Bluetooth off on a
//  guest Wi-Fi, its own iPhone's tamper alert never reached the watch while the disarm alert came
//  15 s later; with the phone on cellular both came at once. Three changes follow. The watch app
//  holds each background wake until every alert the link handed over is posted: the link reports
//  nothing pending as soon as it has handed an alert over, and a wake ended then can lose the
//  alert. The watch screen says which path brought the last alert. A relayed alert that arrives
//  late names the event's time, so a copy that waited for the watch to come back in range does not
//  read as a new event. Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

final class Item57WatchDeliveryTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private typealias Checks = WatchAlertStatus.Checks

    // MARK: - The background wake

    /// A wake ends only once the link is up, has handed over everything queued, and every alert it
    /// handed over has been posted.
    func testAWakeEndsOnlyAfterEveryDeliveredAlertIsPosted() {
        XCTAssertTrue(WatchAlertStatus.mayEndLinkWake(activated: true, contentPending: false, alertsInFlight: 0))
        XCTAssertFalse(WatchAlertStatus.mayEndLinkWake(activated: true, contentPending: false, alertsInFlight: 1),
                       "an alert handed over but not yet posted holds the wake")
        XCTAssertFalse(WatchAlertStatus.mayEndLinkWake(activated: true, contentPending: true, alertsInFlight: 0))
        XCTAssertFalse(WatchAlertStatus.mayEndLinkWake(activated: false, contentPending: false, alertsInFlight: 0))
    }

    /// The watch counts each alert before the link's callback returns, uncounts it once posted, and
    /// ends a wake only through that rule.
    func testTheWatchCountsEachAlertUntilItIsPosted() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        let receive = try XCTUnwrap(delegate.range(of: "didReceiveUserInfo userInfo: [String: Any]) {"))
        let body = delegate[receive.upperBound...].prefix(900)
        let count = try XCTUnwrap(body.range(of: "alertsInFlight.withLock { $0 += 1 }"), "counted in the callback")
        let task = try XCTUnwrap(body.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(count.lowerBound, task.lowerBound, "counted before the callback returns")
        XCTAssertTrue(body.contains("alertsInFlight.withLock { $0 -= 1 }"), "uncounted once posted")
        XCTAssertTrue(delegate.contains("WatchAlertStatus.mayEndLinkWake("), "wakes end through the rule")
    }

    // MARK: - Which path brought the last alert

    /// The iPhone link's alerts carry their own notification identifiers; anything else came through
    /// iCloud.
    func testTheWatchTellsTheTwoPathsApart() {
        let relayed = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date())
        XCTAssertEqual(WatchAlertStatus.source(ofNotification: relayed.notificationIdentifier), .iPhoneLink)
        XCTAssertEqual(WatchAlertStatus.source(ofNotification: UUID().uuidString), .iCloud)
    }

    /// The screen names the path when it is known.
    func testTheScreenSaysWhichPathBroughtTheLastAlert() {
        var checks = Checks(registration: .registered, account: .available, notifications: .allowed,
                            subscriptions: .found, link: .ready)
        checks.lastAlert = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertFalse(WatchAlertStatus.describe(checks).lines.contains { $0.hasPrefix("Last alert came through") },
                       "no path line while the path is unknown")
        checks.lastAlertSource = .iPhoneLink
        XCTAssertEqual(WatchAlertStatus.describe(checks).lines.last, "Last alert came through: iPhone link")
        checks.lastAlertSource = .iCloud
        XCTAssertEqual(WatchAlertStatus.describe(checks).lines.last, "Last alert came through: iCloud")
    }

    /// When it opens, the watch reads its delivered alerts to learn the newest one and its path.
    func testTheWatchReadsItsDeliveredAlertsWhenOpened() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        XCTAssertTrue(delegate.contains("deliveredNotifications()"))
        XCTAssertTrue(delegate.contains("WatchAlertStatus.source(ofNotification:"))
    }

    // MARK: - Late alerts

    /// Late, the iCloud alert's fixed text with the event's time. Since 1.8 (73) on time too: every
    /// relayed alert names its event's time (BACKLOG 134, ADR 0051). Alert text: no em-dash (B16).
    func testALateRelayedAlertSaysWhenItHappened() throws {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for kind in [WatchAlertMessage.Kind.tamper, .disarm] {
            let message = WatchAlertMessage(kind: kind, eventID: UUID(), at: at)
            XCTAssertEqual(message.body(deliveredAt: at.addingTimeInterval(30)),
                           "\(message.body.dropLast()) at \(at.formatted(date: .omitted, time: .shortened)).",
                           "on time: with the time too")
            let late = message.body(deliveredAt: at.addingTimeInterval(600))
            XCTAssertNotEqual(late, message.body)
            XCTAssertTrue(late.hasPrefix(String(message.body.dropLast())), late)
            XCTAssertTrue(late.contains(" at "), late)
            XCTAssertTrue(late.hasSuffix("."), late)
            XCTAssertFalse(late.contains("\u{2014}"), late)
        }
        // Since 1.8 (73) the watch's `WatchRelayInbox` builds the alert (ADR 0051): asked here directly.
        let message = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: at)
        XCTAssertEqual(WatchRelayInbox.request(for: message, now: at.addingTimeInterval(600)).content.body,
                       message.body(deliveredAt: at.addingTimeInterval(600)), "the watch shows that form")
    }
}
