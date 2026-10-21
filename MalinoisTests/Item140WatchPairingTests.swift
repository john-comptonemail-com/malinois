//
//  Item140WatchPairingTests.swift
//  MalinoisTests
//
//  TestFlight 1.8 (74), step 4 (the owner, 2026-10-19; BACKLOG 140, ruled "A"; ADR 0052): each tamper reached the
//  watch twice, iCloud's copy (no time) about 8 seconds before the relay's (Time Sensitive, with the time), also with
//  the watch connected through its iPhone. Now the watch's alert extension shows iCloud's tamper copy Time Sensitive,
//  or quietly when the relay's copy of the event already tapped, and the watch app posts the relay's copy quietly when
//  iCloud's tapped as loudly, keeping one entry, with the time. Driven through the real `WatchRelayInbox`, the real
//  extension and pairing, with a notification list of the test's own, and pushes as CloudKit sends them. Written
//  before the change, red at that commit (against compile-only stubs).
//  Codex's look at 75 (62b4b31), codex-1: the tidy-up at iCloud's wake never ran, since the watch app had no
//  remote-notification background mode, and nothing else tidied; and a list that never answered would hold every
//  relayed alert back. Now the app is woken, and tidies when it opens and at a repeat of a relayed alert; a list read
//  has a deadline. Their tests too were written first, red.
//  TestFlight 76 (the owner, 2026-10-20): with the watch app closed, tamper alerts "came through with times, some
//  (maybe most) were just silent": the relayed copy was posted quietly because iCloud's Time Sensitive copy was in the
//  list, and iCloud's copy had not tapped. Since 77 (the owner's "A") the relayed copy always alerts as in 74, and the
//  pairing only keeps one entry and quiets iCloud's later copy: never silent, two taps when iCloud's copy comes first.
//  Those tests too were written first, red.
//

import XCTest
import UserNotifications
@testable import Malinois

/// The watch's notification list and centre: every post and removal recorded, the list kept as the system keeps it.
@MainActor
private final class Rig {
    let suiteName = "MalinoisItem140Pairing-\(UUID().uuidString)"
    let defaults: UserDefaults
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// The requests posted, in order.
    var posted: [UNNotificationRequest] = []
    /// Each removal asked for.
    var removed: [[String]] = []
    /// The list, as watchOS keeps it: what was posted or delivered, less what was removed.
    var list: [WatchAlertPairing.Delivered] = []
    /// Every notification's content as it reached the wrist, in order, for counting taps.
    var shown: [UNNotificationContent] = []
    var failing = false
    /// How long each read of the list takes, when it stalls.
    var listStall: TimeInterval?
    /// One read that stalls (counted from 1), for how long, and the reads so far (observation 1 on 75).
    var stalledRead: Int?
    var stallLength: TimeInterval = 1
    private var reads = 0

    /// How long the read now starting takes, if it stalls.
    func nextReadStall() -> TimeInterval? {
        reads += 1
        return reads == stalledRead ? stallLength : listStall
    }

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func inbox(listDeadline: TimeInterval = 2) -> WatchRelayInbox {
        WatchRelayInbox(defaults: defaults, now: { [unowned self] in self.now },
                        post: { [unowned self] request in try await self.post(request) },
                        delivered: { [weak self] in
                            // Weak: a stalled read can outlive the test.
                            if let stall = self?.nextReadStall() { try? await Task.sleep(nanoseconds: UInt64(stall * 1e9)) }
                            return self?.list ?? []
                        },
                        remove: { [unowned self] ids in self.remove(ids) },
                        listDeadline: listDeadline)
    }

    func post(_ request: UNNotificationRequest) async throws {
        if failing { throw NSError(domain: "Item140Pairing", code: 1) }
        posted.append(request)
        list.append(WatchAlertPairing.Delivered(identifier: request.identifier, content: request.content))
        shown.append(request.content)
    }

    func remove(_ ids: [String]) {
        removed.append(ids)
        list.removeAll { ids.contains($0.identifier) }
    }

