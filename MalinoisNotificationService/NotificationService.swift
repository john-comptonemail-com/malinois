//
//  NotificationService.swift
//  MalinoisNotificationService
//
//  The receiving iPhone's notification service extension (BACKLOG 76, ADR 0017). The
//  subscriptions ask for mutable pushes, so iOS hands this every cross-device alert before
//  showing it. It fetches the record the push names from the owner's private database (CloudKit
//  decrypts the record's fields for the signed-in owner; this code handles no keys) and words the
//  alert with `AlertRewrite`: the tripwires and the device; a banner without sound for a
//  Vision-only trip; Time Sensitive for every other tamper alert; the device's name on a disarm.
//
//  Fail loud: whatever goes wrong (no record in the push, a failed or slow fetch, a record type
//  it does not know, iOS ending the extension), the alert is shown as sent: "Tamper detected on
//  your device." with sound. A failure here never silences an alert.
//

import UserNotifications
import CloudKit

final class NotificationService: UNNotificationServiceExtension {

    /// How long the fetch may take. iOS gives the extension about 30 seconds; the rest is margin
    /// for handing over the alert as sent.
    private static let fetchDeadline: TimeInterval = 20

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var asSent: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        self.contentHandler = contentHandler
        asSent = request.content
        lock.unlock()
        let content = request.content
        guard let notification = CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification,
              let recordID = notification.recordID,
              let containerID = AlertRewrite.appContainerIdentifier(extensionBundleID: Bundle.main.bundleIdentifier)
        else { return deliver(content) }
        Task {
            let rewrite = await Self.rewrite(recordID: recordID, containerID: containerID)
            deliver(rewrite.map { Self.apply($0, to: content) } ?? content)
        }
    }

    /// iOS is about to end the extension: the alert goes out as sent.
    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let content = asSent
        lock.unlock()
        if let content { deliver(content) }
    }

    /// Hands iOS the alert once; a second call (the deadline racing the fetch) is dropped.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    /// Fetches the record and words its alert; nil when anything fails or runs out of time.
    private static func rewrite(recordID: CKRecord.ID, containerID: String) async -> AlertRewrite? {
        let database = CKContainer(identifier: containerID).privateCloudDatabase
        let record: CKRecord? = await withTaskGroup(of: CKRecord?.self) { group in
            group.addTask { try? await database.record(for: recordID) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(fetchDeadline * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let record, let kind = AlertRewrite.pushedRecord(ofType: record.recordType) else { return nil }
        let values = record.encryptedValues
        let deviceName = values["deviceName"] as? String
        switch kind {
        case .disarm:
            return .forDisarm(deviceName: deviceName)
        case .tamper:
            let event = AlertRewrite.tamperEvent(sensorsField: values["triggeredSensors"] as? String,
                                                 metadataJSON: values["metadataJSON"] as? String,
                                                 startDate: values["startDate"] as? Date)
            return .forTamper(event, deviceName: deviceName)
        }
    }

    /// The push's content with the rewrite's words, sound and level.
    private static func apply(_ rewrite: AlertRewrite, to content: UNNotificationContent) -> UNNotificationContent {
        guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        mutable.title = rewrite.title
        mutable.body = rewrite.body
        mutable.sound = rewrite.playsSound ? .default : nil
        mutable.interruptionLevel = rewrite.timeSensitive ? .timeSensitive : .active
        return mutable
    }
}
