//
//  EvidenceForm.swift
//  MalinoisEvidence
//
//  The statements evidence signing signs (BACKLOG item 90), in format "malinois-evidence/1": a revision of a record, a
//  retention statement (the log's limit retired these signatures with their records), the statement Apple's
//  certification of a key covers, an export statement, and an absence statement (signed records that left the log
//  other than by its limit, item 182). Each is a JSON object in the fixed form (`EvidenceJSON`) whose members come in a fixed
//  order, every member always present (null when it has no value); hashes and key IDs in lowercase hex; times in
//  milliseconds since 1970 by the phone's clock, which the statement states as the phone's. The phone signs a
//  statement's SHA-256; a verifier checks the bytes against it, then reads them here. Shared by the app and the Mac
//  verifier.
//
//  The five layouts, member by member:
//    record:    format, type "record", id (the record's UUID), revision (1, 2, ...: the phone's count of this record's
//               signed revisions), signedAt, app ("1.10 (81)"), facts (the record's own fields, in the order the app
//               writes them), attachments ([{name, sha256, bytes}]: each photo or clip, the thumbnail, each trace)
//    retention: format, type "retention", signedAt, app, retired ([{key, counters: [[first, last], ...]}], keys in
//               ascending order, each range after the one before with a counter between them)
//    key:       format, type "key", key (the key ID), signedAt, app, follows (the key this log was signed with before a
//               restore from a backup, or null)
//    export:    format, type "export", record (the shared record's UUID), revision (its latest revision in the bundle),
//               signedAt, app, shown ([{key, counters}], as a retention statement's: the statements its bundle shows in
//               full; item 182, the owner's "B") (phase 4: a bundle's last signature, so a verifier can tell it stops
//               where the log did, and that nothing it shows was hidden)
//    absence:   format, type "absence", signedAt, app, records ([{id, revision, startDate}]: each signed record that left
//               the log other than by its limit, the revision last signed and its start, or null; IDs in ascending
//               order, each once. Item 182, the owner's ruling of 2026-10-31, "a": its signatures stay in the file)
//

import Foundation

enum EvidenceForm {
    /// The format every statement names first. A reader refuses a statement in another format (a newer app's) rather
    /// than guess at it: `EvidenceProblem.unknownFormat`.
    static let format = "malinois-evidence/1"

    /// A file's or a blob's SHA-256 and length.
    struct Digest: Equatable, Sendable {
        let sha256: Data
        let bytes: Int64
    }

    /// Something a record's revision covers by its hash: a photo or clip ("primary", "secondary"), the thumbnail, a
    /// sensor trace.
    struct Attachment: Equatable, Sendable {
        let name: String
        let digest: Digest
    }

    /// One revision of one record, as the phone signs it.
    struct Record: Equatable, Sendable {
        let id: UUID
        let revision: Int64
        let signedAt: Int64
        let app: String
        let facts: [EvidenceJSON.Member]
        let attachments: [Attachment]
    }

    /// The signatures the log's limit retired with their records (the refinement of 2026-10-21): per key, their
    /// counters, so a verifier can tell a counter the limit removed from one nothing accounts for.
    struct Retention: Equatable, Sendable {
        let signedAt: Int64
        let app: String
        let retired: [Retired]
    }

    /// One key's counters, as ranges: in a retention statement those it retires; in an export statement those of the
    /// statements its bundle shows in full.
    struct KeyCounters: Equatable, Sendable {
        let keyID: Data
        let counters: [ClosedRange<UInt32>]
    }

    /// One key's retired counters.
    typealias Retired = KeyCounters

    /// The statement Apple's certification of a key covers: the certificate carries a hash of it.
    struct KeyStatement: Equatable, Sendable {
        let keyID: Data
        let signedAt: Int64
        let app: String
        let follows: Data?
    }

    /// An export of a record (phase 4): the bundle's last signature, naming the record and its latest revision in it.
    struct Export: Equatable, Sendable {
        let record: UUID
        let revision: Int64
        let signedAt: Int64
        let app: String
        /// Per key, the counters of every statement the bundle shows in full (item 182; the owner's ruling of 2026-10-31,
        /// "B"): whether a bundle shows a statement is not signed, so a verifier reports one named here that is not.
        let shown: [KeyCounters]

