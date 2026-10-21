//
//  WatchRelayInbox.swift
//  MalinoisWatch
//
//  How the watch handles the alerts its paired iPhone relays (item 57, ADR 0043; BACKLOG 134, ADR 0051):
//  each event once; an alert whose event is more than an hour old joins one summary, and the others are
//  shown on their own with their event's time. iCloud's copy of the same event, which can reach the watch first,
//  is paired with it (ADR 0052). The iPhone app's test target compiles this file too, as it does
//  WatchAlertStatus.swift, and drives it with a clock, a store and a notification centre of its own.
//

import Foundation
import OSLog
import UserNotifications
#if os(iOS)
// Compiled into the iPhone app's tests, which find the shared message type in the app.
@testable import Malinois
#endif

/// The relayed alerts' handling on the watch, one at a time in the order they are handed in (ADR 0051):
/// each event once; one more than an hour old joins the summary, the others are shown on their own.
@MainActor
final class WatchRelayInbox {
    /// The relayed alerts shown on their own, under 1.6's key (the 1.6 review's finding 5): read at launch
    /// beside the record below, so the alerts an earlier build showed are still recognized, and written
    /// before it, for an earlier build installed over this one.
    nonisolated static let shownRelayIDsKey = "com.malinois.watch.shownRelayIDs"
    /// What the watch keeps about relayed alerts, across launches (ADR 0051): the alerts shown on their
    /// own, the alerts summed up and the summary, in one record, so an interruption can never keep one
    /// without the others (Codex's X2).
    nonisolated static let memoryKey = "com.malinois.watch.relayMemory"

    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let post: @MainActor (sending UNNotificationRequest) async throws -> Void
    /// The watch's notification list, as the pairing reads it (ADR 0052): read right before each post.
    private let delivered: @MainActor () async -> [WatchAlertPairing.Delivered]
    /// Removes notifications from the list by identifier: iCloud's copies of an event once its relayed copy is posted.
    private let remove: @MainActor ([String]) -> Void
    /// How long a read of the list may take before the inbox goes on without it (Codex's look at 75): a relayed copy is
    /// then posted as before, with sound, and nothing is removed, so a list that does not answer holds no alert back.
    private let listDeadline: TimeInterval
    private let log = Logger(subsystem: "com.johncompton.Malinois.watchkitapp", category: "alerts")
    /// The relayed alerts shown on their own, so a repeated delivery is not shown again, and those being
    /// posted now (item 108, CE-03).
    private var ledger: WatchAlertStatus.RelayLedger
    /// The relayed alerts summed up, so a copy of one is not counted again (Codex's X1).
    private var summed: [WatchRelayMemory.Summed]
    /// The summary old alerts join, as last posted.
    private var summary: WatchRelaySummary?
    /// The alert being handled, or the last one handled: the next one waits for it.
    private var last: Task<Bool, Never>?
    /// The latest repeat's tidy-up, beside the alerts' queue (Codex's second look at 75, observation 1): each waits for the
    /// one before it, never for an alert. Tests wait for it.
    private(set) var repeatTidy: Task<Void, Never>?

