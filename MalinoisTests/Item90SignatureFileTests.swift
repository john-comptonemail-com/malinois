//
//  Item90SignatureFileTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 2: the file of evidence signatures beside the event log (the owner's ruling of 2026-10-31,
//  "1 - a": a file of its own, never inside the records). One entry a line, appended and synced; a line a kill cut short
//  is skipped, never the file; a file that cannot be read now is never written over; and only a retirement rewrites it,
//  dropping exactly the retired records' signatures. Written before the code, red at that commit (against compile-only
//  stubs).
//

import XCTest
@testable import Malinois

final class Item90SignatureFileTests: XCTestCase {

    private var folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item90SignatureFile-\(UUID().uuidString)")
    private let a = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1") ?? UUID()
    private let b = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2") ?? UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }

    private func signature(_ record: UUID?, _ byte: UInt8) -> EvidenceSignatureFile.Entry {
        EvidenceSignatureFile.Entry(kind: .signature, key: Data(repeating: 7, count: 32), statement: Data([byte]),
                                    assertion: Data([byte, byte]), record: record)
    }

    /// Item 182, codex-1 on 68bd96b3: the keys every bundle lists, the one rule for the export and the signer: each key
    /// certified after a key statement of its own, with the latest such statement, in the order certified, once.
    func testTheKeysABundleListsAreThoseCertifiedAfterAStatementOfTheirOwn() {
        let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32), k3 = Data(repeating: 3, count: 32)
        let entries: [EvidenceSignatureFile.Entry] = [
            .init(kind: .keyPending, key: k1, statement: Data("k1, an earlier try".utf8)),
            .init(kind: .keyPending, key: k1, statement: Data("k1, made with".utf8)),
            .init(kind: .keyCertified, key: k1, attestation: Data("a1".utf8)),
            .init(kind: .keyCertified, key: k2, attestation: Data("a2".utf8)),   // no statement before it
            .init(kind: .keyPending, key: k2, statement: Data("k2, after".utf8)),
            .init(kind: .keyPending, key: k3, statement: Data("k3".utf8)),
            .init(kind: .keyCertified, key: k3, attestation: Data("a3".utf8)),
            .init(kind: .keyCertified, key: k3, attestation: Data("a3, again".utf8)),   // certified again: listed once
        ]
        XCTAssertEqual(EvidenceSignatureFile.listedKeys(in: entries), [
            .init(key: k1, statement: Data("k1, made with".utf8), attestation: Data("a1".utf8)),
            .init(key: k3, statement: Data("k3".utf8), attestation: Data("a3".utf8)),
        ])
    }

    func testEntriesAreAppendedAndReadBackInOrder() throws {
        XCTAssertEqual(file.read(), [], "no file yet: no entries")
        let entries = [
            EvidenceSignatureFile.Entry(kind: .keyPending, key: Data(repeating: 7, count: 32), statement: Data("statement".utf8)),
            EvidenceSignatureFile.Entry(kind: .keyCertified, key: Data(repeating: 7, count: 32), attestation: Data([1, 2, 3]),
                                        existing: [a]),
            signature(b, 1),
            EvidenceSignatureFile.Entry(kind: .absenceLogged, records: [a], at: Date(timeIntervalSince1970: 1_793_000_000)),
            EvidenceSignatureFile.Entry(kind: .unsupported, at: Date(timeIntervalSince1970: 1_793_000_001.5)),
        ]
        for entry in entries { XCTAssertTrue(file.append(entry)) }
        XCTAssertEqual(file.read(), entries)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, entries.count, "one entry a line")
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testALineAKillCutShortIsSkippedAndTheRestRead() throws {
        XCTAssertTrue(file.append(signature(a, 1)))
        XCTAssertTrue(file.append(signature(b, 2)))
        // A write cut short, then a later good one: only the broken line is left out.
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"signature","rec"#.utf8))
        try handle.close()
        XCTAssertEqual(file.read(), [signature(a, 1), signature(b, 2)])
        XCTAssertTrue(file.append(signature(a, 3)), "an append after a broken tail starts a line of its own")
        XCTAssertEqual(file.read(), [signature(a, 1), signature(b, 2), signature(a, 3)])
    }

    func testDroppingARecordsSignaturesKeepsEverythingElse() {
        let key = EvidenceSignatureFile.Entry(kind: .keyPending, key: Data(repeating: 7, count: 32), statement: Data([9]))
        let retention = signature(nil, 5)
        for entry in [key, signature(a, 1), signature(b, 2), signature(a, 3), retention] { XCTAssertTrue(file.append(entry)) }
        XCTAssertTrue(file.dropSignatures { $0.record == a })
        XCTAssertEqual(file.read(), [key, signature(b, 2), retention])
        XCTAssertTrue(file.dropSignatures { _ in false }, "nothing to drop leaves the file as it is")
        XCTAssertEqual(file.read(), [key, signature(b, 2), retention])
    }

    func testAFileThatCannotBeReadIsNeverWrittenOver() throws {
        // First, a file that can be read takes lines and drops them.
        XCTAssertTrue(file.append(signature(a, 1)))
        XCTAssertTrue(file.append(signature(b, 2)))
        XCTAssertTrue(file.dropSignatures { $0.record == a })
        XCTAssertEqual(file.read(), [signature(b, 2)])
        // A folder where the file should be stands in for a file the phone's lock keeps sealed.
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        XCTAssertNil(file.read())
        XCTAssertFalse(file.append(signature(a, 1)))
        XCTAssertFalse(file.dropSignatures { $0.record == a })
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isFolder) && isFolder.boolValue)
    }
}
