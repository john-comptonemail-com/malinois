//
//  WatchAlertPairing.swift
//  MalinoisWatch
//
//  The two copies of one alert from the watch's own iPhone (BACKLOG 140, TestFlight 1.8 (74); ADR 0052): iCloud's,
//  which reaches the paired watch first, and the relay's, which names the event's time (ADR 0051). Both carry the
//  event's ID: iCloud's in the name of the record that fired it, the relay's in its notification identifier. Compiled
//  into the watch app, its alert extension and the iPhone app's tests. Pure: it decides from what it is given.
//

import CloudKit
import Foundation
import UserNotifications
#if os(iOS)
// Compiled into the iPhone app's tests, which find the shared message type in the app.
@testable import Malinois
#endif

/// How the watch tells iCloud's copy of an alert from the relay's, and what it does when both are there (ADR 0052).
enum WatchAlertPairing {
    /// The iCloud subscriptions' IDs (`CloudExfiltrator`'s; a test keeps them equal).
    static let tamperSubscriptionID = "malinois-tamper-meta-v2-sub"
    static let disarmSubscriptionID = "malinois-disarm-v2-sub"

    /// One event's alert, as both copies name it.
    struct Pair: Equatable, Hashable, Sendable {
        let kind: WatchAlertMessage.Kind
        let eventID: UUID

        /// The identifier the relay's copy of this event is posted under.
        var relayIdentifier: String { WatchAlertMessage(kind: kind, eventID: eventID, at: .distantPast).notificationIdentifier }
    }

    /// One notification in the watch's list, as the pairing reads it.
    struct Delivered: Equatable, Sendable {
        let identifier: String
        /// The event iCloud's copy is about; nil for the relay's own notifications and anything else.
        let iCloud: Pair?

        init(identifier: String, content: UNNotificationContent) {
            self.identifier = identifier
            iCloud = WatchAlertPairing.iCloudAlert(userInfo: content.userInfo)
        }
    }

    /// What the watch does with a relayed alert, given its list. The relayed copy itself always alerts as in 74
    /// (TestFlight 76: quieted after iCloud's copy, which had not tapped, tamper alerts came silently; the owner's "A").
    struct Plan: Equatable, Sendable {
        /// iCloud's copies of the event, removed once the relayed copy is posted: one entry, with the time.
        let replacing: [String]
    }

    /// Pure (unit-tested). Which of Malinois's iCloud alerts a push is, from the subscription that sent it; nil for
    /// anything else.
    static func iCloudKind(userInfo: [AnyHashable: Any]) -> WatchAlertMessage.Kind? {
        switch CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID {
        case tamperSubscriptionID: .tamper
        case disarmSubscriptionID: .disarm
        default: nil
        }
    }

    /// Pure (unit-tested). Whether a push is iCloud's tamper alert: what the extension's burst record counts (ADR 0061).
    /// Not the relay's copies, which carry no push.
    static func isICloudTamperAlert(userInfo: [AnyHashable: Any]) -> Bool {
        iCloudKind(userInfo: userInfo) == .tamper
    }

    /// Pure (unit-tested). The event an iCloud alert is about: its kind from the subscription that sent it, its ID from
    /// the name of the record that fired it, with that subscription's prefix (`meta-v2-` and `disarm-v2-`:
    /// `CloudExfiltrator.makeMetaRecord` and `makeDisarmSignalRecord`). Nil for anything else.
    static func iCloudAlert(userInfo: [AnyHashable: Any]) -> Pair? {
        guard let kind = iCloudKind(userInfo: userInfo),
              let push = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let name = push.recordID?.recordName else { return nil }
        let prefix = kind == .tamper ? "meta-v2-" : "disarm-v2-"
        guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))) else { return nil }
        return Pair(kind: kind, eventID: id)
    }

    /// Pure (unit-tested). How the watch's alert extension shows an iCloud alert, given the identifiers in the watch's
    /// list: quietly (the passive level, without sound) when the relay's copy of the same event is there, since that
    /// copy tapped; otherwise a tamper alert, by its subscription, Time Sensitive, as on the iPhone (ADR 0045), or quietly,
    /// in words that say so, when it is one of many arriving at once (`AlertBurst`, ADR 0061); anything else as sent.
    /// The words change only for that. `earlierTamperArrivals`: when the extension's earlier iCloud tamper alerts
    /// arrived, from its own record (item 169's codex-3).
    static func iCloudContent(_ content: UNNotificationContent, deliveredIdentifiers: Set<String>,
                              earlierTamperArrivals: [Date] = [], burstLast: Date? = nil,
                              now: Date = Date()) -> UNNotificationContent {
        guard let kind = iCloudKind(userInfo: content.userInfo),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        if let pair = iCloudAlert(userInfo: content.userInfo), deliveredIdentifiers.contains(pair.relayIdentifier) {
            mutable.interruptionLevel = .passive
            mutable.sound = nil
            return mutable
        }
        guard kind == .tamper else { return content }
        if AlertBurst.arrive(now, after: AlertBurst.Record(arrivals: earlierTamperArrivals, burstLast: burstLast)).quiet {
            mutable.interruptionLevel = .passive
            mutable.sound = nil
            mutable.body = AlertBurst.quietBody
            return mutable
        }
        mutable.interruptionLevel = .timeSensitive
        return mutable
    }

    /// Pure (unit-tested). What posting a relayed alert does to the list (ADR 0052): iCloud's copies of its event go once
    /// it is posted. It alerts whatever the list holds: the list says iCloud's copy arrived, not that it tapped (TestFlight
    /// 76), so with iCloud's copy first both tap.
    static func relayed(_ message: WatchAlertMessage, delivered: [Delivered]) -> Plan {
        let pair = Pair(kind: message.kind, eventID: message.eventID)
        return Plan(replacing: delivered.filter { $0.iCloud == pair }.map(\.identifier))
    }
}
