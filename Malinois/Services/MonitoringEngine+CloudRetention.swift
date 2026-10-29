//
//  MonitoringEngine+CloudRetention.swift
//  Malinois
//
//  Cloud retention (32.R2) and the beat trails' trim: moved unchanged from MonitoringEngine.swift (BACKLOG 158's
//  first stage, 1.8.2's step 1), which sits at the lint size limit. Members the class needs elsewhere are internal;
//  the stored state stays in the class. Since 1.8.2 also the account bindings' upkeep: their prune (step 17) and their
//  one-time seeding, moved here with codex-7's change.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringEngine {

    /// Stamped only on an honestly-clean purge (the pre-R3-9 single stamp lives on as the
    /// success key, so existing devices carry their cadence over without a re-purge storm).
    private static let cloudRetentionLastRunKey = "com.malinois.cloudRetention.lastRun"

    /// Stamped before every attempt — the short-backoff half of the R3-9 cadence.
    private static let cloudRetentionLastAttemptKey = "com.malinois.cloudRetention.lastAttempt"

    /// Pure (unit-tested): the automatic purge runs at most about daily on SUCCESS, and a
    /// failed attempt retries after a short backoff instead of waiting the full day (R3-9)
    /// — but never a hot loop: every attempt, failed included, backs off at least an hour.
    nonisolated static func autoPurgeDue(lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Bool {
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < 20 * 3600 { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return false }
        return true
    }

    /// The most watches one retention pass hands over for trimming: a year of nightly watches is
    /// hundreds, and each is a fetch and a delete, so a first pass works through them over a few
    /// days (item 52's follow-up 2).
    nonisolated static let beatTrimSessionsPerPass = 50

    /// The watches waiting for their trails to be trimmed, shared with log migration.
    static func beatSessions() -> [BeatSession] { BeatSessionRegistry.read() }

    private static func saveBeatSessions(_ sessions: [BeatSession]) {
        BeatSessionRegistry.save(sessions)
    }

    /// A Pro watch going live joins the list (a free watch never beats, so it never does), after
    /// the log's own arm records if they were never added.
    func registerBeatSession(_ session: BeatSession) {
        seedBeatSessionsIfNeeded()
        var sessions = Self.beatSessions()
        guard !sessions.contains(where: { $0.id == session.id }) else { return }
        sessions.append(session)
        Self.saveBeatSessions(sessions)
    }

    /// Pure (unit-tested): the watches waiting, with the log's own arm records added that are
    /// not there yet (once, for watches from before the list existed). Another phone's arm
    /// record is not this phone's watch.
    nonisolated static func seededBeatSessions(_ sessions: [BeatSession], from events: [Event]) -> [BeatSession] {
        BeatSessionRegistry.addingLegacyWatches(sessions, from: events)
    }

    /// Seeds legacy watches from a complete, readable log. EventStore normally does
    /// this before count migration; the engine remains a fallback for a later readable
    /// store. A sealed or fresh log cannot complete one-time seeding.
    private func seedBeatSessionsIfNeeded() {
        guard eventStore.hasReadTheLog else { return }
        BeatSessionRegistry.seedIfNeeded(from: eventStore.events)
    }

    /// Rebuilds the account bindings, once the complete log is readable, when their file is missing (a restore from a
    /// device backup, which leaves it out, or an update from before 1.5.1): every restored first-hand record held, its
    /// upload history noted as unknown (item 166's codex-29), and other devices' copies left for the next fetch to bind
    /// (`CloudEnrollment.holdRestoredEvents`; codex-7 on 1.8.2, twice; the owner's ruling (a), hold rather than guess).
    /// Then the bindings no record needs any longer go (item 153's MAL-08). Moved here from MonitoringEngine.swift, which
    /// sits at the lint size limit.
    func seedCloudOwnershipIfReadable() {
        guard eventStore.hasReadTheLog else { return }
        cloud.enrollment.holdRestoredEvents(eventStore.events)
        pruneCloudBindingsIfReadable()
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
        guard eventStore.hasReadTheLog else { return }
        seedBeatSessionsIfNeeded()   // a legacy watch's arm record joins the list before anything is pruned
        var keeping = Set(eventStore.events.map(\.id)).union(eventStore.uploadsUnderWay)
        keeping.formUnion(bindingsInUse.keys)
        if let liveFloodAnchorID { keeping.insert(liveFloodAnchorID) }
        keeping.formUnion(eventStore.removalsAwaitingReport)
        keeping.formUnion(Self.beatSessions().map(\.id))
        if let heartbeatSession { keeping.insert(heartbeatSession) }
        let pruned = cloud.enrollment.pruneBindings(keeping: keeping)
        if pruned > 0 { Log.engine.info("Pruned \(pruned, privacy: .public) account bindings of records gone from the log") }
    }

    /// Pure (unit-tested): the watches due for a trim, oldest first: begun before `cutoff`, and
    /// not the watch that is live. Whether a due watch's trail goes is the cloud's call, on the
    /// server time of its last beat (`CloudExfiltrator.trimBeatTrails`).
    nonisolated static func sessionsDueForBeatTrim(sessions: [BeatSession], cutoff: Date, live: UUID?) -> [BeatSession] {
        sessions.filter { $0.start < cutoff && $0.id != live }.sorted { $0.start < $1.start }
    }

    /// Hands the due watches, oldest first and at most `beatTrimSessionsPerPass`, to the cloud,
    /// and drops from the list those it trimmed. A watch whose last beat is still inside the
    /// window, or whose trim failed, stays for a later pass; the pass's cadence is the media
    /// purge's alone, so a trim's leftovers never make the pass run sooner.
    private func trimOldBeatTrails(olderThan cutoff: Date, monthsOld months: Int,
                                   stillWanted: @escaping @MainActor () -> Bool) async {
        seedBeatSessionsIfNeeded()
        var candidates = Self.sessionsDueForBeatTrim(sessions: Self.beatSessions(), cutoff: cutoff, live: heartbeatSession)
        #if DEBUG
        let needsLease = beatTrailsTrimForTesting == nil || requiresCloudLeaseForTesting
        #else
        let needsLease = true
        #endif
        if needsLease {
            guard let lease = await cloud.acquireCloudLease() else { return }
            candidates = candidates.filter { cloud.enrollment.authorizeSession(session: $0.id, lease: lease) }
        }
        let due = Array(candidates.prefix(Self.beatTrimSessionsPerPass))
        guard !due.isEmpty else { return }
        let outcomes = await trimBeatTrails(due, monthsOld: months, stillWanted: stillWanted)
        let trimmed = Set(outcomes.filter { $0.value == .trimmed }.map(\.key))
        // Read again: a watch may have gone live and joined the list while the trims ran.
        Self.saveBeatSessions(Self.beatSessions().filter { !trimmed.contains($0.id) })
    }

    /// The batch's trims: iCloud's, or the test's stand-in.
    private func trimBeatTrails(_ sessions: [BeatSession], monthsOld months: Int,
                                stillWanted: @escaping @MainActor () -> Bool) async -> [UUID: BeatTrimOutcome] {
        #if DEBUG
        if let trim = beatTrailsTrimForTesting { return await trim(sessions) }
        #endif
        return await cloud.trimBeatTrails(sessions, monthsOld: months, stillWanted: stillWanted)
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
        guard entitlements.proActive, !settings.awaitingUnlock,   // the defaults are not the owner's policy (ADR 0055)
              let months = settings.cloudRetention.autoMonths else { return }
        let defaults = UserDefaults.standard
        let lastSuccess = defaults.object(forKey: Self.cloudRetentionLastRunKey) as? Date
        let lastAttempt = defaults.object(forKey: Self.cloudRetentionLastAttemptKey) as? Date
        guard Self.autoPurgeDue(lastSuccess: lastSuccess, lastAttempt: lastAttempt,
                                now: Date()) else { return }
        // The attempt is stamped BEFORE the purge — a crash mid-purge must not hot-loop —
        // and success only on an honestly-clean result (R3-3 made `failed` trustworthy:
        // a walk that couldn't read every record now reports failure, so the retry it
        // earns actually happens on the shorter cadence).
        defaults.set(Date(), forKey: Self.cloudRetentionLastAttemptKey)
        let cutoff = CloudExfiltrator.purgeCutoff(monthsOld: months, now: Date())
        // The setting is asked again before every batch of deletions (item 169's codex-2): one changed while the pass
        // waits on iCloud stops what it has not sent, and the next pass follows the new one.
        let wanted: @MainActor () -> Bool = { [weak self] in self?.automaticRetentionWants(months: months) ?? false }
        let result = await cloud.purgeFullMedia(monthsOld: months, stillWanted: wanted)
        if !result.failed {
            defaults.set(Date(), forKey: Self.cloudRetentionLastRunKey)
        }
        guard wanted() else { return }
        await trimOldBeatTrails(olderThan: cutoff, monthsOld: months, stillWanted: wanted)   // its progress is per watch
    }

    /// Whether the owner's setting still asks the automatic clean-up for `months` (item 169's codex-2).
    func automaticRetentionWants(months: Int) -> Bool {
        settings.cloudRetention.autoMonths == months
    }
}
