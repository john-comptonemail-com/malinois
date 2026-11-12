//
//  EvidenceBundle.swift
//  MalinoisEvidence
//
//  The export bundle (BACKLOG item 90, phase 4; the owner's rulings of 2026-10-31): what Share sends beside a signed
//  record so that someone else can check it, one folder that iOS zips. The phone writes it and a verifier reads and
//  checks it here, so the app's tests and the Mac verifier share one layout:
//    bundle.json       the index: the format, the record shared, the phone's certified keys in order, the attachments
//    keys/             each key's statement (`<key>.json`) and Apple's attestation of it (`<key>.cbor`)
//    signatures.jsonl  every signature by those keys, in the phone's order: its key, its assertion, the hash of what it
//                      signed, and whether that statement is shown
//    statements/       the statements shown in full, each under its hash (`<hash>.json`): the shared record's
//                      revisions, the watch around it, retention, absence and unkept statements, and the export statement
//    notes.jsonl       the phone's unsigned notes: a key lost
//    attachments/      the shared record's photo or clip, thumbnail and traces, as its latest revision signed them
//  The index names the format "malinois-evidence-bundle/1", or "/2" when the bundle holds an unkept statement (item 188;
//  ADR 0073, the owner's "A"), which 1.10's verifier refuses as another format rather than reading it as damaged; a check
//  names a label that is not what the bundle holds, either way (item 193's codex-2, the owner's "a").
//  The index and each line are in the fixed JSON form (`EvidenceJSON`), as the phone writes them. A check names what it
//  finds as facts, and every file in the bundle must be one this layout names: any other is named, Finder's `.DS_Store`
//  files apart (item 187). Only a hash, a key ID or a plain attachment name becomes a file name, and only plain files
//  are read, so nothing outside the bundle is. Shared by the app and the Mac verifier.
//

import Foundation

enum EvidenceBundle {
    /// The format the index names first: this, or `formatWithUnkept`. A reader refuses any other (a newer app's):
    /// `EvidenceProblem.unknownFormat`.
    static let format = "malinois-evidence-bundle/1"
    /// The format of a bundle that holds an unkept statement (item 188; ADR 0073, the owner's "A"): 1.10's verifier, which
    /// cannot read one, refuses the bundle as in another format, saying a newer verifier is needed, rather than reporting
    /// a statement not in its fixed form, which reads like damage. Every other bundle stays in `format`, which it checks.
    static let formatWithUnkept = "malinois-evidence-bundle/2"

    /// The format a bundle of `contents` names: `formatWithUnkept` when it shows an unkept statement in full, as a check
    /// judges what it holds (item 193's codex-2); the phone's export shows every one.
    static func format(of contents: Contents) -> String {
        let holdsUnkept = contents.signatures.contains { signature in
            guard signature.shown, case .unkept? = try? EvidenceForm.read(signature.statement) else { return false }
            return true
        }
        return holdsUnkept ? formatWithUnkept : format
    }

    static let indexName = "bundle.json"
    static let signaturesName = "signatures.jsonl"
    static let notesName = "notes.jsonl"
    static let keysFolder = "keys"
    static let statementsFolder = "statements"
    static let attachmentsFolder = "attachments"
    /// The README beside the index in every bundle: what the archive is and how to check it, in the words the owner
    /// approved (2026-10-31; its sentence on what the verifier prints, 2026-11-04: "a"; "contains" for "holds", 2026-11-07,
    /// item 208). Not signed, and no check reads it.
    static let readmeName = "README.txt"
    static let readme = [
        "This folder contains one event that Malinois, an iPhone app, recorded and signed on the phone: the event's record as "
            + "it was signed, the photos, clips and sensor traces it names, the phone's signatures, and Apple's certification "
            + "of the key that made them.",
        "",
        "To check it, use Malinois's verifier on a Mac. Its source, and how to build it, are in Malinois's public "
            + "repository, github.com/john-comptonemail-com/malinois, which Malinois's support page links (\"Checking an "
            + "evidence bundle\" in its README). Run it on the ZIP as you received it, by its name:",
        "",
        "    malinois-verify \"Malinois evidence 2026-10-31 1302.zip\"",
        "",
        "It prints what it checked, then PASS or the problems it found. What a check can and cannot show is "
            + "in the repository's SECURITY.md (\"Evidence someone else can check\").",
        "",
        "This README is not signed, and the verifier does not read it: get the verifier from the repository, not from a "
            + "link that came with a bundle.",
    ].joined(separator: "\n") + "\n"

    // MARK: - What the phone writes

    /// One of the phone's certified keys: its ID, the statement Apple's certification covers, and Apple's attestation.
    struct Key: Equatable, Sendable {
        let id: Data
        let statement: Data
        let attestation: Data
    }

    /// One signature from the phone's file: its key, App Attest's assertion, and the statement signed, shown in full or
    /// as its hash alone.
    struct Signature: Equatable, Sendable {
        let key: Data
        let assertion: Data
        let statement: Data
        let shown: Bool
    }

    /// A note the phone wrote without signing it.
    enum Note: Equatable, Sendable {
        /// App Attest no longer had this key (a restore from a backup): a new key follows it.
        case keyLost(key: Data, at: Int64?)
    }

