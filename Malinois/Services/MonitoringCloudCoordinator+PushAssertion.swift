//
//  MonitoringCloudCoordinator+PushAssertion.swift
//  Malinois
//
//  Item 153's MAL-01 (1.8.1; ADR 0003 amended). The engine spawned its fact pushes on bare tasks, so the lapse record
//  written as the scene left the foreground, and a trip's fact pushed just before a lock or a kill, had no
//  background-task assertion until the uploader took one after its identity lookup and its queue wait. Now the spawn
//  holds one from before the task exists (the status records' spawn, `logStateChange`, does the same in the main
//  file), and the uploader's own assertion covers the push itself from its first step on. The cloud coordinator
//  owns these spawns and their binding-use counts. Item 162's A10 (1.8.2): the uploader reads the log's copy of
//  an event when a push's turn comes, through the hook wired here.
//

import Foundation

extension MonitoringCloudCoordinator {
    /// Pushes the bare fact of an event to iCloud at once (Pro only, iCloud backup permitting), on a task that holds
    /// a background-task assertion from before it is spawned: a lock or a kill right now finds it held (item 153's
    /// MAL-01). The uploader takes its own from its first step on; UIKit allows both. The record's account binding is
    /// kept from before the task starts until the push ends (`beginBindingUse`; codex-6 on 1.8.2's step 17). A failed
    /// fact, including a thumbnail still owed, reopens its matching synced row through the uploader's queued hook.
    func pushFactIfCloud(_ event: Event) {
        guard cloudAllowed, backupAllows(event) else { return }   // item 115
        let hold = BackgroundAssertion.begin("malinois-fact-task")
        beginBindingUse(event.id)
        let lifetime = retainHostForFiniteWork()
        Task {
            defer { lifetime.keepAlive() }
            defer { hold.end(); endBindingUse(event.id) }
            await cloud.pushFact(event)   // enqueue awaits the chained work, so this returns post-attempt
            handleEncryptedDataResetIfNeeded()   // R3-2: fact pushes consume the reset flag too
        }
    }

    /// Work that will still upload under `id`'s binding begins (`bindingsInUse`): counted, so overlapping uses of one
    /// record keep its binding until the last ends.
    func beginBindingUse(_ id: UUID) { bindingsInUse[id, default: 0] += 1 }

    /// That work has ended.
    func endBindingUse(_ id: UUID) {
        guard let running = bindingsInUse[id] else { return }
        bindingsInUse[id] = running > 1 ? running - 1 : nil
    }

    /// Hands `event` to a full upload on a task, its binding in use from now until the upload ends: the upload's own
    /// pin (`EventStore.beginUpload`) starts only when the task runs, and the prune can run first (codex-6 on
    /// `0ed887f`). The event limit's choices are unchanged: this keeps the binding, not the row.
    func exfiltrateInBackground(_ event: Event, cloudAllowedOverride: Bool? = nil) {
        beginBindingUse(event.id)
        let lifetime = retainHostForFiniteWork()
        Task {
            defer { lifetime.keepAlive() }
            defer { endBindingUse(event.id) }
            await exfiltrate(event, cloudAllowedOverride: cloudAllowedOverride)
        }
    }

    /// Hands the uploader the log's copy of each event (item 162's A10), at init: a push reads it when its turn comes in
    /// the event's queue, so every write carries the event as the log holds it then, never an older copy. And the store
    /// what it asks of the engine: whether a discard needs iCloud asked, and an upload pass for a clip its retry attached
    /// (BACKLOG 176's codex-5).
    func handTheUploaderTheLog() {
        cloud.storedEvent = { [weak self] id in self?.eventStore.events.first { $0.id == id } }
        cloud.mediaLanded = { [weak self] id, token, epoch in self?.eventStore.noteMediaUploaded(token, for: id, epoch: epoch) }
        cloud.factFailed = { [weak self] snapshot in self?.reopenAfterFailedFact(snapshot) }
        eventStore.discardNeedsCheck = { [weak self] event in self?.discardNeedsACheck(event) ?? true }
        eventStore.mediaAttachedLate = { [weak self] in self?.captureEvidenceStoredLate() }
    }
}
