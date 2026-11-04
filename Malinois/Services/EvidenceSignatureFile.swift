//
//  EvidenceSignatureFile.swift
//  Malinois
//
//  The file of evidence signatures beside the event log (BACKLOG item 90, phase 2; the owner's ruling of 2026-10-31,
//  "1 - a": a file of its own, never inside the records, so a fault in signing cannot damage a record):
//  `evidence-signatures.jsonl`, one entry a line, appended and synced to disk, and rewritten only to drop the signatures
//  of records the log's limit retired. Protected as the log is: unreadable while the phone is locked.
//

import Foundation

struct EvidenceSignatureFile: Sendable {
    /// The file's name, in the event log's folder.
    static let name = "evidence-signatures.jsonl"

    /// What an entry is.
    enum EntryKind: String, Codable, Sendable {
        /// A key made, with the statement Apple is asked to certify (kept for retries with the same statement).
        case keyPending
        /// Apple's certification of that key.
        case keyCertified
        /// A key App Attest no longer has (a restore from a backup, a reinstall): a new one follows it.
        case keyLost
        /// A signed statement: a record's revision, or a retention, export or absence statement.
        case signature
        /// This device cannot sign (App Attest unsupported): said once.
        case unsupported
        /// The event log's line for an absence statement is written (item 182): the records the statement names, so a
        /// relaunch does not write it again; or the line `historyMissing` owed, under its ID (item 190).
        case absenceLogged
        /// Keys the Keychain's list names that the file had lost when it was read, with records of the log's from before
        /// that launch (an edited backup restored, item 190's A3): the keys, and the ID of the event log's line owed.
        case historyMissing
    }

    /// One line of the file.
    struct Entry: Codable, Equatable, Sendable {
        var kind: EntryKind
        /// The key ID, 32 bytes.
        var key: Data?
        /// The key statement (`keyPending`) or the signed statement (`signature`), in the fixed form.
        var statement: Data?
        /// Apple's attestation object (`keyCertified`).
        var attestation: Data?
        /// App Attest's assertion object (`signature`).
        var assertion: Data?
        /// The record a revision is of (`signature`; none for a retention statement).
        var record: UUID?
        /// The records the log held when the install's first key was certified (`keyCertified`): never signed.
        var existing: [UUID]?
        /// The records an entry names (`absenceLogged`), or the ID of its line (`historyMissing`).
        var records: [UUID]?
        /// The key IDs an entry names, 32 bytes each (`historyMissing`).
        var keys: [Data]?
        /// When, by the phone's clock (`keyLost`, `unsupported`, `absenceLogged`, `historyMissing`).
        var at: Date?

        init(kind: EntryKind, key: Data? = nil, statement: Data? = nil, attestation: Data? = nil, assertion: Data? = nil,
             record: UUID? = nil, existing: [UUID]? = nil, records: [UUID]? = nil, keys: [Data]? = nil, at: Date? = nil) {
            self.kind = kind
            self.key = key
            self.statement = statement
            self.attestation = attestation
            self.assertion = assertion
            self.record = record
            self.existing = existing
            self.records = records
            self.keys = keys
            self.at = at
        }
    }

    /// A key a bundle lists: certified in the file after a key statement of its own, with that statement and Apple's
    /// certification.
    struct ListedKey: Equatable, Sendable {
        let key: Data
        let statement: Data
        let attestation: Data
    }

    /// The keys every bundle lists, in the order certified: each key certified after a key statement of its own, with
    /// the latest such statement before its certification (the one it was made with). A key never certified, or
    /// certified with no statement before it, is not listed. The export lists exactly these, and the signer acts on
    /// these alone (item 182, codex-1 on 68bd96b3), so a key whose certification is itself forged is acted on only where
    /// every bundle shows it failing its check.
    static func listedKeys(in entries: [Entry]) -> [ListedKey] {
        var statements: [Data: Data] = [:]
        var listed: [ListedKey] = []
        for entry in entries {
            switch entry.kind {
            case .keyPending:
                if let key = entry.key, let statement = entry.statement { statements[key] = statement }
            case .keyCertified:
                if let key = entry.key, let statement = statements[key], let attestation = entry.attestation,
                   !listed.contains(where: { $0.key == key }) {
                    listed.append(ListedKey(key: key, statement: statement, attestation: attestation))
                }
            case .keyLost, .signature, .unsupported, .absenceLogged, .historyMissing:
                break
            }
        }
        return listed
    }

    let url: URL

    /// The entries, in order; nil when the file exists and cannot be read now (the phone locked, or a fault): nothing may
    /// be written then. A missing file reads as no entries. A line that does not decode (a write a kill cut short, or a
    /// kind no longer written, such as an earlier development build's note of records set aside) is skipped.
    func read() -> [Entry]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var entries: [Entry] = []
        for line in data.split(separator: Self.newline, omittingEmptySubsequences: true) {
            if let entry = try? StoredJSON.decode(Entry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                Log.store.error("Evidence signatures: a line that does not decode was skipped")
            }
        }
        return entries
    }

    /// Whether the file can take a line now: it opens for writing, or there is none yet. The log is written as a new file
    /// each time, which its protection allows while the phone is locked; this one is appended to, which it does not.
    func canAppend() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        try? handle.close()
        return true
    }

    /// Appends `entry` as one line and syncs it to disk; false when it could not.
    func append(_ entry: Entry) -> Bool {
        guard let line = try? Self.encoded(entry) else { return false }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil,
                                     attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else { return false }
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            var bytes = line
            bytes.append(Self.newline)
            // A line a kill cut short has no newline: this one starts a line of its own.
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([Self.newline]) { bytes.insert(Self.newline, at: 0) }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            return true
        } catch {
            Log.store.error("Evidence signatures: an append failed: \(Log.ref(error), privacy: .public)")
            return false
        }
    }

    /// Rewrites the file without the signatures `drop` picks, at once and whole; false when it could not.
    func dropSignatures(where drop: (Entry) -> Bool) -> Bool {
        guard let entries = read() else { return false }
        let kept = entries.filter { !($0.kind == .signature && drop($0)) }
        guard kept.count != entries.count else { return true }
        var data = Data()
        do {
            for entry in kept {
                data.append(try Self.encoded(entry))
                data.append(Self.newline)
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch {
            Log.store.error("Evidence signatures: a rewrite failed: \(Log.ref(error), privacy: .public)")
            return false
        }
    }

    private static let newline = UInt8(ascii: "\n")

    private static func encoded(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }
}
