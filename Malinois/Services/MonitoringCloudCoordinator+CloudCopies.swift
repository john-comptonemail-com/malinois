//
//  MonitoringCloudCoordinator+CloudCopies.swift
//  Malinois
//
//  The cloud coordinator's cloud-loss checks and reupload notices. State lives in the coordinator core.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringCloudCoordinator {

    /// How many of the newest synced records the launch check looks for.
    nonisolated static let cloudCheckSampleSize = 20

    /// How many captures awaiting a discard check (item 166's codex-24) one sweep pass asks iCloud about, in one fetch: a
    /// few record names each (two cameras, two schema generations), well within what one CloudKit fetch takes.
    nonisolated static let discardCheckBatchSize = 20

    /// Pure (unit-tested): which records the check looks for: this phone's own records that
    /// reached iCloud, the newest `limit`, newest first. Never a mirror (the capturing device owns
    /// it) or a record still waiting to go up.
    nonisolated static func cloudCheckSample(_ events: [Event], limit: Int) -> [Event] {
        Array(events.filter { $0.cloudSyncState == .synced && !$0.isMirrored }
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit))
    }

    /// Pure (unit-tested): whether the missing share says the copies were deleted: most of them
    /// gone, and never a single one (one record can be missing for its own reasons).
    nonisolated static func cloudCopiesDeleted(sampled: Int, missing: Int) -> Bool {
        missing >= 2 && missing * 2 > sampled
    }

    /// What the check does about deleted copies (item 87).
    enum CloudWipeResponse: Equatable { case reupload, differentAccount, unknownAccount }

    /// Pure (unit-tested): the response, from the account this installation is verified for and the
    /// current one (item 152's lead 13; before 1.8.2, the account remembered at the first check). The
    /// records go back up only to the account they went to; to another one never (the owner's
    /// evidence must not land in someone else's iCloud), and with either account unknown the check
    /// only reports.
    nonisolated static func cloudWipeResponse(enrolledAccount: String?, currentAccount: String?) -> CloudWipeResponse {
        guard let enrolledAccount, let currentAccount else { return .unknownAccount }
        return enrolledAccount == currentAccount ? .reupload : .differentAccount
    }

    /// The launch check (item 87, run after the launch pull): are this phone's newest synced
    /// records still in iCloud? "Delete Data from iCloud" in iOS Settings needs only the unlocked
    /// phone outside Guided Access (item 64) and raises no error at the next save, so nothing else
    /// notices it. An answer that is not conclusive changes nothing. It looks for, and puts back, only
    /// the records bound to the account this installation is verified for (item 152's lead 13).
    /// Deciding by the account remembered at the first check missed copies deleted before any check had
    /// found them, and every copy after a deliberate change of account; and an older account's records,
    /// absent from the new one by design, read there as a deletion.
    func checkCloudCopies() async {
        guard entitlements.proActive else { return }
        let enrollment = cloud.enrollment
        guard let enrolled = enrollment.enrolledAccount else { return }   // nothing went up from an unverified one
        let bound = eventStore.events.filter { enrollment.isBound($0, to: enrolled) }
        let sample = Self.cloudCheckSample(bound, limit: Self.cloudCheckSampleSize)
        guard !sample.isEmpty else { return }
        // Each record under every name it can have: evidence 1.0 uploaded is still under 1.0's.
        let names = sample.flatMap(CloudExfiltrator.cloudRecordNames(for:))
        guard let present = await cloudPresence(names) else { return }
        let missing = sample.filter { !CloudExfiltrator.cloudRecordNames(for: $0).contains(where: present.contains) }.count
        // All (or all but one) in place: nothing to say. Before 1.8.2 the account was remembered here the first time
        // (item 87's choice 2a), for the bindings' rebuild; that rebuild holds every restored record now (codex-7).
        guard Self.cloudCopiesDeleted(sampled: sample.count, missing: missing) else { return }
        let current = await cloudAccountName()
        switch Self.cloudWipeResponse(enrolledAccount: enrolled, currentAccount: current) {
        case .reupload:
            // The records bound to that account only (item 152's lead 13); never a mirror.
            let requeued = eventStore.requeueForReupload { enrollment.isBound($0, to: enrolled) }
            cloudReuploadCount = requeued
            refreshCloudReuploadNotice()
            Log.engine.warning("Cloud copies missing (\(missing, privacy: .public) of \(sample.count, privacy: .public)); requeued \(requeued, privacy: .public)")
            let lifetime = retainHostForFiniteWork()
            Task { defer { lifetime.keepAlive() }; await retryPendingSync() }
        case .differentAccount:
            cloudResetNotice = "This phone's records are not in the iCloud account it is signed into, which is not "
                + "the one it used before. Malinois uploaded none of them to this account; they are still on this phone."
            Log.engine.warning("Cloud copies missing under a different iCloud account; nothing uploaded")
        case .unknownAccount:
            cloudResetNotice = "iCloud no longer holds this phone's records. They are still on this phone."
            Log.engine.warning("Cloud copies missing; the account cannot be confirmed, so nothing uploaded")
        }
    }

    /// The launch check's notice in the words for the backup switch as it is now: turned back on, as it asks, it no
    /// longer asks (Codex's codex-1 on 76). Nothing when the check queued nothing.
    func refreshCloudReuploadNotice() {
        guard let count = cloudReuploadCount else { return }
        cloudResetNotice = Self.cloudReuploadNotice(requeued: count, backupOn: settings.cloudBackup)
    }

    /// Item 166's codex-24 (the owner's option (b)): a locally discarded capture with no current receipt is marked
    /// lost only once iCloud says it holds none of its files, including after cloud loss voids an already-pruned
    /// capture's receipts. What iCloud holds becomes the
    /// capture's record instead. Asked at each sweep pass, under the pass's lease (no identity lookup of its own), in one
    /// fetch for up to `discardCheckBatchSize` of this phone's captures bound to the lease's account, whose records the
    /// check reads, the oldest first; an answer that is not conclusive leaves them to the next pass or sweep, their
    /// download offered meanwhile.
    func checkDiscardedCaptures(lease: CloudEnrollment.Lease) async {
        let batch = Array(eventStore.capturesAwaitingDiscardCheck
            .filter { cloud.enrollment.isBound($0, to: lease.account) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.discardCheckBatchSize))
        guard !batch.isEmpty else { return }
        let names = batch.map { CloudExfiltrator.fullMediaRecordNames(for: $0.id, manifest: $0.downloadManifest) }
        guard let present = await cloudPresence(names.flatMap { $0 }, lease: lease) else { return }   // no answer: asked again later
        for (event, eventNames) in zip(batch, names) {
            let landed = eventNames.filter(present.contains).compactMap(Self.mediaToken(fromPhotoRecordName:))
            eventStore.resolveDiscardCheck(event.id, landed: Set(landed), epoch: event.receiptEpoch)
        }
    }

    /// How many captures await a discard check this phone can ask iCloud about (bound to the verified account): a pass
    /// whose check met a transient failure comes back for them, as for a record still to upload (item 166's codex-28).
    var discardChecksOwed: Int {
        guard let account = cloud.enrollment.enrolledAccount else { return 0 }
        return eventStore.capturesAwaitingDiscardCheck.filter { cloud.enrollment.isBound($0, to: account) }.count
    }

    /// Whether a capture the byte limit discards with no record of a landed file needs iCloud asked before it is marked
    /// lost (item 166's codex-24): not one that can never have gone up, recorded while iCloud backup was off or tied to no
    /// account (the binding every upload needs); those are marked at once, as before. A record the restore's rebuild tied
    /// to no account is not one of those: its upload history is unknown (codex-29), and its check is owed.
    func discardNeedsACheck(_ event: Event) -> Bool {
        switch cloud.enrollment.uploadHoldReason(for: event) {
        case .backupOff?: return false
        case .unknownAccount?: return cloud.enrollment.uploadHistoryUnknown(for: event)
        default: return event.keptLocal != true
        }
    }

    /// Pure (unit-tested): the camera or slot token of a photo record's name, "photo-front-v2-…" → "front".
    nonisolated static func mediaToken(fromPhotoRecordName name: String) -> String? {
        guard name.hasPrefix("photo-") else { return nil }
        return name.dropFirst("photo-".count).split(separator: "-").first.map(String.init)
    }

    private func cloudPresence(_ names: [String]) async -> Set<String>? {
        #if DEBUG
        if let presence = cloudPresenceForTesting { return await presence(names) }
        #endif
        return await cloud.presentRecordNames(names)
    }

    /// The same under a lease the caller holds (codex-24's check, under the sweep pass's lease).
    private func cloudPresence(_ names: [String], lease: CloudEnrollment.Lease) async -> Set<String>? {
        #if DEBUG
        if let presence = cloudPresenceForTesting { return await presence(names) }
        #endif
        return await cloud.presentRecordNames(names, lease: lease)
    }

    private func cloudAccountName() async -> String? {
        #if DEBUG
        if cloudPresenceForTesting != nil { return cloudAccountForTesting }
        #endif
        return await cloud.userRecordName()
    }
}