    /// `post` adds a notification request (the notification centre's `add`); `now` is the clock; `delivered` reads
    /// the notification list and `remove` takes notifications out of it (ADR 0052). The shown alerts and the summary
    /// are read from `defaults`, where they are kept.
    init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() },
         post: @escaping @MainActor (sending UNNotificationRequest) async throws -> Void,
         delivered: @escaping @MainActor () async -> [WatchAlertPairing.Delivered] = { [] },
         remove: @escaping @MainActor ([String]) -> Void = { _ in },
         listDeadline: TimeInterval = 2) {
        self.defaults = defaults
        self.now = now
        self.post = post
        self.delivered = delivered
        self.remove = remove
        self.listDeadline = listDeadline
        let kept = WatchRelayMemory.read(defaults.data(forKey: Self.memoryKey))
        let shownBefore = defaults.stringArray(forKey: Self.shownRelayIDsKey) ?? []
        ledger = WatchAlertStatus.RelayLedger(shown: WatchRelayMemory.merged(kept?.shown ?? [], shownBefore))
        summed = kept?.summed ?? []
        summary = kept?.summary
    }

    /// Handles one relayed alert, live or queued, once those handed in before it are done: shown on its
    /// own, joined to the summary, or passed over as one already shown or counted. One at a time, so a
    /// post that finishes late cannot overwrite a later count. Returns whether a notification was posted.
    @discardableResult
    func receive(_ message: WatchAlertMessage) async -> Bool {
        let previous = last
        let task = Task { () -> Bool in
            _ = await previous?.value
            return await self.handle(message)
        }
        last = task
        return await task.value
    }

    /// The alert is remembered, and the summary kept, only once its post succeeded (item 108, CE-03),
    /// so a later copy of one that failed is tried again and a failed update leaves the count as it was.
    private func handle(_ message: WatchAlertMessage) async -> Bool {
        let id = message.notificationIdentifier
        // Each event once: not when summed up before (Codex's X1), shown on its own, or being posted.
        guard !summed.contains(where: { $0.id == id }), ledger.begin(id) else {
            // A repeat (the queued copy after the live one): iCloud's copy of the event, which may have come in between,
            // quiet, can go from the list (Codex's codex-1 on 75). Beside the alerts' queue, not in it, so a list slow to
            // answer holds no new alert back (Codex's second look at 75, observation 1).
            let previous = repeatTidy
            repeatTidy = Task { [weak self] in
                _ = await previous?.value
                guard let self else { return }
                let copies = WatchAlertPairing.relayed(message, delivered: await self.readList()).replacing
                if !copies.isEmpty { self.remove(copies) }
            }
            return false
        }
        let handledAt = now()
        let joined = message.isSummarized(handledAt: handledAt)
            ? WatchRelaySummary.adding(message, to: summary, at: handledAt) : nil
        // iCloud's copy of the event, if the list has it (ADR 0052): the relayed copy replaces it, and alerts as before,
        // since iCloud's may not have tapped (TestFlight 76).
        let plan = WatchAlertPairing.relayed(message, delivered: await readList())
        let request: UNNotificationRequest
        if let joined {
            request = joined.request(now: handledAt)
        } else {
            request = Self.request(for: message, now: handledAt)
        }
        var posted = false
        do {
            try await post(request)
            posted = true
        } catch {
            log.error("Relayed alert not shown: \(Self.reference(error), privacy: .public) \(error, privacy: .private)")
        }
        // An alert summed up is remembered in the summary, not among the alerts shown on their own, so a
        // burst of old alerts cannot push out the shown alerts whose queued copies are still to come
        // (Codex's X1: each copy pushed out the next one's memory, and all were counted).
        ledger.finish(id, posted: posted && joined == nil)
        guard posted else { return false }
        // Once the relayed copy is accepted, so iCloud's goes only after its replacement was scheduled.
        if !plan.replacing.isEmpty { remove(plan.replacing) }
        if let joined {
            summary = joined
            // Kept whichever summary counted it, so a new summary does not forget the earlier ones' alerts
            // (Codex's Y1).
            summed = WatchRelayMemory.remembering(WatchRelayMemory.Summed(id: id, at: message.at), in: summed)
        }
        keepMemory(shownChanged: joined == nil)
        return true
    }

    /// Takes out of the list iCloud's copies of events already handled (`tidy`): when an iCloud push wakes the app and
    /// when it becomes active (Codex's codex-1 on 75: whether, and when, a push wakes the app is up to watchOS).
    func reconcile() async {
        let stale = tidy(delivered: await readList())
        if !stale.isEmpty { remove(stale) }
    }

    /// The list, or none when it does not answer within `listDeadline`.
    private func readList() async -> [WatchAlertPairing.Delivered] {
        await withCheckedContinuation { (done: CheckedContinuation<[WatchAlertPairing.Delivered], Never>) in
            let answer = FirstAnswer()
            Task { @MainActor in
                let list = await self.delivered()
                if answer.claim() { done.resume(returning: list) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, self.listDeadline) * 1_000_000_000))
                if answer.claim() { done.resume(returning: []) }
            }
        }
    }

    /// iCloud's copies to take out of the list when an iCloud push wakes the app (ADR 0052): those of an event already
    /// handled, shown on its own or summed up, or whose relayed copy is in the list. The relayed copy came first and
    /// tapped; the alert extension showed iCloud's quietly.
    func tidy(delivered list: [WatchAlertPairing.Delivered]) -> [String] {
        let listed = Set(list.map(\.identifier))
        return list.compactMap { entry in
            guard let relay = entry.iCloud?.relayIdentifier else { return nil }
            let handled = listed.contains(relay) || ledger.shown.contains(relay) || summed.contains { $0.id == relay }
            return handled ? entry.identifier : nil
        }
    }

    /// The alerts shown on their own under 1.6's key first, and only when they changed, so that key is never
    /// behind the record and whatever it holds that the record lacks is newer: a post the watch stopped in
    /// the middle of, or 72 installed over this build (Codex's Y2: written after the record, it could be left
    /// behind, and the merge at launch then lost an alert still remembered). Then the alerts shown on their
    /// own, the alerts summed up and the summary in one write (Codex's X2).
    private func keepMemory(shownChanged: Bool) {
        if shownChanged { defaults.set(ledger.shown, forKey: Self.shownRelayIDsKey) }
        let memory = WatchRelayMemory(shown: ledger.shown, summed: summed, summary: summary)
        defaults.set(try? JSONEncoder().encode(memory), forKey: Self.memoryKey)
    }

    /// The notification for an alert shown on its own: its event's time in the text, with sound, and
    /// Time Sensitive for a tamper (ADR 0045), also after iCloud's copy of the event, which may not have tapped (ADR
    /// 0052, since TestFlight 76).
    nonisolated static func request(for message: WatchAlertMessage, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body(deliveredAt: now)
        content.sound = .default
        content.interruptionLevel = message.isTimeSensitive ? .timeSensitive : .active
        return UNNotificationRequest(identifier: message.notificationIdentifier, content: content, trigger: nil)
    }

    /// Pure (unit-tested). How a notification is shown while the watch app is open: the summary's quiet
    /// updates (the passive level) are listed, not shown as banners; everything else as before.
    nonisolated static func presentationOptions(for content: UNNotificationContent) -> UNNotificationPresentationOptions {
        content.interruptionLevel == .passive ? [.list] : [.banner, .sound, .list]
    }

    /// An error's domain and code, safe to log publicly, as `WatchAppDelegate.reference` and the
    /// iPhone app's `Log.ref` (R1-L3).
    nonisolated static func reference(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}

