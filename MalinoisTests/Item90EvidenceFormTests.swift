//
//  Item90EvidenceFormTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 1: the statements evidence signing signs, in their fixed form. The phone signs a statement's
//  SHA-256, so each statement has one spelling, byte for byte: members in a fixed order, every member always present,
//  whole numbers, minimal escapes, lowercase hex. A reader takes nothing else, so a verifier never reads a statement
//  two ways, and names a newer format instead of guessing at it. Also the hashes and the time and trace encodings the
//  forms use. Written before the code, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

final class Item90EvidenceFormTests: XCTestCase {

    private let id = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let key1 = Data(repeating: 0x11, count: 32)
    private let key2 = Data(repeating: 0x22, count: 32)
    private let key3 = Data(repeating: 0x33, count: 32)

    private var record: EvidenceForm.Record {
        EvidenceForm.Record(
            id: id, revision: 2, signedAt: 1_793_000_006_000, app: "1.10 (81)",
            facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_250)),
                    EvidenceJSON.Member("triggeredSensors", .array([.string("motion"), .string("vision")])),
                    EvidenceJSON.Member("stateChange", .null),
                    EvidenceJSON.Member("ownerAttributed", .bool(false))],
            attachments: [EvidenceForm.Attachment(name: "primary", digest: .init(sha256: Data(repeating: 0xAB, count: 32), bytes: 1_234)),
                          EvidenceForm.Attachment(name: "thumbnail", digest: .init(sha256: Data(repeating: 0x01, count: 32), bytes: 3))])
    }

    private var retention: EvidenceForm.Retention {
        EvidenceForm.Retention(signedAt: 1_793_000_000_000, app: "1.10 (81)",
                               retired: [EvidenceForm.Retired(keyID: key1, counters: [1...57, 60...60]),
                                         EvidenceForm.Retired(keyID: key2, counters: [3...4])])
    }

    private var keyStatement: EvidenceForm.KeyStatement {
        EvidenceForm.KeyStatement(keyID: key3, signedAt: 1_793_000_000_000, app: "1.10 (81)", follows: nil)
    }

    /// The export names the statements its bundle shows (item 182, the owner's "B").
    private var export: EvidenceForm.Export {
        EvidenceForm.Export(record: id, revision: 3, signedAt: 1_793_000_009_000, app: "1.10 (81)",
                            shown: [EvidenceForm.KeyCounters(keyID: key1, counters: [1...2, 4...4]),
                                    EvidenceForm.KeyCounters(keyID: key2, counters: [7...7])])
    }

    private var exportShownText: String {
        #"{"key":"\#(hex("11"))","counters":[[1,2],[4,4]]},{"key":"\#(hex("22"))","counters":[[7,7]]}"#
    }

    private var exportText: String {
        #"{"format":"malinois-evidence/1","type":"export","record":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","revision":3,"#
            + #""signedAt":1793000009000,"app":"1.10 (81)","shown":["# + exportShownText + "]}"
    }

    private let later = UUID(uuidString: "7A0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D") ?? UUID()

    private var absence: EvidenceForm.Absence {
        EvidenceForm.Absence(signedAt: 1_793_000_010_000, app: "1.10 (81)",
                             records: [EvidenceForm.Absent(id: id, revision: 3, startDate: 1_793_000_000_250),
                                       EvidenceForm.Absent(id: later, revision: 1, startDate: nil)])
    }

    private var absenceText: String {
        #"{"format":"malinois-evidence/1","type":"absence","signedAt":1793000010000,"app":"1.10 (81)","records":["#
            + #"{"id":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","revision":3,"startDate":1793000000250},"#
            + #"{"id":"7A0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D","revision":1,"startDate":null}]}"#
    }

    private func hex(_ byte: String) -> String { String(repeating: byte, count: 32) }

    private var keyText: String {
        #"{"format":"malinois-evidence/1","type":"key","key":"\#(hex("33"))","signedAt":1793000000000,"app":"1.10 (81)","follows":null}"#
    }

    // MARK: - Writing

    func testARecordIsWrittenInItsFixedOrder() {
        let expected = #"{"format":"malinois-evidence/1","type":"record","id":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","revision":2,"#
            + #""signedAt":1793000006000,"app":"1.10 (81)","facts":{"startDate":1793000000250,"triggeredSensors":["motion","vision"],"#
            + #""stateChange":null,"ownerAttributed":false},"attachments":[{"name":"primary","sha256":"\#(hex("ab"))","bytes":1234},"#
            + #"{"name":"thumbnail","sha256":"\#(hex("01"))","bytes":3}]}"#
        XCTAssertEqual(TestApp.text(EvidenceForm.bytes(.record(record))), expected)
    }

    func testARetentionStatementAndAKeyStatementAreWrittenInTheirFixedOrder() {
        let retained = #"{"format":"malinois-evidence/1","type":"retention","signedAt":1793000000000,"app":"1.10 (81)","retired":["#
            + #"{"key":"\#(hex("11"))","counters":[[1,57],[60,60]]},{"key":"\#(hex("22"))","counters":[[3,4]]}]}"#
        XCTAssertEqual(TestApp.text(EvidenceForm.bytes(.retention(retention))), retained)
        XCTAssertEqual(TestApp.text(EvidenceForm.bytes(.key(keyStatement))), keyText)
        let follows = EvidenceForm.KeyStatement(keyID: key3, signedAt: 1, app: "1.10 (81)", follows: key1)
        XCTAssertEqual(TestApp.text(EvidenceForm.bytes(.key(follows))),
                       #"{"format":"malinois-evidence/1","type":"key","key":"\#(hex("33"))","signedAt":1,"app":"1.10 (81)","follows":"\#(hex("11"))"}"#)
        // The verifier's tests write key statements by hand: the same bytes.
        XCTAssertEqual(TestApp.keyStatement(keyID: key3), EvidenceForm.bytes(.key(keyStatement)))
    }

    /// Phase 4: the statement a phone signs as it exports a record, the bundle's last signature.
    func testAnExportStatementIsWrittenInItsFixedOrder() {
        XCTAssertEqual(TestApp.text(EvidenceForm.bytes(.export(export))), exportText)
    }

    /// The statement that signed records left the log other than by its limit (item 182), in its one spelling: its
    /// records in ascending order of their IDs, each with the revision last signed and its start, or null.
    func testAnAbsenceStatementIsWrittenInItsFixedOrderAndReadsBack() throws {
        XCTAssertEqual(TestApp.text(EvidenceForm.bytes(.absence(absence))), absenceText)
        XCTAssertEqual(try EvidenceForm.read(Data(absenceText.utf8)), .absence(absence))
    }

    func testStringsEscapeOnlyWhatJSONRequires() {
        let value = EvidenceJSON.string("a\"b\\c\u{8}\u{C}\n\r\t\u{1}\u{1F}\u{7F}é/€")
        let expected = Data(#""a\"b\\c\b\f\n\r\t\u0001\u001f"#.utf8) + Data("\u{7F}é/€\"".utf8)
        XCTAssertEqual(value.bytes, expected)
        let nested = EvidenceJSON.object([EvidenceJSON.Member("z", .int(-5)), EvidenceJSON.Member("a", .array([.null, .bool(true)]))])
        XCTAssertEqual(TestApp.text(nested.bytes), #"{"z":-5,"a":[null,true]}"#)
        XCTAssertEqual(nested["a"], .array([.null, .bool(true)]))
        XCTAssertNil(nested["b"])
        XCTAssertNil(EvidenceJSON.int(1)["a"])
    }

    // MARK: - Reading

    func testEachStatementReadsBackToItself() throws {
        let following = EvidenceForm.KeyStatement(keyID: key3, signedAt: 7, app: "1.10 (81)", follows: key1)
        let showingNone = EvidenceForm.Export(record: id, revision: 1, signedAt: 5, app: "1.10 (81)", shown: [])
        for statement in [EvidenceForm.Statement.record(record), .retention(retention), .key(keyStatement), .key(following),
                          .export(export), .export(showingNone)] {
            XCTAssertEqual(try EvidenceForm.read(EvidenceForm.bytes(statement)), statement)
        }
        let value = EvidenceJSON.object([EvidenceJSON.Member("text", .string("a\"\u{1}é")),
                                         EvidenceJSON.Member("n", .int(Int64.min)), EvidenceJSON.Member("m", .int(Int64.max)),
                                         EvidenceJSON.Member("list", .array([.object([]), .array([]), .bool(false)]))])
        XCTAssertEqual(try EvidenceJSON(fixedForm: value.bytes), value)
    }

    func testAReaderTakesNothingButTheFixedForm() {
        let good = keyText
        XCTAssertNoThrow(try EvidenceForm.read(Data(good.utf8)))
        let variants: [(String, String)] = [
            ("a space after a colon", good.replacingOccurrences(of: #""type":"key""#, with: #""type": "key""#)),
            ("a newline at the end", good + "\n"),
            ("bytes after the value", good + "{}"),
            ("an escaped slash", good.replacingOccurrences(of: "1.10 (81)", with: #"1.10\/81"#)),
            // The escape is built from two pieces: an editing tool once turned the escaped letter back into the letter.
            ("a letter escaped", good.replacingOccurrences(of: "1.10 (81)", with: #"\"# + "u0031.10 (81)")),
            ("an uppercase escape", good.replacingOccurrences(of: "1.10 (81)", with: #"1.10\u001F"#)),
            ("a raw control character", good.replacingOccurrences(of: "1.10 (81)", with: "1.10\t(81)")),
            ("a repeated key", good.replacingOccurrences(of: #""app":"1.10 (81)""#, with: #""app":"1.10 (81)","app":"1.10 (81)""#)),
            ("a fraction", good.replacingOccurrences(of: "1793000000000", with: "1793000000000.0")),
            ("an exponent", good.replacingOccurrences(of: "1793000000000", with: "1.793e12")),
            ("a leading zero", good.replacingOccurrences(of: "1793000000000", with: "01793000000000")),
            ("minus zero", good.replacingOccurrences(of: "1793000000000", with: "-0")),
            ("a number beyond 64 bits", good.replacingOccurrences(of: "1793000000000", with: "99999999999999999999")),
            ("members out of order", good.replacingOccurrences(of: #""format":"malinois-evidence/1","type":"key""#,
                                                               with: #""type":"key","format":"malinois-evidence/1""#)),
            ("a missing member", good.replacingOccurrences(of: #","follows":null"#, with: "")),
            ("an extra member", good.replacingOccurrences(of: #""follows":null"#, with: #""follows":null,"extra":1"#)),
            ("uppercase hex", good.replacingOccurrences(of: hex("33"), with: String(repeating: "AB", count: 32))),
            ("a short key ID", good.replacingOccurrences(of: hex("33"), with: String(repeating: "33", count: 31))),
            ("an empty app", good.replacingOccurrences(of: "1.10 (81)", with: "")),
            ("an unknown type", good.replacingOccurrences(of: #""type":"key""#, with: #""type":"selfie""#)),
            ("the format not a string", good.replacingOccurrences(of: #""malinois-evidence/1""#, with: "1")),
            ("not an object", "[]"),
            ("only the format", #"{"format":"malinois-evidence/1"}"#),
            ("nothing", ""),
        ]
        for (why, text) in variants { assertRefused(Data(text.utf8), why) }
        assertRefused(Data(good.utf8.prefix(60)) + Data([0xFF]) + Data(good.utf8.dropFirst(61)), "invalid UTF-8")
    }

    func testARecordOrRetentionOutOfItsRulesIsRefused() {
        let goodRecord = TestApp.text(EvidenceForm.bytes(.record(record)))
        XCTAssertEqual(try? EvidenceForm.read(Data(goodRecord.utf8)), .record(record), "the record each variant starts from")
        let records: [(String, String)] = [
            ("a lowercase id", goodRecord.replacingOccurrences(of: id.uuidString, with: id.uuidString.lowercased())),
            ("revision 0", goodRecord.replacingOccurrences(of: #""revision":2"#, with: #""revision":0"#)),
            ("facts not an object", goodRecord.replacingOccurrences(of: #""facts":{"#, with: #""facts":[{"#)
                .replacingOccurrences(of: #""ownerAttributed":false}"#, with: #""ownerAttributed":false}]"#)),
            ("a negative length", goodRecord.replacingOccurrences(of: #""bytes":3"#, with: #""bytes":-3"#)),
            ("a repeated attachment", goodRecord.replacingOccurrences(of: #""name":"thumbnail""#, with: #""name":"primary""#)),
            ("an attachment with no name", goodRecord.replacingOccurrences(of: #""name":"thumbnail""#, with: #""name":"""#)),
        ]
        for (why, text) in records { assertRefused(Data(text.utf8), why) }
        let goodRetention = TestApp.text(EvidenceForm.bytes(.retention(retention)))
        XCTAssertEqual(try? EvidenceForm.read(Data(goodRetention.utf8)), .retention(retention), "the statement each variant starts from")
        let k1 = #"{"key":"\#(hex("11"))","counters":[[1,57],[60,60]]}"#
        let k2 = #"{"key":"\#(hex("22"))","counters":[[3,4]]}"#
        let retentions: [(String, String)] = [
            ("keys out of order", goodRetention.replacingOccurrences(of: k1 + "," + k2, with: k2 + "," + k1)),
            ("a key twice", goodRetention.replacingOccurrences(of: k2, with: k1)),
            ("overlapping ranges", goodRetention.replacingOccurrences(of: "[[1,57],[60,60]]", with: "[[1,57],[50,60]]")),
            ("adjacent ranges", goodRetention.replacingOccurrences(of: "[[1,57],[60,60]]", with: "[[1,57],[58,60]]")),
            ("ranges out of order", goodRetention.replacingOccurrences(of: "[[1,57],[60,60]]", with: "[[60,60],[1,57]]")),
            ("a range backwards", goodRetention.replacingOccurrences(of: "[[3,4]]", with: "[[4,3]]")),
            ("counter 0", goodRetention.replacingOccurrences(of: "[[1,57]", with: "[[0,57]")),
            ("a counter beyond 32 bits", goodRetention.replacingOccurrences(of: "[[3,4]]", with: "[[3,4294967296]]")),
            ("a key with no counters", goodRetention.replacingOccurrences(of: #""counters":[[3,4]]"#, with: #""counters":[]"#)),
            ("a range of three numbers", goodRetention.replacingOccurrences(of: "[[3,4]]", with: "[[3,4,5]]")),
            ("a range of one number", goodRetention.replacingOccurrences(of: "[[3,4]]", with: "[[3]]")),
            ("nothing retired", #"{"format":"malinois-evidence/1","type":"retention","signedAt":1,"app":"1.10 (81)","retired":[]}"#),
        ]
        for (why, text) in retentions { assertRefused(Data(text.utf8), why) }
    }

    func testAnExportStatementOutOfItsRulesIsRefused() {
        XCTAssertEqual(try? EvidenceForm.read(Data(exportText.utf8)), .export(export), "the statement each variant starts from")
        let variants: [(String, String)] = [
            ("a lowercase record", exportText.replacingOccurrences(of: id.uuidString, with: id.uuidString.lowercased())),
            ("a record that is no UUID", exportText.replacingOccurrences(of: id.uuidString, with: "6F1E2D3C")),
            ("revision 0", exportText.replacingOccurrences(of: #""revision":3"#, with: #""revision":0"#)),
            ("a negative revision", exportText.replacingOccurrences(of: #""revision":3"#, with: #""revision":-3"#)),
            ("a revision as text", exportText.replacingOccurrences(of: #""revision":3"#, with: #""revision":"3""#)),
            ("a time as text", exportText.replacingOccurrences(of: "1793000009000", with: #""1793000009000""#)),
            ("an empty app", exportText.replacingOccurrences(of: "1.10 (81)", with: "")),
            ("members out of order", exportText.replacingOccurrences(of: #""record":"\#(id.uuidString)","revision":3"#,
                                                                 with: #""revision":3,"record":"\#(id.uuidString)""#)),
            ("a missing member", exportText.replacingOccurrences(of: #","revision":3"#, with: "")),
            ("an extra member", exportText.replacingOccurrences(of: #""app":"1.10 (81)""#, with: #""app":"1.10 (81)","extra":1"#)),
            ("its shown keys out of order", exportText.replacingOccurrences(
                of: exportShownText,
                with: #"{"key":"\#(hex("22"))","counters":[[7,7]]},{"key":"\#(hex("11"))","counters":[[1,2],[4,4]]}"#)),
            ("shown ranges touching", exportText.replacingOccurrences(of: "[[1,2],[4,4]]", with: "[[1,2],[3,4]]")),
            ("a shown range reversed", exportText.replacingOccurrences(of: "[[7,7]]", with: "[[7,6]]")),
            ("a shown counter 0", exportText.replacingOccurrences(of: "[[1,2],[4,4]]", with: "[[0,2],[4,4]]")),
            ("a shown key without counters", exportText.replacingOccurrences(of: "[[7,7]]", with: "[]")),
            ("no shown member", exportText.replacingOccurrences(of: #","shown":["#, with: #","seen":["#)),
        ]
        for (why, text) in variants { assertRefused(Data(text.utf8), why) }
    }

    func testAnAbsenceStatementOutOfItsRulesIsRefused() {
        XCTAssertEqual(try? EvidenceForm.read(Data(absenceText.utf8)), .absence(absence), "the statement each variant starts from")
        let first = #"{"id":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","revision":3,"startDate":1793000000250}"#
        let second = #"{"id":"7A0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D","revision":1,"startDate":null}"#
        let variants: [(String, String)] = [
            ("no records", absenceText.replacingOccurrences(of: first + "," + second, with: "")),
            ("records out of order", absenceText.replacingOccurrences(of: first + "," + second, with: second + "," + first)),
            ("a record twice", absenceText.replacingOccurrences(of: second, with: first)),
            ("revision 0", absenceText.replacingOccurrences(of: #""revision":3"#, with: #""revision":0"#)),
            ("a start as text", absenceText.replacingOccurrences(of: "1793000000250", with: #""1793000000250""#)),
            ("a lowercase record", absenceText.replacingOccurrences(of: later.uuidString, with: later.uuidString.lowercased())),
            ("a record that is no UUID", absenceText.replacingOccurrences(of: later.uuidString, with: "7A0B1C2D")),
            ("a member missing", absenceText.replacingOccurrences(of: #","startDate":null"#, with: "")),
            ("an extra member", absenceText.replacingOccurrences(of: #""app":"1.10 (81)""#, with: #""app":"1.10 (81)","extra":1"#)),
            ("members out of order", absenceText.replacingOccurrences(of: #""signedAt":1793000010000,"app":"1.10 (81)""#,
                                                                      with: #""app":"1.10 (81)","signedAt":1793000010000"#)),
            ("an empty app", absenceText.replacingOccurrences(of: "1.10 (81)", with: "")),
        ]
        for (why, text) in variants { assertRefused(Data(text.utf8), why) }
    }

    func testTheJSONReaderTakesOnlyItsOwnSpelling() {
        // The JSON type keeps its own promise, apart from the statements' layout checks.
        XCTAssertEqual(try? EvidenceJSON(fixedForm: Data(#"{"a":[1,"x",null]}"#.utf8)),
                       .object([EvidenceJSON.Member("a", .array([.int(1), .string("x"), .null]))]))
        let variants = [("bytes after the value", #"{"a":1} "#), ("a value after the value", "1 2"), ("a leading zero", "01"),
                        ("minus zero", "-0"), ("a raw control character", "\"a\tb\""),
                        ("an escaped letter", "\"" + #"\"# + "u0061\"")]
        for (why, text) in variants { assertJSONRefused(Data(text.utf8), why) }
    }

    func testTheReaderStaysInsideItsInput() {
        // Escapes cut short at the end of the input; the escape built from pieces, as above.
        for cut in ["u0", "u00", "u000"] {
            assertJSONRefused(Data(("\"" + #"\"# + cut).utf8), "an escape cut short: \(cut)")
        }
        assertJSONRefused(Data("9223372036854775808".utf8), "one beyond the largest 64-bit number")
        assertJSONRefused(Data("-9223372036854775809".utf8), "one below the smallest")
        assertJSONRefused(Data("-".utf8), "a minus sign alone")
        XCTAssertEqual(try? EvidenceJSON(fixedForm: Data("-9223372036854775808".utf8)), .int(Int64.min))
    }

    func testARepeatedKeyIsRefusedWhereTheLayoutAllowsAnyName() {
        assertJSONRefused(Data(#"{"a":1,"a":1}"#.utf8), "a repeated key")
        let goodRecord = TestApp.text(EvidenceForm.bytes(.record(record)))
        assertRefused(Data(goodRecord.replacingOccurrences(of: #""stateChange":null"#, with: #""stateChange":null,"stateChange":null"#).utf8),
                      "a fact twice")
    }

    func testANewerFormatIsNamedNotGuessed() {
        for format in ["malinois-evidence/2", "something-else"] {
            let text = keyText.replacingOccurrences(of: "malinois-evidence/1", with: format)
            XCTAssertThrowsError(try EvidenceForm.read(Data(text.utf8)), format) {
                XCTAssertEqual($0 as? EvidenceProblem, .unknownFormat(format))
            }
        }
    }

    func testTheReaderStopsAtItsLimits() throws {
        let deepest = String(repeating: "[", count: EvidenceJSON.maximumDepth) + "1" + String(repeating: "]", count: EvidenceJSON.maximumDepth)
        XCTAssertNoThrow(try EvidenceJSON(fixedForm: Data(deepest.utf8)))
        assertJSONRefused(Data(("[" + deepest + "]").utf8), "one level deeper than the limit")
        let objects = String(repeating: #"{"a":"#, count: EvidenceJSON.maximumDepth) + "1" + String(repeating: "}", count: EvidenceJSON.maximumDepth)
        XCTAssertNoThrow(try EvidenceJSON(fixedForm: Data(objects.utf8)))
        assertJSONRefused(Data((#"{"a":"# + objects + "}").utf8), "objects one level deeper than the limit")
        let longest = Data(("\"" + String(repeating: "a", count: EvidenceJSON.maximumBytes - 2) + "\"").utf8)
        XCTAssertNoThrow(try EvidenceJSON(fixedForm: longest))
        assertJSONRefused(Data(("\"" + String(repeating: "a", count: EvidenceJSON.maximumBytes - 1) + "\"").utf8),
                          "one byte over the limit")
    }

    // MARK: - Times, traces and hashes

    func testTimesAndLengthsAreWholeMillisecondsOrNothing() {
        XCTAssertEqual(EvidenceForm.milliseconds(since1970: Date(timeIntervalSince1970: 1_793_000_000.25)), 1_793_000_000_250)
        XCTAssertEqual(EvidenceForm.milliseconds(since1970: Date(timeIntervalSince1970: -1.5)), -1_500)
        XCTAssertEqual(EvidenceForm.milliseconds(5.0004), 5_000)
        XCTAssertEqual(EvidenceForm.milliseconds(5.0006), 5_001)
        XCTAssertEqual(EvidenceForm.milliseconds(0), 0)
        for unrepresentable in [Double.nan, .infinity, -.infinity, 1e300, 1e15] {
            XCTAssertNil(EvidenceForm.milliseconds(unrepresentable), "\(unrepresentable)")
        }
        XCTAssertNil(EvidenceForm.milliseconds(since1970: Date(timeIntervalSince1970: 1e300)))
    }

    func testATracesBytesAreItsSamplesAsBigEndianDoubles() {
        XCTAssertEqual(EvidenceForm.traceBytes([0.5, -1.0]),
                       Data([0x3F, 0xE0, 0, 0, 0, 0, 0, 0, 0xBF, 0xF0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(EvidenceForm.traceBytes([]), Data())
    }

    func testHashesAreSHA256InLowercaseHex() throws {
        let abc = EvidenceHash.sha256(Data("abc".utf8))
        XCTAssertEqual(EvidenceHash.hex(abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(EvidenceHash.bytes(hex: EvidenceHash.hex(abc)), abc)
        XCTAssertEqual(EvidenceHash.bytes(hex: ""), Data())
        for bad in ["AB", "abc", "zz", "0x00", " ab"] { XCTAssertNil(EvidenceHash.bytes(hex: bad), bad) }
        XCTAssertEqual(EvidenceHash.digest(of: Data("abc".utf8)), EvidenceForm.Digest(sha256: abc, bytes: 3))
    }

    func testAFilesDigestReadsTheWholeFileInPieces() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item90Digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two and a half megabytes: more than two of the reader's one-megabyte pieces.
        let content = Data((0..<(5 << 19)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = folder.appendingPathComponent("clip.mov")
        try content.write(to: file)
        XCTAssertEqual(try EvidenceHash.digest(ofFileAt: file),
                       EvidenceForm.Digest(sha256: TestApp.sha256(content), bytes: Int64(content.count)))
        let empty = folder.appendingPathComponent("empty.jpg")
        try Data().write(to: empty)
        XCTAssertEqual(try EvidenceHash.digest(ofFileAt: empty), EvidenceForm.Digest(sha256: TestApp.sha256(Data()), bytes: 0))
        XCTAssertThrowsError(try EvidenceHash.digest(ofFileAt: folder.appendingPathComponent("missing.mov")))
    }

    // MARK: - Helpers

    private func assertRefused(_ data: Data, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EvidenceForm.read(data), why, file: file, line: line) {
            XCTAssertEqual($0 as? EvidenceProblem, .formNotFixed, why, file: file, line: line)
        }
    }

    private func assertJSONRefused(_ data: Data, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EvidenceJSON(fixedForm: data), why, file: file, line: line) {
            XCTAssertEqual($0 as? EvidenceProblem, .formNotFixed, why, file: file, line: line)
        }
    }
}
