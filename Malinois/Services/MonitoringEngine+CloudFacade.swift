// Compatibility entry points for cloud coordination owned by MonitoringCloudCoordinator.
import Foundation
import UIKit

extension MonitoringEngine {
    /// Keep the complete engine alive through each finite async facade call, matching
    /// the original instance method's ownership, even if its caller drops its reference.
    private func withCloudLifetime<Value>(
        _ operation: @MainActor (MonitoringCloudCoordinator) async -> Value
    ) async -> Value {
        let lifetime = MonitoringCloudCoordinator.FiniteWorkLifetime(owner: self)
        defer { lifetime.keepAlive() }
        return await operation(cloudCoordinator)
    }

    typealias CloudWipeResponse = MonitoringCloudCoordinator.CloudWipeResponse
    typealias LaunchPullKind = MonitoringCloudCoordinator.LaunchPullKind
    typealias SweepUploadOutcome = MonitoringCloudCoordinator.SweepUploadOutcome
    typealias PushFailureResponse = MonitoringCloudCoordinator.PushFailureResponse
    typealias MediaPlacement = MonitoringCloudCoordinator.MediaPlacement
    typealias EvidenceDownload = MonitoringCloudCoordinator.EvidenceDownload

    static var backupOffNotice: String { MonitoringCloudCoordinator.backupOffNotice }
    nonisolated static let cloudCheckSampleSize = MonitoringCloudCoordinator.cloudCheckSampleSize
    nonisolated static let discardCheckBatchSize = MonitoringCloudCoordinator.discardCheckBatchSize
    nonisolated static let beatTrimSessionsPerPass = MonitoringCloudCoordinator.beatTrimSessionsPerPass
    nonisolated static let sweepMaxPasses = MonitoringCloudCoordinator.sweepMaxPasses
    nonisolated static let sweepMaxIdlePasses = MonitoringCloudCoordinator.sweepMaxIdlePasses
    nonisolated static let sweepMaxFailuresInARow = MonitoringCloudCoordinator.sweepMaxFailuresInARow
    nonisolated static let lateDisarmSignalAge = MonitoringCloudCoordinator.lateDisarmSignalAge
    nonisolated static let maxDownloadedStillBytes = MonitoringCloudCoordinator.maxDownloadedStillBytes
    nonisolated static let maxDownloadedMovieBytes = MonitoringCloudCoordinator.maxDownloadedMovieBytes

    var cloudReuploadCount: Int? {
        get { cloudCoordinator.cloudReuploadCount }
        set { cloudCoordinator.cloudReuploadCount = newValue }
    }

    var bindingsInUse: [UUID: Int] {
        get { cloudCoordinator.bindingsInUse }
        set { cloudCoordinator.bindingsInUse = newValue }
    }

    var retryingSync: Bool {
        get { cloudCoordinator.retryingSync }
        set { cloudCoordinator.retryingSync = newValue }
    }

    var sweepRerunOwed: Bool {
        get { cloudCoordinator.sweepRerunOwed }
        set { cloudCoordinator.sweepRerunOwed = newValue }
    }

    var heartbeatSession: UUID? {
        get { cloudCoordinator.heartbeatSession }
        set { cloudCoordinator.heartbeatSession = newValue }
    }

    var discardChecksOwed: Int { cloudCoordinator.discardChecksOwed }

    #if DEBUG
    var evidencePushForTesting: ((Event) async -> CloudExfiltrator.ExfilOutcome)? {
        get { cloudCoordinator.evidencePushForTesting }
        set { cloudCoordinator.evidencePushForTesting = newValue }
    }

    var sweepUploadForTesting: ((Event) async -> (state: CloudSyncState, transient: CloudExfiltrator.TransientFailure?))? {
        get { cloudCoordinator.sweepUploadForTesting }
        set { cloudCoordinator.sweepUploadForTesting = newValue }
    }

    var sweepTransientForTesting: CloudExfiltrator.TransientFailure? {
        get { cloudCoordinator.sweepTransientForTesting }
        set { cloudCoordinator.sweepTransientForTesting = newValue }
    }

    var sweepDisarmSignalsForTesting: [UUID: Bool] {
        get { cloudCoordinator.sweepDisarmSignalsForTesting }
        set { cloudCoordinator.sweepDisarmSignalsForTesting = newValue }
    }