/// Which of two racing answers came first (`WatchRelayInbox.readList`): the list, or its deadline.
@MainActor
private final class FirstAnswer {
    private var given = false

    /// True the first time only.
    func claim() -> Bool {
        guard !given else { return false }
        given = true
        return true
    }
}

/// One summary of relayed alerts more than an hour old (ADR 0051), as the watch keeps it.
struct WatchRelaySummary: Codable, Equatable, Sendable {
    /// Every summary's notification identifier starts so; `WatchAlertStatus.source(ofNotification:)`
    /// counts it as the iPhone link's.
    static let identifierPrefix = "malinois-relay-summary-"
    /// An old alert handled this long after the summary last changed starts a new summary, so a later
    /// absence is not added to an earlier one.
    static let startsAgainAfter: TimeInterval = 3600
    /// A kept count beyond this is damaged; a summary this full starts again rather than overflow.
    static let countLimit = 1_000_000

    /// The summary's notification identifier; a new summary has a new one, so an earlier summary is
    /// never replaced by a smaller count.
    let identifier: String
    /// The alerts it sums up. Which alerts they were is kept beside it (`WatchRelayMemory.summed`), so a new
    /// summary does not forget them (Codex's Y1).
    var count: Int
    /// The latest event among them, by its time.
    var latestKind: WatchAlertMessage.Kind
    var latestAt: Date
    /// When an alert last joined it, by the watch's clock.
    var changedAt: Date

    /// Whether a kept summary can be trusted: a summary's identifier and a count in range.
    var isSound: Bool {
        identifier.hasPrefix(Self.identifierPrefix) && (1...Self.countLimit).contains(count)
    }

    /// Pure (unit-tested). The summary `message` joins when handled at `now`: `current` with the alert
    /// counted, or a new summary when there is none, when `current` last changed more than an hour away
    /// from `now` (either way: the watch's clock can be set back), or when it is full. Whether the alert
    /// was counted before is the inbox's to know (`WatchRelayMemory.summed`).
    static func adding(_ message: WatchAlertMessage, to current: WatchRelaySummary?, at now: Date) -> WatchRelaySummary {
        guard let current, abs(now.timeIntervalSince(current.changedAt)) <= startsAgainAfter,
              current.count < countLimit else {
            return WatchRelaySummary(identifier: identifierPrefix + UUID().uuidString, count: 1, latestKind: message.kind,
                                     latestAt: message.at, changedAt: now)
        }
        var joined = current
        joined.count += 1
        if message.at >= current.latestAt {
            joined.latestKind = message.kind
            joined.latestAt = message.at
        }
        joined.changedAt = now
        return joined
    }