    /// One of the shared record's attachments: its name in the record's statement, its file in the bundle (the name,
    /// alone or with an extension), and its bytes.
    struct Attachment: Sendable {
        let name: String
        let file: String
        let source: AttachmentSource
    }

    /// Where an attachment's bytes come from: a file on the phone (a photo or clip, copied), or memory.
    enum AttachmentSource: Sendable {
        case file(URL)
        case bytes(Data)
    }

    /// What the phone puts in a bundle.
    struct Contents: Sendable {
        let record: UUID
        /// The phone's certified keys, in the order certified.
        let keys: [Key]
        /// Every signature by those keys, in the phone's order.
        let signatures: [Signature]
        let notes: [Note]
        /// The shared record's attachments, as of its latest revision.
        let attachments: [Attachment]
    }

    // MARK: - What a check finds

    /// A key the index lists: certified, or what its check found instead.
    struct KeyCheck: Equatable, Sendable {
        let keyID: Data
        let key: EvidenceCertifiedKey?
        let problem: EvidenceProblem?
    }

    /// A line of the signatures: the signature when it checks out under its key over its hash (with its statement, when
    /// shown and read), and what the check found instead of what it needed, about the signature (no entry) or about the
    /// statement shown (an entry without it).
    struct SignatureCheck: Equatable, Sendable {
        /// The line's number, from 1.
        let line: Int
        let entry: EvidenceSignedEntry?
        let problem: EvidenceProblem?
    }

    /// An attachment, against the last revision of the shared record shown.
    struct AttachmentCheck: Equatable, Sendable {
        let name: String
        let outcome: AttachmentOutcome
    }

    /// What the check of an attachment found.
    enum AttachmentOutcome: Equatable, Sendable {
        /// The file's bytes are the ones the revision signed.
        case matches
        /// The file's bytes are not the ones the revision signed.
        case differs
        /// The revision signed it; the bundle does not list it (the phone no longer had the file).
        case notInBundle
        /// The bundle lists a file the revision did not sign.
        case notSigned
        /// The bundle lists it and it cannot be read.
        case unreadable(EvidenceProblem)
    }

    /// What a bundle's check found, each part as a fact.
    struct Report: Equatable, Sendable {
        /// The record the bundle shares: the export statement's, or, without one, the index's.
        let record: UUID
        /// The keys the index lists, in its order.
        let keys: [KeyCheck]
        /// Every line of the signatures, in order.
        let signatures: [SignatureCheck]
        /// Each certified key's counters, in the index's order.
        let sequences: [EvidenceSequence]
        /// The bundle's export statement: the last line's, when it checks out and is one. Without it, the end of the
        /// bundle is unaccounted for.
        let export: EvidenceForm.Export?
        /// The counters of the export's key above the export statement's own.
        let afterExport: [UInt32]
        /// The shared record's revisions shown, in the order signed.
        let revisions: [EvidenceForm.Record]
        /// Its revision numbers up to the one the export names (or the highest shown) that are not shown.
        let missingRevisions: [Int64]
        /// Whether its revisions shown rise in the order signed, none above the one the export names.
        let revisionsInOrder: Bool
        /// The attachments of the last revision shown (the latest, when they are in order), in its order, then the files
        /// the bundle lists that it does not sign.
        let attachments: [AttachmentCheck]
        /// The phone's notes, unsigned, in order.
        let notes: [Note]
        /// What could not be read outside the keys, the lines and the attachments: a file missing, a note; and a format
        /// label that is not what the bundle holds (item 193's codex-2).
        let problems: [EvidenceProblem]
        /// The absence statements shown: signed records the phone said left its log other than by its limit (item 182),
        /// in the order signed. A verifier reports each.
        let absences: [EvidenceForm.Absence]
        /// The counters the export statement names as shown that the bundle does not show in full: sent as their hash
        /// alone, or missing (item 182, the owner's "B"). A verifier reports them.
        let unshown: [EvidenceForm.KeyCounters]
        /// The counters of the statements the bundle shows in full that its export statement does not name, the export's
        /// own line apart, by key in the index's order: statements put in by someone passing the bundle on, from another
        /// of the phone's bundles or another phone (item 190, codex-1 and deepseek-4). Empty without an export statement.
        /// A verifier reports them.
        let unnamed: [EvidenceForm.KeyCounters]
        /// The counters the export statement names where a statement shown in full shares its counter with another signature
        /// shown only as its hash, by key as the export names them (item 206, Codex-1). The count went back there, and an
        /// export names by counter, so it does not say which of the two it means. Not a problem: an honest bundle can hold
        /// one, and a statement someone cut down to its fingerprint looks the same. A verifier says so.
        let ambiguous: [EvidenceForm.KeyCounters]
        /// The certified keys the index lists that are neither the export statement's key nor one it follows, by the key
        /// statements' `follows`, in the index's order: another phone's key, or one no restore led from (item 190,
        /// codex-1). Empty without an export statement. A verifier reports each.
        let unrelatedKeys: [Data]
        /// The export statement's key and the keys it follows that the bundle holds certified, oldest first: the order
        /// the phone made them in, which a verifier shows the signatures in (item 190, codex-1). Empty without an export
        /// statement.
        let keyOrder: [Data]
        /// The key the export's chain stops at: the one the oldest key of `keyOrder` follows, which the bundle does not
        /// hold certified (a key an edited backup took out of the signature file, or one from before a reinstall). The
        /// keys of `unrelatedKeys` then cannot be tied to the export's key, whatever they are, rather than shown to be
        /// another phone's (item 190, deepseek-1 on 29d6501 and deepseek-2 on b7702f5). nil when the chain ends at a key
        /// that follows none, and without an export statement.
        let chainBreak: Data?
        /// The files and folders in the bundle that its layout does not name as plain files, each as its path in the
        /// bundle, in order: a file added on the way, a folder (named, not opened), a link (never followed), and anything
        /// but a plain file under a name the layout lists, the README's included. A verifier reports each (item 187,
        /// codex-1 on 09d997f and on 07b7134).
        let unlisted: [String]
        /// macOS's own `.DS_Store` files in the bundle, which Finder leaves in a folder it shows, each as its path in the
        /// bundle, in order: named, not judged.
        let ignored: [String]
    }

