//
//  NotificationService.swift
//  MalinoisNotificationService
//

import CloudKit
import UserNotifications

/// Delivers the subscription's generic alert without reading private CloudKit evidence.
/// The extension cannot verify the main app's installation-bound enrollment. Until a shared
/// authorization design is implemented and tested across reinstalls, fetching details here
/// would bypass that boundary. Words and sound remain as sent, but for a tamper alert that is one
/// of many arriving at once, which comes quietly and says so (ADR 0061), counted from the
/// extension's own record of tamper arrivals (item 169's codex-3). A tamper alert is shown
/// Time Sensitive (the owner's ruling, 2026-10-12; ADR 0045), decided from the subscription the
/// push names: a subscription cannot ask for that level itself.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Only a tamper alert's level depends on the burst count (ADR 0061): anything else is answered as sent
        // (item 169's codex-4).
        guard Self.isTamperAlert(request.content.userInfo) else {
            contentHandler(Self.leveled(request.content))
            return
        }
        // Counted from the extension's own record of tamper arrivals, which the owner clearing the list does not empty
        // (item 169's codex-3), and answered at once.
        let now = Date()
        let before = AlertBurst.recordArrival(at: now, defaults: .standard, key: AlertBurst.arrivalsKey)
        contentHandler(Self.leveled(request.content, earlierTamperArrivals: before.arrivals, burstLast: before.burstLast,
                                    now: now))
    }

    /// The alert as sent, Time Sensitive when the tamper subscription sent it, or quietly, in words that say so, when
    /// it is one of many tamper alerts arriving at once (`AlertBurst`, ADR 0061); anything else unchanged.
    /// `earlierTamperArrivals`: when the extension's earlier tamper alerts arrived, from its own record; `burstLast`: the
    /// running burst's last, kept beside it (item 170's codex-5).
    static func leveled(_ content: UNNotificationContent, earlierTamperArrivals: [Date] = [], burstLast: Date? = nil,
                        now: Date = Date()) -> UNNotificationContent {
        let subscriptionID = CKNotification(fromRemoteNotificationDictionary: content.userInfo)?.subscriptionID
        guard isTimeSensitive(subscriptionID: subscriptionID),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        if AlertBurst.arrive(now, after: AlertBurst.Record(arrivals: earlierTamperArrivals, burstLast: burstLast)).quiet {
            mutable.interruptionLevel = .passive
            mutable.sound = nil
            mutable.body = AlertBurst.quietBody
            return mutable
        }
        mutable.interruptionLevel = .timeSensitive
        return mutable
    }

    /// Whether a push is a tamper alert: the tamper subscription sent it.
    static func isTamperAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
        isTimeSensitive(subscriptionID: CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID)
    }

    /// The tamper subscription's ID (`CloudExfiltrator`'s; a test keeps the two equal). Held here,
    /// since the extension compiles none of the app's cloud code.
    static let tamperSubscriptionID = "malinois-tamper-meta-v2-sub"

    /// Pure (unit-tested; the owner's ruling, 2026-10-12, "B"; ADR 0045): whether a pushed alert is
    /// shown Time Sensitive. The tamper subscription's alerts are, so they break through Focus and
    /// Sleep as 1.4's and 1.5's did; the disarm alert and anything else keep their level. Decided
    /// from the push alone, reading no record (ADR 0039), so a Vision-only trip is not told apart.
    static func isTimeSensitive(subscriptionID: String?) -> Bool {
        subscriptionID == tamperSubscriptionID
    }
}
