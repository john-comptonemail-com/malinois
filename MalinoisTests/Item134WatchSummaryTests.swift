//
//  Item134WatchSummaryTests.swift
//  MalinoisTests
//
//  BACKLOG 134 (the owner's ruling, 2026-10-18: "1 a 2 a 3 b"; ADR 0051). After four days off, an Apple
//  Watch showed every tamper alert its iPhone had queued, one by one, and a relayed alert named its
//  event's time only when it arrived more than a minute late. Now a relayed alert whose event is more than
//  an hour old joins one summary ("While your watch was away: ..."), which lights the screen and taps when
//  it starts and then changes its count quietly (the owner, 2026-10-18: "approved, and make the screen
//  light up/tap"); every relayed alert shown on its own names its event's time. iCloud's alerts are not
//  changed (ADR 0046). The watch's handling is driven here through `WatchRelayInbox`, which this target
//  compiles as it does `WatchAlertStatus.swift`, with a clock, a store and a notification centre of the
//  test's own. Written before the change, red at that commit (against compile-only stubs).
//  Codex's review of build 73 (c56952a): X1, the watch remembered only the newest 50 alerts it had shown or
//  counted, so a copy of an alert counted earlier, or the late queued copies of more than 50 alerts shown
//  live, were counted again, the second as a chain in which each copy pushed out the next; X2, the shown
//  alerts and the summary were kept in two writes, which an interruption could leave disagreeing. The
//  tests for them were written before their fix, red at that commit.
//  Codex's second look (90b4251): Y1, the alerts a summary counted were forgotten when a new summary
//  started, so a late copy of one was counted again; Y2, 1.6's key was written after the record, so an
//  interruption between them left it behind, and at the 500 the merge at launch brought back an alert
//  already forgotten and pushed out one still remembered. Their tests too were written first, red.
//  Codex's third look (1c3deeb): Z1, past the 1,000 summed-up alerts a replay in order counted every copy
//  again, each forgotten one pushing out the next; Z2, after 72 and back, the merge kept the record's old
//  place for an alert 72 had just shown again, so it was pushed out. Their tests too were written first, red.
//

import XCTest
import UserNotifications
@testable import Malinois

/// The watch's relay handling with a clock, a store and a notification centre of its own. The centre
/// records every post it is asked for, can fail them, and can hold them until released.
@MainActor
private final class Rig {
    let suiteName = "MalinoisItem134-\(UUID().uuidString)"
    let defaults: UserDefaults
    var now: Date
    /// Every request the watch asked to post, failed ones included.
    var attempts: [UNNotificationRequest] = []
    /// The requests posted.
    var posted: [UNNotificationRequest] = []
    var failing = false
    var holding = false
    var held: [CheckedContinuation<Void, Never>] = []