    /// iCloud's push as the watch's alert extension hands it to watchOS, given the list at that moment.
    @discardableResult
    func deliverICloud(_ push: UNNotificationRequest) -> UNNotificationContent {
        let content = WatchAlertPairing.iCloudContent(push.content, deliveredIdentifiers: Set(list.map(\.identifier)))
        list.append(WatchAlertPairing.Delivered(identifier: push.identifier, content: content))
        shown.append(content)
        return content
    }

    /// The taps on the wrist: notifications with sound above the passive level.
    var taps: Int { shown.filter { $0.sound != nil && $0.interruptionLevel != .passive }.count }

    func tearDown() { defaults.removePersistentDomain(forName: suiteName) }
}

/// Content handed back on another thread.
private final class ContentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UNNotificationContent?
    var content: UNNotificationContent? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
final class Item140WatchPairingTests: XCTestCase {
    private var rig: Rig!

    override func setUp() async throws {
        try await super.setUp()
        rig = try Rig()
    }

    override func tearDown() async throws {
        rig.tearDown()
        rig = nil
        try await super.tearDown()
    }

    // MARK: - Pushes as CloudKit sends them

    private static let tamperBody = "Tamper detected on your device."
    private static let disarmBody = "Malinois was disarmed on one of your devices."

    /// A query subscription's alert: the alert, the subscription that sent it, and the name of the record that fired it.
    private func push(subscriptionID: String, recordName: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Malinois"
        content.body = body
        content.sound = .default
        content.userInfo = ["aps": ["alert": ["title": "Malinois", "body": body], "content-available": 1,
                                    "mutable-content": 1, "sound": "default"],
                            "ck": ["ce": 2, "cid": "iCloud.com.johncompton.Malinois", "nid": UUID().uuidString,
                                   "qry": ["dbs": 2, "fo": 1, "rid": recordName, "sid": subscriptionID,
                                           "zid": "_defaultZone", "zoid": "_defaultOwner"]]]
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    private func tamperPush(_ event: UUID) -> UNNotificationRequest {
        push(subscriptionID: CloudExfiltrator.makeTamperSubscription().subscriptionID,
             recordName: "meta-v2-" + event.uuidString, body: Self.tamperBody)
    }

    private func disarmPush(_ event: UUID) -> UNNotificationRequest {
        push(subscriptionID: CloudExfiltrator.makeDisarmSubscription().subscriptionID,
             recordName: "disarm-v2-" + event.uuidString, body: Self.disarmBody)
    }

    /// A relayed alert whose event happened `secondsAgo` before the rig's clock.
    private func relayed(_ kind: WatchAlertMessage.Kind, _ event: UUID, secondsAgo: TimeInterval = 8) -> WatchAlertMessage {
        WatchAlertMessage(kind: kind, eventID: event, at: rig.now.addingTimeInterval(-secondsAgo))
    }

    // MARK: - The pair

    /// iCloud's alert names its event in its record's name, under the subscription that writes it.
    func testAnICloudAlertIsMatchedByItsSubscriptionAndRecordName() {
        let event = UUID()
        XCTAssertEqual(WatchAlertPairing.tamperSubscriptionID, CloudExfiltrator.makeTamperSubscription().subscriptionID)
        XCTAssertEqual(WatchAlertPairing.disarmSubscriptionID, CloudExfiltrator.makeDisarmSubscription().subscriptionID)
        XCTAssertEqual(WatchAlertPairing.iCloudAlert(userInfo: tamperPush(event).content.userInfo),
                       WatchAlertPairing.Pair(kind: .tamper, eventID: event))
        XCTAssertEqual(WatchAlertPairing.iCloudAlert(userInfo: disarmPush(event).content.userInfo),
                       WatchAlertPairing.Pair(kind: .disarm, eventID: event))
        XCTAssertEqual(WatchAlertPairing.Pair(kind: .tamper, eventID: event).relayIdentifier,
                       relayed(.tamper, event).notificationIdentifier)
    }

    /// Anything else is not paired: another prefix, another subscription, no event ID, no CloudKit payload.
    func testAnythingElseIsNotPaired() {
        let event = UUID()
        let tamper = CloudExfiltrator.makeTamperSubscription().subscriptionID
        let others = [push(subscriptionID: tamper, recordName: "disarm-v2-" + event.uuidString, body: Self.tamperBody),
                      push(subscriptionID: "someone-else", recordName: "meta-v2-" + event.uuidString, body: "Hello"),
                      push(subscriptionID: tamper, recordName: "meta-v2-not-an-id", body: Self.tamperBody)]
        for other in others {
            XCTAssertNil(WatchAlertPairing.iCloudAlert(userInfo: other.content.userInfo))
        }
        XCTAssertNil(WatchAlertPairing.iCloudAlert(userInfo: [:]))
        XCTAssertNil(WatchAlertPairing.iCloudAlert(userInfo: WatchRelayInbox.request(for: relayed(.tamper, event),
                                                                                     now: rig.now).content.userInfo))
    }

    // MARK: - The watch's alert extension

    /// Alone in the list, iCloud's tamper alert is shown Time Sensitive, as on the iPhone (ADR 0045), words as sent.
    func testTheExtensionShowsICloudsTamperAlertTimeSensitive() {
        let request = tamperPush(UUID())
        let content = WatchAlertPairing.iCloudContent(request.content, deliveredIdentifiers: [])
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.title, "Malinois")
        XCTAssertEqual(content.body, Self.tamperBody)
        XCTAssertNotNil(content.sound)
    }