    var sweepStandInAlertsForTesting: [UUID] {
        get { cloudCoordinator.sweepStandInAlertsForTesting }
        set { cloudCoordinator.sweepStandInAlertsForTesting = newValue }
    }

    var cloudPresenceForTesting: (([String]) async -> Set<String>?)? {
        get { cloudCoordinator.cloudPresenceForTesting }
        set { cloudCoordinator.cloudPresenceForTesting = newValue }
    }

    var cloudAccountForTesting: String? {
        get { cloudCoordinator.cloudAccountForTesting }
        set { cloudCoordinator.cloudAccountForTesting = newValue }
    }

    var cloudFetchForTesting: ((Int) async -> (events: [Event], complete: Bool))? {
        get { cloudCoordinator.cloudFetchForTesting }
        set { cloudCoordinator.cloudFetchForTesting = newValue }
    }

    var beatSendForTesting: ((HeartbeatBeat) async -> Bool)? {
        get { cloudCoordinator.beatSendForTesting }
        set { cloudCoordinator.beatSendForTesting = newValue }
    }

    var latestBeatFetchForTesting: ((UUID) async -> LastHeard)? {
        get { cloudCoordinator.latestBeatFetchForTesting }
        set { cloudCoordinator.latestBeatFetchForTesting = newValue }
    }

    var beatTrailsTrimForTesting: (@MainActor ([BeatSession]) async -> [UUID: BeatTrimOutcome])? {
        get { cloudCoordinator.beatTrailsTrimForTesting }
        set { cloudCoordinator.beatTrailsTrimForTesting = newValue }
    }

    var requiresCloudLeaseForTesting: Bool {
        get { cloudCoordinator.requiresCloudLeaseForTesting }
        set { cloudCoordinator.requiresCloudLeaseForTesting = newValue }
    }

    var fullMediaFetchForTesting: (@MainActor (UUID, [String]?) async -> CloudExfiltrator.FullMediaFetch?)? {
        get { cloudCoordinator.fullMediaFetchForTesting }
        set { cloudCoordinator.fullMediaFetchForTesting = newValue }
    }
    #endif

    /// Home's notice when the launch check finds this phone's iCloud copies gone and queues them again (item 87). With
    /// iCloud backup off they upload only once it is turned back on; the notice said "uploading" (claude-1, found while
    /// checking Fable's fable-5 on 75). Pure (unit-tested).
    nonisolated static func cloudReuploadNotice(requeued: Int, backupOn: Bool) -> String {
        MonitoringCloudCoordinator.cloudReuploadNotice(requeued: requeued, backupOn: backupOn)
    }

    /// Whether iCloud backup lets this record upload. While backup is off nothing does, except the
    /// entry recording that it was turned off, so the cloud log shows it even when its first upload
    /// fails. An event recorded while backup was off never uploads, even once it is back on (the
    /// owner's ruling); the store marks it when it is added. While the settings wait for the unlock
    /// (ADR 0055) nothing uploads either: the switch is not known yet, and the pending sweep reads
    /// the answer again once it is.
    func backupAllows(_ event: Event) -> Bool {
        cloudCoordinator.backupAllows(event)
    }

    /// Turns iCloud backup on or off, only while disarmed and only once the settings are the owner's
    /// (ADR 0055); returns whether it did. The Settings switch asks for device authentication before
    /// turning it off; this records the change. Off is recorded before uploads stop, in the one
    /// entry that still uploads; on is recorded after, and a pending sweep then carries up what
    /// waited while backup was off (events recorded before it was turned off), once any sweep
    /// already running has ended (item 116, R4).
    @discardableResult
    func setCloudBackup(_ on: Bool) -> Bool {
        cloudCoordinator.setCloudBackup(on)
    }

    /// Wires the switch into the three places that apply it (first at init, before the settings' resolution can write a
    /// record; codex-12 on 1.8.2): the store marks an event
    /// recorded while backup is off; the enrollment registers it to no account, which older
    /// versions honour too (item 116, R3); and the uploader reads the rule before every step
    /// (R2). Each reads the switch as known (`cloudBackupKnownOff`, `cloudBackupKnownOn`): while the
    /// settings wait for the unlock nothing is marked, held or sent on the strength of a default (ADR 0055).
    func watchBackupSetting() {
        cloudCoordinator.watchBackupSetting()
    }

