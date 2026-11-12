//
//  Item90EvidenceBundleTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 4: the export bundle's layout and its check, shared by the app's export and the Mac verifier
//  (the owner's rulings of 2026-10-31). The phone writes one folder: the index, each key's statement and Apple's
//  attestation, every signature in the phone's order (the statements shown in full beside them, every other as its
//  hash), its unsigned notes and the shared record's attachments. A check certifies each key, checks every signature,
//  accounts for each key's counters up to the export statement (a retention statement counting only from the key or a
//  key that follows it), finds the shared record's revisions up to the one the export names, and hashes the attachments
//  against the latest revision; what it cannot read or account for, it names as a fact, every file its layout does not
//  name among them (BACKLOG 187's codex-1), with every name in a folder listed, those beginning "._" too, and anything
//  but a plain file under a name the layout lists (187's round B). Keys certified by test chains made at run time.
//  Written before the code, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

final class Item90EvidenceBundleTests: XCTestCase {

    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("Item90EvidenceBundle-\(UUID().uuidString)")
    private let shared = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let armed = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1") ?? UUID()
    private let disarmed = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1") ?? UUID()
    private let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2") ?? UUID()
    private let retiredRecord = UUID(uuidString: "00000000-0000-4000-8000-0000000000C3") ?? UUID()
    private let photo = Data("a photo's bytes".utf8)
    private let thumbnail = Data("a thumbnail's bytes".utf8)
    private let otherThumbnail = Data("another thumbnail's bytes".utf8)
    private let trace = EvidenceForm.traceBytes([0.5, 1.25, -2])

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: - The layout

