//
//  Item153AlertBurstTests.swift
//  MalinoisTests
//
//  Item 153's MAL-04 (BACKLOG 163's step 16; the owner: "16 - 1"; ADR 0061). After "Delete Data from iCloud" the phone
//  uploads its records again, and each one fires the tamper subscription: check C on 1.8.1 (2026-10-27) brought the
//  owner's iPad one Time Sensitive alert per record, 334 of them. Now the alert extensions, the iPhone's and the
//  watch's, count the tamper alerts already in their list: once three have come within a minute, the rest come
//  quietly (no sound, not Time Sensitive) and say they are one of many, while each follows the one before by less
//  than two and a half minutes. Written before the rule, red at that commit (the two controls added with the fix: alerts
//  dated after now, and which alerts are counted). Each part of the rule has its own test:
//  three in a minute start a burst, three spread wider start none, a burst goes on across waits shorter than the gap
//  and ends after a longer one, and only tamper alerts are counted or quieted.
//  Item 169's codex-3 (BACKLOG 163's step 51; the owner: "1 - yes"): the extensions counted the tamper alerts still in
//  their list, which the owner's clearing and, on the watch, the app's own tidy-up empty, so a re-upload of events the
//  watch had seen relayed stayed loud; and relayed alerts under an hour old were never counted. Now each path keeps its
//  own short record of tamper arrivals: the iPhone's and iPad's extension, the watch's, and the watch app for the
//  alerts its iPhone relays. Written before the change, red at that commit.
//

import UserNotifications
import XCTest
@testable import Malinois

