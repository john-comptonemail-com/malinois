import XCTest
import UserNotifications
@testable import Malinois

final class NotificationEnrollmentTests: XCTestCase {
    func testUnenrolledExtensionDeliversGenericAlertUnchanged() {
        let content = UNMutableNotificationContent()
        content.title = "Malinois"
        content.body = "Tamper detected on your device."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["ck": ["rid": "private-record", "cid": "private-container"]]
        let request = UNNotificationRequest(identifier: "generic-test", content: content, trigger: nil)
        let service = NotificationService()
        var delivered: UNNotificationContent?
        var calls = 0
        service.didReceive(request) { result in
            delivered = result
            calls += 1
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(delivered?.title, content.title)
        XCTAssertEqual(delivered?.body, content.body)
        XCTAssertEqual(delivered?.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(delivered?.sound)
        XCTAssertEqual(delivered?.userInfo as NSDictionary?, content.userInfo as NSDictionary)
    }

    func testDisarmAlertNeedsNoRecordFetchOrDelayedCallback() {
        let content = UNMutableNotificationContent()
        content.body = "Malinois was disarmed on one of your devices."
        let request = UNNotificationRequest(identifier: "disarm-test", content: content, trigger: nil)
        var bodies: [String] = []
        NotificationService().didReceive(request) { bodies.append($0.body) }
        XCTAssertEqual(bodies, [content.body])
    }
}
