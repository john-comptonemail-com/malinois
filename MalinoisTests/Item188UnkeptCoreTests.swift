//
//  Item188UnkeptCoreTests.swift
//  MalinoisTests
//
//  BACKLOG item 188 (item 192's step 1; ADR 0073, accepted with the format "A"): the unkept statement, the sixth
//  statement kind, in the evidence core the phone and the Mac verifier share. It names counters of the key that signs it
//  that App Attest made and the phone's file did not keep. A verifier counts them as accounted for only when the key
//  itself signed the statement, and only below the statement's own counter, and reports them as made and not kept, not
//  as missing; a bundle that holds one names the format "malinois-evidence-bundle/2", every other bundle "/1", and a
//  check reads both. Keys certified by test chains made at run time. Written before the code, red at that commit
//  (against compile-only stubs).
//

import XCTest
@testable import Malinois

final class Item188UnkeptCoreTests: XCTestCase {

    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("Item188UnkeptCore-\(UUID().uuidString)")
    private let shared = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2") ?? UUID()
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: - The statement

    func testTheUnkeptStatementIsWrittenInItsFixedFormAndReadBack() throws {
        let statement = unkept([3...4, 7...7])
        let bytes = EvidenceForm.bytes(statement)
        XCTAssertEqual(TestApp.text(bytes),
                       #"{"format":"malinois-evidence/1","type":"unkept","signedAt":1793000000700,"app":"1.11 (83)","#
                       + #""counters":[[3,4],[7,7]]}"#)
        XCTAssertEqual(try EvidenceForm.read(bytes), statement)
    }

    func testAnUnkeptStatementNotInItsOneSpellingIsRefused() {
        let layout = #"{"format":"malinois-evidence/1","type":"unkept","signedAt":1793000000700,"app":"1.11 (83)","counters":COUNTERS}"#
        let counters = ["[]", "[[0,2]]", "[[4,3]]", "[[3,4],[5,6]]", "[[3,4],[4,6]]", "[[5,6],[1,2]]", "[[1,4294967296]]",
                        "[[1]]", "[[1,2,3]]", "[3]", "null", #"[["1","2"]]"#]
        var refused = counters.map { (layout.replacingOccurrences(of: "COUNTERS", with: $0), "counters \($0)") }
        refused += [
            (#"{"format":"malinois-evidence/1","type":"unkept","signedAt":1793000000700,"app":"","counters":[[1,1]]}"#, "no app"),
            (#"{"format":"malinois-evidence/1","type":"unkept","app":"1.11 (83)","signedAt":1793000000700,"counters":[[1,1]]}"#,
             "its members in another order"),
            (#"{"format":"malinois-evidence/1","type":"unkept","signedAt":1793000000700,"app":"1.11 (83)","counters":[[1,1]],"#
                + #""key":"\#(String(repeating: "a1", count: 32))"}"#, "a member more"),
            (#"{"format":"malinois-evidence/1","type":"unkept","signedAt":1793000000700,"app":"1.11 (83)"}"#, "no counters"),
            (#"{"format":"malinois-evidence/1","type":"unkept","signedAt":null,"app":"1.11 (83)","counters":[[1,1]]}"#, "no time"),
        ]
        for (text, why) in refused {
            XCTAssertThrowsError(try EvidenceForm.read(Data(text.utf8)), why) {
                XCTAssertEqual($0 as? EvidenceProblem, .formNotFixed, why)
            }
        }
    }

    // MARK: - A key's counters

    func testAnUnkeptStatementOfTheKeysOwnAccountsForTheCountersBelowItsOwn() {
        let named = EvidenceVerifier.sequence(of: [signed(keyA, 1, record(1)), signed(keyA, 2, nil), signed(keyA, 5, unkept([3...4]))],
                                              keyID: keyA, followers: [])
        XCTAssertEqual(named.counters, [1, 2, 5])
        XCTAssertEqual(named.unkept, [3...4], "made by App Attest and not kept by the phone")
        XCTAssertEqual(named.missing, [], "not missing")
        XCTAssertEqual(named.retired, [])
        // Beside a retention statement, each gap is what its statement says.
        let both = EvidenceVerifier.sequence(of: [signed(keyA, 1, record(1)), signed(keyA, 3, retention([(keyA, [2...2])])),
                                                  signed(keyA, 6, unkept([4...5]))], keyID: keyA, followers: [])
        XCTAssertEqual(both.retired, [2...2])
        XCTAssertEqual(both.unkept, [4...5])
        XCTAssertEqual(both.missing, [])
        // Shown only as its hash, the statement accounts for nothing (what it says is not in the bundle): the gap is
        // missing, as before.
        let hidden = EvidenceVerifier.sequence(of: [signed(keyA, 1, record(1)), signed(keyA, 2, nil), signed(keyA, 5, nil)],
                                               keyID: keyA, followers: [])
        XCTAssertEqual(hidden.unkept, [])
        XCTAssertEqual(hidden.missing, [3...4])
    }

    /// ADR 0073, decision 5: a statement accounts only for counters below its own, as the phone names them; one naming a
    /// counter at or above its own accounts for none of those.
    func testAnUnkeptStatementCountsOnlyBelowItsOwnCounter() {
        let partly = EvidenceVerifier.sequence(of: [signed(keyA, 1, record(1)), signed(keyA, 3, unkept([2...2, 4...5])),
                                                    signed(keyA, 6, record(2))], keyID: keyA, followers: [])
        XCTAssertEqual(partly.unkept, [2...2])
        XCTAssertEqual(partly.missing, [4...5], "at or above its own counter: missing")
        let straddling = EvidenceVerifier.sequence(of: [signed(keyA, 1, record(1)), signed(keyA, 3, unkept([2...4])),
                                                        signed(keyA, 5, record(2))], keyID: keyA, followers: [])
        XCTAssertEqual(straddling.unkept, [2...2])
        XCTAssertEqual(straddling.missing, [4...4])
        let above = EvidenceVerifier.sequence(of: [signed(keyA, 1, unkept([2...3])), signed(keyA, 4, record(1))],
                                              keyID: keyA, followers: [])
        XCTAssertEqual(above.unkept, [])
        XCTAssertEqual(above.missing, [2...3])
    }

    /// ADR 0073, decision 5: only the key itself names its counters, never a key that follows it (whose retention
    /// statements count) nor any other.
    func testAnotherKeysUnkeptStatementAccountsForNone() {
        // Key B's statement at its fifth counter, above the counters it names, so only whose key it is decides.
        let entries = [signed(keyA, 1, record(1)), signed(keyA, 4, record(2)), signed(keyB, 1, nil), signed(keyB, 2, nil),
                       signed(keyB, 3, nil), signed(keyB, 4, nil), signed(keyB, 5, unkept([2...3]))]
        for followers in [Set<Data>(), [keyB]] {
            let sequence = EvidenceVerifier.sequence(of: entries, keyID: keyA, followers: followers)
            XCTAssertEqual(sequence.unkept, [], "followers \(followers.count)")
            XCTAssertEqual(sequence.missing, [2...3], "followers \(followers.count)")
        }
        // And key B's own sequence has no gap: the counters its statement names are all here.
        XCTAssertEqual(EvidenceVerifier.sequence(of: entries, keyID: keyB, followers: []).missing, [])
    }

    // MARK: - The bundle's format

    /// ADR 0073, decision 6 (the owner's "A"): a bundle that holds an unkept statement names the format "/2"; every other
    /// bundle stays "/1", which 1.10's verifier reads.
    func testABundleHoldingAnUnkeptStatementNamesTheSecondFormatAndEveryOtherTheFirst() throws {
        let plain = try TestPhone()
        let plainKey = try plain.certifyKey()
        try plain.sign(revision(1), shown: true)
        try plain.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: plainKey.keyID, counters: [1...1])]), shown: true)
        XCTAssertTrue(try indexText(try written(plain)).hasPrefix(#"{"format":"malinois-evidence-bundle/1","#))
        XCTAssertEqual(EvidenceBundle.format, "malinois-evidence-bundle/1")
        let named = try phoneWithANamedGap()
        XCTAssertTrue(try indexText(try written(named)).hasPrefix(#"{"format":"malinois-evidence-bundle/2","#))
        XCTAssertEqual(EvidenceBundle.formatWithUnkept, "malinois-evidence-bundle/2")
    }

    /// ADR 0073's tests: a bundle checked before the statement and after it. Before, the gap is missing; after, it is
    /// accounted for as made and not kept, and the check finds nothing else.
    func testABundleBeforeTheStatementShowsTheGapMissingAndOneAfterAccountsForIt() throws {
        let before = try TestPhone()
        let key = try before.certifyKey()
        try before.sign(revision(1), shown: true)                                                      // 1
        try before.sign(otherRecord(), kept: false)                                                    // 2: made, not kept
        try before.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1])]), shown: true) // 3
        let unnamed = try check(try written(before), before)
        XCTAssertEqual(unnamed.sequences.first?.missing, [2...2])
        XCTAssertEqual(unnamed.sequences.first?.unkept, [])
        let after = try phoneWithANamedGap()
        let report = try check(try written(after), after)
        XCTAssertEqual(report.keys.map(\.problem), [nil])
        XCTAssertEqual(report.signatures.map(\.problem), [nil, nil, nil])
        XCTAssertEqual(report.sequences.first?.missing, [], "nothing missing")
        XCTAssertEqual(report.sequences.first?.unkept, [2...2], "made and not kept")
        XCTAssertEqual(report.sequences.first?.retired, [])
        XCTAssertEqual(report.export?.revision, 1)
        XCTAssertEqual(report.afterExport, [])
        XCTAssertEqual(report.unshown, [])
        XCTAssertEqual(report.unnamed, [], "the export names the unkept statement as shown")
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.unlisted, [])
        XCTAssertEqual(report.attachments, [EvidenceBundle.AttachmentCheck(name: "primary", outcome: .matches)])
    }

