//
//  WatchAlertRelay.swift
//  Malinois
//
//  Sends this iPhone's own alerts straight to its paired Apple Watch (item 57, ADR 0043). iCloud
//  never sends a device's own change to its paired watch (TestFlight 1.6 (59)), so without this the
//  watch of the armed iPhone hears nothing. The message goes over Bluetooth or shared Wi-Fi through
//  WatchConnectivity, never through iCloud, and carries only the iCloud alerts' fixed texts.
//

import Combine
import Foundation
import os
import OSLog
import UIKit
import WatchConnectivity

/// Watches the log and sends each new first-hand incident and disarm to the paired watch.
@MainActor
final class WatchAlertRelay {
    /// Pure (unit-tested): the alerts newly added events earn, on the iCloud alerts' terms
    /// (Cross-device alerts on, Pro active). A first-hand incident sends the tamper alert; a
    /// first-hand status entry sends the disarm alert exactly when iCloud sends one for it, a disarm
    /// or a countdown someone cancelled, by iCloud's own rule (`disarmSignalWanted`, item 124's F10:
    /// a cancelled countdown used to reach no watch). Another device's events arrive through iCloud,
    /// and the other status entries alert nobody.
    nonisolated static func alerts(for newEvents: [Event], alertsOn: Bool, proActive: Bool) -> [WatchAlertMessage] {
        guard alertsOn, proActive else { return [] }
        return newEvents.compactMap { event -> WatchAlertMessage? in
            guard !event.isMirrored else { return nil }
            if let kind = event.stateChange {
                guard CloudExfiltrator.disarmSignalWanted(kind: kind) else { return nil }
                return WatchAlertMessage(kind: .disarm, eventID: event.id, at: event.startDate)
            }
            return WatchAlertMessage(kind: .tamper, eventID: event.id, at: event.startDate)
        }
    }

    private let store: EventStore
    private let settings: AppSettings
    private let entitlements: ProEntitlements
    private let send: (WatchAlertMessage) -> Void
    private let usesWatchConnectivity: Bool
    private var seen: Set<UUID> = []
    /// New entries logged before the first Pro check resolved (item 152's lead 19), or before the stored settings loaded
    /// (item 165's A3), decided once both have; at most `WatchLinkOutbox.limit`, the newest kept, as the link's own
    /// outbox does.
    private var held: [Event] = []
    private var subscription: AnyCancellable?
    private var resolution: AnyCancellable?

    /// `send` replaces WatchConnectivity in tests.
    init(store: EventStore, settings: AppSettings, entitlements: ProEntitlements,
         send: ((WatchAlertMessage) -> Void)? = nil) {
        self.store = store
        self.settings = settings
        self.entitlements = entitlements
        self.usesWatchConnectivity = send == nil
        self.send = send ?? { WatchLink.shared.send($0) }
    }

    /// Starts watching the log; what it already holds is not news.
    func start() {
        if usesWatchConnectivity { WatchLink.shared.activate() }
        seen = Set(store.events.map(\.id))
        subscription = store.$events.sink { [weak self] events in self?.handle(events) }
        // The first resolution decides what waited for it (lead 19). The publisher fires as `hasResolved` is set, after
        // the status it resolves to, so the decision reads the resolved status.
        resolution = entitlements.$hasResolved.sink { [weak self] resolved in
            if resolved { self?.releaseHeld(proResolved: true) }
        }
        // The alerts switch is the owner's only once the stored settings have loaded: before the first unlock it is the
        // default's, so what is new waits for them as well (item 165's A3).
        settings.whenResolved { [weak self] _ in
            guard let self else { return }
            self.releaseHeld(proResolved: self.entitlements.hasResolved)
        }
    }

