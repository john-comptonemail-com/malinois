//
//  Item57TimeSensitiveTests.swift
//  MalinoisTests
//
//  The 1.6 review's finding 3, ruled by the owner (2026-10-12, "B, go ahead"; ADR 0045). Since 1.5.1
//  the generic iCloud alerts arrive at the ordinary level: a subscription cannot ask for Time
//  Sensitive, and the alert extension passes alerts through, so a Focus could hold a tamper alert.
//  Tamper alerts are Time Sensitive again, as 1.4's and 1.5's were (the owner's ruling, 2026-09-28):
//  on the iPhone the extension raises the level for the tamper subscription's alerts, decided from
//  the push alone with no record read (ADR 0039); on the watch the relayed tamper alert asks for it,
//  under the watch app's own Time Sensitive capability. Disarm alerts keep the ordinary level.
//  Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
import UserNotifications
@testable import Malinois

final class Item57TimeSensitiveTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A push as CloudKit sends a query subscription's alert: the alert, and the subscription that sent it.
    private func push(subscriptionID: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Malinois"
        content.body = body
        content.sound = .default
        content.userInfo = ["aps": ["alert": ["body": body], "mutable-content": 1, "sound": "default"],
                            "ck": ["ce": 2, "cid": "iCloud.com.johncompton.Malinois", "nid": UUID().uuidString,
                                   "qry": ["dbs": 2, "fo": 1, "rid": UUID().uuidString, "sid": subscriptionID,
                                           "zid": "_defaultZone", "zoid": "_defaultOwner"]]]
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    /// What the extension delivers, once it has read the device's list (since 1.8.2 it counts the tamper alerts there,
    /// ADR 0061), so the test waits for its answer.
    private func delivered(_ request: UNNotificationRequest) -> UNNotificationContent? {
        // No earlier test's burst (item 169's codex-3), nor its running burst (item 170's codex-5).
        for key in [AlertBurst.arrivalsKey, AlertBurst.burstKey(AlertBurst.arrivalsKey)] { UserDefaults.standard.removeObject(forKey: key) }
        let answered = expectation(description: "the extension delivered the alert")
        var result: UNNotificationContent?
        NotificationService().didReceive(request) { result = $0; answered.fulfill() }
        wait(for: [answered], timeout: 5)
        return result
    }

    /// The rule: the tamper subscription's alerts are Time Sensitive; the disarm alert's and anything
    /// else's are not.
    func testOnlyTheTamperSubscriptionsAlertsAreTimeSensitive() {
        let tamper = CloudExfiltrator.makeTamperSubscription().subscriptionID
        XCTAssertEqual(NotificationService.tamperSubscriptionID, tamper, "the extension knows the tamper subscription")
        XCTAssertTrue(NotificationService.isTimeSensitive(subscriptionID: tamper))
        XCTAssertFalse(NotificationService.isTimeSensitive(subscriptionID: CloudExfiltrator.makeDisarmSubscription().subscriptionID))
        XCTAssertFalse(NotificationService.isTimeSensitive(subscriptionID: nil))
    }

    /// On the iPhone a tamper push is delivered Time Sensitive, its words and sound as sent.
    func testTheExtensionDeliversTamperAlertsTimeSensitive() throws {
        let request = push(subscriptionID: CloudExfiltrator.makeTamperSubscription().subscriptionID,
                           body: "Tamper detected on your device.")
        let result = try XCTUnwrap(delivered(request))
        XCTAssertEqual(result.interruptionLevel, .timeSensitive)
        XCTAssertEqual(result.title, request.content.title)
        XCTAssertEqual(result.body, request.content.body)
        XCTAssertNotNil(result.sound)
    }

    /// A disarm push keeps the ordinary level.
    func testTheExtensionLeavesTheDisarmAlertOrdinary() throws {
        let request = push(subscriptionID: CloudExfiltrator.makeDisarmSubscription().subscriptionID,
                           body: "Malinois was disarmed on one of your devices.")
        XCTAssertEqual(try XCTUnwrap(delivered(request)).interruptionLevel, .active)
    }

    /// On the watch the relayed tamper alert asks for Time Sensitive and the disarm alert does not, and
    /// the watch app holds the capability in both of its entitlement files. Since 1.8 (73) the watch's
    /// `WatchRelayInbox` builds the alert (ADR 0051), so it is asked here directly.
    func testTheWatchShowsRelayedTamperAlertsTimeSensitive() throws {
        let tamper = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: Date())
        let disarm = WatchAlertMessage(kind: .disarm, eventID: UUID(), at: Date())
        XCTAssertTrue(tamper.isTimeSensitive)
        XCTAssertFalse(disarm.isTimeSensitive)
        XCTAssertEqual(WatchRelayInbox.request(for: tamper, now: Date()).content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(WatchRelayInbox.request(for: disarm, now: Date()).content.interruptionLevel, .active)
        for file in ["MalinoisWatch/MalinoisWatch.entitlements", "MalinoisWatch/MalinoisWatch-Release.entitlements"] {
            XCTAssertTrue(try text(file).contains("<key>com.apple.developer.usernotifications.time-sensitive</key>"), file)
        }
    }
}
