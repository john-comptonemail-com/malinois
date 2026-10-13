//
//  NotificationService.swift
//  MalinoisNotificationService
//

import CloudKit
import UserNotifications

/// Delivers the subscription's generic alert without reading private CloudKit evidence.
/// The extension cannot verify the main app's installation-bound enrollment. Until a shared
/// authorization design is implemented and tested across reinstalls, fetching details here
/// would bypass that boundary. Words and sound remain exactly as sent. A tamper alert is shown
/// Time Sensitive (the owner's ruling, 2026-10-12; ADR 0045), decided from the subscription the
/// push names: a subscription cannot ask for that level itself.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(Self.leveled(request.content))
    }

    /// The alert as sent, Time Sensitive when the tamper subscription sent it; anything else unchanged.
    static func leveled(_ content: UNNotificationContent) -> UNNotificationContent {
        let subscriptionID = CKNotification(fromRemoteNotificationDictionary: content.userInfo)?.subscriptionID
        guard isTimeSensitive(subscriptionID: subscriptionID),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        mutable.interruptionLevel = .timeSensitive
        return mutable
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