    init(now: Date) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        self.now = now
    }

    /// The watch app's inbox, as a launch builds it from what the watch keeps.
    func inbox() -> WatchRelayInbox {
        WatchRelayInbox(defaults: defaults, now: { [unowned self] in self.now },
                        post: { [unowned self] request in try await self.post(request) })
    }

    func post(_ request: UNNotificationRequest) async throws {
        attempts.append(request)
        if holding { await withCheckedContinuation { held.append($0) } }
        if failing { throw NSError(domain: "Item134", code: 1) }
        posted.append(request)
    }

    func release() {
        let waiting = held
        held.removeAll()
        waiting.forEach { $0.resume() }
    }

    func tearDown() {
        release()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Defaults that record every write, in order, with its value (the method of Codex's X2 probe).
private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    struct Write {
        let key: String
        let value: Any?
    }

    var writes: [Write] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(Write(key: defaultName, value: value))
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class Item134WatchSummaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem134")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// A rig whose store is removed when the test ends.
    private func rig(at now: Date) throws -> Rig {
        let rig = try Rig(now: now)
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    /// A local date in 2026, so "the same day" does not depend on the time zone the tests run in.
    private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private func dated(_ date: Date) -> String { "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time(date))" }

    private func alert(_ kind: WatchAlertMessage.Kind = .tamper, at: Date) -> WatchAlertMessage {
        WatchAlertMessage(kind: kind, eventID: UUID(), at: at)
    }

    private func isSummary(_ request: UNNotificationRequest) -> Bool {
        request.identifier.hasPrefix(WatchRelaySummary.identifierPrefix)
    }

    /// `count` relayed alerts' notification identifiers, for records built by hand.
    private func identifiers(_ count: Int) -> [String] {
        (0..<count).map { _ in alert(at: Date()).notificationIdentifier }
    }

    /// `count` summed-up alerts, events a minute apart from `start`, for records built by hand.
    private func summedAlerts(_ count: Int, from start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> [WatchRelayMemory.Summed] {
        (0..<count).map { WatchRelayMemory.Summed(id: alert(at: start).notificationIdentifier, at: start.addingTimeInterval(Double($0) * 60)) }
    }

    /// What the watch keeps, as the next launch reads it.
    private func kept(_ rig: Rig) -> WatchRelayMemory? {
        WatchRelayMemory.read(rig.defaults.data(forKey: WatchRelayInbox.memoryKey))
    }

    // MARK: - The rule

    /// An alert whose event is more than an hour old when the watch handles it is summed up; an hour
    /// exactly, or an event time ahead of the watch's clock, is new. A fixed hour, no setting.
    func testAnAlertMoreThanAnHourOldIsSummedUp() throws {
        let now = try local(10, 19, 9, 0)
        let ago = { (seconds: TimeInterval) in self.alert(at: now.addingTimeInterval(-seconds)) }
        XCTAssertEqual(WatchAlertMessage.summarizedAfter, 3600, "a fixed hour")
        XCTAssertFalse(ago(30).isSummarized(handledAt: now), "on time")
        XCTAssertFalse(ago(3600).isSummarized(handledAt: now), "an hour exactly is still new")
        XCTAssertTrue(ago(3601).isSummarized(handledAt: now))
        XCTAssertTrue(ago(4 * 86_400).isSummarized(handledAt: now), "after four days off")
        XCTAssertFalse(ago(-600).isSummarized(handledAt: now), "an event time ahead of the watch's clock counts as new")
    }

    // MARK: - The texts (the owner's approved wording, 2026-10-18)

    /// Every relayed alert shown on its own names its event's time, tamper and disarm alike, on time
    /// or late; with the date when the event was on another day. Alert text: no em-dash (B16).
    func testEveryRelayedAlertNamesItsEventsTime() throws {
        let at = try local(10, 19, 8, 59)
        for (kind, words) in [(WatchAlertMessage.Kind.tamper, "Tamper detected on your device"),
                              (.disarm, "Malinois was disarmed on one of your devices")] {
            let message = alert(kind, at: at)
            XCTAssertEqual(message.body(deliveredAt: at.addingTimeInterval(20)), "\(words) at \(time(at)).", "on time, with the time")
            XCTAssertEqual(message.body(deliveredAt: at.addingTimeInterval(1800)), "\(words) at \(time(at)).", "late, the same day")
        }
        let lateEvening = try local(10, 18, 23, 50)
        let overMidnight = alert(.disarm, at: lateEvening).body(deliveredAt: lateEvening.addingTimeInterval(20 * 60))
        XCTAssertEqual(overMidnight, "Malinois was disarmed on one of your devices at \(dated(lateEvening)).", "another day: with the date")
        XCTAssertFalse(overMidnight.contains("\u{2014}"), overMidnight)
    }

    /// The summary's words: the count, the latest event's kind and time, and where the detail is.
    func testTheSummarysWording() throws {
        let now = try local(10, 19, 9, 0)
        let latest = try local(10, 15, 15, 42)
        let one = WatchRelaySummary(identifier: WatchRelaySummary.identifierPrefix + "a", count: 1, latestKind: .tamper,
                                    latestAt: latest, changedAt: now)
        XCTAssertEqual(one.body(at: now),
                       "While your watch was away: 1 Malinois alert, a tamper at \(dated(latest)). See your iPhone's Event Log.")
        var five = one
        five.count = 5
        five.latestKind = .disarm
        XCTAssertEqual(five.body(at: now),
                       "While your watch was away: 5 Malinois alerts, the latest a disarm at \(dated(latest)). See your iPhone's Event Log.")
        let thisMorning = try local(10, 19, 7, 30)
        var today = five
        today.latestKind = .tamper
        today.latestAt = thisMorning
        XCTAssertEqual(today.body(at: now),
                       "While your watch was away: 5 Malinois alerts, the latest a tamper at \(time(thisMorning)). See your iPhone's Event Log.",
                       "the same day: the time alone")
        XCTAssertEqual(one.request(now: now).content.title, "Malinois")
        XCTAssertFalse(five.body(at: now).contains("\u{2014}"))
    }

    // MARK: - One summary

    /// Old alerts join one summary, the latest event by its time; an old alert more than an hour after the
    /// summary last changed (or with the watch's clock set back by more) starts a new one, and so does a
    /// summary at its count limit, rather than overflow. (Each alert counted once is the inbox's: below.)
    func testOldAlertsJoinOneSummaryUntilAnHourPassesWithoutOne() throws {
        let now = try local(10, 19, 9, 0)
        let fourDays = alert(.tamper, at: now.addingTimeInterval(-4 * 86_400))
        let first = WatchRelaySummary.adding(fourDays, to: nil, at: now)
        XCTAssertTrue(first.identifier.hasPrefix(WatchRelaySummary.identifierPrefix))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.latestAt, fourDays.at)
        XCTAssertEqual(first.changedAt, now)

        let twoDays = alert(.disarm, at: now.addingTimeInterval(-2 * 86_400))
        let second = WatchRelaySummary.adding(twoDays, to: first, at: now.addingTimeInterval(3600))
        XCTAssertEqual(second.identifier, first.identifier, "within the hour: the same summary")
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.latestKind, .disarm)
        XCTAssertEqual(second.latestAt, twoDays.at)
        XCTAssertEqual(second.changedAt, now.addingTimeInterval(3600))

        let threeDays = alert(.tamper, at: now.addingTimeInterval(-3 * 86_400))
        let third = WatchRelaySummary.adding(threeDays, to: second, at: second.changedAt.addingTimeInterval(60))
        XCTAssertEqual(third.count, 3)
        XCTAssertEqual(third.latestKind, .disarm, "an earlier event joining later leaves the latest as it was")
        XCTAssertEqual(third.latestAt, twoDays.at)

        let later = alert(.tamper, at: now.addingTimeInterval(-86_400))
        let fresh = WatchRelaySummary.adding(later, to: third, at: third.changedAt.addingTimeInterval(3601))
        XCTAssertNotEqual(fresh.identifier, third.identifier, "more than an hour without one: a new summary")
        XCTAssertEqual(fresh.count, 1)
        XCTAssertNotEqual(WatchRelaySummary.adding(later, to: third, at: third.changedAt.addingTimeInterval(-3601)).identifier,
                          third.identifier, "a clock set back by more than an hour: a new summary")
        var full = third
        full.count = WatchRelaySummary.countLimit
        XCTAssertEqual(WatchRelaySummary.adding(later, to: full, at: full.changedAt).count, 1, "a full summary starts again")
    }

    /// A summary's first post lights the screen and taps, at the ordinary level (not Time Sensitive); each
    /// later post of it changes the count quietly, under the same identifier. While the watch app is open the
    /// quiet updates are listed, not shown as banners; everything else shows as before.
    func testASummaryTapsWhenItStartsAndThenChangesQuietly() throws {
        let now = try local(10, 19, 9, 0)
        let started = WatchRelaySummary.adding(alert(at: now.addingTimeInterval(-86_400)), to: nil, at: now)
        let grown = WatchRelaySummary.adding(alert(at: now.addingTimeInterval(-7200)), to: started, at: now)
        let first = started.request(now: now)
        let update = grown.request(now: now)
        XCTAssertEqual(first.identifier, started.identifier)
        XCTAssertEqual(update.identifier, first.identifier, "posted again under its identifier, replacing the copy before")
        XCTAssertNil(first.trigger)
        XCTAssertEqual(first.content.interruptionLevel, .active, "lights the screen; not Time Sensitive")
        XCTAssertNotNil(first.content.sound, "taps")
        XCTAssertEqual(update.content.interruptionLevel, .passive, "the count changes quietly")
        XCTAssertNil(update.content.sound)

        XCTAssertEqual(WatchRelayInbox.presentationOptions(for: update.content), [.list])
        XCTAssertEqual(WatchRelayInbox.presentationOptions(for: first.content), [.banner, .sound, .list])
        let tamper = WatchRelayInbox.request(for: alert(at: now), now: now)
        XCTAssertEqual(tamper.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(WatchRelayInbox.presentationOptions(for: tamper.content), [.banner, .sound, .list])
    }

    // MARK: - Damaged values

    /// A time that is not a finite number is not one this app sent.
    func testAnUnreadableTimeIsIgnored() throws {
        let sent = alert(at: Date()).userInfo
        XCTAssertNotNil(WatchAlertMessage(userInfo: sent))
        for bad in [Double.nan, .infinity, -.infinity] {
            var damaged = sent
            damaged["at"] = bad
            XCTAssertNil(WatchAlertMessage(userInfo: damaged), "\(bad)")
        }
    }

    /// What the watch keeps is read back whole; one that cannot be read is ignored; a summary in it that
    /// cannot be trusted (a count out of range, an identifier that is not a summary's) is dropped while both
    /// lists are kept; a list longer than its limit keeps its newest entries.
    func testAKeptMemoryThatCannotBeTrustedIsIgnored() throws {
        let now = try local(10, 19, 9, 0)
        let summary = WatchRelaySummary(identifier: WatchRelaySummary.identifierPrefix + "kept", count: 3,
                                        latestKind: .disarm, latestAt: now.addingTimeInterval(-7200), changedAt: now)
        let memory = WatchRelayMemory(shown: identifiers(2), summed: summedAlerts(3), summary: summary)
        XCTAssertEqual(WatchRelayMemory.read(try JSONEncoder().encode(memory)), memory)
        XCTAssertNil(WatchRelayMemory.read(nil))
        XCTAssertNil(WatchRelayMemory.read(Data("not a record".utf8)))
        for damaged in [0, -5, WatchRelaySummary.countLimit + 1].map({ count in
                            WatchRelaySummary(identifier: summary.identifier, count: count, latestKind: .tamper, latestAt: now, changedAt: now)
                        }) + [WatchRelaySummary(identifier: "malinois-relay-tamper-\(UUID().uuidString)", count: 3,
                                                latestKind: .tamper, latestAt: now, changedAt: now)] {
            let read = WatchRelayMemory.read(try JSONEncoder().encode(WatchRelayMemory(shown: memory.shown, summed: memory.summed, summary: damaged)))
            XCTAssertEqual(read, WatchRelayMemory(shown: memory.shown, summed: memory.summed, summary: nil), "count \(damaged.count), \(damaged.identifier)")
        }
        let long = WatchRelayMemory(shown: identifiers(WatchAlertStatus.rememberedRelayLimit + 2),
                                    summed: summedAlerts(WatchRelayMemory.summedLimit + 2), summary: nil)
        let trimmed = try XCTUnwrap(WatchRelayMemory.read(try JSONEncoder().encode(long)))
        XCTAssertEqual(trimmed.shown, Array(long.shown.suffix(WatchAlertStatus.rememberedRelayLimit)))
        XCTAssertEqual(trimmed.summed, Array(long.summed.suffix(WatchRelayMemory.summedLimit)))
    }

    // MARK: - Through the watch's handling

    /// The owner's case: after days off, the queue arrives in order. The alerts more than an hour old become
    /// one summary, posted again as each joins, tapping only when it starts; the last hour's alerts show as
    /// before, each with its time.
    func testAfterDaysAwayOldAlertsBecomeOneSummaryAndTheLastHourShowsAsBefore() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        let old = [alert(.tamper, at: now.addingTimeInterval(-4 * 86_400)), alert(.disarm, at: now.addingTimeInterval(-3 * 86_400)),
                   alert(.tamper, at: now.addingTimeInterval(-2 * 86_400)), alert(.disarm, at: now.addingTimeInterval(-86_400)),
                   alert(.tamper, at: now.addingTimeInterval(-7200))]
        let lastHour = [alert(.disarm, at: now.addingTimeInterval(-1800)), alert(.tamper, at: now.addingTimeInterval(-60))]
        for message in old + lastHour {
            let posted = await inbox.receive(message)
            XCTAssertTrue(posted)
        }

        XCTAssertEqual(rig.posted.count, 7)
        let summaries = Array(rig.posted.prefix(5))
        XCTAssertTrue(summaries.allSatisfy { isSummary($0) }, summaries.map(\.identifier).description)
        XCTAssertEqual(Set(summaries.map(\.identifier)).count, 1, "one summary, posted again as each old alert joins")
        XCTAssertEqual(summaries.map(\.content.interruptionLevel), [.active, .passive, .passive, .passive, .passive],
                       "it taps when it starts, then changes quietly")
        XCTAssertNotNil(summaries[0].content.sound)
        XCTAssertTrue(summaries.dropFirst().allSatisfy { $0.content.sound == nil })
        XCTAssertEqual(summaries.last?.content.body,
                       "While your watch was away: 5 Malinois alerts, the latest a tamper at \(time(old[4].at)). See your iPhone's Event Log.")

        let shown = Array(rig.posted.suffix(2))
        XCTAssertEqual(shown.map(\.identifier), lastHour.map(\.notificationIdentifier))
        XCTAssertEqual(shown.map(\.content.body), ["Malinois was disarmed on one of your devices at \(time(lastHour[0].at)).",
                                                   "Tamper detected on your device at \(time(lastHour[1].at))."])
        XCTAssertEqual(shown.map(\.content.interruptionLevel), [.active, .timeSensitive])
        XCTAssertTrue(shown.allSatisfy { $0.content.sound != nil })
    }

    /// The whole path but WatchConnectivity itself: the iPhone's relay sends its new incidents and a disarm as they
    /// happen, as the payload the link carries; the watch, back four days later, reads those payloads and sums them
    /// up; an alert the relay sends on the day the watch is back shows on its own, with its time.
    func testTheIPhonesQueuedAlertsReachTheWatchDaysLaterAsOneSummary() async throws {
        let store = EventStore()
        let settings = AppSettings()
        settings.notifyOtherDevices = true
        var payloads: [[String: Any]] = []
        let relay = WatchAlertRelay(store: store, settings: settings, entitlements: ProEntitlements(resolvedAs: .trial),
                                    send: { payloads.append($0.userInfo) })
        relay.start()
        let disarmed = try local(10, 15, 15, 42)
        for (minutesBefore, change) in [(2.0, nil), (1.0, nil), (0.0, "disarmed")] as [(TimeInterval, String?)] {
            let at = disarmed.addingTimeInterval(-minutesBefore * 60)
            store.add(Event(startDate: at, endDate: at, triggeredSensors: change == nil ? [.motion] : [], stateChange: change))
        }
        XCTAssertEqual(payloads.count, 3, "the iPhone relays two incidents and the disarm")

        let rig = try rig(at: local(10, 19, 9, 0))   // the watch comes back four days later
        let inbox = rig.inbox()
        for payload in payloads {
            let message = try XCTUnwrap(WatchAlertMessage(userInfo: payload), "the watch reads what the iPhone sent")
            await inbox.receive(message)
        }
        XCTAssertEqual(rig.posted.count, 3)
        XCTAssertEqual(Set(rig.posted.map(\.identifier)).count, 1, "one summary")
        XCTAssertEqual(rig.posted.last?.content.body,
                       "While your watch was away: 3 Malinois alerts, the latest a disarm at \(dated(disarmed)). See your iPhone's Event Log.")

        let tripped = try local(10, 19, 8, 59)
        store.add(Event(startDate: tripped, endDate: tripped, triggeredSensors: [.motion]))
        let fresh = try XCTUnwrap(payloads.last.flatMap { WatchAlertMessage(userInfo: $0) })
        await inbox.receive(fresh)
        let shown = try XCTUnwrap(rig.posted.last)
        XCTAssertEqual(shown.content.body, "Tamper detected on your device at \(time(tripped)).", "a minute old: on its own, with its time")
        XCTAssertEqual(shown.content.interruptionLevel, .timeSensitive)
    }

    /// The queue can arrive over several background wakes, and watchOS can end the app between them: old
    /// alerts handled within the hour join the summary the watch kept; an absence that ends more than an
    /// hour later starts a new one, which taps again.
    func testASummaryCarriesOnAcrossWakesAndRelaunches() async throws {
        let start = try local(10, 19, 9, 0)
        let rig = try rig(at: start)
        let firstWake = rig.inbox()
        await firstWake.receive(alert(at: start.addingTimeInterval(-3 * 86_400)))
        await firstWake.receive(alert(.disarm, at: start.addingTimeInterval(-2 * 86_400)))
        rig.now = start.addingTimeInterval(20 * 60)
        await rig.inbox().receive(alert(at: start.addingTimeInterval(-86_400)))   // a later wake, after a relaunch

        XCTAssertEqual(rig.posted.count, 3)
        XCTAssertEqual(Set(rig.posted.map(\.identifier)).count, 1, "the summary the watch kept")
        XCTAssertEqual(rig.posted.map(\.content.interruptionLevel), [.active, .passive, .passive])
        XCTAssertEqual(rig.posted.last?.content.body,
                       "While your watch was away: 3 Malinois alerts, the latest a tamper at \(dated(start.addingTimeInterval(-86_400))). See your iPhone's Event Log.")

        rig.now = rig.now.addingTimeInterval(2 * 3600)   // the watch was away again
        await rig.inbox().receive(alert(.disarm, at: rig.now.addingTimeInterval(-5 * 3600)))
        let next = try XCTUnwrap(rig.posted.last)
        XCTAssertNotEqual(next.identifier, rig.posted[0].identifier, "a new summary")
        XCTAssertEqual(next.content.interruptionLevel, .active, "which taps again")
        XCTAssertTrue(next.content.body.hasPrefix("While your watch was away: 1 Malinois alert, a disarm at "), next.content.body)
    }

    /// Each event once: a second copy of an old alert is not counted again, the late queued copy of an alert
    /// already shown on its own is not counted, after a relaunch too, and the memory is 1.6's, so the alerts
    /// an earlier build showed are still recognized.
    func testEachEventIsShownOrCountedOnce() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        let old = alert(at: now.addingTimeInterval(-2 * 86_400))
        let first = await inbox.receive(old)
        let copy = await inbox.receive(old)
        XCTAssertTrue(first)
        XCTAssertFalse(copy, "a copy of an alert already counted")

        let live = alert(.disarm, at: now.addingTimeInterval(-10))
        let shown = await inbox.receive(live)
        XCTAssertTrue(shown)
        rig.now = now.addingTimeInterval(2 * 3600)
        let lateCopy = await inbox.receive(live)
        XCTAssertFalse(lateCopy, "the queued copy of an alert shown live, arriving after an hour")
        let afterRelaunch = await rig.inbox().receive(old)
        XCTAssertFalse(afterRelaunch, "remembered across launches")
        XCTAssertEqual(rig.posted.count, 2)
        XCTAssertTrue(rig.posted[0].content.body.hasPrefix("While your watch was away: 1 Malinois alert, "), rig.posted[0].content.body)

        XCTAssertEqual(WatchRelayInbox.shownRelayIDsKey, "com.malinois.watch.shownRelayIDs", "1.6's key")
        let shownByAnEarlierBuild = alert(at: now.addingTimeInterval(-3 * 86_400))
        rig.defaults.set([shownByAnEarlierBuild.notificationIdentifier], forKey: "com.malinois.watch.shownRelayIDs")
        let earlier = await rig.inbox().receive(shownByAnEarlierBuild)
        XCTAssertFalse(earlier)
        XCTAssertEqual(rig.attempts.count, 2, "nothing more was posted")
    }

    // MARK: - Codex's review of c56952a: X1 and X2

    /// X1: a copy of an alert the summary already counts is not counted again, however many alerts joined
    /// after it (more than the watch remembers of alerts shown on their own), after a relaunch too: the
    /// watch remembers each alert summed up.
    func testACopyOfAnAlertAlreadyCountedIsNotCountedAgainHoweverManyFollowed() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        let old = (0...WatchAlertStatus.rememberedRelayLimit).map { alert(at: now.addingTimeInterval(-7200 - Double($0))) }
        for message in old { await inbox.receive(message) }
        XCTAssertEqual(rig.posted.count, old.count)
        let relaunched = rig.inbox()
        for copy in [old[0], old[old.count / 2], old[old.count - 1]] {
            let counted = await relaunched.receive(copy)
            XCTAssertFalse(counted, "already counted")
        }
        XCTAssertEqual(rig.posted.count, old.count, "nothing more was posted")
        let body = rig.posted.last?.content.body ?? ""
        XCTAssertTrue(body.hasPrefix("While your watch was away: \(old.count.formatted()) Malinois alerts,"), body)
    }

    /// X1: the late queued copies of alerts shown live are not counted, more than the 50 the watch remembered
    /// until 1.8 (73), after a relaunch too, and none of them starts a summary.
    func testLateQueuedCopiesOfAlertsShownLiveAreNotCounted() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        let live = (0...50).map { alert($0.isMultiple(of: 2) ? .tamper : .disarm, at: now.addingTimeInterval(Double($0) - 50)) }
        for message in live { await inbox.receive(message) }
        XCTAssertEqual(rig.posted.count, live.count)
        XCTAssertFalse(rig.posted.contains { isSummary($0) }, "each shown on its own")
        rig.now = now.addingTimeInterval(2 * 3600)
        let relaunched = rig.inbox()
        var counted = 0
        for copy in live {
            let posted = await relaunched.receive(copy)
            counted += posted ? 1 : 0
        }
        XCTAssertEqual(counted, 0, "every copy is of an alert already shown")
        XCTAssertEqual(rig.posted.count, live.count)
        XCTAssertNil(kept(rig)?.summary)
    }

    /// X1, the limit: past what the watch remembers of alerts shown on their own (the newest
    /// `rememberedRelayLimit`), only the late copy of the one forgotten is counted, once: a copy summed up does
    /// not push out the others, so it never sets off a chain.
    func testBeyondWhatTheWatchRemembersOnlyTheForgottenCopyIsCounted() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        let limit = WatchAlertStatus.rememberedRelayLimit
        let live = (0...limit).map { alert(at: now.addingTimeInterval(-Double(limit - $0))) }
        for message in live { await inbox.receive(message) }
        rig.now = now.addingTimeInterval(2 * 3600)
        let relaunched = rig.inbox()
        var counted = 0
        for copy in live {
            let posted = await relaunched.receive(copy)
            counted += posted ? 1 : 0
        }
        XCTAssertEqual(counted, 1, "only the copy of the alert the watch no longer remembers")
        XCTAssertEqual(kept(rig)?.summed.map(\.id), [live[0].notificationIdentifier])
        XCTAssertEqual(kept(rig)?.summary?.count, 1)
    }

    /// X2: the alerts shown on their own, the alerts summed up and the summary are kept as one record,
    /// written once each time an alert is posted, so no interruption can keep one without the others. Y2:
    /// 1.6's key, for an earlier build installed over this one, is written before the record, and only when
    /// the alerts shown on their own change, so it is never behind the record.
    func testTheShownAlertsAndTheSummaryAreKeptAsOneRecord() async throws {
        let now = try local(10, 19, 9, 0)
        let suite = "MalinoisItem134Record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RecordingDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let inbox = WatchRelayInbox(defaults: defaults, now: { now }, post: { _ in })
        let fresh = alert(.disarm, at: now.addingTimeInterval(-30))
        let old = [alert(at: now.addingTimeInterval(-3 * 86_400)), alert(at: now.addingTimeInterval(-86_400))]
        for message in [fresh] + old { await inbox.receive(message) }

        XCTAssertEqual(defaults.writes.map(\.key), [WatchRelayInbox.shownRelayIDsKey, WatchRelayInbox.memoryKey,
                                                    WatchRelayInbox.memoryKey, WatchRelayInbox.memoryKey],
                       "the alert shown on its own: 1.6's key, then the record; each summed up: the record alone")
        let records = defaults.writes.filter { $0.key == WatchRelayInbox.memoryKey }.map { WatchRelayMemory.read($0.value as? Data) }
        XCTAssertEqual(records.map { $0?.shown ?? [] }, Array(repeating: [fresh.notificationIdentifier], count: 3),
                       "each record holds the alerts shown on their own")
        XCTAssertEqual(records.map { $0?.summed.map(\.id) ?? [] },
                       [[], [old[0].notificationIdentifier], old.map(\.notificationIdentifier)],
                       "and, in the same write, every alert summed up so far")
        XCTAssertEqual(records.map { $0?.summary?.count ?? 0 }, [0, 1, 2], "and the summary")
        XCTAssertEqual(defaults.stringArray(forKey: WatchRelayInbox.shownRelayIDsKey), [fresh.notificationIdentifier])
    }

    /// X2, from an earlier build: the first launch of this one takes the alerts 1.6's key holds into the record;
    /// after 1.8 (72) is installed over it and this build again, the alerts 72 added to that key are
    /// recognized beside those only the record holds.
    func testTheRecordTakesTheAlertsAnEarlierBuildRemembered() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let shownBy72 = alert(at: now.addingTimeInterval(-60))
        rig.defaults.set([shownBy72.notificationIdentifier], forKey: WatchRelayInbox.shownRelayIDsKey)
        let inbox = rig.inbox()
        let copy = await inbox.receive(shownBy72)
        XCTAssertFalse(copy, "recognized from 1.6's key")
        let shownBy73 = alert(.disarm, at: now.addingTimeInterval(-30))
        await inbox.receive(shownBy73)
        XCTAssertEqual(kept(rig)?.shown, [shownBy72, shownBy73].map(\.notificationIdentifier), "the record took both")

        let shownAfterGoingBack = alert(at: now.addingTimeInterval(-20))
        rig.defaults.set([shownBy73, shownAfterGoingBack].map(\.notificationIdentifier), forKey: WatchRelayInbox.shownRelayIDsKey)
        let again = rig.inbox()
        for message in [shownBy72, shownBy73, shownAfterGoingBack] {
            let posted = await again.receive(message)
            XCTAssertFalse(posted, "recognized from the record or from 1.6's key")
        }
        XCTAssertEqual(rig.posted.count, 1, "only the alert shown by this build")
    }

    /// A failed post is neither remembered nor counted: a later copy of the alert tries again (and starts the
    /// summary, so it taps), and a failed update leaves the count as it was.
    func testAFailedPostIsNeitherRememberedNorCounted() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        let old = alert(at: now.addingTimeInterval(-2 * 86_400))
        rig.failing = true
        let failed = await inbox.receive(old)
        XCTAssertFalse(failed)
        XCTAssertEqual(rig.attempts.count, 1)
        XCTAssertNil(kept(rig)?.summary, "no summary kept")
        rig.failing = false
        let retried = await inbox.receive(old)
        XCTAssertTrue(retried, "a later copy tries again")
        let started = try XCTUnwrap(rig.posted.last)
        XCTAssertEqual(started.content.interruptionLevel, .active)
        XCTAssertTrue(started.content.body.hasPrefix("While your watch was away: 1 Malinois alert, "), started.content.body)

        rig.failing = true
        await inbox.receive(alert(at: now.addingTimeInterval(-86_400)))
        rig.failing = false
        await inbox.receive(alert(at: now.addingTimeInterval(-7200)))
        let updated = try XCTUnwrap(rig.posted.last)
        XCTAssertEqual(updated.identifier, started.identifier)
        XCTAssertTrue(updated.content.body.hasPrefix("While your watch was away: 2 Malinois alerts, "), updated.content.body)
        XCTAssertEqual(updated.content.interruptionLevel, .passive)
    }

    /// Relayed alerts are handled one at a time, in the order they arrive: an alert arriving while the one
    /// before it is still being posted waits, so a count cannot be overwritten by a post that finishes late,
    /// and the summary taps once.
    func testRelayedAlertsAreHandledOneAtATimeInArrivalOrder() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let inbox = rig.inbox()
        rig.holding = true
        let first = Task { await inbox.receive(self.alert(at: now.addingTimeInterval(-3 * 86_400))) }
        for _ in 0..<1000 where rig.held.isEmpty { await Task.yield() }
        XCTAssertEqual(rig.held.count, 1, "the first post is under way")
        let second = Task { await inbox.receive(self.alert(.disarm, at: now.addingTimeInterval(-86_400))) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(rig.attempts.count, 1, "the second alert waits for the first post to finish")
        rig.holding = false
        rig.release()
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(rig.posted.map(\.content.interruptionLevel), [.active, .passive], "one tap")
        XCTAssertTrue(rig.posted.last?.content.body.hasPrefix("While your watch was away: 2 Malinois alerts, the latest a disarm") ?? false,
                      rig.posted.last?.content.body ?? "nothing posted")
    }

    // MARK: - Codex's second look at 90b4251: Y1 and Y2

    /// Y1 (Codex's case): an alert counted in one summary is still known when a new summary has started, after
    /// a relaunch: its late copy is not counted in the new one.
    func testAnAlertCountedInAnEarlierSummaryIsNotCountedInTheNext() async throws {
        let start = try local(10, 19, 9, 0)
        let rig = try rig(at: start)
        let inbox = rig.inbox()
        let first = alert(at: start.addingTimeInterval(-7200))
        let second = alert(.disarm, at: start.addingTimeInterval(-7100))
        await inbox.receive(first)
        let earlier = try XCTUnwrap(kept(rig)?.summary)
        rig.now = start.addingTimeInterval(3601)
        await inbox.receive(second)
        let later = try XCTUnwrap(kept(rig)?.summary)
        XCTAssertNotEqual(later.identifier, earlier.identifier, "more than an hour later: a new summary")
        let copy = await rig.inbox().receive(first)
        XCTAssertFalse(copy, "counted in the earlier summary")
        XCTAssertEqual(kept(rig)?.summary?.count, 1, "the new summary holds only the second alert")
        XCTAssertEqual(rig.posted.count, 2)
    }

    /// Y1, Codex's control: a new summary whose first post failed leaves the earlier one in place, with what
    /// it counted, until a later copy starts the new one.
    func testAFailedStartOfANewSummaryKeepsTheEarlierOne() async throws {
        let start = try local(10, 19, 9, 0)
        let rig = try rig(at: start)
        let inbox = rig.inbox()
        let first = alert(at: start.addingTimeInterval(-7200))
        let second = alert(.disarm, at: start.addingTimeInterval(-7100))
        await inbox.receive(first)
        let earlier = try XCTUnwrap(kept(rig)?.summary)
        rig.now = start.addingTimeInterval(3601)
        rig.failing = true
        let failed = await inbox.receive(second)
        XCTAssertFalse(failed)
        XCTAssertEqual(kept(rig)?.summary, earlier)
        rig.failing = false
        let copy = await rig.inbox().receive(first)
        XCTAssertFalse(copy)
        let retried = await rig.inbox().receive(second)
        XCTAssertTrue(retried)
        XCTAssertNotEqual(kept(rig)?.summary?.identifier, earlier.identifier)
        XCTAssertEqual(kept(rig)?.summed.map(\.id), [first, second].map(\.notificationIdentifier))
    }

    /// Y1, the limit: the newest `summedLimit` alerts summed up are known whichever summary counted them, after
    /// a relaunch; only past it is the copy of the one forgotten counted, once.
    func testTheNewestSummedUpAlertsAreKnownAcrossSummaries() async throws {
        let start = try local(10, 19, 9, 0)
        let rig = try rig(at: start)
        let inbox = rig.inbox()
        let limit = WatchRelayMemory.summedLimit
        let old = (0...limit).map { alert(at: start.addingTimeInterval(-7200 - Double(limit - $0))) }
        for (index, message) in old.enumerated() {
            if index == limit / 2 { rig.now = start.addingTimeInterval(3601) }   // half way, a new summary
            await inbox.receive(message)
        }
        XCTAssertEqual(rig.posted.count, old.count)
        XCTAssertEqual(Set(rig.posted.map(\.identifier)).count, 2, "two summaries")
        let relaunched = rig.inbox()
        for copy in [old[1], old[limit / 2 - 1], old[limit / 2], old[limit]] {
            let counted = await relaunched.receive(copy)
            XCTAssertFalse(counted, "known, in the earlier summary or the current one")
        }
        let forgotten = await relaunched.receive(old[0])
        XCTAssertTrue(forgotten, "past the limit: counted once")
        XCTAssertEqual(rig.posted.count, old.count + 1)
    }

    /// Y2 (Codex's case): an interruption between the two writes of a post, at the 500 alerts shown on their
    /// own, loses nothing still remembered, whichever write it falls after: the late copy of the oldest alert
    /// still remembered is recognized, and the one already forgotten is not brought back.
    func testAnInterruptedWriteAtTheLimitForgetsNothingStillRemembered() async throws {
        let now = try local(10, 19, 9, 0)
        let suite = "MalinoisItem134Interrupted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RecordingDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let limit = WatchAlertStatus.rememberedRelayLimit
        let live = (0...limit).map { alert(at: now.addingTimeInterval(Double($0) - Double(limit))) }
        let before = Array(live.prefix(limit)).map(\.notificationIdentifier)
        defaults.set(try JSONEncoder().encode(WatchRelayMemory(shown: before, summed: [], summary: nil)), forKey: WatchRelayInbox.memoryKey)
        defaults.set(before, forKey: WatchRelayInbox.shownRelayIDsKey)
        let previous: [String: Any?] = [WatchRelayInbox.memoryKey: defaults.object(forKey: WatchRelayInbox.memoryKey),
                        WatchRelayInbox.shownRelayIDsKey: defaults.object(forKey: WatchRelayInbox.shownRelayIDsKey)]
        defaults.writes.removeAll()
        let posted = await WatchRelayInbox(defaults: defaults, now: { now }, post: { _ in }).receive(live[limit])
        XCTAssertTrue(posted)
        let first = try XCTUnwrap(defaults.writes.first, "the post wrote something")

        // The watch stops after the post's first write: that write's value, and the other key as it was.
        let restart = "MalinoisItem134Restart-\(UUID().uuidString)"
        let restarted = try XCTUnwrap(UserDefaults(suiteName: restart))
        addTeardownBlock { restarted.removePersistentDomain(forName: restart) }
        for key in [WatchRelayInbox.memoryKey, WatchRelayInbox.shownRelayIDsKey] {
            restarted.set(key == first.key ? first.value : previous[key] ?? nil, forKey: key)
        }
        var requests: [UNNotificationRequest] = []
        let inbox = WatchRelayInbox(defaults: restarted, now: { now.addingTimeInterval(7200) }, post: { requests.append($0) })
        for message in [live[1], live[limit]] {
            let copy = await inbox.receive(message)
            XCTAssertFalse(copy, "still among the newest 500")
        }
        XCTAssertTrue(requests.isEmpty, "no summary made of alerts already shown")
    }

    // MARK: - Codex's third look at 1c3deeb: Z1 and Z2

    /// Z1 (Codex's case): past the 1,000 summed-up alerts, the late copies of all of them, in their order and after
    /// a relaunch, count only the one forgotten, once: kept by their events' times, a copy older than every
    /// alert remembered is not kept, so it cannot push out the next.
    func testPastTheSummedUpLimitAReplayCountsOnlyTheForgottenOne() async throws {
        let start = try local(10, 19, 9, 0)
        let rig = try rig(at: start)
        let inbox = rig.inbox()
        let limit = WatchRelayMemory.summedLimit
        let old = (0...limit).map { alert(at: start.addingTimeInterval(-7200 - Double(limit - $0))) }
        for (index, message) in old.enumerated() {
            if index == limit / 2 { rig.now = start.addingTimeInterval(3601) }
            await inbox.receive(message)
        }
        let before = try XCTUnwrap(kept(rig)?.summary?.count)
        let relaunched = rig.inbox()
        var countedAgain = 0
        for copy in old {
            let posted = await relaunched.receive(copy)
            countedAgain += posted ? 1 : 0
        }
        XCTAssertEqual(countedAgain, 1, "only the copy of the one forgotten")
        XCTAssertEqual(kept(rig)?.summary?.count, before + 1)
    }

    /// Z1, the rule: the summed-up alerts kept are the newest `summedLimit` by their events' times; a full list
    /// takes a newer alert in its place and leaves an older one out.
    func testTheSummedUpAlertsKeptAreTheNewestByEventTime() {
        let full = summedAlerts(WatchRelayMemory.summedLimit)
        let older = WatchRelayMemory.Summed(id: "malinois-relay-tamper-older", at: full[0].at.addingTimeInterval(-60))
        XCTAssertEqual(WatchRelayMemory.remembering(older, in: full), full, "older than all those kept: left out")
        let newer = WatchRelayMemory.Summed(id: "malinois-relay-tamper-newer", at: full[full.count - 1].at.addingTimeInterval(60))
        XCTAssertEqual(WatchRelayMemory.remembering(newer, in: full), Array(full.dropFirst()) + [newer], "the oldest gives way")
        let between = WatchRelayMemory.Summed(id: "malinois-relay-tamper-between", at: full[10].at.addingTimeInterval(30))
        let kept = WatchRelayMemory.remembering(between, in: full)
        XCTAssertEqual(kept.count, WatchRelayMemory.summedLimit)
        XCTAssertEqual(kept.map(\.at), kept.map(\.at).sorted(), "kept in event order")
        XCTAssertTrue(kept.contains(between))
        XCTAssertFalse(kept.contains(full[0]))
    }

    /// Codex's W1 (fourth look), the limit stated exactly: an alert outside the 1,000 kept (older than, or as old as,
    /// every alert remembered) is counted each time a copy of it arrives, since nothing remembers it, but it is never
    /// kept, so it pushes out no alert remembered; the alerts kept are still known.
    func testACopyOutsideTheSummedUpLimitIsCountedEachTimeButPushesNothingOut() async throws {
        let start = try local(10, 19, 9, 0)
        let rig = try rig(at: start)
        let limit = WatchRelayMemory.summedLimit
        let old = (1...limit).map { alert(at: start.addingTimeInterval(-7200 - Double(limit - $0))) }
        let inbox = rig.inbox()
        for message in old { await inbox.receive(message) }
        let keptBefore = try XCTUnwrap(kept(rig)?.summed)
        XCTAssertEqual(keptBefore.count, limit)
        let older = alert(at: old[0].at.addingTimeInterval(-60))
        let asOld = alert(.disarm, at: old[0].at)
        var counted = 0
        for copy in [older, asOld, older, asOld] {
            let posted = await rig.inbox().receive(copy)   // after a relaunch each time
            counted += posted ? 1 : 0
        }
        XCTAssertEqual(counted, 4, "each copy outside what the watch remembers is counted")
        XCTAssertEqual(kept(rig)?.summed, keptBefore, "none is kept, so none pushes out an alert remembered")
        XCTAssertEqual(kept(rig)?.summary?.count, limit + 4)
        for copy in [old[0], old[limit - 1]] {
            let posted = await rig.inbox().receive(copy)
            XCTAssertFalse(posted, "still remembered")
        }
    }

    /// Z2 (Codex's case): this build left 500 alerts shown; 72, installed over it, showed a new one and then the
    /// late copy of the oldest, which it no longer remembered. Back on this build, the alerts 72 showed last are
    /// recognized, and the merge stays as it is when the next post is only summed up and the app starts again.
    func testComingBackFrom72KeepsTheAlerts72ShowedLast() async throws {
        let now = try local(10, 19, 9, 0)
        let rig = try rig(at: now)
        let limit = WatchAlertStatus.rememberedRelayLimit
        let live = (0...limit).map { alert(at: now.addingTimeInterval(Double($0) - Double(limit))) }
        let before = Array(live.prefix(limit)).map(\.notificationIdentifier)
        rig.defaults.set(try JSONEncoder().encode(WatchRelayMemory(shown: before, summed: [], summary: nil)), forKey: WatchRelayInbox.memoryKey)
        rig.defaults.set(before, forKey: WatchRelayInbox.shownRelayIDsKey)
        // 72's own rule: the newest 50 it showed.
        var shownBy72 = WatchAlertStatus.remembering(live[limit].notificationIdentifier, in: before, limit: 50)
        shownBy72 = WatchAlertStatus.remembering(live[0].notificationIdentifier, in: shownBy72, limit: 50)
        rig.defaults.set(shownBy72, forKey: WatchRelayInbox.shownRelayIDsKey)

        rig.now = now.addingTimeInterval(7200)
        let back = rig.inbox()
        for copy in [live[0], live[limit]] {
            let posted = await back.receive(copy)
            XCTAssertFalse(posted, "shown by 72, last of all")
        }
        let summedUp = await back.receive(alert(.disarm, at: now.addingTimeInterval(-7200)))
        XCTAssertTrue(summedUp)
        let shown = try XCTUnwrap(kept(rig)?.shown)
        XCTAssertEqual(Array(shown.suffix(2)), [live[limit], live[0]].map(\.notificationIdentifier), "72's order, its last two newest")
        XCTAssertEqual(WatchRelayMemory.merged(shown, shownBy72), shown, "the next launch merges to the same list")
        XCTAssertEqual(rig.posted.count, 1, "only the new alert, summed up")
    }

    /// Z2, the rule: the alerts only the record holds come first, then 1.6's key in its own order, the newest
    /// `rememberedRelayLimit`: an alert in both takes the key's place, which is never behind the record.
    func testTheMergeTakes16sKeyInItsOwnOrder() {
        let record = ["a", "b", "c", "d"].map { "malinois-relay-tamper-\($0)" }
        let key = ["c", "e", "a"].map { "malinois-relay-tamper-\($0)" }
        XCTAssertEqual(WatchRelayMemory.merged(record, key), ["b", "d", "c", "e", "a"].map { "malinois-relay-tamper-\($0)" })
        XCTAssertEqual(WatchRelayMemory.merged(record, record), record, "the same list: unchanged")
        XCTAssertEqual(WatchRelayMemory.merged([], key), key, "the first launch after 72: 72's list")
        let long = identifiers(WatchAlertStatus.rememberedRelayLimit)
        XCTAssertEqual(WatchRelayMemory.merged(long, Array(long.dropFirst()) + ["malinois-relay-tamper-new"]),
                       Array(long.dropFirst()) + ["malinois-relay-tamper-new"], "a post stopped after 1.6's key: its list")
    }

    // MARK: - The watch app's wiring (its own target: read from the source tree, as built)

    /// The watch app hands every relayed alert, live or queued, to the inbox and records one for its screen
    /// only once the inbox posted it; it builds no notification of its own, posts through the watch's
    /// notification centre, and lists the summary's quiet updates while it is open. The inbox is compiled
    /// into the watch app and these tests.
    func testTheWatchAppHandsEveryRelayedAlertToTheInbox() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        let show = try XCTUnwrap(delegate.range(of: "private func showRelayed(")).upperBound
        let body = delegate[show...].prefix(400)
        let receive = try XCTUnwrap(body.range(of: "relayInbox.receive(message)"), "the inbox handles it")
        let record = try XCTUnwrap(body.range(of: "recordAlert(source: .iPhoneLink)"))
        XCTAssertLessThan(receive.lowerBound, record.lowerBound, "recorded once posted")
        XCTAssertEqual(count("await self.showRelayed(", in: delegate), 2, "the live and the queued copy")
        XCTAssertFalse(delegate.contains("UNMutableNotificationContent()"), "the inbox builds every relayed alert")
        XCTAssertTrue(delegate.contains("UNUserNotificationCenter.current().add(request)"))
        XCTAssertTrue(delegate.contains("WatchRelayInbox.presentationOptions(for: notification.request.content)"))
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        XCTAssertEqual(count("/* WatchRelayInbox.swift in Sources */", in: project), 4, "the watch app and these tests")
    }
}
