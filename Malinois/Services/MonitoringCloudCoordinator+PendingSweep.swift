//
//  MonitoringCloudCoordinator+PendingSweep.swift
//  Malinois
//
//  The cloud coordinator's pending-upload sweep. Single-flight, waiting and rerun state live in its core.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringCloudCoordinator {

    /// The most passes one sweep may make, and how many in a row may land nothing (item 79).
    nonisolated static let sweepMaxPasses = 20

    nonisolated static let sweepMaxIdlePasses = 3

    /// How many records in a row may fail, with no wait named by the server, before a pass
    /// takes it for an outage and stops handing out more (item 79; see `sweepDoorClosed`).
    nonisolated static let sweepMaxFailuresInARow = 3

    /// Pure (unit-tested; item 79): after a pass, how long to wait before the next — or nil to
    /// stop. Another pass is earned only by a TRANSIENT failure (a throttle, an outage, a lost
    /// response) with a network path up: a refusal is an answer the next trigger can re-ask,
    /// and an offline device has the reconnect trigger. The wait is the server's own
    /// Retry-After when it sent one, else a doubling fallback, clamped to the timing's floor
    /// and ceiling; the pass and idle-pass caps bound a sweep that is getting nowhere.
    nonisolated static func sweepFollowUpDelay(remaining: Int,
                                               transient: CloudExfiltrator.TransientFailure?,
                                               online: Bool, pass: Int, idlePasses: Int,
                                               floor: TimeInterval, ceiling: TimeInterval) -> TimeInterval? {
        guard remaining > 0, let transient, online,
              pass < sweepMaxPasses, idlePasses < sweepMaxIdlePasses else { return nil }
        let wanted = transient.retryAfter ?? floor * pow(2, Double(idlePasses))
        guard !wanted.isNaN else { return floor }   // never a number the sleep cannot take
        return min(max(wanted, floor), ceiling)
    }

    /// The transient failure this pass has met, if any: the cloud sender's own report — or,
    /// under the test seam, the closure's.
    private var sweepTransient: CloudExfiltrator.TransientFailure? {
        #if DEBUG
        if sweepUploadForTesting != nil { return sweepTransientForTesting }
        #endif
        return cloud.lastTransientFailure
    }

    private func clearSweepTransient() {
        #if DEBUG
        sweepTransientForTesting = nil
        #endif
        cloud.clearTransientFailure()
    }

    /// What a pass learns from one record's upload (item 79): whether it landed, and the
    /// transient failure standing in the pass so far, whichever record's save reported it.
    struct SweepUploadOutcome: Sendable {
        let id: UUID
        /// The row is synced: the upload's copy was still the row's when it landed.
        let landed: Bool
        /// The upload's record reached iCloud, whether or not its copy could mark the row (a later cancel of a run
        /// changed it meanwhile): what carries a pass's "disarmed" alert (item 170's codex-3).
        let uploaded: Bool
        let transient: CloudExfiltrator.TransientFailure?
    }

    /// Pure (unit-tested; item 79): whether a pass stops handing out records. The server
    /// naming a wait closes the door at once: that answer is about this device, not about one
    /// record, and everything handed out after it would spend its attempts for nothing. A
    /// transient failure WITHOUT a named wait (a lost path, a lost response, a stalled save)
    /// closes it only when several records in a row have failed with none landing in between,
    /// which is what an outage looks like — one record that cannot get through, a large clip
    /// on a slow link, must not hold the others back. Refusals never close it: each record
    /// gets its one attempt, as before.
    nonisolated static func sweepDoorClosed(transient: CloudExfiltrator.TransientFailure?,
                                            failuresInARow: Int) -> Bool {
        guard let transient else { return false }
        return transient.retryAfter != nil || failuresInARow >= sweepMaxFailuresInARow
    }

    /// A disarm record sent later than this after it happened is "late" (item 74 line 9).
    nonisolated static let lateDisarmSignalAge: TimeInterval = 600

    /// Pure (unit-tested; item 74 line 9, the owner's ruling (a)): the late disarm records in one
    /// sweep pass whose "disarmed" alert is skipped. A backlog of old disarms used to raise one
    /// alert per record on the owner's other devices. A disarm (or cancelled countdown, which
    /// writes the same signal) sent within `lateAfter` of happening always alerts; among the
    /// late ones only the newest does, so the owner still learns once that protection stopped.
    nonisolated static func mutedLateDisarmSignals(in pending: [Event], now: Date,
                                                   lateAfter: TimeInterval) -> Set<UUID> {
        let late = lateDisarms(in: pending, now: now, lateAfter: lateAfter)
        guard let newest = late.max(by: { $0.startDate < $1.startDate }) else { return [] }
        return Set(late.map(\.id)).subtracting([newest.id])
    }

    /// Pure: the late disarm records in a pass, disarms and cancelled countdowns sent more than `lateAfter` after they
    /// happened (item 74 line 9).
    nonisolated static func lateDisarms(in pending: [Event], now: Date, lateAfter: TimeInterval) -> [Event] {
        pending.filter { event in
            guard let kind = event.stateChange, CloudExfiltrator.disarmSignalWanted(kind: kind) else { return false }
            return now.timeIntervalSince(event.startDate) > lateAfter
        }
    }

    /// Pure (unit-tested; item 162's ds4f1-1017-6): the late disarm that carries a pass's one "disarmed" alert when the
    /// newest, which was to carry it, did not land: the newest of the pass's late disarms that did. Nil when the newest
    /// landed, or none did. Before, that pass sent no alert, and none came at all if the newest never landed.
    nonisolated static func lateDisarmAlertStandIn(late: [Event], landed: Set<UUID>) -> Event? {
        guard let carrier = late.max(by: { $0.startDate < $1.startDate }), !landed.contains(carrier.id) else { return nil }
        return late.filter { landed.contains($0.id) }.max(by: { $0.startDate < $1.startDate })
    }

    /// The late disarms' one alert, sent for `event`, a late disarm whose record landed in this pass, when the newest
    /// did not (`lateDisarmAlertStandIn`). Its failure is logged, as any disarm signal's is.
    private func sendLateDisarmAlert(for event: Event) async {
        #if DEBUG
        sweepStandInAlertsForTesting.append(event.id)
        if sweepUploadForTesting != nil { return }
        #endif
        await cloud.pushDisarmSignal(event)
    }

    /// One record's upload inside the sweep.
    /// `disarmSignal`: false for a late disarm this pass does not alert for (item 74 line 9).
    func sweepUpload(_ event: Event, disarmSignal: Bool) async -> SweepUploadOutcome {
        #if DEBUG
        sweepDisarmSignalsForTesting[event.id] = disarmSignal
        if let upload = sweepUploadForTesting {
            let outcome = await upload(event)
            let current = applyUploadCompletion(outcome.state, snapshot: event)
            if current, let transient = outcome.transient { sweepTransientForTesting = transient }
            let landed = eventStore.events.first { $0.id == event.id }?.cloudSyncState == .synced
            return SweepUploadOutcome(id: event.id, landed: landed, uploaded: outcome.state == .synced,
                                      transient: sweepTransient)
        }
        #endif
        let uploaded = await exfiltrate(event, disarmSignal: disarmSignal)
        let landed = eventStore.events.first { $0.id == event.id }?.cloudSyncState == .synced
        return SweepUploadOutcome(id: event.id, landed: landed, uploaded: uploaded, transient: sweepTransient)
    }

    /// Uploads whatever has not reached iCloud yet: the pending sweep. Started by the launch,
    /// every foreground, a reconnect, an encrypted-data reset's requeue, and the Event Log
    /// (opening it, pull-to-refresh, Retry). Single-flight — see `retryingSync`.
    ///
    /// Returns when the FIRST pass is done, as it always has: the Event Log and the launch
    /// both follow it with a pull, which must not sit behind a throttle's waits. When a pass
    /// ends on a transient failure with records left, the sweep carries on by itself (item
    /// 79): follow-up passes on the engine's own task, each after the wait
    /// `sweepFollowUpDelay` names, until nothing is left or that rule says stop.
    /// `pendingSweepActive` covers the whole of it, `pendingSweepWaiting` the waits.
    func retryPendingSync() async {
        guard entitlements.proActive else { return }   // cloud backup is Pro
        guard !retryingSync else { return }
        retryingSync = true
        pendingSweepActive = true
        // The first pass makes the sweep's first identity lookup itself (item 155's S3, Codex's second look): a
        // preflight lookup here used to record a throttle's wait, which the pass then cleared before looking up
        // again at once. Now the pass's own lookup is the first: a throttle on it hands nothing out and its wait
        // reaches the follow-up, as a lookup that failed for want of a network has since item 152's lead 1; no
        // account ends the sweep at once, as before.
        await runSweepPass(1, idlePasses: 0)
    }

    private func endPendingSweep() {
        retryingSync = false
        pendingSweepActive = false
        guard sweepRerunOwed else { return }   // asked for while this one ran (item 116, N1)
        sweepRerunOwed = false
        let lifetime = retainHostForFiniteWork()
        Task { defer { lifetime.keepAlive() }; await retryPendingSync() }
    }

    /// One pass over what is pending right now; then the sweep either ends or schedules its
    /// next pass. `idlePasses` counts the passes before this one that landed nothing, in a row.
    private func runSweepPass(_ pass: Int, idlePasses: Int) async {
        clearSweepTransient()
        #if DEBUG
        let needsLease = sweepUploadForTesting == nil || requiresCloudLeaseForTesting
        #else
        let needsLease = true
        #endif
        var lease: CloudEnrollment.Lease?
        if needsLease { lease = await cloud.acquireCloudLease() }
        if needsLease, lease == nil, sweepTransient == nil {
            endPendingSweep()   // no account, or another one
            return
        }
        // Captures discarded unchecked are asked of iCloud first, under this pass's lease (no lookup of their own), so a
        // mark this sets goes up with this pass (item 166's codex-24). A wait iCloud names to that question closes the
        // pass's door before any upload, as a save's does (codex-28).
        if let lease { await checkDiscardedCaptures(lease: lease) }
        let doorClosedBeforeUploads = Self.sweepDoorClosed(transient: sweepTransient, failuresInARow: 0)
        // Bounded concurrency: a day's worth of offline events, each doing up to a
        // few retries, would take tens of seconds run strictly serially (and hang
        // pull-to-refresh). Run a few at a time so badges clear quickly without
        // flooding CloudKit.
        var pending = Self.sweepOrder(eventStore.events.filter { $0.cloudSyncState != .synced && backupAllows($0) })   // items 115, 148
        if needsLease {
            if let lease, !doorClosedBeforeUploads {
                pending = pending.filter { cloud.enrollment.authorizeUpload(event: $0, lease: lease) }
            } else {
                // The lookup failed for want of a network (item 152's lead 1) or met a throttle (item 155's S3), or the
                // check met a named wait (codex-28): nothing handed out; the follow-up below keeps its wait.
                pending = []
            }
        }
        // One "disarmed" alert for a backlog of late disarms, not one per record (item 74 line 9).
        let passStart = Date()
        let muted = Self.mutedLateDisarmSignals(in: pending, now: passStart, lateAfter: Self.lateDisarmSignalAge)
        let late = Self.lateDisarms(in: pending, now: passStart, lateAfter: Self.lateDisarmSignalAge)
        let maxConcurrent = 3
        var uploadedIDs = Set<UUID>()   // what each upload did, for the late disarms' alert (item 170's codex-3)
        await withTaskGroup(of: SweepUploadOutcome.self) { group in
            var next = pending.makeIterator()
            for _ in 0..<maxConcurrent {
                if let event = next.next() { group.addTask { await self.sweepUpload(event, disarmSignal: !muted.contains(event.id)) } }
            }
            // A throttle or an outage closes the door for this pass (item 79; the rule is
            // `sweepDoorClosed`): what is in flight finishes, and the rest waits for the
            // follow-up pass. It used to be handed out regardless, each record spending its
            // three attempts against a server that had just said "not now", and failing until
            // the next trigger.
            var failuresInARow = 0
            var doorClosed = false
            while let outcome = await group.next() {
                if outcome.uploaded { uploadedIDs.insert(outcome.id) }
                failuresInARow = outcome.landed ? 0 : failuresInARow + 1
                doorClosed = doorClosed || Self.sweepDoorClosed(transient: outcome.transient,
                                                                failuresInARow: failuresInARow)
                if !doorClosed, let event = next.next() { group.addTask { await self.sweepUpload(event, disarmSignal: !muted.contains(event.id)) } }
            }
        }
        // R3-2 backstop: a sweep whose only traffic was state records (their branch consumes
        // now, but belt-and-braces) — and any flag raised between checks — is acted on at
        // the tail of every pass, so no process ends holding a detected-but-ignored reset.
        handleEncryptedDataResetIfNeeded()

        let handedOut = Set(pending.map(\.id))
        let landedIDs = Set(eventStore.events.filter { handedOut.contains($0.id) && $0.cloudSyncState == .synced }.map(\.id))
        let landed = landedIDs.count
        // The late disarms' alert, if the newest, which was to carry it, did not land (item 162's ds4f1-1017-6): by what
        // each upload did, not by the rows, which a later cancel of a run can leave unsynced (item 170's codex-3).
        if let standIn = Self.lateDisarmAlertStandIn(late: late, landed: uploadedIDs) { await sendLateDisarmAlert(for: standIn) }
        let remaining = EventStore.unsyncedCount(in: eventStore.events) + discardChecksOwed   // an owed check comes back too (codex-28)
        let idle = landed > 0 ? 0 : idlePasses + 1
        guard let wait = Self.sweepFollowUpDelay(remaining: remaining, transient: sweepTransient,
                                                 online: connectivity.isOnline, pass: pass, idlePasses: idle,
                                                 floor: timing.sweepWaitFloor,
                                                 ceiling: timing.sweepWaitCeiling) else {
            if pass > 1 || remaining > 0 {
                Log.engine.info("Pending sweep ended at pass \(pass, privacy: .public): \(landed, privacy: .public) landed, \(remaining, privacy: .public) left")
            }
            endPendingSweep()
            return
        }
        let asked = sweepTransient?.retryAfter.map { String(format: "%.0f s", $0) } ?? "no wait"
        Log.engine.info("Pending sweep pass \(pass, privacy: .public): \(landed, privacy: .public) landed, \(remaining, privacy: .public) left; iCloud named \(asked, privacy: .public), next pass in \(wait, privacy: .public) s")
        pendingSweepWaiting = true
        // The follow-up pass belongs to the engine, not to whoever asked for the sweep: a
        // screen's task is cancelled when the screen closes, and a cancelled wait is no wait.
        let lifetime = retainHostForFiniteWork()
        Task {
            defer { lifetime.keepAlive() }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self.pendingSweepWaiting = false
            await self.runSweepPass(pass + 1, idlePasses: idle)
        }
    }
}
