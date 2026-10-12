//
//  NotificationService.swift
//  MalinoisNotificationService
//

import UserNotifications

/// Delivers the subscription's generic alert without reading private CloudKit evidence.
/// The extension cannot verify the main app's installation-bound enrollment. Until a shared
/// authorization design is implemented and tested across reinstalls, fetching details here
/// would bypass that boundary. Sound and interruption level remain exactly as sent.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(request.content)
    }
}