    /// Pure (unit-tested): which records the check looks for: this phone's own records that
    /// reached iCloud, the newest `limit`, newest first. Never a mirror (the capturing device owns
    /// it) or a record still waiting to go up.
    nonisolated static func cloudCheckSample(_ events: [Event], limit: Int) -> [Event] {
        MonitoringCloudCoordinator.cloudCheckSample(events, limit: limit)
    }

    /// Pure (unit-tested): whether the missing share says the copies were deleted: most of them
    /// gone, and never a single one (one record can be missing for its own reasons).
    nonisolated static func cloudCopiesDeleted(sampled: Int, missing: Int) -> Bool {
        MonitoringCloudCoordinator.cloudCopiesDeleted(sampled: sampled, missing: missing)
    }

    /// Pure (unit-tested): the response, from the account this installation is verified for and the
    /// current one (item 152's lead 13; before 1.8.2, the account remembered at the first check). The
    /// records go back up only to the account they went to; to another one never (the owner's
    /// evidence must not land in someone else's iCloud), and with either account unknown the check
    /// only reports.
    nonisolated static func cloudWipeResponse(enrolledAccount: String?, currentAccount: String?) -> CloudWipeResponse {
        MonitoringCloudCoordinator.cloudWipeResponse(enrolledAccount: enrolledAccount, currentAccount: currentAccount)
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
        await withCloudLifetime { coordinator in
            await coordinator.checkCloudCopies()
        }
    }

    /// The launch check's notice in the words for the backup switch as it is now: turned back on, as it asks, it no
    /// longer asks (Codex's codex-1 on 76). Nothing when the check queued nothing.
    func refreshCloudReuploadNotice() {
        cloudCoordinator.refreshCloudReuploadNotice()
    }

    /// Item 166's codex-24 (the owner's option (b)): a locally discarded capture with no current receipt is marked
    /// lost only once iCloud says it holds none of its files, including after cloud loss voids an already-pruned
    /// capture's receipts. What iCloud holds becomes the
    /// capture's record instead. Asked at each sweep pass, under the pass's lease (no identity lookup of its own), in one
    /// fetch for up to `discardCheckBatchSize` of this phone's captures bound to the lease's account, whose records the
    /// check reads, the oldest first; an answer that is not conclusive leaves them to the next pass or sweep, their
    /// download offered meanwhile.
    func checkDiscardedCaptures(lease: CloudEnrollment.Lease) async {
        await withCloudLifetime { coordinator in
            await coordinator.checkDiscardedCaptures(lease: lease)
        }
    }

    /// Whether a capture the byte limit discards with no record of a landed file needs iCloud asked before it is marked
    /// lost (item 166's codex-24): not one that can never have gone up, recorded while iCloud backup was off or tied to no
    /// account (the binding every upload needs); those are marked at once, as before. A record the restore's rebuild tied
    /// to no account is not one of those: its upload history is unknown (codex-29), and its check is owed.
    func discardNeedsACheck(_ event: Event) -> Bool {
        cloudCoordinator.discardNeedsACheck(event)
    }

    /// Pure (unit-tested): the camera or slot token of a photo record's name, "photo-front-v2-…" → "front".
    nonisolated static func mediaToken(fromPhotoRecordName name: String) -> String? {
        MonitoringCloudCoordinator.mediaToken(fromPhotoRecordName: name)
    }