    func testABundleIsWrittenInItsLayout() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone, notes: [.keyLost(key: Data(repeating: 0x5E, count: 32), at: 1_793_000_000_000),
                                                             .keyLost(key: Data(repeating: 0x6F, count: 32), at: nil)]))
        let key = phone.keys[0]
        let hex = TestApp.hex(key.keyID)
        func bytes(_ path: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(path)) }
        // The index: its format, the record shared, the keys in the order certified, and each attachment's file.
        XCTAssertEqual(TestApp.text(try bytes("bundle.json")),
                       #"{"format":"malinois-evidence-bundle/1","record":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","keys":["\#(hex)"],"#
                       + #""attachments":[{"name":"primary","file":"primary.jpg"},{"name":"thumbnail","file":"thumbnail.jpg"},"#
                       + #"{"name":"motionTrace","file":"motionTrace.bin"}]}"#)
        // Each key's statement and Apple's attestation, byte for byte.
        XCTAssertEqual(try bytes("keys/\(hex).json"), key.statement)
        XCTAssertEqual(try bytes("keys/\(hex).cbor"), key.attestation)
        // Every signature the file keeps, in its order, a line each: its key, its assertion, the hash signed, and whether
        // the statement is shown.
        XCTAssertEqual(TestApp.text(try bytes("signatures.jsonl")), phone.signatures.map { signature in
            #"{"key":"\#(hex)","assertion":"\#(signature.assertion.base64EncodedString())","#
                + #""hash":"\#(TestApp.hex(TestApp.sha256(signature.statement)))","shown":\#(signature.shown)}"# + "\n"
        }.joined())
        // The statements shown, each under its hash.
        for signature in phone.signatures where signature.shown {
            XCTAssertEqual(try bytes(statementPath(signature)), signature.statement)
        }
        // The notes, a line each.
        XCTAssertEqual(TestApp.text(try bytes("notes.jsonl")),
                       #"{"kind":"keyLost","key":"\#(String(repeating: "5e", count: 32))","at":1793000000000}"# + "\n"
                       + #"{"kind":"keyLost","key":"\#(String(repeating: "6f", count: 32))","at":null}"# + "\n")
        // The attachments' bytes.
        XCTAssertEqual(try bytes("attachments/primary.jpg"), photo)
        XCTAssertEqual(try bytes("attachments/thumbnail.jpg"), thumbnail)
        XCTAssertEqual(try bytes("attachments/motionTrace.bin"), trace)
        // And nothing else but the README beside the index (phase 5): no statement for the one shown as its hash alone.
        let statements = phone.signatures.filter(\.shown).map(statementPath)
        XCTAssertEqual(statements.count, 6)
        XCTAssertEqual(Set(try FileManager.default.subpathsOfDirectory(atPath: folder.path)),
                       Set(["bundle.json", "README.txt", "signatures.jsonl", "notes.jsonl", "keys", "keys/\(hex).json", "keys/\(hex).cbor",
                            "statements", "attachments", "attachments/primary.jpg", "attachments/thumbnail.jpg",
                            "attachments/motionTrace.bin"] + statements))
    }

    /// Phase 5 (the owner, 2026-10-31: "wording approved"): every bundle carries a README beside its index, in the
    /// approved words, which no check reads: changed or removed, the report is the same.
    func testEveryBundleCarriesItsReadmeWhichNoCheckReads() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let readme = folder.appendingPathComponent(EvidenceBundle.readmeName)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), Self.approvedReadme)
        let report = try check(folder, phone)
        try Data("Run this other verifier instead.".utf8).write(to: readme)
        XCTAssertEqual(try check(folder, phone), report, "changed: the same report")
        try FileManager.default.removeItem(at: readme)
        XCTAssertEqual(try check(folder, phone), report, "removed: the same report")
    }

    /// The README's words as the owner approved them (2026-10-31; its sentence on what the verifier prints, 2026-11-04:
    /// "a"): a change to them is a change for the owner to approve.
    private static let approvedReadme = [
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

    func testTheWriterRefusesWhatAReaderWouldRefuseAndWritesNothing() throws {
        let phone = try standardPhone()
        let refusedNames = [("primary", "../primary.jpg"), ("primary", "primary.jpg/x"), ("primary", "thumbnail.jpg"),
                            ("primary", "primary.jpg.exe"), ("primary", "primary."), ("primary", "primary.longerthan8"),
                            ("../primary", "../primary"), ("2primary", "2primary"), ("", "")]
        var refusals: [EvidenceBundle.Contents] = try refusedNames.map { name, file in
            try contents(phone, attachments: [EvidenceBundle.Attachment(name: name, file: file, source: .bytes(photo))])
        }
        refusals.append(try contents(phone, attachments: [
            EvidenceBundle.Attachment(name: "primary", file: "primary.jpg", source: .bytes(photo)),
            EvidenceBundle.Attachment(name: "primary", file: "primary.png", source: .bytes(photo)),
        ]))
        refusals.append(try contents(phone, attachments: [
            EvidenceBundle.Attachment(name: "primary", file: "primary.jpg", source: .bytes(photo)),
            EvidenceBundle.Attachment(name: "Primary", file: "Primary.png", source: .bytes(photo)),
        ]))   // one name in two letter cases: one file on a Mac's disk
        refusals.append(EvidenceBundle.Contents(record: shared, keys: [EvidenceBundle.Key(id: Data([1]), statement: Data(), attestation: Data())],
                                                signatures: [], notes: [], attachments: []))
        refusals.append(EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys + phone.bundleKeys, signatures: [], notes: [],
                                                attachments: []))
        refusals.append(EvidenceBundle.Contents(record: shared, keys: [], signatures: [], notes: [.keyLost(key: Data([1]), at: nil)],
                                                attachments: []))
        for (number, refused) in refusals.enumerated() {
            let folder = base.appendingPathComponent("refused-\(number)")
            XCTAssertThrowsError(try EvidenceBundle.write(refused, to: folder), "refusal \(number)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "refusal \(number) wrote nothing")
        }
        XCTAssertNoThrow(try written(try contents(phone)), "the phone's own contents")
    }

    // MARK: - The check

    func testAWholeBundleChecksOut() throws {
        let phone = try standardPhone()
        let notes: [EvidenceBundle.Note] = [.keyLost(key: Data(repeating: 0x5E, count: 32), at: 1_793_000_000_000)]
        let report = try check(try written(try contents(phone, notes: notes)), phone)
        let keyID = phone.keys[0].keyID
        XCTAssertEqual(report.record, shared)
        XCTAssertEqual(report.keys.map(\.keyID), [keyID])
        XCTAssertEqual(report.keys.first?.key?.keyID, keyID, "certified by the (test) chain to the root given")
        XCTAssertNil(report.keys.first?.problem)
        XCTAssertEqual(report.signatures.map(\.line), Array(1...7))
        XCTAssertEqual(report.signatures.compactMap(\.entry?.counter), Array(2...8))
        XCTAssertEqual(report.signatures.compactMap(\.problem), [])
        XCTAssertEqual(report.signatures.map { $0.entry?.statement != nil }, [true, false, true, true, true, true, true],
                       "the other record as its hash alone")
        XCTAssertEqual(report.sequences.map(\.keyID), [keyID])
        XCTAssertEqual(report.sequences.first?.counters, Array(2...8))
        XCTAssertEqual(report.sequences.first?.retired, [1...1], "the retention statement accounts for counter 1")
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.export, EvidenceForm.Export(record: shared, revision: 2, signedAt: 1_793_000_009_000, app: "1.10 (81)",
                                                          shown: [EvidenceForm.KeyCounters(keyID: keyID, counters: [2...2, 4...7])]))
        XCTAssertEqual(report.unshown, [])
        XCTAssertEqual(report.unnamed, [], "it shows what its export names, and no more")
        XCTAssertEqual(report.unrelatedKeys, [])
        XCTAssertEqual(report.keyOrder, [keyID])
        XCTAssertEqual(report.afterExport, [])
        XCTAssertEqual(report.revisions.map(\.id), [shared, shared])
        XCTAssertEqual(report.revisions.map(\.revision), [1, 2])
        XCTAssertEqual(report.missingRevisions, [])
        XCTAssertTrue(report.revisionsInOrder)
        XCTAssertEqual(report.attachments, [found("primary", .matches), found("thumbnail", .matches), found("motionTrace", .matches)],
                       "against the latest revision, not the first (another thumbnail)")
        XCTAssertEqual(report.notes, notes)
        XCTAssertEqual(report.problems, [])
    }

    func testACounterNothingAccountsForIsMissing() throws {
        let phone = try TestPhone()
        try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // 1
        try phone.sign(record(other, 1), kept: false)                                    // 2: lost, and nothing names it
        try phone.sign(record(other, 2))                                                 // 3
        try phone.sign(export(shared, 1), shown: true)                                   // 4
        let report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.sequences.first?.counters, [1, 3, 4])
        XCTAssertEqual(report.sequences.first?.retired, [])
        XCTAssertEqual(report.sequences.first?.missing, [2...2])
        XCTAssertEqual(report.export?.revision, 1)
    }

    func testARetentionStatementCountsOnlyFromTheKeyOrAKeyThatFollowsIt() throws {
        for thirdFollows in [false, true] {
            let phone = try TestPhone()
            let first = try phone.certifyKey()
            try phone.sign(record(retiredRecord, 1), kept: false)                            // A1
            try phone.sign(record(other, 1), kept: false)                                    // A2
            try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // A3
            // A restore from a backup: App Attest no longer has key A, and key B follows it.
            let second = try phone.certifyKey(follows: first.keyID)
            try phone.sign(retention([(first.keyID, [1...1])]), shown: true)                 // B1
            // A third key: one that follows B after a second restore (and so A), or one that follows no key.
            let third = try phone.certifyKey(follows: thirdFollows ? second.keyID : nil)
            try phone.sign(retention([(first.keyID, [2...2])]), shown: true)                 // C1
            try phone.sign(export(shared, 1), shown: true)                                   // C2
            let report = try check(try written(try contents(phone)), phone)
            XCTAssertEqual(report.sequences.map(\.keyID), [first.keyID, second.keyID, third.keyID])
            XCTAssertEqual(report.afterExport, [], "key A's counter 3 is above the export's 2, but it is another key's")
            let sequence = try XCTUnwrap(report.sequences.first)
            XCTAssertEqual(sequence.counters, [3])
            if thirdFollows {
                XCTAssertEqual(sequence.retired, [1...2], "B follows A, and C follows B")
                XCTAssertEqual(sequence.missing, [])
            } else {
                XCTAssertEqual(sequence.retired, [1...1], "B follows A")
                XCTAssertEqual(sequence.missing, [2...2], "a key that does not follow A retires none of its counters")
            }
        }
    }

    /// A statement that signed records left the phone's log other than by its limit (item 182) is named in the report,
    /// for a verifier to say so.
    func testAStatementThatSignedRecordsLeftTheLogIsNamedInTheReport() throws {
        let phone = try TestPhone()
        try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // 1
        try phone.sign(record(other, 1))                                                 // 2: gone from the log since
        let gone = EvidenceForm.Absence(signedAt: 1_793_000_008_000, app: "1.10 (81)",
                                        records: [EvidenceForm.Absent(id: other, revision: 1, startDate: 1_793_000_000_000)])
        try phone.sign(.absence(gone), shown: true)                                      // 3
        try phone.sign(export(shared, 1), shown: true)                                   // 4
        let report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.absences, [gone])
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.problems, [])
        // A whole bundle with none names none.
        XCTAssertEqual(try check(try written(try contents(try standardPhone())), phone).absences, [])
    }

    /// The export statement names every statement its bundle shows (item 182, the owner's "B"): one sent as its hash
    /// alone, by someone passing the bundle on, is named, and its counter still counts.
    func testAStatementTheExportNamesAsShownMustBeShown() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // 1
        try phone.sign(record(armed, 1), shown: true)                                    // 2: the watch's arm
        try phone.sign(record(other, 1))                                                 // 3: as its hash
        try phone.sign(export(shared, 1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
        XCTAssertEqual(try check(try written(try contents(phone)), phone).unshown, [], "the bundle shows what its export names")
        let arm = phone.signatures[1]
        phone.signatures[1] = EvidenceBundle.Signature(key: arm.key, assertion: arm.assertion, statement: arm.statement, shown: false)
        let report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.unshown, [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [2...2])])
        XCTAssertEqual(report.sequences.first?.missing, [], "its counter still counts")
    }

    /// And the other way (item 190, codex-1 and deepseek-4): a statement shown in full that the export does not name was
    /// put in by someone passing the bundle on, its line marked shown and its statement copied from another bundle of the
    /// phone's; named, the export's own line apart, an earlier share's export statement among them.
    func testAStatementShownThatTheExportDoesNotNameIsNamed() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // 1
        try phone.sign(record(armed, 1), shown: true)                                    // 2: the watch's arm
        try phone.sign(export(other, 1))                                                 // 3: an earlier share's, as its hash
        try phone.sign(record(other, 1))                                                 // 4: as its hash
        try phone.sign(export(shared, 1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
        XCTAssertEqual(try check(try written(try contents(phone)), phone).unnamed, [], "the phone shows what its export names")
        for index in [2, 3] {
            let line = phone.signatures[index]
            phone.signatures[index] = EvidenceBundle.Signature(key: line.key, assertion: line.assertion, statement: line.statement,
                                                               shown: true)
        }
        let report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.unnamed, [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [3...4])])
        XCTAssertEqual(report.unshown, [])
        XCTAssertEqual(report.sequences.first?.missing, [], "their counters still count")
        XCTAssertEqual(report.problems, [], "a fact for a verifier to report")
        // Without an export statement there is nothing to name them against: the missing export is the finding.
        phone.signatures.removeLast()
        XCTAssertEqual(try check(try written(try contents(phone)), phone).unnamed, [])
    }

    /// Every key must be the export's or one it follows, by the key statements' `follows` (item 190, codex-1): a restore's
    /// keys are the phone's, in the order made; another phone's key, certified by Apple as every phone's is, and a key the
    /// export's key does not follow, are named.
    func testAKeyThatIsNeitherTheExportsNorOneItFollowsIsNamed() throws {
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // A1
        // A restore from a backup: key B follows A, and signs the export.
        let second = try phone.certifyKey(follows: first.keyID)
        try phone.sign(export(shared, 1, shown: [EvidenceForm.KeyCounters(keyID: first.keyID, counters: [1...1])]), shown: true)
        var report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.unrelatedKeys, [])
        XCTAssertEqual(report.keyOrder, [first.keyID, second.keyID], "the order the phone made them in")
        XCTAssertEqual(report.unnamed, [])
        // A key whose certification does not check out is a problem of its own, named with its key, not one of these.
        let damaged = EvidenceBundle.Contents(record: shared,
                                             keys: [EvidenceBundle.Key(id: first.keyID, statement: first.statement,
                                                                       attestation: Data("not Apple's".utf8))] + [phone.bundleKeys[1]],
                                             signatures: phone.signatures, notes: [], attachments: try latestFiles())
        let damagedReport = try check(try written(damaged), phone)
        XCTAssertNotNil(damagedReport.keys.first?.problem)
        XCTAssertEqual(damagedReport.unrelatedKeys, [], "a key not certified is named as such")
        // Another phone's key and a status it signed, put in by someone passing the bundle on.
        let stranger = TestPhone(chain: phone.chain)
        let strangerKey = try stranger.certifyKey()
        try stranger.sign(record(disarmed, 1), shown: true)
        let mixed = EvidenceBundle.Contents(record: shared, keys: stranger.bundleKeys + phone.bundleKeys,
                                           signatures: stranger.signatures + phone.signatures, notes: [], attachments: try latestFiles())
        report = try check(try written(mixed), phone)
        XCTAssertEqual(report.keys.compactMap(\.key).count, 3, "certified, as every phone's key is")
        XCTAssertEqual(report.unrelatedKeys, [strangerKey.keyID])
        XCTAssertEqual(report.keyOrder, [first.keyID, second.keyID])
        XCTAssertEqual(report.unnamed, [EvidenceForm.KeyCounters(keyID: strangerKey.keyID, counters: [1...1])])
        // A key that follows none, beside the keys it should have followed.
        let third = try phone.certifyKey()
        try phone.sign(export(shared, 1, shown: [EvidenceForm.KeyCounters(keyID: first.keyID, counters: [1...1])]), shown: true)
        report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.unrelatedKeys, [first.keyID, second.keyID])
        XCTAssertEqual(report.keyOrder, [third.keyID])
        XCTAssertNil(report.chainBreak, "the export's chain ends at a key that follows none: it stops nowhere")
    }

    /// Item 190's deepseek-1 on 29d6501: a backup edited to take out the last key's lines and keep the earlier keys': the
    /// next key follows the key taken out, which the bundle does not hold, so the export's chain stops there and the
    /// earlier keys cannot be tied to it. They are still named, the history being cut, and the check says where the chain
    /// stops (`chainBreak`), so that a verifier names them as cut off by that key, not as another phone's (the owner's
    /// "b").
    func testWhereTheExportsChainStopsAtAKeyTheBundleLacksIsSaid() throws {
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)
        let second = try phone.certifyKey(follows: first.keyID)
        try phone.sign(record(armed, 1), shown: false)
        let lost = Data(repeating: 0xC3, count: 32)   // the key the edit took out: no line of it in the bundle
        let next = try phone.certifyKey(follows: lost)
        try phone.sign(export(shared, 1, shown: [EvidenceForm.KeyCounters(keyID: first.keyID, counters: [1...1])]), shown: true)
        let report = try check(try written(try contents(phone)), phone)
        XCTAssertEqual(report.keyOrder, [next.keyID])
        XCTAssertEqual(report.unrelatedKeys, [first.keyID, second.keyID], "still named: the history was cut")
        XCTAssertEqual(report.chainBreak, lost)
    }

    /// A statement hidden between two shown is named alone.
    func testAHiddenStatementBetweenTwoShownIsNamedAlone() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(record(shared, 1, attachments: latestAttachments), shown: true)   // 1
        try phone.sign(record(armed, 1), shown: false)                                   // 2: named as shown, sent as its hash
        try phone.sign(record(disarmed, 1), shown: true)                                 // 3
        try phone.sign(export(shared, 1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...3])]), shown: true)
        XCTAssertEqual(try check(try written(try contents(phone)), phone).unshown,
                       [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [2...2])])
    }

    /// What several ranges name and the counters shown lack, range by range: within a range, at its ends, and a range
    /// with none shown.
    func testTheCountersNamedAndNotShownAreFoundAcrossSeveralRanges() {
        XCTAssertEqual(EvidenceBundle.gaps(in: [1...5, 8...9, 12...12, 20...21], present: [2, 4, 8, 12, 15]),
                       [1...1, 3...3, 5...5, 9...9, 20...21])
        XCTAssertEqual(EvidenceBundle.gaps(in: [1...3], present: [1, 2, 3]), [])
        XCTAssertEqual(EvidenceBundle.gaps(in: [UInt32.max - 1...UInt32.max], present: [UInt32.max]), [UInt32.max - 1...UInt32.max - 1])
    }

    /// codex-6 on 73441cbe: the check takes one pass through the ranges named and the counters shown, however many: 20,000
    /// of each is a moment's work, not four hundred million steps.
    func testTheShownCheckTakesOnePassThroughLongLists() {
        let counters = (0..<20_000).map { UInt32($0 * 2 + 1) }
        let ranges = counters.map { $0...$0 }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(EvidenceBundle.gaps(in: ranges, present: counters), [])
        XCTAssertEqual(EvidenceBundle.gaps(in: ranges, present: Array(counters.dropLast())), [39_999...39_999])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "seconds")
    }

    func testWithoutAnExportStatementTheEndIsUnaccountedFor() throws {
        // The export could not be signed (a key App Attest had lost): the bundle goes without it.
        let phone = try standardPhone()
        phone.signatures.removeLast()
        let report = try check(try written(try contents(phone)), phone)
        XCTAssertNil(report.export)
        XCTAssertEqual(report.record, shared, "the index's")
        XCTAssertEqual(report.revisions.map(\.revision), [1, 2])
        XCTAssertEqual(report.missingRevisions, [])
        XCTAssertTrue(report.revisionsInOrder)
        XCTAssertEqual(report.attachments.map(\.outcome), [.matches, .matches, .matches])
        XCTAssertEqual(report.sequences.first?.counters, Array(2...7))
    }

    func testOnlyTheLastLineIsTheBundlesExportAndItNamesTheRecord() throws {
        // A signature after the export statement: the bundle does not end with one.
        let after = try standardPhone()
        try after.sign(record(other, 2))                                                   // 9
        let notLast = try check(try written(try contents(after)), after)
        XCTAssertNil(notLast.export)
        XCTAssertEqual(notLast.afterExport, [])
        // The export statement last, after a signature of its key with a higher counter.
        let moved = try standardPhone()
        try moved.sign(record(other, 2))                                                   // 9
        moved.signatures.swapAt(moved.signatures.count - 1, moved.signatures.count - 2)
        let report = try check(try written(try contents(moved)), moved)
        XCTAssertEqual(report.export?.revision, 2)
        XCTAssertEqual(report.afterExport, [9])
        // An index naming another record than the export statement: the statement, signed, decides.
        let phone = try standardPhone()
        let misnamed = try check(try written(EvidenceBundle.Contents(record: other, keys: phone.bundleKeys, signatures: phone.signatures,
                                                                     notes: [], attachments: try latestFiles())), phone)
        XCTAssertEqual(misnamed.record, shared)
        XCTAssertEqual(misnamed.revisions.map(\.revision), [1, 2])
    }

    func testTheSharedRecordsRevisionsAreShownUpToTheOneTheExportNames() throws {
        // A revision shown as its hash alone is missing, and the attachments are checked against the latest shown.
        let hidden = try TestPhone()
        try hidden.certifyKey()
        try hidden.sign(record(shared, 1, attachments: earlierAttachments), shown: true)
        try hidden.sign(record(shared, 2, attachments: latestAttachments))
        try hidden.sign(export(shared, 2), shown: true)
        let missing = try check(try written(try contents(hidden)), hidden)
        XCTAssertEqual(missing.revisions.map(\.revision), [1])
        XCTAssertEqual(missing.missingRevisions, [2])
        XCTAssertTrue(missing.revisionsInOrder)
        XCTAssertEqual(missing.attachments, [found("primary", .matches), found("thumbnail", .differs), found("motionTrace", .notSigned)])
        // An export naming a revision beyond those shown: the ones up to it are missing.
        let beyond = try TestPhone()
        try beyond.certifyKey()
        try beyond.sign(record(shared, 1, attachments: latestAttachments), shown: true)
        try beyond.sign(export(shared, 3), shown: true)
        XCTAssertEqual(try check(try written(try contents(beyond)), beyond).missingRevisions, [2, 3])
        // An export naming a revision no phone reaches: the missing are listed only up to the verifier's limit.
        let far = try TestPhone()
        try far.certifyKey()
        try far.sign(record(shared, 1, attachments: latestAttachments), shown: true)
        try far.sign(export(shared, 1_000_000), shown: true)
        let farReport = try check(try written(try contents(far)), far)
        XCTAssertEqual(farReport.missingRevisions.count, 9_999)
        XCTAssertEqual(farReport.missingRevisions.last, 10_000)
        // A revision newer than the one the export names: not in order.
        let newer = try TestPhone()
        try newer.certifyKey()
        try newer.sign(record(shared, 1, attachments: latestAttachments), shown: true)
        try newer.sign(record(shared, 2, attachments: latestAttachments), shown: true)
        try newer.sign(export(shared, 1), shown: true)
        let ahead = try check(try written(try contents(newer)), newer)
        XCTAssertFalse(ahead.revisionsInOrder)
        XCTAssertEqual(ahead.missingRevisions, [])
        // Revisions signed out of order, or one signed twice: not in order either.
        for numbers: [Int64] in [[2, 1], [1, 1]] {
            let phone = try TestPhone()
            try phone.certifyKey()
            for number in numbers { try phone.sign(record(shared, number, attachments: latestAttachments), shown: true) }
            try phone.sign(export(shared, 2), shown: true)
            XCTAssertFalse(try check(try written(try contents(phone)), phone).revisionsInOrder, "\(numbers)")
        }
        // One signature listed twice is one signature: its revision is not repeated.
        let twice = try TestPhone()
        try twice.certifyKey()
        try twice.sign(record(shared, 1, attachments: latestAttachments), shown: true)
        try twice.sign(export(shared, 1), shown: true)
        twice.signatures.insert(twice.signatures[0], at: 1)
        let listedTwice = try check(try written(try contents(twice)), twice)
        XCTAssertEqual(listedTwice.revisions.map(\.revision), [1])
        XCTAssertTrue(listedTwice.revisionsInOrder)
    }

    func testEachAttachmentIsCheckedAgainstTheLatestRevision() throws {
        let phone = try standardPhone()
        // The photo gone from the phone (the storage cap), and a file the latest revision does not sign.
        let folder = try written(try contents(phone, attachments: [
            EvidenceBundle.Attachment(name: "thumbnail", file: "thumbnail.jpg", source: .bytes(thumbnail)),
            EvidenceBundle.Attachment(name: "motionTrace", file: "motionTrace", source: .bytes(trace)),
            EvidenceBundle.Attachment(name: "secondary", file: "secondary.mov", source: .bytes(Data("a clip".utf8))),
        ]))
        XCTAssertEqual(try check(folder, phone).attachments,
                       [found("primary", .notInBundle), found("thumbnail", .matches), found("motionTrace", .matches),
                        found("secondary", .notSigned)])
        // A byte changed, and a file the index lists that is not there.
        try Data("a thumbnail's bytez".utf8).write(to: folder.appendingPathComponent("attachments/thumbnail.jpg"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("attachments/motionTrace"))
        XCTAssertEqual(try check(folder, phone).attachments,
                       [found("primary", .notInBundle), found("thumbnail", .differs),
                        found("motionTrace", .unreadable(.fileMissing("attachments/motionTrace"))), found("secondary", .notSigned)])
    }

    func testAStatementShownThatIsMissingOrNotTheOneSignedIsNamedAndItsCounterStillCounts() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let path = statementPath(phone.signatures[4])   // counter 6: the shared record's second revision
        try FileManager.default.removeItem(at: folder.appendingPathComponent(path))
        let gone = try check(folder, phone)
        XCTAssertEqual(gone.signatures[4].problem, .fileMissing(path))
        XCTAssertEqual(gone.signatures[4].entry?.counter, 6, "its signature checks out over its hash")
        XCTAssertNil(gone.signatures[4].entry?.statement)
        XCTAssertEqual(gone.sequences.first?.missing, [], "its counter is accounted for")
        XCTAssertEqual(gone.revisions.map(\.revision), [1])
        XCTAssertEqual(gone.missingRevisions, [2])
        // Other bytes under its hash's name: the first revision's.
        try phone.signatures[2].statement.write(to: folder.appendingPathComponent(path))
        let changed = try check(folder, phone)
        XCTAssertEqual(changed.signatures[4].problem, .formHashMismatch)
        XCTAssertEqual(changed.signatures[4].entry?.counter, 6)
        XCTAssertNil(changed.signatures[4].entry?.statement)
        XCTAssertEqual(changed.sequences.first?.missing, [])
        XCTAssertEqual(changed.missingRevisions, [2])
        // More bytes than any statement a reader takes.
        try Data(count: (1 << 20) + 1).write(to: folder.appendingPathComponent(path))
        XCTAssertEqual(try check(folder, phone).signatures[4].problem, .unreadable("\(path) is too large"))
    }

    func testASignatureThatDoesNotCheckOutIsNamedAndAccountsForNothing() throws {
        let phone = try standardPhone()
        let stranger = try phone.chain.certify(at: TestApp.date(2026, 10, 31, 1, 0))   // a key the index does not list
        var signatures = phone.signatures
        // The line of counter 3, signed by the stranger's key under this key's name; then a line of the stranger's own.
        let third = signatures[1]
        signatures[1] = EvidenceBundle.Signature(
            key: third.key, assertion: try TestAttestation.assertion(by: stranger.key, formHash: TestApp.sha256(third.statement), counter: 3),
            statement: third.statement, shown: third.shown)
        signatures.insert(EvidenceBundle.Signature(
            key: stranger.keyID, assertion: try TestAttestation.assertion(by: stranger.key, formHash: TestApp.sha256(third.statement), counter: 1),
            statement: third.statement, shown: false), at: 2)
        let folder = try written(EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: signatures, notes: [],
                                                         attachments: try latestFiles()))
        // And a first line that is not one.
        let url = folder.appendingPathComponent("signatures.jsonl")
        try (Data(#"{"key":"not a key"}"#.utf8) + Data("\n".utf8) + Data(contentsOf: url)).write(to: url)
        let report = try check(folder, phone)
        XCTAssertEqual(report.signatures.count, 9)
        XCTAssertEqual(report.signatures[0], EvidenceBundle.SignatureCheck(line: 1, entry: nil, problem: .formNotFixed))
        XCTAssertEqual(report.signatures[2], EvidenceBundle.SignatureCheck(line: 3, entry: nil, problem: .signatureMismatch))
        XCTAssertEqual(report.signatures[3], EvidenceBundle.SignatureCheck(line: 4, entry: nil, problem: .notCertified))
        XCTAssertEqual(report.signatures.compactMap(\.entry?.counter), [2, 4, 5, 6, 7, 8])
        XCTAssertEqual(report.sequences.first?.missing, [3...3], "a signature that does not check out accounts for nothing")
        XCTAssertEqual(report.export?.revision, 2, "and the rest is checked")
    }

    func testAKeyWhoseCertificationFailsIsNamedAndItsSignaturesAccountForNothing() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let keyID = phone.keys[0].keyID
        let hex = TestApp.hex(keyID)
        // The roots and the app are the ones given.
        XCTAssertEqual(try EvidenceBundle.check(folder, appID: TestApp.id, roots: [try TestAttestationChain().rootDER]).keys.first?.problem,
                       .chainNotTrusted, "another root")
        XCTAssertEqual(try EvidenceBundle.check(folder, appID: "TESTTEAM00.com.example.other", roots: [phone.chain.rootDER]).keys.first?.problem,
                       .otherApp, "another app")
        // Phase 5 (the owner's ruling of 2026-10-31, "1 - a"): the Mac verifier gives the App ID's hash, as every
        // attestation carries it, so the published source never holds the team ID; the same report either way.
        XCTAssertEqual(try EvidenceBundle.check(folder, appIDHash: TestApp.sha256(Data(TestApp.id.utf8)), roots: [phone.chain.rootDER]),
                       try EvidenceBundle.check(folder, appID: TestApp.id, roots: [phone.chain.rootDER]), "the app's hash")
        XCTAssertEqual(try EvidenceBundle.check(folder, appIDHash: TestApp.sha256(Data("TESTTEAM00.com.example.other".utf8)),
                                                roots: [phone.chain.rootDER]).keys.first?.problem, .otherApp, "another app's hash")
        // Its files listed under another key's name: the certification names its own key.
        let misfiled = try written(try contents(phone))
        let otherHex = String(repeating: "ab", count: 32)
        for type in ["json", "cbor"] {
            try FileManager.default.moveItem(at: misfiled.appendingPathComponent("keys/\(hex).\(type)"),
                                             to: misfiled.appendingPathComponent("keys/\(otherHex).\(type)"))
        }
        let misfiledIndex = misfiled.appendingPathComponent("bundle.json")
        try Data(try String(contentsOf: misfiledIndex, encoding: .utf8).replacingOccurrences(of: hex, with: otherHex).utf8).write(to: misfiledIndex)
        let underAnotherName = try check(misfiled, phone)
        XCTAssertEqual(underAnotherName.keys, [EvidenceBundle.KeyCheck(keyID: Data(repeating: 0xAB, count: 32), key: nil, problem: .keyMismatch)])
        XCTAssertEqual(underAnotherName.signatures.map(\.problem), Array(repeating: .notCertified, count: 7))
        // Another statement than the one Apple's certificate covers.
        try TestApp.keyStatement(keyID: keyID, signedAt: 1).write(to: folder.appendingPathComponent("keys/\(hex).json"))
        let report = try check(folder, phone)
        XCTAssertEqual(report.keys, [EvidenceBundle.KeyCheck(keyID: keyID, key: nil, problem: .notForThisStatement)])
        XCTAssertEqual(report.signatures.map(\.problem), Array(repeating: .notCertified, count: 7))
        XCTAssertEqual(report.sequences, [])
        XCTAssertNil(report.export)
        XCTAssertEqual(report.revisions, [])
        // Its attestation gone.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("keys/\(hex).cbor"))
        XCTAssertEqual(try check(folder, phone).keys.first?.problem, .fileMissing("keys/\(hex).cbor"))
    }

    func testAnIndexThatIsNotThePhonesIsRefused() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let index = folder.appendingPathComponent("bundle.json")
        let original = try String(contentsOf: index, encoding: .utf8)
        let hex = TestApp.hex(phone.keys[0].keyID)
        let refused: [(String, EvidenceProblem, String)] = [
            // "/2" is a bundle that holds an unkept statement (item 188, ADR 0073): a newer format is "/3".
            (original.replacingOccurrences(of: "bundle/1", with: "bundle/3"), .unknownFormat("malinois-evidence-bundle/3"), "a newer format"),
            (original.replacingOccurrences(of: #","keys""#, with: #", "keys""#), .formNotFixed, "whitespace"),
            (original.replacingOccurrences(of: "6F1E2D3C", with: "6f1e2d3c"), .formNotFixed, "a UUID not as the phone writes it"),
            (original.replacingOccurrences(of: hex, with: hex.uppercased()), .formNotFixed, "a key in uppercase hex"),
            (original.replacingOccurrences(of: #"["\#(hex)"]"#, with: #"["\#(hex)","\#(hex)"]"#), .formNotFixed, "a key twice"),
            (original.replacingOccurrences(of: #"["\#(hex)"]"#, with: #"["\#(hex.dropLast(2))"]"#), .formNotFixed, "a key of 31 bytes"),
            (original.replacingOccurrences(of: #""keys""#, with: #""key""#), .formNotFixed, "a member renamed"),
            (original.replacingOccurrences(of: #""primary.jpg""#, with: #""../primary.jpg""#), .formNotFixed, "a file outside the attachments"),
            (original.replacingOccurrences(of: #""primary.jpg""#, with: #""primary/x.jpg""#), .formNotFixed, "a file in a folder"),
            (original.replacingOccurrences(of: #""primary.jpg""#, with: #""thumbnail.jpg""#), .formNotFixed, "another attachment's file"),
            (original.replacingOccurrences(of: #"{"name":"thumbnail","file":"thumbnail.jpg"}"#, with: #"{"name":"primary","file":"primary.png"}"#),
             .formNotFixed, "a name twice"),
            (original.replacingOccurrences(of: #"{"name":"thumbnail","file":"thumbnail.jpg"}"#, with: #"{"name":"Primary","file":"Primary.png"}"#),
             .formNotFixed, "a name twice, in two letter cases"),
        ]
        for (text, problem, why) in refused {
            XCTAssertNotEqual(text, original, why)
            try Data(text.utf8).write(to: index)
            assertRefused(problem, why) { try self.check(folder, phone) }
        }
        try FileManager.default.removeItem(at: index)
        assertRefused(.fileMissing("bundle.json"), "a bundle cut short before its index") { try self.check(folder, phone) }
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        assertRefused(.unreadable("bundle.json is not a plain file in the bundle"), "a folder in its place") { try self.check(folder, phone) }
        try FileManager.default.removeItem(at: index)
        try Data(original.utf8).write(to: index)
        XCTAssertNoThrow(try check(folder, phone), "the phone's own index")
    }

    func testOnlyPlainFilesInTheBundleAreRead() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let manager = FileManager.default
        // A link in place of an attachment, to a file with the very bytes signed.
        let outside = base.appendingPathComponent("outside.jpg")
        try thumbnail.write(to: outside)
        let thumbnailFile = folder.appendingPathComponent("attachments/thumbnail.jpg")
        try manager.removeItem(at: thumbnailFile)
        try manager.createSymbolicLink(at: thumbnailFile, withDestinationURL: outside)
        // A link in place of a statement shown, the second revision's, to its very bytes.
        let path = statementPath(phone.signatures[4])
        let statementFile = folder.appendingPathComponent(path)
        let moved = base.appendingPathComponent("statement-outside.json")
        try manager.moveItem(at: statementFile, to: moved)
        try manager.createSymbolicLink(at: statementFile, withDestinationURL: moved)
        let report = try check(folder, phone)
        XCTAssertEqual(report.attachments[1], found("thumbnail", .unreadable(.unreadable("attachments/thumbnail.jpg is not a plain file in the bundle"))))
        XCTAssertEqual(report.signatures[4].problem, .unreadable("\(path) is not a plain file in the bundle"))
        XCTAssertEqual(report.signatures[4].entry?.counter, 6)
        // The statement back in its place (the second revision the latest shown again), then a link in place of the
        // attachments folder, to a folder with the very files.
        try manager.removeItem(at: statementFile)
        try manager.moveItem(at: moved, to: statementFile)
        let attachments = folder.appendingPathComponent("attachments")
        let elsewhere = base.appendingPathComponent("attachments-elsewhere")
        try manager.moveItem(at: attachments, to: elsewhere)
        try manager.removeItem(at: elsewhere.appendingPathComponent("thumbnail.jpg"))
        try thumbnail.write(to: elsewhere.appendingPathComponent("thumbnail.jpg"))
        try Data("another photo".utf8).write(to: elsewhere.appendingPathComponent("another.jpg"))
        try manager.createSymbolicLink(at: attachments, withDestinationURL: elsewhere)
        let linked = try check(folder, phone)
        XCTAssertEqual(linked.attachments.map(\.outcome),
                       ["primary.jpg", "thumbnail.jpg", "motionTrace.bin"].map {
                           EvidenceBundle.AttachmentOutcome.unreadable(.unreadable("attachments/\($0) is not a plain file in the bundle"))
                       })
        XCTAssertEqual(linked.unlisted, ["attachments"], "the link named, and what it points to never listed (item 187)")
    }

    /// Codex's codex-1 on 07b7134 (item 187's round B): a name on the layout's list counts only as a plain file. The
    /// README, which no check reads, passed whatever it was, so a folder named README.txt hid whatever it held.
    func testANameOnTheLayoutsListCountsOnlyAsAPlainFile() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let readme = folder.appendingPathComponent(EvidenceBundle.readmeName)
        let manager = FileManager.default
        try manager.removeItem(at: readme)
        try manager.createDirectory(at: readme, withIntermediateDirectories: false)
        try Data("an unsigned photo".utf8).write(to: readme.appendingPathComponent("unsigned-photo.jpg"))
        XCTAssertEqual(try check(folder, phone).unlisted, [EvidenceBundle.readmeName], "a folder in the README's place")
        try manager.removeItem(at: readme)
        let outside = base.appendingPathComponent("README-elsewhere.txt")
        try Data(EvidenceBundle.readme.utf8).write(to: outside)
        try manager.createSymbolicLink(at: readme, withDestinationURL: outside)
        XCTAssertEqual(try check(folder, phone).unlisted, [EvidenceBundle.readmeName], "a link in the README's place")
    }

    /// Item 187's round B (Claude's, found while fixing Codex's findings on 07b7134): Foundation's folder listings on
    /// macOS leave out every name that begins "._", so a photo added under such a name, beside the index or in
    /// `attachments/`, passed the Mac's check unseen. Every name in the bundle is listed now.
    func testANameBeginningWithADotAndAnUnderscoreIsListedToo() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        for path in ["._unsigned-photo.jpg", "attachments/._unsigned-photo.jpg"] {
            try Data("an unsigned photo".utf8).write(to: folder.appendingPathComponent(path))
        }
        XCTAssertEqual(try check(folder, phone).unlisted, ["._unsigned-photo.jpg", "attachments/._unsigned-photo.jpg"])
    }

    /// Item 187 (codex-1): a folder of the bundle that cannot be listed is a problem, never taken as empty.
    func testAFolderOfTheBundleThatCannotBeListedIsAProblem() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        let statements = folder.appendingPathComponent("statements")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: statements.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statements.path) }
        let report = try check(folder, phone)
        XCTAssertTrue(report.problems.contains(.unreadable("statements cannot be listed")), "\(report.problems)")
        XCTAssertEqual(report.unlisted, [])
    }

    /// Codex's codex-1 on 09d997f: the check read only the files the index lists, so a photo added to a bundle on its way
    /// passed unseen, in `attachments/` or anywhere else in it, while SECURITY.md says a passing check covers each photo,
    /// clip and trace in the ZIP. Every file and folder in the bundle must now be one its layout names, and any other is
    /// named; Finder's own `.DS_Store` files, which it leaves in a folder it shows, are named apart and not judged (the
    /// owner's "codex-1 a").
    func testEveryFileInTheBundleIsOneItsLayoutNames() throws {
        let phone = try standardPhone()
        let folder = try written(try contents(phone))
        var report = try check(folder, phone)
        XCTAssertEqual(report.unlisted, [], "a bundle as the phone writes it")
        XCTAssertEqual(report.ignored, [])
        let manager = FileManager.default
        func add(_ path: String) throws { try Data("added".utf8).write(to: folder.appendingPathComponent(path)) }
        try add("attachments/another.jpg")   // a photo added on the way
        try add("notes.txt")
        let keyFile = "keys/\(TestApp.hex(phone.keys[0].keyID)).pem"
        try add(keyFile)
        // The statement of the signature the bundle shows as its hash alone: the layout has no place for it.
        let hidden = statementPath(phone.signatures[1])
        try phone.signatures[1].statement.write(to: folder.appendingPathComponent(hidden))
        try manager.createDirectory(at: folder.appendingPathComponent("more/inside"), withIntermediateDirectories: true)
        try add("more/inside/photo.jpg")
        try manager.createSymbolicLink(at: folder.appendingPathComponent("statements/linked"), withDestinationURL: base)
        try add(".DS_Store")
        try add("attachments/.DS_Store")
        report = try check(folder, phone)
        XCTAssertEqual(report.unlisted, ["attachments/another.jpg", keyFile, "more", "notes.txt", hidden, "statements/linked"].sorted(),
                       "each named, a folder the layout does not name as itself, a link never followed")
        XCTAssertEqual(report.ignored, [".DS_Store", "attachments/.DS_Store"], "Finder's own files, named apart")
        XCTAssertEqual(report.attachments, [found("primary", .matches), found("thumbnail", .matches), found("motionTrace", .matches)],
                       "the files the layout names judged as before")
        XCTAssertEqual(report.problems, [])
    }

    func testTheNotesAreReadAsThePhoneWroteThemAndWhatCannotBeReadIsNamed() throws {
        let notes: [EvidenceBundle.Note] = [.keyLost(key: Data(repeating: 0x5E, count: 32), at: 1_793_000_000_000),
                                            .keyLost(key: Data(repeating: 0x6F, count: 32), at: nil)]
        let folder = try written(EvidenceBundle.Contents(record: shared, keys: [], signatures: [], notes: notes, attachments: []))
        let report = try EvidenceBundle.check(folder, appID: TestApp.id, roots: [])
        XCTAssertEqual(report.notes, notes)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.record, shared)
        XCTAssertEqual(report.keys, [])
        XCTAssertEqual(report.signatures, [])
        XCTAssertNil(report.export)
        // Lines that are not notes are named, and the rest still read.
        let url = folder.appendingPathComponent("notes.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8)
        // An earlier build's note of records set aside is not one the phone writes (codex-2 on 5fa9ec18, the owner's "a").
        let notNotes = [#"{"kind":"setAside","records":3,"at":null}"#,
                        #"{"kind":"keyLost","kee":"\#(String(repeating: "5e", count: 32))","at":1}"#, #"{"kind":"keyLost","key":null}"#]
        try (#"{"kind":"keyFound","key":null,"at":1}"# + "\n" + lines + notNotes.map { $0 + "\n" }.joined())
            .write(to: url, atomically: true, encoding: .utf8)
        let damaged = try EvidenceBundle.check(folder, appID: TestApp.id, roots: [])
        XCTAssertEqual(damaged.notes, notes)
        XCTAssertEqual(damaged.problems, [1, 4, 5, 6].map { EvidenceProblem.unreadable("notes.jsonl, line \($0)") },
                       "the first line and the three after the phone's two")
        // Files missing.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("signatures.jsonl"))
        XCTAssertEqual(try EvidenceBundle.check(folder, appID: TestApp.id, roots: []).problems,
                       [.fileMissing("signatures.jsonl"), .fileMissing("notes.jsonl")])
    }

    // MARK: - Helpers

    /// The phone of most tests: one key; a record the log's limit retired (its signature gone, a retention statement
    /// naming its counter); the watch around the incident, its arm and disarm shown; another record as its hash alone;
    /// the shared record's two revisions shown; then the export statement.
    private func standardPhone() throws -> TestPhone {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(record(retiredRecord, 1), kept: false)                              // 1
        try phone.sign(record(armed, 1), shown: true)                                      // 2
        try phone.sign(record(other, 1))                                                   // 3
        try phone.sign(record(shared, 1, attachments: earlierAttachments), shown: true)    // 4
        try phone.sign(retention([(key.keyID, [1...1])]), shown: true)                     // 5
        try phone.sign(record(shared, 2, attachments: latestAttachments), shown: true)     // 6
        try phone.sign(record(disarmed, 1), shown: true)                                   // 7
        // Naming what it shows, as the phone's export does (item 182, the owner's "B").
        try phone.sign(export(shared, 2, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [2...2, 4...7])]),
                       shown: true)                                                        // 8
        return phone
    }

    /// The shared record's attachments as its first revision signed them: the photo, and another thumbnail.
    private var earlierAttachments: [EvidenceForm.Attachment] {
        [EvidenceForm.Attachment(name: "primary", digest: EvidenceHash.digest(of: photo)),
         EvidenceForm.Attachment(name: "thumbnail", digest: EvidenceHash.digest(of: otherThumbnail))]
    }

    /// As its latest revision signed them: the photo, the thumbnail and a motion trace.
    private var latestAttachments: [EvidenceForm.Attachment] {
        [EvidenceForm.Attachment(name: "primary", digest: EvidenceHash.digest(of: photo)),
         EvidenceForm.Attachment(name: "thumbnail", digest: EvidenceHash.digest(of: thumbnail)),
         EvidenceForm.Attachment(name: "motionTrace", digest: EvidenceHash.digest(of: trace))]
    }

    /// The latest revision's attachments as the phone hands them over: the photo as a file, the rest in memory.
    private func latestFiles() throws -> [EvidenceBundle.Attachment] {
        let onThePhone = base.appendingPathComponent("photo-on-the-phone.jpg")
        try photo.write(to: onThePhone)
        return [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg", source: .file(onThePhone)),
                EvidenceBundle.Attachment(name: "thumbnail", file: "thumbnail.jpg", source: .bytes(thumbnail)),
                EvidenceBundle.Attachment(name: "motionTrace", file: "motionTrace.bin", source: .bytes(trace))]
    }

    private func contents(_ phone: TestPhone, notes: [EvidenceBundle.Note] = [],
                          attachments: [EvidenceBundle.Attachment]? = nil) throws -> EvidenceBundle.Contents {
        EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: notes,
                                attachments: try attachments ?? latestFiles())
    }

    /// Writes `contents` as a new bundle in the test's folder.
    private func written(_ contents: EvidenceBundle.Contents) throws -> URL {
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)")
        try EvidenceBundle.write(contents, to: folder)
        return folder
    }

    private func check(_ folder: URL, _ phone: TestPhone) throws -> EvidenceBundle.Report {
        try EvidenceBundle.check(folder, appID: TestApp.id, roots: [phone.chain.rootDER])
    }

    private func record(_ id: UUID, _ revision: Int64, attachments: [EvidenceForm.Attachment] = []) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: id, revision: revision, signedAt: 1_793_000_000_000 + revision, app: "1.10 (81)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))], attachments: attachments))
    }

    private func retention(_ retired: [(Data, [ClosedRange<UInt32>])]) -> EvidenceForm.Statement {
        .retention(EvidenceForm.Retention(signedAt: 1_793_000_000_500, app: "1.10 (81)",
                                          retired: retired.map { EvidenceForm.Retired(keyID: $0.0, counters: $0.1) }))
    }

    private func export(_ id: UUID, _ revision: Int64, shown: [EvidenceForm.KeyCounters] = []) -> EvidenceForm.Statement {
        .export(EvidenceForm.Export(record: id, revision: revision, signedAt: 1_793_000_009_000, app: "1.10 (81)", shown: shown))
    }

    private func found(_ name: String, _ outcome: EvidenceBundle.AttachmentOutcome) -> EvidenceBundle.AttachmentCheck {
        EvidenceBundle.AttachmentCheck(name: name, outcome: outcome)
    }

    /// Where a statement shown sits in a bundle: under its hash.
    private func statementPath(_ signature: EvidenceBundle.Signature) -> String {
        "statements/\(TestApp.hex(TestApp.sha256(signature.statement))).json"
    }

    private func assertRefused(_ problem: EvidenceProblem, _ why: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Any) {
        XCTAssertThrowsError(try body(), why, file: file, line: line) {
            XCTAssertEqual($0 as? EvidenceProblem, problem, why, file: file, line: line)
        }
    }
}

/// A phone's signing history, made with a test chain: its keys certified in order, each signing with a counter that rises
/// from 1, and the signatures its file keeps, in the order made.
final class TestPhone {   // also the Mac verifier's tests (Item90VerifierTests)
    let chain: TestAttestationChain
    private(set) var keys: [TestCertifiedKey] = []
    /// What the file keeps, in order; a test may change it.
    var signatures: [EvidenceBundle.Signature] = []
    private var counters: [Data: UInt32] = [:]
    /// The App ID's hash its keys are certified and sign for: the test app's, or Malinois's own (item 187).
    let appIDHash: Data?

    init(appIDHash: Data? = nil) throws {
        chain = try TestAttestationChain()
        self.appIDHash = appIDHash
    }

    /// Another phone, its keys certified by `chain` as Apple certifies every phone's (item 190, codex-1).
    init(chain: TestAttestationChain, appIDHash: Data? = nil) {
        self.chain = chain
        self.appIDHash = appIDHash
    }

    /// A new key certified by the chain, its statement naming the key it follows after a restore, or none.
    @discardableResult
    func certifyKey(follows: Data? = nil, app: String = "1.10 (81)") throws -> TestCertifiedKey {
        var shape = TestAttestationShape()
        shape.appIDHash = appIDHash
        let made = try chain.certify(at: TestApp.date(2026, 10, 31, 1, 0), shape: shape) { keyID in
            EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: keyID, signedAt: 1_793_000_000_000, app: app, follows: follows)))
        }
        keys.append(made)
        return made
    }

    /// Signs `statement` with the newest key at its next counter, and keeps the signature, the statement shown or as its
    /// hash; `kept: false` for one the file no longer has (its counter spent all the same).
    func sign(_ statement: EvidenceForm.Statement, shown: Bool = false, kept: Bool = true) throws {
        let key = try XCTUnwrap(keys.last)
        let counter = (counters[key.keyID] ?? 0) + 1
        counters[key.keyID] = counter
        let bytes = EvidenceForm.bytes(statement)
        let assertion = try TestAttestation.assertion(by: key.key, formHash: TestApp.sha256(bytes), counter: counter,
                                                      appIDHash: appIDHash)
        if kept { signatures.append(EvidenceBundle.Signature(key: key.keyID, assertion: assertion, statement: bytes, shown: shown)) }
    }

    /// The newest key's count goes back by `steps`, as a forced restart took App Attest's back on the owner's phone (item 205).
    func rollBackCount(by steps: UInt32) {
        guard let key = keys.last else { return }
        counters[key.keyID] = (counters[key.keyID] ?? 0) - min(steps, counters[key.keyID] ?? 0)
    }

    /// The keys, as a bundle lists them.
    var bundleKeys: [EvidenceBundle.Key] {
        keys.map { EvidenceBundle.Key(id: $0.keyID, statement: $0.statement, attestation: $0.attestation) }
    }
}
