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

    /// True while the log couldn't be read because the device hasn't been unlocked since
    /// boot (Data Protection keeps the file encrypted), NOT because it's corrupt. A silent
    /// push can background-launch us before first unlock; renaming the still-encrypted —
    /// but perfectly healthy — file to a corrupt-backup there would strand real evidence
    /// (V-01). So we defer: block `persist()` (as `loadFailed` does) and retry the load the
    /// moment the device unlocks. Cleared by a successful reload.
    private var awaitingUnlock = false

    /// True only when `load()` decoded the on-disk log THIS launch — the one state in which
    /// an unreferenced media file is provably a leak rather than evidence whose metadata was
    /// lost. Gates the orphan sweep; deliberately left false on a first launch (no file) and
    /// on every failed/deferred load.
    private var loadedCleanly = false

    /// True after a RUNTIME persist failure (disk full, I/O error) until the next successful
    /// write (F6): "written to disk" is an async dispatch, and a failed write used to be
    /// log-only — the owner saw events in the UI that were never durably stored. Surfaced on
    /// Home beside `loadFailed`.
    @Published private(set) var persistDegraded = false
    /// ioQueue-confined mirror, so the main-actor hop happens only on state CHANGES.
    nonisolated(unsafe) private var persistFailedOnQueue = false
    private var protectedDataObserver: NSObjectProtocol?

    /// Retention cap — oldest events (and their media) are pruned past this, so
    /// the log and its media directory can't grow without bound.
    static let maxEvents = 500

    /// Media-size cap. With video the default, 500 clips could be ~15 GB, so the
    /// oldest events' *media* is dropped past this budget (the log entries — thumbnail
    /// + metadata — are kept, so the forensic record survives; only the heavy files go).
    static let maxMediaBytes: Int64 = 2_000_000_000   // ~2 GB

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

    /// Whether a prior event log is on disk — i.e. this app's *container* survived, so the
    /// launch is not a fresh install. Used to tell a genuine reinstall (Keychain PIN inherited,
    /// container gone) apart from a lost setup flag (PIN and container both intact) — see
    /// `KeychainService.recoveryKind`.
    ///
    /// Deliberately does NOT create anything, unlike `rootDirectoryURL()`: it must stay a pure
    /// observation, and it is asked at launch *before* the store is built.
    nonisolated static var containerHasPriorEvents: Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = docs.appendingPathComponent("MalinoisEvents", isDirectory: true)
                       .appendingPathComponent("events.json")
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// ~/Documents/MalinoisEvents/
    nonisolated private static func rootDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MalinoisEvents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        return dir
    }

    /// Directory for full-res stills / clips.
    nonisolated private static func mediaDirectoryURL() -> URL {
        let dir = rootDirectoryURL().appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        return dir
    }

    private var rootURL: URL { Self.rootDirectoryURL() }
    private var metadataURL: URL { rootURL.appendingPathComponent("events.json") }
    var mediaDirectory: URL { Self.mediaDirectoryURL() }

    init() {
        load()
        recoverFromJournal()
        sweepOrphanedMedia()
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

    /// Folds events mirrored from iCloud into the log, newest-first, skipping anything
    /// already present. Returns the number actually added.
    ///
    /// **A local event always wins.** If an incoming copy shares an id with one already in
    /// the log, the incoming one is discarded outright rather than merged field-by-field.
    /// This is the safety property the whole feature rests on: the log is the most critical
    /// structure in the app, first-hand evidence captured on this device outranks a claim
    /// arriving over the network, and an update path is exactly where a merge bug would be
    /// able to damage real evidence. Adding is the only thing a fetch can ever do.
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
    /// A mirror may therefore be superseded by a strictly later revision of the same event. A
    /// mirror still never displaces first-hand evidence, whatever its revision.
    nonisolated static func supersedes(incoming: Event, existing: Event) -> Bool {
        guard existing.isMirrored, incoming.isMirrored else { return false }
        let incomingRev = incoming.cloudRevision ?? 0
        let existingRev = existing.cloudRevision ?? 0
        if incomingRev > existingRev { return true }
        // Equal revisions can still differ in the ONE field whose value grows WITHIN a
        // revision: the coalesced flood count. Without this arm, a mirror that first fetched
        // rev 2 at count 1 was FROZEN — every later fetch carried the same revision, failed
        // strictly-greater, and the receiving device showed a plain row while the capturing
        // device said "sustained ×14" (found live 2026-08-30 on the build-25 pair; 34.H8's
        // thumbnail freeze, resurfaced through count progress). Monotonic on purpose: only a
        // strictly higher count repairs, so replays and stale duplicates still lose.
        return incomingRev == existingRev
            && (incoming.sustainedCount ?? 0) > (existing.sustainedCount ?? 0)
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

    /// Drops events past the count cap. When over cap, coalesced "sustained activity"
    /// (flood) events are dropped FIRST — synthetic noise from a flooding attack must
    /// never evict genuine tamper evidence past the retention boundary. Only if removing
    /// every flood event still leaves the log over cap are the oldest genuine removed —
    /// and the newest event is never a candidate, whatever its class (39.R1.6: the
    /// just-added flood record used to evict itself at birth when the log sat at cap).
    /// In-memory only (no disk I/O), so it's safe to run inline on the trigger path. Returns
    /// the evicted events' media names rather than deleting them itself — the caller deletes
    /// AFTER its `persist()`, so the checkpoint that drops the references lands first (34.H4).
    @discardableResult
    private func pruneToCountCap() -> [String] {
        guard events.count > Self.maxEvents else { return [] }
        let victims = Set(Self.countEvictionOrder(
            events: events.map { EvictionRow(id: $0.id,
                                             isFlood: $0.sustainedCount != nil,
                                             isSynced: $0.cloudSyncState == .synced,
                                             isAudit: $0.isStateChange || $0.interrupted == true,
                                             isMirrored: $0.isMirrored) },
            cap: Self.maxEvents))
        var removedNames: [String] = []
        events.removeAll { e in
            guard victims.contains(e.id) else { return false }
            removedNames.append(contentsOf: [e.mediaFilename, e.secondaryMediaFilename].compactMap { $0 })
            return true
        }
        return removedNames
    }

    /// Pure (unit-tested): which events the count cap evicts, oldest-first within each class.
    ///
    /// Classes are ordered by what the log can least afford to lose (34.H5 + the paced
    /// sub-flood finding): mirrored copies go first of all (fourth-pass R3-4 — the origin
    /// device and the cloud still hold them, so nothing owned is lost), then coalesced flood
    /// records (synthetic noise), then genuine events whose evidence already reached iCloud
    /// (the cloud keeps a copy), then genuine events still **waiting to upload**, and the
    /// arm/disarm/interruption audit rows last of all — they are tiny, and they are exactly
    /// what a paced attacker generating ordinary-looking events wants pushed over the
    /// boundary.
    ///
    /// **The newest event is exempt from every pass** (39.R1.6). Retention exists to shed the
    /// OLDEST, but the flood-first pass used to walk all the way to the front — so at cap,
    /// with no older flood rows retained (the steady state; flood rows always evict first),
    /// the just-added coalesced flood record evicted ITSELF at birth: the onset vanished,
    /// every later count update no-oped against a missing id, and each cadence still wrote a
    /// Media file nothing referenced. The record of the incident in progress outranks even an
    /// audit row in the degenerate everything-else-exhausted corner; the bound therefore
    /// holds at max(cap, 1), which at the real cap (500) is the same hard bound.
    /// One event's eviction-relevant facts — a struct rather than a tuple since the mirror
    /// class (R3-4) took the field count to five.
    struct EvictionRow {
        let id: UUID
        var isFlood = false
        var isSynced = false
        var isAudit = false
        var isMirrored = false
    }

    nonisolated static func countEvictionOrder(events: [EvictionRow], cap: Int) -> [UUID] {
        var overflow = events.count - cap
        guard overflow > 0 else { return [] }
        var out: [UUID] = []
        var taken = Set<UUID>()
        func pass(_ matches: (EvictionRow) -> Bool) {
            for e in events.dropFirst().reversed() {   // newest-first input → oldest-first here, newest exempt
                guard overflow > 0 else { return }
                if matches(e), !taken.contains(e.id) {
                    out.append(e.id)
                    taken.insert(e.id)
                    overflow -= 1
                }
            }
        }
        // Mirrors go before ANY first-hand class (fourth-pass R3-4): they are copies — the
        // capturing device and the cloud still hold them, and a re-fetch brings them back —
        // while every later class is evidence only THIS device owns. Without this pass,
        // bulk-inserted future-dated mirrors at cap evicted first-hand events and their
        // local media: cloud credentials reaching on-device evidence, the exact thing
        // tier-2 promises they cannot do (ADR 0006, extended to eviction).
        pass { $0.isMirrored }
        pass { $0.isFlood }
        pass { !$0.isAudit && $0.isSynced }
        pass { !$0.isAudit }
        pass { _ in true }
        return out
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
        let dir = Self.mediaDirectoryURL()
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
        ioQueue.async {
            let dir = Self.mediaDirectoryURL()
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
    /// update lands, and the sweep must never race that window. The rule itself is pure
    /// (`orphanedMediaNames`).
    private func sweepOrphanedMedia() {
        guard loadedCleanly, !loadFailed, !awaitingUnlock else { return }
        let referenced = Set(events.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
        ioQueue.async {
            let fm = FileManager.default
            let root = Self.rootDirectoryURL()
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
            let dir = Self.mediaDirectoryURL()
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
    nonisolated private static func journalURL() -> URL {
        rootDirectoryURL().appendingPathComponent("events.journal")
    }
    /// Cheap gate so the per-persist checkpoint is a no-op while nothing is journaled.
    private var journalHasEntries = false
    /// One log line per process for a failing journal — it degrades to the old behavior
    /// (in-memory + async persist), and a locked launch fails EVERY append until unlock.
    private var journalFailureLogged = false

    /// Appends the event's birth line BEFORE the caller proceeds — the point (H4/31.F3):
    /// `persist()` is an async full-file write, so a kill between detection and that write
    /// used to erase the event entirely, and the free tier has no cloud copy to survive it.
    /// A sub-millisecond append is the price of "the record exists first" being literally
    /// true. Deliberately not fsynced: a completed write survives process death — the
    /// force-quit / Voice Control close / OOM kills this app actually meets — and a hard
    /// power cut is the cloud fact push's race to win, not worth 10–100 ms on the trigger
    /// path (ADR 0005).
    private func appendToJournal(_ event: Event) {
        guard let line = Self.journalLine(for: event) else { return }
        let url = Self.journalURL()
        var appended = false
        if let handle = try? FileHandle(forWritingTo: url) {
            appended = ((try? handle.seekToEnd()) != nil) && ((try? handle.write(contentsOf: line)) != nil)
            try? handle.close()
        } else {
            appended = (try? line.write(to: url, options: [.completeFileProtectionUnlessOpen])) != nil
        }
        if appended {
            journalHasEntries = true
        } else if !journalFailureLogged {
            journalFailureLogged = true
            Log.store.error("Journal append failed — birth records fall back to the async log write")
        }
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
        guard let data = try? Data(contentsOf: Self.journalURL()) else { return }
        journalHasEntries = !data.isEmpty
        let known = Set(events.map(\.id))
        let missing = Self.journaledEvents(in: data).filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return }
        events = Self.merged(local: events, incoming: missing)
        let removedMedia = pruneToCountCap()
        persist()
        deleteMediaNames(removedMedia)
        Log.store.warning("Recovered \(missing.count, privacy: .public) event(s) from the journal — their log write never landed")
    }

    /// The newest successfully-persisted snapshot's ids, waiting for one coalesced
    /// checkpoint pass; nil when none is scheduled. Full-file writes are cumulative — the
    /// latest snapshot supersedes every earlier one — so a checkpoint per persist would be
    /// O(N²) busywork under a burst of adds (each pass re-reads the whole journal; the
    /// 500-add retention tests made the storm visible as seconds of main-queue drain).
    /// Retiring lines LATE is always safe — the journal only ever holds redundant extras.
    private var pendingCheckpointIDs: Set<UUID>?

    /// Coalesces checkpoint requests: a burst of persist successes becomes one pass over
    /// the journal with the newest snapshot, after a short debounce lets the burst land.
    private func scheduleJournalCheckpoint(persistedIDs: Set<UUID>) {
        let alreadyScheduled = pendingCheckpointIDs != nil
        pendingCheckpointIDs = persistedIDs          // the newest snapshot supersedes
        guard !alreadyScheduled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let ids = self.pendingCheckpointIDs {
                self.pendingCheckpointIDs = nil
                self.journalCheckpoint(persistedIDs: ids)
            }
        }
    }

    /// A metadata write reached disk: every journal line whose event is in that snapshot is
    /// redundant — rewrite the journal without them (usually: remove it). Entries born after
    /// the snapshot was taken keep their lines, so a mid-persist `add` loses nothing; a
    /// rewrite also sheds any torn tail, self-healing the file.
    private func journalCheckpoint(persistedIDs: Set<UUID>) {
        guard journalHasEntries else { return }
        let url = Self.journalURL()
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

    /// Persists a captured payload and derives its thumbnail entirely OFF the main
    /// actor. Both are heavy for clips (tens of MB / a video-frame decode), and
    /// doing them on `@MainActor` hitched the UI at exactly the moment the app
    /// needs to stay responsive. Returns nil if the write/move fails, so callers
    /// never reference media that isn't there.
    nonisolated func store(_ source: MediaSource, ext: String) async -> StoredMedia? {
        await withCheckedContinuation { cont in
            ioQueue.async {
                let name = UUID().uuidString + "." + ext
                let dest = Self.mediaDirectoryURL().appendingPathComponent(name)
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
                    Log.store.error("Failed to store media \(name, privacy: .public): \(String(describing: error), privacy: .public)")
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
    /// race-free.
    private func persist() {
        guard !loadFailed, !awaitingUnlock else { return }   // never overwrite an un-backed-up (R-05) or still-encrypted (V-01) log
        let snapshot = events
        let url = metadataURL
        let options = writeProtection
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: options)
                if self.persistFailedOnQueue {
                    self.persistFailedOnQueue = false
                    Task { @MainActor in self.persistDegraded = false }
                }
                // This snapshot is durably on disk — its events' journal lines are now
                // redundant and can be retired (on the main actor, the journal's one writer).
                let persistedIDs = Set(snapshot.map(\.id))
                Task { @MainActor in self.scheduleJournalCheckpoint(persistedIDs: persistedIDs) }
            } catch {
                Log.store.fault("Failed to persist event metadata: \(String(describing: error), privacy: .public)")
                if !self.persistFailedOnQueue {
                    self.persistFailedOnQueue = true
                    Task { @MainActor in self.persistDegraded = true }
                }
            }
        }
    }

    private func load() {
        let url = metadataURL
        guard fileManager.fileExists(atPath: url.path) else { return }   // first launch — no file
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Event].self, from: data) {
            events = decoded
            awaitingUnlock = false            // a successful read clears any deferred state
            loadedCleanly = true              // the in-memory log is the truth about the disk
            return
        }
        // The file exists but couldn't be read. Two very different causes:
        //  (a) the device hasn't been unlocked since boot, so completeFileProtection keeps
        //      the file encrypted — a background push-launch hits this on a HEALTHY file;
        //  (b) the file is genuinely corrupt/undecodable.
        // Only (b) may rename-to-backup. Renaming in case (a) — a metadata op that succeeds
        // even while the content is protected — would strand real evidence in a backup we
        // never re-read (V-01). So defer: leave the file untouched, block persist(), and
        // retry when the device unlocks.
        if !UIApplication.shared.isProtectedDataAvailable {
            awaitingUnlock = true
            observeProtectedDataAvailable()
            Log.store.info("events.json unreadable while the device is locked; deferring load until unlock")
            return
        }
        // (b) genuinely unreadable/corrupt. The device is unlocked to be here, so the
        // locked-file question is settled — a deferred load that lands in this branch must
        // clear its flag whatever the quarantine outcome (32.R4): left set, `persist()`
        // stayed refused for the rest of the process, silently, with nothing on Home saying
        // so. `loadFailed` alone governs the un-backupable case, and that one IS surfaced.
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
        }
    }

    /// Registers a one-time observer that retries the deferred load the instant the device
    /// is first unlocked (V-01). Idempotent — only the first locked-launch arms it.
    private func observeProtectedDataAvailable() {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadAfterUnlock() }
        }
    }

    private func reloadAfterUnlock() {
        guard awaitingUnlock else { return }
        // Whatever was added while the log was unreadable. The realistic case is an
        // interrupted-session record: a background launch before first unlock constructs the
        // engine, and `recoverInterruptedSessionIfNeeded` logs one during construction.
        let queued = events
        // Reads the disk copy and clears `awaitingUnlock` — or leaves both alone if it still
        // can't (device re-locked, or the file is corrupt), in which case persistence stays
        // blocked and `queued` is still all we have.
        load()
        recoverFromJournal()   // the protected file is readable now too (ADR 0005)
        guard !queued.isEmpty else { return }
        events = Self.reconciledAfterUnlock(disk: events, queued: queued)
        let removedMedia = pruneToCountCap()
        persist()
        deleteMediaNames(removedMedia)   // after the checkpoint (34.H4)
        scheduleByteCapPrune()
        Log.store.info("Reconciled \(queued.count, privacy: .public) queued event(s) with the log on unlock")
    }
}
