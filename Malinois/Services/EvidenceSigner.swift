//
//  EvidenceSigner.swift
//  Malinois
//
//  Signs this phone's records (BACKLOG item 90, phase 2; ADR 0065): each first-hand record first written after this
//  install's key was certified, at every revision, once the write of the log that holds it is on disk; never on a
//  trigger's path, and never touching the log: what it writes goes to its own file (`EvidenceSignatureFile`). The key
//  is made and certified at launch and whenever the app comes forward, until Apple answers; until then nothing is
//  signed, and the records written meanwhile stay unsigned. When the log's limit retires signed records, a signed
//  retention statement names their counters and their signatures leave the file. Any other signed record that leaves the
//  log is named in a signed absence statement, its signatures kept, and the event log is given one line saying so
//  (item 182; the owner's rulings of 2026-10-31, "a" and "1 - a, 2 - a, 3 - wording approved"). A signature App Attest
//  made that the file does not keep leaves a gap in its key's counters: a line the file refuses is held and written first
//  at the next signing turn, so only a stop of the app leaves one, and the key in use's are named in a signed unkept
//  statement at its next signature, or at its first pass when a build before this one left them (item 188, ADR 0073).
//

import DeviceCheck
import Foundation
import UIKit

/// What an export takes from the signature file (phase 4; ADR 0067): its entries in order, ending with the export
/// statement signed for this export (the signer makes none without one: item 187, deepseek-1).
struct EvidenceExportSnapshot: Equatable, Sendable {
    let entries: [EvidenceSignatureFile.Entry]
    /// Whether the last signature in `entries` is the export statement signed for this export: always, from the signer.
    let signedExport: Bool
}

/// The keys this install certified, kept where no edit of a backup reaches (item 190's A3, the owner's "a"): in the
/// order Apple certified them, and those the signature file was found to have lost and that were dealt with.
struct EvidenceKeyList: Codable, Equatable, Sendable {
    var certified: [Data] = []
    var accounted: [Data] = []
    /// The keys this install made, each noted before Apple was asked to certify it, not yet in `certified`: a key the
    /// signature file lists joins `certified` from here alone (item 190's codex-1 on b7702f5, the owner's "a").
    var made: [Data] = []
}

/// A list written before `made` (the builds of rounds 190A and 190B) decodes, with no key noted as made (item 190's
/// codex-1 and deepseek-5 on b7702f5): a key the file lists that such a list lacks stays off it, a limit of those
/// builds' development installs alone, none of them distributed (deepseek-2 on 424d8ce, the owner's "a").
extension EvidenceKeyList {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        certified = try container.decodeIfPresent([Data].self, forKey: .certified) ?? []
        accounted = try container.decodeIfPresent([Data].self, forKey: .accounted) ?? []
        made = try container.decodeIfPresent([Data].self, forKey: .made) ?? []
    }
}

/// Where the signer keeps its `EvidenceKeyList`: the Keychain, for this device only (`KeychainEvidenceKeyList`), or a
/// test's stand-in.
protocol EvidenceKeyListStore: Sendable {
    /// The list: empty when there is none, nil when it cannot be read now.
    func read() -> EvidenceKeyList?
    /// Keeps `list` in place of the one kept; false when it could not.
    func write(_ list: EvidenceKeyList) -> Bool
}

/// The list in the Keychain, for this device only and readable after the first unlock (`KeychainService`): no backup
/// restores it onto another iPhone, and none hands it to whoever edits the backup.
struct KeychainEvidenceKeyList: EvidenceKeyListStore {
    func read() -> EvidenceKeyList? { KeychainService.evidenceKeyList() }
    func write(_ list: EvidenceKeyList) -> Bool { KeychainService.setEvidenceKeyList(list) }
}

/// Why Share can or cannot offer a record's bundle now (item 200): the event's screen says why a share went without it.
enum EvidenceExportReadiness: Equatable, Sendable {
    /// The bundle can be offered.
    case ready
    /// This phone has no signature of the record: another device's copy, a record from before the first certification,
    /// or one not signed yet. No bundle is expected.
    case notSigned
    /// No certified key can sign the export: a new install or iPhone, or a key App Attest lost, until Apple certifies the next.
    case noCertifiedKey
    /// Not now: the signature file cannot be read, the log on disk is not compared yet in this launch, or a signed record
    /// it found gone is not named yet.
    case notNow
}