    private func handle(_ events: [Event]) {
        let new = events.filter { !seen.contains($0.id) }
        guard !new.isEmpty else { return }
        seen.formUnion(new.map(\.id))
        // After a launch while the phone was locked the log is read at unlock in one go: history,
        // not news. Relayed, every old incident and disarm would reach the wrist at once (the 1.6
        // review's finding 1).
        guard !store.isReadingHistory else { return }
        // Before the first Pro check resolves, Pro reads as off whatever it turns out to be: what is new waits for the
        // answer instead of being dropped for good (item 152's lead 19: a cold launch's interruption record). Before the
        // stored settings load, the alerts switch is the default's: what is new waits for them too (item 165's A3).
        guard entitlements.hasResolved, !settings.awaitingUnlock else {
            held = Array((held + new).suffix(WatchLinkOutbox.limit))
            return
        }
        relay(new)
    }

    /// Sends what waited, once the first Pro check and the stored settings both have answers. `proResolved` is the
    /// check's own news: its publisher fires before `hasResolved` reads true, so the flag cannot be asked there.
    private func releaseHeld(proResolved: Bool) {
        guard !held.isEmpty, proResolved, !settings.awaitingUnlock else { return }
        let waiting = held
        held = []
        relay(waiting)
    }

    private func relay(_ events: [Event]) {
        for message in Self.alerts(for: events, alertsOn: settings.notifyOtherDevices, proActive: entitlements.proActive) {
            send(message)
        }
    }
}

/// Alerts sent before the watch link has finished activating (the 1.6 review's finding 2).
/// Activation is asynchronous, and a relaunch writes its interruption record within milliseconds of
/// starting it, so such alerts wait here: sent when activation completes with a paired watch running
/// Malinois, dropped without one. At most `limit` wait, the newest kept; while the owner switches
/// watches they wait again, and after a failed activation they wait for the next (item 155's A10).
/// Pure (unit-tested); `WatchLink` keeps it under a lock.
struct WatchLinkOutbox: Equatable {
    static let limit = 20
    private var activated = false
    private var waiting: [WatchAlertMessage] = []
    /// Failed activations in a row, and when WatchConnectivity was last asked to activate (item 155's A10).
    private var failures = 0
    private var lastAttempt: Date?

    /// Holds the alert while the link is activating and says so; once it has activated, holds
    /// nothing and returns false, and the caller sends the alert at once.
    mutating func holdIfActivating(_ message: WatchAlertMessage) -> Bool {
        guard !activated else { return false }
        waiting.append(message)
        if waiting.count > Self.limit { waiting.removeFirst(waiting.count - Self.limit) }
        return true
    }

    /// Activation completed: the alerts that waited, to send now if a watch can take them, or none.
    mutating func activationCompleted(watchReady: Bool) -> [WatchAlertMessage] {
        activated = true
        failures = 0
        lastAttempt = nil
        defer { waiting.removeAll() }
        return watchReady ? waiting : []
    }

    /// The owner is switching watches: alerts wait until the link activates again.
    mutating func sessionBecameInactive() {
        activated = false
    }

    /// The first wait before asking WatchConnectivity to activate again after a failure, and the longest (item 155's A10).
    static let firstRetryWait: TimeInterval = 5
    static let maxRetryWait: TimeInterval = 600

    /// Activation failed (item 155's A10): what waited keeps waiting, as later alerts do, for the next attempt, which a
    /// send or a foreground makes once the wait has passed (`retryDue`). Before, they were dropped, and every later one
    /// with them, until the app launched again.
    mutating func activationFailed(at now: Date) {
        activated = false
        failures += 1
        lastAttempt = now
    }

    /// Whether a send or a foreground should ask WatchConnectivity to activate again: only after a failed activation,
    /// and no sooner than the wait, 5 s after the first failure and doubling with each, up to ten minutes. Asking
    /// starts the wait again.
    mutating func retryDue(now: Date) -> Bool {
        guard let last = lastAttempt else { return false }   // set only by a failed activation
        let wait = min(Self.firstRetryWait * pow(2, Double(failures - 1)), Self.maxRetryWait)
        guard now.timeIntervalSince(last) >= wait else { return false }
        lastAttempt = now
        return true
    }
}