    /// A check reads both formats, and still refuses any other as another format, never as damage.
    func testACheckReadsBothFormatsAndRefusesAnyOther() throws {
        let phone = try phoneWithANamedGap()
        let folder = try written(phone)
        XCTAssertNoThrow(try check(folder, phone))
        let index = folder.appendingPathComponent(EvidenceBundle.indexName)
        let original = try String(contentsOf: index, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "bundle/2", with: "bundle/3").utf8).write(to: index)
        XCTAssertThrowsError(try check(folder, phone)) {
            XCTAssertEqual($0 as? EvidenceProblem, .unknownFormat("malinois-evidence-bundle/3"))
        }
    }

    /// Item 193's codex-2 (the owner's "a"): the format the index names is the phone's word, not signed, and a check names
    /// it as a problem when it is not what the bundle holds, either way: a `/2` bundle relabelled `/1`, a `/1` one `/2`.
    func testAFormatLabelThatIsNotWhatTheBundleHoldsIsAProblem() throws {
        let named = try phoneWithANamedGap()
        let second = try written(named)
        XCTAssertEqual(try check(second, named).problems, [])
        try relabel(second, from: EvidenceBundle.formatWithUnkept, to: EvidenceBundle.format)
        XCTAssertEqual(try check(second, named).problems, [.formatNotAsHeld(EvidenceBundle.format)])
        let plain = try TestPhone()
        let key = try plain.certifyKey()
        try plain.sign(revision(1), shown: true)
        try plain.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1])]), shown: true)
        let first = try written(plain)
        XCTAssertEqual(try check(first, plain).problems, [])
        try relabel(first, from: EvidenceBundle.format, to: EvidenceBundle.formatWithUnkept)
        XCTAssertEqual(try check(first, plain).problems, [.formatNotAsHeld(EvidenceBundle.formatWithUnkept)])
    }

    // MARK: - Helpers

    /// The bundle's index naming the format `to` where it named `from`.
    private func relabel(_ folder: URL, from: String, to: String) throws {
        let index = folder.appendingPathComponent(EvidenceBundle.indexName)
        let text = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(#"{"format":""# + from + #"","#))
        try Data(text.replacingOccurrences(of: #"{"format":""# + from + #"","#, with: #"{"format":""# + to + #"","#).utf8).write(to: index)
    }

    /// A phone whose second signature App Attest made and its file did not keep, named in an unkept statement before
    /// the export, which names what the bundle shows: the shared record's revision and the statement.
    private func phoneWithANamedGap() throws -> TestPhone {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)                                                       // 1
        try phone.sign(otherRecord(), kept: false)                                                     // 2: made, not kept
        try phone.sign(unkept([2...2]), shown: true)                                                   // 3
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1, 3...3])]), shown: true) // 4
        return phone
    }

    private func signed(_ key: Data, _ counter: UInt32, _ statement: EvidenceForm.Statement?) -> EvidenceSignedEntry {
        let bytes = statement.map(EvidenceForm.bytes) ?? Data("a statement shown as its hash, \(counter)".utf8)
        return EvidenceSignedEntry(keyID: key, counter: counter, formHash: TestApp.sha256(bytes), category: nil, bundleVersion: nil,
                                   statement: statement)
    }

    private func unkept(_ counters: [ClosedRange<UInt32>]) -> EvidenceForm.Statement {
        .unkept(EvidenceForm.Unkept(signedAt: 1_793_000_000_700, app: "1.11 (83)", counters: counters))
    }

    private func record(_ revision: Int64) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: other, revision: revision, signedAt: 1_793_000_000_000 + revision, app: "1.11 (83)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))], attachments: []))
    }

    private func otherRecord() -> EvidenceForm.Statement { record(1) }

    private func retention(_ retired: [(Data, [ClosedRange<UInt32>])]) -> EvidenceForm.Statement {
        .retention(EvidenceForm.Retention(signedAt: 1_793_000_000_500, app: "1.11 (83)",
                                          retired: retired.map { EvidenceForm.Retired(keyID: $0.0, counters: $0.1) }))
    }

    /// The shared record's revision `number`, its photo attached.
    private func revision(_ number: Int64) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: shared, revision: number, signedAt: 1_793_000_000_000 + number, app: "1.11 (83)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                    attachments: [EvidenceForm.Attachment(name: "primary", digest: EvidenceHash.digest(of: photo))]))
    }

    private func export(_ number: Int64, shown: [EvidenceForm.KeyCounters]) -> EvidenceForm.Statement {
        .export(EvidenceForm.Export(record: shared, revision: number, signedAt: 1_793_000_009_000, app: "1.11 (83)", shown: shown))
    }

    private let photo = Data("a photo's bytes".utf8)

    /// A bundle of `phone`'s signatures as they stand, with the photo attached, in a folder of its own.
    private func written(_ phone: TestPhone) throws -> URL {
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
                                               attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                       source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        try EvidenceBundle.write(contents, to: folder)
        return folder
    }

    private func indexText(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(EvidenceBundle.indexName), encoding: .utf8)
    }

    private func check(_ folder: URL, _ phone: TestPhone) throws -> EvidenceBundle.Report {
        try EvidenceBundle.check(folder, appID: TestApp.id, roots: [phone.chain.rootDER])
    }
}