actor EvidenceSigner {
    private typealias Entry = EvidenceSignatureFile.Entry

    /// One signature of a record: its key and counter, for a retention statement, and what its revision signed.
    private struct RecordSignature {
        let key: Data
        let counter: UInt32
        let revision: Int64
        /// When the record started, as this revision signed it (milliseconds by the phone's clock).
        let startDate: Int64?
        /// The record's kind as this revision signed it: nil for an incident, the status entry's kind otherwise.
        let kind: String?
        /// Whether this revision signed it as an interruption record (codex-1 on c2202a26).
        let interrupted: Bool
        /// The hash of the content this revision signed (the facts and attachments), to tell a change from a rewrite.
        let content: Data
        /// The hash of the statement signed, so a cleanup drops this signature exactly (codex-1 on 68bd96b3).
        let statement: Data
        /// The digests this revision signed for the record's photo or clip files, by name ("primary", "secondary"):
        /// what a download from iCloud is compared with (item 190's A4, its download half).
        let media: [String: EvidenceForm.Digest]
    }

    /// What the file says of one record's signatures: the record is what its latest revision signed, the highest of its
    /// signatures not retired, wherever the file puts it (codex-3 on 5fa9ec18).
    private struct Signed {
        var signatures: [RecordSignature]

        private var latest: RecordSignature? { signatures.max { $0.revision < $1.revision } }
        var revision: Int64 { latest?.revision ?? 0 }
        var startDate: Int64? { latest?.startDate }
        var kind: String? { latest?.kind }
        var interrupted: Bool { latest?.interrupted ?? false }
        /// The record's identity as signed: its start, its kind and whether it is an interruption record.
        var identity: RecordIdentity { RecordIdentity(start: startDate, kind: kind, interrupted: interrupted) }
        var content: Data? { latest?.content }
    }

    /// One signature, by its key, its counter and the hash of its statement: what a retirement drops from the file,
    /// exactly (codex-3 on 417158fe), never another statement under the same key and counter (codex-1 on 68bd96b3).
    private struct SignatureRef: Hashable {
        let key: Data
        let counter: UInt32
        let statement: Data
    }

    /// An absence statement's line in the event log: its ID, made from the statement (`lineID(for:)`), and the
    /// statement's records.
    private struct OwedLine {
        let id: UUID
        let records: [UUID]
        /// The line as its absence statement fixes it, the same at every writing, so a line written again is the line as
        /// signed (codex-2 on eaac8b96, the owner's "a"): its text, from the count and starts of the records the
        /// statement names, and its time, the statement's.
        let kind: String
        let at: Date
    }

    private let file: EvidenceSignatureFile
    private let keys: any EvidenceKeyService
    private let mediaDirectory: URL
    private let app: String
    private let now: @Sendable () -> Date
    private let retryAfter: TimeInterval
    private let logWarning: @Sendable (String) -> Void

    private var loaded = false
    /// A key made and its statement, waiting for Apple's certification (tried again with the same statement).
    private var pending: (key: Data, statement: Data)?
    /// The certified key in use; nil before the first certification and after App Attest lost it.
    private var current: Data?
    /// The last key certified, which a new key's statement names.
    private var lastCertified: Data?
    /// The records the log held when the install's first key was certified: never signed.
    private var baseline: Set<UUID>?
    private var unsupportedNoted = false
    private var records: [UUID: Signed] = [:]
    /// Each record as the last pass saw it, so an unchanged one costs a comparison.
    private var lastSeen: [UUID: Event] = [:]
    private var digests: [String: (size: Int64, modified: Date, digest: EvidenceForm.Digest)] = [:]
    /// When a certification last failed, so the next waits `retryAfter`.
    private var lastFailure: Date?
    private var certifying = false
    private var latestGeneration = 0
    private var queued: (events: [Event], limitRemoved: [UUID: RecordIdentity])?
    /// A write of the log a pass could not compare, the file and the list not readable then: compared wherever they are
    /// first read, and replaced by any later write (item 190's codex-2 on 424d8ce, the owner's "a").
    private var passKept: (events: [Event], limitRemoved: [UUID: RecordIdentity])?
    private var passing = false
    /// Whether a pass or an export is signing. One at a time, so the file keeps its signatures in App Attest's counter
    /// order and an export's statement is the last signature its snapshot holds.
    private var signing = false
    private var waitingToSign: [CheckedContinuation<Void, Never>] = []
    /// Records named in an absence statement: gone from the log other than by its limit, their signatures kept (the
    /// owner's "1 - a"), never named again.
    private var absent: Set<UUID> = []
    /// Signed records the last comparison found gone and could not name yet (no key could sign their absence statement,
    /// or its signing failed): named at the next chance, and no bundle is offered nor export signed while any is owed
    /// (codex-1 on 401fe979, the owner's "a").
    private var unnamedGone: Set<UUID> = []
    /// Each absence statement's line the file has not noted as written, in the order signed: noted once a write of the
    /// log on disk holds it (codex-5 on 73441cbe).
    private var linesOwed: [OwedLine] = []
    /// The lines owed handed to the event log in this launch: none is handed over twice before a write on disk holds it.
    private var linesHandedOver: Set<UUID> = []
    /// This phone's own records in the last write of the log a pass heard; nil before the launch's first.
    private var lastHeld: Set<UUID>?
    /// Writes a line in the event log under the ID and at the time given (the engine's `logSignerLine`): true once the
    /// log has it.
    private var writeLine: (@Sendable (String, UUID, Date) async -> Bool)?
    private var writingLines = false
    /// The counters the file's retention statements name, by key (codex-4 on 73441cbe).
    private var retiredCounters: [Data: [ClosedRange<UInt32>]] = [:]
    /// Retired signatures still in the file, a rewrite having failed: dropped at a later pass, and never a signature
    /// made since (codex-3 on 417158fe).
    private var cleanupOwed: Set<SignatureRef> = []
    /// Tells the store which of its limit's removals the signer has accounted for (`EventStore.forgetLimitRemovals`).
    private let removalsAccounted: (@Sendable (Set<UUID>) -> Void)?
    /// Tells the store which lines are owed their note, to hold from its limit (`EventStore.holdLinesForTheSigner`).
    private let linesOwedChanged: (@Sendable (Set<UUID>) -> Void)?
    /// The keys this install certified, kept where no edit of a backup reaches (item 190's A3).
    private let keyList: (any EvidenceKeyListStore)?
    /// That list as read with the file, with the file's keys this install made (codex-1 on b7702f5), each key made and
    /// certified since: a new key's statement follows its last.
    private var keysKept: EvidenceKeyList?
    /// Whether `keysKept` differs from the Keychain's, a write refused: tried again at the next pass (deepseek-5 on
    /// b7702f5).
    private var keyListUnsaved = false
    /// The keys the list names that the file had lost when it was read and that are not dealt with yet: dealt with once
    /// `heldAtLaunch` is known too.
    private var keysMissing: [Data] = []
    /// This phone's own records in the log as the store read it at this launch, or at the unlock when the launch could not
    /// read it (`heardTheLogRead`): whether it held any tells history the log kept from a reinstall's empty log, whatever
    /// the phone's clock says (codex-3 on 29d6501; codex-2 and deepseek-3 on b7702f5, the owner's "a").
    private var heldAtLaunch: Set<UUID>?
    /// Each certified key's public point, from its certification in the file: what the file's signatures are checked
    /// with when it is read (codex-1 on ba2e282e), every one read before any signature (codex-1 on 5fa9ec18), and only
    /// for a key every bundle lists (codex-1 on 68bd96b3); and each key Apple certifies in this launch, so that a line the
    /// signer writes late is acted on as one read (item 188).
    private var keyPoints: [Data: Data] = [:]
    /// Each key's counters the file accounts for, as a verifier counts them: its signatures' that hold, and those its own
    /// retention and unkept statements name below their own (item 188, ADR 0073). Below the key in use's highest, any
    /// other was made by App Attest and not kept.
    private var accounted: [Data: [ClosedRange<UInt32>]] = [:]
    /// Lines the file refused once App Attest had made their signatures (a full disk), in the order made: written first at
    /// the next signing turn, and no signature is made while one is held (item 188, ADR 0073, decision 3).
    private var heldLines: [Entry] = []

    /// - Parameters:
    ///   - file: where the signatures are kept, beside the log.
    ///   - keys: App Attest, or a test's stand-in.
    ///   - mediaDirectory: the folder of the log's photo and clip files.
    ///   - app: the app's version and build, as a statement names them ("1.10 (81)").
    ///   - now: the phone's clock.
    ///   - retryAfter: how long a certification that failed waits before the next try.
    ///   - removalsAccounted: told which of the store's limit removals are accounted for (item 182).
    ///   - linesOwedChanged: told which lines are owed their note, to hold from the limit (item 182).
    ///   - keyList: where the keys this install certified are kept beside the file, where no edit of a backup reaches
    ///     (item 190's A3): the Keychain's in the app; none, for a test of the file alone.
    ///   - logWarning: where the line saying signatures were thrown away goes (item 206): the phone's log, whose text is
    ///     public, so it carries a count and nothing of a record; a test's list.
    init(file: EvidenceSignatureFile, keys: any EvidenceKeyService, mediaDirectory: URL, app: String,
         now: @escaping @Sendable () -> Date = { Date() }, retryAfter: TimeInterval = 60,
         removalsAccounted: (@Sendable (Set<UUID>) -> Void)? = nil,
         linesOwedChanged: (@Sendable (Set<UUID>) -> Void)? = nil,
         keyList: (any EvidenceKeyListStore)? = nil,
         logWarning: @escaping @Sendable (String) -> Void = { Log.store.warning("\($0, privacy: .public)") }) {
        self.file = file
        self.keys = keys
        self.mediaDirectory = mediaDirectory
        self.app = app
        self.now = now
        self.retryAfter = retryAfter
        self.removalsAccounted = removalsAccounted
        self.linesOwedChanged = linesOwedChanged
        self.keyList = keyList
        self.logWarning = logWarning
    }

    #if DEBUG
    /// Test-only: where this signer keeps its list of certified keys (item 190's A3).
    var keyListForTesting: (any EvidenceKeyListStore)? { keyList }
    /// Test-only: this phone's own records in the log the launch read, as the signer was told (item 190's deepseek-3).
    var heldAtLaunchForTesting: Set<UUID>? { heldAtLaunch }
    #endif

    /// The log as the store read it at this launch, or at the unlock when the launch could not read it: this phone's own
    /// records in it (item 190's codex-2 and deepseek-3 on b7702f5, the owner's "a"). With the file read, the keys it lost
    /// are dealt with at once, and a line they owe is written as soon as the signer has heard a write of the log, a write
    /// a pass could not compare compared now (codex-2 on 424d8ce).
    func heardTheLogRead(_ firstHand: Set<UUID>) async {
        guard heldAtLaunch == nil else { return }
        heldAtLaunch = firstHand
        guard loadIfNeeded() else { return }   // the file's first read deals with them (codex-2 on 424d8ce)
        noteKeysMissingIfKnown()
        await passWhatWasKept()
        if let lastHeld { await writeOwedLines(holding: lastHeld) }
    }

    /// Where the signer writes its lines in the event log: the engine's `logSignerLine`, once the engine is made (item
    /// 182). The lines owed are written once a write of the log has been heard (one the log already holds, after a
    /// relaunch, is only noted then), each later one when it falls due, each at its absence statement's time; a write a
    /// pass could not compare is compared first (codex-2 on 424d8ce).
    func writeLines(with writer: @escaping @Sendable (String, UUID, Date) async -> Bool) async {
        writeLine = writer
        guard loadIfNeeded() else { return }
        await passWhatWasKept()
        guard let lastHeld else { return }
        await writeOwedLines(holding: lastHeld)
    }

    /// Makes this install's key and asks Apple to certify it, when there is no certified key yet and the last try is
    /// `retryAfter` old: `records` is what the log holds now (nil while the log is not read, when nothing happens). Then,
    /// with a key, names what a comparison found gone and could not name yet, the event log given its line at once
    /// (codex-1 on 401fe979, the owner's "a"): asked at launch and whenever the app comes forward. A write of the log a
    /// pass could not compare is compared once the file can be read (codex-2 on 424d8ce, the owner's "a").
    func certifyIfNeeded(records: [UUID]?) async {
        await certify(records: records)
        await passWhatWasKept()
        guard current != nil, !unnamedGone.isEmpty else { return }
        await startSigning()
        defer { finishSigning() }
        guard writeHeldLines() else { return }   // a line the file refused, first (item 188)
        _ = await nameWhatIsOwedNow()
    }

    /// The certification itself, which a pass also asks for, in its own signing turn, once App Attest has lost the key.
    private func certify(records: [UUID]?) async {
        guard !certifying, loadIfNeeded(), current == nil else { return }
        guard keys.isSupported else { return noteUnsupported() }
        // The install's first certification notes what the log holds, never to be signed: without the log, it waits.
        guard baseline != nil || records != nil else { return }
        if let lastFailure, now().timeIntervalSince(lastFailure) < retryAfter { return }
        certifying = true
        defer { certifying = false }
        do {
            let key = try await pendingKey()
            let attestation = try await keys.attestKey(key.key.base64EncodedString(),
                                                       clientDataHash: EvidenceHash.sha256(key.statement))
            let entry = Entry(kind: .keyCertified, key: key.key, attestation: attestation, existing: baseline == nil ? records ?? [] : nil)
            guard file.append(entry) else { return failed() }
            apply(entry)
            // Its point, as a key read with the file has: a line held and written late is checked with it (item 188).
            keyPoints[key.key] = EvidenceVerifier.publicKey(ofAttestation: attestation, keyID: key.key)
            noteCertified(key.key)
            lastFailure = nil
        } catch let error as DCError where error.code == .invalidKey {
            // App Attest no longer has the key it was asked to certify: the next try makes another.
            if let key = pending?.key, file.append(Entry(kind: .keyLost, key: key, at: now())) { pending = nil }
            failed()
        } catch let error as DCError where error.code == .featureUnsupported {
            noteUnsupported()
        } catch {
            Log.store.error("Evidence signing: the key's certification failed: \(Log.ref(error), privacy: .public)")
            failed()
        }
    }

    /// After a write of the log reached the disk: its number (rising: an older one arriving late is ignored), the
    /// events it holds, and this phone's own records the log's limit removed that the store has not been told are
    /// accounted for, each with what the removed row was (`EventStore.limitRemovalsAsRemoved`, each on disk before the log
    /// that dropped it: item 182).
    func logWritten(generation: Int, events: [Event], limitRemoved: [UUID: RecordIdentity] = [:]) async {
        guard generation > latestGeneration else { return }
        latestGeneration = generation
        queued = (events, limitRemoved)
        passKept = nil   // a write a pass could not compare is older (codex-2 on 424d8ce)
        await passQueued()
    }

    /// Passes the newest write queued, in the signing turn, one pass at a time.
    private func passQueued() async {
        guard !passing else { return }   // the pass running takes the newest write when it ends
        passing = true
        defer { passing = false }
        await startSigning()   // after an export signing now
        defer { finishSigning() }
        while let next = queued {
            queued = nil
            await pass(next.events, limitRemoved: next.limitRemoved)
        }
    }

    /// The write of the log a pass could not compare, the file and the list not readable then: passed wherever they are
    /// first read, and kept again should they still not be (codex-2 on 424d8ce, the owner's "a"). A later write replaces
    /// it, so it is never passed after a newer one.
    private func passWhatWasKept() async {
        guard let kept = passKept else { return }
        passKept = nil
        queued = kept
        await passQueued()
    }

    /// For an export of `record` (phase 4; ADR 0067), once no pass is signing: signs an export statement naming the
    /// record's latest signed revision and the statements its bundle shows (`shownCounters`: the revisions of `showing`,
    /// the record and the watch around it, and every retention, absence and unkept statement; the owner's "B"), kept in
    /// the file like any signature, and returns the file's entries ending with it, so the bundle's last signature is the
    /// export's. A line the file refused is written first, and the key in use's counters App Attest made and the file does
    /// not keep are named before it; when its own counter shows more, a second export statement follows their statement
    /// (item 188, ADR 0073, decision 4), and while they cannot be named, no snapshot (item 193's codex-1, the owner's "a").
    /// nil, with no statement, for a record with no signature of this phone's; nil when no export statement could be
    /// signed (no key, or the signing failed: a bundle without one would end its check in problems; item 187,
    /// deepseek-1 on 09d997f); nil when the file cannot be read now, or before the signer has compared the log on disk in
    /// this launch (codex-3 on 68bd96b3), or while a signed record it found gone cannot be named, which it tries first
    /// (codex-1 on 401fe979).
    func export(of record: UUID, showing: Set<UUID>) async -> EvidenceExportSnapshot? {
        await startSigning()
        defer { finishSigning() }
        guard loadIfNeeded(), lastHeld != nil, writeHeldLines() else { return nil }   // a refused line first (item 188)
        guard await nameWhatIsOwedNow() else { return nil }
        if !cleanupOwed.isEmpty, drop(cleanupOwed) { cleanupOwed = [] }   // retired signatures leave first (codex-2 on ba2e282e)
        var signedExport = false
        if current != nil, let revision = records[record]?.revision {
            // Counters known not kept, named before the export statement, which ends the bundle (item 188).
            await nameUnkept()
            if let key = current { signedExport = await signExport(of: record, revision: revision, showing: showing, key: key) }
            // A key App Attest lost (a restore from a backup) shows only when a signature is refused: a new one at once,
            // as a pass asks for one, and the export statement signed with it, so the first share after a restore has
            // its bundle (item 190's deepseek-3, the owner's "A5 a"). With Apple out of reach, no bundle. (A signature that
            // succeeded leaves the key current.)
            if current == nil {
                await certify(records: nil)
                if let renewed = current {
                    signedExport = await signExport(of: record, revision: revision, showing: showing, key: renewed)
                }
            }
        }
        // No bundle goes without its export statement (item 187, deepseek-1 on 09d997f, the owner's "a").
        guard signedExport, let entries = file.read() else { return nil }
        return EvidenceExportSnapshot(entries: entries, signedExport: signedExport)
    }

    /// The counters of the statements a bundle shows in full, by key: the revisions of the records in `showing`, and every
    /// retention, absence and unkept statement, as `EvidenceExporter.contents` shows them (item 182, the owner's "B"; item
    /// 188).
    static func shownCounters(in entries: [EvidenceSignatureFile.Entry], showing: Set<UUID>) -> [EvidenceForm.KeyCounters] {
        var byKey: [Data: [UInt32]] = [:]
        for entry in entries where entry.kind == .signature {
            guard let key = entry.key, let statement = entry.statement, let assertion = entry.assertion,
                  let counter = counter(of: assertion) else { continue }
            switch try? EvidenceForm.read(statement) {
            case .record(let form)?:
                guard showing.contains(form.id) else { continue }
            case .retention?, .absence?, .unkept?:
                break
            case .export?, .key?, nil:
                continue
            }
            byKey[key, default: []].append(counter)
        }
        return byKey.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { key in
            EvidenceForm.KeyCounters(keyID: key, counters: EvidenceForm.counterRanges(byKey[key, default: []]))
        }
    }

    /// Whether `record` has a signature of this phone's, so Share can offer its bundle; false while the file cannot be
    /// read now.
    func hasSignature(of record: UUID) -> Bool {
        loadIfNeeded() && records[record] != nil
    }

    /// What Settings shows of the signing key (item 199): the certified key in use, or that a key waits for Apple's
    /// certification (before the install's first, or after App Attest lost one, until the next is certified); nil where
    /// this iPhone cannot sign (App Attest not supported) and while the signature file cannot be read now.
    func signingKey() -> SigningKey? {
        guard keys.isSupported, loadIfNeeded() else { return nil }
        return current.map(SigningKey.certified) ?? .waitingForApple
    }

    /// Runs `join` while no signature can be made (the signing turn held, as a pass or a share holds it), handing it what
    /// this phone signed for `record`'s photos and clips, for a download from iCloud to be compared with (item 190's A4,
    /// its download half): by slot ("primary", "secondary"), the digest of the latest revision naming it, among the
    /// signatures this phone made or its file's read checked under their key, one whose line the file still refuses
    /// included; none for a slot no revision names (a copy from another device, a record from before 1.10, or one signed
    /// without it); nil while the file cannot be read now, when nothing can be told and the download waits. The turn
    /// waits for a signature in progress and writes the lines the file refused first, so a download compares a capture
    /// and attaches it with no signature made between (item 194's codex-1, the owner's "a").
    func whileSigningHeld<T: Sendable>(mediaOf record: UUID,
                                       _ join: @MainActor @Sendable ([String: EvidenceForm.Digest]?) async -> T) async -> T {
        await startSigning()
        defer { finishSigning() }
        guard loadIfNeeded() else { return await join(nil) }
        writeHeldLines()
        return await join(mediaSigned(of: record))
    }

    /// What `whileSigningHeld` hands a download: each slot's digest in the latest revision naming it.
    private func mediaSigned(of record: UUID) -> [String: EvidenceForm.Digest] {
        var latest: [String: (revision: Int64, digest: EvidenceForm.Digest)] = [:]
        func take(_ revision: Int64, _ media: [String: EvidenceForm.Digest]) {
            for (slot, digest) in media where revision > latest[slot]?.revision ?? 0 { latest[slot] = (revision, digest) }
        }
        for signature in records[record]?.signatures ?? [] { take(signature.revision, signature.media) }
        // A signature App Attest made here whose line the file still refuses, written first at the next turn (item 194).
        for line in heldLines {
            guard let statement = line.statement, case .record(let form)? = try? EvidenceForm.read(statement),
                  form.id == record else { continue }
            take(form.revision, Self.media(of: form))
        }
        return latest.mapValues { $0.digest }
    }

    /// Whether Share can offer `record`'s bundle: the record has a signature of this phone's, a certified key is current
    /// to sign its export statement (item 187, deepseek-1 on 09d997f, the owner's "a"; one App Attest has lost shows only
    /// when a signature is refused, and the export then makes no bundle), and the signer has compared the log on disk in
    /// this launch (codex-3 on 68bd96b3, the owner's "a") and named every signed record it found gone (codex-1 on
    /// 401fe979, the owner's "a"). Never while the log failed to load, when a signed record it lost would not be named
    /// gone. A write of the log a pass could not compare is compared first (codex-2 on 424d8ce, the owner's "a").
    func canExport(_ record: UUID) async -> Bool {
        await exportReadiness(record) == .ready
    }

    /// Why Share can or cannot offer `record`'s bundle now (item 200), by `canExport`'s conditions: ready exactly when it
    /// can. The signature file not readable now, the log on disk not compared yet in this launch, and a signed record it
    /// found gone not named yet are each "not now"; a record with no signature of this phone's is "not signed"; a signed
    /// record with no certified key to sign its export is "no certified key".
    func exportReadiness(_ record: UUID) async -> EvidenceExportReadiness {
        guard loadIfNeeded() else { return .notNow }
        await passWhatWasKept()
        guard records[record] != nil else { return .notSigned }
        guard current != nil else { return .noCertifiedKey }
        guard lastHeld != nil, unnamedGone.isEmpty else { return .notNow }
        return .ready
    }

    /// Waits until no pass or export is signing, then signs alone until `finishSigning()`.
    private func startSigning() async {
        guard signing else {
            signing = true
            return
        }
        await withCheckedContinuation { waitingToSign.append($0) }   // handed the turn by finishSigning
    }

    /// Hands the turn to the next waiting, or frees it.
    private func finishSigning() {
        if waitingToSign.isEmpty {
            signing = false
        } else {
            waitingToSign.removeFirst().resume()
        }
    }

    // MARK: - A pass

    private func pass(_ events: [Event], limitRemoved: [UUID: RecordIdentity]) async {
        guard loadIfNeeded() else {
            passKept = (events, limitRemoved)   // compared once the file and the list can be read (codex-2 on 424d8ce)
            return
        }
        if keyListUnsaved { saveKeyList() }   // a list the Keychain refused, written again (deepseek-5 on b7702f5)
        noteKeysMissingIfKnown()   // a line the file did not take at its read, owed again (item 190's A3)
        // A line the file refused at the last signing, first, so this pass reads what it says (item 188, ADR 0073).
        writeHeldLines()
        // This phone's own records: a copy from iCloud under a record's ID never stands for it (item 182), nor a row whose
        // start or kind is not the signed record's, which is never signed as it (codex-2 on 21ea9a43, the owner's "a").
        let firstHand = events.filter { !$0.isMirrored }
        let replaced = Set(firstHand.filter { event in
            records[event.id].map { !Self.isSameRecord(event, as: $0) } ?? false
        }.map(\.id))
        let present = Set(firstHand.map(\.id)).subtracting(replaced)
        lastHeld = present
        if !cleanupOwed.isEmpty, drop(cleanupOwed) { cleanupOwed = [] }
        let gone = records.keys.filter { !present.contains($0) && !absent.contains($0) }
        // The limit's removals are retired, and the store forgets each once it is accounted for: retired, not signed here,
        // or one the signer never retires (named gone before it came back). Never one still in this write's log: the
        // store hands over its removals as each write's notice runs, which can be after later writes, so a record can be
        // named while this write still holds it, unsigned until this very pass signs it. Any other signed record that
        // left the log is named gone (item 182; the owner's "a"), one gone with a log the launch could not read too
        // (codex-2 on 5fa9ec18, the owner's "a"). A line still owed its note keeps its removal in the store: the removal
        // shows the log held it (codex-5 on 417158fe).
        // A removal retires a record only when the row the limit removed was that record, its start, kind and
        // interruption as signed: the removal of another row under its ID leaves it to be named gone (codex-1 on
        // eaac8b96 and c2202a26, the owner's "a").
        let retired = gone.filter { id in limitRemoved[id].map { $0 == records[id]?.identity } ?? false }
        var accounted = Set(limitRemoved.keys.filter { id in
            !present.contains(id) && (records[id] == nil || absent.contains(id))
        })
        if !retired.isEmpty, await retire(retired) { accounted.formUnion(retired) }
        accounted.subtract(linesOwed.map(\.id))
        if !accounted.isEmpty { removalsAccounted?(accounted) }
        // What this comparison finds gone and cannot name now stays owed (codex-1 on 401fe979, the owner's "a").
        unnamedGone = Set(gone).subtracting(retired)
        _ = await nameWhatIsOwed()
        await writeOwedLines(holding: present.union(limitRemoved.keys))
        guard let key = current, let baseline else { return }
        // The records held at the first certification are never signed, unless the file's own signatures show one was:
        // an edited list stops no signed record's changes (codex-2 on 68bd96b3).
        for event in events where !event.isMirrored && (!baseline.contains(event.id) || records[event.id] != nil) {
            if replaced.contains(event.id) { continue }   // never signed as the record it is not
            if lastSeen[event.id] == event { continue }
            guard let files = mediaDigests(for: event) else { continue }   // a file there but unreadable now: next write
            let facts = event.evidenceFacts
            let attachments = event.evidenceAttachments(primary: files.primary, secondary: files.secondary)
            let content = Self.content(id: event.id, facts: facts, attachments: attachments)
            if records[event.id]?.content == content {
                lastSeen[event.id] = event
                continue
            }
            // A revision no count can pass (only a statement under a key whose certification is itself forged holds one:
            // ADR 0066's fifth amendment) is not signed past, rather than stopping the app (Claude's self-review).
            let (revision, overflow) = (records[event.id]?.revision ?? 0).addingReportingOverflow(1)
            guard !overflow else { continue }
            let form = EvidenceForm.Record(id: event.id, revision: revision, signedAt: milliseconds(), app: app,
                                           facts: facts, attachments: attachments)
            guard await sign(.record(form), record: event.id, key: key, content: content) else {
                // A key App Attest lost: a new one, and the records wait for the next write. Any other failure: the
                // record is tried again at the next write.
                if current == nil {
                    await certify(records: nil)
                    // Once a key is certified, what this pass could not name is named in its own turn, the line at once
                    // (codex-1 on 21ea9a43).
                    _ = await nameWhatIsOwedNow()
                    return
                }
                continue
            }
            lastSeen[event.id] = event
        }
        // The key in use's counters App Attest made and the file does not keep that no signature of this pass named: a
        // build before this one left them, or their statement's signing failed (item 188, ADR 0073, decision 2). A key
        // App Attest lost shows here as at a record's signature: a new one, and what is owed named with it.
        await nameUnkept()
        if current == nil {
            await certify(records: nil)
            _ = await nameWhatIsOwedNow()
        }
    }

    /// Signs `statement` with `key` and keeps the signature; false when it could not (the record untouched either way).
    /// A line the file refuses once App Attest has made its signature is held, written first at the next signing turn
    /// (item 188, ADR 0073, decision 3). The counters a kept signature shows App Attest made and the file does not keep
    /// are named at once in an unkept statement, whose own signature names nothing more, so statements never chain
    /// (decision 2): a gap it shows waits for the next signing.
    private func sign(_ statement: EvidenceForm.Statement, record: UUID?, key: Data, content: Data?) async -> Bool {
        // App Attest counts every signature, and one missing from the file reads as removed: none is asked for while the
        // file cannot take it (the phone locked), nor while a line it refused is held (item 188), and the record waits for
        // a later write.
        guard heldLines.isEmpty, file.canAppend() else { return false }
        let bytes = EvidenceForm.bytes(statement)
        let assertion: Data
        do {
            assertion = try await assertionPastTheFile(over: bytes, key: key)
        } catch let error as DCError where error.code == .invalidKey {
            if file.append(Entry(kind: .keyLost, key: key, at: now())) { current = nil }
            return false
        } catch {
            Log.store.error("Evidence signing: a signature failed: \(Log.ref(error), privacy: .public)")
            return false
        }
        let entry = Entry(kind: .signature, key: key, statement: bytes, assertion: assertion, record: record)
        guard file.append(entry) else {
            // App Attest has counted it: held, its counter is lost only if the app stops before the next turn (item 188).
            heldLines.append(entry)
            return false
        }
        if let counter = Self.counter(of: assertion) { account(key: key, counter: counter, statement: statement) }
        if let record, case .record(let form) = statement {
            note(record: record, revision: form.revision, startDate: Self.startDate(of: form), kind: Self.kind(of: form),
                 interrupted: Self.interrupted(of: form), content: content ?? Data(), statement: EvidenceHash.sha256(bytes),
                 media: Self.media(of: form), key: key, assertion: assertion)
        }
        // An unkept statement's own signature names nothing more: a gap it shows waits for the next signing.
        if case .unkept = statement { return true }
        await nameUnkept()
        return true
    }

    /// App Attest's signature over `bytes`, its counter past all the file accounts for under `key`. App Attest's count can go
    /// back: a forced restart took it back by two on the owner's phone (TestFlight 84, item 205, ADR 0077), and it gave those
    /// counters out again though their signatures were kept, which every later bundle of the key then showed as repeated. A
    /// counter the file already accounts for is thrown away and asked for again, each ask moving the count on, so no counter is
    /// kept twice and none goes missing. At most `maxAsksPastTheFile` at a time: past that the record waits for a later write.
    /// The file keeps nothing of what is thrown away, so a bundle looks the same whether the count went back or not. The phone's
    /// log says how many were thrown away, on every way out short of a kill (item 206): a kill in the middle of the asking runs
    /// no `defer` (item 207). No line means nothing was thrown away, unless the app was killed in the middle of the asking; it
    /// never means the count did not go back: a stop that loses a signature and takes the count back over it leaves nothing
    /// to throw away.
    private func assertionPastTheFile(over bytes: Data, key: Data) async throws -> Data {
        let hash = EvidenceHash.sha256(bytes)
        var thrownAway = 0
        defer {
            if thrownAway > 0 { logWarning("Evidence signing: the count went back: \(thrownAway) signature(s) thrown away") }
        }
        while thrownAway < Self.maxAsksPastTheFile {
            let assertion = try await keys.generateAssertion(key.base64EncodedString(), clientDataHash: hash)
            guard let counter = Self.counter(of: assertion), let highest = accounted[key]?.map(\.upperBound).max(),
                  counter <= highest else { return assertion }
            thrownAway += 1
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// How many signatures one statement may throw away (`assertionPastTheFile`): far more than a restart has taken back. A real
    /// count rises at each ask, so what a pass throws away adds up to how far it went back; one that did not rise would cost this
    /// many asks for each statement of the pass, each statement then waiting for a later write.
    private static let maxAsksPastTheFile = 64

    /// Signs the export statement of `record` at `revision` with `key`, naming what the bundle shows as the file stands:
    /// true once the file's last signature is an export statement signed here. When its own counter shows counters App
    /// Attest made and the file did not keep, their unkept statement follows it, then a second export statement, which
    /// the bundle carries; the first stays in the file, a signature of its own (item 188, ADR 0073, decision 4).
    private func signExport(of record: UUID, revision: Int64, showing: Set<UUID>, key: Data) async -> Bool {
        for _ in 1...2 {
            guard let entries = file.read() else { return false }
            let statement = EvidenceForm.Statement.export(EvidenceForm.Export(
                record: record, revision: revision, signedAt: milliseconds(), app: app,
                shown: Self.shownCounters(in: entries, showing: showing)))
            // Kept naming no record, so no record's retirement drops it: the next bundle has no gap where it was.
            guard await sign(statement, record: nil, key: key, content: nil), let after = file.read() else { return false }
            if after.last(where: { $0.kind == .signature })?.statement == EvidenceForm.bytes(statement) {
                // Only an export its key's counters account for up to its own: when the statement naming a gap it showed
                // was refused, or its line is held (always that statement, the gap then unaccounted until it is written),
                // the bundle would show the gap missing, so no bundle; the next share names it first (item 193's codex-1,
                // the owner's "a").
                return unaccounted(key).isEmpty
            }
        }
        return false
    }

    /// Names, in a signed unkept statement, the counters of the key in use App Attest made and the file does not keep:
    /// those below the highest it accounts for (item 188, ADR 0073, decision 2). Never an earlier key's, whose entries came
    /// through a backup someone could have edited, nor a key whose signatures the file's read could not check (one no
    /// bundle lists), whose counters would all look unkept. Named again at a later turn when the signing fails.
    private func nameUnkept() async {
        guard let key = current else { return }
        let unkept = unaccounted(key)
        guard !unkept.isEmpty else { return }
        _ = await sign(.unkept(EvidenceForm.Unkept(signedAt: milliseconds(), app: app, counters: unkept)), record: nil, key: key,
                       content: nil)
    }

    /// The counters of `key` below the highest its file accounts for that nothing accounts for: App Attest made them and
    /// the file does not keep them. None for a key whose signatures the file's read could not check (one no bundle lists),
    /// whose counters would all look so (item 188; the export's check too, item 193's codex-1).
    private func unaccounted(_ key: Data) -> [ClosedRange<UInt32>] {
        keyPoints[key] == nil ? [] : Self.holes(in: accounted[key, default: []])
    }

    /// What a signature the file keeps accounts for under its key (`accounted`): its own counter, and the key's own
    /// counters a retention or unkept statement names below it, as a verifier counts them (item 188).
    private func account(key: Data, counter: UInt32, statement: EvidenceForm.Statement?) {
        var ranges = [counter...counter]
        switch statement {
        case .retention(let retention)?:
            ranges += retention.retired.filter { $0.keyID == key }.flatMap(\.counters).compactMap { Self.below(counter, $0) }
        case .unkept(let unkept)?:
            ranges += unkept.counters.compactMap { Self.below(counter, $0) }
        default:
            break
        }
        accounted[key] = EvidenceVerifier.merged(accounted[key, default: []] + ranges)
    }

    /// The part of `range` below `counter`: what a statement signed at `counter` may name of its own key's.
    private static func below(_ counter: UInt32, _ range: ClosedRange<UInt32>) -> ClosedRange<UInt32>? {
        counter > range.lowerBound ? range.lowerBound...min(range.upperBound, counter - 1) : nil
    }

    /// The counters from 1 to the highest of `ranges` that none of them holds, as ascending ranges.
    private static func holes(in ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        var holes: [ClosedRange<UInt32>] = []
        var next: UInt64 = 1
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if UInt64(range.lowerBound) > next { holes.append(UInt32(next)...(range.lowerBound - 1)) }
            next = max(next, UInt64(range.upperBound) + 1)
        }
        return holes
    }

    /// Writes the lines the file refused once App Attest had made their signatures, in the order made, each acted on as a
    /// line the file is read with (item 188, ADR 0073, decision 3): true once none is held.
    @discardableResult
    private func writeHeldLines() -> Bool {
        while let line = heldLines.first {
            guard file.append(line) else { return false }
            heldLines.removeFirst()
            apply(line)
            switch line.statement.flatMap({ try? EvidenceForm.read($0) }) {
            case .retention?: retireWhatTheFileRetired()   // its signatures dropped at the next cleanup, as at a read
            case .absence?: reportLinesOwed()
            default: break
            }
        }
        return true
    }

    /// Signs a retention statement naming the counters of the signed records the log's limit retired, then drops their
    /// signatures from the file: true once that is done (none of them signed is done at once), false while it cannot be
    /// (no key, or the statement not signed), when they are retired at a later write.
    private func retire(_ gone: [UUID]) async -> Bool {
        guard let key = current else { return false }   // retired once a key can sign the statement
        let byKey = Dictionary(grouping: gone.flatMap { records[$0]?.signatures ?? [] }, by: \.key)
        let retired = byKey.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { keyID in
            EvidenceForm.Retired(keyID: keyID, counters: EvidenceForm.counterRanges(byKey[keyID, default: []].map(\.counter)))
        }
        if !retired.isEmpty {
            let statement = EvidenceForm.Retention(signedAt: milliseconds(), app: app, retired: retired)
            guard await sign(.retention(statement), record: nil, key: key, content: nil) else { return false }
            // Exactly the signatures retired leave the file. A rewrite that fails (a full disk) leaves them there:
            // dropped at a later pass, never with one made since, and the statement, read back at a relaunch, keeps them
            // retired (codex-4 on 73441cbe, codex-3 on 417158fe).
            let signatures = Set(gone.flatMap { records[$0]?.signatures ?? [] }
                .map { SignatureRef(key: $0.key, counter: $0.counter, statement: $0.statement) })
            if !drop(signatures) {
                cleanupOwed.formUnion(signatures)
                Log.store.error("Evidence signing: retired signatures stay in the file until a later write")
            }
        }
        for id in gone {
            records[id] = nil
            lastSeen[id] = nil
        }
        return true
    }

    /// Rewrites the file without `signatures`, by each one's key, counter and statement; false when it could not.
    private func drop(_ signatures: Set<SignatureRef>) -> Bool {
        file.dropSignatures { entry in
            guard let key = entry.key, let counter = entry.assertion.flatMap(Self.counter(of:)),
                  let statement = entry.statement else { return false }
            return signatures.contains(SignatureRef(key: key, counter: counter, statement: EvidenceHash.sha256(statement)))
        }
    }

    /// Signs an absence statement naming `gone`, signed records that left the log other than by its limit (the owner's
    /// "a"), keeps their signatures (the owner's "1 - a"), and owes the event log one line for them (the owner's "2 - a").
    /// Signed once a key can sign it; until then they are found gone again at the next write.
    private func declareGone(_ gone: [UUID]) async {
        guard let key = current else { return }
        let listed = gone.sorted { $0.uuidString < $1.uuidString }.map { id in
            EvidenceForm.Absent(id: id, revision: records[id]?.revision ?? 1, startDate: records[id]?.startDate)
        }
        let absence = EvidenceForm.Absence(signedAt: milliseconds(), app: app, records: listed)
        let statement = EvidenceForm.Statement.absence(absence)
        guard await sign(statement, record: nil, key: key, content: nil) else { return }
        noteAbsence(absence, statement: EvidenceForm.bytes(statement))
        reportLinesOwed()
    }

    /// Names what is owed (`unnamedGone`), in the signing turn the caller holds: true once none is owed.
    private func nameWhatIsOwed() async -> Bool {
        unnamedGone.subtract(absent)
        if !unnamedGone.isEmpty { await declareGone(Array(unnamedGone)) }
        unnamedGone.subtract(absent)
        return unnamedGone.isEmpty
    }

    /// Names what is owed outside a pass (once a key is certified, when the app comes forward, before an export), and
    /// gives the event log the line at once, as a pass would: true once none is owed.
    private func nameWhatIsOwedNow() async -> Bool {
        guard !unnamedGone.isEmpty else { return true }
        let named = await nameWhatIsOwed()
        if let lastHeld { await writeOwedLines(holding: lastHeld) }
        return named
    }

    /// An absence statement's records: never named gone again, and their line owed, under the ID made from the
    /// statement's bytes, until the file notes it written; the line's text and time from the statement too.
    private func noteAbsence(_ absence: EvidenceForm.Absence, statement: Data) {
        let ids = absence.records.map(\.id)
        absent.formUnion(ids)
        linesOwed.append(OwedLine(id: Self.lineID(for: statement), records: ids, kind: Self.line(for: absence),
                                  at: Date(timeIntervalSince1970: TimeInterval(absence.signedAt) / 1_000)))
    }

    /// A line the file notes as written, for an absence statement's records.
    private func noteLineWritten(_ ids: [UUID]) {
        if let index = linesOwed.firstIndex(where: { $0.records == ids }) { linesOwed.remove(at: index) }
    }

    /// A retention statement's counters, read back to tell retired records when the file is read (codex-4 on 73441cbe).
    private func noteRetired(_ retired: [EvidenceForm.Retired]) {
        for keyCounters in retired { retiredCounters[keyCounters.keyID, default: []] += keyCounters.counters }
    }

    /// Gives the event log each line owed, in the order signed, under its own ID, and notes it written once a write of
    /// the log on disk holds it (`held`: this phone's own records in the write a pass heard last). So a kill between the
    /// line and its note neither writes it twice (the next launch finds it in the log) nor loses it (the next launch
    /// writes it again, under the same ID): codex-5 on 73441cbe. A line handed over in this launch waits for that write.
    private func writeOwedLines(holding held: Set<UUID>) async {
        guard !writingLines else { return }
        writingLines = true
        var noted = false
        defer {
            writingLines = false
            if noted { reportLinesOwed() }
        }
        var index = 0
        while index < linesOwed.count {
            let owed = linesOwed[index]
            if held.contains(owed.id) {
                guard file.append(Entry(kind: .absenceLogged, records: owed.records, at: now())) else { return }
                linesOwed.remove(at: index)
                noted = true
                continue
            }
            if !linesHandedOver.contains(owed.id) {
                guard let writeLine, await writeLine(owed.kind, owed.id, owed.at) else { return }
                linesHandedOver.insert(owed.id)
            }
            index += 1
        }
    }

    /// Tells the store the lines owed their note, to hold from its limit until noted (codex-3 on ba2e282e, the owner's
    /// "a"): none leaves the log before it is noted, so the limit's removal of one shows the log held it.
    private func reportLinesOwed() {
        linesOwedChanged?(Set(linesOwed.map(\.id)))
    }

    /// The ID of an absence statement's line in the event log, made from the statement's bytes, so it is the same at
    /// every launch and a line the log already holds is found rather than written again (codex-5 on 73441cbe). A
    /// version 8 UUID: made by the app, not at random.
    static func lineID(for statement: Data) -> UUID {
        var bytes = [UInt8](EvidenceHash.sha256(Data("malinois absence line\n".utf8) + statement).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The event log's line for an absence statement: its records' count, and the first and last of their starts as the
    /// statement names them, never as the file holds them later (codex-2 on eaac8b96).
    private static func line(for absence: EvidenceForm.Absence) -> String {
        let starts = absence.records.compactMap(\.startDate).sorted()
        func date(_ milliseconds: Int64?) -> Date? { milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) } }
        return Event.signedRecordsGoneKind(count: absence.records.count, first: date(starts.first), last: date(starts.last))
    }

    // MARK: - The key

    /// The key waiting for certification, made (and its statement kept) when there is none. With a list, one goes to Apple
    /// as it was saved only when this install noted it as made and its statement names it and follows the list's last
    /// certified key, or none (item 190's codex-1 on 424d8ce and on 63e77b0, the owner's "a"): any other, as an earlier
    /// build can leave waiting, is set aside, never certified, and a fresh key made and noted in its place.
    private func pendingKey() async throws -> (key: Data, statement: Data) {
        if let pending, keysKept.map({ Self.goesToAppleAsSaved(pending, list: $0) }) ?? true { return pending }
        let identifier = try await keys.generateKey()
        guard let key = Data(base64Encoded: identifier), key.count == 32 else { throw DCError(.invalidInput) }
        try noteMade(key)
        // The last key this install certified, by the Keychain's list where the file has lost it (item 190's A3); with a
        // list, never a key the file alone names, so a list with none certified yet has it follow none (deepseek-1 on
        // 424d8ce, the owner's "a").
        let follows = keysKept.map { $0.certified.last } ?? lastCertified
        let statement = EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: key, signedAt: milliseconds(), app: app,
                                                                          follows: follows)))
        guard file.append(Entry(kind: .keyPending, key: key, statement: statement)) else { throw CocoaError(.fileWriteUnknown) }
        pending = (key, statement)
        return (key, statement)
    }

    /// Whether a key waiting for certification goes to Apple as it was saved, with the Keychain's list `list`: made here,
    /// its statement this key's and following the list's last certified key, or none (codex-1 on 63e77b0).
    private static func goesToAppleAsSaved(_ pending: (key: Data, statement: Data), list: EvidenceKeyList) -> Bool {
        guard list.made.contains(pending.key), case .key(let statement)? = try? EvidenceForm.read(pending.statement) else {
            return false
        }
        return statement.keyID == pending.key && statement.follows == list.certified.last
    }

    private func failed() { lastFailure = now() }

    private func noteUnsupported() {
        if !unsupportedNoted, file.append(Entry(kind: .unsupported, at: now())) { unsupportedNoted = true }
    }

    // MARK: - The file

    /// Reads the file once, when it can be read (not while the phone is locked), and the Keychain's list of the keys this
    /// install certified with it; false until both can be. At that read, the keys the file lost are dealt with when the log
    /// the launch read is known (item 190's codex-2 on 424d8ce, the owner's "a").
    private func loadIfNeeded() -> Bool {
        if loaded { return true }
        guard let entries = file.read() else { return false }
        // The list with the file, or neither (codex-2 on 29d6501, the owner's "a"): one that cannot be read now (before the
        // phone's first unlock since it started, or a fault) is never taken as none, so no key is made without it; both
        // are read again at the next call.
        var kept: EvidenceKeyList?
        if let keyList {
            guard let list = keyList.read() else { return false }
            kept = list
        }
        let listed = EvidenceSignatureFile.listedKeys(in: entries)
        // Every key's point first, from its certification, so each signature is checked against its key wherever the
        // file puts the certification (codex-1 on 5fa9ec18); and only a key every bundle lists, so a key whose
        // certification is itself forged is acted on only where every bundle shows it failing (codex-1 on 68bd96b3).
        for key in listed {
            guard let point = EvidenceVerifier.publicKey(ofAttestation: key.attestation, keyID: key.key) else { continue }
            keyPoints[key.key] = point
        }
        entries.forEach(apply)
        retireWhatTheFileRetired()
        if let kept { readKeyList(kept, listed: listed) }
        loaded = true
        reportLinesOwed()
        noteKeysMissingIfKnown()
        return true
    }

    // MARK: - The keys this install certified (item 190's A3, the owner's "a")

    /// The Keychain's list, as read with the file. A key the file names and the list lacks joins it when this install made
    /// it, the list having noted it before Apple was asked (the app stopped between the file and the Keychain), so the
    /// list never lags the file; any other stays off it, so that no key made elsewhere, whatever the statement beside it
    /// says, is ever the one the next key follows (codex-1 on b7702f5, the owner's "a"). A list with no key at all, made
    /// or certified (the first launch over 1.10 (81)), takes the file's keys from one that follows none, in a chain, as
    /// every file the app writes holds them. A key the list names that the file no longer names, not dealt with yet, is
    /// missing (an edited backup restored, or a reinstall, which empties the app's files).
    private func readKeyList(_ read: EvidenceKeyList, listed: [EvidenceSignatureFile.ListedKey]) {
        var list = read
        let unanchored = list.certified.isEmpty && list.made.isEmpty
        let before = list.certified.count
        for key in listed where !list.certified.contains(key.key) {
            if unanchored {
                guard case .key(let statement)? = try? EvidenceForm.read(key.statement),
                      statement.follows == list.certified.last else { continue }
            } else {
                guard list.made.contains(key.key) else { continue }
            }
            list.certified.append(key.key)
            list.made.removeAll { $0 == key.key }
        }
        keysKept = list
        if list.certified.count > before { saveKeyList() }
        let names = Set(listed.map(\.key))
        keysMissing = list.certified.filter { !names.contains($0) && !list.accounted.contains($0) }
    }

    /// A key Apple has just certified, in the file: added to the list, no longer only made, and the last this install
    /// certified even when the Keychain does not take it now (Claude's self-review on round 190B): the next key follows
    /// it, and the list is written again at the next pass (deepseek-5 on b7702f5).
    private func noteCertified(_ key: Data) {
        guard keyList != nil, var list = keysKept, !list.certified.contains(key) else { return }
        list.certified.append(key)
        list.made.removeAll { $0 == key }
        keysKept = list
        saveKeyList()
    }

    /// Notes in the list that this install made `key`, before Apple is asked to certify it, so that its certification in
    /// the file is one the list takes back (codex-1 on b7702f5, the owner's "a"); throws when the Keychain does not take
    /// the note, and no key goes to Apple then.
    private func noteMade(_ key: Data) throws {
        guard let keyList, var list = keysKept else { return }
        list.made.append(key)
        guard keyList.write(list) else { throw CocoaError(.fileWriteUnknown) }
        keysKept = list
        keyListUnsaved = false
    }

    /// Writes the list as kept; one the Keychain refuses is written again at the next pass (deepseek-5 on b7702f5, the
    /// owner's "a").
    private func saveKeyList() {
        guard let keyList, let keysKept else { return }
        keyListUnsaved = !keyList.write(keysKept)
    }

    /// Keys the file had lost, once both the file and the log the launch read are known, whichever comes second
    /// (`heldAtLaunch`; codex-2 and deepseek-3 on b7702f5, the owner's "a"): when that log held a record of this phone's
    /// (an edited backup restored), the event log is owed one line, kept in the file until it is written; when it held
    /// none (a reinstall, which empties the log), nothing is said. That log decides alone, never the records' times, which
    /// the phone's clock sets, nor what a later write still holds. Either way the list then counts the keys dealt with, so
    /// the line is owed once.
    private func noteKeysMissingIfKnown() {
        guard !keysMissing.isEmpty, let heldAtLaunch, var list = keysKept else { return }
        let missing = keysMissing
        if !heldAtLaunch.isEmpty {
            let id = Self.lineID(forMissing: missing)
            let at = now()
            guard file.append(Entry(kind: .historyMissing, records: [id], keys: missing, at: at)) else { return }
            if !linesOwed.contains(where: { $0.id == id }) {
                linesOwed.append(OwedLine(id: id, records: [id], kind: Event.signaturesMissingKind, at: at))
                reportLinesOwed()
            }
        }
        list.accounted += missing.filter { !list.accounted.contains($0) }
        keysKept = list
        saveKeyList()
        keysMissing = []
    }

    /// The ID of the line saying signatures are missing, from the keys missing, so it is the same at every launch.
    static func lineID(forMissing keys: [Data]) -> UUID {
        lineID(for: Data("missing keys\n".utf8) + keys.reduce(Data(), +))
    }

    /// After the file is read: signatures a retention statement names were retired, though still in the file (their
    /// rewrite failed): dropped at the next pass, and a record left with none of its own is forgotten as retired, never
    /// named gone (codex-4 on 73441cbe); one signed again since keeps its live signatures (codex-2 on ba2e282e), and is
    /// what they signed (codex-3 on 5fa9ec18).
    private func retireWhatTheFileRetired() {
        for (id, signed) in records {
            let retired = signed.signatures.filter(isRetired)
            guard !retired.isEmpty else { continue }
            cleanupOwed.formUnion(retired.map { SignatureRef(key: $0.key, counter: $0.counter, statement: $0.statement) })
            let live = signed.signatures.filter { !isRetired($0) }
            if live.isEmpty {
                records[id] = nil
                lastSeen[id] = nil   // a retention statement written late, as a retirement forgets it (item 188)
            } else {
                records[id]?.signatures = live
            }
        }
    }

    private func isRetired(_ signature: RecordSignature) -> Bool {
        retiredCounters[signature.key]?.contains { $0.contains(signature.counter) } ?? false
    }

    private func apply(_ entry: Entry) {
        switch entry.kind {
        case .keyPending:
            if let key = entry.key, let statement = entry.statement { pending = (key, statement) }
        case .keyCertified:
            guard let key = entry.key else { return }
            if pending?.key == key { pending = nil }
            current = key
            lastCertified = key
            if baseline == nil { baseline = Set(entry.existing ?? []) }
        case .keyLost:
            if entry.key == current { current = nil }
            if entry.key == pending?.key { pending = nil }
        case .signature:
            // Acted on only when its signature signs its statement under its key: a statement someone put in another
            // signature's entry counts for nothing, stays in the file, and shows in a bundle's check (codex-1 on
            // ba2e282e).
            guard let key = entry.key, let statement = entry.statement, let assertion = entry.assertion,
                  let point = keyPoints[key] else { return }
            let formHash = EvidenceHash.sha256(statement)
            guard EvidenceVerifier.signs(assertion, formHash: formHash, publicKey: point) else { return }
            let read = try? EvidenceForm.read(statement)
            // What it accounts for under its key, whatever it signs, a statement this build cannot read included (item 188).
            if let counter = Self.counter(of: assertion) { account(key: key, counter: counter, statement: read) }
            switch read {
            case .record(let form)?:
                // The record the signed statement names, never the entry's unsigned label (Claude's finding on
                // 417158fe: a relabelled signature would have hidden its record's deletion).
                note(record: form.id, revision: form.revision, startDate: Self.startDate(of: form), kind: Self.kind(of: form),
                     interrupted: Self.interrupted(of: form),
                     content: Self.content(id: form.id, facts: form.facts, attachments: form.attachments), statement: formHash,
                     media: Self.media(of: form), key: key, assertion: assertion)
            case .absence(let absence)?:
                noteAbsence(absence, statement: statement)
            case .retention(let retention)?:
                noteRetired(retention.retired)
            default:
                break
            }
        case .unsupported:
            unsupportedNoted = true
        case .absenceLogged:
            noteLineWritten(entry.records ?? [])
        case .historyMissing:
            // The line owed for keys the file had lost (item 190's A3), until a later entry notes it written.
            if let id = entry.records?.first, let at = entry.at, !linesOwed.contains(where: { $0.id == id }) {
                linesOwed.append(OwedLine(id: id, records: [id], kind: Event.signaturesMissingKind, at: at))
            }
        }
    }

    private func note(record: UUID, revision: Int64, startDate: Int64?, kind: String?, interrupted: Bool, content: Data,
                      statement: Data, media: [String: EvidenceForm.Digest], key: Data, assertion: Data) {
        guard let counter = Self.counter(of: assertion) else { return }
        records[record, default: Signed(signatures: [])].signatures.append(
            RecordSignature(key: key, counter: counter, revision: revision, startDate: startDate, kind: kind,
                            interrupted: interrupted, content: content, statement: statement, media: media))
    }

    /// Whether `event` is the record `signed` signs: the start, kind (incident, or which status entry) and interruption
    /// its revisions signed, which the app never changes once it has made a record. A row under a signed record's ID
    /// with another is another record (codex-2 on 21ea9a43 and codex-1 on c2202a26, the owner's "a").
    private static func isSameRecord(_ event: Event, as signed: Signed) -> Bool {
        event.evidenceIdentity == signed.identity
    }

    // MARK: - Helpers

    /// The digests of a record's photo or clip files: a file no longer on the phone is left out; nil when one is there
    /// but cannot be read now (the record waits for a later write).
    private func mediaDigests(for event: Event) -> (primary: EvidenceForm.Digest?, secondary: EvidenceForm.Digest?)? {
        var found: [EvidenceForm.Digest?] = []
        for name in [event.mediaFilename, event.secondaryMediaFilename] {
            guard let name, let url = Self.mediaFile(named: name, in: mediaDirectory) else {
                found.append(nil)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                found.append(nil)
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            if let cached = digests[name], cached.size == size, cached.modified == modified {
                found.append(cached.digest)
                continue
            }
            guard let digest = try? EvidenceHash.digest(ofFileAt: url) else { return nil }
            digests[name] = (size, modified, digest)
            found.append(digest)
        }
        return (found[0], found[1])
    }

    /// The file a record's photo or clip names, when the name is a plain one in the media folder: the file the signer
    /// hashes and an export copies. nil for any other name. The store's rule (`EventStore.mediaFile(named:in:)`, item
    /// 187), so every path a name from the log becomes follows one.
    static func mediaFile(named name: String, in directory: URL) -> URL? {
        EventStore.mediaFile(named: name, in: directory)
    }

    private func milliseconds() -> Int64 { EvidenceForm.milliseconds(since1970: now()) ?? 0 }

    /// What a revision's content is, apart from its number, time and build: a hash of its facts and attachments.
    private static func content(id: UUID, facts: [EvidenceJSON.Member], attachments: [EvidenceForm.Attachment]) -> Data {
        EvidenceHash.sha256(EvidenceForm.bytes(.record(EvidenceForm.Record(id: id, revision: 1, signedAt: 0, app: "-", facts: facts,
                                                                           attachments: attachments))))
    }

    /// The digests a record's revision signs for its photo or clip files, by name ("primary", "secondary").
    private static func media(of form: EvidenceForm.Record) -> [String: EvidenceForm.Digest] {
        Dictionary(form.attachments.filter { $0.name == "primary" || $0.name == "secondary" }.map { ($0.name, $0.digest) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// A record's kind as its revision signed it: its "stateChange" fact, nil for an incident.
    private static func kind(of form: EvidenceForm.Record) -> String? {
        guard case .string(let kind)? = form.facts.first(where: { $0.key == "stateChange" })?.value else { return nil }
        return kind
    }

    /// Whether a record's revision signed it as an interruption record: its "interrupted" fact (codex-1 on c2202a26).
    private static func interrupted(of form: EvidenceForm.Record) -> Bool {
        guard case .bool(let interrupted)? = form.facts.first(where: { $0.key == "interrupted" })?.value else { return false }
        return interrupted
    }

    /// A record's start as its revision signed it, in milliseconds by the phone's clock: its "startDate" fact.
    private static func startDate(of form: EvidenceForm.Record) -> Int64? {
        guard case .int(let milliseconds)? = form.facts.first(where: { $0.key == "startDate" })?.value else { return nil }
        return milliseconds
    }

    /// The counter a signature carries.
    private static func counter(of assertion: Data) -> UInt32? {
        guard let object = try? EvidenceCBOR.decode(assertion), let data = object["authenticatorData"]?.bytesValue else { return nil }
        return try? EvidenceAuthenticatorData.assertion(data).counter
    }
}

/// The signer's place in the app, built at launch beside the event log: it hears each write of the log, and asks for
/// the key's certification at launch and whenever the app comes forward.
@MainActor
final class EvidenceSigning {
    let signer: EvidenceSigner
    private var activeObserver: NSObjectProtocol?

    #if DEBUG
    /// Test-only: the list of certified keys an app's signer keeps instead of the Keychain's, which every test shares
    /// (item 190's A3; `TestIsolation` sets one per test).
    nonisolated(unsafe) static var keyListForTesting: (any EvidenceKeyListStore)?
    #endif

    /// The list an app's signer keeps: `override`, a test's, or the Keychain's (item 190's A3).
    nonisolated static func defaultKeyList(forTesting override: (any EvidenceKeyListStore)?) -> any EvidenceKeyListStore {
        override ?? KeychainEvidenceKeyList()
    }

    /// This app's: the Keychain's, but under a test, the test's own.
    private static var appKeyList: any EvidenceKeyListStore {
        #if DEBUG
        return defaultKeyList(forTesting: keyListForTesting)
        #else
        return defaultKeyList(forTesting: nil)
        #endif
    }

    /// - Parameter retryAfter: how long a certification that failed waits before the next try.
    init(store: EventStore, keys: any EvidenceKeyService = AppAttestKeyService(), center: NotificationCenter = .default,
         retryAfter: TimeInterval = 60) {
        let signer = EvidenceSigner(file: EvidenceSignatureFile(url: store.evidenceSignaturesURL), keys: keys,
                                    mediaDirectory: store.mediaDirectory, app: Self.appVersion, retryAfter: retryAfter,
                                    removalsAccounted: { [weak store] ids in Task { @MainActor in store?.forgetLimitRemovals(ids) } },
                                    linesOwedChanged: { [weak store] ids in Task { @MainActor in store?.holdLinesForTheSigner(ids) } },
                                    keyList: Self.appKeyList)
        self.signer = signer
        // The log as the store read it, this phone's own records: at launch, or at the unlock when the launch could not
        // read it (item 190's codex-2 and deepseek-3 on b7702f5, the owner's "a").
        let heard: (Set<UUID>) -> Void = { read in Task { await signer.heardTheLogRead(read) } }
        if let read = store.logReadAtLaunch { heard(read) }
        store.onLogRead = heard
        store.onDurableWrite = { [weak store] generation, events in
            // Each on disk before the log that dropped it (item 182); one removed since is harmless: a record still in this
            // write's log is not gone from it.
            let limitRemoved = store?.limitRemovalsAsRemoved ?? [:]
            Task { await signer.logWritten(generation: generation, events: events, limitRemoved: limitRemoved) }
        }
        let certify: @MainActor @Sendable () -> Void = { [weak store] in
            let records = store.flatMap { $0.acceptsWrites ? $0.events.map(\.id) : nil }
            Task { await signer.certifyIfNeeded(records: records) }
        }
        certify()
        activeObserver = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { certify() }
        }
    }

    /// Whether the signer's lines reach the event log (`writeLines`).
    private(set) var writesLines = false

    /// Hands the signer the writer of its lines in the event log: the engine's `logSignerLine`, once the engine is made
    /// (item 182).
    func writeLines(_ log: @escaping @MainActor @Sendable (String, UUID, Date) -> Bool) {
        writesLines = true
        let signer = signer
        Task {
            await signer.writeLines { kind, id, at in
                await MainActor.run { log(kind, id, at) }
            }
        }
    }

    /// The app's version and build, as a statement names them: "1.10 (81)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
