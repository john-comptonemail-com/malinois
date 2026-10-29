//
//  Item170ReviewTests.swift
//  MalinoisTests
//
//  Codex's look at 1.8.2's fixes, 60a8f1a..f305c4e (BACKLOG 170; the owner: "c, rest yes"). Written before the fixes,
//  red at the round's red commit.
//  - codex-2 (step 52): a cancel that counts on its run's record was only queued for the log's next write, with no
//    journal line of its own, so a kill right after it lost it. Now it is on disk when the cancel returns, if the log's
//    queue is through within the cancel's wait, which step 60 bounded (item 172's codex-1).
//  - codex-3 (step 53): a sweep pass chose the stand-in "disarmed" alert from the rows' sync state, so a late cancel
//    run extended while its upload was in flight, whose row the older copy cannot mark synced, looked as if it had not
//    landed, and an older late disarm sent a second alert. Now the stand-in is chosen from what each upload did.
//  - codex-6 (step 54): a cancel dated before its run's last (the clock moved back) joined the run, with no alert. Now
//    it starts a run of its own.
//  - codex-5 (step 55): a burst stayed quiet only while its first three were still in the bounded record of arrivals
//    (fifty, an hour), so a long, sparse burst turned loud again with no gap. Now a running burst is kept apart from
//    the record and ends only by its gap.
//  - codex-4 (step 56): the watch counted a relayed tamper alert before posting it, so alerts it could not show used
//    up a burst's first three. Now an alert counts once it is shown.
//  - codex-7 (step 57): a speaker request iOS refused was only logged, and the siren taken as on the speaker. Now a
//    refused request is checked like the fallback, and where the siren plays is logged.
//

import AVFoundation
import CloudKit
import UserNotifications
import XCTest
@testable import Malinois

@MainActor
final class Item170ReviewTests: XCTestCase {
    nonisolated private static let keys = [MonitoringEngine.cancelRunKey, AlertBurst.arrivalsKey,
                                           AlertBurst.burstKey(AlertBurst.arrivalsKey)]

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem170")
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        EventStore.writeDelayForTesting = 0
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The cancel run (steps 52 to 54; codex-2, -3 and -6)

    private struct Phone {
        let engine: MonitoringEngine
        let store: EventStore
        let enrollment: CloudEnrollment
    }

    /// A Pro phone verified for "owner", offline (nothing it records reaches iCloud), disarmed on Home, the PIN set and
    /// entered recently, so ARM asks for nothing (item 169's rig).
    private func offlinePhone() async throws -> Phone {
        XCTAssertTrue(KeychainService.setPIN("7391"))
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let gate = CloudEnrollment(file: root.appendingPathComponent("enrollment-170/state.json"), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "owner", resolve: { "owner" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: gate)
        cloud.accountIdentityForTesting = { nil }   // offline: no account answers
        cloud.saveAttemptForTesting = { _ in throw CKError(.networkUnavailable) }
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        engine.simulateGuidedAccessForTesting(on: true)
        return Phone(engine: engine, store: store, enrollment: gate)
    }

    private func cancelACountdown(_ phone: Phone, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(phone.engine.armPINCheckIsDue, file: file, line: line)
        phone.engine.beginArming()
        phone.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(phone.engine.state, .arming, file: file, line: line)
        phone.engine.cancelArming()
        XCTAssertEqual(phone.engine.state, .disarmed, file: file, line: line)
    }

    private func cancels(_ phone: Phone) -> [Event] {
        phone.store.events.filter { $0.stateChange == "armingCancelled" }
    }

    /// codex-2: the second cancel of a run is on disk when the cancel returns, the log's writes slowed by less than the
    /// cancel's wait (step 60 bounds it; item 172's codex-1). The file as the cancel leaves it, which is what a kill then
    /// would leave, holds the count. Red at the round's red commit: the write was only queued, and the file still held
    /// one cancel.
    func testALaterCancelIsOnDiskWhenTheCancelReturns() async throws {
        let phone = try await offlinePhone()
        cancelACountdown(phone)
        phone.store.drainIOForTesting()
        EventStore.writeDelayForTesting = 0.3
        cancelACountdown(phone)
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let disk = try JSONDecoder().decode([Event].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))
        XCTAssertEqual(disk.first { $0.stateChange == "armingCancelled" }?.cancelCount, 2, "the second cancel is on disk")
        EventStore.writeDelayForTesting = 0
        phone.store.drainIOForTesting()
    }

