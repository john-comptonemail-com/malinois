//
//  WatchNotificationService.swift
//  MalinoisWatchNotificationService
//
//  The watch's alert extension (BACKLOG 140, TestFlight 1.8 (74); ADR 0052): each iCloud alert passes through it before
//  watchOS shows it. A tamper alert is shown Time Sensitive, as the iPhone's extension shows it (ADR 0045), so the first
//  copy to arrive breaks through a Focus; iCloud's copy of an event whose relayed copy is already in the list is shown
//  quietly, since that copy tapped. It reads the push and the watch's list of notifications, nothing else: no record
//  (ADR 0039), nothing stored, the words as sent. The iPhone app's tests compile it too.
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
            deliver(WatchAlertPairing.iCloudContent(content, deliveredIdentifiers: listed))
        }
    }
}