    /// The relay's copy came first and tapped: iCloud's is shown quietly, words as sent.
    func testTheExtensionQuietsICloudsCopyAfterTheRelaysCopy() {
        let event = UUID()
        let content = WatchAlertPairing.iCloudContent(tamperPush(event).content,
                                                      deliveredIdentifiers: [relayed(.tamper, event).notificationIdentifier])
        XCTAssertEqual(content.interruptionLevel, .passive)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.body, Self.tamperBody)
    }

    /// A disarm alert keeps its level alone, and is quiet after the relay's copy.
    func testTheExtensionLeavesADisarmAsSentAndQuietsItAfterTheRelay() {
        let event = UUID()
        let alone = WatchAlertPairing.iCloudContent(disarmPush(event).content, deliveredIdentifiers: [])
        XCTAssertEqual(alone.interruptionLevel, .active)
        XCTAssertNotNil(alone.sound)
        let after = WatchAlertPairing.iCloudContent(disarmPush(event).content,
                                                    deliveredIdentifiers: [relayed(.disarm, event).notificationIdentifier])
        XCTAssertEqual(after.interruptionLevel, .passive)
        XCTAssertNil(after.sound)
    }

    /// Another event's relayed copy changes nothing; another push is shown as sent.
    func testTheExtensionLeavesOtherAlertsAsSent() {
        let request = tamperPush(UUID())
        let other = WatchAlertPairing.iCloudContent(request.content,
                                                    deliveredIdentifiers: [relayed(.tamper, UUID()).notificationIdentifier])
        XCTAssertEqual(other.interruptionLevel, .timeSensitive, "another event's copy: this one still breaks through")
        let foreign = push(subscriptionID: "someone-else", recordName: "x", body: "Hello")
        XCTAssertEqual(WatchAlertPairing.iCloudContent(foreign.content, deliveredIdentifiers: []), foreign.content)
    }

    /// The extension itself, with the test host's own (empty) list: a tamper push comes out Time Sensitive.
    func testTheExtensionDeliversATamperPushTimeSensitive() async {
        let box = ContentBox()
        let done = expectation(description: "delivered")
        WatchNotificationService().didReceive(tamperPush(UUID())) { content in
            box.content = content
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(box.content?.interruptionLevel, .timeSensitive)
        XCTAssertEqual(box.content?.body, Self.tamperBody)
    }

    // MARK: - The relayed copy, with iCloud's in the list

    /// The order the owner saw: iCloud's copy (the extension ran: Time Sensitive) about 8 seconds first. The relay's copy
    /// still taps, Time Sensitive with sound, as in 74 (iCloud's may not have: TestFlight 76), and replaces it: one entry,
    /// with the time.
    func testARelayedTamperAfterICloudsCopyStillTapsAndReplacesIt() async throws {
        let event = UUID()
        let iCloud = tamperPush(event)
        rig.deliverICloud(iCloud)
        let posted = await rig.inbox().receive(relayed(.tamper, event))
        XCTAssertTrue(posted)
        let request = try XCTUnwrap(rig.posted.first)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(request.content.sound)
        XCTAssertTrue(request.content.body.hasPrefix("Tamper detected on your device at "), request.content.body)
        XCTAssertEqual(rig.removed, [[iCloud.identifier]])
        XCTAssertEqual(rig.list.map(\.identifier), [relayed(.tamper, event).notificationIdentifier])
        XCTAssertEqual(rig.taps, 2, "iCloud's copy and the relay's")
    }

    /// TestFlight 76's case: iCloud's Time Sensitive copy is in the list but did not tap. The relay's copy taps: an alert
    /// is never left silent.
    func testTheRelayedCopyTapsWhenICloudsCopyCameSilently() async throws {
        let event = UUID()
        let iCloud = tamperPush(event)
        let content = WatchAlertPairing.iCloudContent(iCloud.content, deliveredIdentifiers: [])
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        rig.list.append(WatchAlertPairing.Delivered(identifier: iCloud.identifier, content: content))   // listed, never shown
        await rig.inbox().receive(relayed(.tamper, event))
        XCTAssertEqual(rig.taps, 1, "the tamper alert went silent")
        XCTAssertEqual(rig.list.map(\.identifier), [relayed(.tamper, event).notificationIdentifier])
    }

    /// When the extension did not run, iCloud's copy came as sent, below Time Sensitive: the relay's copy still taps,
    /// Time Sensitive, so a Focus is broken through (the fail-safe direction), and iCloud's copy is removed.
    func testWhenTheExtensionDidNotRunTheRelayedTamperStillTaps() async throws {
        let event = UUID()
        let iCloud = tamperPush(event)
        rig.list.append(WatchAlertPairing.Delivered(identifier: iCloud.identifier, content: iCloud.content))
        await rig.inbox().receive(relayed(.tamper, event))
        let request = try XCTUnwrap(rig.posted.first)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(rig.removed, [[iCloud.identifier]])
    }

    /// A disarm after iCloud's copy: the relay's taps too, at the ordinary level, and replaces it.
    func testARelayedDisarmAfterICloudsCopyStillTapsAndReplacesIt() async throws {
        let event = UUID()
        let iCloud = disarmPush(event)
        rig.deliverICloud(iCloud)
        await rig.inbox().receive(relayed(.disarm, event))
        let request = try XCTUnwrap(rig.posted.first)
        XCTAssertEqual(request.content.interruptionLevel, .active)
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(rig.removed, [[iCloud.identifier]])
        XCTAssertEqual(rig.taps, 2, "iCloud's copy and the relay's")
    }

    /// Without iCloud's copy, or with another event's, the relayed alert is posted as before and nothing is removed.
    func testWithoutICloudsCopyOfTheEventTheRelayedAlertIsPostedAsBefore() async throws {
        let event = UUID()
        rig.deliverICloud(tamperPush(UUID()))
        await rig.inbox().receive(relayed(.tamper, event))
        let request = try XCTUnwrap(rig.posted.first)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(request.content.sound)
        XCTAssertTrue(rig.removed.isEmpty)
    }

    /// An old alert joins the summary as before (ADR 0051), and iCloud's copy of its event goes: the summary counts it.
    func testAnOldAlertJoiningTheSummaryRemovesICloudsCopy() async throws {
        let event = UUID()
        let iCloud = tamperPush(event)
        rig.deliverICloud(iCloud)
        await rig.inbox().receive(relayed(.tamper, event, secondsAgo: 2 * 3600))
        let request = try XCTUnwrap(rig.posted.first)
        XCTAssertTrue(request.identifier.hasPrefix(WatchRelaySummary.identifierPrefix))
        XCTAssertEqual(request.content.interruptionLevel, .active, "the summary's first post taps, as before")
        XCTAssertEqual(rig.removed, [[iCloud.identifier]])
    }

    /// A post that failed removes nothing: iCloud's copy stays the only one.
    func testAFailedPostLeavesICloudsCopy() async {
        let event = UUID()
        rig.deliverICloud(tamperPush(event))
        rig.failing = true
        let posted = await rig.inbox().receive(relayed(.tamper, event))
        XCTAssertFalse(posted)
        XCTAssertTrue(rig.removed.isEmpty)
        XCTAssertEqual(rig.list.count, 1)
    }

    // MARK: - iCloud's copy after the relay's

    /// When iCloud's push wakes the app, its copy of an event the relay's copy is listed for goes.
    func testAtICloudsWakeItsCopyOfAnEventShownIsRemoved() async {
        let event = UUID()
        let inbox = rig.inbox()
        await inbox.receive(relayed(.tamper, event))
        let iCloud = tamperPush(event)
        rig.deliverICloud(iCloud)
        XCTAssertEqual(inbox.tidy(delivered: rig.list), [iCloud.identifier])
    }

    /// The same for an event summed up, and for one shown whose entry the owner cleared: the inbox remembers both.
    func testAtICloudsWakeItsCopyOfAnEventHandledBeforeIsRemoved() async {
        let old = UUID()
        let cleared = UUID()
        let inbox = rig.inbox()
        await inbox.receive(relayed(.tamper, old, secondsAgo: 2 * 3600))
        await inbox.receive(relayed(.disarm, cleared))
        rig.list.removeAll()
        let first = tamperPush(old)
        let second = disarmPush(cleared)
        rig.deliverICloud(first)
        rig.deliverICloud(second)
        XCTAssertEqual(inbox.tidy(delivered: rig.list), [first.identifier, second.identifier])
    }

    /// An event the watch has not handled keeps iCloud's copy.
    func testAtICloudsWakeAnUnhandledEventsCopyStays() async {
        let inbox = rig.inbox()
        await inbox.receive(relayed(.tamper, UUID()))
        rig.deliverICloud(tamperPush(UUID()))
        XCTAssertEqual(inbox.tidy(delivered: rig.list), [])
    }

    // MARK: - Codex's look at 75: the tidy-up, and a list that does not answer

    /// The relay's live copy first, then iCloud's (quiet), then the relay's queued copy of the same alert: the repeat is
    /// not shown, and takes iCloud's copy out of the list.
    func testARepeatOfARelayedAlertRemovesICloudsLaterCopy() async {
        let event = UUID()
        let inbox = rig.inbox()
        await inbox.receive(relayed(.tamper, event))
        let iCloud = tamperPush(event)
        XCTAssertEqual(rig.deliverICloud(iCloud).interruptionLevel, .passive)
        let again = await inbox.receive(relayed(.tamper, event))
        XCTAssertFalse(again, "not shown twice")
        await inbox.repeatTidy?.value
        XCTAssertEqual(rig.removed, [[iCloud.identifier]])
        XCTAssertEqual(rig.list.map(\.identifier), [relayed(.tamper, event).notificationIdentifier])
        XCTAssertEqual(rig.taps, 1)
    }

    /// When the app opens, or an iCloud push wakes it: iCloud's copies of events already handled go; another event's stays.
    func testReconcilingRemovesICloudsCopiesOfEventsAlreadyHandled() async {
        let shown = UUID()
        let inbox = rig.inbox()
        await inbox.receive(relayed(.tamper, shown))
        let late = tamperPush(shown)
        rig.deliverICloud(late)
        let other = tamperPush(UUID())
        rig.deliverICloud(other)
        await inbox.reconcile()
        XCTAssertEqual(rig.removed, [[late.identifier]])
        XCTAssertEqual(Set(rig.list.map(\.identifier)), [relayed(.tamper, shown).notificationIdentifier, other.identifier])
    }

    /// A list that does not answer in time: the relayed alert is posted as in 74, Time Sensitive with sound, without waiting.
    func testAListThatTakesTooLongStillLetsTheRelayedAlertTap() async throws {
        let event = UUID()
        rig.deliverICloud(tamperPush(event))
        rig.listStall = 5
        let inbox = rig.inbox(listDeadline: 0.2)
        let start = Date()
        let posted = await inbox.receive(relayed(.tamper, event))
        XCTAssertTrue(posted)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the post waited for the list")
        let request = try XCTUnwrap(rig.posted.first)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive, "without the list, as in 74")
        XCTAssertNotNil(request.content.sound)
    }

    // MARK: - Codex's second look at 75, observation 1 (build 76): a repeat's tidy-up beside the alerts' queue

    /// A repeat whose read of the list is slow to answer holds nothing back: its handling ends at once, the next alert
    /// is posted without waiting for that read, and iCloud's copy still goes once the read answers.
    func testARepeatsTidyUpDoesNotHoldBackTheAlertsQueue() async throws {
        let event = UUID()
        let inbox = rig.inbox(listDeadline: 3)
        await inbox.receive(relayed(.tamper, event))            // read 1: the live copy's pairing
        let iCloud = tamperPush(event)
        rig.deliverICloud(iCloud)
        rig.stalledRead = 2                                       // the repeat's read, answering after a second
        rig.stallLength = 1
        let start = Date()
        let again = await inbox.receive(relayed(.tamper, event))
        XCTAssertFalse(again)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the repeat waited for the list in the alerts' queue")
        let posted = await inbox.receive(relayed(.tamper, UUID()))   // read 3, answering at once
        XCTAssertTrue(posted)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the next alert waited for the repeat's read")
        await inbox.repeatTidy?.value
        XCTAssertEqual(rig.removed, [[iCloud.identifier]], "iCloud's copy still goes")
    }

    /// The tidy-up does not wait past the deadline either, so a background wake ends in time.
    func testReconcilingDoesNotWaitPastTheDeadline() async {
        let inbox = rig.inbox(listDeadline: 0.2)
        rig.listStall = 5
        let start = Date()
        await inbox.reconcile()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// iCloud's pushes wake the watch app: the remote-notification background mode, in the watch app's Info.plist, for
    /// Debug and Release (Apple's `WKApplicationDelegate`: the callback is for apps with that mode).
    func testTheWatchAppIsWokenByICloudsPushes() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("MalinoisWatch/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["UIBackgroundModes"] as? [String], ["remote-notification"])
        let project = try String(contentsOf: Self.root.appendingPathComponent("Malinois.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        XCTAssertEqual(project.components(separatedBy: "INFOPLIST_FILE = MalinoisWatch/Info.plist;").count - 1, 2)
    }

    /// The watch tidies the list when it opens and when an iCloud push wakes it.
    func testTheWatchTidiesWhenItOpensAndWhenICloudWakesIt() throws {
        let delegate = try String(contentsOf: Self.root.appendingPathComponent("MalinoisWatch/WatchAppDelegate.swift"),
                                  encoding: .utf8)
        func body(of signature: String) throws -> String {
            let start = try XCTUnwrap(delegate.range(of: signature), signature)
            let rest = delegate[start.upperBound...]
            let end = try XCTUnwrap(rest.range(of: "\n    }\n"), signature)
            return String(rest[..<end.lowerBound])
        }
        XCTAssertTrue(try body(of: "func applicationDidBecomeActive()").contains("relayInbox.reconcile()"))
        XCTAssertTrue(try body(of: "func didReceiveRemoteNotification(").contains("relayInbox.reconcile()"))
    }

    // MARK: - The whole path, both orders

    /// Never silent, and one entry with the time per event: iCloud's copy first (the watch app closed: the owner's order)
    /// taps twice, both copies alerting; the relay's first (the watch app open: its live copy arrives at once) taps once,
    /// iCloud's later copy coming quietly.
    func testEitherOrderNeverLeavesATamperSilentAndKeepsOneTimedEntry() async {
        let first = UUID()
        let inbox = rig.inbox()
        rig.deliverICloud(tamperPush(first))
        await inbox.receive(relayed(.tamper, first))
        XCTAssertEqual(rig.taps, 2, "iCloud's copy first: both alert")
        XCTAssertEqual(rig.list.map(\.identifier), [relayed(.tamper, first).notificationIdentifier])

        let second = UUID()
        await inbox.receive(relayed(.tamper, second))
        let iCloud = tamperPush(second)
        let shown = rig.deliverICloud(iCloud)
        XCTAssertEqual(shown.interruptionLevel, .passive, "the relay's copy first")
        rig.remove(inbox.tidy(delivered: rig.list))
        XCTAssertEqual(rig.taps, 3, "the relay's copy first: one tap")
        XCTAssertEqual(Set(rig.list.map(\.identifier)), [relayed(.tamper, first).notificationIdentifier,
                                                         relayed(.tamper, second).notificationIdentifier])
    }
}
