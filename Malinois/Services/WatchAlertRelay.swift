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
    private var subscription: AnyCancellable?

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
    }

    private func handle(_ events: [Event]) {
        let new = events.filter { !seen.contains($0.id) }
        guard !new.isEmpty else { return }
        seen.formUnion(new.map(\.id))
        // After a launch while the phone was locked the log is read at unlock in one go: history,
        // not news. Relayed, every old incident and disarm would reach the wrist at once (the 1.6
        // review's finding 1).
        guard !store.isReadingHistory else { return }
        for message in Self.alerts(for: new, alertsOn: settings.notifyOtherDevices, proActive: entitlements.proActive) {
            send(message)
        }
    }
}

/// Alerts sent before the watch link has finished activating (the 1.6 review's finding 2).
/// Activation is asynchronous, and a relaunch writes its interruption record within milliseconds of
/// starting it, so such alerts wait here: sent when activation completes with a paired watch running
/// Malinois, dropped without one. At most `limit` wait, the newest kept; while the owner switches
/// watches they wait again. Pure (unit-tested); `WatchLink` keeps it under a lock.
struct WatchLinkOutbox: Equatable {
    static let limit = 20
    private var activated = false
    private var waiting: [WatchAlertMessage] = []

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
        defer { waiting.removeAll() }
        return watchReady ? waiting : []
    }

    /// The owner is switching watches: alerts wait until the link activates again.
    mutating func sessionBecameInactive() {
        activated = false
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

    init(session: @escaping () -> WatchSessionPort? = { WCSession.isSupported() ? WCSession.default : nil }) {
        self.session = session
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the alert, or holds it until the link has activated (`WatchLinkOutbox`). The watch
    /// shows each event once.
    func send(_ message: WatchAlertMessage) {
        guard let session = session() else { return }
        guard !outbox.withLock({ $0.holdIfActivating(message) }) else { return }
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
    /// them, and are dropped otherwise.
    func activationCompleted(_ activationState: WCSessionActivationState, on session: WatchSessionPort) {
        let watchReady = activationState == .activated && session.isPaired && session.isWatchAppInstalled
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