    /// Pure (unit-tested). The summary's text when posted at `now` (the owner's approved wording,
    /// 2026-10-18), its latest event's time as the alerts give it. No em-dash (B16).
    func body(at now: Date) -> String {
        let latest = "\(latestKind == .tamper ? "a tamper" : "a disarm") at \(WatchAlertMessage.when(latestAt, now: now))"
        return count == 1
            ? "While your watch was away: 1 Malinois alert, \(latest). See your iPhone's Event Log."
            : "While your watch was away: \(count.formatted()) Malinois alerts, the latest \(latest). See your iPhone's Event Log."
    }

    /// Pure (unit-tested). The summary's notification, posted again under its identifier as alerts join,
    /// which replaces the copy before. Its first post lights the screen and taps, at the ordinary level,
    /// not Time Sensitive (the owner, 2026-10-18: "make the screen light up/tap"); each later post changes
    /// the count quietly, at the passive level, without sound.
    func request(now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Malinois"
        content.body = body(at: now)
        if count == 1 {
            content.sound = .default
            content.interruptionLevel = .active
        } else {
            content.interruptionLevel = .passive
        }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

/// What the watch keeps about relayed alerts, as one record: the alerts shown on their own, the alerts
/// summed up and the summary are always written together (Codex's X2 on build 73).
struct WatchRelayMemory: Codable, Equatable, Sendable {
    /// One summed-up alert: its notification identifier and its event's time.
    struct Summed: Codable, Equatable, Sendable {
        let id: String
        let at: Date
    }

    /// How many summed-up alerts the watch remembers, in the current summary and earlier ones (Codex's Y1).
    static let summedLimit = 1000

    /// The alerts shown on their own, newest last.
    var shown: [String]
    /// The alerts summed up, the newest `summedLimit` by their events' times, oldest first, whichever summary
    /// counted them: a copy of one is not counted again, in that summary or a later one (Codex's X1 and Y1).
    var summed: [Summed]
    /// The summary old alerts join.
    var summary: WatchRelaySummary?

    /// Pure (unit-tested). A kept record, or nil when there is none or it cannot be read; a summary in it
    /// that cannot be trusted (`WatchRelaySummary.isSound`) is dropped, and the lists keep their newest
    /// entries within their limits.
    static func read(_ data: Data?) -> WatchRelayMemory? {
        guard let data, var kept = try? JSONDecoder().decode(WatchRelayMemory.self, from: data) else { return nil }
        if kept.summary?.isSound == false { kept.summary = nil }
        kept.shown = Array(kept.shown.suffix(WatchAlertStatus.rememberedRelayLimit))
        kept.summed = Array(kept.summed.sorted { $0.at < $1.at }.suffix(summedLimit))
        return kept
    }

    /// Pure (unit-tested). `summed` with `alert` remembered: the newest `summedLimit` by their events' times,
    /// oldest first. A full list leaves out an alert older than all it keeps, so the late copy of one already
    /// forgotten is counted once but cannot push out the next (Codex's Z1: kept as they arrived, each such copy
    /// pushed out the next, and a replay of them all was counted in full).
    static func remembering(_ alert: Summed, in summed: [Summed]) -> [Summed] {
        if summed.count >= summedLimit, let oldest = summed.first, alert.at <= oldest.at { return summed }
        var kept = summed
        kept.insert(alert, at: kept.firstIndex { $0.at > alert.at } ?? kept.endIndex)
        return Array(kept.suffix(summedLimit))
    }

    /// Pure (unit-tested). The alerts shown on their own as the record keeps them and as 1.6's key holds them,
    /// the newest `WatchAlertStatus.rememberedRelayLimit` in all. That key is written before the record, so it
    /// is never behind it: what it holds, and the order it holds it in, is the newer (a post stopped between the
    /// two writes, or an earlier build installed over this one; Codex's Y2 and Z2).
    static func merged(_ kept: [String], _ older: [String]) -> [String] {
        // The record's own alerts first, then the key's in its order: an alert in both takes the key's place, so
        // one 72 showed again after this build forgot it is not pushed out (Codex's Z2).
        let fromKey = Set(older)
        return Array((kept.filter { !fromKey.contains($0) } + older).suffix(WatchAlertStatus.rememberedRelayLimit))
    }
}
