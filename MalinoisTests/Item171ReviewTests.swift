//
//  Item171ReviewTests.swift
//  MalinoisTests
//
//  Codex's look at item 170's fixes, f305c4e..c22341f (BACKLOG 171; the owner: "as recommended, another look first").
//  Written before the fixes, red at the round's red commit.
//  - codex-1 (step 58): a clock moved back could still quiet a lone tamper alert: the burst rule dropped only the
//    arrivals dated after now and kept the older ones, so an old burst's first three quieted it. Now an arrival dated
//    before any the record holds starts the record afresh, and taps.
//  - codex-2 (step 58): the record's arrivals and its running burst were two values written one after the other. Now
//    they are one value, one write; a record in the earlier form is read once.
//  - Codex's limit on step 52 (step 60): a later cancel waited for everything queued for the disk, a clip being stored
//    included (seconds). Now it waits about two seconds at most; the write lands after it.
//

import AVFoundation
import CloudKit
import UserNotifications
import XCTest
@testable import Malinois

@MainActor
final class Item171ReviewTests: XCTestCase {
    nonisolated private static let keys = [MonitoringEngine.cancelRunKey, AlertBurst.arrivalsKey,
                                           AlertBurst.burstKey(AlertBurst.arrivalsKey)]
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem171")
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        EventStore.writeDelayForTesting = 0
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - A clock moved back (step 58; codex-1)

    /// The decisions for arrivals at `seconds` after `base`, each through the rule and the record it leaves.
    private func quietness(_ seconds: [TimeInterval]) -> [Bool] {
        var record = AlertBurst.Record(arrivals: [], burstLast: nil)
        return seconds.map { offset in
            let arrival = AlertBurst.arrive(base.addingTimeInterval(offset), after: record)
            record = arrival.record
            return arrival.quiet
        }
    }

    /// Codex's case: arrivals at 0, 10, 20 and 30 (the fourth quiet), then, after more than 150 real seconds, the clock
    /// moved back so the next lone alert reads 25. It taps, and the record starts afresh from it. Red at the round's
    /// red commit: the old triple quieted it.
    func testAnArrivalBeforeTheRecordsLatestStartsItAfreshAndTaps() {
        let before = AlertBurst.Record(arrivals: [0.0, 10, 20, 30].map { base.addingTimeInterval($0) },
                                       burstLast: base.addingTimeInterval(30))
        let arrival = AlertBurst.arrive(base.addingTimeInterval(25), after: before)
        XCTAssertFalse(arrival.quiet, "a lone alert after the clock moved back taps")
        XCTAssertEqual(arrival.record, AlertBurst.Record(arrivals: [base.addingTimeInterval(25)], burstLast: nil))
    }

    /// After it, a new burst's first three tap and its fourth comes quietly: the old triple is not found again. Red at
    /// the round's red commit: all quiet.
    func testANewBurstAfterTheClockMovedBackTapsThreeTimes() {
        XCTAssertEqual(quietness([0, 10, 20, 30, 25, 35, 45, 55]), [false, false, false, true, false, false, false, true])
    }

