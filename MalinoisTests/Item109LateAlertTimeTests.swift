//
//  Item109LateAlertTimeTests.swift
//  MalinoisTests
//
//  BACKLOG 109. Build 66 tried to put a late iCloud alert's time in the push: the tamper and disarm
//  records carried the event's time in one field in the clear, and the alert subscriptions asked
//  CloudKit to include it (`desiredKeys`). On the owner's devices (2026-10-13), with the field
//  deployed to Production, iCloud then sent no alert pushes at all: the iPad and the watch off
//  Bluetooth got nothing, while every record synced; 65 alerted at once. 1.6 (67) removes it (the
//  owner's ruling, "go"), and these tests keep it out until a design is proven on devices first:
//  every custom field is encrypted again, the subscriptions ask for no field, and the extension
//  leaves the alert's words as sent. The Pro welcome keeps 66's encryption correction, without the
//  time. Written before the change, red at that commit (against 66's code).
//

import XCTest
import CloudKit
import UserNotifications
@testable import Malinois

final class Item109LateAlertTimeTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The source between `start` and the next `end` marker, for checks on one function.
    private func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let begin = try XCTUnwrap(source.range(of: start), start)
        let rest = source[begin.upperBound...]
        let stop = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return rest[..<stop]
    }

    private let occurred = Date(timeIntervalSince1970: 1_760_380_920)
    private let tamperText = "Tamper detected on your device."
    private let disarmText = "Malinois was disarmed on one of your devices."

    /// The fields a record holds in the clear: the plain subscript cannot see an encrypted value.
    private func clearKeys(_ record: CKRecord) -> Set<String> {
        Set(record.allKeys().filter { record[$0] != nil })
    }

    private func tempFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The tamper and disarm records hold nothing in the clear but the thumbnail, which a CKAsset has
    /// to be: 66's time field stopped iCloud sending the alert.
    func testTheAlertRecordsHoldNoFieldInTheClear() throws {
        let tamper = Event(startDate: occurred, endDate: occurred.addingTimeInterval(4), triggeredSensors: [.touch])
        let meta = CloudExfiltrator.makeMetaRecord(tamper, deviceName: "John's iPhone",
                                                   thumbnailURL: try tempFile("item109-thumb.jpg"))
        XCTAssertEqual(clearKeys(meta), ["thumbnail"])
        let disarm = Event(startDate: occurred, endDate: occurred, triggeredSensors: [], stateChange: "disarmed")
        XCTAssertEqual(clearKeys(CloudExfiltrator.makeDisarmSignalRecord(disarm, deviceName: "John's iPhone")), [])
    }

    /// The alert subscriptions ask for no record field in the push.
    func testTheSubscriptionsAskForNoField() {
        for subscription in [CloudExfiltrator.makeTamperSubscription(), CloudExfiltrator.makeDisarmSubscription()] {
            XCTAssertTrue(subscription.notificationInfo?.desiredKeys?.isEmpty ?? true, subscription.subscriptionID)
            XCTAssertTrue(subscription.notificationInfo?.shouldSendMutableContent == true, "still mutable (item 76)")
        }
    }

    /// The extension leaves a late alert's words as sent, even from a push that carried a time (a
    /// subscription saved by 66): the tamper alert is still Time Sensitive, the disarm alert ordinary.
    func testTheExtensionLeavesTheWordsAsSent() throws {
        func push(_ subscriptionID: String, _ body: String) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = "Malinois"
            content.body = body
            content.sound = .default
            content.userInfo = ["aps": ["alert": ["body": body], "mutable-content": 1, "sound": "default"],
                                "ck": ["ce": 2, "cid": "iCloud.com.johncompton.Malinois", "nid": UUID().uuidString,
                                       "qry": ["dbs": 2, "fo": 1, "rid": UUID().uuidString, "sid": subscriptionID,
                                               "zid": "_defaultZone", "zoid": "_defaultOwner",
                                               "af": ["occurredAt": Int64(Date().timeIntervalSince1970 - 300)]]]]
            return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        }
        func delivered(_ request: UNNotificationRequest) -> UNNotificationContent? {
            var result: UNNotificationContent?
            NotificationService().didReceive(request) { result = $0 }
            return result
        }
        let tamper = try XCTUnwrap(delivered(push(CloudExfiltrator.makeTamperSubscription().subscriptionID, tamperText)))
        XCTAssertEqual(tamper.body, tamperText)
        XCTAssertEqual(tamper.interruptionLevel, .timeSensitive)
        let disarm = try XCTUnwrap(delivered(push(CloudExfiltrator.makeDisarmSubscription().subscriptionID, disarmText)))
        XCTAssertEqual(disarm.body, disarmText)
        XCTAssertEqual(disarm.interruptionLevel, .active)
    }

    /// The Pro welcome says Apple can't read the data only with Advanced Data Protection on (65 said
    /// event details were always end-to-end encrypted, which SECURITY.md contradicts), with no time clause.
    func testTheProWelcomeKeepsTheEncryptionCorrection() throws {
        let onboarding = try text("Malinois/Views/OnboardingViews.swift")
        let note = try section(onboarding, from: "private var closingNote: String {", to: "case .earlyAccess:")
        XCTAssertTrue(note.contains("the developer can't read them, and with Advanced Data Protection on, neither can Apple."))
        XCTAssertFalse(note.contains("end-to-end encrypted"))
        XCTAssertFalse(note.contains("apart from when each happened"))
    }
}