    /// codex-6: a cancel dated before its run's last, as after the clock was moved back an hour, starts a run of its
    /// own: a record of its own, and its alert. Red at the round's red commit: it joined the old run.
    func testACancelBeforeTheRunsLastStartsARunOfItsOwn() async throws {
        let phone = try await offlinePhone()
        cancelACountdown(phone)
        var run = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: MonitoringEngine.cancelRunKey))
        run["last"] = Date().addingTimeInterval(3600).timeIntervalSince1970
        UserDefaults.standard.set(run, forKey: MonitoringEngine.cancelRunKey)
        cancelACountdown(phone)
        XCTAssertEqual(cancels(phone).count, 2, "a record of its own")
        XCTAssertTrue(cancels(phone).allSatisfy { $0.cancelCount == nil }, "neither counts the other")
    }

    /// Control for codex-6: a cancel nine minutes after the run's last still joins it.
    func testACancelWithinTheGapStillJoinsTheRun() async throws {
        let phone = try await offlinePhone()
        cancelACountdown(phone)
        var run = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: MonitoringEngine.cancelRunKey))
        run["last"] = Date().addingTimeInterval(-9 * 60).timeIntervalSince1970
        UserDefaults.standard.set(run, forKey: MonitoringEngine.cancelRunKey)
        cancelACountdown(phone)
        XCTAssertEqual(cancels(phone).count, 1)
        XCTAssertEqual(cancels(phone).first?.cancelCount, 2)
    }

    /// Holds one save until the test lets it go.
    @MainActor
    private final class SaveGate {
        private(set) var held = false
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?

        func hold() async {
            held = true
            guard !released else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func release() {
            released = true
            waiting?.resume()
            waiting = nil
        }
    }

    private func until(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    /// codex-3, through the real upload: recorded offline, an older late disarm A and a late cancel run B; back online,
    /// B's record is held at its save while another cancel extends the run. B's record and alert land, and its row
    /// stays unsynced, since the older copy cannot mark the newer row; A must send no second "disarmed" alert. Red at
    /// the round's red commit: the pass read B's row and sent A's stand-in.
    func testALateRunExtendedDuringItsUploadStillCarriesThePassAlert() async throws {
        let phone = try await offlinePhone()
        let early = Date().addingTimeInterval(-50 * 60)
        let a = Event(startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                      stateChange: "disarmed")
        phone.enrollment.registerLocalEvent(a)
        phone.store.add(a)
        cancelACountdown(phone)
        let first = try XCTUnwrap(cancels(phone).first)
        let started = Date().addingTimeInterval(-30 * 60)
        let b = Event(id: first.id, startDate: started, endDate: started, triggeredSensors: [],
                      cloudSyncState: first.cloudSyncState, stateChange: "armingCancelled")
        phone.store.update(b)   // the run began half an hour ago; its last cancel was just now
        let idle = await until { !phone.engine.pendingSweepActive }
        XCTAssertTrue(idle, "no sweep running yet")

        let gate = SaveGate()
        let bRecord = "state-v2-" + b.id.uuidString
        phone.engine.cloud.accountIdentityForTesting = { "owner" }
        phone.engine.cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordID.recordName == bRecord }) { await gate.hold() }
        }
        let sweep = Task { await phone.engine.retryPendingSync() }
        let held = await until { gate.held }
        XCTAssertTrue(held, "B's save is held")
        cancelACountdown(phone)   // the run goes on while B's save waits
        XCTAssertEqual(cancels(phone).first?.cancelCount, 2)
        gate.release()
        await sweep.value
        XCTAssertEqual(phone.engine.sweepDisarmSignalsForTesting[b.id], true, "B carried the pass's alert")
        XCTAssertEqual(phone.engine.sweepStandInAlertsForTesting, [], "and A sent no second one")
    }

    /// Through the real upload too, an older late disarm stands in when the newest's upload fails: what each upload did
    /// reaches the pass, the failure as well as the landing (its undo check: the upload answering nothing landed).
    func testAnOlderLateDisarmStandsInWhenTheNewestFailsThroughTheRealUpload() async throws {
        let phone = try await offlinePhone()
        let older = Date().addingTimeInterval(-50 * 60), newer = Date().addingTimeInterval(-30 * 60)
        let a = Event(startDate: older, endDate: older, triggeredSensors: [], cloudSyncState: .pending, stateChange: "disarmed")
        let b = Event(startDate: newer, endDate: newer, triggeredSensors: [], cloudSyncState: .pending, stateChange: "disarmed")
        for event in [a, b] {
            phone.enrollment.registerLocalEvent(event)
            phone.store.add(event)
        }
        let idle = await until { !phone.engine.pendingSweepActive }
        XCTAssertTrue(idle, "no sweep running yet")
        let bRecord = "state-v2-" + b.id.uuidString
        phone.engine.cloud.accountIdentityForTesting = { "owner" }
        phone.engine.cloud.saveAttemptForTesting = { records in
            if records.contains(where: { $0.recordID.recordName == bRecord }) { throw CKError(.serverRejectedRequest) }
        }
        await phone.engine.retryPendingSync()
        XCTAssertEqual(phone.engine.sweepStandInAlertsForTesting, [a.id], "A carries the pass's alert")
    }

    // MARK: - A burst outlasting its record (step 55; codex-5)

    /// The decisions for arrivals at `times` (seconds), through the rule and its bounded record, as a path makes them.
    private func quietness(_ times: [TimeInterval]) -> [Bool] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var record = AlertBurst.Record(arrivals: [], burstLast: nil)
        return times.map { t in
            let arrival = AlertBurst.arrive(start.addingTimeInterval(t), after: record)
            record = arrival.record
            return arrival.quiet
        }
    }

    /// Codex's two timelines: three within a minute, then one every 40 seconds well past fifty arrivals, or one every two
    /// minutes well past an hour. The burst stays quiet to the end: no gap of 150 seconds ended it. Red at the round's
    /// red commit: loud again at the 53rd, and after the hour.
    func testABurstOutlastingItsRecordStaysQuiet() {
        let quick: [TimeInterval] = [0, 10, 20]
        for spacing in [40.0, 120.0] {
            let sparse: [TimeInterval] = (1...60).map { 20 + Double($0) * spacing }
            let quiet = quietness(quick + sparse)
            XCTAssertEqual(Array(quiet.prefix(3)), [false, false, false], "spacing \(spacing): the first three tap")
            XCTAssertEqual(quiet.dropFirst(3).firstIndex(of: false), nil, "spacing \(spacing): loud again")
        }
    }

    /// Control: a gap of 150 seconds still ends a long burst; the next tamper alert taps.
    func testAGapStillEndsALongBurst() {
        let quick: [TimeInterval] = [0, 10, 20]
        let sparse: [TimeInterval] = (1...60).map { 20 + Double($0) * 40 }
        let afterTheGap: TimeInterval = 20 + 60 * 40 + 150
        XCTAssertEqual(quietness(quick + sparse + [afterTheGap]).last, false)
    }

    /// Control: a running burst whose last arrival is dated after now (the clock moved back) quiets nothing.
    func testABurstDatedAfterNowQuietsNothing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(AlertBurst.arrive(now, after: AlertBurst.Record(arrivals: [], burstLast: now.addingTimeInterval(30))).quiet)
    }

    /// A burst running by the extensions' record: its last arrival 40 seconds ago, the arrivals kept one every 40
    /// seconds, which hold no three within a minute (its first three long gone).
    private func keepARunningBurst() {
        let now = Date()
        UserDefaults.standard.set([120.0, 80, 40].map { now.addingTimeInterval(-$0).timeIntervalSince1970 },
                                  forKey: AlertBurst.arrivalsKey)
        UserDefaults.standard.set(now.addingTimeInterval(-40).timeIntervalSince1970,
                                  forKey: AlertBurst.burstKey(AlertBurst.arrivalsKey))
    }

    /// Through the iPhone's extension: the running burst keeps the next tamper alert quiet. Red at the round's red
    /// commit: it tapped.
    func testTheIPhonesExtensionKeepsARunningBurstQuiet() async {
        keepARunningBurst()
        let push = Self.push(subscriptionID: NotificationService.tamperSubscriptionID, body: Self.tamperBody)
        let level = await answer(NotificationService(), push)
        XCTAssertEqual(level, .passive)
    }

    /// Through the watch's extension, the same. Red at the round's red commit: it tapped.
    func testTheWatchsExtensionKeepsARunningBurstQuiet() async {
        keepARunningBurst()
        let push = Self.push(subscriptionID: WatchAlertPairing.tamperSubscriptionID, body: Self.tamperBody,
                             recordName: "meta-v2-" + UUID().uuidString)
        let level = await answer(WatchNotificationService(), push)
        XCTAssertEqual(level, .passive)
    }

    /// Through the watch app's relay inbox: three quick relayed tamper alerts, then one every 40 seconds, sixty of
    /// them, each under an hour old: all but the first three come quietly. Red at the round's red commit: loud again.
    func testTheRelayInboxKeepsALongSparseBurstQuiet() async throws {
        let relay = try RelayRig()
        defer { relay.cleanUp() }
        for n in 0..<63 {
            _ = await relay.inbox.receive(WatchAlertMessage(kind: .tamper, eventID: UUID(),
                                                            at: relay.clock.addingTimeInterval(-5)))
            relay.clock = relay.clock.addingTimeInterval(n < 2 ? 10 : 40)
        }
        let levels = relay.posted.map(\.content.interruptionLevel)
        XCTAssertEqual(levels.count, 63)
        XCTAssertEqual(Array(levels.prefix(3)), [.timeSensitive, .timeSensitive, .timeSensitive])
        XCTAssertEqual(levels.dropFirst(3).firstIndex { $0 != .passive }, nil, "loud again")
    }

    // MARK: - Relayed alerts the watch could not show (step 56; codex-4)

    /// codex-4: three relayed tamper alerts the watch could not show, then one it could, within the minute: that one
    /// taps, Time Sensitive. Red at the round's red commit: the three failures had used up the burst's first three.
    func testRelayedAlertsTheWatchCouldNotShowDoNotCount() async throws {
        let relay = try RelayRig()
        defer { relay.cleanUp() }
        relay.failures = 3
        for _ in 0..<4 {
            _ = await relay.inbox.receive(WatchAlertMessage(kind: .tamper, eventID: UUID(),
                                                            at: relay.clock.addingTimeInterval(-5)))
            relay.clock = relay.clock.addingTimeInterval(1)
        }
        XCTAssertEqual(relay.posted.map(\.content.interruptionLevel), [.timeSensitive])
    }

    /// The same when the failures are one message's tries: its retry, shown at last, taps.
    func testARelayedAlertShownOnItsRetryTaps() async throws {
        let relay = try RelayRig()
        defer { relay.cleanUp() }
        relay.failures = 3
        let message = WatchAlertMessage(kind: .tamper, eventID: UUID(), at: relay.clock.addingTimeInterval(-5))
        for _ in 0..<4 {
            _ = await relay.inbox.receive(message)
            relay.clock = relay.clock.addingTimeInterval(1)
        }
        XCTAssertEqual(relay.posted.map(\.content.interruptionLevel), [.timeSensitive])
    }

    // MARK: - A refused speaker request (step 57; codex-7)

    private static let headphones = SirenOutput(port: .headphones, name: "Headphones")

    /// codex-7: iOS refuses the speaker request while wired headphones take the sound: where the siren plays is
    /// reported, as for the fallback. Red at the round's red commit: the siren was taken as on the speaker.
    func testARefusedSpeakerRequestIsReported() {
        let siren = SirenPlayer()
        var reported: [SirenOutput] = []
        siren.onPlayingElsewhere = { reported.append($0) }
        siren.outputsForTesting = [Self.headphones]
        siren.speakerOverrideFailuresForTesting = 1
        siren.start(onSpeaker: true)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the siren sounds")
        XCTAssertEqual(reported, [Self.headphones])
        siren.stop()
    }

    /// The same for a request refused at a change of route while the siren plays. Red at the round's red commit.
    func testASpeakerRequestRefusedAtARouteChangeIsReported() {
        let siren = SirenPlayer()
        var reported: [SirenOutput] = []
        siren.onPlayingElsewhere = { reported.append($0) }
        siren.start(onSpeaker: true)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the siren sounds")
        settle(0.5)   // iOS's own notices of the start's route changes
        siren.outputsForTesting = [Self.headphones]
        siren.speakerOverrideFailuresForTesting = 1
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        XCTAssertTrue(pump(until: { reported == [Self.headphones] }, timeout: 2), "reported")
        siren.stop()
    }

    // MARK: - Helpers

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

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

    /// The watch app's relay inbox with a clock, a store and a notification centre of its own, which fails the next
    /// `failures` posts.
    @MainActor
    private final class RelayRig {
        let suite = "Item170Relay-\(UUID().uuidString)"
        let defaults: UserDefaults
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var posted: [UNNotificationRequest] = []
        var failures = 0
        private(set) var inbox: WatchRelayInbox!

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            inbox = WatchRelayInbox(defaults: defaults, now: { [unowned self] in self.clock },
                                    post: { [unowned self] request in
                                        if self.failures > 0 {
                                            self.failures -= 1
                                            throw CocoaError(.featureUnsupported)
                                        }
                                        self.posted.append(request)
                                    })
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