    /// Pure (unit-tested): the automatic purge runs at most about daily on SUCCESS, and a
    /// failed attempt retries after a short backoff instead of waiting the full day (R3-9)
    /// — but never a hot loop: every attempt, failed included, backs off at least an hour.
    nonisolated static func autoPurgeDue(lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Bool {
        MonitoringCloudCoordinator.autoPurgeDue(lastSuccess: lastSuccess, lastAttempt: lastAttempt, now: now)
    }

    /// The watches waiting for their trails to be trimmed, shared with log migration.
    static func beatSessions() -> [BeatSession] {
        MonitoringCloudCoordinator.beatSessions()
    }

    /// A Pro watch going live joins the list (a free watch never beats, so it never does), after
    /// the log's own arm records if they were never added.
    func registerBeatSession(_ session: BeatSession) {
        cloudCoordinator.registerBeatSession(session)
    }

    /// Pure (unit-tested): the watches waiting, with the log's own arm records added that are
    /// not there yet (once, for watches from before the list existed). Another phone's arm
    /// record is not this phone's watch.
    nonisolated static func seededBeatSessions(_ sessions: [BeatSession], from events: [Event]) -> [BeatSession] {
        MonitoringCloudCoordinator.seededBeatSessions(sessions, from: events)
    }

    /// Rebuilds the account bindings, once the complete log is readable, when their file is missing (a restore from a
    /// device backup, which leaves it out, or an update from before 1.5.1): every restored first-hand record held, its
    /// upload history noted as unknown (item 166's codex-29), and other devices' copies left for the next fetch to bind
    /// (`CloudEnrollment.holdRestoredEvents`; codex-7 on 1.8.2, twice; the owner's ruling (a), hold rather than guess).
    /// Then the bindings no record needs any longer go (item 153's MAL-08). Moved here from MonitoringEngine.swift, which
    /// sits at the lint size limit.
    func seedCloudOwnershipIfReadable() {
        cloudCoordinator.seedCloudOwnershipIfReadable()
    }

    /// Prunes the account bindings no record needs any longer (item 153's MAL-08), once the complete log is read: a
    /// log not read from disk reads as empty, and pruning from it would drop every binding. Kept: the log's records,
    /// uploads under way, the bindings work still uses (`bindingsInUse`: fact pushes waiting their turn, and a response
    /// or capture from its record's registration until its upload ends, since a record can leave a full log during its
    /// capture; Codex's codex-6, twice), the live flood's record (the engine still pushes it after its row has left a
    /// full log), the event limit's removals whose unsynced-removal marker has not read them yet (item 114; the
    /// marker's rule reads their bindings), the Pro watches whose heartbeat trails iCloud may still hold, and the live
    /// watch.
    func pruneCloudBindingsIfReadable() {
        cloudCoordinator.pruneCloudBindingsIfReadable()
    }

    /// Pure (unit-tested): the watches due for a trim, oldest first: begun before `cutoff`, and
    /// not the watch that is live. Whether a due watch's trail goes is the cloud's call, on the
    /// server time of its last beat (`CloudExfiltrator.trimBeatTrails`).
    nonisolated static func sessionsDueForBeatTrim(sessions: [BeatSession], cutoff: Date, live: UUID?) -> [BeatSession] {
        MonitoringCloudCoordinator.sessionsDueForBeatTrim(sessions: sessions, cutoff: cutoff, live: live)
    }

    /// Enforces the automatic cloud-retention policy (32.R2), quietly and at most daily.
    /// Only the auto modes delete anything here — Manual deletes solely through the owner's
    /// explicit Settings action, and Keep-forever never deletes at all. Pro-gated like every
    /// cloud path, and never run while the settings wait for the unlock (ADR 0055: the
    /// defaults' 12 months are not the owner's policy); device dates schedule attempts and shortlist sessions, but each deleting
    /// call derives the policy and 30-day floor from CloudKit system timestamps. What it deletes: full-resolution media past the setting,
    /// and (item 52's follow-up 2) the per-beat trails of this phone's watches whose last beat
    /// is past it, each watch keeping its latest beat.
    func enforceCloudRetentionIfDue() async {
        await withCloudLifetime { coordinator in
            await coordinator.enforceCloudRetentionIfDue()
        }
    }

    /// Whether the owner's setting still asks the automatic clean-up for `months` (item 169's codex-2).
    func automaticRetentionWants(months: Int) -> Bool {
        cloudCoordinator.automaticRetentionWants(months: months)
    }

    /// Uploads camera evidence the pipeline stored after the response's own upload had run
    /// (`CapturePipelineHost`). Free users have no cloud upload: `retryPendingSync` returns at
    /// once for them.
    func captureEvidenceStoredLate() {
        cloudCoordinator.captureEvidenceStoredLate()
    }

    /// Asks for a pending sweep that must not be lost. With none running, one starts now. With one
    /// running, which chose its records before the caller's became pending and may end without
    /// another pass, another is owed, and `endPendingSweep` starts it when that sweep ends, however
    /// long it runs and whatever the clock does (item 116, N1: a ten-minute wait used to give up and
    /// ask anyway, and the single-flight guard turned it away). Used for late evidence (item 108,
    /// CE-01) and for iCloud backup turned back on (item 116, R4).
    func sweepAfterTheRunningOne() {
        cloudCoordinator.sweepAfterTheRunningOne()
    }

    /// Verify iCloud access just succeeded (item 143): run what a relaunch would have. The upload retry, then the launch
    /// pull, which fills the log from iCloud, settles a restore owed since the install, checks this phone's copies
    /// (item 87) and refreshes Home's "Allow notifications" line once another device's records are in. The button ran
    /// only the retry and a plain pull before, so the line and the restore waited for a relaunch. The pull still asks
    /// for everything the log can hold, as the button's did, where the launch rule alone would ask a log that already
    /// has records (a newly selected account) for one page. An owed reinstall record is written first (item 148's 5),
    /// so it binds to the verified account and the retry can upload it.
    func cloudAccessVerified() async {
        await withCloudLifetime { coordinator in
            await coordinator.cloudAccessVerified()
        }
    }

    /// Pure (unit-tested). How much the launch pull asks iCloud for: everything the local cap
    /// allows when the log is empty or a restore is owed — a fresh install, whose records are in
    /// iCloud, not missing, including one whose first pull could not reach it (item 89, C1) —
    /// and one page otherwise, which is what the other devices did since.
    nonisolated static func launchSyncLimit(localEventCount: Int, restoreOwed: Bool = false,
                                            cap: Int, page: Int) -> Int {
        MonitoringCloudCoordinator.launchSyncLimit(localEventCount: localEventCount, restoreOwed: restoreOwed, cap: cap, page: page)
    }

    /// Pure (unit-tested): what the launch pull is doing, by the same rule as `launchSyncLimit`:
    /// a restore when the log is empty or a restore is owed, otherwise a routine check. Home said
    /// "Restoring" on every launch before (owner, 2026-10-11), which read as lost history.
    nonisolated static func launchPullKind(localEventCount: Int, restoreOwed: Bool) -> LaunchPullKind {
        MonitoringCloudCoordinator.launchPullKind(localEventCount: localEventCount, restoreOwed: restoreOwed)
    }

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
        MonitoringCloudCoordinator.sweepFollowUpDelay(
            remaining: remaining,
            transient: transient,
            online: online,
            pass: pass,
            idlePasses: idlePasses,
            floor: floor,
            ceiling: ceiling
        )
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
        MonitoringCloudCoordinator.sweepDoorClosed(transient: transient, failuresInARow: failuresInARow)
    }