    // MARK: - Writing and checking

    /// Writes `contents` into `folder`, with `readme` beside the index and the index last, so a bundle cut short has
    /// none. Throws, writing nothing, for contents a reader would refuse: a key ID that is not 32 bytes, an attachment
    /// name that is not plain, or one twice.
    static func write(_ contents: Contents, to folder: URL) throws {
        // Everything a reader would refuse is refused before anything is written.
        var names = Set<String>()
        for attachment in contents.attachments {
            // One name a file, whatever the file system makes of letter case.
            guard isPlainFileName(attachment.file, of: attachment.name), names.insert(attachment.name.lowercased()).inserted else {
                throw EvidenceProblem.formNotFixed
            }
        }
        let keyIDs = contents.keys.map(\.id) + contents.signatures.map(\.key)
        guard keyIDs.allSatisfy({ $0.count == 32 }), Set(contents.keys.map(\.id)).count == contents.keys.count else {
            throw EvidenceProblem.formNotFixed
        }
        for note in contents.notes {
            switch note {
            case .keyLost(let key, _): guard key.count == 32 else { throw EvidenceProblem.formNotFixed }
            }
        }
        let manager = FileManager.default
        for name in [keysFolder, statementsFolder, attachmentsFolder] {
            try manager.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for key in contents.keys {
            let hex = EvidenceHash.hex(key.id)
            try key.statement.write(to: folder.appendingPathComponent("\(keysFolder)/\(hex).json"))
            try key.attestation.write(to: folder.appendingPathComponent("\(keysFolder)/\(hex).cbor"))
        }
        var signatures = Data()
        for signature in contents.signatures {
            let hash = EvidenceHash.sha256(signature.statement)
            if signature.shown { try signature.statement.write(to: folder.appendingPathComponent(statementPath(hash))) }
            signatures.append(signatureLine(signature, hash: hash).bytes)
            signatures.append(newline)
        }
        try signatures.write(to: folder.appendingPathComponent(signaturesName))
        var notes = Data()
        for note in contents.notes {
            notes.append(noteLine(note).bytes)
            notes.append(newline)
        }
        try notes.write(to: folder.appendingPathComponent(notesName))
        for attachment in contents.attachments {
            let url = folder.appendingPathComponent("\(attachmentsFolder)/\(attachment.file)")
            switch attachment.source {
            case .file(let source): try manager.copyItem(at: source, to: url)
            case .bytes(let data): try data.write(to: url)
            }
        }
        try Data(readme.utf8).write(to: folder.appendingPathComponent(readmeName))
        try index(contents).bytes.write(to: folder.appendingPathComponent(indexName))
    }

    /// Checks the bundle in `folder` for the app `appID` ("TEAMID.bundle") against Apple's roots (DER), every file in the
    /// folder among it. Throws only when its index cannot be read or names another format; everything else is in the
    /// report.
    static func check(_ folder: URL, appID: String, roots: [Data]) throws -> Report {
        try check(folder, appIDHash: EvidenceHash.sha256(Data(appID.utf8)), roots: roots)
    }

    /// As `check(_:appID:roots:)`, for the app whose App ID has the SHA-256 `appIDHash`, as every attestation carries
    /// it: the Mac verifier knows Malinois by it, and its source never holds the team ID (item 90, phase 5).
    static func check(_ folder: URL, appIDHash: Data, roots: [Data]) throws -> Report {
        let index = try readIndex(folder)
        // Each key: Apple's certification of its statement.
        var keys: [KeyCheck] = []
        var certified: [Data: EvidenceCertifiedKey] = [:]
        for keyID in index.keys {
            let hex = EvidenceHash.hex(keyID)
            do {
                let statement = try read("\(keysFolder)/\(hex).json", in: folder, limit: statementLimit)
                let attestation = try read("\(keysFolder)/\(hex).cbor", in: folder, limit: attestationLimit)
                let key = try EvidenceVerifier.certify(attestation: attestation, statement: statement, appIDHash: appIDHash, roots: roots)
                // The certification names its key; the index must have named the same one.
                guard key.keyID == keyID else { throw EvidenceProblem.keyMismatch }
                certified[keyID] = key
                keys.append(KeyCheck(keyID: keyID, key: key, problem: nil))
            } catch {
                keys.append(KeyCheck(keyID: keyID, key: nil, problem: problem(error)))
            }
        }
        var problems: [EvidenceProblem] = []
        let signatureLines = lines(signaturesName, in: folder, problems: &problems) ?? []
        let signatures = signatureLines.enumerated().map { offset, line in
            checkSignature(line, number: offset + 1, in: folder, keys: certified)
        }
        let entries = signatures.compactMap(\.entry)
        // The format the index names is the phone's word, not signed: "/2" exactly when the bundle holds an unkept
        // statement (ADR 0073's decision 6), so either label on the other content is named (item 193's codex-2).
        // What it holds, as the writer judges it: a statement it shows in full that reads as an unkept statement, whether
        // or not its signature checks out (that is a problem of its own).
        let holdsUnkept = signatureLines.contains { line in
            guard let fields = try? signatureFields(line), fields.shown,
                  let shown = try? read(statementPath(fields.hash), in: folder, limit: statementLimit),
                  case .unkept? = try? EvidenceForm.read(shown) else { return false }
            return true
        }
        if index.format != (holdsUnkept ? formatWithUnkept : format) { problems.append(.formatNotAsHeld(index.format)) }
        // Each certified key's counters, a retention statement counting only from the key or a key that follows it.
        let statements = index.keys.compactMap { certified[$0]?.statement }
        let sequences = index.keys.compactMap { certified[$0] }.map { key in
            EvidenceVerifier.sequence(of: entries, keyID: key.keyID, followers: EvidenceVerifier.followers(of: key.keyID, among: statements))
        }
        // The bundle's export statement is its last line's: its key signs nothing after it.
        var export: EvidenceForm.Export?
        var afterExport: [UInt32] = []
        if let last = signatures.last?.entry, case .export(let statement)? = last.statement {
            export = statement
            afterExport = Set(entries.filter { $0.keyID == last.keyID && $0.counter > last.counter }.map(\.counter)).sorted()
        }
        // The shared record: the export statement names it, signed; without one, the index does.
        let record = export?.record ?? index.record
        let revisions = sharedRevisions(of: record, in: entries, keyOrder: index.keys)
        let shown = Set(revisions.map(\.revision))
        let highest = min(max(export?.revision ?? 0, shown.max() ?? 0), EvidenceVerifier.revisionsListed)
        let missingRevisions = highest < 1 ? [] : (1...highest).filter { !shown.contains($0) }
        let rising = zip(revisions, revisions.dropFirst()).allSatisfy { $0.revision < $1.revision }
        let revisionsInOrder = rising && revisions.allSatisfy { $0.revision <= (export?.revision ?? .max) }
        var notes: [Note] = []
        for (offset, line) in (lines(notesName, in: folder, problems: &problems) ?? []).enumerated() {
            if let note = readNote(line) {
                notes.append(note)
            } else {
                problems.append(.unreadable("\(notesName), line \(offset + 1)"))
            }
        }
        let attachments = checkAttachments(signed: revisions.last?.attachments ?? [], listed: index.attachments, in: folder)
        let absences = entries.compactMap { entry -> EvidenceForm.Absence? in
            if case .absence(let absence)? = entry.statement { return absence }
            return nil
        }
        // Whether a statement is shown is not signed; the export statement names what the bundle shows (the owner's "B").
        let unshown: [EvidenceForm.KeyCounters] = (export?.shown ?? []).compactMap { named in
            let present = Set(entries.filter { $0.keyID == named.keyID && $0.statement != nil }.map(\.counter)).sorted()
            let missing = Self.gaps(in: named.counters, present: present)
            return missing.isEmpty ? nil : EvidenceForm.KeyCounters(keyID: named.keyID, counters: missing)
        }
        // And the other way, with every key the export's or one it follows (item 190, codex-1 and deepseek-4): someone
        // passing the bundle on could add genuine statements from another of the phone's bundles, or another phone's key
        // with its own, and the check would pass.
        let exportLine = export == nil ? nil : signatures.last?.entry
        let keyOrder = exportLine.map { Array(Self.lineage(from: $0.keyID, certified: certified).reversed()) } ?? []
        let unrelatedKeys = exportLine == nil ? [] : index.keys.filter { certified[$0] != nil && !keyOrder.contains($0) }
        let unnamed = exportLine.map { Self.unnamed(in: entries, apart: $0, named: export?.shown ?? [], keyOrder: index.keys) } ?? []
        let ambiguous = Self.ambiguous(in: entries, named: export?.shown ?? [])
        // Where the chain stops at a key the bundle does not hold, the keys it cannot reach are cut off by that key, not
        // shown to be another phone's (item 190, deepseek-1 on 29d6501, the owner's "b").
        let chainBreak = keyOrder.first.flatMap { certified[$0]?.statement.follows }
        // Every file the bundle holds must be one its layout names, so a check covers every file (codex-1 on 09d997f).
        let files = inventory(folder, index: index, signatureLines: signatureLines, problems: &problems)
        return Report(record: record, keys: keys, signatures: signatures, sequences: sequences, export: export,
                      afterExport: afterExport, revisions: revisions, missingRevisions: missingRevisions,
                      revisionsInOrder: revisionsInOrder, attachments: attachments, notes: notes, problems: problems,
                      absences: absences, unshown: unshown, unnamed: unnamed, ambiguous: ambiguous, unrelatedKeys: unrelatedKeys,
                      keyOrder: keyOrder,
                      chainBreak: chainBreak, unlisted: files.unlisted, ignored: files.ignored)
    }

    /// The export statement's key and, by the key statements' `follows`, each key before it the bundle holds certified,
    /// newest first, none twice (item 190, codex-1).
    static func lineage(from key: Data, certified: [Data: EvidenceCertifiedKey]) -> [Data] {
        var chain: [Data] = []
        var next: Data? = key
        while let current = next, let certifiedKey = certified[current], !chain.contains(current) {
            chain.append(current)
            next = certifiedKey.statement.follows
        }
        return chain
    }

    /// The counters, by key in `keyOrder`, of the statements `entries` shows in full that `named` does not name, the
    /// export statement's own line `export` apart (item 190, codex-1 and deepseek-4): one pass through each key's counters
    /// and its named ranges, both ascending, however many or wide the ranges (as `gaps`).
    static func unnamed(in entries: [EvidenceSignedEntry], apart export: EvidenceSignedEntry, named: [EvidenceForm.KeyCounters],
                        keyOrder: [Data]) -> [EvidenceForm.KeyCounters] {
        var shown: [Data: Set<UInt32>] = [:]
        for entry in entries where entry.statement != nil && !(entry.keyID == export.keyID && entry.counter == export.counter) {
            shown[entry.keyID, default: []].insert(entry.counter)
        }
        var found: [EvidenceForm.KeyCounters] = []
        var listed = Set<Data>()
        for key in keyOrder where listed.insert(key).inserted {
            guard let counters = shown[key] else { continue }
            let ranges = named.filter { $0.keyID == key }.flatMap(\.counters).sorted { $0.lowerBound < $1.lowerBound }
            var outside: [UInt32] = []
            var index = 0
            for counter in counters.sorted() {
                while index < ranges.count, ranges[index].upperBound < counter { index += 1 }
                if index == ranges.count || !ranges[index].contains(counter) { outside.append(counter) }
            }
            if !outside.isEmpty { found.append(EvidenceForm.KeyCounters(keyID: key, counters: EvidenceForm.counterRanges(outside))) }
        }
        return found
    }

    /// The counters of `named` at which `entries` shows a statement in full beside a different signature shown only as its
    /// hash (item 206, Codex-1): one pass through each key's such counters and its named ranges, both ascending, however many
    /// or wide the ranges (as `gaps`). One signature listed twice is one signature, so its hash beside its own statement counts
    /// for nothing.
    static func ambiguous(in entries: [EvidenceSignedEntry], named: [EvidenceForm.KeyCounters]) -> [EvidenceForm.KeyCounters] {
        var shown: [Data: [UInt32: Set<Data>]] = [:]
        for entry in entries where entry.statement != nil {
            shown[entry.keyID, default: [:]][entry.counter, default: []].insert(entry.formHash)
        }
        var beside: [Data: Set<UInt32>] = [:]
        for entry in entries where entry.statement == nil {
            if let full = shown[entry.keyID]?[entry.counter], !full.contains(entry.formHash) {
                beside[entry.keyID, default: []].insert(entry.counter)
            }
        }
        return named.compactMap { named in
            let ranges = named.counters.sorted { $0.lowerBound < $1.lowerBound }
            var inside: [UInt32] = []
            var index = 0
            for counter in (beside[named.keyID] ?? []).sorted() {
                while index < ranges.count, ranges[index].upperBound < counter { index += 1 }
                if index < ranges.count, ranges[index].contains(counter) { inside.append(counter) }
            }
            return inside.isEmpty ? nil : EvidenceForm.KeyCounters(keyID: named.keyID, counters: EvidenceForm.counterRanges(inside))
        }
    }

    /// The counters of `ranges` (ascending and apart, as the readers take them) not among `present` (ascending, each
    /// once), as ranges: what an export names as shown and the bundle does not show. One pass through both lists, however
    /// many or wide the ranges (codex-6 on 73441cbe).
    static func gaps(in ranges: [ClosedRange<UInt32>], present: [UInt32]) -> [ClosedRange<UInt32>] {
        var gaps: [ClosedRange<UInt32>] = []
        var index = present.startIndex
        for range in ranges {
            while index < present.endIndex, present[index] < range.lowerBound { index += 1 }
            var next = UInt64(range.lowerBound)
            while index < present.endIndex, present[index] <= range.upperBound {
                if UInt64(present[index]) > next { gaps.append(UInt32(next)...(present[index] - 1)) }
                next = UInt64(present[index]) + 1
                index += 1
            }
            if next <= UInt64(range.upperBound) { gaps.append(UInt32(next)...range.upperBound) }
        }
        return gaps
    }

    /// Whether `file` is the attachment `name` as a file in the bundle: the name (a letter, then letters and digits),
    /// alone or with one extension of up to eight letters and digits.
    static func isPlainFileName(_ file: String, of name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, isLetter(first), scalars.count <= 32, scalars.allSatisfy(isLetterOrDigit) else {
            return false
        }
        if file == name { return true }
        guard file.hasPrefix(name + ".") else { return false }
        let fileExtension = file.unicodeScalars.dropFirst(scalars.count + 1)
        return (1...8).contains(fileExtension.count) && fileExtension.allSatisfy(isLetterOrDigit)
    }

    // MARK: - Helpers

    /// The index, as read.
    private struct Index {
        /// The format it names: `format` or `formatWithUnkept`.
        let format: String
        let record: UUID
        let keys: [Data]
        let attachments: [(name: String, file: String)]
    }

    /// One signature, however often it is listed.
    private struct Listed: Hashable {
        let keyID: Data
        let counter: UInt32
        let formHash: Data
    }

    /// The largest key statement or statement a reader takes, as `EvidenceJSON` reads them.
    private static let statementLimit = Int64(EvidenceJSON.maximumBytes)
    /// The largest attestation a reader takes: Apple's is a few kilobytes.
    private static let attestationLimit: Int64 = 1 << 20
    /// The largest file of lines a reader takes: each of a phone's signatures is about half a kilobyte.
    private static let linesLimit: Int64 = 1 << 26
    private static let newline = UInt8(ascii: "\n")

    private static func statementPath(_ hash: Data) -> String { "\(statementsFolder)/\(EvidenceHash.hex(hash)).json" }

    private static func index(_ contents: Contents) -> EvidenceJSON {
        .object([
            .init("format", .string(format(of: contents))), .init("record", .string(contents.record.uuidString)),
            .init("keys", .array(contents.keys.map { .string(EvidenceHash.hex($0.id)) })),
            .init("attachments", .array(contents.attachments.map { attachment -> EvidenceJSON in
                .object([.init("name", .string(attachment.name)), .init("file", .string(attachment.file))])
            })),
        ])
    }

    private static func signatureLine(_ signature: Signature, hash: Data) -> EvidenceJSON {
        .object([.init("key", .string(EvidenceHash.hex(signature.key))), .init("assertion", .string(signature.assertion.base64EncodedString())),
                 .init("hash", .string(EvidenceHash.hex(hash))), .init("shown", .bool(signature.shown))])
    }

    private static func noteLine(_ note: Note) -> EvidenceJSON {
        switch note {
        case .keyLost(let key, let at):
            return .object([.init("kind", .string("keyLost")), .init("key", .string(EvidenceHash.hex(key))),
                            .init("at", at.map(EvidenceJSON.int) ?? .null)])
        }
    }

    /// The index, when it is the phone's: in the fixed form, either format (`format`, `formatWithUnkept`), each key once
    /// in lowercase hex, and each attachment once under a plain file name.
    private static func readIndex(_ folder: URL) throws -> Index {
        let data = try read(indexName, in: folder, limit: statementLimit)
        guard case .object(let members) = try EvidenceJSON(fixedForm: data), let first = members.first, first.key == "format",
              case .string(let named) = first.value else { throw EvidenceProblem.formNotFixed }
        guard named == format || named == formatWithUnkept else { throw EvidenceProblem.unknownFormat(named) }
        // The record's UUID as the phone writes it, in uppercase.
        guard members.map(\.key) == ["format", "record", "keys", "attachments"],
              case .string(let recordText) = members[1].value, let record = UUID(uuidString: recordText), record.uuidString == recordText,
              case .array(let keyList) = members[2].value, case .array(let attachmentList) = members[3].value else {
            throw EvidenceProblem.formNotFixed
        }
        var keys: [Data] = []
        for item in keyList {
            let key = try hash(item)
            guard !keys.contains(key) else { throw EvidenceProblem.formNotFixed }
            keys.append(key)
        }
        var attachments: [(name: String, file: String)] = []
        for item in attachmentList {
            guard case .object(let fields) = item, fields.map(\.key) == ["name", "file"],
                  case .string(let name) = fields[0].value, case .string(let file) = fields[1].value,
                  isPlainFileName(file, of: name),
                  !attachments.contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw EvidenceProblem.formNotFixed }
            attachments.append((name, file))
        }
        return Index(format: named, record: record, keys: keys, attachments: attachments)
    }

