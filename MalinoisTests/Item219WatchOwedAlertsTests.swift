//
//  Item219WatchOwedAlertsTests.swift
//  MalinoisTests
//
//  BACKLOG item 219 (1.13, item 240's list; docs/design/1.13-fixes.md, part 1; the owner, 2026-11-12: "as you
//  recommend, wording approved": D1 and D2 (a)). The iPhone hands a queued alert to the watch once, and the watch app
//  gives its background wake back after 10 seconds at the latest (item 212). Until the inbox had handled it, the alert
//  lived only in memory: shown when the app next ran, or lost if watchOS ended the suspended app first (item 218's
//  Codex-2). Now the watch writes each alert down before the hand-over returns, takes it off once handled (posted on its
//  own, added to the summary, or passed over as one already shown), and hands those left to the inbox at each launch and
//  each wake; a refused post is tried three times in all; the list takes the newest 100. Through the real inbox and the
//  real wakes' keeper, with settings, a clock and a notification centre of the test's own; the watch app's own target
//  is read from the source tree. Written before the fix, red at that commit (where the list writes nothing down).
//

import UserNotifications
import XCTest
@testable import Malinois

@MainActor
final class Item219WatchOwedAlertsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    // MARK: - Written down at the hand-over, taken off once handled

    /// An alert handed over is on the list at once.
    func testAnAlertHandedOverIsWrittenDownAtOnce() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier])
    }

    /// An alert handed over twice (a hand-over the link makes again after a stop) is owed once, its refusals counted on.
    func testAnAlertHandedOverTwiceIsOwedOnce() async throws {
        let rig = try Rig(refusing: true)
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        _ = await rig.inbox.receive(alert)                    // refused once
        WatchRelayOwed.note(alert, defaults: rig.defaults)     // handed over again
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier], "owed once")
        XCTAssertEqual(WatchRelayOwed.all(defaults: rig.defaults).map(\.refusedPosts), [1], "its refusal still counted")
    }

    /// The watch app writes each alert down before the hand-over returns, ahead of handing it to the inbox.
    func testTheWatchAppWritesEachAlertDownBeforeTheHandOverReturns() throws {
        let body = try Self.watchAppFunction("func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any])")
        let note = try XCTUnwrap(body.range(of: "WatchRelayOwed.note(message)"), "written down: \(body)")
        let task = try XCTUnwrap(body.range(of: "Task { @MainActor in"), "handed to the inbox in a task: \(body)")
        XCTAssertLessThan(note.lowerBound, task.lowerBound, "before the hand-over returns")
    }

    /// Posted on its own: off the list.
    func testAPostedAlertLeavesTheList() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier], "owed until handled")
        let posted = await rig.inbox.receive(alert)
        XCTAssertTrue(posted)
        XCTAssertEqual(rig.owed, [])
    }

    /// Added to the summary (its event more than an hour old): off the list.
    func testASummedAlertLeavesTheList() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 90)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier], "owed until handled")
        let posted = await rig.inbox.receive(alert)
        XCTAssertTrue(posted)
        XCTAssertEqual(rig.posted.first?.identifier.hasPrefix(WatchRelaySummary.identifierPrefix), true, "in the summary")
        XCTAssertEqual(rig.owed, [])
    }

    /// Passed over as one already shown (the queued copy after the live one): off the list.
    func testARepeatLeavesTheList() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        _ = await rig.inbox.receive(alert)                       // the live copy, shown
        WatchRelayOwed.note(alert, defaults: rig.defaults)        // the queued copy, written down at its hand-over
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier], "owed until handled")
        let posted = await rig.inbox.receive(alert)
        XCTAssertFalse(posted, "passed over")
        XCTAssertEqual(rig.posted.count, 1)
        XCTAssertEqual(rig.owed, [])
    }

    // MARK: - A refused post (D1 (a))

    /// A post watchOS refuses leaves the alert owed; it is tried again at the next runs, three tries in all, then dropped.
    func testARefusedPostIsTriedThreeTimesInAllThenDropped() async throws {
        let rig = try Rig(refusing: true)
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        let first = await rig.inbox.receive(alert)
        XCTAssertFalse(first)
        XCTAssertEqual(WatchRelayOwed.all(defaults: rig.defaults).map(\.refusedPosts), [1], "still owed, its refusal counted")
        for run in 2...3 {
            let tasks = rig.nextRun().receiveOwed()
            XCTAssertEqual(tasks.count, 1, "run \(run) hands it in again")
            for task in tasks { _ = await task.value }
        }
        XCTAssertEqual(rig.attempts, 3, "three tries in all")
        XCTAssertEqual(rig.owed, [], "then dropped")
        XCTAssertTrue(rig.nextRun().receiveOwed().isEmpty, "never a fourth")
    }

    // MARK: - A stop between the two writes

    /// The record of alerts shown is written before the list lets the alert go, so a stop between the two writes leaves
    /// it on both, never on neither.
    func testTheRecordOfAlertsShownIsWrittenBeforeTheListLetsGo() async throws {
        let rig = try Rig(recording: true)
        defer { rig.cleanUp() }
        let alert = rig.alert(.disarm, minutesAgo: 1)   // a disarm: no burst record is written
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        let writes = try XCTUnwrap(rig.writes)
        writes.clear()
        _ = await rig.inbox.receive(alert)
        let keys = writes.keys
        let record = try XCTUnwrap(keys.lastIndex(of: WatchRelayInbox.memoryKey), "the record written: \(keys)")
        let list = try XCTUnwrap(keys.lastIndex(of: WatchRelayOwed.key), "the list written: \(keys)")
        XCTAssertLessThan(record, list, "the record first: \(keys)")
        XCTAssertEqual(rig.owed, [])
    }

    /// The list is written only when it changes (1.13's chain i, 2026-11-13): an alert not on it, as the live copy never
    /// is, writes nothing when handled or refused, so the record of alerts shown stays the only write for an alert the
    /// open app shows (item 134's X2); and an alert already owed writes nothing when it is handed over again.
    func testTheListIsWrittenOnlyWhenItChanges() throws {
        let rig = try Rig(recording: true)
        defer { rig.cleanUp() }
        let writes = try XCTUnwrap(rig.writes)
        writes.clear()
        let live = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.handled(live.notificationIdentifier, defaults: rig.defaults)
        XCTAssertFalse(WatchRelayOwed.postRefused(live.notificationIdentifier, defaults: rig.defaults))
        XCTAssertEqual(writes.keys, [], "an alert not on the list: nothing written")
        let queued = rig.alert(.tamper, minutesAgo: 2)
        WatchRelayOwed.note(queued, defaults: rig.defaults)
        XCTAssertEqual(writes.keys, [WatchRelayOwed.key], "written down")
        writes.clear()
        WatchRelayOwed.note(queued, defaults: rig.defaults)
        XCTAssertEqual(writes.keys, [], "handed over again: nothing written")
        WatchRelayOwed.handled(queued.notificationIdentifier, defaults: rig.defaults)
        XCTAssertEqual(writes.keys, [WatchRelayOwed.key], "taken off: written")
        XCTAssertEqual(rig.owed, [])
    }

    /// A stop after the record of alerts shown and before the list's write: the next run passes the alert over, with no
    /// second post, and lets it go.
    func testAnAlertOnBothListsIsPassedOverAtTheNextRun() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        _ = await rig.inbox.receive(alert)                    // shown, and in the record
        WatchRelayOwed.note(alert, defaults: rig.defaults)     // still on the list, as a stop between the writes leaves it
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier])
        for task in rig.nextRun().receiveOwed() { _ = await task.value }
        XCTAssertEqual(rig.posted.count, 1, "no second post")
        XCTAssertEqual(rig.owed, [])
    }

    // MARK: - The next run

    /// At the next run the owed alerts are handled, oldest first; one more than an hour old joins the summary.
    func testTheNextRunPostsWhatWasOwedOldestFirst() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let old = rig.alert(.tamper, minutesAgo: 90)
        let earlier = rig.alert(.disarm, minutesAgo: 20)
        let later = rig.alert(.tamper, minutesAgo: 10)
        for alert in [later, old, earlier] { WatchRelayOwed.note(alert, defaults: rig.defaults) }
        let tasks = rig.nextRun().receiveOwed()
        XCTAssertEqual(tasks.count, 3)
        for task in tasks { _ = await task.value }
        guard rig.posted.count == 3 else { return XCTFail("three posts, not \(rig.posted.count)") }
        XCTAssertTrue(rig.posted[0].identifier.hasPrefix(WatchRelaySummary.identifierPrefix), "the oldest, into the summary")
        XCTAssertEqual(rig.posted.dropFirst().map(\.identifier), [earlier.notificationIdentifier, later.notificationIdentifier])
        XCTAssertEqual(rig.owed, [])
    }

    /// An owed alert handed in and not yet handled is not handed in again meanwhile (a launch for a wake hands them in
    /// twice), so a refused post is not tried twice at once.
    func testAnOwedAlertIsNotHandedInTwiceAtOnce() async throws {
        let rig = try Rig(holdingPosts: true)
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        let next = rig.nextRun()
        let first = next.receiveOwed()
        let second = next.receiveOwed()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0, "already in hand")
        try await rig.waitForAHeldPost()
        rig.letPostsGo()
        for task in first + second { _ = await task.value }
        XCTAssertEqual(rig.attempts, 1)
        XCTAssertEqual(rig.owed, [])
    }

    /// A later wake of the same run hands a refused alert in again: once handled, an alert is no longer in hand.
    func testALaterWakeOfTheSameRunHandsARefusedAlertInAgain() async throws {
        let rig = try Rig(refusing: true)
        defer { rig.cleanUp() }
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        let run = rig.nextRun()
        for task in run.receiveOwed() { _ = await task.value }   // at launch: refused
        let again = run.receiveOwed()                             // at the next wake, the same run
        XCTAssertEqual(again.count, 1, "handed in again")
        for task in again { _ = await task.value }
        XCTAssertEqual(rig.attempts, 2)
        XCTAssertEqual(WatchRelayOwed.all(defaults: rig.defaults).map(\.refusedPosts), [2])
    }

    // MARK: - The wake's cutoff (Codex's ask in item 218)

    /// With the wakes' keeper and the real inbox: a post still waiting when the deadline gives the wake back leaves the
    /// alert owed, and the next run shows it.
    func testAnAlertCutOffByTheWakesDeadlineIsShownAtTheNextRun() async throws {
        let rig = try Rig(holdingPosts: true)
        defer { rig.cleanUp() }
        let wakes = WakeRig(), wake = Wake()
        wakes.keeper.hold(wake)
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)   // at the hand-over
        let handling = Task { await rig.inbox.receive(alert) }
        try await rig.waitForAHeldPost()
        wakes.fireAll()                                      // the deadline: the wake given back mid-post
        XCTAssertEqual(wakes.ended, [ObjectIdentifier(wake)])
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier], "still owed: watchOS may end the app now")
        // watchOS ends the suspended app, and this run's post never finishes. The next run shows the alert.
        rig.holdPosts = false
        for task in rig.nextRun().receiveOwed() { _ = await task.value }
        XCTAssertEqual(rig.posted.map(\.identifier), [alert.notificationIdentifier], "shown at the next run")
        XCTAssertEqual(rig.owed, [])
        rig.letPostsGo()   // the first run's post, which watchOS would never have let finish
        _ = await handling.value
    }

    /// Several slow reads of the notification list in one run (item 218's allowance): every alert posted, none owed.
    func testSeveralSlowReadsOfTheListLeaveNoAlertOwed() async throws {
        let rig = try Rig(listDelay: .milliseconds(50), listDeadline: 0.12)
        defer { rig.cleanUp() }
        let alerts = (1...3).map { rig.alert(.tamper, minutesAgo: Double(10 - $0)) }
        for alert in alerts { WatchRelayOwed.note(alert, defaults: rig.defaults) }
        XCTAssertEqual(rig.owed.count, 3, "owed until handled")
        let handling = alerts.map { alert in Task { await rig.inbox.receive(alert) } }
        for task in handling { _ = await task.value }
        XCTAssertEqual(rig.posted.count, 3)
        XCTAssertEqual(rig.owed, [])
    }

    // MARK: - The limit (D2 (a)), and a list that cannot be read

    /// The list takes the newest 100 by their events' times.
    func testTheListTakesTheNewest100() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alerts = (0...100).map { rig.alert(.tamper, minutesAgo: Double(200 - $0)) }   // 101 alerts, oldest first
        for alert in alerts.reversed() { WatchRelayOwed.note(alert, defaults: rig.defaults) }
        XCTAssertEqual(WatchRelayOwed.all(defaults: rig.defaults).map(\.message), Array(alerts.dropFirst()))
    }

    /// A list that cannot be read starts again empty, and takes alerts again.
    func testAListThatCannotBeReadStartsAgainEmpty() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.defaults.set(Data("not a list".utf8), forKey: WatchRelayOwed.key)
        XCTAssertEqual(WatchRelayOwed.all(defaults: rig.defaults), [])
        let alert = rig.alert(.tamper, minutesAgo: 1)
        WatchRelayOwed.note(alert, defaults: rig.defaults)
        XCTAssertEqual(rig.owed, [alert.notificationIdentifier])
    }

    // MARK: - The watch app hands the owed alerts in

    /// At launch, before the link can hand new ones over, and at each wake for the link; each counted in flight, so a
    /// wake is held for them as for new ones.
    func testTheWatchAppHandsTheOwedAlertsInAtLaunchAndAtEachWake() throws {
        let launch = try Self.watchAppFunction("func applicationDidFinishLaunching()")
        let handOwed = try XCTUnwrap(launch.range(of: "handOwedAlerts()"), "at launch: \(launch)")
        let activate = try XCTUnwrap(launch.range(of: "activateLink()"), "the link: \(launch)")
        XCTAssertLessThan(handOwed.lowerBound, activate.lowerBound, "before the link can hand new ones over")
        let wake = try Self.watchAppFunction("func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>)")
        XCTAssertTrue(wake.contains("handOwedAlerts()"), "at each wake for the link: \(wake)")
        let hand = try Self.watchAppFunction("private func handOwedAlerts()")
        XCTAssertTrue(hand.contains("relayInbox.receiveOwed()"), hand)
        XCTAssertTrue(hand.contains("alertsInFlight.withLock { $0 += tasks.count }"), "counted in flight: \(hand)")
    }

    // MARK: - Helpers

    /// The watch app's function that begins with `signature`, to its closing brace (its own target, which this suite
    /// cannot build: read from the source tree, as built).
    private static func watchAppFunction(_ signature: String) throws -> String {
        let source = try String(contentsOf: root.appendingPathComponent("MalinoisWatch/WatchAppDelegate.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) in the watch app")
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex), "its end")
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The watch app's inbox with settings, a clock and a notification centre of the test's own; each new run is a new
    /// inbox over the same settings, as at a launch.
    @MainActor
    private final class Rig {
        let suite = "Item219Relay-\(UUID().uuidString)"
        let defaults: UserDefaults
        /// The keys written, in order, when the rig records them.
        let writes: Writes?
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var posted: [UNNotificationRequest] = []
        /// Every post asked for, refused or not.
        private(set) var attempts = 0
        var holdPosts: Bool
        private let refusing: Bool
        private var held: [CheckedContinuation<Void, Never>] = []
        private let listDelay: Duration?
        private let listDeadline: TimeInterval
        private(set) var inbox: WatchRelayInbox!

        init(refusing: Bool = false, holdingPosts: Bool = false, recording: Bool = false,
             listDelay: Duration? = nil, listDeadline: TimeInterval = 2) throws {
            if recording {
                let recorder = try XCTUnwrap(RecordingDefaults(suiteName: suite))
                defaults = recorder
                writes = recorder.writes
            } else {
                defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                writes = nil
            }
            self.refusing = refusing
            holdPosts = holdingPosts
            self.listDelay = listDelay
            self.listDeadline = listDeadline
            inbox = nextRun()
        }

        /// The owed alerts' identifiers, oldest first.
        var owed: [String] { WatchRelayOwed.all(defaults: defaults).map(\.message.notificationIdentifier) }

        func alert(_ kind: WatchAlertMessage.Kind, minutesAgo: Double) -> WatchAlertMessage {
            WatchAlertMessage(kind: kind, eventID: UUID(), at: clock.addingTimeInterval(-minutesAgo * 60))
        }

        /// The watch app at its next launch: a new inbox over the same settings.
        func nextRun() -> WatchRelayInbox {
            WatchRelayInbox(defaults: defaults, now: { [unowned self] in self.clock },
                            post: { [unowned self] request in try await self.post(request) },
                            delivered: { [listDelay] in
                                if let listDelay { try? await Task.sleep(for: listDelay) }
                                return []
                            },
                            listDeadline: listDeadline)
        }

        private func post(_ request: UNNotificationRequest) async throws {
            attempts += 1
            if holdPosts { await withCheckedContinuation { held.append($0) } }
            if refusing { throw CocoaError(.featureUnsupported) }
            posted.append(request)
        }

        /// Waits until a post is held; after three seconds, fails.
        func waitForAHeldPost(file: StaticString = #filePath, line: UInt = #line) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while held.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(held.isEmpty, "a post held", file: file, line: line)
        }

        /// Lets every held post go, and holds no more.
        func letPostsGo() {
            holdPosts = false
            let all = held
            held.removeAll()
            all.forEach { $0.resume() }
        }

        /// Lets every held post go, so no test's run waits on one after it ends, and removes the settings.
        func cleanUp() {
            letPostsGo()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// The keys a store's writes went to, in order.
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []

        var keys: [String] { lock.withLock { written } }
        func add(_ key: String) { lock.withLock { written.append(key) } }
        func clear() { lock.withLock { written.removeAll() } }
    }

    /// Settings that note the key of each write.
    private final class RecordingDefaults: UserDefaults {
        let writes = Writes()

        override func set(_ value: Any?, forKey defaultName: String) {
            writes.add(defaultName)
            super.set(value, forKey: defaultName)
        }
    }

    /// A stand-in for watchOS's wake.
    private final class Wake {}

    /// The wakes' keeper, with what it gave back and the deadlines it set, which the test fires itself.
    @MainActor
    private final class WakeRig {
        var ended: [ObjectIdentifier] = []
        private var scheduled: [@MainActor @Sendable () -> Void] = []
        private(set) lazy var keeper = WatchLinkWakes<Wake>(
            end: { [unowned self] wake in self.ended.append(ObjectIdentifier(wake)) },
            after: { [unowned self] _, action in self.scheduled.append(action) })

        /// Runs every deadline set so far, as if its time had come.
        func fireAll() {
            let due = scheduled
            scheduled.removeAll()
            due.forEach { $0() }
        }
    }
}