    /// Pure (unit-tested; item 74 line 9, the owner's ruling (a)): the late disarm records in one
    /// sweep pass whose "disarmed" alert is skipped. A backlog of old disarms used to raise one
    /// alert per record on the owner's other devices. A disarm (or cancelled countdown, which
    /// writes the same signal) sent within `lateAfter` of happening always alerts; among the
    /// late ones only the newest does, so the owner still learns once that protection stopped.
    nonisolated static func mutedLateDisarmSignals(in pending: [Event], now: Date,
                                                   lateAfter: TimeInterval) -> Set<UUID> {
        MonitoringCloudCoordinator.mutedLateDisarmSignals(in: pending, now: now, lateAfter: lateAfter)
    }

    /// Pure: the late disarm records in a pass, disarms and cancelled countdowns sent more than `lateAfter` after they
    /// happened (item 74 line 9).
    nonisolated static func lateDisarms(in pending: [Event], now: Date, lateAfter: TimeInterval) -> [Event] {
        MonitoringCloudCoordinator.lateDisarms(in: pending, now: now, lateAfter: lateAfter)
    }

    /// Pure (unit-tested; item 162's ds4f1-1017-6): the late disarm that carries a pass's one "disarmed" alert when the
    /// newest, which was to carry it, did not land: the newest of the pass's late disarms that did. Nil when the newest
    /// landed, or none did. Before, that pass sent no alert, and none came at all if the newest never landed.
    nonisolated static func lateDisarmAlertStandIn(late: [Event], landed: Set<UUID>) -> Event? {
        MonitoringCloudCoordinator.lateDisarmAlertStandIn(late: late, landed: landed)
    }

    /// One record's upload inside the sweep.
    /// `disarmSignal`: false for a late disarm this pass does not alert for (item 74 line 9).
    func sweepUpload(_ event: Event, disarmSignal: Bool) async -> SweepUploadOutcome {
        await withCloudLifetime { coordinator in
            await coordinator.sweepUpload(event, disarmSignal: disarmSignal)
        }
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
        await withCloudLifetime { coordinator in
            await coordinator.retryPendingSync()
        }
    }