    /// A line of the signatures, checked: its key certified, its signature over its hash, then the statement shown.
    private static func checkSignature(_ line: Data, number: Int, in folder: URL, keys: [Data: EvidenceCertifiedKey]) -> SignatureCheck {
        let fields: (key: Data, assertion: Data, hash: Data, shown: Bool)
        do {
            fields = try signatureFields(line)
        } catch {
            return SignatureCheck(line: number, entry: nil, problem: problem(error))
        }
        guard let key = keys[fields.key] else { return SignatureCheck(line: number, entry: nil, problem: .notCertified) }
        let signed: EvidenceSignedEntry
        do {
            signed = try EvidenceVerifier.check(assertion: fields.assertion, formHash: fields.hash, form: nil, under: key)
        } catch {
            return SignatureCheck(line: number, entry: nil, problem: problem(error))
        }
        guard fields.shown else { return SignatureCheck(line: number, entry: signed, problem: nil) }
        // A fault in the statement shown is named, and the signature still counts over its hash.
        do {
            let form = try read(statementPath(fields.hash), in: folder, limit: statementLimit)
            let entry = try EvidenceVerifier.check(assertion: fields.assertion, formHash: fields.hash, form: form, under: key)
            return SignatureCheck(line: number, entry: entry, problem: nil)
        } catch {
            return SignatureCheck(line: number, entry: signed, problem: problem(error))
        }
    }

