//
//  Item76AlertRewriteTests.swift
//  MalinoisTests
//
//  Tests for BACKLOG 76: the receiving iPhone words a cross-device alert from the record it
//  names, instead of the subscription's one static sentence. The owner's rulings (2026-09-28,
//  "all as recommended"): a Vision-only trip is a banner without sound; every other tamper
//  alert is Time Sensitive; the disarm alert names the device; the title names the device; a
//  failure anywhere shows the push as sent. The words come from the Event Log's own wording
//  (`Event.sensorSummary`), so an alert and the log never disagree.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item76AlertRewriteTests: XCTestCase {

    private func event(_ sensors: [SensorType], interrupted: Bool? = nil, cause: String? = nil,
                       wrongPINs: Int? = nil) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: sensors, cloudSyncState: .synced,
              interrupted: interrupted, interruptionCause: cause, wrongPINCount: wrongPINs)
    }

    // MARK: - Tamper alerts

    /// A trip names its tripwires and the device, with sound, and breaks through a Focus.
    func testATripNamesTheTripwiresAndTheDeviceAndIsTimeSensitive() {
        let alert = AlertRewrite.forTamper(event([.motion, .touch]), deviceName: "iPhone Air")
        XCTAssertEqual(alert.title, "Malinois: iPhone Air")
        XCTAssertEqual(alert.body, "Tamper detected: Device motion, Touch.")
        XCTAssertTrue(alert.playsSound)
        XCTAssertTrue(alert.timeSensitive)
    }

    /// A trip seen only by the camera (a shadow, a cat) is a banner without sound, at the
    /// ordinary level.
    func testAVisionOnlyTripIsABannerWithoutSound() {
        let alert = AlertRewrite.forTamper(event([.vision]), deviceName: "iPhone Air")
        XCTAssertEqual(alert.body, "The camera saw movement.")
        XCTAssertFalse(alert.playsSound, "no sound for what may be a cat")
        XCTAssertFalse(alert.timeSensitive)
        XCTAssertEqual(alert.title, "Malinois: iPhone Air")
    }

    /// Vision with any other tripwire is a full alert.
    func testVisionWithAnotherTripwireIsAFullAlert() {
        let decoded = AlertRewrite.tamperEvent(sensorsField: "vision,motion", metadataJSON: nil, startDate: nil)
        let alert = AlertRewrite.forTamper(decoded, deviceName: "iPhone Air")
        XCTAssertEqual(alert.body, "Tamper detected: Device motion, Vision.")
        XCTAssertTrue(alert.playsSound)
        XCTAssertTrue(alert.timeSensitive)
    }

    /// An interruption and a wrong PIN read as the Event Log reads them, as full alerts.
    func testAnInterruptionAndAWrongPINReadAsTheLogReadsThem() {
        let interrupted = AlertRewrite.forTamper(event([], interrupted: true, cause: "rebooted"), deviceName: "iPhone Air")
        XCTAssertEqual(interrupted.body, "Monitoring interrupted: the device restarted while armed.")
        XCTAssertTrue(interrupted.playsSound)
        XCTAssertTrue(interrupted.timeSensitive)
        let wrongPIN = AlertRewrite.forTamper(event([.touch], wrongPINs: 2), deviceName: "iPhone Air")
        XCTAssertEqual(wrongPIN.body, "Wrong PIN entered 2 times.")
        XCTAssertTrue(wrongPIN.timeSensitive)
    }

    /// The title falls back to the app's name without a usable device name, and a long one is cut.
    func testTheTitleFallsBackAndIsBounded() {
        XCTAssertEqual(AlertRewrite.forTamper(event([.touch]), deviceName: nil).title, "Malinois")
        XCTAssertEqual(AlertRewrite.forTamper(event([.touch]), deviceName: "   ").title, "Malinois")
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(AlertRewrite.forTamper(event([.touch]), deviceName: long).title,
                       "Malinois: " + String(repeating: "x", count: 64))
    }

    /// The device's name is the only text an alert takes from the record, and the record is cloud
    /// input: someone holding the owner's iCloud password can write one. The name is shown as one
    /// line of ordinary characters, so it cannot add a line of its own to the alert or turn its
    /// text around; an emoji sequence stays whole. (A follow-up from Claude's review of item 76,
    /// written before its fix and red at that commit.)
    func testTheDeviceNameIsOneLineOfOrdinaryCharacters() {
        let crafted = "iPhone\nApple ID locked.\r\n\tCall now"
        XCTAssertEqual(AlertRewrite.forDisarm(deviceName: crafted).title,
                       "Malinois: iPhone Apple ID locked. Call now")
        XCTAssertEqual(AlertRewrite.forTamper(event([.touch]), deviceName: "iPhone\u{202E}riA").title,
                       "Malinois: iPhoneriA", "no character that turns the text around")
        XCTAssertEqual(AlertRewrite.title(deviceName: "Air\u{0007}\u{2028}Pro"), "Malinois: Air Pro")
        XCTAssertEqual(AlertRewrite.title(deviceName: "\u{202E}\u{2066}"), "Malinois", "nothing ordinary left")
        let family = "👨\u{200D}👩\u{200D}👧 iPad"
        XCTAssertEqual(AlertRewrite.title(deviceName: family), "Malinois: " + family)
    }

    // MARK: - The disarm alert

    /// The disarm alert names the device in its title, and its body says it once (the owner's
    /// ruling, 2026-09-28); without a name it keeps today's sentence.
    func testTheDisarmAlertNamesTheDevice() {
        let alert = AlertRewrite.forDisarm(deviceName: "iPhone Air")
        XCTAssertEqual(alert.body, "Malinois was disarmed.", "the title names the device; the body says it once")
        XCTAssertEqual(alert.title, "Malinois: iPhone Air")
        XCTAssertTrue(alert.playsSound)
        XCTAssertFalse(alert.timeSensitive, "the owner's ruling makes tamper alerts Time Sensitive, not disarms")
        XCTAssertEqual(AlertRewrite.forDisarm(deviceName: nil).body, "Malinois was disarmed on one of your devices.")
    }

    // MARK: - What the extension reads

    /// The extension decodes only what an alert shows: the tripwires (unknown ones dropped,
    /// sorted as the log's decoder sorts them) and, from the metadata, an interruption and its
    /// cause, a wrong-PIN count and a flood count, each bounded or allow-listed.
    func testTheDecoderReadsWhatTheAlertNeeds() {
        let json = #"{"interrupted":true,"interruptionCause":"terminated","wrongPINCount":3,"sustainedCount":5}"#
        let decoded = AlertRewrite.tamperEvent(sensorsField: "touch,bogus,motion", metadataJSON: json, startDate: nil)
        XCTAssertEqual(decoded.triggeredSensors, [.motion, .touch])
        XCTAssertEqual(decoded.interrupted, true)
        XCTAssertEqual(decoded.interruptionCause, "terminated")
        XCTAssertEqual(decoded.wrongPINCount, 3)
        XCTAssertEqual(decoded.sustainedCount, 5)
        let hostile = AlertRewrite.tamperEvent(sensorsField: nil,
                                               metadataJSON: #"{"interruptionCause":"made-up","wrongPINCount":-4,"sustainedCount":0}"#,
                                               startDate: nil)
        XCTAssertNil(hostile.interruptionCause, "an unknown cause is dropped")
        XCTAssertNil(hostile.wrongPINCount, "a count below one is dropped")
        XCTAssertNil(hostile.sustainedCount)
        XCTAssertNil(AlertRewrite.tamperEvent(sensorsField: "motion", metadataJSON: "not json", startDate: nil).interrupted)
    }

    /// The extension reads from the app's container: its bundle id is the app's plus one part.
    func testTheExtensionFindsTheAppsContainer() {
        XCTAssertEqual(AlertRewrite.appContainerIdentifier(extensionBundleID: "com.johncompton.Malinois.NotificationService"),
                       "iCloud.com.johncompton.Malinois")
        XCTAssertNil(AlertRewrite.appContainerIdentifier(extensionBundleID: nil))
        XCTAssertNil(AlertRewrite.appContainerIdentifier(extensionBundleID: "nodots"))
    }

    /// The record types the extension recognizes are the ones the app writes and subscribes to.
    func testTheRecordTypesMatchWhatTheAppWrites() {
        XCTAssertEqual(AlertRewrite.pushedRecord(ofType: CloudExfiltrator.metaRecordTypeV2), .tamper)
        XCTAssertEqual(AlertRewrite.pushedRecord(ofType: CloudExfiltrator.disarmSignalRecordTypeV2), .disarm)
        XCTAssertNil(AlertRewrite.pushedRecord(ofType: CloudExfiltrator.stateRecordTypeV2), "audit records raise no alert")
    }

    /// No alert text carries an em-dash (screen text).
    func testNoAlertTextHasAnEmDash() {
        let alerts = [AlertRewrite.forTamper(event([.motion, .touch]), deviceName: "iPhone Air"),
                      AlertRewrite.forTamper(event([.vision]), deviceName: "iPhone Air"),
                      AlertRewrite.forTamper(event([], interrupted: true, cause: "terminated"), deviceName: nil),
                      AlertRewrite.forDisarm(deviceName: "iPhone Air")]
        for alert in alerts {
            XCTAssertFalse((alert.title + alert.body).contains("\u{2014}"), alert.body)
        }
    }

    // MARK: - The subscriptions

    /// Both subscriptions ask for mutable pushes, so the receiving iPhone's extension runs, and
    /// still wake the app to pull the record in.
    func testBothSubscriptionsAskForMutablePushes() {
        for subscription in [CloudExfiltrator.makeTamperSubscription(), CloudExfiltrator.makeDisarmSubscription()] {
            XCTAssertEqual(subscription.notificationInfo?.shouldSendMutableContent, true, subscription.subscriptionID)
            XCTAssertEqual(subscription.notificationInfo?.shouldSendContentAvailable, true)
        }
    }

    /// An account's existing subscriptions are upgraded in place: the same IDs, saved again when
    /// they do not send mutable pushes, so a device still on 1.3.x (which only creates missing
    /// IDs) never adds a second copy and a second alert.
    func testSubscriptionsAreUpgradedInPlace() {
        let tamperID = CloudExfiltrator.makeTamperSubscription().subscriptionID
        let disarmID = CloudExfiltrator.makeDisarmSubscription().subscriptionID
        XCTAssertEqual(CloudExfiltrator.subscriptionsToSave(existing: [:]).map(\.subscriptionID), [tamperID, disarmID])
        XCTAssertEqual(CloudExfiltrator.subscriptionsToSave(existing: [tamperID: false, disarmID: true]).map(\.subscriptionID),
                       [tamperID], "a 1.3.x subscription is saved again, under its own ID")
        XCTAssertTrue(CloudExfiltrator.subscriptionsToSave(existing: [tamperID: true, disarmID: true]).isEmpty)
    }

    // MARK: - The project

    /// The extension ships the app's version and build number: App Store validation rejects an
    /// upload whose extension disagrees, and nothing else ties the two targets' settings together.
    func testTheExtensionShipsTheAppsVersionAndBuild() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Malinois.xcodeproj/project.pbxproj")
        guard let text = try? String(contentsOf: project, encoding: .utf8) else {
            throw XCTSkip("the project file is not readable from this test run")
        }
        func setting(_ key: String, inConfig id: String) -> String? {
            guard let start = text.range(of: "\t\t\(id) /* ") else { return nil }
            let rest = text[start.upperBound...]
            guard let end = rest.range(of: "\t\t\tname = ") else { return nil }
            let block = rest[..<end.lowerBound]
            guard let line = block.split(separator: "\n").first(where: { $0.contains("\(key) = ") }) else { return nil }
            return line.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        }
        let pairs = [("C1C2C3D4E5F6000000000109", "71B2C3D4E5F6000000000051"),   // Debug: app, extension
                     ("C1C2C3D4E5F600000000010A", "71B2C3D4E5F6000000000052")]   // Release
        for (app, ext) in pairs {
            for key in ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"] {
                let appValue = try XCTUnwrap(setting(key, inConfig: app), "\(key) in the app's \(app)")
                XCTAssertEqual(setting(key, inConfig: ext), appValue, "\(key): the extension must match the app")
            }
        }
    }
}