    /// Pushes the bare fact of an event to iCloud at once (Pro only, iCloud backup permitting), on a task that holds
    /// a background-task assertion from before it is spawned: a lock or a kill right now finds it held (item 153's
    /// MAL-01). The uploader takes its own from its first step on; UIKit allows both. The record's account binding is
    /// kept from before the task starts until the push ends (`beginBindingUse`; codex-6 on 1.8.2's step 17). A failed
    /// fact, including a thumbnail still owed, reopens its matching synced row through the uploader's queued hook.
    func pushFactIfCloud(_ event: Event) {
        cloudCoordinator.pushFactIfCloud(event)
    }

    /// Work that will still upload under `id`'s binding begins (`bindingsInUse`): counted, so overlapping uses of one
    /// record keep its binding until the last ends.
    func beginBindingUse(_ id: UUID) {
        cloudCoordinator.beginBindingUse(id)
    }

    /// That work has ended.
    func endBindingUse(_ id: UUID) {
        cloudCoordinator.endBindingUse(id)
    }

    /// Hands `event` to a full upload on a task, its binding in use from now until the upload ends: the upload's own
    /// pin (`EventStore.beginUpload`) starts only when the task runs, and the prune can run first (codex-6 on
    /// `0ed887f`). The event limit's choices are unchanged: this keeps the binding, not the row.
    func exfiltrateInBackground(_ event: Event, cloudAllowedOverride: Bool? = nil) {
        cloudCoordinator.exfiltrateInBackground(event, cloudAllowedOverride: cloudAllowedOverride)
    }

    /// Hands the uploader the log's copy of each event (item 162's A10), at init: a push reads it when its turn comes in
    /// the event's queue, so every write carries the event as the log holds it then, never an older copy. And the store
    /// what it asks of the engine: whether a discard needs iCloud asked, and an upload pass for a clip its retry attached
    /// (BACKLOG 176's codex-5).
    func handTheUploaderTheLog() {
        cloudCoordinator.handTheUploaderTheLog()
    }

    /// Pure (unit-tested): the order the pending sweep hands records out in: incidents (anything that is not a status
    /// entry, interruption records included) before status entries, each group in the order given (newest first).
    nonisolated static func sweepOrder(_ pending: [Event]) -> [Event] {
        MonitoringCloudCoordinator.sweepOrder(pending)
    }

    /// The launch-time pull (owner, 2026-09-04): the log used to fill from iCloud only on the
    /// Event Log's pull-to-refresh, so a fresh install showed "Event Log (0)" until the owner
    /// found the gesture — reading as evidence gone rather than not yet fetched. Runs once the
    /// entitlement has resolved (Pro-gated like every cloud path, through `syncFromCloud`), after
    /// the upload sweep, and says so on Home while it runs. Verify iCloud access runs it too, asking
    /// for at least `minimumLimit` (item 143, `cloudAccessVerified()`).
    func restoreFromCloudAtLaunch(minimumLimit: Int = 0) async {
        await withCloudLifetime { coordinator in
            await coordinator.restoreFromCloudAtLaunch(minimumLimit: minimumLimit)
        }
    }

    /// Handles a subscription push end to end and reports **what actually happened**.
    ///
    /// The AppDelegate used to post a notification and call the completion handler with
    /// `.newData` in the same breath, while the fetch had not started. That reported success for
    /// work that might fail, and — worse — told iOS the background work was finished while it
    /// was still running, so the system was free to suspend the app mid-copy. The push exists
    /// precisely so the evidence reaches a second device; being suspended halfway defeats it.
    func handleRemotePush() async -> UIBackgroundFetchResult {
        await withCloudLifetime { coordinator in
            await coordinator.handleRemotePush()
        }
    }

    /// Pure (unit-tested). `.failed` is reported only for a query that genuinely failed — a
    /// free-tier device that never pulls, and a pull that found nothing new, are both `.noData`.
    nonisolated static func pushResult(pro: Bool, fetchFailed: Bool, added: Int) -> UIBackgroundFetchResult {
        MonitoringCloudCoordinator.pushResult(pro: pro, fetchFailed: fetchFailed, added: added)
    }