@MainActor
final class Item153AlertBurstTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: [TimeInterval]) -> [Date] {
        seconds.map { now.addingTimeInterval(-$0) }
    }

    // MARK: - The rule

    /// The first three tamper alerts of any run alert as before.
    func testTheFirstThreeOfABurstAlertAsBefore() {
        XCTAssertFalse(AlertBurst.isQuiet(earlierArrivals: [], now: now))
        XCTAssertFalse(AlertBurst.isQuiet(earlierArrivals: ago([10]), now: now))
        XCTAssertFalse(AlertBurst.isQuiet(earlierArrivals: ago([20, 10]), now: now))
    }

    /// Three within a minute start a burst: the fourth arrives quietly.
    func testTheFourthWithinAMinuteArrivesQuietly() {
        XCTAssertTrue(AlertBurst.isQuiet(earlierArrivals: ago([30, 20, 10]), now: now))
    }

    /// Three spread wider than a minute start no burst, though each follows the last within the gap.
    func testThreeSpreadWiderThanAMinuteStartNoBurst() {
        XCTAssertFalse(AlertBurst.isQuiet(earlierArrivals: ago([200, 100, 10]), now: now))
    }

    /// A burst goes on while each alert follows the one before by less than two and a half minutes, as a re-upload's
    /// passes do when iCloud makes the phone wait between them.
    func testABurstGoesOnAcrossWaitsShorterThanTheGap() {
        XCTAssertTrue(AlertBurst.isQuiet(earlierArrivals: ago([400, 390, 380, 250, 120]), now: now))
    }

    /// Two and a half minutes without a tamper alert end the burst: the next one alerts as before.
    func testABurstEndsAfterTheGap() {
        XCTAssertFalse(AlertBurst.isQuiet(earlierArrivals: ago([200, 190, 180]), now: now))
    }

    /// Alerts the list dates after now (a clock set back) start no burst.
    func testAlertsDatedAfterNowDoNotCount() {
        XCTAssertFalse(AlertBurst.isQuiet(earlierArrivals: ago([-30, -20, -10]), now: now))
    }

    /// The iPhone's extension counts only the tamper alerts in its list: a disarm alert is not one.
    func testOnlyTamperAlertsInTheListAreCounted() {
        let tamper = Self.push(subscriptionID: NotificationService.tamperSubscriptionID, body: Self.tamperBody)
        let disarm = Self.push(subscriptionID: CloudExfiltrator.makeDisarmSubscription().subscriptionID, body: Self.disarmBody)
        XCTAssertTrue(NotificationService.isTamperAlert(tamper.userInfo))
        XCTAssertFalse(NotificationService.isTamperAlert(disarm.userInfo))
        XCTAssertFalse(NotificationService.isTamperAlert([:]), "a local notification")
        // And the watch's: iCloud's tamper alerts only, not its disarm alerts or the relay's copies.
        XCTAssertTrue(WatchAlertPairing.isICloudTamperAlert(userInfo: tamper.userInfo))
        XCTAssertFalse(WatchAlertPairing.isICloudTamperAlert(userInfo: disarm.userInfo))
        XCTAssertFalse(WatchAlertPairing.isICloudTamperAlert(userInfo: [:]), "a relayed copy")
    }

    // MARK: - The iPhone's and iPad's alert extension

    /// A tamper alert that is one of many arrives passive, without sound, saying so; a lone one is Time Sensitive with
    /// its words as sent.
    func testTheIPhonesExtensionShowsABurstsTamperAlertQuietly() {
        let push = Self.push(subscriptionID: NotificationService.tamperSubscriptionID, body: Self.tamperBody)
        let quiet = NotificationService.leveled(push, earlierTamperArrivals: ago([30, 20, 10]), now: now)
        XCTAssertEqual(quiet.interruptionLevel, .passive)
        XCTAssertNil(quiet.sound)
        XCTAssertEqual(quiet.body, "Tamper detected on your device - one of many alerts arriving at once. The Event Log "
                       + "has each one.")
        let lone = NotificationService.leveled(push, earlierTamperArrivals: [], now: now)
        XCTAssertEqual(lone.interruptionLevel, .timeSensitive)
        XCTAssertEqual(lone.body, Self.tamperBody)
    }

    /// A disarm alert keeps its level and words whatever the list holds: only tamper alerts are quieted.
    func testTheIPhonesExtensionLeavesADisarmAlertAlone() {
        let push = Self.push(subscriptionID: CloudExfiltrator.makeDisarmSubscription().subscriptionID, body: Self.disarmBody)
        XCTAssertEqual(NotificationService.leveled(push, earlierTamperArrivals: ago([30, 20, 10]), now: now), push)
    }

    // MARK: - The watch's alert extension

    /// On the watch too, an iCloud tamper alert that is one of many arrives passive, without sound, saying so.
    func testTheWatchsExtensionShowsABurstsTamperAlertQuietly() {
        let push = Self.push(subscriptionID: WatchAlertPairing.tamperSubscriptionID, body: Self.tamperBody,
                             recordName: "meta-v2-" + UUID().uuidString)
        let quiet = WatchAlertPairing.iCloudContent(push, deliveredIdentifiers: [],
                                                    earlierTamperArrivals: ago([30, 20, 10]), now: now)
        XCTAssertEqual(quiet.interruptionLevel, .passive)
        XCTAssertNil(quiet.sound)
        XCTAssertEqual(quiet.body, AlertBurst.quietBody)
        let lone = WatchAlertPairing.iCloudContent(push, deliveredIdentifiers: [], earlierTamperArrivals: [], now: now)
        XCTAssertEqual(lone.interruptionLevel, .timeSensitive)
        XCTAssertEqual(lone.body, Self.tamperBody)
    }

    /// The watch's disarm alert from iCloud keeps its level and words in a burst too.
    func testTheWatchsExtensionLeavesADisarmAlertAlone() {
        let push = Self.push(subscriptionID: WatchAlertPairing.disarmSubscriptionID, body: Self.disarmBody,
                             recordName: "disarm-v2-" + UUID().uuidString)
        XCTAssertEqual(WatchAlertPairing.iCloudContent(push, deliveredIdentifiers: [],
                                                       earlierTamperArrivals: ago([30, 20, 10]), now: now), push)
    }

    // MARK: - Item 169's codex-3: each path's own record of arrivals

    /// The record keeps the last hour's arrivals, at most fifty, and drops any dated after now.
    func testTheArrivalRecordKeepsAnHourAndAtMostFifty() {
        XCTAssertEqual(AlertBurst.remembering(now, in: ago([4000, 3000, 10]) + [now.addingTimeInterval(60)]),
                       ago([3000, 10, 0]))
        let many = (1...60).map { now.addingTimeInterval(-Double($0)) }.reversed()
        let kept = AlertBurst.remembering(now, in: Array(many))
        XCTAssertEqual(kept.count, AlertBurst.memoryLimit)
        XCTAssertEqual(kept.last, now)
    }

    /// Four tamper alerts in a row through the iPhone's extension: the fourth arrives quietly, whatever the list holds.
    func testTheIPhonesExtensionCountsItsOwnRecordOfArrivals() async {
        // The record and its running burst (item 170's codex-5).
        for key in [AlertBurst.arrivalsKey, AlertBurst.burstKey(AlertBurst.arrivalsKey)] { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in [AlertBurst.arrivalsKey, AlertBurst.burstKey(AlertBurst.arrivalsKey)] { UserDefaults.standard.removeObject(forKey: key) } }
        let answers = Answers()
        for _ in 0..<4 {
            let push = Self.push(subscriptionID: NotificationService.tamperSubscriptionID, body: Self.tamperBody)
            let answered = expectation(description: "answered")
            NotificationService().didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: push,
                                                                   trigger: nil)) { content in
                answers.levels.append(content.interruptionLevel)
                answered.fulfill()
            }
            await fulfillment(of: [answered], timeout: 5)
        }
        XCTAssertEqual(answers.levels, [.timeSensitive, .timeSensitive, .timeSensitive, .passive])
    }

    /// The same through the watch's extension, which the watch app's tidy-up cannot reset.
    func testTheWatchsExtensionCountsItsOwnRecordOfArrivals() async {
        // The record and its running burst (item 170's codex-5).
        for key in [AlertBurst.arrivalsKey, AlertBurst.burstKey(AlertBurst.arrivalsKey)] { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in [AlertBurst.arrivalsKey, AlertBurst.burstKey(AlertBurst.arrivalsKey)] { UserDefaults.standard.removeObject(forKey: key) } }
        let answers = Answers()
        for _ in 0..<4 {
            let push = Self.push(subscriptionID: WatchAlertPairing.tamperSubscriptionID, body: Self.tamperBody,
                                 recordName: "meta-v2-" + UUID().uuidString)
            let answered = expectation(description: "answered")
            WatchNotificationService().didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: push,
                                                                        trigger: nil)) { content in
                answers.levels.append(content.interruptionLevel)
                answered.fulfill()
            }
            await fulfillment(of: [answered], timeout: 5)
        }
        XCTAssertEqual(answers.levels, [.timeSensitive, .timeSensitive, .timeSensitive, .passive])
    }

    /// Codex's probe: a 20-minute backlog of relayed tamper alerts, each under an hour old, taps three times, then
    /// arrives quietly, saying so.
    func testARelayedBacklogGoesQuietAfterThree() async throws {
        let relay = try RelayRig()
        defer { relay.cleanUp() }
        let start = relay.clock.addingTimeInterval(-1200)
        for n in 0..<20 {
            _ = await relay.inbox.receive(WatchAlertMessage(kind: .tamper, eventID: UUID(),
                                                            at: start.addingTimeInterval(Double(n) * 30)))
            relay.clock = relay.clock.addingTimeInterval(1)
        }
        XCTAssertEqual(relay.posted.count, 20)
        XCTAssertEqual(relay.posted.prefix(3).map(\.content.interruptionLevel), [.timeSensitive, .timeSensitive, .timeSensitive])
        XCTAssertTrue(relay.posted.dropFirst(3).allSatisfy { $0.content.interruptionLevel == .passive && $0.content.sound == nil },
                      "the rest quietly")
        XCTAssertEqual(relay.posted.last?.content.body, AlertBurst.quietBody)
    }

    /// Relayed disarm alerts are never quieted.
    func testRelayedDisarmAlertsAreNeverQuieted() async throws {
        let relay = try RelayRig()
        defer { relay.cleanUp() }
        for n in 0..<5 {
            _ = await relay.inbox.receive(WatchAlertMessage(kind: .disarm, eventID: UUID(),
                                                            at: relay.clock.addingTimeInterval(-Double(60 - n))))
            relay.clock = relay.clock.addingTimeInterval(1)
        }
        XCTAssertEqual(relay.posted.count, 5)
        XCTAssertFalse(relay.posted.contains { $0.content.interruptionLevel == .passive })
    }

    /// What a test's extensions answered.
    private final class Answers: @unchecked Sendable {
        var levels: [UNNotificationInterruptionLevel] = []
    }

    /// The watch app's relay inbox with a clock, a store and a notification centre of its own.
    @MainActor
    private final class RelayRig {
        let suite = "Item169Relay-\(UUID().uuidString)"
        let defaults: UserDefaults
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var posted: [UNNotificationRequest] = []
        private(set) var inbox: WatchRelayInbox!

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            inbox = WatchRelayInbox(defaults: defaults, now: { [unowned self] in self.clock },
                                    post: { [unowned self] request in self.posted.append(request) })
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    // MARK: - Pushes

    private static let tamperBody = CloudExfiltrator.makeTamperSubscription().notificationInfo?.alertBody ?? ""
    private static let disarmBody = CloudExfiltrator.makeDisarmSubscription().notificationInfo?.alertBody ?? ""

    /// An iCloud push as the subscriptions send it (the shape of item 140's watch pairing tests).
    private static func push(subscriptionID: String, body: String,
                             recordName: String = "meta-v2-" + UUID().uuidString) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Malinois"
        content.body = body
        content.sound = .default
        content.userInfo = ["aps": ["alert": ["title": "Malinois", "body": body], "content-available": 1,
                                    "mutable-content": 1, "sound": "default"],
                            "ck": ["ce": 2, "cid": "iCloud.com.johncompton.Malinois", "nid": UUID().uuidString,
                                   "qry": ["dbs": 2, "fo": 1, "rid": recordName, "sid": subscriptionID,
                                           "zid": "_defaultZone", "zoid": "_defaultOwner"]]]
        return content
    }
}
