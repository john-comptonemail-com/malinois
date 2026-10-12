//
//  EventStore.swift
//  Malinois
//
//  The local, offline-first record of tamper events. Metadata is persisted as a
//  single JSON file; full-resolution media lives as individual files alongside.
//  This is the fallback that guarantees evidence exists even with no network.
//

import Foundation
import OSLog
import Combine
import UIKit

@MainActor
final class EventStore: ObservableObject {

    @Published private(set) var events: [Event] = []

    /// True if the on-disk log existed but couldn't be read OR preserved at launch. While
    /// set, `persist()` refuses to write (so it can't clobber the un-backed-up file) —
    /// surfaced on Home so a silently non-persisting store can't go unnoticed (R-05).
    @Published private(set) var loadFailed = false

    /// True while the log's bytes couldn't be read because Data Protection still holds the key
    /// (the device locked, or an instant from unlocking), NOT because it's corrupt. A silent
    /// push can background-launch us before first unlock; renaming the still-encrypted —
    /// but perfectly healthy — file to a corrupt-backup there would strand real evidence
    /// (V-01). So we defer: block `persist()` (as `loadFailed` does) and try the load again at
    /// the unlock notice or when the app becomes active, whichever comes first. Cleared by a
    /// load that reads the file, or sets it aside once UIKit says the phone is unlocked
    /// (item 86 and its review, ADR 0016).
    private var awaitingUnlock = false

    /// True only when `load()` decoded the on-disk log THIS launch. Together with resolved
    /// attachment intents, this distinguishes leaks from evidence awaiting attachment.
    /// Gates the orphan sweep; deliberately left false on a first launch (no file) and
    /// on every failed/deferred load.
    private var loadedCleanly = false

    /// Whether the in-memory log is this launch's reading of the log on disk, with no load
    /// deferred or failed since: the one state in which a record missing from it is provably
    /// not on disk either. Item 52's follow-up 2 adds the log's own arm records to the
    /// heartbeat's list of watches only then, before count migration can remove arm rows;
    /// a log still locked after a restart, or one started fresh, reads as empty.
    var hasReadTheLog: Bool { loadedCleanly && !loadFailed && !awaitingUnlock }

    /// True after a RUNTIME persist failure (disk full, I/O error) until the next successful
    /// write (F6): "written to disk" is an async dispatch, and a failed write used to be
    /// log-only — the owner saw events in the UI that were never durably stored. Surfaced on
    /// Home beside `loadFailed`.
    @Published private(set) var persistDegraded = false
    /// The log could not be decoded and was set aside as a timestamped backup; a fresh log has
    /// started (item 73, review 2 R2.2). Cleared by the next clean load.
    @Published private(set) var logWasQuarantined = false
    /// A birth-journal append or full sync failed, so the crash-durability promise does not
    /// hold for recent events (item 73, review 1 R6). The full log write still lands them.
    @Published private(set) var journalDegraded = false
    /// ioQueue-confined mirror, so the main-actor hop happens only on state CHANGES.
    nonisolated(unsafe) private var persistFailedOnQueue = false
    private var protectedDataObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    /// Whether the device's protected data can be read now: UIKit's answer, injected so a test can
    /// answer the way UIKit does while the app is still being built (item 86; the engine has the
    /// same seam).
    private let protectedDataAvailable: @MainActor () -> Bool

    /// Independent count budgets: routine status history must not crowd out incidents,
    /// and a stream of incidents must not erase the separate status history (ADR 0035).
    static let maxIncidentEvents = 500
    static let maxAuditEvents = 100
    /// Combined bound, requested per record type from iCloud. Neither pool borrows
    /// unused capacity from the other; media remains subject to its separate byte cap.
    static let maxEvents = maxIncidentEvents + maxAuditEvents

    /// Media-size cap. With video the default, 500 clips could be ~15 GB, so the
    /// oldest events' *media* is dropped past this budget (the log entries — thumbnail
    /// + metadata — are kept, so the forensic record survives; only the heavy files go).
    nonisolated static let maxMediaBytes: Int64 = 2_000_000_000   // ~2 GB