        init(record: UUID, revision: Int64, signedAt: Int64, app: String, shown: [KeyCounters] = []) {
            self.record = record
            self.revision = revision
            self.signedAt = signedAt
            self.app = app
            self.shown = shown
        }
    }

    /// Signed records that left the log other than by its limit (item 182; the owner's ruling of 2026-10-31, "a"): the
    /// log's limit removes records, and a retention statement says so; a signed record that leaves any other way (an app
    /// fault, an edited backup restored, a phone opened up) is named here, and a verifier reports it.
    struct Absence: Equatable, Sendable {
        let signedAt: Int64
        let app: String
        let records: [Absent]
    }

    /// One of them: its ID, the revision last signed, and when it started by the phone's clock (nil when its record's
    /// start was written as null).
    struct Absent: Equatable, Sendable {
        let id: UUID
        let revision: Int64
        let startDate: Int64?
    }

    /// Any of the five.
    enum Statement: Equatable, Sendable {
        case record(Record)
        case retention(Retention)
        case key(KeyStatement)
        case export(Export)
        case absence(Absence)
    }

    /// The statement's fixed-form bytes, which the phone signs.
    static func bytes(_ statement: Statement) -> Data { json(statement).bytes }

    /// Reads a statement. Throws `EvidenceProblem.unknownFormat` for another format, and `.formNotFixed` for anything
    /// that is not exactly one statement in this format's fixed form (writing what was read must give the same bytes).
    static func read(_ data: Data) throws -> Statement {
        guard case .object(let members) = try EvidenceJSON(fixedForm: data), let first = members.first, first.key == "format",
              case .string(let named) = first.value else { throw EvidenceProblem.formNotFixed }
        guard named == format else { throw EvidenceProblem.unknownFormat(named) }
        // The second member's name is checked with the rest of the layout, below.
        guard members.count > 1, case .string(let type) = members[1].value else {
            throw EvidenceProblem.formNotFixed
        }
        let statement: Statement
        switch type {
        case "record": statement = .record(try record(members))
        case "retention": statement = .retention(try retention(members))
        case "key": statement = .key(try keyStatement(members))
        case "export": statement = .export(try export(members))
        case "absence": statement = .absence(try absence(members))
        default: throw EvidenceProblem.formNotFixed
        }
        // The one spelling: a lowercase UUID or uppercase hex reads, but is not what the phone writes.
        guard bytes(statement) == data else { throw EvidenceProblem.formNotFixed }
        return statement
    }

    /// Milliseconds since 1970 for a time on the phone's clock; nil when a whole number of milliseconds cannot hold it
    /// exactly (a damaged log's), which a record writes as null.
    static func milliseconds(since1970 date: Date) -> Int64? { milliseconds(date.timeIntervalSince1970) }

    /// Whole milliseconds for a length in seconds, rounded to the nearest; nil as for a time.
    static func milliseconds(_ seconds: Double) -> Int64? {
        let value = (seconds * 1_000).rounded()
        // Below 2^53 every whole number is exact in a Double, and 2^53 milliseconds is some 285,000 years. Not a number
        // and the infinities fail the comparison too.
        guard value.magnitude < 9_007_199_254_740_992 else { return nil }
        return Int64(value)
    }

    /// Counters as a retention statement writes them: ascending ranges, each after the one before with a counter between
    /// them, whatever order and repeats they came in.
    static func counterRanges(_ counters: [UInt32]) -> [ClosedRange<UInt32>] {
        var ranges: [ClosedRange<UInt32>] = []
        for counter in Set(counters).sorted() {
            if let last = ranges.last, UInt64(last.upperBound) + 1 == UInt64(counter) {
                ranges[ranges.count - 1] = last.lowerBound...counter
            } else {
                ranges.append(counter...counter)
            }
        }
        return ranges
    }