    private static func signatureFields(_ line: Data) throws -> (key: Data, assertion: Data, hash: Data, shown: Bool) {
        guard case .object(let members) = try EvidenceJSON(fixedForm: line), members.map(\.key) == ["key", "assertion", "hash", "shown"],
              case .string(let text) = members[1].value, let assertion = Data(base64Encoded: text),
              case .bool(let shown) = members[3].value else { throw EvidenceProblem.formNotFixed }
        return (try hash(members[0].value), assertion, try hash(members[2].value), shown)
    }

    /// A note, when the line is one as the phone writes it.
    private static func readNote(_ line: Data) -> Note? {
        guard case .object(let members)? = try? EvidenceJSON(fixedForm: line), members.count == 3,
              case .string(let kind) = members[0].value else { return nil }
        let at: Int64?
        switch members[2].value {
        case .null: at = nil
        case .int(let milliseconds): at = milliseconds
        default: return nil
        }
        let names = members.map(\.key)
        if kind == "keyLost", names == ["kind", "key", "at"], let key = try? hash(members[1].value) {
            return .keyLost(key: key, at: at)
        }
        return nil
    }

    /// The shared record's revisions shown among `entries`, in the order signed (the keys in the index's order, then by
    /// counter), a signature listed twice taken once.
    private static func sharedRevisions(of record: UUID, in entries: [EvidenceSignedEntry], keyOrder: [Data]) -> [EvidenceForm.Record] {
        // The index lists each key once; a key listed again keeps its first place rather than stopping the check.
        let place = Dictionary(keyOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var listed = Set<Listed>()
        return entries
            .filter { listed.insert(Listed(keyID: $0.keyID, counter: $0.counter, formHash: $0.formHash)).inserted }
            .sorted { (place[$0.keyID] ?? 0, $0.counter) < (place[$1.keyID] ?? 0, $1.counter) }
            .compactMap { entry -> EvidenceForm.Record? in
                guard case .record(let revision)? = entry.statement, revision.id == record else { return nil }
                return revision
            }
    }

    /// Each attachment `signed` names, against the file the index lists for it, then the files listed that it does not
    /// name.
    private static func checkAttachments(signed: [EvidenceForm.Attachment], listed: [(name: String, file: String)],
                                         in folder: URL) -> [AttachmentCheck] {
        var checks: [AttachmentCheck] = []
        for attachment in signed {
            guard let file = listed.first(where: { $0.name == attachment.name })?.file else {
                checks.append(AttachmentCheck(name: attachment.name, outcome: .notInBundle))
                continue
            }
            let path = "\(attachmentsFolder)/\(file)"
            do {
                let url = try plainFile(path, in: folder).url
                // Read a megabyte at a time: a clip is never held whole.
                guard let digest = try? EvidenceHash.digest(ofFileAt: url) else { throw EvidenceProblem.unreadable("\(path) cannot be read") }
                checks.append(AttachmentCheck(name: attachment.name, outcome: digest == attachment.digest ? .matches : .differs))
            } catch {
                checks.append(AttachmentCheck(name: attachment.name, outcome: .unreadable(problem(error))))
            }
        }
        let names = Set(signed.map(\.name))
        for entry in listed where !names.contains(entry.name) {
            checks.append(AttachmentCheck(name: entry.name, outcome: .notSigned))
        }
        return checks
    }

    /// The files and folders in the bundle that its layout does not name, and macOS's `.DS_Store` files, each as its path
    /// in the bundle, in order (item 187, codex-1 on 09d997f). The layout names the index, the README, the signatures and
    /// the notes; the keys', statements' and attachments' folders; each listed key's statement and attestation; the
    /// statement of each line shown; and each listed attachment, each only as a plain file: anything else under a name it
    /// lists is unlisted too (item 187, codex-1 on 07b7134), and the reads report what they cannot read. Every name in a
    /// folder is listed, those beginning "._" too (`names(in:)`). A folder it does not name is named, not opened; a link
    /// is never followed; a folder that cannot be listed is a problem.
    private static func inventory(_ folder: URL, index: Index, signatureLines: [Data],
                                  problems: inout [EvidenceProblem]) -> (unlisted: [String], ignored: [String]) {
        var named: Set<String> = [indexName, readmeName, signaturesName, notesName]
        for key in index.keys {
            named.insert("\(keysFolder)/\(EvidenceHash.hex(key)).json")
            named.insert("\(keysFolder)/\(EvidenceHash.hex(key)).cbor")
        }
        for line in signatureLines {
            if let fields = try? signatureFields(line), fields.shown { named.insert(statementPath(fields.hash)) }
        }
        for attachment in index.attachments { named.insert("\(attachmentsFolder)/\(attachment.file)") }
        let folders = [keysFolder, statementsFolder, attachmentsFolder]
        let manager = FileManager.default
        func type(_ path: String) -> FileAttributeType? {
            // The attributes of a link are its own, never those of what it points to.
            (try? manager.attributesOfItem(atPath: folder.appendingPathComponent(path).path))?[.type] as? FileAttributeType
        }
        var unlisted: [String] = []
        var ignored: [String] = []
        for inFolder in [""] + folders {
            // A folder of the layout that is not a folder, or not there, is named or read as such where it stands.
            guard inFolder.isEmpty || type(inFolder) == .typeDirectory else { continue }
            let url = inFolder.isEmpty ? folder : folder.appendingPathComponent(inFolder)
            guard let names = Self.names(in: url) else {
                problems.append(.unreadable("\(inFolder.isEmpty ? "the bundle's folder" : inFolder) cannot be listed"))
                continue
            }
            for name in names {
                let path = inFolder.isEmpty ? name : "\(inFolder)/\(name)"
                let kind = type(path)
                if name == ".DS_Store", kind == .typeRegular {
                    ignored.append(path)
                } else if inFolder.isEmpty, folders.contains(name), kind == .typeDirectory {
                    continue   // listed in its turn
                } else if !named.contains(path) || kind != .typeRegular {
                    // A name on the layout's list counts only as a plain file: the README is read by no check, so a
                    // folder or a link in its place would pass unseen (item 187, codex-1 on 07b7134).
                    unlisted.append(path)
                }
            }
        }
        return (unlisted.sorted(), ignored.sorted())
    }

    /// Every name in the folder `folder` but "." and "..", in no order; nil when it cannot be listed. Read with the
    /// system's `readdir`: Foundation's folder listings on macOS leave out every name that begins "._", so a file so named
    /// would pass a check unseen (item 187's round B). The Mac verifier lists with it too.
    static func names(in folder: URL) -> [String]? {
        guard let directory = opendir(folder.path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            var bytes = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            guard let name = withUnsafeBytes(of: &bytes, { String(bytes: $0.prefix(length), encoding: .utf8) }) else { return nil }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        return errno == 0 ? names : nil   // readdir ends with nil at the end, and on a failure with errno set
    }

    /// The lines of the bundle's file `name`, each without its newline; nil, with what was found added to `problems`, when
    /// the file cannot be read.
    private static func lines(_ name: String, in folder: URL, problems: inout [EvidenceProblem]) -> [Data]? {
        do {
            var lines = try read(name, in: folder, limit: linesLimit).split(separator: newline, omittingEmptySubsequences: false)
                .map { Data($0) }
            // The last line ends with a newline too.
            if lines.last?.isEmpty == true { lines.removeLast() }
            return lines
        } catch {
            problems.append(problem(error))
            return nil
        }
    }

    /// The bytes of the plain file at `path` in the bundle, when there are at most `limit` of them.
    private static func read(_ path: String, in folder: URL, limit: Int64) throws -> Data {
        let file = try plainFile(path, in: folder)
        guard file.length <= limit else { throw EvidenceProblem.unreadable("\(path) is too large") }
        guard let data = try? Data(contentsOf: file.url) else { throw EvidenceProblem.unreadable("\(path) cannot be read") }
        return data
    }

    /// The plain file at `path` in the bundle, and its length: neither a link nor in a linked folder, so nothing outside the
    /// bundle is read. The bundle's own folder is the caller's.
    private static func plainFile(_ path: String, in folder: URL) throws -> (url: URL, length: Int64) {
        let manager = FileManager.default
        let url = folder.appendingPathComponent(path)
        // The attributes of a link are its own, never those of what it points to.
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { throw EvidenceProblem.fileMissing(path) }
        var inPlainFolder = true
        if path.contains("/") {
            let parent = try? manager.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            inPlainFolder = parent?[.type] as? FileAttributeType == .typeDirectory
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular, inPlainFolder else {
            throw EvidenceProblem.unreadable("\(path) is not a plain file in the bundle")
        }
        return (url, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// A key ID or a SHA-256 hash, in lowercase hex.
    private static func hash(_ value: EvidenceJSON) throws -> Data {
        guard case .string(let text) = value, let bytes = EvidenceHash.bytes(hex: text), bytes.count == 32 else {
            throw EvidenceProblem.formNotFixed
        }
        return bytes
    }

    /// What a check found, from what it caught.
    private static func problem(_ error: any Error) -> EvidenceProblem {
        error as? EvidenceProblem ?? .unreadable("\(error)")
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool { isLetter(scalar) || ("0"..."9").contains(scalar) }
}
