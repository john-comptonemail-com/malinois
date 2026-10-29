//
//  WatchNotificationService.swift
//  MalinoisWatchNotificationService
//
//  The watch's alert extension (BACKLOG 140, TestFlight 1.8 (74); ADR 0052): each iCloud alert passes through it before
//  watchOS shows it. A tamper alert is shown Time Sensitive, as the iPhone's extension shows it (ADR 0045), so the first
//  copy to arrive breaks through a Focus; iCloud's copy of an event whose relayed copy is already in the list is shown
//  quietly, since that copy tapped; and a tamper alert that is one of many arriving at once comes quietly, saying so
//  (ADR 0061), counted from the extension's own record of iCloud tamper arrivals, which the app's tidy-up of the list
//  cannot empty (item 169's codex-3). It reads the push and the watch's list of notifications, and keeps that record:
//  no CloudKit record (ADR 0039), the words as sent but for a burst. The iPhone app's tests compile it too.
//

import UserNotifications

/// Shows each iCloud alert by `WatchAlertPairing.iCloudContent`; if it does not finish in time, watchOS shows the push
/// as sent.
final class WatchNotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Handed to the list's completion, which UserNotifications calls once, on its own queue.
        nonisolated(unsafe) let deliver = contentHandler
        nonisolated(unsafe) let content = request.content
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let listed = Set(notifications.map(\.request.identifier))
            let now = Date()
            let earlier = WatchAlertPairing.isICloudTamperAlert(userInfo: content.userInfo)
                ? AlertBurst.recordArrival(at: now, defaults: .standard, key: AlertBurst.arrivalsKey)
                : AlertBurst.Record(arrivals: [], burstLast: nil)
            deliver(WatchAlertPairing.iCloudContent(content, deliveredIdentifiers: listed, earlierTamperArrivals: earlier.arrivals,
                                                    burstLast: earlier.burstLast, now: now))
        }
    }
}
