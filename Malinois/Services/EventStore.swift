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
import CryptoKit
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
    /// a log still locked after a restart, or one started fresh, reads as empty. Item 90's
    /// signer reads it at each write: a signed record missing from a log this launch did not
    /// read left with that log, and was not retired by the limit.
    var hasReadTheLog: Bool { loadedCleanly && !loadFailed && !awaitingUnlock }

    /// True while a deferred load reads the log at unlock (item 57, the 1.6 review's finding 1):
    /// what appears in `events` meanwhile is history from disk, not news, so the watch relay sends
    /// nothing for it.
    private(set) var isReadingHistory = false

    /// True after a RUNTIME persist failure (disk full, I/O error) until the next successful
    /// write (F6): "written to disk" is an async dispatch, and a failed write used to be
    /// log-only — the owner saw events in the UI that were never durably stored. Surfaced on
    /// Home beside `loadFailed`.
    @Published private(set) var persistDegraded = false
    /// The log could not be decoded and was set aside as a timestamped backup; a fresh log has
    /// started (item 73, review 2 R2.2). Cleared by the next clean load.
    @Published private(set) var logWasQuarantined = false
    /// The event logs set aside because they could not be read as a whole (item 122), newest first: listed after each load
    /// (at launch, and after the unlock when the launch could not read the log), once it has set one aside, and kept until
    /// the owner deletes one. Home says so while any is kept; the Event Log lists them at its top.
    @Published private(set) var setAsideLogs: [SetAsideLog] = []
    /// What Deletes of set-aside logs left to tell the owner (item 227's DS-5), each kind once, in the order they
    /// happened: a Delete that deleted nothing, and one that removed its log and may have left the log's photos and
    /// clips. The Event Log, where Delete's screen leaves for, shows each until the owner dismisses it there
    /// (`setAsideDeletionWasTold`). A whole delete adds nothing and takes nothing away. Kept in memory only.
    @Published private(set) var setAsideDeletionsToTell: [SetAsideLogDeletion] = []
    /// A birth-journal append or full sync failed, so the crash-durability promise does not
    /// hold for recent events (item 73, review 1 R6). The full log write still lands them.
    @Published private(set) var journalDegraded = false
    /// ioQueue-confined mirror, so the main-actor hop happens only on state CHANGES. Held to the queue by its type, as
    /// the four like it are (`QueueConfined`, item 220's defect 2): each was a field marked unsafe, kept to the queue
    /// by its comment alone.
    nonisolated private let persistFailedOnQueue = QueueConfined(false, onQueueLabelled: EventStore.ioQueueLabel)
    /// Media a limit dropped while the log write before its deletion had failed: deleted after the next write that
    /// succeeds, those that log no longer names (item 165's A1). `ioQueue`-confined, as `persistFailedOnQueue`.
    nonisolated private let mediaOwedDeletion = QueueConfined(Set<String>(), onQueueLabelled: EventStore.ioQueueLabel)
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
    nonisolated private let ioQueue = DispatchQueue(label: EventStore.ioQueueLabel, qos: .utility)
    /// The file queue's name: what the state confined to it checks it is used on (`QueueConfined`).
    nonisolated private static let ioQueueLabel = "com.malinois.eventstore.io"

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
    /// Observes every snapshot the store writes, on the I/O queue, after the write and its attachment checkpoint
    /// (item 155's S1, Codex's second look): the store's root, the snapshot and the bytes on disk, so a test can keep
    /// the disk as a kill right after that write would leave it. Static like `rootOverrideForTesting`: set before the
    /// store under test writes, cleared by the isolation's tearDown. Compiled out of Release. Main-actor isolated, like
    /// the store (item 155's T1): `persist` reads it when it queues a write and hands the write that observer, so the
    /// I/O queue never touches this static (reading it there raced the tests that set it), and a write calls the
    /// observer that was set when it was queued, never one set while it waited.
    static var checkpointObserverForTesting: (@Sendable (URL, [Event], Data) -> Void)?
    /// Test-only (item 170's codex-2): each queued log write first waits this long on the I/O queue, as a slow disk
    /// would, so a test can read the files as a kill before the write would leave them. Read when the write is queued,
    /// as the observer is. Compiled out of Release.
    static var writeDelayForTesting: TimeInterval = 0
    /// Drains queued disk writes before a test removes a crash-snapshot directory.
    func drainIOForTesting() { ioQueue.sync {} }
    /// Runs the attachment recovery now, as a retry's recovery at launch can while a capture saves (BACKLOG 176's
    /// codex-1).
    func recoverMediaAttachmentsForTesting() { recoverMediaAttachments() }
    /// A smaller media budget than the shipped 2 GB, for one store (item 116).
    var mediaBudgetForTesting: Int64?
    /// Awaited after the clean-up has measured the files, before it decides (item 116).
    var mediaMeasuredForTesting: (@MainActor () async -> Void)?
    /// Whether no byte-limit pass is running or owed: a test waits on it before a step that must not race one.
    var byteCapPruneIdleForTesting: Bool { !byteCapPruneRunning }
    /// Called on the I/O queue with the staged copy, before its size is checked against the
    /// record: a test shortens it there, as a short write would.
    nonisolated(unsafe) static var stagedCopyForTesting: ((URL) -> Void)?
    /// Stands in for a phone locked past its grace period (1.8.2's step 63, the audit's lead 7), which the Simulator does
    /// not enforce: a file of the store's under "complete unless open" cannot be reopened by its path.
    nonisolated(unsafe) static var sealedForTesting = false
    /// Step 63: iOS refuses to raise a waiting clip to the store's protection.
    nonisolated(unsafe) static var clipProtectionRefusedForTesting = false
    /// Step 63: where the camera's clips wait, in place of `CameraController.pendingClipsFolder`.
    nonisolated(unsafe) static var pendingClipsFolderForTesting: URL?
    /// BACKLOG 176's codex-3: the writer stops before renaming a file that replaces one, leaving its temporary file, as
    /// a kill there would.
    nonisolated(unsafe) static var killBeforeReplacingForTesting = false
    /// Item 182 (codex-2 on 995f7d98): the log's full sync before a journal checkpoint fails, as a disk refusing it would.
    nonisolated(unsafe) static var fullSyncFailsForTesting = false
    /// The journal's open for an append fails, as a refused open would (item 187's round B, qwen-5).
    nonisolated(unsafe) static var journalOpenFailsForTesting = false
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
    /// Where evidence signing keeps its signatures: beside the log, in a file of their own (BACKLOG item 90; the
    /// owner's ruling of 2026-10-31, "1 - a").
    nonisolated var evidenceSignaturesURL: URL { root.appendingPathComponent(EvidenceSignatureFile.name) }

    /// Hears each write of the log once it is on disk (item 90's signer): the write's number, rising, and the events
    /// written. Called on the main actor after the write, never on a trigger's path.
    var onDurableWrite: ((Int, [Event]) -> Void)?
    /// The number of the last write queued, for `onDurableWrite`.
    private var writesQueued = 0
    /// This phone's own records in the log as the store first read it: at launch, or at the unlock when the launch could
    /// not read it; nil until then. The signer tells by it history the log kept from a reinstall's empty log (item 190's
    /// codex-2 and deepseek-3 on b7702f5, the owner's "a").
    private(set) var logReadAtLaunch: Set<UUID>?
    /// Told `logReadAtLaunch` when it comes after the signer was made (the unlock).
    var onLogRead: ((Set<UUID>) -> Void)?

    /// Keeps this phone's own records in the log as read, once it can be written, and tells `onLogRead`: at launch no one
    /// listens yet, and the signer reads `logReadAtLaunch`.
    private func noteTheLogRead(_ onDisk: [Event]) {
        guard acceptsWrites else { return }
        let read = Set(onDisk.filter { !$0.isMirrored }.map(\.id))
        logReadAtLaunch = read
        onLogRead?(read)
    }

    /// Whether the log may be written now: its load is not waiting for the phone's unlock and did not fail. The records
    /// in memory are then the log's, on a first launch with no log too (item 90's signer notes them when this install's
    /// key is first certified, never to be signed).
    var acceptsWrites: Bool { !loadFailed && !awaitingUnlock }

    /// - Parameter protectedDataAvailable: whether the device's protected data can be read; UIKit's
    ///   answer unless a test injects one.
    init(protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }) {
        root = Self.resolvedRoot()
        self.protectedDataAvailable = protectedDataAvailable
        load()
        refreshSetAsideLogs()   // item 122: the one this load set aside among them
        let onDisk = events, writesAtLoad = writesQueued   // the log as read, for the signer (item 182, codex-3)
        noteTheLogRead(onDisk)
        loadReportsOwed()   // item 166's A1: before the journal's recovery and the launch trims add their own (codex-22)
        loadLimitRemovals()   // item 182: before the journal's recovery too, whose log write writes them (codex-3)
        recoverFromJournal()
        dropReportsOwedForEventsHeld()   // the journal may have brought one back
        dropLimitRemovalsHeld()          // or a removal's record
        enforceCountCapsAfterLoad()
        recoverMediaAttachments()
        attachWaitingClips()   // a clip a sealed phone kept waiting before the app ended (step 63)
        writeBackBoundedCopies()
        sweepOrphanedMedia()
        establishSeenMark()   // item 81
        handTheSignerTheLogRead(onDisk, writesAtLoad: writesAtLoad)
    }

    /// Tells the signer the log on disk as the store read it, when no write follows to tell it (item 182, codex-3 on
    /// 68bd96b3, the owner's "a"), so the signer compares at launch, or at the unlock, not only at the first write. Not
    /// while the load failed or waits for the unlock, and not once a write is queued, whose own notice holds the log as
    /// written. After the caller's work, so the signer's hearing is set up first at launch.
    private func handTheSignerTheLogRead(_ onDisk: [Event], writesAtLoad: Int) {
        guard acceptsWrites, writesQueued == writesAtLoad else { return }
        writesQueued += 1
        let writeNumber = writesQueued
        Task { @MainActor [weak self] in self?.onDurableWrite?(writeNumber, onDisk) }
    }

    // MARK: - Mutations

    /// Adds a record of this phone's, first in the log whatever its time: the limit takes rows by their place in the
    /// log, so a clock set back never has a new row taken in its own add (the clock, on 92bf0605, the owner's "a").
    /// The signer's line, `placedByItsTime`, at its absence statement's time, goes below every row newer than it
    /// instead, so it takes no newer row's place in the limit (codex-2 on c2202a26).
    func add(_ incoming: Event, placedByItsTime: Bool = false) {
        var event = incoming
        if keepsNewEventsLocal() { event.keptLocal = true }   // item 115: recorded while iCloud backup is off
        appendToJournal(event)        // durable FIRST — the record exists before anything else (ADR 0005)
        // An iCloud copy under the record's ID gives way to it: the evidence signer's line, written again after it was
        // lost here (codex-4 on 417158fe). Left beside it, a later pull would keep the copy.
        events.removeAll { $0.id == event.id && $0.isMirrored }
        let place = placedByItsTime ? (events.lastIndex { $0.startDate > event.startDate }.map { $0 + 1 } ?? 0) : 0
        events.insert(event, at: place)
        // The row this add puts in is never the one its own limit takes, and the rows it does take have their journal
        // lines retired with this write, as the journal's recovery and the load do (codex-1 on 92bf0605, the owner's
        // "a").
        let before = Set(events.map(\.id))
        let removedMedia = pruneToCountCap(sparing: event.id)   // cheap, in-memory — safe on the trigger path
        persist(alsoRetiring: before.subtracting(events.map(\.id)))
        // Media deletes enqueue AFTER the metadata write (34.H4): the queue is serial, so the
        // snapshot that no longer references these files reaches disk before the files go — a
        // kill in between leaves an orphan for the launch sweep, never a dangling reference.
        deleteMediaNames(removedMedia)
        scheduleByteCapPrune()        // byte cap statting runs OFF the trigger path (F-19)
    }

    /// Folds events mirrored from iCloud into the log, newest-first: a new id is added, and a
    /// copy of one already held replaces it only as `supersedes` allows. The log keeps the order things happened on
    /// this phone, never a sort by time, which a clock set back would steer (codex-1 on 995f7d98, the owner's "a"): the
    /// rows it holds stay where they are; this phone's own rows it did not hold (the journal's recovery, what was
    /// written while the phone was locked) go first, as given, the newest first; another device's copies, and this
    /// phone's signer lines (written at their statement's time, `add`'s `placedByItsTime`), take their place by their
    /// time, below every row newer than them (codex-1 on 2bbc3574).
    ///
    /// **First-hand evidence always wins.** An incoming copy never replaces an event captured
    /// on this device, whatever it claims; it is discarded outright, never merged field by
    /// field. This is the safety property the whole feature rests on: the log is the most
    /// critical structure in the app, first-hand evidence captured on this device outranks a
    /// claim arriving over the network, and an update path is exactly where a merge bug would
    /// be able to damage real evidence. A MIRROR (another device's event held here) may be
    /// replaced by a copy of itself that knows more, a later revision or an equal one with a
    /// grown count, a new failure reason or a newly staged thumbnail, and keeps the media downloaded onto it
    /// (`inheritingLocalEnrichment`). From a copy of any revision it learns that its capture was
    /// lost after its local files were discarded (`learningTheLoss`).
    ///
    /// Pure so it can be tested without CloudKit, which cannot run in the Simulator at all.
    nonisolated static func merged(local: [Event], incoming: [Event]) -> [Event] {
        var byID = [UUID: Event](minimumCapacity: local.count + incoming.count)
        var order: [UUID] = []
        for e in local where byID.updateValue(e, forKey: e.id) == nil { order.append(e.id) }
        var arrived: [UUID] = [], byTime: [UUID] = []
        for e in incoming {
            if let existing = byID[e.id] {
                if supersedes(incoming: e, existing: existing) {
                    byID[e.id] = inheritingLocalEnrichment(existing: existing, incoming: e)
                } else if let learned = learningTheLoss(existing: existing, incoming: e) {
                    byID[e.id] = learned
                }
            } else {
                byID[e.id] = e
                if e.isMirrored || Event.isSignerLine(e) {   // the signer's lines by their time (items 182, 190)
                    byTime.append(e.id)
                } else {
                    arrived.append(e.id)
                }
            }
        }
        var result = (arrived + order).compactMap { byID[$0] }
        for id in byTime {
            guard let row = byID[id] else { continue }
            result.insert(row, at: result.lastIndex { $0.startDate > row.startDate }.map { $0 + 1 } ?? 0)
        }
        return result
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
    /// by an equal revision that has learned more: a count that grew, a capture's failure
    /// reason it did not have (item 94), or a thumbnail whose first staging failed. A mirror still never displaces
    /// first-hand evidence,
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
        // other phone never said why there was no photo). A staged thumbnail can newly arrive at the same revision too.
        // Monotonic on purpose: a count must grow, a reason newly appear or a thumbnail newly arrive; no count may
        // shrink and the reason may not go away. Replays and stale duplicates still lose.
        guard incomingRev == existingRev else { return false }
        let floods = (incoming: incoming.sustainedCount ?? 0, existing: existing.sustainedCount ?? 0)
        let attempts = (incoming: incoming.wrongPINCount ?? 0, existing: existing.wrongPINCount ?? 0)
        let reason = (incoming: incoming.captureFailure != nil, existing: existing.captureFailure != nil)
        guard floods.incoming >= floods.existing, attempts.incoming >= attempts.existing,
              reason.incoming || !reason.existing else { return false }
        return floods.incoming > floods.existing || attempts.incoming > attempts.existing
            || (reason.incoming && !reason.existing)
            || (incoming.thumbnailData != nil && existing.thumbnailData == nil)
    }

    /// Pure (unit-tested): what a superseding mirror copy inherits from the copy it replaces.
    /// A cloud-decoded mirror carries `mediaFilename` nil BY CONSTRUCTION (the file is not on
    /// this device) — but the owner may have downloaded full evidence onto this mirror, and a
    /// wholesale replacement dropped that reference, stranding the file for the orphan sweep
    /// to delete (eighth-review M3). Locally-born enrichment survives, each downloaded file in
    /// the slot of its camera (`carryingFiles`); everything the cloud copy actually carries
    /// (counts, revision, metadata) wins as before.
    nonisolated static func inheritingLocalEnrichment(existing: Event, incoming: Event) -> Event {
        var out = carryingFiles(of: existing, into: incoming)
        if existing.mediaDiscarded == true { out.mediaDiscarded = true }   // never taken back (item 166's A2)
        // Never a thumbnail the decoder would refuse (codex-13 on 1.8.2: one an older version saved).
        if out.thumbnailData == nil, let kept = existing.thumbnailData, kept.count <= CloudExfiltrator.maxThumbnailBytes {
            out.thumbnailData = kept
        }
        return out
    }

    /// Pure (unit-tested): `incoming` with the files downloaded onto `existing`, each in the slot of its camera
    /// (item 201). A file the download placed by its camera (`MonitoringCloudCoordinator.mediaPlacement`) goes to the
    /// slot the later record names for that camera; where it names none, the file keeps its own slot if the later
    /// record leaves that slot unnamed, or else takes the other, unnamed one, and gives the slot its camera. A file a
    /// legacy position placed, with no camera known, keeps its position. When the files would not land in empty
    /// slots of their own, they keep the slots they had, as before 1.12: no file is dropped.
    nonisolated static func carryingFiles(of existing: Event, into incoming: Event) -> Event {
        var out = incoming
        let held = [existing.mediaFilename.map { (file: $0, camera: existing.primaryCamera, primary: true) },
                    existing.secondaryMediaFilename.map { (file: $0, camera: existing.secondaryCamera, primary: false) }]
            .compactMap { $0 }
        func label(_ primary: Bool) -> String? { primary ? incoming.primaryCamera : incoming.secondaryCamera }
        func empty(_ primary: Bool) -> Bool { (primary ? incoming.mediaFilename : incoming.secondaryMediaFilename) == nil }
        /// The slot a file goes to: true for the first.
        func slot(file camera: String?, from primary: Bool) -> Bool {
            guard let camera else { return primary }   // a legacy position: kept
            if incoming.primaryCamera == camera { return true }
            if incoming.secondaryCamera == camera { return false }
            if label(primary) == nil { return primary }
            if label(!primary) == nil { return !primary }
            return primary
        }
        let slots = held.map { slot(file: $0.camera, from: $0.primary) }
        guard Set(slots).count == slots.count, slots.allSatisfy(empty) else {
            if out.mediaFilename == nil { out.mediaFilename = existing.mediaFilename }
            if out.secondaryMediaFilename == nil { out.secondaryMediaFilename = existing.secondaryMediaFilename }
            return out
        }
        for (item, primary) in zip(held, slots) {
            if primary {
                out.mediaFilename = item.file
                if out.primaryCamera == nil { out.primaryCamera = item.camera }
            } else {
                out.secondaryMediaFilename = item.file
                if out.secondaryCamera == nil { out.secondaryCamera = item.camera }
            }
        }
        return out
    }

    /// Pure (unit-tested): a mirror that learns its capture is gone locally and from iCloud (item
    /// 166's A2, Codex's codex-2). The capturing phone marks the loss (`mediaDiscarded`) on a copy that
    /// may carry the same revision as the one held (the thumbnail stays) or, from an older version,
    /// a lower one; neither may replace it (`supersedes`), so the flag alone is taken, and the copy
    /// held keeps everything else it had. First-hand evidence is never touched; nil when nothing is
    /// learned.
    nonisolated static func learningTheLoss(existing: Event, incoming: Event) -> Event? {
        guard existing.isMirrored, incoming.isMirrored, incoming.mediaDiscarded == true,
              existing.mediaDiscarded != true else { return nil }
        var learned = existing
        learned.mediaDiscarded = true
        return learned
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
    /// the result is newest-first like everything else: what was written while the phone was locked (`queued`, the
    /// newest first) goes first, as it came, whatever its time (codex-1 on 995f7d98).
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
        let next = Self.merged(local: events, incoming: incoming)
        let changes = Self.mergeChanges(from: before, to: next)
        guard changes.inserted + changes.updated > 0 else { return 0 }   // the log as it was (codex-1 on 995f7d98)
        events = next
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
           let owed = try? StoredJSON.decode(RestoreOwed.self, from: data) {
            restoreOwedSince = owed.since
        }
        if let data = try? Data(contentsOf: seenURL),
           let stored = try? StoredJSON.decode([UUID].self, from: data) {
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
    /// `spared`: the row an add puts in, never taken by that add's limit, counted as already going as a row whose
    /// upload runs (codex-1 on 92bf0605).
    @discardableResult
    private func pruneToCountCap(sparing spared: UUID? = nil) -> [String] {
        // Preserve every legacy first-hand watch before a smaller status budget drops
        // its arm row. The shared registry's marker makes this a one-time operation.
        if hasReadTheLog { BeatSessionRegistry.seedIfNeeded(from: events) }
        // Each pool by the rows' place in the log, newest first, never by their times, which a clock set back can
        // change (the clock, on 92bf0605, the owner's "a"; an edited backup's order is a stated limit, SECURITY.md).
        let victims = Set(Self.countEvictionOrder(
            events: events.map { EvictionRow(id: $0.id,
                                             isFlood: $0.sustainedCount != nil,
                                             isSynced: $0.cloudSyncState == .synced,
                                             isAudit: $0.isStateChange || $0.interrupted == true,
                                             isMirrored: $0.isMirrored,
                                             inFlight: uploadsInFlight[$0.id] != nil || linesHeldForTheSigner.contains($0.id)
                                                 || $0.id == spared) },
            incidentCap: Self.maxIncidentEvents, auditCap: Self.maxAuditEvents))
        // Item 114: a budget still over after this pass waited for an upload, or for a line the evidence signer holds;
        // check again when it ends or is let go.
        defer {
            if !uploadsInFlight.isEmpty || !linesHeldForTheSigner.isEmpty, overACountBudget { limitsWaitForUploads = true }
        }
        guard !victims.isEmpty else { return [] }
        var removedNames: [String] = []
        var removed: [Event] = []
        events.removeAll { e in
            guard victims.contains(e.id) else { return false }
            removedNames.append(contentsOf: [e.mediaFilename, e.secondaryMediaFilename].compactMap { $0 })
            removed.append(e)
            return true
        }
        // This phone's own records the limit removed, for evidence signing: on disk before the log that drops them
        // (item 182; `persist`), each with what the removed row was (codex-1 on eaac8b96).
        for event in removed where !event.isMirrored { limitRemovalsAsRemoved[event.id] = event.evidenceIdentity }
        // Every row the limit removes owes its journal line's retirement, whichever path asked for the pass (codex-2 on
        // 2bbc3574): kept owed until a checkpoint retires it.
        journalRetirementsOwed.formUnion(removed.lazy.map(\.id))
        let watch = evictionWatch()
        // What the marker could count, without a thumbnail, none dropped (item 116, Q1), owed on disk: the file queue
        // writes it before the log the caller saves next, so a kill before the report runs does not lose it (item 166's
        // A1, Codex's codex-1).
        let candidates = removed.filter(\.mayBeAMissedUpload).map(Self.lightCopy)
        let owed = candidates.isEmpty ? nil : OwedReport(id: UUID(), events: candidates, watch: watch)
        if let owed { oweReport(owed) }
        if let report = onCountEviction {
            let ids = Set(removed.map(\.id))
            reportsInFlight.formUnion(ids)
            Task { @MainActor [weak self] in
                report(removed, watch)   // item 114's marker, outside this mutation
                self?.reportsInFlight.subtract(ids)
                if let owed { self?.retireReportsOwed([owed.id]) }
            }
        } else if let owed {
            unreportedEvictions.append((owed.events, owed.watch, owed.id))   // until the engine listens
        }
        return removedNames
    }

    /// Whether either count budget is still over, which only an upload in flight leaves it (item 114).
    private var overACountBudget: Bool {
        let status = events.filter { $0.isStateChange || $0.interrupted == true }.count
        return events.count - status > Self.maxIncidentEvents || status > Self.maxAuditEvents
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
        /// Its upload is running (item 114; status entries too, item 116): never taken, and
        /// counted as already going.
        var inFlight = false
    }

    /// Pure retention policy, with newest-first input. Each pool first discards mirrored
    /// copies, including its newest mirror, so cloud input cannot displace owned evidence.
    /// Incidents then discard floods, synced evidence and finally pending evidence, oldest
    /// first within each class. Status entries discard the oldest owned status entries.
    /// The newest first-hand row in EACH pool is protected from eviction, including an
    /// in-flight flood anchor. A first-hand pool therefore retains at least one row even
    /// if a caller supplies a zero cap; production budgets are 500 incidents / 100 status.
    /// A row whose upload is running is never taken and no newer row is taken in its place: it
    /// counts as already going, and the store applies the limit again when the upload ends, by
    /// when the row is usually synced and goes without loss (item 114, from item 108's F5).
    nonisolated static func countEvictionOrder(events: [EvictionRow], incidentCap: Int,
                                               auditCap: Int) -> [UUID] {
        func evict(_ rows: [EvictionRow], cap: Int, incidents: Bool) -> [UUID] {
            let protected = rows.first { !$0.isMirrored }?.id
            var overflow = rows.count - max(0, cap) - rows.filter { $0.inFlight && $0.id != protected }.count
            guard overflow > 0 else { return [] }
            var result: [UUID] = []
            var taken = Set<UUID>()
            func pass(_ matches: (EvictionRow) -> Bool) {
                for row in rows.reversed() {
                    guard overflow > 0 else { return }
                    guard row.id != protected, !row.inFlight, !taken.contains(row.id), matches(row) else { continue }
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

    // MARK: - Uploads in flight (item 114, from item 108's F5)

    /// Events whose upload is running now (an incident's evidence or a status entry's record),
    /// counted because a retry can overlap the response's own upload. The event limit and the
    /// storage cap leave them alone until the last upload ends.
    private var uploadsInFlight: [UUID: Int] = [:]
    /// A limit left something for an upload to finish: apply both again when the uploads end.
    private var limitsWaitForUploads = false

    /// The event limit's removals, for the engine's marker (item 114), with the watch each was made
    /// in. Called after the removal is saved, on a later turn of the main actor, so a marker the
    /// engine adds cannot re-enter it. Removals made before it is set (the trims while the log
    /// loads at launch, item 116's R6, and the reports a launch before still owed, item 166's A1)
    /// are kept and handed over when it is.
    var onCountEviction: (([Event], Date?) -> Void)? {
        didSet { handOverUnreported() }
    }

    /// Hands the removals kept for the report to it, once it is set; each report owed is retired from disk once its
    /// report has run (item 166's A1).
    private func handOverUnreported() {
        guard let report = onCountEviction, !unreportedEvictions.isEmpty else { return }
        let held = unreportedEvictions
        unreportedEvictions = []
        let ids = Set(held.flatMap { $0.events.map(\.id) })
        reportsInFlight.formUnion(ids)
        Task { @MainActor [weak self] in
            for batch in held { report(batch.events, batch.watch) }
            self?.reportsInFlight.subtract(ids)
            self?.retireReportsOwed(Set(held.map(\.owed)))
        }
    }

    /// The removals whose marker report has not run yet: kept until the engine listens (`unreportedEvictions`), or
    /// handed to a report that runs a turn later. The marker's rule reads their account bindings, so those are kept
    /// until it has run (item 153's MAL-08).
    var removalsAwaitingReport: Set<UUID> {
        reportsInFlight.union(unreportedEvictions.flatMap { $0.events.map(\.id) })
    }

    /// The removals handed to a report that has not run yet.
    private var reportsInFlight: Set<UUID> = []

    /// The watch a removal is made in (the engine's `armedSince`), read when it is made: the report
    /// runs a turn later, and a disarm in between must not move it out of its watch (item 116, N2).
    var evictionWatch: () -> Date? = { nil }

    /// Removals no one has heard yet that the marker could count (`Event.mayBeAMissedUpload`), with
    /// their watch, without their thumbnails. Nothing else is kept, and nothing of this is dropped:
    /// bounding it lost the one loss the marker exists to report, first a large launch trim whole
    /// (item 116, P1), then an incident crowded out by status entries (Q1). It holds only events
    /// this store held a moment before, or a launch before still owed (`reportsOwed`), and only until
    /// the engine listens, when the Pro check first answers: normally seconds after launch, though
    /// nothing forces StoreKit to answer. Each carries the id of its report owed.
    private var unreportedEvictions: [(events: [Event], watch: Date?, owed: UUID)] = []

    // MARK: - The event limit's removals, for evidence signing (item 182)

    /// The file beside the log that names this phone's own records the event limit removed, until evidence signing has
    /// accounted for them.
    static let limitRemovalsFileName = "limit-removals.json"

    /// This phone's own records the event limit removed, until the signer has accounted for them (`forgetLimitRemovals`):
    /// written beside the log before the log that drops them and read back at launch, so a kill between the two cannot
    /// make a removal by the limit look like a record that left the log some other way (item 182, the owner's "a"; the
    /// reports owed keep the same order, codex-22). The signer hears them with each write (`EvidenceSigning`). Each with
    /// what the removed row was, its start, kind and interruption, so the signer retires a record only when the row the
    /// limit removed was that record (codex-1 on eaac8b96 and c2202a26, the owner's "a").
    private(set) var limitRemovalsAsRemoved: [UUID: RecordIdentity] = [:]

    /// The IDs of the limit's removals (`limitRemovalsAsRemoved`).
    var limitRemovals: Set<UUID> { Set(limitRemovalsAsRemoved.keys) }

    /// The removals as last written to disk (nil: not known), so a log write writes them first when they differ.
    /// `ioQueue`-confined.
    nonisolated private let limitRemovalsOnDisk = QueueConfined<[UUID: RecordIdentity]?>(nil, onQueueLabelled: EventStore.ioQueueLabel)

    /// A file of removals that cannot be read and could not be set aside: never written over.
    private var limitRemovalsFrozen = false

    /// This phone's key for the removals' check, once read or made. `ioQueue`-confined.
    nonisolated private let limitRemovalsKeyRead = QueueConfined<SymmetricKey?>(nil, onQueueLabelled: EventStore.ioQueueLabel)

    private var limitRemovalsURL: URL { rootURL.appendingPathComponent(Self.limitRemovalsFileName) }

    /// Forgets the removals the signer has accounted for: retired with a signed statement, or never signed here. One
    /// whose journal line is still owed retirement stays until the line is retired, then goes, so a kill before the
    /// checkpoint cannot leave the line to bring the row back as a write that never landed (codex-1 on 995f7d98).
    func forgetLimitRemovals(_ ids: Set<UUID>) {
        let owed = ids.intersection(journalRetirementsOwed)
        limitRemovalsForgottenOnRetirement.formUnion(owed)
        let before = limitRemovalsAsRemoved.count
        for id in ids.subtracting(owed) { limitRemovalsAsRemoved[id] = nil }
        if limitRemovalsAsRemoved.count != before { saveLimitRemovals() }
    }

    /// Forgets the removals the signer accounted for whose journal lines are no longer owed retirement.
    private func forgetRemovalsNoLongerOwed() {
        let ready = limitRemovalsForgottenOnRetirement.subtracting(journalRetirementsOwed)
        guard !ready.isEmpty else { return }
        limitRemovalsForgottenOnRetirement.subtract(ready)
        forgetLimitRemovals(ready)
    }

    /// Writes the removals on the file queue, so a write asked for before a log write lands before it; the file goes once
    /// none is left. Not while the log waits for the first unlock or could not be read: no log is written then either.
    private func saveLimitRemovals() {
        guard !loadFailed, !awaitingUnlock, !limitRemovalsFrozen else { return }
        let removals = limitRemovalsAsRemoved
        let url = limitRemovalsURL
        let options = writeProtection
        ioQueue.async { [weak self] in _ = self?.writeLimitRemovalsOnQueue(removals, to: url, options: options) }
    }

    /// Writes `removals`, checked with this phone's key (or removes the file when there are none), and records them as
    /// what is on disk; false when that failed, the key's read too. The log is written all the same: signing never
    /// holds the log up. A removal that never reached the disk can only be named gone after a kill, never a record that
    /// left otherwise named retired (ADR 0066).
    nonisolated private func writeLimitRemovalsOnQueue(_ removals: [UUID: RecordIdentity], to url: URL,
                                                       options: Data.WritingOptions) -> Bool {
        do {
            if removals.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                guard let key = limitRemovalsKeyOnQueue() else { throw CocoaError(.fileWriteNoPermission) }
                try Self.limitRemovalsData(removals, key: key).write(to: url, options: options)
            }
            limitRemovalsOnDisk.set(removals)
            return true
        } catch {
            Log.store.error("Failed to save the limit's removals: \(Log.ref(error), privacy: .public)")
            return false
        }
    }

    /// At launch and after the unlock's reload, before the journal's recovery, whose log write writes them (codex-3 on
    /// 73441cbe): the removals not yet accounted for, as far as this phone's key vouches for them (codex-1 on 73441cbe,
    /// the owner's "1 - a"). A file that cannot be read, or whose check does not hold with the key (edited, or made with a
    /// key this phone does not have, as after a restore onto another iPhone), is set aside, never taken for none and
    /// written over: the signer names its signed records gone, never retired.
    private func loadLimitRemovals() {
        guard !awaitingUnlock, !loadFailed else { return }
        let url = limitRemovalsURL
        var stored: [UUID: RecordIdentity] = [:]
        if fileManager.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let key = Self.limitRemovalsKey(create: false),
               let checked = Self.limitRemovals(in: data, key: key) {
                stored = checked
            } else {
                setLimitRemovalsAside(url)
            }
        }
        if !limitRemovalsFrozen {
            let onDisk = stored
            ioQueue.async { [weak self] in self?.limitRemovalsOnDisk.set(onDisk) }
        }
        limitRemovalsAsRemoved.merge(stored) { inMemory, _ in inMemory }
        if limitRemovalsAsRemoved != stored { saveLimitRemovals() }
    }

    /// After the journal's recovery: a record the log holds was not removed after all (a kill before the log's write),
    /// unless only an iCloud copy holds its ID.
    private func dropLimitRemovalsHeld() {
        guard !awaitingUnlock, !loadFailed else { return }
        let before = limitRemovalsAsRemoved.count
        for event in events where !event.isMirrored { limitRemovalsAsRemoved[event.id] = nil }
        if limitRemovalsAsRemoved.count != before { saveLimitRemovals() }
    }

    private func setLimitRemovalsAside(_ url: URL) {
        let backup = Self.setAsideURL(for: url)   // a name not yet taken (item 220's defect 4)
        if (try? fileManager.moveItem(at: url, to: backup)) == nil {
            limitRemovalsFrozen = true
            Log.store.fault("limit-removals.json unreadable or unchecked and could not be set aside; it is not written over")
        } else {
            Log.store.error("limit-removals.json unreadable or unchecked; preserved as \(backup.lastPathComponent, privacy: .public)")
        }
    }

    /// This phone's key for the removals' check, made at the first write that needs it. `ioQueue`-confined.
    nonisolated private func limitRemovalsKeyOnQueue() -> SymmetricKey? {
        if let read = limitRemovalsKeyRead.get() { return read }
        let key = Self.limitRemovalsKey(create: true)
        limitRemovalsKeyRead.set(key)
        return key
    }

    /// The key that checks the removals' file: this phone's, kept in the keychain for this device only
    /// (`KeychainService.limitRemovalsKey`), or a test's.
    nonisolated static func limitRemovalsKey(create: Bool) -> SymmetricKey? {
        #if DEBUG
        if let limitRemovalsKeyForTesting { return limitRemovalsKeyForTesting(create) }
        #endif
        return KeychainService.limitRemovalsKey(create: create)
    }

    #if DEBUG
    /// A test's key for the removals' check, in place of the keychain's.
    nonisolated(unsafe) static var limitRemovalsKeyForTesting: (@Sendable (Bool) -> SymmetricKey?)?
    #endif

    /// The removals' file: each removal, by ID ascending, with what the removed row was, and their check, an HMAC-SHA256
    /// with this phone's key, so an edited backup restored can neither add a record to them (codex-1 on 73441cbe) nor
    /// change what a removed row was (codex-1 on eaac8b96 and c2202a26). A file of an earlier form does not read: set
    /// aside, its records are named gone.
    private struct CheckedLimitRemovals: Codable {
        let removals: [LimitRemoval]
        let check: Data
    }

    /// One of the removals in their file: the ID, and the removed row's start, kind and interruption.
    private struct LimitRemoval: Codable {
        let id: UUID
        let start: Int64?
        let kind: String?
        /// True for an interruption record; left out otherwise.
        let interrupted: Bool?
    }

    /// The removals' file holding `removals`, checked with `key`.
    nonisolated static func limitRemovalsData(_ removals: [UUID: RecordIdentity], key: SymmetricKey) throws -> Data {
        let sorted = removals.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { LimitRemoval(id: $0.key, start: $0.value.start, kind: $0.value.kind,
                                interrupted: $0.value.interrupted ? true : nil) }
        let check = Data(HMAC<SHA256>.authenticationCode(for: limitRemovalsCheckInput(sorted), using: key))
        return try JSONEncoder().encode(CheckedLimitRemovals(removals: sorted, check: check))
    }

    /// The removals `data` holds when it is the removals' file and its check holds with `key`; nil otherwise.
    nonisolated static func limitRemovals(in data: Data, key: SymmetricKey) -> [UUID: RecordIdentity]? {
        guard let file = try? StoredJSON.decode(CheckedLimitRemovals.self, from: data),
              HMAC<SHA256>.isValidAuthenticationCode(file.check, authenticating: limitRemovalsCheckInput(file.removals),
                                                     using: key) else { return nil }
        return Dictionary(file.removals.map { ($0.id, RecordIdentity(start: $0.start, kind: $0.kind,
                                                                     interrupted: $0.interrupted == true)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// What the check covers: this file's use of the key and its form, then each removal in the file's order, one a line:
    /// its ID, its start or "-", its kind's bytes in base64 or "-", and 1 for an interruption record or 0.
    nonisolated private static func limitRemovalsCheckInput(_ removals: [LimitRemoval]) -> Data {
        let lines = removals.map { removal in
            [removal.id.uuidString, removal.start.map(String.init) ?? "-",
             removal.kind.map { Data($0.utf8).base64EncodedString() } ?? "-", removal.interrupted == true ? "1" : "0"]
                .joined(separator: " ")
        }
        return Data((["malinois limit removals 3"] + lines).joined(separator: "\n").utf8)
    }

    // MARK: - Reports owed (item 166's A1)

    /// The file beside the log that holds the event limit's reports still owed.
    static let reportsOwedFileName = "reports-owed.json"

    /// A removal the marker's report has not heard yet: what it could count (light copies) and the watch it was made in.
    /// Written beside the log before the log that drops its events, kept until its report has run, and read back at
    /// launch, so a kill before the report runs does not lose it (item 166's A1, Codex's codex-1).
    private struct OwedReport: Codable, Equatable {
        let id: UUID
        let events: [Event]
        let watch: Date?
    }

    /// The reports owed, as written beside the log.
    private var reportsOwed: [OwedReport] = []

    /// The reports owed as last written to disk (nil: not known, before they are read or after a file that could not be
    /// set aside), so a log write can check its reports are there first (`persist`, codex-22). `ioQueue`-confined.
    nonisolated private let reportsOwedOnDisk = QueueConfined<[OwedReport]?>(nil, onQueueLabelled: EventStore.ioQueueLabel)

    /// An unreadable file of reports owed that could not be set aside: never written over, and no log that drops an event
    /// whose report is owed is written either.
    private var reportsOwedFrozen = false

    private var reportsOwedURL: URL { rootURL.appendingPathComponent(Self.reportsOwedFileName) }

    private func oweReport(_ owed: OwedReport) {
        reportsOwed.append(owed)
        saveReportsOwed()
    }

    /// Drops the reports that have run, and saves what is still owed. The record a report adds is in the journal by then:
    /// `add` journals it before it returns.
    private func retireReportsOwed(_ ids: Set<UUID>) {
        let before = reportsOwed.count
        reportsOwed.removeAll { ids.contains($0.id) }
        if reportsOwed.count != before { saveReportsOwed() }
    }

    /// Writes the reports owed on the file queue, so a write asked for before a log write lands before it; the file goes
    /// once none is owed. Not while the log waits for the first unlock (the file may be there, unread) or could not be
    /// read: the log is not written then either, so nothing it held is gone from disk. A write that fails is tried again
    /// by the next log write, which waits for it (`persist`, codex-22).
    private func saveReportsOwed() {
        guard !loadFailed, !awaitingUnlock, !reportsOwedFrozen else { return }
        let owed = reportsOwed
        let url = reportsOwedURL
        let options = writeProtection
        ioQueue.async { [weak self] in _ = self?.writeReportsOwedOnQueue(owed, to: url, options: options) }
    }

    /// Writes `owed` (or removes the file when none is owed) and records it as what is on disk; false when that failed.
    nonisolated private func writeReportsOwedOnQueue(_ owed: [OwedReport], to url: URL, options: Data.WritingOptions) -> Bool {
        do {
            if owed.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try JSONEncoder().encode(owed).write(to: url, options: options)
            }
            reportsOwedOnDisk.set(owed)
            return true
        } catch {
            Log.store.error("Failed to save the reports owed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            return false
        }
    }

    /// At launch and after the unlock reload, before the journal's recovery and the log's trims, which may owe reports of
    /// their own and write the file (codex-22): the reports a launch before still owed, kept for the report as the launch
    /// trims are (`handOverUnreported`). A file that cannot be read is set aside, never taken for none and written over.
    private func loadReportsOwed() {
        guard !awaitingUnlock else { return }
        let url = reportsOwedURL
        var stored: [OwedReport] = []
        if fileManager.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let decoded = try? StoredJSON.decode([OwedReport].self, from: data) {
                stored = decoded
            } else {
                setReportsOwedAside(url)
            }
        }
        if !reportsOwedFrozen {
            let onDisk = stored
            ioQueue.async { [weak self] in self?.reportsOwedOnDisk.set(onDisk) }
        }
        let known = Set(reportsOwed.map(\.id))
        for report in stored where !known.contains(report.id) {
            reportsOwed.append(report)
            unreportedEvictions.append((report.events, report.watch, report.id))
        }
        dropReportsOwedForEventsHeld()
        if reportsOwed != stored { saveReportsOwed() }
        // Handed over only after the journal's recovery (codex-26): a report listening at an unlock would otherwise get one
        // for an incident the recovery then brings back (`reloadAfterUnlock` hands them over once it has run).
    }

    /// The journal can bring back an event a report is owed for: it is not lost, so its report is no longer owed.
    private func dropReportsOwedForEventsHeld() {
        let held = Set(events.map(\.id))
        guard reportsOwed.contains(where: { $0.events.contains { held.contains($0.id) } }) else { return }
        reportsOwed = reportsOwed.compactMap { report in
            let gone = report.events.filter { !held.contains($0.id) }
            return gone.isEmpty ? nil : OwedReport(id: report.id, events: gone, watch: report.watch)
        }
        let kept = Dictionary(reportsOwed.map { ($0.id, $0.events) }, uniquingKeysWith: { first, _ in first })
        unreportedEvictions = unreportedEvictions.compactMap { batch in
            kept[batch.owed].map { ($0, batch.watch, batch.owed) }
        }
        saveReportsOwed()
    }

    /// An unreadable file of reports owed, kept aside as a damaged log is (`setAside`): the reports start afresh. If it
    /// cannot even be moved, it is never written over, and a log that would drop an event whose report is owed waits.
    private func setReportsOwedAside(_ url: URL) {
        let backup = Self.setAsideURL(for: url)   // a name not yet taken (item 220's defect 4)
        if (try? fileManager.moveItem(at: url, to: backup)) == nil {
            reportsOwedFrozen = true
            Log.store.fault("reports-owed.json unreadable and could not be set aside; it is not written over")
        } else {
            Log.store.error("reports-owed.json unreadable; preserved as \(backup.lastPathComponent, privacy: .public)")
        }
    }

    /// A lighter copy for the marker's rule, which reads none of the evidence: the thumbnail and the
    /// Vision trace go; the motion and sound traces cannot be cleared and stay (at most 60 and 30
    /// samples as the monitors record them; a log written otherwise is not checked).
    nonisolated private static func lightCopy(_ event: Event) -> Event {
        var lite = event
        lite.thumbnailData = nil
        lite.visionTrace = nil
        return lite
    }

    /// Whether an event added now is recorded while iCloud backup is off (item 115); the engine
    /// supplies it. Such an event is marked `keptLocal` and never uploads.
    var keepsNewEventsLocal: () -> Bool = { false }

    /// Marks an event's upload as running: an incident's evidence, or a status entry's record
    /// (item 116, R5).
    func beginUpload(_ id: UUID) { uploadsInFlight[id, default: 0] += 1 }

    /// Ends one upload of the event. Once none are left, limits that waited for one apply again.
    func endUpload(_ id: UUID) {
        guard let running = uploadsInFlight[id] else { return }
        uploadsInFlight[id] = running > 1 ? running - 1 : nil
        guard uploadsInFlight.isEmpty else { return }
        applyLimitsThatWaited()
    }

    /// The limits again, when they waited for an upload or a held line; nothing when they did not wait.
    private func applyLimitsThatWaited() {
        guard limitsWaitForUploads else { return }
        limitsWaitForUploads = false
        let removedMedia = pruneToCountCap()
        persist()
        deleteMediaNames(removedMedia)   // after the checkpoint (34.H4), as in add()
        scheduleByteCapPrune()
    }

    /// The evidence signer's lines still owed their note (item 182; codex-3 on ba2e282e, the owner's "a"): the limit takes
    /// none of them, as it takes no record whose upload is running, so none leaves the log before the signer notes it
    /// written, and the limit's removal of one shows the log held it.
    private(set) var linesHeldForTheSigner: Set<UUID> = []

    /// Holds `ids`, the signer's owed lines, from the limit, in place of those held before; once one is let go, limits
    /// that waited apply again.
    func holdLinesForTheSigner(_ ids: Set<UUID>) {
        let letGo = !linesHeldForTheSigner.isSubset(of: ids)
        linesHeldForTheSigner = ids
        if letGo { applyLimitsThatWaited() }
    }

    /// Whether an upload of the event is running.
    func isUploading(_ id: UUID) -> Bool { uploadsInFlight[id] != nil }

    /// The events whose uploads are running: their account bindings are kept (item 153's MAL-08).
    var uploadsUnderWay: Set<UUID> { Set(uploadsInFlight.keys) }

    private var byteCapPruneRunning = false
    private var byteCapPruneRepeat = false

    /// Debounced trigger for the byte-cap prune. Kept OFF the trigger path (F-19): the
    /// prune stats up to ~1000 media files, which must not delay the sub-second fact push
    /// at capture time. Exactly one runner at a time; an add() that lands during a pass
    /// requests one more pass afterward, so nothing is missed and nothing runs twice (R-08).
    /// Also requested by every write that attaches media (`update`, recovery; Codex's V3).
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
    /// mutation happen on it. An event that changed while its files were measured (a late
    /// capture attached, its upload reopened) is left for the next pass, which judges it as it
    /// is now (item 140, A1).
    private func pruneMediaBytes() async {
        let dir = mediaDirectory
        let snapshot = events.map { (id: $0.id,
                                     isFlood: $0.sustainedCount != nil,
                                     isSynced: $0.cloudSyncState == .synced,
                                     media: [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 }) }
        var budget = Self.maxMediaBytes
        #if DEBUG
        if let mediaBudgetForTesting { budget = mediaBudgetForTesting }
        #endif
        let inFlight = Set(uploadsInFlight.keys)   // item 114: an upload's media waits for it to end
        let (evict, discarded, waited) = await Task.detached { () -> (Set<UUID>, Set<UUID>, Bool) in
            func size(_ name: String) -> Int64 {
                // A name that is not a plain file name names no file of the log's (item 187).
                guard let file = EventStore.mediaFile(named: name, in: dir) else { return 0 }
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                return (attrs?[.size] as? Int64) ?? 0
            }
            let sizes = snapshot.map { (id: $0.id, isFlood: $0.isFlood, isSynced: $0.isSynced,
                                        bytes: $0.media.reduce(Int64(0)) { $0 + size($1) }) }
            let order = EventStore.mediaEvictionOrder(sizes: sizes, budget: budget, inFlight: inFlight)
            let waited = !inFlight.isEmpty && sizes.reduce(Int64(0)) { $0 + $1.bytes } > budget
            return (order.evict, order.discardedBeforeUpload, waited)
        }.value
        #if DEBUG
        if let mediaMeasuredForTesting { await mediaMeasuredForTesting() }
        #endif
        if waited {
            // Over budget only with an upload's media: check again when it ends. If it ended while
            // the files were measured, nothing is left to call back: look again now (item 116, R7).
            if uploadsInFlight.isEmpty { byteCapPruneRepeat = true } else { limitsWaitForUploads = true }
        }
        guard !evict.isEmpty else { return }
        if !discarded.isEmpty {
            Log.store.warning("Storage emergency: discarded \(discarded.count, privacy: .public) event(s)' media before its current upload finished")
        }
        let measured = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        for idx in events.indices where evict.contains(events[idx].id) {
            // An upload that began while the files were measured keeps its media (item 114).
            guard uploadsInFlight[events[idx].id] == nil else { limitsWaitForUploads = true; continue }
            // Not as measured: a late capture attached, its upload reopened. Deleting now would take
            // evidence that never uploaded, unmarked; the next pass judges it as it is (item 140, A1).
            let now = events[idx]
            guard let was = measured[now.id],
                  was.media == [now.mediaFilename, now.secondaryMediaFilename].compactMap({ $0 }),
                  was.isSynced == (now.cloudSyncState == .synced),
                  was.isFlood == (now.sustainedCount != nil) else {
                byteCapPruneRepeat = true
                continue
            }
            if let n = events[idx].mediaFilename { names.append(n) }
            if let n = events[idx].secondaryMediaFilename { names.append(n) }
            events[idx].mediaFilename = nil
            events[idx].secondaryMediaFilename = nil
            // The badge and detail view must not read a later meta-only retry as everything
            // having made it (34.H5): a capture none of whose files is known to have reached iCloud
            // (item 166's codex-23: part of a capture there keeps its download) is marked lost
            // once iCloud, asked at the engine's sweep, holds none of them (codex-24).
            if discarded.contains(events[idx].id), (events[idx].uploadedMedia ?? []).isEmpty {
                if discardNeedsCheck(events[idx]) {
                    events[idx].mediaDiscardUnchecked = true
                } else {
                    events[idx].mediaDiscarded = true   // it can never have gone up: lost, as before
                }
            }
        }
        persist()
        deleteMediaNames(names)   // after the checkpoint (34.H4): references drop before files
    }

    /// Pure (unit-tested): given events newest-first with their on-disk media sizes, which
    /// events' media to free to get under `budget` — and, separately, which evicted genuine captures are not
    /// currently synced. The caller reconciles receipts and cloud presence before deciding whether the capture
    /// was lost, so a metadata-only retry cannot imply that missing evidence is backed up (34.H5).
    ///
    /// Order of loss: coalesced flood media first (synthetic noise), then synced media
    /// oldest-first (locally it is a cache — the cloud holds it and it can be re-downloaded),
    /// and only in a genuine storage emergency the oldest still-pending media.
    /// Media whose upload is running is neither counted nor taken, so no newer pending media goes
    /// in its place; the store prunes again when the upload ends (item 114, from item 108's F5).
    nonisolated static func mediaEvictionOrder(
        sizes allSizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)],
        budget: Int64, inFlight: Set<UUID> = []
    ) -> (evict: Set<UUID>, discardedBeforeUpload: Set<UUID>) {
        let sizes = allSizes.filter { !inFlight.contains($0.id) }
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
        // Flood media is deliberately expendable and synced media is treated as a cloud-backed cache.
        // Unsynced genuine captures need the caller's receipt/presence decision before loss is recorded.
        let discarded = Set(sizes.filter { evict.contains($0.id) && !$0.isSynced && !$0.isFlood }
                                 .map { $0.id })
        return (evict, discarded)
    }

    private func deleteMedia(for events: [Event]) {
        deleteMediaNames(events.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
    }

    /// Deletes media files on the ioQueue — off the main actor, consistent with the
    /// rest of the store's file I/O. Every limit and eviction deletes through here, and a file a
    /// set-aside log may refer to is kept (item 120, Codex's V1; ADR 0048): the journal and an
    /// attachment intent can bring an event back, with its photo, after its log was set aside,
    /// and the limits would then delete evidence the set-aside log keeps. A file goes only once the
    /// write that drops its reference has succeeded (item 165's A1).
    private func deleteMediaNames(_ names: [String]) {
        guard !names.isEmpty else { return }
        ioQueue.async { [self] in
            // Only once the log that drops them is down (34.H4): after a failed write the log on disk still names them,
            // so they wait for the next write that succeeds (item 165's A1). The queue is serial, so the flag is the
            // outcome of the write each caller queued just before.
            if persistFailedOnQueue.get() {
                mediaOwedDeletion.update { $0.formUnion(names) }
                return
            }
            removeMediaOnQueue(names)
        }
    }

    /// Deletes media files, on `ioQueue`, except those a set-aside log may refer to, and never by a name that is not a
    /// plain file name (`mediaFile(named:in:)`, item 187): such a name names no file of the log's. Only a plain file
    /// goes, and none while the media folder is not a real folder (item 218's Codex-1, Claude's inventory of its shape):
    /// a folder an edited backup put under a photo's name went with everything in it, and a link in the media folder's
    /// place was followed into another folder.
    nonisolated private func removeMediaOnQueue(_ names: [String]) {
        let dir = Self.mediaDirectoryURL(in: root)
        guard Self.realDirectory(dir) else {
            if !names.isEmpty { Log.store.fault("Deleted no media: the media folder is not a real folder") }
            return
        }
        let kept = Self.mediaNamesSetAsideLogsMayReference(names, in: Self.ensured(root))
        if !kept.isEmpty {
            Log.store.info("Kept \(kept.count, privacy: .public) media file(s) a set-aside log refers to")
        }
        var refused = 0
        for name in names where !kept.contains(name) {
            guard let file = Self.mediaFile(named: name, in: dir), Self.isPlainFileOrNothing(file) else {
                refused += 1
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
        if refused > 0 {
            Log.store.fault("Deleted no file for \(refused, privacy: .public) media name(s) that name no plain file")
        }
    }

    /// After a write that succeeded, on `ioQueue`: the media owed deletion (item 165's A1) that the log just written no
    /// longer names goes now.
    nonisolated private func removeMediaOwedDeletion(notNamedIn snapshot: [Event]) {
        let waiting = mediaOwedDeletion.get()
        guard !waiting.isEmpty else { return }
        let named = Set(snapshot.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
        let owed = waiting.subtracting(named)
        mediaOwedDeletion.set([])
        removeMediaOnQueue(Array(owed))
    }

    /// Which of `names` a set-aside event log (`events.corrupt-*`) may refer to: each name whose
    /// bytes appear in one, and all of them when the folder or a set-aside log cannot be read. A
    /// set-aside log does not decode, so its bytes are searched (item 120, V1).
    /// They are searched as written and with a JSON escape read (item 230: `SetAsideLog.searchForms`), since
    /// the log's screen decodes its records. That finds every spelling of a name the store gives
    /// (`isStoredMediaName`), which is the only kind a set-aside log names (item 231's Codex-10). A name of
    /// another form that a log's bytes happen to have is still kept here, which is more than that rule asks:
    /// this search never removes, and the limits' removals ask it for any name a row of the log has.
    /// Only a plain file is opened (item 218's rule for Codex-1, which this search had been left out of): a link
    /// or a folder under a set-aside log's name is not read, wherever it leads, and keeps every name, as an entry
    /// that cannot be read does.
    nonisolated static func mediaNamesSetAsideLogsMayReference(_ names: [String], in root: URL) -> Set<String> {
        mediaNamesSetAsideLogsReference(names, in: root) ?? Set(names)
    }

    /// The search behind `mediaNamesSetAsideLogsMayReference`: which of `names` appear in a set-aside log's bytes, and
    /// nil where that one answers every name, because the folder, or an entry named like a set-aside log, cannot be
    /// read as a plain file. A set-aside log's Delete asks this one, to say that it could not tell which photos and
    /// clips were only the deleted log's (item 227's DS-5).
    nonisolated static func mediaNamesSetAsideLogsReference(_ names: [String], in root: URL) -> Set<String>? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        var kept: Set<String> = []
        for entry in entries where entry.hasPrefix("events.corrupt-") {
            let url = root.appendingPathComponent(entry)
            guard isPlainFile(url), let data = try? Data(contentsOf: url) else { return nil }
            let forms = SetAsideLog.searchForms(of: data)
            for name in names where !kept.contains(name) && SetAsideLog.names(name, in: forms) {
                kept.insert(name)
            }
        }
        return kept
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
    /// while any `events.corrupt-*.json` backup exists or the folder cannot be listed (after a
    /// corruption, unreferenced media may be real evidence whose metadata was lost — the F-11
    /// backup is the tombstone that says so, and since item 120 it is never deleted
    /// automatically, so true leaks stay too), touches only files this store named (UUID basenames, the tmp sweeper's
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
                  let persisted = try? StoredJSON.decode([Event].self, from: data) else { return }
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
            // A folder that cannot be listed might hold a set-aside log: sweep nothing.
            guard let rootNames = try? fm.contentsOfDirectory(atPath: root.path) else { return }
            // A set-aside log is never deleted automatically (item 120, F5; build 70's stopgap).
            // Since the seventh review (#6) a launch deleted one 30 days old, or once three newer
            // ones existed, and this sweep then deleted every photo and clip only it referred to.
            // Now each is kept with its media, and while one exists the sweep deletes nothing.
            // Reading one record by record and sharing it are item 122 (1.8).
            let corruptBackupPresent = rootNames.contains { $0.hasPrefix("events.corrupt-") }
            let dir = Self.mediaDirectoryURL(in: storeRoot)
            // Only in a real folder, and only plain files (item 218's Codex-1, Claude's inventory of its shape): a
            // folder an edited backup put under a photo's name went with everything in it. Where probed, Foundation's
            // listing by URL lists nothing through a link in the folder's place; the rule here does not rest on that.
            guard Self.realDirectory(dir) else { return }
            let onDisk: [(name: String, modified: Date)] = ((try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []).compactMap { url in
                    guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                          Self.isPlainFile(url),
                          let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                              .contentModificationDate
                    else { return nil }   // not ours, not a plain file, or unreadable — never sweep what we can't judge
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
    /// `maxAge`, plus anything beyond the `keepNewest` most recent regardless of age. Used for
    /// the settings stashes (`AppSettings`), which otherwise accumulated without bound (seventh
    /// review, #6). Set-aside event logs no longer use it: they and their media are kept
    /// (item 120, F5). A future-dated stamp reads as young: kept, same clock-weirdness rule as
    /// the sweep's. Of two of one second the later is the newer, by the number after the seconds
    /// in its name (`corruptArtifactOrder`; item 220): by the time alone, which of the two was
    /// reaped depended on the order they were found in, and could be the one just made.
    nonisolated static func reapableCorruptArtifacts(stamps: [(name: String, date: Date)],
                                                     now: Date,
                                                     keepNewest: Int = 3,
                                                     maxAge: TimeInterval = 30 * 86_400) -> [String] {
        stamps.sorted {
            ($0.date, corruptArtifactOrder($0.name)) > ($1.date, corruptArtifactOrder($1.name))
        }.enumerated().compactMap { idx, s in
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

    /// Pure (unit-tested): a set-aside file's place among those of its second, from its name: 1 for the plain name, the
    /// number after the seconds for a later one (`setAsideURL`: `-2`, `-3` and so on). So that the list of set-aside
    /// logs is newest first within a second too (item 220's defect 4).
    nonisolated static func corruptArtifactOrder(_ name: String) -> Int {
        guard let range = name.range(of: "corrupt-") else { return 1 }
        let afterSeconds = name[range.upperBound...].drop { $0.isNumber }
        guard afterSeconds.first == "-" else { return 1 }
        return Int(afterSeconds.dropFirst().prefix { $0.isNumber }) ?? 1
    }

    /// Where a file that cannot be read is set aside: beside it, as `<name>.corrupt-<seconds>.json`, the seconds those of
    /// `now`. While a name of that second is already there, a number follows the seconds, `-2`, `-3` and so on (item
    /// 220's defect 4): two set-asides in one second, or the clock set back to the second of a set-aside log still kept,
    /// left the second file unmoved, and the store then wrote nothing until the next launch. The number is the one after
    /// the LAST name taken of that second, never a lower one that is free again (item 226's Codex-6): it is the order
    /// the files of a second were made in, which the list of set-aside logs and the reaping of settings stashes go by,
    /// and a name given a second time counted as the oldest. The name starts as every set-aside's does and still gives
    /// its time (`corruptArtifactDate`). When the last of `tries` names is taken it is the plain one: while that is
    /// taken too, the move fails as it did. `taken` is asked of the entry itself, so a link that leads nowhere counts.
    nonisolated static func setAsideURL(
        for url: URL, now: Date = Date(), tries: Int = 100,
        taken: (URL) -> Bool = { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }
    ) -> URL {
        let seconds = Int(now.timeIntervalSince1970)
        let base = url.deletingPathExtension()
        func name(_ number: Int) -> URL {
            base.appendingPathExtension(number == 1 ? "corrupt-\(seconds).json" : "corrupt-\(seconds)-\(number).json")
        }
        let last = max(2, tries)
        guard let lastTaken = (1...last).last(where: { taken(name($0)) }) else { return name(1) }
        return lastTaken < last ? name(lastTaken + 1) : name(1)
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
    /// Called as each append's full sync lands: what had reached the medium before the line (item 153's MAL-07).
    var journalSyncObserverForTesting: (() -> Void)?
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
    /// The line starts on a line of its own: after a torn last line (an append cut by a power
    /// cut or a forced restart, or a partial write), it used to be written straight after the
    /// fragment, so neither decoded, and the event rested on the async log write alone until a
    /// checkpoint shed the fragment (item 129, F1).
    /// An event that does not encode has no line, and that is an append that failed, said on Home as
    /// any other (item 220's defect 3): it used to be passed over without a word. The log's own write
    /// of such an event fails too, and says so itself.
    private func appendToJournal(_ event: Event) {
        guard var line = Self.journalLine(for: event) else {
            journalDegraded = true
            if !journalFailureLogged {
                journalFailureLogged = true
                Log.store.error("Journal append failed: the event did not encode — birth records fall back to the async log write")
            }
            return
        }
        let url = journalFile
        var appended = false
        var sync: (synced: Bool, errno: Int32, elapsed: Duration)?
        #if DEBUG
        let openFails = Self.journalOpenFailsForTesting
        #else
        let openFails = false
        #endif
        if !openFails, let handle = try? FileHandle(forUpdating: url) {
            if let end = try? handle.seekToEnd(), end > 0, (try? handle.seek(toOffset: end - 1)) != nil,
               let last = try? handle.read(upToCount: 1), last.first != 0x0A {
                line.insert(0x0A, at: 0)
            }
            appended = ((try? handle.seekToEnd()) != nil) && ((try? handle.write(contentsOf: line)) != nil)
            if appended { sync = Self.fullSync(handle) } else { try? handle.close() }
        } else {
            // Only a journal that is not there yet is made here: one that could not be opened is never written over, or
            // the lines the log has not taken yet would be lost (item 187, qwen-5 on 09d997f). The append then fails.
            appended = (try? line.write(to: url, options: [.completeFileProtectionUnlessOpen, .withoutOverwriting])) != nil
            // First line of a fresh file: the write created it; reopen for the barrier.
            if appended, let handle = try? FileHandle(forWritingTo: url) { sync = Self.fullSync(handle) }
        }
        if appended {
            journalHasEntries = true
            journalDegraded = !(sync?.synced ?? false)   // a full sync that failed is a promise that does not hold (item 73, R6)
            if let sync, sync.synced {
                #if DEBUG
                journalFullSyncsForTesting += 1
                journalSyncObserverForTesting?()
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
            .compactMap { try? StoredJSON.decode(Event.self, from: Data($0)) }
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
        let unheld = Self.journaledEvents(in: data).filter { !known.contains($0.id) }
        // A row the limit removed after its write landed, its line not yet retired at a kill, is not a write that never
        // landed: never brought back, its removal kept for the signer, its line retired (codex-1 on 995f7d98).
        let removedByTheLimit = Set(unheld.lazy.map(\.id).filter { self.limitRemovalsAsRemoved[$0] != nil })
        let missing = unheld.filter { !removedByTheLimit.contains($0.id) }
        guard !missing.isEmpty || !removedByTheLimit.isEmpty else { return }
        var retired = removedByTheLimit
        var removedMedia: [String] = []
        if !missing.isEmpty {
            // The journal holds them as they came, the oldest first; the log puts the newest first (codex-1 on
            // 995f7d98).
            events = Self.merged(local: events, incoming: Array(missing.reversed()))
            let beforePrune = Set(events.map(\.id))
            removedMedia = pruneToCountCap()
            // A recovered line whose event the cap immediately re-evicts must still retire
            // (ext-review #3's second path): it used to survive every checkpoint, so each
            // launch resurrected it, evicted it again, and left the line — churn forever and
            // an unbounded journal. Retired only via the SUCCESS path of the persist that
            // durably records the absence; a failed persist keeps the line, the safe direction.
            // Include previously known rows removed by an upgrade, not only recovered
            // rows: their journal lines must not resurrect on another launch either.
            retired.formUnion(beforePrune.subtracting(events.map(\.id)))
        }
        persist(alsoRetiring: retired)
        deleteMediaNames(removedMedia)
        if !missing.isEmpty {
            Log.store.warning("Recovered \(missing.count, privacy: .public) event(s) from the journal — their log write never landed")
        }
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

    /// The journal lines owed retirement: the rows a write's limit, the recovery or the load removed, kept until a
    /// checkpoint has retired them, across failed writes and failed syncs, and handed to every write until then
    /// (codex-2 on 995f7d98, the owner's "a").
    private var journalRetirementsOwed: Set<UUID> = []

    /// The removals the signer accounted for while their journal lines were owed retirement: forgotten once retired
    /// (codex-1 on 995f7d98).
    private var limitRemovalsForgottenOnRetirement: Set<UUID> = []

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
        guard journalHasEntries else {
            journalRetirementsOwed.subtract(persistedIDs)   // no journal: no line left to retire
            forgetRemovalsNoLongerOwed()
            return
        }
        let logURL = metadataURL
        ioQueue.async { [weak self] in
            var synced = false
            if let handle = try? FileHandle(forWritingTo: logURL) {
                let result = Self.fullSync(handle)
                synced = result.synced
                #if DEBUG
                if Self.fullSyncFailsForTesting { synced = false }
                #endif
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
        guard journalHasEntries else {
            journalRetirementsOwed.subtract(persistedIDs)
            forgetRemovalsNoLongerOwed()
            return
        }
        let url = journalFile
        guard let data = try? Data(contentsOf: url) else { return }   // still owed
        let survivors = Self.journaledEvents(in: data).filter { !persistedIDs.contains($0.id) }
        if survivors.isEmpty {
            guard (try? FileManager.default.removeItem(at: url)) != nil else { return }   // still owed
            journalHasEntries = false
        } else {
            var out = Data()
            for event in survivors { if let line = Self.journalLine(for: event) { out.append(line) } }
            guard (try? out.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])) != nil else { return }
        }
        journalRetirementsOwed.subtract(persistedIDs)   // retired (codex-2 on 995f7d98)
        forgetRemovalsNoLongerOwed()
    }

    func update(_ event: Event, persistNow: Bool = true) {
        guard let idx = events.firstIndex(where: { $0.id == event.id }) else { return }
        let before = events[idx]
        events[idx] = Self.preservingMonotonicFields(current: before, incoming: event)
        if persistNow { persist() }
        // Media this write attaches counts toward the byte limit now, not at the next event or merge: a
        // capture, a retry, a late file, a download (item 129's F4; Codex's V3, BACKLOG 128).
        if Self.attachesMedia(before: before, after: events[idx]) { scheduleByteCapPrune() }
    }

    /// Pure: whether a write gives the event a media file it did not have.
    nonisolated static func attachesMedia(before: Event, after: Event) -> Bool {
        (after.mediaFilename != nil && after.mediaFilename != before.mediaFilename)
            || (after.secondaryMediaFilename != nil && after.secondaryMediaFilename != before.secondaryMediaFilename)
    }

    /// Pure (unit-tested): a whole-value update may never walk back fields that only move
    /// forward. Callers hold value copies of an event across async gaps — `respond()` holds
    /// one across the whole capture — and anything written to the STORED copy meanwhile
    /// (owner attribution at disarm, a sync state advanced by a completed push) was silently
    /// erased when the stale copy was written back (sixth-review F2). Attribution is
    /// monotonic at `true`; sync state reuses the exact `setSyncState` rule this write-back
    /// used to bypass. So is `keptLocal` (item 116, R1): `add` marks the stored copy of an
    /// event recorded while iCloud backup is off, and the response's own copy, written back
    /// when its capture ends, never had the mark.
    nonisolated static func preservingMonotonicFields(current: Event, incoming: Event) -> Event {
        var out = incoming
        if current.ownerAttributed == true { out.ownerAttributed = true }
        if current.keptLocal == true { out.keptLocal = true }
        // A capture's loss, and a check of it still owed, are not taken back by a copy from before them (codex-24).
        if current.mediaDiscarded == true { out.mediaDiscarded = true }
        if current.mediaDiscardUnchecked == true, out.mediaDiscarded != true { out.mediaDiscardUnchecked = true }
        // The camera files that reached iCloud only grow (item 166's codex-23), within one generation: a copy from before
        // iCloud's copies were found gone brings back none of the receipts that loss voided (item 174's codex-1).
        let generation = max(current.receiptEpoch ?? 0, incoming.receiptEpoch ?? 0)
        func receipts(_ event: Event) -> [String] { (event.receiptEpoch ?? 0) == generation ? event.uploadedMedia ?? [] : [] }
        let landed = receipts(incoming) + receipts(current).filter { !receipts(incoming).contains($0) }
        out.uploadedMedia = landed.isEmpty ? nil : landed
        out.receiptEpoch = generation == 0 ? nil : generation
        if !mayTransitionSyncState(from: current.cloudSyncState, to: incoming.cloudSyncState) {
            out.cloudSyncState = current.cloudSyncState
        }
        return out
    }

    /// iCloud's answer for a capture the byte cap discarded unchecked (item 166's codex-24): the camera files it holds
    /// become the capture's record of what landed; with none, and no receipt of a file that landed while it was asked
    /// (codex-27: an answer sampled before the file landed), the capture is marked lost, and a record
    /// already synced is reopened so the mark reaches iCloud and the other devices. `epoch` is the generation of the
    /// capture's receipts when iCloud was asked: an answer asked for before iCloud's copies were found gone is not taken,
    /// and the check stays owed for one asked for after (BACKLOG 176's codex-2).
    func resolveDiscardCheck(_ id: UUID, landed: Set<String>, epoch: Int?) {
        guard let idx = events.firstIndex(where: { $0.id == id }), events[idx].mediaDiscardUnchecked == true,
              (events[idx].receiptEpoch ?? 0) == (epoch ?? 0) else { return }
        events[idx].mediaDiscardUnchecked = nil
        let known = events[idx].uploadedMedia ?? []
        if landed.isEmpty, known.isEmpty {
            events[idx].mediaDiscarded = true
            if events[idx].cloudSyncState == .synced { events[idx].cloudSyncState = .pending }
        } else {
            events[idx].uploadedMedia = known + landed.sorted().filter { !known.contains($0) }
        }
        persist()
    }

    /// Whether a capture the byte cap discards with no record of a landed file needs iCloud asked before it is marked
    /// lost (item 166's codex-24); the engine supplies it. False for one that can never have gone up, marked at once.
    var discardNeedsCheck: (Event) -> Bool = { _ in true }

    /// The captures whose discard iCloud is still to be asked about (`resolveDiscardCheck`).
    var capturesAwaitingDiscardCheck: [Event] {
        events.filter { $0.mediaDiscardUnchecked == true && !$0.isMirrored }
    }

    /// A capture's full file reached iCloud (item 166's codex-23): its camera token is noted on this phone's own event, so
    /// the byte cap never marks the capture lost when part of it is in iCloud. `epoch` is the receipts'
    /// generation the upload began in (`Event.receiptEpoch`): a landing from before iCloud's copies were found gone is
    /// not noted, since it may have landed in the iCloud that was then wiped (item 174's codex-1).
    func noteMediaUploaded(_ token: String, for id: UUID, epoch: Int? = nil) {
        guard let idx = events.firstIndex(where: { $0.id == id }), !events[idx].isMirrored,
              (events[idx].receiptEpoch ?? 0) == (epoch ?? 0),
              !(events[idx].uploadedMedia ?? []).contains(token) else { return }
        events[idx].uploadedMedia = (events[idx].uploadedMedia ?? []) + [token]
        persist()
    }

    /// Flush the current in-memory log to disk. Used by callers that batched updates with
    /// `persistNow: false` (the flood coalescer, F2) and now need the final state durable.
    func flush() { persist() }

    /// Waits, `seconds` at most, for the writes already queued, the log's among them, to run: for a change with no
    /// journal line of its own (item 170's codex-2: a cancel that counts on its run's record). Answers whether the queue
    /// was through in time; only then can a kill after this not undo them, and a write that ran can still have been
    /// skipped or have failed (`persist`). Bounded (item 171), since a clip being stored ahead of the log's write holds
    /// the queue for seconds: the write then lands after the wait, and a kill before it loses it (item 172's codex-1).
    /// On the main actor, for the owner's own action, never on the trigger path.
    @discardableResult
    func waitForQueuedWrites(atMost seconds: TimeInterval) -> Bool {
        let through = DispatchSemaphore(value: 0)
        ioQueue.async { through.signal() }
        return through.wait(timeout: .now() + seconds) == .success
    }

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

    /// `update` and `reopenForReupload` as ONE write (item 155's S1, Codex's second look): a capture's completion
    /// writes the event's final state, media attached, and reopens it if a sparse upload during the capture marked
    /// it synced, in the same persisted snapshot. As two calls they were two queued writes, and the first put the
    /// media beside the synced state on disk: a kill between them left an event the sweep skipped and whose photo
    /// the byte cap deleted as a cloud-backed copy, unmarked. The monotonic rule applies as in `update`; the walk
    /// back from synced is the one `reopenForReupload` sanctions, for the same reason. Local captures only: a
    /// mirrored download is never reopened.
    func updateAndReopenForReupload(_ event: Event) {
        guard let idx = events.firstIndex(where: { $0.id == event.id }) else { return }
        let before = events[idx]
        var merged = Self.preservingMonotonicFields(current: before, incoming: event)
        if merged.cloudSyncState == .synced { merged.cloudSyncState = .pending }
        events[idx] = merged
        persist()
        if Self.attachesMedia(before: before, after: merged) { scheduleByteCapPrune() }   // as `update` does
    }

    /// Requeues every synced event for re-upload after an iCloud encrypted-data reset
    /// (34.H13): Apple purged the cloud copies, so "synced" is no longer true of any of
    /// them. This is the one sanctioned path around the monotonic sync-state guard — the
    /// guard exists so a late duplicate's FAILURE can't walk a synced event back; this is
    /// the opposite case, a deliberate global truth-restoration. Returns how many changed.
    @discardableResult
    func requeueAllForReupload() -> Int {
        requeueForReupload { _ in true }
    }

    /// `requeueAllForReupload` for the events `picked` chooses (item 152's lead 13): the iCloud-copies check puts back
    /// only the records bound to the installation's verified account. Returns how many changed.
    @discardableResult
    func requeueForReupload(where picked: (Event) -> Bool) -> Int {
        let result = Self.requeuedForReupload(events, only: Set(events.filter(picked).map(\.id)))
        guard result.events != events else { return 0 }   // a receipt voided is saved too (item 174's codex-1)
        events = result.events
        persist()
        return result.changed
    }

    /// Pure (unit-tested): the log with every synced FIRST-HAND event returned to pending, and the
    /// upload receipts of every first-hand event it picks voided in a new generation, a partly
    /// uploaded capture's too (item 174's codex-1). A capture already pruned locally owes a new-generation loss check.
    /// Local-only and already-pending events keep their
    /// sync state — they are in the retry set regardless. Mirrors are excluded (eighth-review M4): the capturing device owns its
    /// evidence's re-upload, and re-publishing a mirror stamped this device's name — under
    /// `.allKeys`, racing the capturing device's richer re-upload — falsified provenance
    /// and could regress the cloud copy. The accepted residue: if the capturing device is
    /// gone, its mirrored copies stay local after an encrypted-data reset. `only`, when given, limits it to those
    /// events (item 152's lead 13).
    nonisolated static func requeuedForReupload(_ events: [Event], only: Set<UUID>? = nil) -> (events: [Event], changed: Int) {
        var changed = 0
        let out = events.map { e -> Event in
            guard !e.isMirrored, only?.contains(e.id) ?? true else { return e }
            var copy = e
            // iCloud's copies are gone, so what this phone noted as landed no longer says what iCloud holds, for a
            // partly uploaded capture as for a synced one (item 174's codex-1): void, in a new generation that no older
            // copy and no earlier upload's report can bring back.
            copy.uploadedMedia = nil
            copy.receiptEpoch = (e.receiptEpoch ?? 0) + 1
            // A capture already pruned while synced no longer has its local files or a current cloud receipt.
            // Owe the existing account-bound check in this generation before deciding whether its capture is lost.
            if e.mediaFilename == nil, e.secondaryMediaFilename == nil, e.mediaDiscarded != true,
               e.primaryCamera != nil || e.secondaryCamera != nil {
                copy.mediaDiscardUnchecked = true
            }
            if e.cloudSyncState == .synced {
                copy.cloudSyncState = .pending
                changed += 1
            }
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

    /// The event's photo or clip file, for its screen, Share and an upload: nil without one, when its name is not a plain
    /// file name (`mediaFile(named:in:)`), or when what is under it is not a plain file, a link or a folder an edited
    /// backup put there (item 190's deepseek-5; the export's bundle already took none). A name with nothing under it yet
    /// keeps its URL, for the callers that look.
    func mediaURL(for event: Event) -> URL? {
        guard let name = event.mediaFilename, let url = Self.mediaFile(named: name, in: mediaDirectory) else { return nil }
        return Self.isPlainFileOrNothing(url) ? url : nil
    }

    /// The event's second camera's file, as `mediaURL(for:)`.
    func secondaryMediaURL(for event: Event) -> URL? {
        guard let name = event.secondaryMediaFilename, let url = Self.mediaFile(named: name, in: mediaDirectory) else { return nil }
        return Self.isPlainFileOrNothing(url) ? url : nil
    }

    /// A set-aside record's photo or clip file, for its screen (item 122): as `mediaURL(for:)`, and nil while the media
    /// folder is not a real folder, as a set-aside log's Share and Delete have it (ADR 0078's decision 5). The screen
    /// showed the file through a link an edited backup had put in the folder's place (item 226's Codex-5): the file was
    /// asked, the folder was not. A live event's screen, its Share and its upload still read through `mediaURL(for:)`
    /// (the owner's ruling of 2026-11-10; BACKLOG item 224's point 7). And nil for a name the store never gives
    /// (`isStoredMediaName`, item 231's Codex-10): a set-aside log names no file by one, here as in its Share and its
    /// Delete, so the screen shows the record's thumbnail only, as for a name that is not a plain file name.
    func setAsideMediaURL(for event: Event) -> URL? {
        guard Self.realDirectory(mediaDirectory), let name = event.mediaFilename, Self.isStoredMediaName(name) else { return nil }
        return mediaURL(for: event)
    }

    /// A set-aside record's second camera's file, as `setAsideMediaURL(for:)`.
    func setAsideSecondaryMediaURL(for event: Event) -> URL? {
        guard Self.realDirectory(mediaDirectory), let name = event.secondaryMediaFilename, Self.isStoredMediaName(name) else {
            return nil
        }
        return secondaryMediaURL(for: event)
    }

    /// Whether what is at `url` is a plain file, or nothing: its own attributes, a link's never followed (item 190).
    nonisolated static func isPlainFileOrNothing(_ url: URL) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else {
            return true
        }
        return type == .typeRegular
    }

    /// Whether what is at `url` is a plain file: its own attributes, a link's never followed, and a folder is not one.
    /// The rule for a set-aside log and for each photo or clip it names, in its list and its Share, and for the
    /// launch's sweep (item 218's Codex-1): only an edited backup restored to the phone puts a link or a folder where
    /// the app keeps a file. It answers no for what could not be looked at, too; a set-aside log's Delete, which must
    /// tell that apart, asks `look(at:)` (item 228).
    nonisolated static func isPlainFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// What a look at a path found, by its own attributes, a link's never followed.
    enum Looked: Sendable {
        /// A plain file.
        case plainFile
        /// Something else: a folder, a link.
        case notAPlainFile
        /// Nothing under that name.
        case nothing
        /// The look itself failed (the folder it is in cannot be searched, say): what is there is not known.
        case notKnown
    }

    /// What is at `url`: `isPlainFile`'s look, with its three ways of not being a plain file told apart (item 228's
    /// Codex-7 and Codex-8). A set-aside log's Delete needs them apart to say what it did: nothing under a log's name
    /// is a log already gone, and a look that failed is neither that nor a folder.
    nonisolated static func look(at url: URL) -> Looked {
        do {
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            return type == .typeRegular ? .plainFile : .notAPlainFile
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .nothing
        } catch {
            return .notKnown
        }
    }

    /// The file a photo's or clip's name from the log stands for in the media folder `directory`, when the name is a
    /// plain file name: not empty, not "." or "..", with no "/" and no NUL (which ends a name at the file system); nil for
    /// any other name, which names no file (item 187, deepseek-3 on 09d997f, the owner's "a"). The app names its files
    /// by UUID; only a log restored from an edited backup holds another name, and would otherwise lead the limit to delete,
    /// or an upload to send, a file outside the media folder, or the folder itself. The one rule for every path a name
    /// from the log becomes, the signer's and the export's included.
    nonisolated static func mediaFile(named name: String, in directory: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Whether `name` is a name the store gives a photo or clip: a UUID as `UUID().uuidString` writes it, in capitals,
    /// and ".jpg" or ".mov", byte for byte. Every build has given these names and no other (`store(_:ext:)`, and the
    /// attachment intents since they exist).
    ///
    /// The one rule for what a set-aside log names (item 231, Codex-10; the owner, 2026-11-11: "a, wording
    /// approved"): its record's screen shows, its Share carries and its Delete removes a file under such a name only.
    /// A set-aside log is searched for a name, not decoded, while its screen decodes its records, and the two must
    /// agree on what the log names. For a name of this form they do: JSON can write each of its characters as itself
    /// or as its unicode escape, the search reads both (`SetAsideLog.searchForms`), and no other text is the same name
    /// to the decoder or to a phone's file system, which tells capitals from lower case: plain digits, the letters
    /// here, hyphens and a dot have no equivalent form. For a wider name they did not: a quote's short escape and an
    /// accented letter as one character or as two each wrote one name two ways, so that Delete of one set-aside log
    /// took a photo another one's screen showed. A file under any other name is none of a set-aside log's. It stays;
    /// once no set-aside log is kept, the launch's sweep takes it if it has a UUID before its last dot and no record
    /// names it, and leaves it otherwise. A live event's screen, its Share and its upload read by
    /// `mediaFile(named:in:)` alone, as they did. One limit stays, on a volume that ignores case, which the
    /// Simulator's is and a phone's is not: there a row of the event log can name a set-aside log's photo in another
    /// case, and the app compares names.
    nonisolated static func isStoredMediaName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 40 else { return false }
        for (index, byte) in bytes[..<36].enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            default:
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte) else { return false }
            }
        }
        let ending = Array(bytes[36...])
        return ending == Array(".jpg".utf8) || ending == Array(".mov".utf8)
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
        /// The waiting clip's own file name, when the clip waits where the camera leaves it: a save that a refusal left
        /// undone runs again from it at the next launch or deferred load (1.8.2's step 63; BACKLOG 176).
        var source: String?
    }

    nonisolated private var attachmentDirectory: URL { root.appendingPathComponent("MediaAttachments") }
    /// The attachment folder's limit. A save is admitted with three entries free, for its manifest, its staging file and
    /// the temporary file that replaces the manifest (BACKLOG 176's codex-3).
    nonisolated private static let attachmentLimit = 1_200
    /// How far past its limit the folder is still read, so that one a kill left over it, under the earlier rule of two
    /// entries, is still recovered and cleaned rather than refused for good (codex-3).
    nonisolated private static let attachmentReadMargin = 8
    nonisolated private static let intentByteLimit: Int64 = 512_000

    /// Stores first-hand evidence with an explicit recovery destination. Pass the logged
    /// event and the capture's physical camera, slot and (for clips) duration. A protected,
    /// synced intent precedes publication of a completely saved file. Relaunch can attach
    /// that file even if the caller's update never runs. Unknown, mirrored, occupied or
    /// mismatched targets fail without consuming the source. Downloads keep using the
    /// context-free overload: their placement must be decided after awaiting the download.
    /// Retained staging payloads plus the incoming payload must fit the media byte cap;
    /// an overfull or unreadable staging area refuses admission before consuming the source.
    /// Returns nil on any storage failure; a save whose own file the recovery attached while
    /// it ran returns that file (BACKLOG 176's codex-1). This does not claim power-cut atomicity across
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
        var intent = AttachmentIntent(eventID: event.id, startDate: event.startDate, secondary: secondary,
                                      camera: camera, duration: duration, captureIssue: captureIssue, filename: UUID().uuidString + "." + ext)
        if case .clip(let url) = source, Self.waits(url) { intent.source = url.lastPathComponent }
        guard Self.accepts(intent, for: current) else { return nil }
        let pending = intent
        let stored: StoredMedia? = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.storeRecoverably(source, intent: pending))
            }
        }
        #if DEBUG
        if let stored { attachmentPublishedForTesting?(event.id, stored.filename) }
        #endif
        // Publication suspends the caller. A deletion/discard or another attachment during
        // that interval must not be undone by the late result. The durable intent remains
        // subject to these same checks at recovery; the saved bytes are not destroyed here.
        // The recovery attaching this very file meanwhile (a retry's, at launch) completes the
        // save rather than refusing it (BACKLOG 176's codex-1).
        guard let stored, let latest = events.first(where: { $0.id == event.id }) else { return nil }
        let slot = intent.secondary ? latest.secondaryMediaFilename : latest.mediaFilename
        guard slot == stored.filename || Self.accepts(intent, for: latest) else { return nil }
        return stored
    }

    nonisolated private static func accepts(_ intent: AttachmentIntent, for event: Event) -> Bool {
        // A capture the byte limit discarded takes no late file, marked lost or its check owed (item 166's codex-24).
        guard event.id == intent.eventID, event.startDate == intent.startDate,
              !event.isMirrored, !event.isStateChange, event.mediaDiscarded != true,
              event.mediaDiscardUnchecked != true else { return false }
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

    /// Whether what is at `url` is a real folder: its own attributes, so a link to a folder is not one. A set-aside
    /// log's Share asks it of the media folder too (item 218's Codex-1).
    nonisolated static func realDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory
    }

    /// Bounded capacity for pending slots and interrupted staging files. Enumeration and decoding are bounded; a
    /// directory more than a few entries past its limit, or unreadable, refuses new work and orphan deletion.
    nonisolated private func attachmentFiles() -> [URL]? { Self.attachmentFiles(in: root) }

    nonisolated private static func attachmentFiles(in root: URL) -> [URL]? {
        let attachmentDirectory = root.appendingPathComponent("MediaAttachments")
        guard realDirectory(root), realDirectory(attachmentDirectory) else { return nil }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: attachmentDirectory,
            includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard files.count < attachmentLimit + attachmentReadMargin else { return nil }
            files.append(url)
        }
        return failed ? nil : files
    }

    nonisolated private func readIntent(_ url: URL) -> AttachmentIntent? {
        guard Self.mayBeIntent(url), let data = try? Data(contentsOf: url) else { return nil }
        return Self.validIntent(data, at: url)
    }

    /// A file whose name and size an intent's could be: a regular `<UUID>.json` within the intent's byte limit.
    nonisolated private static func mayBeIntent(_ url: URL) -> Bool {
        guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              let size = regularSize(url), size <= intentByteLimit else { return false }
        return true
    }

    nonisolated private static func validIntent(_ data: Data, at url: URL) -> AttachmentIntent? {
        guard let intent = try? StoredJSON.decode(AttachmentIntent.self, from: data), intent.version == 1,
              intent.camera == "front" || intent.camera == "rear",
              intent.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              intent.startDate.timeIntervalSinceReferenceDate.isFinite,
              intent.byteCount > 0, intent.byteCount <= maxMediaBytes,
              intent.filename == url.deletingPathExtension().lastPathComponent + ".jpg"
                || intent.filename == url.deletingPathExtension().lastPathComponent + ".mov",
              intent.filename.hasSuffix(".mov") || intent.duration == nil else { return nil }
        return intent
    }

    /// The file names of the clips the attachment intents name as waiting where the camera left them (1.8.2's step 63:
    /// a refused save leaves its clip there, and the next launch's `attachWaitingClips` saves it from its intent), read
    /// without loading the store, for the camera's launch sweep (BACKLOG 180's A3). Nil when the intents cannot all be
    /// read (they are sealed while the phone is locked, as every file of the store's is, or the folder is past its
    /// limit): the sweep must then remove nothing. A file that is not a valid intent names no clip, as the launch would
    /// not save from it either.
    nonisolated static func waitingClipNamesClaimedByIntents() -> Set<String>? {
        let root = resolvedRoot()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("MediaAttachments").path) else { return [] }
        guard let files = attachmentFiles(in: root) else { return nil }
        var names: Set<String> = []
        for url in files where mayBeIntent(url) {
            guard let data = try? Data(contentsOf: url) else { return nil }   // sealed or unreadable: it might name any
            if let source = validIntent(data, at: url)?.source { names.insert(source) }
        }
        return names
    }

    nonisolated private static func syncFile(_ url: URL) throws {
        #if DEBUG
        if sealedForTesting { throw CocoaError(.fileWriteNoPermission) }   // reopened by path (step 63)
        #endif
        let result = fullSync(try FileHandle(forWritingTo: url))
        guard result.synced else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Serial-queue admission for staging bytes, separate from pruning committed media.
    /// Count logical file lengths (including sparse files), never allocated blocks. Unknown
    /// sizes and links fail closed; a file is measured, never opened, since a phone locked
    /// past its grace period refuses to reopen one (1.8.2's step 63). Subtracting from the
    /// remaining budget avoids overflow. Refusal neither deletes evidence nor moves the incoming source.
    nonisolated private static func admitsStaging(incomingBytes: Int64, files: [URL]) -> Bool {
        guard incomingBytes > 0, incomingBytes <= maxMediaBytes else { return false }
        var remaining = maxMediaBytes
        for url in files where url.pathExtension == "pending" {
            guard let bytes = regularSize(url), bytes >= 0, bytes <= remaining else { return false }
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
              let files = attachmentFiles(), files.count <= Self.attachmentLimit - 3,
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
            // Each file is written and flushed through the handle that wrote it, never reopened by its path: a phone
            // locked past its grace period refuses that reopen, and the save failed there (1.8.2's step 63; the audit's
            // lead 7, reproduced on the owner's iPhone Air).
            try Self.writeSealed(JSONEncoder().encode(intent), to: manifest)
            switch source {
            case .still(let bytes):
                try Self.writeSealed(bytes, to: staged)
                intent.thumbnail = CameraController.thumbnail(from: bytes)
            case .clip(let url):
                // AVFoundation needs the movie's recognized suffix. The staging name is
                // intentionally .pending (not published evidence), which it cannot decode.
                // Read the finished source before moving it; publication and protection
                // still complete before this thumbnail or filename reaches the caller.
                intent.thumbnail = CameraController.videoThumbnail(from: url, duration: intent.duration)
                // Flushed, and raised to the store's protection, while it still waits where the camera left it, whose
                // protection a sealed phone still opens: a refusal leaves it there, whole, for the next launch, never
                // deleted (step 63). The move keeps the file and its protection.
                guard Self.fullSync(try FileHandle(forWritingTo: url)).synced else { throw CocoaError(.fileWriteUnknown) }
                try Self.raiseClipProtection(url)
                try fm.moveItem(at: url, to: staged)
            }
            #if DEBUG
            Self.stagedCopyForTesting?(staged)
            #endif
            guard Self.regularSize(staged) == intent.byteCount else { throw CocoaError(.fileReadCorruptFile) }
            let data = try JSONEncoder().encode(intent)
            guard data.count <= Self.intentByteLimit else { throw CocoaError(.fileWriteUnknown) }
            try Self.writeSealed(data, to: manifest)
            try fm.moveItem(at: staged, to: destination)
            return StoredMedia(filename: intent.filename, thumbnail: intent.thumbnail)
        } catch {
            // Keep the intent and any fully protected staging bytes for conservative cleanup.
            // No final filename was published, so recovery cannot mistake a partial write for success.
            Log.store.error("Recoverable media save failed: \(Log.ref(error), privacy: .public)")
            return nil
        }
    }

    /// Where the camera leaves its recordings (`CameraController.pendingClipsFolder`).
    nonisolated private static var waitingClipsFolder: URL {
        #if DEBUG
        if let pendingClipsFolderForTesting { return pendingClipsFolderForTesting }
        #endif
        return CameraController.pendingClipsFolder
    }

    /// Whether `url` is a recording waiting where the camera leaves it.
    nonisolated private static func waits(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == waitingClipsFolder.standardizedFileURL.path
            && isRecordingName(url.lastPathComponent)
    }

    /// Whether an intent's clip still waits where the camera left it (BACKLOG 180's codex-1): a clip that cannot be looked
    /// at counts as waiting, so its intent is kept rather than aged out.
    nonisolated private static func sourceStillWaits(_ intent: AttachmentIntent) -> Bool {
        guard let name = intent.source else { return false }
        let clip = waitingClipsFolder.appendingPathComponent(name)
        guard waits(clip) else { return false }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: clip.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch {
            return true
        }
    }

    /// A recording's own file name: a UUID and ".mov", with no path in it.
    nonisolated private static func isRecordingName(_ name: String) -> Bool {
        name.hasSuffix(".mov") && UUID(uuidString: String(name.dropLast(4))) != nil
    }

    /// Asks for an upload pass once the waiting-clip retry has attached a clip: its recovery can land after the launch's
    /// own pass chose its records (BACKLOG 176's codex-5). The engine supplies it, as for a late camera file.
    var mediaAttachedLate: () -> Void = {}

    /// 1.8.2's step 63: the saves a refusal left undone, run again from the clips still waiting where the camera left
    /// them, each from its own intent, which names the clip; what they publish the recovery then attaches, under the same
    /// checks as at launch, and an upload pass is asked for. Off the main actor, as any save; at launch and at the
    /// deferred load only (BACKLOG 176), when every clip it finds is from an earlier run of the app, whose capture has
    /// ended: at an unlock a capture could be saving, or still holding the event of a clip it could not save.
    private func attachWaitingClips() {
        guard !loadFailed, !awaitingUnlock else { return }
        ioQueue.async { [weak self] in
            guard let self, let files = self.attachmentFiles() else { return }
            let media = self.root.appendingPathComponent("Media")
            var saved = false
            for url in files {
                guard let intent = self.readIntent(url), let name = intent.source,
                      Self.regularSize(media.appendingPathComponent(intent.filename)) != intent.byteCount else { continue }
                let clip = Self.waitingClipsFolder.appendingPathComponent(name)
                guard Self.waits(clip), FileManager.default.fileExists(atPath: clip.path) else { continue }
                var retry = intent
                retry.thumbnail = nil
                if self.storeRecoverably(.clip(clip), intent: retry) != nil { saved = true }
            }
            guard saved else { return }
            Task { @MainActor [weak self] in
                if self?.recoverMediaAttachments() == true { self?.mediaAttachedLate() }
            }
        }
    }

    /// Reads only bounded local intents after log/journal recovery, also on deferred unlock.
    /// Applies enrichment to the current event, never replaces its other metadata. Conflicts,
    /// unknown identities, missing/partial media and corrupt intents remain unattached.
    /// Answers whether it attached any.
    @discardableResult
    private func recoverMediaAttachments() -> Bool {
        guard !loadFailed, !awaitingUnlock else { return false }
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
        if changed {
            persist()
            scheduleByteCapPrune()   // recovered media counts toward the byte limit too (Codex's V3)
        }
        return changed
    }

    /// Retires only intents whose matching attachment is in a fully synced snapshot. The
    /// caller must supply a just-written or freshly disk-decoded snapshot on ioQueue, with
    /// no intervening metadata writes. A failed write/sync keeps the recovery record. On a clean launch, abandoned entries
    /// age out after 30 days, with at most 1,207 directory entries (the limit and a few past it) examined per pass; while
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
            // A committed file still awaiting an eligible attachment is never aged out, nor the intent of a clip still
            // waiting where the camera left it: its retry saves from that intent (BACKLOG 180's codex-1).
            let recoverable = intent.flatMap { item in
                event.map { Self.accepts(item, for: $0)
                    && (Self.regularSize(root.appendingPathComponent("Media").appendingPathComponent(item.filename))
                        == item.byteCount || Self.sourceStillWaits(item)) }
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

    /// Removes the media file `filename` that a download stored and did not attach (item 194's codex-2, the owner's "a"):
    /// only a plain name in the media folder that no record names, so another capture's evidence is never touched.
    func discardUnattached(_ filename: String) {
        guard !events.contains(where: { $0.mediaFilename == filename || $0.secondaryMediaFilename == filename }),
              let file = Self.mediaFile(named: filename, in: mediaDirectory) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Writes `data` to `url` under the store's protection ("complete unless open"), flushing it through the descriptor
    /// that wrote it, then renames it into place, replacing any file there (1.8.2's step 63, the audit's lead 7): a phone
    /// locked past its grace period lets such a file be created and written, but refuses to reopen one by its path, and
    /// refuses to change its class (`protects`, step 64). A leftover from a kill before the rename is a UUID-named file
    /// of the same kind, which the 30-day clean-up retires.
    nonisolated private static func writeSealed(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var flushed = false
        #if targetEnvironment(simulator)
        // The Simulator keeps no Data Protection, as Foundation's protection options do not there: a class set on the
        // Mac's own volume seals with the Mac's screen lock, and the suite failed while the Mac was locked.
        let protected = true
        #else
        let protected = protects(descriptor)
        #endif
        if protected, (try? handle.write(contentsOf: data)) != nil {
            flushed = fullSync(handle).synced   // and closes it
        } else {
            try? handle.close()
        }
        #if DEBUG
        if killBeforeReplacingForTesting, FileManager.default.fileExists(atPath: url.path) { throw CocoaError(.fileWriteUnknown) }
        #endif
        guard flushed, rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Data Protection's "complete unless open" class (class B), as `fcntl`'s F_SETPROTECTIONCLASS takes it.
    nonisolated static let completeUnlessOpenClass: Int32 = 2

    /// Gives a file the writer has just created the store's protection, "complete unless open", through the descriptor
    /// that created it, and answers whether the file has it. A file that has it already, from the store's folder, is
    /// left as it is: a sealed phone refuses any change of a "complete unless open" file's class, even to the same class
    /// (the owner's iPhone Air, 2026-10-28: EPERM, BACKLOG 176's step 64), while a file of a weaker class still takes it.
    /// `currentClass` and `setClass` stand in for `fcntl` only in tests.
    nonisolated static func protects(_ descriptor: Int32,
                                     currentClass: (Int32) -> Int32 = { fcntl($0, F_GETPROTECTIONCLASS) },
                                     setClass: (Int32) -> Bool = {
                                         fcntl($0, F_SETPROTECTIONCLASS, EventStore.completeUnlessOpenClass) != -1
                                     }) -> Bool {
        currentClass(descriptor) == completeUnlessOpenClass || setClass(descriptor)
    }

    /// Raises a clip to the store's protection ("complete unless open"), in place.
    nonisolated private static func raiseClipProtection(_ url: URL) throws {
        #if DEBUG
        if clipProtectionRefusedForTesting { throw CocoaError(.fileWriteNoPermission) }
        #endif
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                              ofItemAtPath: url.path)
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
        journalRetirementsOwed.formUnion(alsoRetiring)   // owed until a checkpoint retires them, whatever this write does
        guard !loadFailed, !awaitingUnlock else { return }   // never overwrite an un-backed-up (R-05) or still-encrypted (V-01) log
        let retiring = journalRetirementsOwed
        let snapshot = events
        writesQueued += 1
        let writeNumber = writesQueued
        let url = metadataURL
        let options = writeProtection
        let cleanLoad = loadedCleanly
        let owed = reportsOwed
        let owedURL = reportsOwedURL
        let owedFrozen = reportsOwedFrozen
        let removals = limitRemovalsAsRemoved
        let removalsURL = limitRemovalsURL
        let removalsFrozen = limitRemovalsFrozen
        #if DEBUG
        let observer = Self.checkpointObserverForTesting   // read here, on the main actor (item 155's T1)
        let delay = Self.writeDelayForTesting
        #endif
        ioQueue.async { [weak self] in
            #if DEBUG
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            #endif
            guard let self else { return }
            do {
                // The limit's removals before the log that drops them (item 182): a write that fails is tried again by the
                // next log write, and never holds this one up.
                if !removalsFrozen, removals != self.limitRemovalsOnDisk.get() {
                    _ = self.writeLimitRemovalsOnQueue(removals, to: removalsURL, options: options)
                }
                // A log never drops an event whose report is owed until that report is on disk (item 166's A1, codex-22):
                // a write of the reports owed that failed is tried again here, and the log waits while it fails.
                if owed != self.reportsOwedOnDisk.get(), !(owedFrozen && owed.isEmpty) {
                    guard !owedFrozen, self.writeReportsOwedOnQueue(owed, to: owedURL, options: options) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: options)
                self.checkpointAttachments(persistedSnapshot: snapshot, cleanLoad: cleanLoad, logURL: url)
                self.removeMediaOwedDeletion(notNamedIn: snapshot)
                #if DEBUG
                observer?(self.root, snapshot, data)
                #endif
                if self.persistFailedOnQueue.get() {
                    self.persistFailedOnQueue.set(false)
                    Task { @MainActor in self.persistDegraded = false }
                }
                // This snapshot is durably on disk — its events' journal lines are now
                // redundant and can be retired (on the main actor, the journal's one writer).
                let persistedIDs = Set(snapshot.map(\.id)).union(retiring)
                Task { @MainActor in self.scheduleJournalCheckpoint(persistedIDs: persistedIDs) }
                // On disk: the signer may sign what it holds (item 90), on the main actor, never on the write's queue.
                Task { @MainActor in self.onDurableWrite?(writeNumber, snapshot) }
            } catch {
                Log.store.fault("Failed to persist event metadata: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                if !self.persistFailedOnQueue.get() {
                    self.persistFailedOnQueue.set(true)
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
        guard let decoded = try? StoredJSON.decode([Event].self, from: data) else {
            setAside(url)   // readable but undecodable: damaged, whatever the lock state
            return
        }
        // Copies from iCloud held to the limits a fresh one is read under: an older version saved them before 1.8.2's
        // step 32, and a refetch at the same revision does not replace them (codex-13 on 1.8.2). Written back when that
        // changed a row, so the disk no longer holds what was trimmed (codex-13's second look), once the journal and
        // the attachments are recovered (`writeBackBoundedCopies`, codex-18).
        let bounded = decoded.map(CloudExfiltrator.boundedCopy)
        events = bounded
        awaitingUnlock = false            // a successful read clears any deferred state
        loadedCleanly = true              // the in-memory log is the truth about the disk
        if bounded != decoded { boundedCopiesOwedAWrite = true }
    }

    /// Set by a load that held a copy to the limits: the log on disk still holds the copy as an older version saved it.
    private var boundedCopiesOwedAWrite = false

    /// Writes the log back when its load held a copy to the limits (codex-13's second look), after journal and
    /// attachment recovery (codex-18 on 1.8.2): a write's checkpoint ages out an attachment intent whose incident is
    /// not in what it writes, and before recovery an incident only the journal knows is not.
    private func writeBackBoundedCopies() {
        guard boundedCopiesOwedAWrite else { return }
        boundedCopiesOwedAWrite = false
        persist()
    }

    /// Lists the set-aside event logs in the store's folder again (item 122).
    func refreshSetAsideLogs() {
        setAsideLogs = SetAsideLog.all(in: Self.ensured(root))
    }

    /// Deletes a set-aside log at the owner's word, from its screen (item 122's decision 3 (a); the owner, 2026-11-07: the
    /// photos and clips only it names go at once), then lists the set-aside logs again. Only a plain file named
    /// `events.corrupt-…` in the store's own folder is deleted: not a folder or a link under such a name, which only an
    /// edited backup restored to the phone can put there (item 218's Codex-1). With it go, at once, the photos and clips
    /// under a name the store gives (`isStoredMediaName`, item 231) whose names its bytes have (as written, or with a
    /// JSON escape read: item 230) and that nothing else names (`mediaGoingWithASetAsideLog`), plain files in a real
    /// media folder only. A log whose bytes cannot be read goes
    /// alone: what it names is not known, and the launch's sweep takes those once nothing names them. On the store's
    /// own queue, as the sweep is. The names the event log has in memory
    /// are read before the queue's turn; a record added meanwhile names a new file, since photos and clips are named by
    /// fresh UUIDs, and no set-aside log can name it (Fable's note in item 213: this relies on those names staying
    /// fresh).
    ///
    /// Its answer says what happened (item 227's DS-5): `.notDeleted` when the log was not deleted, and then nothing
    /// was; `.deleted` when it went with each photo and clip only it names, or was gone already; `.deletedMediaLeft`
    /// when it went and Malinois could not tell which photos and clips were only its own, or could not remove one. Any
    /// answer but `.deleted` is kept in `setAsideDeletionsToTell`, for the Event Log to say until the owner dismisses it.
    func deleteSetAsideLog(_ log: SetAsideLog) async -> SetAsideLogDeletion {
        await deleteSetAsideLogReporting(log).outcome
    }

    /// `deleteSetAsideLog`, with what the status entry of the Delete says (item 234's A1): whether the log's file went
    /// by this call, how many records it had and how many photos and clips went with it. The app's Delete is the
    /// engine's (`MonitoringEngine.deleteSetAsideLog`), which writes that entry.
    func deleteSetAsideLogReporting(_ log: SetAsideLog) async -> SetAsideLogDeletionReport {
        let storeRoot = Self.ensured(root)
        guard log.id.hasPrefix(SetAsideLog.namePrefix),
              log.url.deletingLastPathComponent().resolvingSymlinksInPath().path == storeRoot.resolvingSymlinksInPath().path
        else {
            keepToTell(.notDeleted)
            return SetAsideLogDeletionReport(outcome: .notDeleted, removedLog: false, records: nil, mediaRemoved: 0)
        }
        let inMemory = Set(events.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
        let report = await withCheckedContinuation { (done: CheckedContinuation<SetAsideLogDeletionReport, Never>) in
            ioQueue.async { [self] in
                done.resume(returning: deleteSetAsideLogOnQueue(log.url, root: storeRoot, inMemory: inMemory))
            }
        }
        keepToTell(report.outcome)
        refreshSetAsideLogs()
        return report
    }

    /// Keeps a Delete's answer for the Event Log to say, each kind once: not a whole delete, which has nothing to tell
    /// and takes nothing away from what an earlier Delete left to tell.
    private func keepToTell(_ outcome: SetAsideLogDeletion) {
        guard outcome != .deleted, !setAsideDeletionsToTell.contains(outcome) else { return }
        setAsideDeletionsToTell.append(outcome)
    }

    /// The owner dismissed the Event Log's notice of `outcome`.
    func setAsideDeletionWasTold(_ outcome: SetAsideLogDeletion) {
        setAsideDeletionsToTell.removeAll { $0 == outcome }
    }

    /// `deleteSetAsideLog`'s work on the store's queue: the file first, so a failure leaves its photos and clips with it.
    /// Only a plain file is a set-aside log, and only plain files in a real media folder go with it (item 218's Codex-1):
    /// a folder under either name went with everything in it, a link's bytes are another file's, and a link in the media
    /// folder's place leads into another folder. A plain file that cannot be read still goes, alone. One that cannot
    /// even be looked at is not deleted, and is not taken for a log already gone (item 228's Codex-7). And only a file
    /// under a name the store gives goes with it (`isStoredMediaName`, item 231's Codex-10): a file under any other
    /// name is not the log's, stays, and is nothing to tell.
    ///
    /// Once the log is gone, each place where Malinois cannot tell which photos and clips are only its own, or cannot
    /// remove one, answers `.deletedMediaLeft` (item 227's DS-5): the log's bytes, the media folder's listing, the event
    /// log on disk, a capture's record or another set-aside log could not be read, something that is not a real folder
    /// is in the media folder's place, what is under a photo's name there could not be looked at (item 228's Codex-8),
    /// a link or a folder is where the event log is kept or a link where the captures still being saved are (item
    /// 229's Codex-9: nothing is asked through a link), or a removal failed. Each of these left the photos and clips
    /// without a word.
    nonisolated private func deleteSetAsideLogOnQueue(_ file: URL, root: URL, inMemory: Set<String>) -> SetAsideLogDeletionReport {
        let manager = FileManager.default
        // What the Delete's status entry says (item 234's A1), as far as this call got.
        var removedLog = false
        var records: Int?
        var removed = 0
        func answer(_ outcome: SetAsideLogDeletion) -> SetAsideLogDeletionReport {
            SetAsideLogDeletionReport(outcome: outcome, removedLog: removedLog, records: records, mediaRemoved: removed)
        }
        switch Self.look(at: file) {
        case .plainFile:
            break
        case .nothing:
            // The log is gone already (its Delete asked twice, the first still under way when the second was), which
            // is what was asked.
            return answer(.deleted)
        case .notAPlainFile, .notKnown:
            // A folder or a link there is not a set-aside log. And where the look failed, the log may well be there:
            // nothing is deleted, and that is not a log already gone (item 228's Codex-7).
            return answer(.notDeleted)
        }
        let bytes = try? Data(contentsOf: file)
        guard (try? manager.removeItem(at: file)) != nil else { return answer(.notDeleted) }
        removedLog = true
        guard let bytes else { return answer(.deletedMediaLeft) }
        records = SetAsideLog.reading(bytes).records.count
        let media = Self.mediaDirectoryURL(in: root)
        // The media folder is made whenever it is asked for, so what is not a real folder here is a link or a file in
        // its place: nothing is looked at through it, and what is left is not known.
        guard Self.realDirectory(media) else { return answer(.deletedMediaLeft) }
        guard let onPhone = try? manager.contentsOfDirectory(atPath: media.path) else { return answer(.deletedMediaLeft) }
        var named: [String] = []
        let forms = SetAsideLog.searchForms(of: bytes)
        // Only a file under a name the store gives is the log's (item 231's Codex-10): for such a name the search
        // finds every spelling, in this log and in the others. A name with a UUID before its last dot and anything
        // after it was taken too, and for those one log's spelling was found and another's was not.
        for name in onPhone where Self.isStoredMediaName(name) && SetAsideLog.names(name, in: forms) {
            switch Self.look(at: media.appendingPathComponent(name)) {
            case .plainFile:
                named.append(name)
            case .notAPlainFile, .nothing:
                // A folder or a link under a photo's name is no photo of the log's, and a file that went after the
                // listing is no longer on the phone.
                continue
            case .notKnown:
                // Whether this is a photo of the log's cannot be told, so nothing more is removed, and the owner is
                // told: it was passed over as if it were no file, and the delete counted as a whole one (item 228's
                // Codex-8).
                return answer(.deletedMediaLeft)
            }
        }
        guard !named.isEmpty else { return answer(.deleted) }
        guard let onDisk = Self.mediaNamedOnDisk(in: root) else { return answer(.deletedMediaLeft) }
        guard let saving = mediaNamedByCapturesBeingSaved() else { return answer(.deletedMediaLeft) }
        guard let otherLogs = Self.mediaNamesSetAsideLogsReference(named, in: root) else { return answer(.deletedMediaLeft) }
        let going = Self.mediaGoingWithASetAsideLog(named: named, inMemory: inMemory, onDisk: onDisk, otherLogs: otherLogs,
                                                    saving: saving)
        let left = going.filter { (try? manager.removeItem(at: media.appendingPathComponent($0))) == nil }
        Log.store.info("A set-aside log deleted at the owner's word, with \(going.count - left.count, privacy: .public) photo(s) and clip(s) only it named")
        removed = going.count - left.count
        return answer(left.isEmpty ? .deleted : .deletedMediaLeft)
    }

    /// Pure (unit-tested): which of `named`, the photos and clips a deleted set-aside log names, go with it (item 122): none the
    /// event log names, in memory or on disk; none another set-aside log may name; none a capture still being saved names;
    /// and none at all when the log on disk or a capture's record could not be read (nil).
    nonisolated static func mediaGoingWithASetAsideLog(named: [String], inMemory: Set<String>, onDisk: Set<String>?,
                                                       otherLogs: Set<String>, saving: Set<String>?) -> [String] {
        guard let onDisk, let saving else { return [] }
        return named.filter { !inMemory.contains($0) && !onDisk.contains($0) && !otherLogs.contains($0) && !saving.contains($0) }
    }

    /// The photos and clips the event log on disk names: none when nothing is under the log's name; nil when what is
    /// there cannot be read, cannot be looked at, or is not a plain file. A link there is not followed (item 229's
    /// Codex-9): `fileExists` followed one, and took a file it could not reach for no log, so that a photo that log
    /// names went with a set-aside log.
    nonisolated private static func mediaNamedOnDisk(in root: URL) -> Set<String>? {
        let url = root.appendingPathComponent("events.json")
        switch look(at: url) {
        case .nothing: return []
        case .notAPlainFile, .notKnown: return nil
        case .plainFile: break
        }
        guard let data = try? Data(contentsOf: url), let logged = try? StoredJSON.decode([Event].self, from: data) else { return nil }
        return Set(logged.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } })
    }

    /// The photos and clips a capture still being saved names, by its attachment intent: none when nothing is under
    /// their folder's name, so none is waiting; nil when the folder, or one of them, cannot be read. A link there is
    /// not followed (item 229, Codex-9's twin): `attachmentFiles` reads a real folder only, and `fileExists` had taken
    /// a link to a folder it could not reach for no folder.
    nonisolated private func mediaNamedByCapturesBeingSaved() -> Set<String>? {
        guard Self.look(at: root.appendingPathComponent("MediaAttachments")) != .nothing else { return [] }
        guard let files = attachmentFiles() else { return nil }
        var names: Set<String> = []
        for url in files where url.pathExtension == "json" {
            guard let intent = readIntent(url) else { return nil }
            names.insert(intent.filename)
        }
        return names
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
        // timestamped backup, then start fresh (F-11). Under a name not yet taken (item 220's defect 4): a second
        // set-aside in the same second as one still kept failed to move, and persistence stayed off until a relaunch.
        let backup = Self.setAsideURL(for: url)
        if (try? fileManager.moveItem(at: url, to: backup)) == nil {
            // Couldn't even preserve it — so refuse to overwrite it either (R-05).
            // persist() no-ops while this is set, and Home surfaces the frozen state.
            loadFailed = true
            Log.store.fault("events.json unreadable and un-backupable; persistence disabled to avoid data loss")
        } else {
            Log.store.error("events.json unreadable or corrupt; preserved as \(backup.lastPathComponent, privacy: .public)")
            logWasQuarantined = true   // Home says so (item 73, review 2 R2.2); the backup is kept (item 120, F5)
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
        isReadingHistory = true
        load()
        refreshSetAsideLogs()   // item 122: the one this load set aside among them
        let onDisk = events, writesAtLoad = writesQueued   // the log as read, for the signer (item 182, codex-3)
        noteTheLogRead(onDisk)
        loadReportsOwed()      // item 166's A1: before the recovery's and the reconciliation's trims (codex-22)
        loadLimitRemovals()    // item 182: before the recovery too, whose log write writes them (codex-3)
        recoverFromJournal()   // the protected file is readable now too (ADR 0005)
        isReadingHistory = false
        dropReportsOwedForEventsHeld()
        dropLimitRemovalsHeld()
        handOverUnreported()   // the reports still owed, now that the recovery has run (codex-26)
        recoverMediaAttachments()
        attachWaitingClips()   // step 63
        writeBackBoundedCopies()
        establishSeenMark()    // item 81: the history is known now; what was queued stays new
        // What the launch's recovery brought back from the journal while the removals could not be read is not brought
        // back if the limit removed it, as the recovery now does: its line retired (codex-1 on 995f7d98).
        let removedByTheLimit = Set(queued.lazy.map(\.id).filter { self.limitRemovalsAsRemoved[$0] != nil })
        let kept = queued.filter { !removedByTheLimit.contains($0.id) }
        guard !kept.isEmpty else {
            if !removedByTheLimit.isEmpty { persist(alsoRetiring: removedByTheLimit) }
            enforceCountCapsAfterLoad()
            handTheSignerTheLogRead(onDisk, writesAtLoad: writesAtLoad)
            return
        }
        events = Self.reconciledAfterUnlock(disk: events, queued: kept)
        let beforePrune = Set(events.map(\.id))
        let removedMedia = pruneToCountCap()
        persist(alsoRetiring: beforePrune.subtracting(events.map(\.id)).union(removedByTheLimit))
        deleteMediaNames(removedMedia)   // after the checkpoint (34.H4)
        scheduleByteCapPrune()
        Log.store.info("Reconciled \(kept.count, privacy: .public) queued event(s) with the log on unlock")
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

/// A value only one queue may touch (item 220's defect 2; the owner, 2026-11-09: "a for defect 2"). The store keeps a
/// few pieces of state for its file queue alone. Each was a field marked unsafe, whose confinement only its comment
/// stated, so a new use from another thread would have compiled, and raced. Here the value has one way in, and in
/// Debug builds, which the tests run, each use checks that it is on the queue named `label`: a use from anywhere else
/// is reported, to a test's own hook or by stopping (`QueueConfinement`). A Release build makes no check, and behaves
/// as the fields did. The queue is known by its name, which a value can take before its queue is made: two queues of
/// one name are not told apart (each store's file queue has the one name). Unchecked for the compiler in this one
/// place: the queue is what makes its uses one at a time.
final class QueueConfined<Value>: @unchecked Sendable {
    private var value: Value
    private let label: String

    /// - Parameter label: the name of the queue the value is confined to (`DispatchQueue(label:)`).
    init(_ value: Value, onQueueLabelled label: String) {
        self.value = value
        self.label = label
    }

    /// The value, on its queue.
    func get() -> Value {
        check()
        return value
    }

    /// Replaces the value, on its queue.
    func set(_ new: Value) {
        check()
        value = new
    }

    /// Changes the value in place, on its queue.
    func update<Result>(_ change: (inout Value) -> Result) -> Result {
        check()
        return change(&value)
    }

    /// In Debug builds: reports a use that is not on the value's queue.
    private func check() {
        #if DEBUG
        if String(cString: __dispatch_queue_get_label(nil)) != label { QueueConfinement.violated() }
        #endif
    }
}

/// What a use of a `QueueConfined` value off its queue does, in Debug builds: a test's hook when one is set, a stop
/// otherwise, so that the tests of anything that makes such a use fail where it is made.
enum QueueConfinement {
    #if DEBUG
    /// Test-only: called for a use off the queue, in place of the stop.
    nonisolated(unsafe) static var violationForTesting: (@Sendable () -> Void)?

    static func violated() {
        if let violationForTesting {
            violationForTesting()
        } else {
            preconditionFailure("a queue-confined value was used off its queue")
        }
    }
    #endif
}