    /// Starts at go-live: the first beat at once, so the session's latest record exists from the
    /// start, then one every `heartbeatInterval`. A Pro watch joins the list the retention pass
    /// trims old trails from (item 52's follow-up 2).
    func startHeartbeat(session: UUID) {
        cloudCoordinator.startHeartbeat(session: session)
    }

    /// Stops at the disarm.
    func stopHeartbeat() {
        cloudCoordinator.stopHeartbeat()
    }

    /// When another phone was last heard from, for the watch whose arm record is `session`.
    func lastHeard(session: UUID) async -> LastHeard {
        await withCloudLifetime { coordinator in
            await coordinator.lastHeard(session: session)
        }
    }

    /// Uploads evidence even after disarm, retaining the record's creation-time cloud permission
    /// when supplied. Retries use current entitlement. Only a still-matching event snapshot
    /// receives the completion's sync state and failure UI; newer evidence keeps its own state. Answers whether the
    /// upload's record reached iCloud, whether or not its copy could mark the row (item 170's codex-3).
    @discardableResult
    func exfiltrate(_ event: Event, cloudAllowedOverride: Bool? = nil, disarmSignal: Bool = true) async -> Bool {
        await withCloudLifetime { coordinator in
            await coordinator.exfiltrate(event, cloudAllowedOverride: cloudAllowedOverride, disarmSignal: disarmSignal)
        }
    }

    /// Go loud only on evidence of interference — a terminal network-class failure, under
    /// the same canary conditions as before. A refusal is surfaced whatever the state (a
    /// disarmed retry that discovers a full iCloud is still worth telling the owner about).
    /// An unclassified failure stays quiet: only evidence may escalate.
    nonisolated static func pushFailureResponse(syncState: CloudSyncState, isStateChange: Bool,
                                                interference: Bool?, jammingResponse: Bool,
                                                hadConnectivityAtArm: Bool, online: Bool,
                                                watching: Bool) -> PushFailureResponse {
        MonitoringCloudCoordinator.pushFailureResponse(
            syncState: syncState,
            isStateChange: isStateChange,
            interference: interference,
            jammingResponse: jammingResponse,
            hadConnectivityAtArm: hadConnectivityAtArm,
            online: online,
            watching: watching
        )
    }

    /// Pure (unit-tested; BACKLOG 37): the sync state an arm/disarm audit record lands in
    /// after its push attempt. One lifecycle for evidence and audit rows — a failed push is
    /// `.localOnly` ("safe on device; uploads when a path exists"), exactly like a media
    /// event whose classified attempt exhausted; `.pending` stays the birth/in-flight state.
    /// It used to map failure back to `.pending`, so an offline arm/disarm row parked on
    /// "Syncing…" forever while the media row beside it walked orange → red → green. Retry
    /// coverage is unaffected — every sweep keys on `!= .synced`, which spans both — and the
    /// go-loud gate never sees these rows at all (`pushFailureResponse` excludes state
    /// records; the state branch above also returns before the classifier runs).
    nonisolated static func stateChangeSyncState(pushed: Bool) -> CloudSyncState {
        MonitoringCloudCoordinator.stateChangeSyncState(pushed: pushed)
    }

    /// After marking events owner-attributed locally, re-push their (tiny) meta so the
    /// CloudKit copy and any cross-device alert reflect it too — otherwise the flag only
    /// ever exists on-device (R-06). Deterministic record IDs make it a cheap upsert.
    ///
    /// A re-push that does not complete, including a thumbnail still owed, reopens its still-matching record for the
    /// pending sweep inside the uploader's queue (item 65, finding 3): the record was `.synced`, so a failed fact left
    /// the attribution on this device forever. Reopened, the sweep carries it up on the
    /// next chance (the media re-uploads with it: an upsert of bytes the cloud already
    /// holds, the price of a rare failure path staying simple).
    func reExfiltrateOwnerAttributed(_ ids: Set<UUID>) {
        cloudCoordinator.reExfiltrateOwnerAttributed(ids)
    }