    /// A sensor trace's bytes, as its attachment's hash covers them: each sample as an IEEE 754 double, big-endian.
    static func traceBytes(_ samples: [Double]) -> Data {
        var data = Data(capacity: samples.count * 8)
        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - Writing

    private static func json(_ statement: Statement) -> EvidenceJSON {
        switch statement {
        case .record(let record):
            return .object([
                .init("format", .string(format)), .init("type", .string("record")), .init("id", .string(record.id.uuidString)),
                .init("revision", .int(record.revision)), .init("signedAt", .int(record.signedAt)), .init("app", .string(record.app)),
                .init("facts", .object(record.facts)),
                .init("attachments", .array(record.attachments.map { attachment -> EvidenceJSON in
                    .object([.init("name", .string(attachment.name)),
                             .init("sha256", .string(EvidenceHash.hex(attachment.digest.sha256))),
                             .init("bytes", .int(attachment.digest.bytes))])
                })),
            ])
        case .retention(let retention):
            return .object([
                .init("format", .string(format)), .init("type", .string("retention")), .init("signedAt", .int(retention.signedAt)),
                .init("app", .string(retention.app)), .init("retired", countersJSON(retention.retired)),
            ])
        case .key(let key):
            return .object([
                .init("format", .string(format)), .init("type", .string("key")), .init("key", .string(EvidenceHash.hex(key.keyID))),
                .init("signedAt", .int(key.signedAt)), .init("app", .string(key.app)),
                .init("follows", key.follows.map { EvidenceJSON.string(EvidenceHash.hex($0)) } ?? .null),
            ])
        case .export(let export):
            return .object([
                .init("format", .string(format)), .init("type", .string("export")), .init("record", .string(export.record.uuidString)),
                .init("revision", .int(export.revision)), .init("signedAt", .int(export.signedAt)), .init("app", .string(export.app)),
                .init("shown", countersJSON(export.shown)),
            ])
        case .absence(let absence):
            return .object([
                .init("format", .string(format)), .init("type", .string("absence")), .init("signedAt", .int(absence.signedAt)),
                .init("app", .string(absence.app)),
                .init("records", .array(absence.records.map { record -> EvidenceJSON in
                    .object([.init("id", .string(record.id.uuidString)), .init("revision", .int(record.revision)),
                             .init("startDate", record.startDate.map(EvidenceJSON.int) ?? .null)])
                })),
            ])
        }
    }

    /// Keys' counters as ranges, as a retention statement and an export statement write them.
    private static func countersJSON(_ list: [KeyCounters]) -> EvidenceJSON {
        .array(list.map { item -> EvidenceJSON in
            .object([.init("key", .string(EvidenceHash.hex(item.keyID))),
                     .init("counters", .array(item.counters.map { range -> EvidenceJSON in
                         .array([.int(Int64(range.lowerBound)), .int(Int64(range.upperBound))])
                     }))])
        })
    }

    // MARK: - Reading

    /// The members' values, when their names are exactly `names`, in that order.
    private static func values(_ members: [EvidenceJSON.Member], named names: [String]) throws -> [EvidenceJSON] {
        guard members.map(\.key) == names else { throw EvidenceProblem.formNotFixed }
        return members.map(\.value)
    }

    /// A SHA-256 hash or key ID in lowercase hex.
    private static func hash(_ value: EvidenceJSON) throws -> Data {
        guard case .string(let text) = value, let bytes = EvidenceHash.bytes(hex: text), bytes.count == 32 else {
            throw EvidenceProblem.formNotFixed
        }
        return bytes
    }

    private static func app(_ value: EvidenceJSON) throws -> String {
        guard case .string(let app) = value, !app.isEmpty else { throw EvidenceProblem.formNotFixed }
        return app
    }

    private static func time(_ value: EvidenceJSON) throws -> Int64 {
        guard case .int(let milliseconds) = value else { throw EvidenceProblem.formNotFixed }
        return milliseconds
    }

    private static func record(_ members: [EvidenceJSON.Member]) throws -> Record {
        let top = try values(members, named: ["format", "type", "id", "revision", "signedAt", "app", "facts", "attachments"])
        guard case .string(let idText) = top[2], let id = UUID(uuidString: idText),
              case .int(let revision) = top[3], revision >= 1,
              case .object(let facts) = top[6],
              case .array(let list) = top[7] else { throw EvidenceProblem.formNotFixed }
        var names = Set<String>()
        var attachments: [Attachment] = []
        for item in list {
            guard case .object(let fields) = item else { throw EvidenceProblem.formNotFixed }
            let parts = try values(fields, named: ["name", "sha256", "bytes"])
            guard case .string(let name) = parts[0], !name.isEmpty, names.insert(name).inserted,
                  case .int(let length) = parts[2], length >= 0 else { throw EvidenceProblem.formNotFixed }
            attachments.append(Attachment(name: name, digest: Digest(sha256: try hash(parts[1]), bytes: length)))
        }
        return Record(id: id, revision: revision, signedAt: try time(top[4]), app: try app(top[5]), facts: facts,
                      attachments: attachments)
    }

    private static func retention(_ members: [EvidenceJSON.Member]) throws -> Retention {
        let top = try values(members, named: ["format", "type", "signedAt", "app", "retired"])
        let retired = try keyCounters(top[4])
        guard !retired.isEmpty else { throw EvidenceProblem.formNotFixed }
        return Retention(signedAt: try time(top[2]), app: try app(top[3]), retired: retired)
    }

    /// Keys' counters: keys in ascending order, each once, each with ranges in its one spelling.
    private static func keyCounters(_ value: EvidenceJSON) throws -> [KeyCounters] {
        guard case .array(let list) = value else { throw EvidenceProblem.formNotFixed }
        var retired: [KeyCounters] = []
        for item in list {
            guard case .object(let fields) = item else { throw EvidenceProblem.formNotFixed }
            let parts = try values(fields, named: ["key", "counters"])
            let keyID = try hash(parts[0])
            // Keys in ascending order, each once.
            if let previous = retired.last, !previous.keyID.lexicographicallyPrecedes(keyID) { throw EvidenceProblem.formNotFixed }
            guard case .array(let ranges) = parts[1], !ranges.isEmpty else { throw EvidenceProblem.formNotFixed }
            var counters: [ClosedRange<UInt32>] = []
            for range in ranges {
                guard case .array(let ends) = range, ends.count == 2, case .int(let low) = ends[0], case .int(let high) = ends[1],
                      low >= 1, low <= high, high <= Int64(UInt32.max) else { throw EvidenceProblem.formNotFixed }
                // Each range after the one before, with at least one counter between them: one spelling per set.
                if let previous = counters.last, Int64(previous.upperBound) + 1 >= low { throw EvidenceProblem.formNotFixed }
                counters.append(UInt32(low)...UInt32(high))
            }
            retired.append(KeyCounters(keyID: keyID, counters: counters))
        }
        return retired
    }

    private static func export(_ members: [EvidenceJSON.Member]) throws -> Export {
        let top = try values(members, named: ["format", "type", "record", "revision", "signedAt", "app", "shown"])
        guard case .string(let recordText) = top[2], let record = UUID(uuidString: recordText),
              case .int(let revision) = top[3], revision >= 1 else { throw EvidenceProblem.formNotFixed }
        return Export(record: record, revision: revision, signedAt: try time(top[4]), app: try app(top[5]),
                      shown: try keyCounters(top[6]))
    }

    private static func absence(_ members: [EvidenceJSON.Member]) throws -> Absence {
        let top = try values(members, named: ["format", "type", "signedAt", "app", "records"])
        guard case .array(let list) = top[4], !list.isEmpty else { throw EvidenceProblem.formNotFixed }
        var records: [Absent] = []
        for item in list {
            guard case .object(let fields) = item else { throw EvidenceProblem.formNotFixed }
            let parts = try values(fields, named: ["id", "revision", "startDate"])
            guard case .string(let idText) = parts[0], let id = UUID(uuidString: idText),
                  case .int(let revision) = parts[1], revision >= 1 else { throw EvidenceProblem.formNotFixed }
            // IDs in ascending order, each once: one spelling per set.
            if let previous = records.last, previous.id.uuidString >= id.uuidString { throw EvidenceProblem.formNotFixed }
            let startDate: Int64? = try parts[2] == .null ? nil : time(parts[2])
            records.append(Absent(id: id, revision: revision, startDate: startDate))
        }
        return Absence(signedAt: try time(top[2]), app: try app(top[3]), records: records)
    }

    private static func keyStatement(_ members: [EvidenceJSON.Member]) throws -> KeyStatement {
        let top = try values(members, named: ["format", "type", "key", "signedAt", "app", "follows"])
        let follows: Data? = try top[5] == .null ? nil : hash(top[5])
        return KeyStatement(keyID: try hash(top[2]), signedAt: try time(top[3]), app: try app(top[4]), follows: follows)
    }
}