    /// Data-Protection level for evidence at rest: encrypted while the device is
    /// locked, unless the file is currently open (so an in-flight upload/read
    /// isn't interrupted). Stronger than the container default.
    nonisolated private let writeProtection: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]

    private let fileManager = FileManager.default
    /// Serial queue so background writes never race or land out of order. Also the
    /// queue that `store(_:ext:)` uses to keep all media I/O off the main actor.
    nonisolated private let ioQueue = DispatchQueue(label: "com.malinois.eventstore.io", qos: .utility)

    // Directory URLs are computed with FileManager (thread-safe) and no actor
    // state, so the resolvers are `nonisolated static` — usable from `ioQueue`.

    /// Whether any prior local evidence survives, including journal, media and attachment
    /// intents when the primary log is missing. Empty directories and freshly generated
    /// seen/restore bookkeeping are not evidence. Inspection errors require recovery.
    /// Observation only: never creates, deletes or decrypts files.
    nonisolated static var containerHasPriorEvents: Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return KeychainService.hasPriorLocalEvidence(in: docs.appendingPathComponent("MalinoisEvents", isDirectory: true))
    }

    #if DEBUG
    /// Test-only (the isolation seam, 1.3 step 3): redirects the store's whole on-disk
    /// footprint — log, journal, media — to a directory the test owns. Set it before building
    /// an `EventStore`, clear it in tearDown. Each store reads it ONCE, when it is built (item
    /// 84): moving or clearing it later never redirects a store that already exists — one that
    /// outlived its test used to follow it into the next test's folder, or into the test host's
    /// real log. Compiled out of Release, so no shipped path can ever consult it.
    nonisolated(unsafe) static var rootOverrideForTesting: URL?
    /// Observes the crash window after committed media, before the caller can attach it.
    var attachmentPublishedForTesting: ((UUID, String) -> Void)?
    /// Drains queued disk writes before a test removes a crash-snapshot directory.
    func drainIOForTesting() { ioQueue.sync {} }
    #endif

    /// The folder this store keeps its log, journal and media in: ~/Documents/MalinoisEvents/,
    /// or the test override. Fixed when the store is built (item 84); only its CREATION stays
    /// lazy (`ensured`), as before — a launch on a locked device may not be able to create it
    /// yet, and the next access retries.
    nonisolated private let root: URL

    /// Where a store built now keeps its files. Creates nothing.
    nonisolated private static func resolvedRoot() -> URL {
        #if DEBUG
        if let override = rootOverrideForTesting { return override }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MalinoisEvents", isDirectory: true)
    }

    /// `dir`, created first if it is missing, at the evidence protection class — on every
    /// access, the way the folder resolvers always have.
    nonisolated private static func ensured(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        return dir
    }

    /// Directory for full-res stills / clips, under a store's folder.
    nonisolated private static func mediaDirectoryURL(in root: URL) -> URL {
        ensured(ensured(root).appendingPathComponent("Media", isDirectory: true))
    }

    private var rootURL: URL { Self.ensured(root) }
    private var metadataURL: URL { rootURL.appendingPathComponent("events.json") }
    var mediaDirectory: URL { Self.mediaDirectoryURL(in: root) }

    /// - Parameter protectedDataAvailable: whether the device's protected data can be read; UIKit's
    ///   answer unless a test injects one.
    init(protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }) {
        root = Self.resolvedRoot()
        self.protectedDataAvailable = protectedDataAvailable
        load()
        recoverFromJournal()
        enforceCountCapsAfterLoad()
        recoverMediaAttachments()
        sweepOrphanedMedia()
        establishSeenMark()   // item 81
    }

    // MARK: - Mutations

    func add(_ event: Event) {
        appendToJournal(event)        // durable FIRST — the record exists before anything else (ADR 0005)
        events.insert(event, at: 0)   // newest first
        let removedMedia = pruneToCountCap()   // cheap, in-memory — safe on the trigger path
        persist()
        // Media deletes enqueue AFTER the metadata write (34.H4): the queue is serial, so the
        // snapshot that no longer references these files reaches disk before the files go — a
        // kill in between leaves an orphan for the launch sweep, never a dangling reference.
        deleteMediaNames(removedMedia)
        scheduleByteCapPrune()        // byte cap statting runs OFF the trigger path (F-19)
    }

    /// Folds events mirrored from iCloud into the log, newest-first: a new id is added, and a
    /// copy of one already held replaces it only as `supersedes` allows.
    ///
    /// **First-hand evidence always wins.** An incoming copy never replaces an event captured
    /// on this device, whatever it claims; it is discarded outright, never merged field by
    /// field. This is the safety property the whole feature rests on: the log is the most
    /// critical structure in the app, first-hand evidence captured on this device outranks a
    /// claim arriving over the network, and an update path is exactly where a merge bug would
    /// be able to damage real evidence. A MIRROR (another device's event held here) may be
    /// replaced by a copy of itself that knows more, a later revision or an equal one with a
    /// grown count or a new failure reason, and keeps the media downloaded onto it
    /// (`inheritingLocalEnrichment`).
    ///
    /// Pure so it can be tested without CloudKit, which cannot run in the Simulator at all.
    nonisolated static func merged(local: [Event], incoming: [Event]) -> [Event] {
        var byID = [UUID: Event](minimumCapacity: local.count + incoming.count)
        var order: [UUID] = []
        for e in local where byID.updateValue(e, forKey: e.id) == nil { order.append(e.id) }
        for e in incoming {
            if let existing = byID[e.id] {
                guard supersedes(incoming: e, existing: existing) else { continue }
                byID[e.id] = inheritingLocalEnrichment(existing: existing, incoming: e)
            } else {
                order.append(e.id)
                byID[e.id] = e
            }
        }
        return order.compactMap { byID[$0] }.sorted { $0.startDate > $1.startDate }
    }

    /// Whether an incoming copy may replace one already held.
    ///
    /// **First-hand evidence is never replaced** — that is the rule the whole merge exists to
    /// protect, and it is unconditional. What used to be conflated with it is the case of a
    /// *mirror* meeting a later revision of itself: an id already present was rejected outright,
    /// so a copy fetched from another device was frozen at whatever arrived first. In practice
    /// that was always the sparse pre-capture "fact", because the subscription fires on record
    /// creation and the fast fact is what creates it — so the other device kept a thumbnail-less
    /// stub of every event, permanently, and no later fetch could repair it.
    ///
    /// A mirror may therefore be superseded by a strictly later revision of the same event, or
    /// by an equal revision that has learned more: a count that grew, or a capture's failure
    /// reason it did not have (item 94). A mirror still never displaces first-hand evidence,
    /// whatever its revision.
    nonisolated static func supersedes(incoming: Event, existing: Event) -> Bool {
        guard existing.isMirrored, incoming.isMirrored else { return false }
        let incomingRev = incoming.cloudRevision ?? 0
        let existingRev = existing.cloudRevision ?? 0
        if incomingRev > existingRev { return true }
        // Equal revisions can still differ in the fields whose values grow WITHIN a revision:
        // the coalesced flood count, and the wrong-PIN count (item 49 — a capture that failed
        // leaves the full push at the fact's revision, so the fact's count-less copy froze the
        // same way). Without this arm, a mirror that first fetched rev 2 at count 1 was FROZEN —
        // every later fetch carried the same revision, failed strictly-greater, and the
        // receiving device showed a plain row while the capturing device said "sustained ×14"
        // (found live 2026-08-30 on the build-25 pair; 34.H8's thumbnail freeze, resurfaced
        // through count progress). The capture's failure reason froze the same way (item 94:
        // a failed capture attaches no evidence, so its push keeps the fact's revision, and the
        // other phone never said why there was no photo). Monotonic on purpose: a count must
        // strictly grow or the reason newly appear, no count may shrink and the reason may not
        // go away, so replays and stale duplicates still lose.
        guard incomingRev == existingRev else { return false }
        let floods = (incoming: incoming.sustainedCount ?? 0, existing: existing.sustainedCount ?? 0)
        let attempts = (incoming: incoming.wrongPINCount ?? 0, existing: existing.wrongPINCount ?? 0)
        let reason = (incoming: incoming.captureFailure != nil, existing: existing.captureFailure != nil)
        guard floods.incoming >= floods.existing, attempts.incoming >= attempts.existing,
              reason.incoming || !reason.existing else { return false }
        return floods.incoming > floods.existing || attempts.incoming > attempts.existing
            || (reason.incoming && !reason.existing)
    }

    /// Pure (unit-tested): what a superseding mirror copy inherits from the copy it replaces.
    /// A cloud-decoded mirror carries `mediaFilename` nil BY CONSTRUCTION (the file is not on
    /// this device) — but the owner may have downloaded full evidence onto this mirror, and a
    /// wholesale replacement dropped that reference, stranding the file for the orphan sweep
    /// to delete (eighth-review M3). Locally-born enrichment survives; everything the cloud
    /// copy actually carries (counts, revision, metadata) wins as before.
    nonisolated static func inheritingLocalEnrichment(existing: Event, incoming: Event) -> Event {
        var out = incoming
        if out.mediaFilename == nil { out.mediaFilename = existing.mediaFilename }
        if out.secondaryMediaFilename == nil { out.secondaryMediaFilename = existing.secondaryMediaFilename }
        if out.thumbnailData == nil { out.thumbnailData = existing.thumbnailData }
        return out
    }

    /// How many events are still waiting to reach iCloud — the count behind the Event Log's
    /// sync banner.
    ///
    /// Arm/disarm records **are** counted. They were excluded until 1.1 on the grounds that
    /// they never sync, which stopped being true when BACKLOG 8 started pushing the audit
    /// trail. Leaving them out meant a disarm record that failed to upload raised nothing at
    /// all — and that is the failure that matters most, because the cloud copy is the whole
    /// reason a disarm record outlives an attacker deleting the app.
    nonisolated static func unsyncedCount(in events: [Event]) -> Int {
        events.filter { $0.cloudSyncState != .synced }.count
    }

    /// Reconciles the on-disk log with entries queued while the log was unreadable.
    ///
    /// Both sides are first-hand records from this device, so both survive; ids dedupe them and
    /// the result is newest-first like everything else.
    ///
    /// **This replaces a real data-loss path** (external review, 2026-08-26). The old code
    /// cleared `awaitingUnlock` *without reading the disk copy* whenever anything had been added
    /// while locked — its comment said it was keeping those entries "rather than clobber [them]
    /// with the disk copy", but the effect was the reverse: re-enabling persistence meant the
    /// next write put that small in-memory array over the entire historical log. Reachable in
    /// practice, and on the one path where it costs the most — a force-quit followed by a
    /// background launch before first unlock, which is exactly when the log matters.
    nonisolated static func reconciledAfterUnlock(disk: [Event], queued: [Event]) -> [Event] {
        merged(local: disk, incoming: queued)
    }

    /// Applies `merged` and persists. Returns how many events were inserted **or updated**,
    /// so callers can stay quiet when a fetch found nothing.
    ///
    /// Persistence is keyed on *content having changed*, never on the count having grown
    /// (34-review H8): a mirror superseded by a later revision of itself keeps the count
    /// identical, and the old `added > 0` guard skipped the persist — so the F5 enrichment
    /// repair existed only in memory and evaporated at the next launch.
    @discardableResult
    func merge(_ incoming: [Event]) -> Int {
        let before = events
        events = Self.merged(local: events, incoming: incoming)
        let changes = Self.mergeChanges(from: before, to: events)
        guard changes.inserted + changes.updated > 0 else { return 0 }
        Log.store.info("Merged \(changes.inserted, privacy: .public) new + \(changes.updated, privacy: .public) updated mirrored event(s) from iCloud")
        let removedMedia = pruneToCountCap()
        persist()
        deleteMediaNames(removedMedia)   // after the checkpoint (34.H4), as in add()
        scheduleByteCapPrune()
        return changes.inserted + changes.updated
    }

    // MARK: - New since the owner last looked (item 81)

    /// The file beside the log that holds the seen mark.
    static let seenFileName = "seen.json"

    /// The records the owner has seen: every record in the log when the Event Log was last
    /// opened or closed (it is PIN-gated, so opening it means the owner), plus the history a
    /// restore brought in (`mergeFromCloud(_:)`). Kept on this device only, beside the log. Nil
    /// until established: the first time the log can be read with this feature, whatever it
    /// already holds counts as seen (history, not news).
    @Published private(set) var seenIDs: Set<UUID>?

    /// The file beside the log that says a restore is owed (item 89, C1).
    static let restoreOwedFileName = "restore-owed.json"

    /// When this install first read an empty log (a reinstall, or a new iPhone on the account),
    /// while iCloud's records have yet to come down: a restore is owed. Until a launch pull
    /// reaches iCloud (`completeRestore()`), what a pull brings that is dated before this moment
    /// is history. Judged by the moment, not by an empty log (the 1.4 review, item 89, C1): a
    /// restore that waits past the first arm is still history, and a phone that only receives
    /// still counts its first mirror.
    private(set) var restoreOwedSince: Date?

    private var restoreOwedURL: URL { rootURL.appendingPathComponent(Self.restoreOwedFileName) }

    private struct RestoreOwed: Codable {
        let since: Date
    }

    private var seenURL: URL { rootURL.appendingPathComponent(Self.seenFileName) }

    /// Pure (unit-tested): how many records are new since the owner last looked: the records
    /// Home counts (everything but arm/disarm and the other state records) that are not in
    /// `seen`. Nothing is new until the mark exists.
    nonisolated static func newRecordCount(in events: [Event], seen: Set<UUID>?) -> Int {
        guard let seen else { return 0 }
        return events.lazy.filter { !$0.isStateChange && !seen.contains($0.id) }.count
    }

    /// What Home's Event Log button counts.
    var newRecordCount: Int { Self.newRecordCount(in: events, seen: seenIDs) }

    /// The owner has looked: everything in the log now is seen. Home's authenticated
    /// log navigation calls this before publishing an open or close transition.
    func markAllSeen() {
        saveSeenIDs(Set(events.map(\.id)))
    }

    /// A pull from iCloud: `merge(_:)`, and while a restore is owed, the records it inserted
    /// that are dated before the install count as seen: history, not news. Anything dated after
    /// it, and any record the log already held, keeps its own state.
    @discardableResult
    func mergeFromCloud(_ incoming: [Event]) -> Int {
        let before = Set(events.map(\.id))
        let changed = merge(incoming)
        if let since = restoreOwedSince, let seen = seenIDs {
            let inserted = events.filter { !before.contains($0.id) }
            let history = Self.historyIDs(inserted: inserted, installedAt: since)
            if !history.isEmpty {
                saveSeenIDs(seen.union(history).intersection(Set(events.map(\.id))))
            }
        }
        return changed
    }

    /// Pure (unit-tested; item 89, C1): which of the records a pull inserted are history: the
    /// ones dated before this install first read its log.
    nonisolated static func historyIDs(inserted: [Event], installedAt: Date) -> Set<UUID> {
        Set(inserted.lazy.filter { $0.startDate < installedAt }.map(\.id))
    }

    /// A launch pull reached iCloud and ran to the end: the restore owed since the install is
    /// done, and what later pulls bring is news.
    func completeRestore() {
        guard restoreOwedSince != nil else { return }
        restoreOwedSince = nil
        try? FileManager.default.removeItem(at: restoreOwedURL)
    }

    /// At launch and after the unlock reload: read the mark, or, the first time, adopt what the
    /// log holds. Waits while the log cannot be read (a locked launch), so the history it adopts
    /// is the real one.
    private func establishSeenMark() {
        guard seenIDs == nil, !awaitingUnlock else { return }
        if let data = try? Data(contentsOf: restoreOwedURL),
           let owed = try? JSONDecoder().decode(RestoreOwed.self, from: data) {
            restoreOwedSince = owed.since
        }
        if let data = try? Data(contentsOf: seenURL),
           let stored = try? JSONDecoder().decode([UUID].self, from: data) {
            seenIDs = Set(stored)
        } else {
            // The first launch with this feature, or a mark that cannot be read. An empty log
            // here is a new install: iCloud's records are still to come, and they are history.
            // Noted before the mark, so a stop between the two notes it again.
            if events.isEmpty, restoreOwedSince == nil { oweRestore(since: Date()) }
            markAllSeen()
        }
    }

    private func oweRestore(since date: Date) {
        restoreOwedSince = date
        guard let data = try? JSONEncoder().encode(RestoreOwed(since: date)) else { return }
        try? data.write(to: restoreOwedURL, options: writeProtection)
    }

    private func saveSeenIDs(_ ids: Set<UUID>) {
        seenIDs = ids
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? data.write(to: seenURL, options: writeProtection)
    }

    /// Pure (unit-tested): what a merge actually changed — events present now that weren't
    /// before, and events whose content differs from the copy previously held.
    nonisolated static func mergeChanges(from before: [Event],
                                         to after: [Event]) -> (inserted: Int, updated: Int) {
        let byID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var inserted = 0, updated = 0
        for e in after {
            guard let old = byID[e.id] else { inserted += 1; continue }
            if old != e { updated += 1 }
        }
        return (inserted, updated)
    }

    /// Enforces independent incident and status budgets. Class priority applies within
    /// a pool, never across it: old status entries cannot evict a recent incident.
    /// Returns media names for deletion after the caller has queued its metadata write.
    @discardableResult
    private func pruneToCountCap() -> [String] {
        // Preserve every legacy first-hand watch before a smaller status budget drops
        // its arm row. The shared registry's marker makes this a one-time operation.
        if hasReadTheLog { BeatSessionRegistry.seedIfNeeded(from: events) }
        let victims = Set(Self.countEvictionOrder(
            events: events.map { EvictionRow(id: $0.id,
                                             isFlood: $0.sustainedCount != nil,
                                             isSynced: $0.cloudSyncState == .synced,
                                             isAudit: $0.isStateChange || $0.interrupted == true,
                                             isMirrored: $0.isMirrored) },
            incidentCap: Self.maxIncidentEvents, auditCap: Self.maxAuditEvents))
        guard !victims.isEmpty else { return [] }
        var removedNames: [String] = []
        events.removeAll { e in
            guard victims.contains(e.id) else { return false }
            removedNames.append(contentsOf: [e.mediaFilename, e.secondaryMediaFilename].compactMap { $0 })
            return true
        }
        return removedNames
    }

    /// Migrates a readable legacy log without waiting for another incident. A sealed or
    /// unreadable log is never overwritten. Unlock reconciliation enforces the same budgets.
    private func enforceCountCapsAfterLoad() {
        guard hasReadTheLog else { return }
        let before = Set(events.map(\.id))
        let removedMedia = pruneToCountCap()
        let retired = before.subtracting(events.map(\.id))
        guard !retired.isEmpty else { return }
        // Existing journal lines may already match the loaded snapshot, so recovery did
        // not touch them. Retire trimmed rows only after their absence is saved durably.
        persist(alsoRetiring: retired)
        deleteMediaNames(removedMedia)
    }

    /// The count-retention facts for one row. Status includes arm/disarm, settings changes
    /// and interruption records; all other rows use the incident budget.
    struct EvictionRow {
        let id: UUID
        var isFlood = false
        var isSynced = false
        var isAudit = false
        var isMirrored = false
    }

    /// Pure retention policy, with newest-first input. Each pool first discards mirrored
    /// copies, including its newest mirror, so cloud input cannot displace owned evidence.
    /// Incidents then discard floods, synced evidence and finally pending evidence, oldest
    /// first within each class. Status entries discard the oldest owned status entries.
    /// The newest first-hand row in EACH pool is protected from eviction, including an
    /// in-flight flood anchor. A first-hand pool therefore retains at least one row even
    /// if a caller supplies a zero cap; production budgets are 500 incidents / 100 status.
    nonisolated static func countEvictionOrder(events: [EvictionRow], incidentCap: Int,
                                               auditCap: Int) -> [UUID] {
        func evict(_ rows: [EvictionRow], cap: Int, incidents: Bool) -> [UUID] {
            var overflow = rows.count - max(0, cap)
            guard overflow > 0 else { return [] }
            let protected = rows.first { !$0.isMirrored }?.id
            var result: [UUID] = []
            var taken = Set<UUID>()
            func pass(_ matches: (EvictionRow) -> Bool) {
                for row in rows.reversed() {
                    guard overflow > 0 else { return }
                    guard row.id != protected, !taken.contains(row.id), matches(row) else { continue }
                    result.append(row.id)
                    taken.insert(row.id)
                    overflow -= 1
                }
            }
            pass { $0.isMirrored }
            if incidents {
                pass { $0.isFlood }
                pass { $0.isSynced }
            }
            pass { _ in true }
            return result
        }
        return evict(events.filter { !$0.isAudit }, cap: incidentCap, incidents: true)
            + evict(events.filter(\.isAudit), cap: auditCap, incidents: false)
    }

    private var byteCapPruneRunning = false
    private var byteCapPruneRepeat = false

    /// Debounced trigger for the byte-cap prune. Kept OFF the trigger path (F-19): the
    /// prune stats up to ~1000 media files, which must not delay the sub-second fact push
    /// at capture time. Exactly one runner at a time; an add() that lands during a pass
    /// requests one more pass afterward, so nothing is missed and nothing runs twice (R-08).
    private func scheduleByteCapPrune() {
        if byteCapPruneRunning { byteCapPruneRepeat = true; return }
        byteCapPruneRunning = true
        Task { @MainActor in
            repeat {
                self.byteCapPruneRepeat = false
                await self.pruneMediaBytes()
            } while self.byteCapPruneRepeat
            self.byteCapPruneRunning = false
        }
    }

    /// Frees storage until on-disk media is under the byte budget, dropping flood media
    /// before genuine (the pure `mediaEvictionOrder`). The expensive part — statting
    /// every media file — runs off the main actor; only the decision + the in-memory
    /// mutation happen on it.
    private func pruneMediaBytes() async {
        let dir = mediaDirectory
        let snapshot = events.map { (id: $0.id,
                                     isFlood: $0.sustainedCount != nil,
                                     isSynced: $0.cloudSyncState == .synced,
                                     media: [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 }) }
        let budget = Self.maxMediaBytes
        let (evict, discarded) = await Task.detached { () -> (Set<UUID>, Set<UUID>) in
            func size(_ name: String) -> Int64 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                return (attrs?[.size] as? Int64) ?? 0
            }
            let sizes = snapshot.map { (id: $0.id, isFlood: $0.isFlood, isSynced: $0.isSynced,
                                        bytes: $0.media.reduce(Int64(0)) { $0 + size($1) }) }
            let order = EventStore.mediaEvictionOrder(sizes: sizes, budget: budget)
            return (order.evict, order.discardedBeforeUpload)
        }.value
        guard !evict.isEmpty else { return }
        if !discarded.isEmpty {
            Log.store.warning("Storage emergency: discarded \(discarded.count, privacy: .public) event(s)' media before it ever uploaded")
        }
        var names: [String] = []
        for idx in events.indices where evict.contains(events[idx].id) {
            if let n = events[idx].mediaFilename { names.append(n) }
            if let n = events[idx].secondaryMediaFilename { names.append(n) }
            events[idx].mediaFilename = nil
            events[idx].secondaryMediaFilename = nil
            // The badge and detail view must not read a later meta-only retry as everything
            // having made it (34.H5): record that this event's media was lost pre-upload.
            if discarded.contains(events[idx].id) { events[idx].mediaDiscarded = true }
        }
        persist()
        deleteMediaNames(names)   // after the checkpoint (34.H4): references drop before files
    }

    /// Pure (unit-tested): given events newest-first with their on-disk media sizes, which
    /// events' media to free to get under `budget` — and, separately, which of those had
    /// **never synced**, so the caller records that their evidence was discarded before it
    /// uploaded rather than letting a later meta-only retry read as fully synced (34.H5).
    ///
    /// Order of loss: coalesced flood media first (synthetic noise), then synced media
    /// oldest-first (locally it is a cache — the cloud holds it and it can be re-downloaded),
    /// and only in a genuine storage emergency the oldest still-pending media.
    nonisolated static func mediaEvictionOrder(
        sizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)],
        budget: Int64
    ) -> (evict: Set<UUID>, discardedBeforeUpload: Set<UUID>) {
        var total = sizes.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > budget else { return ([], []) }
        var evict: Set<UUID> = []
        func pass(_ matches: ((id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)) -> Bool) {
            for entry in sizes.reversed() {   // newest-first input → oldest-first here
                guard total > budget else { return }
                if matches(entry), entry.bytes > 0, !evict.contains(entry.id) {
                    evict.insert(entry.id)
                    total -= entry.bytes
                }
            }
        }
        pass { $0.isFlood }
        pass { $0.isSynced }
        pass { _ in true }     // storage emergency: pending media, oldest first
        // Flood media is deliberately expendable and synced media survives in the cloud —
        // only a pending genuine capture is an evidentiary loss worth recording.
        let discarded = Set(sizes.filter { evict.contains($0.id) && !$0.isSynced && !$0.isFlood }
                                 .map { $0.id })
        return (evict, discarded)
    }

    private func deleteMedia(for events: [Event]) {
        deleteMediaNames(events.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
    }

    /// Deletes media files on the ioQueue — off the main actor, consistent with the
    /// rest of the store's file I/O.
    private func deleteMediaNames(_ names: [String]) {
        guard !names.isEmpty else { return }
        ioQueue.async { [root] in
            let dir = Self.mediaDirectoryURL(in: root)
            for name in names {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Launch-time reconciliation of the Media directory against the log (39.R1.6 + 31.F14):
    /// deletes files no event references — true leaks: a cadence still whose record was
    /// evicted before its update landed (before the newest-event exemption), a byte-prune
    /// deletion that failed (`deleteMediaNames` is best-effort `try?`), a B3-era stray. They
    /// are invisible to the byte cap (it stats only referenced names) and to the UI, so they
    /// accumulate without bound.
    ///
    /// Refusals, because deleting evidence by mistake is the one unforgivable failure here:
    /// runs only when this launch decoded the log (`loadedCleanly` — an empty or partial
    /// in-memory log must never be treated as the truth about the disk), refuses wholesale
    /// while any `events.corrupt-*.json` backup exists (after a corruption, unreferenced
    /// media may be real evidence whose metadata was lost — the F-11 backup is the tombstone
    /// that says so), touches only files this store named (UUID basenames, the tmp sweeper's
    /// P3 lesson), and only past an age floor — a capture is stored moments before its event
    /// update lands, and the sweep must never race that window. Unresolved attachment
    /// intents additionally suspend sweeping until recovery/checkpoint or bounded aging. The rule itself is pure
    /// (`orphanedMediaNames`).
    private func sweepOrphanedMedia() {
        guard loadedCleanly, !loadFailed, !awaitingUnlock else { return }
        let inMemoryReferences = Set(events.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
        ioQueue.async { [self, storeRoot = root] in
            // Recovery may have changed memory while its atomic log replacement failed.
            // Only the snapshot actually on disk can authorize retirement. This read and
            // the checkpoint's sync run on the metadata writer's serial queue.
            let logURL = storeRoot.appendingPathComponent("events.json")
            guard let data = try? Data(contentsOf: logURL),
                  let persisted = try? JSONDecoder().decode([Event].self, from: data) else { return }
            checkpointAttachments(persistedSnapshot: persisted, cleanLoad: true, logURL: logURL,
                                  protectedReferences: inMemoryReferences)
            let referenced = inMemoryReferences.union(persisted.flatMap {
                [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 }
            })
            let pending = storeRoot.appendingPathComponent("MediaAttachments")
            if FileManager.default.fileExists(atPath: pending.path) {
                guard let files = attachmentFiles(), files.isEmpty else { return }
            }
            let fm = FileManager.default
            let root = Self.ensured(storeRoot)
            let rootNames = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            // Reap aged corruption tombstones FIRST (seventh review, #6): one backup used to
            // disable this sweep FOREVER. The refusal below stays deliberate — but time-bounded:
            // the owner keeps the newest three for a month, then the tombstones age out and
            // the sweep resumes. Names without a parseable stamp are never touched.
            let backupStamps: [(name: String, date: Date)] = rootNames
                .filter { $0.hasPrefix("events.corrupt-") }
                .compactMap { name in Self.corruptArtifactDate(name).map { (name, $0) } }
            let reaped = Set(Self.reapableCorruptArtifacts(stamps: backupStamps, now: Date()))
            for name in reaped { try? fm.removeItem(at: root.appendingPathComponent(name)) }
            if !reaped.isEmpty {
                Log.store.info("Reaped \(reaped.count, privacy: .public) aged corrupt-log backup(s)")
            }
            let corruptBackupPresent = rootNames
                .contains { $0.hasPrefix("events.corrupt-") && !reaped.contains($0) }
            let dir = Self.mediaDirectoryURL(in: storeRoot)
            let onDisk: [(name: String, modified: Date)] = ((try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []).compactMap { url in
                    guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                          let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                              .contentModificationDate
                    else { return nil }   // not ours, or unreadable — never sweep what we can't judge
                    return (url.lastPathComponent, modified)
                }
            let orphans = Self.orphanedMediaNames(onDisk: onDisk, referenced: referenced,
                                                  corruptBackupPresent: corruptBackupPresent, now: Date())
            guard !orphans.isEmpty else { return }
            for name in orphans { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            Log.store.info("Swept \(orphans.count, privacy: .public) orphaned media file(s) nothing referenced")
        }
    }

    /// Pure (unit-tested): which corrupt-artifact names may be reaped — anything older than
    /// `maxAge`, plus anything beyond the `keepNewest` most recent regardless of age. One
    /// corruption's tombstone used to stand forever, disabling the orphan sweep permanently
    /// and (for settings stashes) accumulating without bound (seventh review, #6). The
    /// deliberate safety refusals stay — bounded to a month instead of eternity. A
    /// future-dated stamp reads as young: kept, same clock-weirdness rule as the sweep's.
    nonisolated static func reapableCorruptArtifacts(stamps: [(name: String, date: Date)],
                                                     now: Date,
                                                     keepNewest: Int = 3,
                                                     maxAge: TimeInterval = 30 * 86_400) -> [String] {
        stamps.sorted { $0.date > $1.date }.enumerated().compactMap { idx, s in
            (idx >= keepNewest || now.timeIntervalSince(s.date) > maxAge) ? s.name : nil
        }
    }

    /// The unix timestamp embedded in a corrupt-artifact name ("…corrupt-<seconds>…"), if
    /// parseable — both the log backups and the settings stashes carry one by construction.
    nonisolated static func corruptArtifactDate(_ name: String) -> Date? {
        guard let range = name.range(of: "corrupt-") else { return nil }
        let digits = name[range.upperBound...].prefix { $0.isNumber }
        return Int(digits).map { Date(timeIntervalSince1970: Double($0)) }
    }

    /// Pure (unit-tested): which on-disk media names the sweep may delete — unreferenced AND
    /// past the age floor, and none at all while a corrupt-log backup exists. A future-dated
    /// modification time fails the age test, so clock weirdness reads as "too young to touch".
    nonisolated static func orphanedMediaNames(onDisk: [(name: String, modified: Date)],
                                               referenced: Set<String>,
                                               corruptBackupPresent: Bool,
                                               now: Date,
                                               minAge: TimeInterval = 86_400) -> [String] {
        guard !corruptBackupPresent else { return [] }
        return onDisk
            .filter { !referenced.contains($0.name) && now.timeIntervalSince($0.modified) >= minAge }
            .map(\.name)
    }

    // MARK: - Write-ahead journal (H4 / 31.F3; ADR 0005)

    /// One JSON-encoded event per line, appended synchronously at birth. Everything journal-
    /// shaped runs on the MAIN actor — append, recovery, checkpoint — so the file has exactly
    /// one writer and nothing races (the full metadata write stays on `ioQueue`; only its
    /// success SIGNAL hops back here). Single chokepoint on purpose: item 35's sealing hooks
    /// the journaled path.
    nonisolated private static func journalURL(in root: URL) -> URL {
        ensured(root).appendingPathComponent("events.journal")
    }
    /// This store's journal, in the folder it was built with (item 84).
    private var journalFile: URL { Self.journalURL(in: root) }
    /// Cheap gate so the per-persist checkpoint is a no-op while nothing is journaled.
    private var journalHasEntries = false
    /// One log line per process for a failing journal — it degrades to the old behavior
    /// (in-memory + async persist), and a locked launch fails EVERY append until unlock.
    private var journalFailureLogged = false
    #if DEBUG
    /// Journal full syncs that have landed this process — one per append, before `add`
    /// returns. The sync itself is invisible from a test; that it happens is the net (53).
    private(set) var journalFullSyncsForTesting = 0
    /// Full-log syncs that preceded a checkpoint's retirement of journal lines (53).
    private(set) var logFullSyncsForTesting = 0
    #endif

    /// Appends the event's birth line BEFORE the caller proceeds — the point (H4/31.F3):
    /// `persist()` is an async full-file write, so a kill between detection and that write
    /// used to erase the event entirely, and the free tier has no cloud copy to survive it.
    /// The append is followed, still before the caller proceeds, by a full sync through to the
    /// storage medium (`F_FULLFSYNC`): a completed write survives process death — the
    /// force-quit / Voice Control close / OOM kills this app actually meets — but sits in OS
    /// caches until the kernel flushes, an undocumented interval that can be tens of seconds,
    /// and a forced power-off inside that window lost what a kill could not. The sync costs
    /// the trigger path about 4 ms (measured on an iPhone Air, 2026-09-02, BACKLOG 53) — the
    /// price of "the record exists first" being true on the medium, not just in memory. Its
    /// cost is logged per event so it can be re-read on a device (ADR 0005, as amended).
    private func appendToJournal(_ event: Event) {
        guard let line = Self.journalLine(for: event) else { return }
        let url = journalFile
        var appended = false
        var sync: (synced: Bool, errno: Int32, elapsed: Duration)?
        if let handle = try? FileHandle(forWritingTo: url) {
            appended = ((try? handle.seekToEnd()) != nil) && ((try? handle.write(contentsOf: line)) != nil)
            if appended { sync = Self.fullSync(handle) } else { try? handle.close() }
        } else {
            appended = (try? line.write(to: url, options: [.completeFileProtectionUnlessOpen])) != nil
            // First line of a fresh file: the write created it; reopen for the barrier.
            if appended, let handle = try? FileHandle(forWritingTo: url) { sync = Self.fullSync(handle) }
        }
        if appended {
            journalHasEntries = true
            journalDegraded = !(sync?.synced ?? false)   // a full sync that failed is a promise that does not hold (item 73, R6)
            if let sync, sync.synced {
                #if DEBUG
                journalFullSyncsForTesting += 1
                #endif
                let ms = sync.elapsed / .milliseconds(1)
                Log.store.info("Journal full sync took \(ms, format: .fixed(precision: 2), privacy: .public) ms")
            } else {
                let failure = sync?.errno ?? -1
                Log.store.error("Journal full sync failed (errno \(failure, privacy: .public)) — the line survives a kill, not a power cut")
            }
        } else {
            journalDegraded = true   // surfaced on Home, not only in the console (item 73, review 1 R6)
            if !journalFailureLogged {
                journalFailureLogged = true
                Log.store.error("Journal append failed — birth records fall back to the async log write")
            }
        }
    }

    /// `F_FULLFSYNC` on an open handle — through the drive's cache to the medium — timed, with
    /// `errno` read on the spot. Closes the handle. Called on the main actor by the append
    /// (the trigger path's ~4 ms) and on `ioQueue` by the checkpoint.
    nonisolated private static func fullSync(_ handle: FileHandle) -> (synced: Bool, errno: Int32, elapsed: Duration) {
        var synced = false
        var failure: Int32 = 0
        let elapsed = ContinuousClock().measure {
            synced = fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1
            if !synced { failure = errno }
        }
        try? handle.close()
        return (synced, failure, elapsed)
    }

    /// Pure (unit-tested): one event, one line — compact JSON plus a trailing newline. The
    /// encoder never emits a raw newline inside compact JSON (strings escape it), which is
    /// the invariant the line-splitting rests on; pinned by test.
    nonisolated static func journalLine(for event: Event) -> Data? {
        guard var data = try? JSONEncoder().encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Pure (unit-tested): decodes journal lines tolerantly. A garbage line — or the torn
    /// final line of an append the kill cut mid-write, the file's whole reason to exist —
    /// is skipped, never fatal: one bad stitch must not void the rest of the net.
    nonisolated static func journaledEvents(in data: Data) -> [Event] {
        data.split(separator: 0x0A)
            .compactMap { try? JSONDecoder().decode(Event.self, from: Data($0)) }
    }

    /// Folds journal entries the log lost back in (at launch, and again after an unlock
    /// reload). `merged` folds by id, so entries the log already holds are no-ops and
    /// first-hand rows are never displaced. Runs even when the log came up fresh after a
    /// corruption quarantine — the journal tail is then genuine recovery. Lines are retired
    /// only when a later metadata write SUCCEEDS (`journalCheckpoint`), so a failed recovery
    /// persist never costs the net; a still-locked launch can't read the protected file and
    /// no-ops until the unlock reload.
    private func recoverFromJournal() {
        guard let data = try? Data(contentsOf: journalFile) else { return }
        journalHasEntries = !data.isEmpty
        let known = Set(events.map(\.id))
        let missing = Self.journaledEvents(in: data).filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return }
        events = Self.merged(local: events, incoming: missing)
        let beforePrune = Set(events.map(\.id))
        let removedMedia = pruneToCountCap()
        // A recovered line whose event the cap immediately re-evicts must still retire
        // (ext-review #3's second path): it used to survive every checkpoint, so each
        // launch resurrected it, evicted it again, and left the line — churn forever and
        // an unbounded journal. Retired only via the SUCCESS path of the persist that
        // durably records the absence; a failed persist keeps the line, the safe direction.
        // Include previously known rows removed by an upgrade, not only recovered
        // rows: their journal lines must not resurrect on another launch either.
        let retired = beforePrune.subtracting(events.map(\.id))
        persist(alsoRetiring: retired)
        deleteMediaNames(removedMedia)
        Log.store.warning("Recovered \(missing.count, privacy: .public) event(s) from the journal — their log write never landed")
    }

    /// The UNION of every successfully-persisted snapshot's ids in the current burst,
    /// waiting for one coalesced checkpoint pass; nil when none is scheduled. One pass per
    /// burst because a checkpoint per persist would be O(N²) busywork (each pass re-reads
    /// the whole journal; the 500-add retention tests made the storm visible as seconds of
    /// main-queue drain). The union — not the newest snapshot — because an id can be
    /// persisted and then EVICTED inside the same burst, and its line must still retire
    /// (ext-review #3): retiring a line is safe the moment ANY successful persist carried
    /// its event; retiring late is safe only while the line's event is merely redundant,
    /// not intentionally removed.
    private var pendingCheckpointIDs: Set<UUID>?

    /// Pure (unit-tested): how a new successful snapshot's ids join a pending checkpoint
    /// (ext-review #3, 2026-08-31). REPLACING lost ids across the debounce: persist-with-X
    /// succeeds → X is evicted inside the 50 ms window → persist-without-X succeeds and its
    /// smaller set superseded the first — X's birth line was never retired, and every
    /// relaunch "recovered" the intentionally evicted event (evicting another row to make
    /// room, then re-pruning X with its line STILL standing: churn forever, against media
    /// deleted long ago). UNION is safe by construction: an id enters this set only via a
    /// persist that SUCCEEDED, so its journal line is redundant either way — the event is
    /// in the log file, or it was deliberately removed after being safely on disk.
    nonisolated static func coalescedCheckpointIDs(pending: Set<UUID>?,
                                                   newlyPersisted: Set<UUID>) -> Set<UUID> {
        (pending ?? []).union(newlyPersisted)
    }

    /// Coalesces checkpoint requests: a burst of persist successes becomes one pass over
    /// the journal with the union of the burst's successfully-persisted ids, after a short
    /// debounce lets the burst land.
    private func scheduleJournalCheckpoint(persistedIDs: Set<UUID>) {
        let alreadyScheduled = pendingCheckpointIDs != nil
        pendingCheckpointIDs = Self.coalescedCheckpointIDs(pending: pendingCheckpointIDs,
                                                           newlyPersisted: persistedIDs)
        guard !alreadyScheduled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let ids = self.pendingCheckpointIDs {
                self.pendingCheckpointIDs = nil
                self.journalCheckpoint(persistedIDs: ids)
            }
        }
    }

    /// A metadata write reached the OS: every journal line whose event is in that snapshot is
    /// redundant — but only once the full log is on the *medium*, or a power cut between the
    /// line's retirement and the kernel's flush of the log could lose the event through the
    /// retirement itself (BACKLOG 53). So the pass first full-syncs the log on `ioQueue` —
    /// one flush per checkpoint pass, which is one per burst — and retires on return.
    private func journalCheckpoint(persistedIDs: Set<UUID>) {
        guard journalHasEntries else { return }
        let logURL = metadataURL
        ioQueue.async { [weak self] in
            var synced = false
            if let handle = try? FileHandle(forWritingTo: logURL) {
                let result = Self.fullSync(handle)
                synced = result.synced
                let ms = result.elapsed / .milliseconds(1)
                if synced {
                    Log.store.info("Full log sync landed in \(ms, format: .fixed(precision: 2), privacy: .public) ms before retiring journal lines")
                } else {
                    Log.store.error("Full log sync failed (errno \(result.errno, privacy: .public)) — journal lines are kept")
                }
            } else {
                Log.store.error("Full log sync could not open the log — journal lines are kept")
            }
            // A sync that did not land keeps the lines: the journal stays the net (the same
            // safe direction as a failed persist). They retire on the next successful pass.
            guard synced else { return }
            Task { @MainActor in
                #if DEBUG
                self?.logFullSyncsForTesting += 1
                #endif
                self?.retireJournalLines(persistedIDs: persistedIDs)
            }
        }
    }

    /// Rewrites the journal without the retired lines (usually: removes it). Entries born
    /// after the snapshot was taken keep their lines, so a mid-persist `add` loses nothing; a
    /// rewrite also sheds any torn tail, self-healing the file.
    private func retireJournalLines(persistedIDs: Set<UUID>) {
        guard journalHasEntries else { return }
        let url = journalFile
        guard let data = try? Data(contentsOf: url) else { return }
        let survivors = Self.journaledEvents(in: data).filter { !persistedIDs.contains($0.id) }
        if survivors.isEmpty {
            try? FileManager.default.removeItem(at: url)
            journalHasEntries = false
        } else {
            var out = Data()
            for event in survivors { if let line = Self.journalLine(for: event) { out.append(line) } }
            try? out.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    func update(_ event: Event, persistNow: Bool = true) {
        guard let idx = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[idx] = Self.preservingMonotonicFields(current: events[idx], incoming: event)
        if persistNow { persist() }
    }

    /// Pure (unit-tested): a whole-value update may never walk back fields that only move
    /// forward. Callers hold value copies of an event across async gaps — `respond()` holds
    /// one across the whole capture — and anything written to the STORED copy meanwhile
    /// (owner attribution at disarm, a sync state advanced by a completed push) was silently
    /// erased when the stale copy was written back (sixth-review F2). Attribution is
    /// monotonic at `true`; sync state reuses the exact `setSyncState` rule this write-back
    /// used to bypass.
    nonisolated static func preservingMonotonicFields(current: Event, incoming: Event) -> Event {
        var out = incoming
        if current.ownerAttributed == true { out.ownerAttributed = true }
        if !mayTransitionSyncState(from: current.cloudSyncState, to: incoming.cloudSyncState) {
            out.cloudSyncState = current.cloudSyncState
        }
        return out
    }

    /// Flush the current in-memory log to disk. Used by callers that batched updates with
    /// `persistNow: false` (the flood coalescer, F2) and now need the final state durable.
    func flush() { persist() }

    func setSyncState(_ state: CloudSyncState, for id: UUID) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        // Monotonic at synced (34.H9): several retry paths can race one event — the fast
        // fact, the full upload, reconnect, foreground and log-open retries — and a LATE
        // duplicate's failure must not walk an already-synced event back to pending or
        // local-only. The record is on the server; a red badge would be false, and the
        // observed-failure escalation (ADR 0001) must never fire off a duplicate's loss.
        guard Self.mayTransitionSyncState(from: events[idx].cloudSyncState, to: state) else { return }
        events[idx].cloudSyncState = state
        persist()
    }

    /// Pure (unit-tested): `.synced` is terminal except to itself.
    nonisolated static func mayTransitionSyncState(from: CloudSyncState, to: CloudSyncState) -> Bool {
        from != .synced || to == .synced
    }

    /// Reopens one `.synced` event for upload (item 65, finding 3): the one bounded retry
    /// (item 54) attaches media to a record that was already `.synced` WITHOUT any — its meta had
    /// landed and there was nothing else to send — so the record now carries something the cloud
    /// copy lacks, and a failed upload of it must be retried like any other. The monotonic guard
    /// would refuse the walk back; this is the second sanctioned path around it, beside
    /// `requeueAllForReupload`, for the same reason: "synced" has stopped being true.
    func reopenForReupload(_ id: UUID) {
        guard let idx = events.firstIndex(where: { $0.id == id }),
              events[idx].cloudSyncState == .synced else { return }
        events[idx].cloudSyncState = .pending
        persist()
    }

    /// Requeues every synced event for re-upload after an iCloud encrypted-data reset
    /// (34.H13): Apple purged the cloud copies, so "synced" is no longer true of any of
    /// them. This is the one sanctioned path around the monotonic sync-state guard — the
    /// guard exists so a late duplicate's FAILURE can't walk a synced event back; this is
    /// the opposite case, a deliberate global truth-restoration. Returns how many changed.
    @discardableResult
    func requeueAllForReupload() -> Int {
        let result = Self.requeuedForReupload(events)
        guard result.changed > 0 else { return 0 }
        events = result.events
        persist()
        return result.changed
    }

    /// Pure (unit-tested): the log with every synced FIRST-HAND event returned to pending.
    /// Local-only and already-pending events are untouched — they are in the retry set
    /// regardless. Mirrors are excluded (eighth-review M4): the capturing device owns its
    /// evidence's re-upload, and re-publishing a mirror stamped this device's name — under
    /// `.allKeys`, racing the capturing device's richer re-upload — falsified provenance
    /// and could regress the cloud copy. The accepted residue: if the capturing device is
    /// gone, its mirrored copies stay local after an encrypted-data reset.
    nonisolated static func requeuedForReupload(_ events: [Event]) -> (events: [Event], changed: Int) {
        var changed = 0
        let out = events.map { e -> Event in
            guard e.cloudSyncState == .synced, !e.isMirrored else { return e }
            var copy = e
            copy.cloudSyncState = .pending
            changed += 1
            return copy
        }
        return (out, changed)
    }

    /// Flags events (captured during disarm PIN entry) as the owner's own handling,
    /// once a correct PIN confirmed it. The record is kept — the log stays append-only —
    /// just labelled so it doesn't read as a tamper.
    func markOwnerAttributed(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for idx in events.indices where ids.contains(events[idx].id) {
            events[idx].ownerAttributed = true
            changed = true
        }
        if changed { persist() }
    }

    func mediaURL(for event: Event) -> URL? {
        guard let name = event.mediaFilename else { return nil }
        return mediaDirectory.appendingPathComponent(name)
    }

    func secondaryMediaURL(for event: Event) -> URL? {
        guard let name = event.secondaryMediaFilename else { return nil }
        return mediaDirectory.appendingPathComponent(name)
    }

    /// A captured payload to persist. Stills arrive as in-memory JPEG data; clips
    /// arrive as a file already on disk (their temp URL) and are *moved*, never
    /// read into memory — so a 120 s until-clear clip never lands in RAM or on the
    /// main thread.
    enum MediaSource: Sendable {
        case still(Data)
        case clip(URL)
    }

    /// Result of a successful `store`: the on-disk filename plus a derived thumbnail.
    struct StoredMedia: Sendable {
        let filename: String
        let thumbnail: Data?
    }

    /// A first-hand capture's destination, recorded before its media is published. No event
    /// is created from this file: recovery requires an existing log/journal identity.
    private struct AttachmentIntent: Codable, Sendable {
        var version = 1
        let eventID: UUID
        let startDate: Date
        let secondary: Bool
        let camera: String
        let duration: Double?
        var captureIssue: String?
        let filename: String
        var byteCount: Int64 = 0
        var thumbnail: Data?
    }

    nonisolated private var attachmentDirectory: URL { root.appendingPathComponent("MediaAttachments") }
    nonisolated private static let attachmentLimit = 1_200
    nonisolated private static let intentByteLimit: Int64 = 512_000

    /// Stores first-hand evidence with an explicit recovery destination. Pass the logged
    /// event and the capture's physical camera, slot and (for clips) duration. A protected,
    /// synced intent precedes publication of a completely saved file. Relaunch can attach
    /// that file even if the caller's update never runs. Unknown, mirrored, occupied or
    /// mismatched targets fail without consuming the source. Downloads keep using the
    /// context-free overload: their placement must be decided after awaiting the download.
    /// Retained staging payloads plus the incoming payload must fit the media byte cap;
    /// an overfull or unreadable staging area refuses admission before consuming the source.
    /// Returns nil on any storage failure. This does not claim power-cut atomicity across
    /// directory renames; recovery validates both the intent and the completed media.
    func store(_ source: MediaSource, ext: String, attachingTo event: Event,
               secondary: Bool = false, camera: String, duration: Double? = nil,
               captureIssue: String? = nil) async -> StoredMedia? {
        guard !loadFailed, !awaitingUnlock,
              let current = events.first(where: { $0.id == event.id }), current.startDate == event.startDate,
              camera == "front" || camera == "rear",
              duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { return nil }
        switch source {
        case .still: guard ext == "jpg", duration == nil else { return nil }
        case .clip: guard ext == "mov" else { return nil }
        }
        let intent = AttachmentIntent(eventID: event.id, startDate: event.startDate, secondary: secondary,
                                      camera: camera, duration: duration, captureIssue: captureIssue, filename: UUID().uuidString + "." + ext)
        guard Self.accepts(intent, for: current) else { return nil }
        let stored: StoredMedia? = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.storeRecoverably(source, intent: intent))
            }
        }
        #if DEBUG
        if let stored { attachmentPublishedForTesting?(event.id, stored.filename) }
        #endif
        // Publication suspends the caller. A deletion/discard or another attachment during
        // that interval must not be undone by the late result. The durable intent remains
        // subject to these same checks at recovery; the saved bytes are not destroyed here.
        guard let latest = events.first(where: { $0.id == event.id }), Self.accepts(intent, for: latest) else { return nil }
        return stored
    }

    nonisolated private static func accepts(_ intent: AttachmentIntent, for event: Event) -> Bool {
        guard event.id == intent.eventID, event.startDate == intent.startDate,
              !event.isMirrored, !event.isStateChange, event.mediaDiscarded != true else { return false }
        let filename = intent.secondary ? event.secondaryMediaFilename : event.mediaFilename
        let camera = intent.secondary ? event.secondaryCamera : event.primaryCamera
        let otherFilename = intent.secondary ? event.mediaFilename : event.secondaryMediaFilename
        let otherCamera = intent.secondary ? event.primaryCamera : event.secondaryCamera
        return filename == nil && (camera == nil || camera == intent.camera)
            && (otherFilename == nil || otherCamera != intent.camera)
    }

    /// Reject links (including multiply linked files), directories and unexpectedly large
    /// manifests before reading them. Parent directories are checked separately.
    nonisolated private static func regularSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    nonisolated private static func realDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory
    }

    /// Bounded capacity for pending slots and interrupted staging files. Enumeration and decoding are bounded;
    /// an overfull or unreadable directory refuses new work and orphan deletion.
    nonisolated private func attachmentFiles() -> [URL]? {
        guard Self.realDirectory(root), Self.realDirectory(attachmentDirectory) else { return nil }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: attachmentDirectory,
            includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard files.count < Self.attachmentLimit else { return nil }
            files.append(url)
        }
        return failed ? nil : files
    }

    nonisolated private func readIntent(_ url: URL) -> AttachmentIntent? {
        guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              let size = Self.regularSize(url), size <= Self.intentByteLimit,
              let data = try? Data(contentsOf: url),
              let intent = try? JSONDecoder().decode(AttachmentIntent.self, from: data), intent.version == 1,
              intent.camera == "front" || intent.camera == "rear",
              intent.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              intent.startDate.timeIntervalSinceReferenceDate.isFinite,
              intent.byteCount > 0, intent.byteCount <= Self.maxMediaBytes,
              intent.filename == url.deletingPathExtension().lastPathComponent + ".jpg"
                || intent.filename == url.deletingPathExtension().lastPathComponent + ".mov",
              intent.filename.hasSuffix(".mov") || intent.duration == nil else { return nil }
        return intent
    }

    nonisolated private static func syncFile(_ url: URL) throws {
        let result = fullSync(try FileHandle(forWritingTo: url))
        guard result.synced else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Serial-queue admission for staging bytes, separate from pruning committed media.
    /// Count logical file lengths (including sparse files), never allocated blocks. Unknown
    /// sizes, unreadable files and links fail closed; subtracting from the remaining budget
    /// avoids overflow. Refusal neither deletes evidence nor moves the incoming source.
    nonisolated private static func admitsStaging(incomingBytes: Int64, files: [URL]) -> Bool {
        guard incomingBytes > 0, incomingBytes <= maxMediaBytes else { return false }
        var remaining = maxMediaBytes
        for url in files where url.pathExtension == "pending" {
            guard let bytes = regularSize(url), bytes >= 0, bytes <= remaining,
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            do { try handle.close() } catch { return false }
            remaining -= bytes
        }
        return incomingBytes <= remaining
    }

    /// Runs only on ioQueue. The final rename is the commit marker: a kill before it leaves
    /// only the original temporary source or staging bytes, never attachable evidence.
    nonisolated private func storeRecoverably(_ source: MediaSource, intent initial: AttachmentIntent) -> StoredMedia? {
        let fm = FileManager.default
        guard Self.realDirectory(root) else { return nil }
        let media = Self.mediaDirectoryURL(in: root)
        let directory = Self.ensured(attachmentDirectory)
        guard Self.realDirectory(root), Self.realDirectory(media), Self.realDirectory(directory),
              let files = attachmentFiles(), files.count <= Self.attachmentLimit - 2,
              !files.contains(where: {
                  guard let held = readIntent($0) else { return false }
                  return held.eventID == initial.eventID
                    && (held.secondary == initial.secondary || held.camera == initial.camera)
                    && Self.regularSize(media.appendingPathComponent(held.filename)) == held.byteCount
              }) else { return nil }
        var intent = initial
        let stem = String(intent.filename.dropLast(4))
        let manifest = directory.appendingPathComponent(stem + ".json")
        let staged = directory.appendingPathComponent(stem + ".pending")
        let destination = media.appendingPathComponent(intent.filename)
        do {
            switch source {
            case .still(let bytes): intent.byteCount = Int64(bytes.count)
            case .clip(let url):
                guard let size = Self.regularSize(url) else { return nil }
                intent.byteCount = size
            }
            guard Self.admitsStaging(incomingBytes: intent.byteCount, files: files) else { return nil }
            try JSONEncoder().encode(intent).write(to: manifest, options: writeProtection)
            try Self.syncFile(manifest)
            switch source {
            case .still(let bytes):
                try bytes.write(to: staged, options: writeProtection)
                intent.thumbnail = CameraController.thumbnail(from: bytes)
            case .clip(let url):
                // AVFoundation needs the movie's recognized suffix. The staging name is
                // intentionally .pending (not published evidence), which it cannot decode.
                // Read the finished source before moving it; publication and protection
                // still complete before this thumbnail or filename reaches the caller.
                intent.thumbnail = CameraController.videoThumbnail(from: url)
                try fm.moveItem(at: url, to: staged)
                try Self.applyClipProtectionOrRemove(at: staged)
            }
            guard Self.regularSize(staged) == intent.byteCount else { throw CocoaError(.fileReadCorruptFile) }
            try Self.syncFile(staged)
            let data = try JSONEncoder().encode(intent)
            guard data.count <= Self.intentByteLimit else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: manifest, options: writeProtection)
            try Self.syncFile(manifest)
            try fm.moveItem(at: staged, to: destination)
            return StoredMedia(filename: intent.filename, thumbnail: intent.thumbnail)
        } catch {
            // Keep the intent and any fully protected staging bytes for conservative cleanup.
            // No final filename was published, so recovery cannot mistake a partial write for success.
            Log.store.error("Recoverable media save failed: \(Log.ref(error), privacy: .public)")
            return nil
        }
    }

    /// Reads only bounded local intents after log/journal recovery, also on deferred unlock.
    /// Applies enrichment to the current event, never replaces its other metadata. Conflicts,
    /// unknown identities, missing/partial media and corrupt intents remain unattached.
    private func recoverMediaAttachments() {
        guard !loadFailed, !awaitingUnlock else { return }
        let recovered: [AttachmentIntent] = ioQueue.sync {
            guard Self.realDirectory(root), Self.realDirectory(root.appendingPathComponent("Media")),
                  let files = attachmentFiles() else { return [] }
            return files.compactMap { url in
                guard let intent = readIntent(url),
                      Self.regularSize(root.appendingPathComponent("Media").appendingPathComponent(intent.filename))
                        == intent.byteCount else { return nil }
                return intent
            }
        }
        // Two conflicting intents for one slot are ambiguous; directory order is never a decision.
        let grouped = Dictionary(grouping: recovered) { "\($0.eventID)-\($0.secondary)" }
        let cameras = Dictionary(grouping: recovered) { "\($0.eventID)-\($0.camera)" }
        var changed = false
        for intents in grouped.values where intents.count == 1 {
            let intent = intents[0]
            guard cameras["\(intent.eventID)-\(intent.camera)"]?.count == 1 else { continue }
            guard let idx = events.firstIndex(where: { $0.id == intent.eventID }),
                  Self.accepts(intent, for: events[idx]) else { continue }
            if let issue = intent.captureIssue, CaptureFailureReason(rawValue: issue) != nil {
                var issues = events[idx].captureFailuresByCamera ?? [:]
                issues[intent.camera] = issue
                events[idx].captureFailuresByCamera = issues
            }
            if intent.secondary {
                events[idx].secondaryMediaFilename = intent.filename
                events[idx].secondaryCamera = intent.camera
                events[idx].secondaryDuration = intent.duration
            } else {
                events[idx].mediaFilename = intent.filename
                events[idx].primaryCamera = intent.camera
                events[idx].primaryDuration = intent.duration
                if let thumbnail = intent.thumbnail { events[idx].thumbnailData = thumbnail }
            }
            if events[idx].cloudSyncState == .synced { events[idx].cloudSyncState = .pending }
            changed = true
        }
        if changed { persist() }
    }

    /// Retires only intents whose matching attachment is in a fully synced snapshot. The
    /// caller must supply a just-written or freshly disk-decoded snapshot on ioQueue, with
    /// no intervening metadata writes. A failed write/sync keeps the recovery record. On a clean launch, abandoned entries
    /// age out after 30 days, with at most 1,200 directory entries examined per pass; while
    /// any remain, the ordinary 24-hour media sweep stays suspended. Corrupt/locked logs
    /// never authorize this cleanup. Only UUID-named regular files in our own folder go.
    nonisolated private func checkpointAttachments(persistedSnapshot: [Event], cleanLoad: Bool, logURL: URL,
                                                   protectedReferences: Set<String> = []) {
        guard let files = attachmentFiles(), !files.isEmpty else { return }
        do { try Self.syncFile(logURL) } catch { return }
        let byID = Dictionary(persistedSnapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for url in files {
            let intent = readIntent(url)
            let event = intent.flatMap { byID[$0.eventID] }
            let attached = intent.map { item in
                guard let event, event.startDate == item.startDate else { return false }
                return (item.secondary ? event.secondaryMediaFilename : event.mediaFilename) == item.filename
            } ?? false
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            let expired = cleanLoad && modified.map { Date().timeIntervalSince($0) > 30 * 86_400 } == true
            // A committed file still awaiting an eligible attachment is never aged out.
            let recoverable = intent.flatMap { item in
                event.map { Self.accepts(item, for: $0)
                    && Self.regularSize(root.appendingPathComponent("Media").appendingPathComponent(item.filename))
                        == item.byteCount }
            } ?? false
            // Journal-only recovery may not yet exist in the durable log. Memory can
            // veto aging, but can never authorize successful attachment retirement.
            let protectedInMemory = intent.map { protectedReferences.contains($0.filename) } ?? false
            guard attached || (expired && !recoverable && !protectedInMemory),
                  ["json", "pending"].contains(url.pathExtension),
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let size = Self.regularSize(url) else { continue }
            // An I/O/Data Protection failure is not corruption. Keep unreadable intents;
            // an oversized manifest is already known invalid without allocating its bytes.
            if !attached, url.pathExtension == "json", size <= Self.intentByteLimit,
               (try? Data(contentsOf: url)) == nil { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Persists a captured payload and derives its thumbnail entirely OFF the main
    /// actor. Both are heavy for clips (tens of MB / a video-frame decode), and
    /// doing them on `@MainActor` hitched the UI at exactly the moment the app
    /// needs to stay responsive. Returns nil if the write/move fails, so callers
    /// never reference media that isn't there.
    nonisolated func store(_ source: MediaSource, ext: String) async -> StoredMedia? {
        await withCheckedContinuation { cont in
            ioQueue.async {
                let name = UUID().uuidString + "." + ext
                let dest = Self.mediaDirectoryURL(in: self.root).appendingPathComponent(name)
                do {
                    let thumbnail: Data?
                    switch source {
                    case .still(let data):
                        try data.write(to: dest, options: self.writeProtection)
                        thumbnail = CameraController.thumbnail(from: data)
                    case .clip(let url):
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try? FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.moveItem(at: url, to: dest)
                        // `moveItem` carries the temp file's protection, not the media
                        // directory's, so this has to be re-applied — and it is part of storing
                        // the clip, not a nicety after it. It used to be `try?`, which reported
                        // success for a clip left at weaker protection than every still beside
                        // it: readable on a locked device, in the one file most likely to show a
                        // face. Failing here is honest — the capture is reported as not stored,
                        // which is what the badge and the retry path already know how to handle.
                        try Self.applyClipProtectionOrRemove(at: dest)
                        thumbnail = CameraController.videoThumbnail(from: dest)
                    }
                    cont.resume(returning: StoredMedia(filename: name, thumbnail: thumbnail))
                } catch {
                    Log.store.error("Failed to store media \(name, privacy: .public): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Applies evidence-grade protection to a just-moved clip, as one transaction with the
    /// move: if the attribute cannot be applied, the file is REMOVED before the error is
    /// rethrown (34-review B3).
    ///
    /// F15 made this failure a real failure instead of a `try?` — correct — but forgot the
    /// file it leaves behind: the caller reports "not stored", so the event carries no
    /// filename, yet the moved clip stayed on disk at the temp file's weaker protection —
    /// readable on a locked device, invisible to the byte cap, and outside the tmp sweeper's
    /// reach. An untracked under-protected clip is the exact artefact the attribute exists
    /// to prevent, so failing must not manufacture one. `apply` is injectable only so the
    /// failure path is testable — `setAttributes` cannot be made to fail on demand in a test.
    nonisolated static func applyClipProtectionOrRemove(
        at dest: URL,
        applying apply: (URL) throws -> Void = { url in
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path)
        }
    ) throws {
        do { try apply(dest) }
        catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    // MARK: - Persistence

    /// Encodes and writes the metadata off the main actor (the array — thumbnails
    /// inline — can be large). A snapshot + serial queue keep writes ordered and
    /// race-free. `alsoRetiring` joins the checkpoint set on SUCCESS only: ids whose
    /// journal lines this snapshot makes obsolete even though their events are NOT in it
    /// (recovered-then-evicted, ext-review #3's second path) — once the file that omits
    /// them is durably down, their absence is deliberate, and their lines must stop
    /// resurrecting them at every launch. On failure nothing retires, so the journal
    /// still recovers them — the safe direction.
    private func persist(alsoRetiring: Set<UUID> = []) {
        guard !loadFailed, !awaitingUnlock else { return }   // never overwrite an un-backed-up (R-05) or still-encrypted (V-01) log
        let snapshot = events
        let url = metadataURL
        let options = writeProtection
        let cleanLoad = loadedCleanly
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: options)
                self.checkpointAttachments(persistedSnapshot: snapshot, cleanLoad: cleanLoad, logURL: url)
                if self.persistFailedOnQueue {
                    self.persistFailedOnQueue = false
                    Task { @MainActor in self.persistDegraded = false }
                }
                // This snapshot is durably on disk — its events' journal lines are now
                // redundant and can be retired (on the main actor, the journal's one writer).
                let persistedIDs = Set(snapshot.map(\.id)).union(alsoRetiring)
                Task { @MainActor in self.scheduleJournalCheckpoint(persistedIDs: persistedIDs) }
            } catch {
                Log.store.fault("Failed to persist event metadata: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                if !self.persistFailedOnQueue {
                    self.persistFailedOnQueue = true
                    Task { @MainActor in self.persistDegraded = true }
                }
            }
        }
    }

    /// Reads the log from disk, telling a SEALED file from a DAMAGED one (V-01, item 86 and its
    /// review):
    ///  - bytes that read and decode: the log;
    ///  - bytes that read but do not decode: damaged, whatever the lock state (a sealed file cannot
    ///    be read at all), so it is set aside at once;
    ///  - bytes that cannot be read: sealed while UIKit says the phone is locked, so the load
    ///    waits; set aside only once UIKit says the phone is unlocked and they still cannot be
    ///    read. UIKit's "locked" is not trusted to mean damaged (inside `MalinoisApp.init` it
    ///    reads an unlocked phone as locked, ADR 0016), and the app being on screen is not
    ///    trusted to mean unlocked (a lock-screen notification tap can make the app active an
    ///    instant before the keys arrive: KeychainService and RootView, found live 2026-08-30).
    private func load() {
        let url = metadataURL
        guard fileManager.fileExists(atPath: url.path) else { return }   // first launch — no file
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard protectedDataAvailable() else {
                // Sealed: a background push-launch before first unlock hits this on a HEALTHY
                // file, and renaming it — a metadata op that succeeds even while the content is
                // protected — would strand real evidence in a backup we never re-read (V-01).
                // Leave it untouched, block persist(), and try again at the unlock notice or
                // when the app becomes active.
                awaitingUnlock = true
                observeForDeferredLoad()
                Log.store.info("events.json unreadable while the device reads as locked; deferring load until unlock")
                return
            }
            // The phone is unlocked and the bytes still cannot be read: broken, not sealed.
            setAside(url)
            return
        }
        guard let decoded = try? JSONDecoder().decode([Event].self, from: data) else {
            setAside(url)   // readable but undecodable: damaged, whatever the lock state
            return
        }
        events = decoded
        awaitingUnlock = false            // a successful read clears any deferred state
        loadedCleanly = true              // the in-memory log is the truth about the disk
    }

    /// Sets a damaged or broken log aside as a timestamped backup and starts fresh (F-11).
    private func setAside(_ url: URL) {
        // The locked-file question is settled — a deferred load that lands here must clear its
        // flag whatever the quarantine outcome (32.R4): left set, `persist()` stayed refused for
        // the rest of the process, silently, with nothing on Home saying so. `loadFailed` alone
        // governs the un-backupable case, and that one IS surfaced.
        awaitingUnlock = false
        // Do NOT start empty and let the next persist()
        // silently overwrite it — that would destroy recoverable evidence. Preserve it as a
        // timestamped backup, then start fresh (F-11).
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        if (try? fileManager.moveItem(at: url, to: backup)) == nil {
            // Couldn't even preserve it — so refuse to overwrite it either (R-05).
            // persist() no-ops while this is set, and Home surfaces the frozen state.
            loadFailed = true
            Log.store.fault("events.json unreadable and un-backupable; persistence disabled to avoid data loss")
        } else {
            Log.store.error("events.json unreadable or corrupt; preserved as \(backup.lastPathComponent, privacy: .public)")
            logWasQuarantined = true   // Home says so; the backup is reaped after 30 days (item 73, review 2 R2.2)
        }
    }

    /// Registers the observers that try a deferred load again (V-01, ADR 0016): the unlock
    /// notice, or the app becoming active (where UIKit, asked again, answers for the running
    /// app). Idempotent while they are registered; a load deferred again registers anew.
    private func observeForDeferredLoad() {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endDeferredLoad() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endDeferredLoad() }
        }
    }

    /// The first of the two notices removes both observers and tries the load again; a load
    /// that still cannot read a sealed file registers them anew.
    private func endDeferredLoad() {
        guard let unlockToken = protectedDataObserver else { return }   // already ended
        NotificationCenter.default.removeObserver(unlockToken)
        if let activeToken = activeObserver { NotificationCenter.default.removeObserver(activeToken) }
        protectedDataObserver = nil
        activeObserver = nil
        reloadAfterUnlock()
    }

    private func reloadAfterUnlock() {
        guard awaitingUnlock else { return }
        // Whatever was added while the log was unreadable. The realistic case is an
        // interrupted-session record: a background launch before first unlock constructs the
        // engine, and `recoverInterruptedSessionIfNeeded` logs one during construction.
        let queued = events
        // Reads the disk copy and clears `awaitingUnlock`, or sets a damaged or broken file
        // aside and clears it too. A file still sealed (the app active an instant before the
        // keys arrive, or the device re-locked before an unlock notice was handled) leaves both
        // alone: persistence stays blocked, `queued` is still all we have, and the load waits
        // again.
        load()
        recoverFromJournal()   // the protected file is readable now too (ADR 0005)
        recoverMediaAttachments()
        establishSeenMark()    // item 81: the history is known now; what was queued stays new
        guard !queued.isEmpty else { enforceCountCapsAfterLoad(); return }
        events = Self.reconciledAfterUnlock(disk: events, queued: queued)
        let beforePrune = Set(events.map(\.id))
        let removedMedia = pruneToCountCap()
        persist(alsoRetiring: beforePrune.subtracting(events.map(\.id)))
        deleteMediaNames(removedMedia)   // after the checkpoint (34.H4)
        scheduleByteCapPrune()
        Log.store.info("Reconciled \(queued.count, privacy: .public) queued event(s) with the log on unlock")
    }
}

#if DEBUG
// MARK: - A seeded backlog for item 79's device legs (Debug builds only)

extension EventStore {
    /// Debug-only (item 79's device legs), pure (unit-tested): the backlog a long stretch in
    /// Airplane Mode leaves behind (the owner's, 2026-09-20) — arm/disarm audit records that never
    /// reached iCloud, alternating from "armed", one second apart, oldest first, the newest dated
    /// `endingAt`. First-hand records, not mirrors, so the pending sweep uploads them.
    nonisolated static func seededBacklog(count: Int, endingAt end: Date) -> [Event] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let at = end.addingTimeInterval(Double(i - (count - 1)))
            return Event(startDate: at, endDate: at, triggeredSensors: [],
                         cloudSyncState: .localOnly,
                         stateChange: i.isMultiple(of: 2) ? "armed" : "disarmed")
        }
    }

    /// Pure (unit-tested): how many seeded status records fit in the status pool. Free
    /// status slots first, then mirrored status copies; neither owned status history nor
    /// any incident is displaced for debug data.
    nonisolated static func seedRoom(requested: Int, current: Int, cap: Int, mirrored: Int) -> Int {
        max(0, min(requested, cap - current + max(0, mirrored)))
    }

    /// Debug-only: adds up to `count` seeded records and returns how many were added and how many
    /// mirrored copies the log dropped to make room. Oldest first, so the log stays newest-first.
    /// Starts no upload: the natural triggers do that (a reconnect, the foreground, opening the
    /// Event Log), and those are what the legs exercise.
    @discardableResult
    func seedUnsyncedBacklogForTesting(count: Int, now: Date = Date()) -> (added: Int, droppedCopies: Int) {
        let audits = events.filter { $0.isStateChange || $0.interrupted == true }
        let copiesBefore = audits.lazy.filter(\.isMirrored).count
        let room = Self.seedRoom(requested: count, current: audits.count, cap: Self.maxAuditEvents,
                                 mirrored: copiesBefore)
        for event in Self.seededBacklog(count: room, endingAt: now) { add(event) }
        let copiesAfter = events.lazy.filter {
            ($0.isStateChange || $0.interrupted == true) && $0.isMirrored
        }.count
        return (room, copiesBefore - copiesAfter)
    }
}
#endif