    /// Pulls mirrored evidence down from iCloud and folds it into the local log (BACKLOG 9b).
    ///
    /// This is the app's first-ever CloudKit **read**. Two deliberate constraints, both from
    /// the risk note attached to the item: the merge only ever *adds* (a local event with the
    /// same id always wins), and every merged copy is marked with `sourceDevice` so a mirror
    /// can never be mistaken for first-hand evidence captured here.
    ///
    /// Pro-gated like every other cloud path — a free user's evidence never left the device,
    /// so there is nothing to pull back.
    @discardableResult
    /// `limit` is per record type. The default is one page, which is right for a push wake-up:
    /// it exists to pull down the event that just fired, not to reconcile the whole log. A
    /// **restore** — pull-to-refresh after a reinstall — asks for the local cap instead, because
    /// stopping early there means silently returning less evidence than iCloud actually holds.
    /// Which of the records count on Home as new is the store's call (`mergeFromCloud`).
    func syncFromCloud(limit: Int = CloudExfiltrator.fetchPageSize) async -> Int {
        await withCloudLifetime { coordinator in
            await coordinator.syncFromCloud(limit: limit)
        }
    }

    /// Pure (unit-tested).
    nonisolated static func mediaPlacement(itemCamera: String?, itemSlot: String,
                                           primaryFilled: Bool, secondaryFilled: Bool,
                                           primaryCamera: String?,
                                           secondaryCamera: String?) -> MediaPlacement {
        MonitoringCloudCoordinator.mediaPlacement(
            itemCamera: itemCamera,
            itemSlot: itemSlot,
            primaryFilled: primaryFilled,
            secondaryFilled: secondaryFilled,
            primaryCamera: primaryCamera,
            secondaryCamera: secondaryCamera
        )
    }

    nonisolated static func stageDownloadedAsset(at url: URL) async -> (media: EventStore.MediaSource, ext: String)? {
        await MonitoringCloudCoordinator.stageDownloadedAsset(at: url)
    }

    /// An iCloud encrypted-data reset purges every record in the zone (34.H13). Apple's
    /// prescribed recovery is a local re-upload: mark everything this device holds as
    /// pending again — the one sanctioned exception to sync-state monotonicity — tell the
    /// owner, and let the existing retry machinery carry it back up. Once per process:
    /// repeated failures while the reset settles must not re-run the requeue storm.
    func handleEncryptedDataResetIfNeeded() {
        cloudCoordinator.handleEncryptedDataResetIfNeeded()
    }

    /// A completion describes only its submitted snapshot. Ignore a changed or deleted event,
    /// preserving pending late evidence or a newer successful upload. Ignore only sync state and the contents of
    /// uploaded-media receipts, which can advance during the upload; the receipt generation and every other field
    /// must still match. This completion compares local cache filenames and the discard-check obligation strictly.
    @discardableResult
    func applyUploadCompletion(_ state: CloudSyncState, snapshot: Event) -> Bool {
        cloudCoordinator.applyUploadCompletion(state, snapshot: snapshot)
    }

    /// A failed fact (including a thumbnail still owed) reopens only its still-matching row. The uploader calls this
    /// inside the event's write queue; a later queued success therefore cannot be demoted by this completion.
    /// Cache paths and discard-check bookkeeping may change during the save without a newer successful fact.
    /// Their current values are kept for the retry; changed capture content, loss, attribution and epoch stay strict.
    func reopenAfterFailedFact(_ snapshot: Event) {
        cloudCoordinator.reopenAfterFailedFact(snapshot)
    }

    /// Downloads an event's full-resolution capture(s) from iCloud into the local store
    /// (BACKLOG 34.B1) — the retrieval half of the Pro backup promise, Pro-gated like every
    /// cloud path. The store takes ownership exactly as it does for a fresh capture: UUID
    /// filename, evidence-grade protection, derived thumbnail. Also recovers media the
    /// byte cap evicted locally — the cloud copy outlives the local eviction by design. The
    /// files join the record as it is when they land: a fetch can replace a mirror while the
    /// download runs, and writing back the copy read before it undid that (item 96). Camera
    /// placement also uses that current record, after staging and storage have finished, so
    /// newly learned labels and captures from another download cannot be overwritten.
    /// What lands counts toward the media byte limit (item 129, F4): the store runs the limit's
    /// pass as each file is attached, and on a phone over the limit it frees synced media oldest
    /// first, which can be the download itself; the iCloud copy stays, so it can be downloaded again.
    /// A capture iCloud gave that cannot be kept here (it fails to stage or to store) leaves the download incomplete,
    /// as an unchecked slot does: the rest is still to get (item 167's A2).
    func downloadFullEvidence(for id: UUID) async -> EvidenceDownload {
        await withCloudLifetime { coordinator in
            await coordinator.downloadFullEvidence(for: id)
        }
    }
}