    /// The same through the record kept in defaults, read and written as an alert path does.
    func testTheRecordInDefaultsStartsAfreshWhenTheClockMovedBack() throws {
        let suite = "Item171Record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let quiet = [0.0, 10, 20, 30, 25, 35, 45, 55].map { offset -> Bool in
            let now = base.addingTimeInterval(offset)
            let before = AlertBurst.recordArrival(at: now, defaults: defaults, key: "burst")
            return AlertBurst.arrive(now, after: before).quiet
        }
        XCTAssertEqual(quiet, [false, false, false, true, false, false, false, true])
    }

    /// Through the watch app's relay inbox: four relayed tamper alerts (the fourth quiet), the clock moved back, then
    /// three more tap and a fourth comes quietly. Red at the round's red commit: quiet after the move.
    func testTheRelayInboxStartsAfreshWhenTheClockMovedBack() async throws {
        let relay = try RelayRig(clock: base)
        defer { relay.cleanUp() }
        for offset in [0.0, 10, 20, 30, 25, 35, 45, 55] {
            relay.clock = base.addingTimeInterval(offset)
            _ = await relay.inbox.receive(WatchAlertMessage(kind: .tamper, eventID: UUID(),
                                                            at: relay.clock.addingTimeInterval(-5)))
        }
        XCTAssertEqual(relay.posted.map { $0.content.interruptionLevel == .passive },
                       [false, false, false, true, false, false, false, true])
    }

    /// A record whose newest arrival is dated after now (the clock moved back), with an old triple before now.
    private func keepARecordFromBeforeTheClockMovedBack() {
        let now = Date()
        UserDefaults.standard.set([-25.0, -15, -5, 5].map { now.addingTimeInterval($0).timeIntervalSince1970 },
                                  forKey: AlertBurst.arrivalsKey)
        UserDefaults.standard.set(now.addingTimeInterval(5).timeIntervalSince1970,
                                  forKey: AlertBurst.burstKey(AlertBurst.arrivalsKey))
    }

    /// Through the iPhone's extension: the alert taps. Red at the round's red commit: it came quietly.
    func testTheIPhonesExtensionTapsAfterTheClockMovedBack() async {
        keepARecordFromBeforeTheClockMovedBack()
        let push = Self.push(subscriptionID: NotificationService.tamperSubscriptionID, body: Self.tamperBody)
        let level = await answer(NotificationService(), push)
        XCTAssertEqual(level, .timeSensitive)
    }

    /// Through the watch's extension: the alert taps. Red at the round's red commit: it came quietly.
    func testTheWatchsExtensionTapsAfterTheClockMovedBack() async {
        keepARecordFromBeforeTheClockMovedBack()
        let push = Self.push(subscriptionID: WatchAlertPairing.tamperSubscriptionID, body: Self.tamperBody,
                             recordName: "meta-v2-" + UUID().uuidString)
        let level = await answer(WatchNotificationService(), push)
        XCTAssertEqual(level, .timeSensitive)
    }

    // MARK: - One value (step 58; codex-2)

    /// An arrival writes the record as one value, its arrivals and its running burst together, so no write can keep
    /// one without the other; the earlier form's separate key is gone. Red at the round's red commit: two values.
    func testTheRecordIsWrittenAsOneValue() throws {
        let suite = "Item171Record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for offset in [0.0, 10, 20, 30] { _ = AlertBurst.recordArrival(at: base.addingTimeInterval(offset), defaults: defaults, key: "burst") }
        let stored = try XCTUnwrap(defaults.dictionary(forKey: "burst"), "one value")
        XCTAssertEqual(stored["arrivals"] as? [Double], [0.0, 10, 20, 30].map { base.addingTimeInterval($0).timeIntervalSince1970 })
        XCTAssertEqual(stored["burstLast"] as? Double, base.addingTimeInterval(30).timeIntervalSince1970, "the fourth was quiet")
        XCTAssertNil(defaults.object(forKey: AlertBurst.burstKey("burst")), "no separate key")
        XCTAssertEqual(AlertBurst.record(defaults: defaults, key: "burst"),
                       AlertBurst.Record(arrivals: [0.0, 10, 20, 30].map { base.addingTimeInterval($0) },
                                         burstLast: base.addingTimeInterval(30)), "and it reads back")
    }

    /// A record in the earlier form (a list of arrivals, the burst's last under its own key) reads the same, and the
    /// next arrival rewrites it as one value. Red at the round's red commit: still two values.
    func testARecordInTheEarlierFormIsReadThenRewrittenAsOne() throws {
        let suite = "Item171Record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([0.0, 10, 20, 30].map { base.addingTimeInterval($0).timeIntervalSince1970 }, forKey: "burst")
        defaults.set(base.addingTimeInterval(30).timeIntervalSince1970, forKey: AlertBurst.burstKey("burst"))
        let before = AlertBurst.recordArrival(at: base.addingTimeInterval(40), defaults: defaults, key: "burst")
        XCTAssertEqual(before, AlertBurst.Record(arrivals: [0.0, 10, 20, 30].map { base.addingTimeInterval($0) },
                                                 burstLast: base.addingTimeInterval(30)), "read as it was")
        XCTAssertTrue(AlertBurst.arrive(base.addingTimeInterval(40), after: before).quiet, "the burst goes on")
        XCTAssertNotNil(defaults.dictionary(forKey: "burst"), "rewritten as one value")
        XCTAssertNil(defaults.object(forKey: AlertBurst.burstKey("burst")), "the separate key gone")
    }

    // MARK: - The cancel's wait, bounded (step 60; Codex's limit on step 52)

    private struct Phone {
        let engine: MonitoringEngine
        let store: EventStore
    }

    /// A Pro phone verified for "owner", offline, disarmed on Home, the PIN set and entered recently (item 169's rig).
    private func offlinePhone() async throws -> Phone {
        XCTAssertTrue(KeychainService.setPIN("7391"))
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let gate = CloudEnrollment(file: root.appendingPathComponent("enrollment-171/state.json"), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "owner", resolve: { "owner" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: gate)
        cloud.accountIdentityForTesting = { nil }
        cloud.saveAttemptForTesting = { _ in throw CKError(.networkUnavailable) }
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        engine.simulateGuidedAccessForTesting(on: true)
        return Phone(engine: engine, store: store)
    }

    /// A later cancel waits for the log's queued write, but about two seconds at most: with the queue held five seconds,
    /// as a clip being stored ahead of the write would hold it, the cancel returns after the bound, and the write lands
    /// after it. Red at the round's red commit: the cancel waited out the whole queue.
    func testALaterCancelWaitsForTheLogAtMostAboutTwoSeconds() async throws {
        let phone = try await offlinePhone()
        phone.engine.beginArming()
        phone.engine.confirmGuidedAccessAndStartGrace()
        phone.engine.cancelArming()   // the run's first cancel: a record of its own
        phone.engine.beginArming()
        phone.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(phone.engine.state, .arming)
        phone.store.drainIOForTesting()
        EventStore.writeDelayForTesting = 5
        let started = Date()
        phone.engine.cancelArming()
        let waited = Date().timeIntervalSince(started)
        EventStore.writeDelayForTesting = 0
        XCTAssertEqual(phone.engine.state, .disarmed)
        XCTAssertLessThan(waited, 3.5, "the cancel waited \(waited) s")
        XCTAssertGreaterThan(waited, 1.5, "it waited for the write a while")
        phone.store.drainIOForTesting()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let disk = try JSONDecoder().decode([Event].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
        XCTAssertEqual(disk.first { $0.stateChange == "armingCancelled" }?.cancelCount, 2, "the write landed after it")
    }

    // MARK: - Helpers

    /// What an extension answered.
    private final class Answers: @unchecked Sendable {
        var levels: [UNNotificationInterruptionLevel] = []
    }

    private func answer(_ service: UNNotificationServiceExtension,
                        _ push: UNNotificationContent) async -> UNNotificationInterruptionLevel? {
        let answers = Answers()
        let answered = expectation(description: "answered")
        // Not on the main actor: the watch's extension answers on the notification centre's own queue.
        service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: push, trigger: nil)) { @Sendable content in
            answers.levels.append(content.interruptionLevel)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        return answers.levels.first
    }

    /// The watch app's relay inbox with a clock, a store and a notification centre of its own.
    @MainActor
    private final class RelayRig {
        let suite = "Item171Relay-\(UUID().uuidString)"
        let defaults: UserDefaults
        var clock: Date
        var posted: [UNNotificationRequest] = []
        private(set) var inbox: WatchRelayInbox!

        init(clock: Date) throws {
            self.clock = clock
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            inbox = WatchRelayInbox(defaults: defaults, now: { [unowned self] in self.clock },
                                    post: { [unowned self] request in self.posted.append(request) })
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    private static let tamperBody = CloudExfiltrator.makeTamperSubscription().notificationInfo?.alertBody ?? ""

    /// An iCloud push as the subscriptions send it (item 153's burst tests).
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