/// What the link uses of a WatchConnectivity session: `WCSession` itself, or a test's stand-in, so
/// the link's holding and sending run in a test (the test-suite audit's P4).
protocol WatchSessionPort: AnyObject {
    var activationState: WCSessionActivationState { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    /// Sends at once to the open watch app (`sendMessage`, no reply).
    func sendNow(_ userInfo: [String: Any])
    /// Queues for delivery, which watchOS makes by waking the watch app (`transferUserInfo`).
    func queue(_ userInfo: [String: Any])
}

extension WCSession: WatchSessionPort {
    func sendNow(_ userInfo: [String: Any]) { sendMessage(userInfo, replyHandler: nil, errorHandler: nil) }
    func queue(_ userInfo: [String: Any]) { transferUserInfo(userInfo) }
}

/// The iPhone's end of the WatchConnectivity session (item 57, ADR 0043).
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()
    /// Alerts waiting for the link to activate; the relay and the session's own queue both reach it.
    private let outbox = OSAllocatedUnfairLock(initialState: WatchLinkOutbox())
    /// The session alerts go to: WatchConnectivity's own, nil where it is unsupported; a test's stand-in.
    private let session: () -> WatchSessionPort?
    /// Asks WatchConnectivity to activate again after a failure (item 155's A10); a test's counter.
    private let reactivate: () -> Void
    /// The clock the retries' waits are measured on; a test's.
    private let now: () -> Date

    init(session: @escaping () -> WatchSessionPort? = { WCSession.isSupported() ? WCSession.default : nil },
         reactivate: @escaping () -> Void = { if WCSession.isSupported() { WCSession.default.activate() } },
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.reactivate = reactivate
        self.now = now
        super.init()
    }

    /// Set once `observeForeground` has run.
    private var foregroundObserver: NSObjectProtocol?

    /// A foreground asks again after a failed activation (item 155's A10).
    func observeForeground(center: NotificationCenter = .default) {
        guard foregroundObserver == nil else { return }
        foregroundObserver = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                queue: nil) { [weak self] _ in self?.retryIfDue() }
    }

    /// Asks WatchConnectivity to activate again after a failed activation, once its wait has passed (item 155's A10).
    func retryIfDue() {
        if outbox.withLock({ $0.retryDue(now: now()) }) { reactivate() }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        observeForeground()
    }

    /// Sends the alert, or holds it until the link has activated (`WatchLinkOutbox`). The watch
    /// shows each event once.
    func send(_ message: WatchAlertMessage) {
        guard let session = session() else { return }
        guard !outbox.withLock({ $0.holdIfActivating(message) }) else {
            retryIfDue()   // after a failed activation, a later alert asks again (item 155's A10)
            return
        }
        deliver(message, on: session)
    }

    /// Delivers to a paired watch running Malinois: at once while the watch app is open, and queued
    /// in every case, which watchOS delivers by waking the watch app in the background.
    private func deliver(_ message: WatchAlertMessage, on session: WatchSessionPort) {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        if session.isReachable {
            session.sendNow(message.userInfo)
        }
        session.queue(message.userInfo)
    }

    /// Activation completed: the alerts that waited go out, or are dropped without a watch.
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            Log.app.error("Watch link activation failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
        }
        activationCompleted(activationState, on: session)
    }

    /// The delegate's answer, for any session: the alerts that waited go to a watch that can take
    /// them, and are dropped without one; after a failed activation they keep waiting (item 155's A10).
    func activationCompleted(_ activationState: WCSessionActivationState, on session: WatchSessionPort) {
        guard activationState == .activated else {
            outbox.withLock { $0.activationFailed(at: now()) }
            return
        }
        let watchReady = session.isPaired && session.isWatchAppInstalled
        let waiting = outbox.withLock { $0.activationCompleted(watchReady: watchReady) }
        waiting.forEach { deliver($0, on: session) }
    }

    /// The owner is switching watches: alerts wait for the next activation.
    func sessionDidBecomeInactive(_ session: WCSession) {
        becameInactive()
    }

    /// The delegate's inactive notice, for any session.
    func becameInactive() {
        outbox.withLock { $0.sessionBecameInactive() }
    }

    /// The owner switched watches: activate again for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
