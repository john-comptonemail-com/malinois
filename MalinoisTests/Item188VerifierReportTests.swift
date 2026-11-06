//
//  Item188VerifierReportTests.swift
//  MalinoisTests
//
//  BACKLOG item 188 (item 192's step 1; ADR 0073, decisions 5 and 6): the Mac verifier's report of an unkept statement.
//  The counters a key's own unkept statement names below its own counter are reported as made by App Attest and not
//  kept by the phone, as information: a bundle whose only gaps are named so ends in PASS. And 1.10's verifier, built as a
//  reader builds it from the source of its release (`v1.10-b82`), refuses a "/2" bundle as in another format, and still
//  checks a "/1" one. macOS only, as the verifier's other tests: the core's Mac run compiles it with the verifier's code
//  and names the earlier source; on the simulator this file is empty. Written before the code, red at that commit
//  (against compile-only stubs).
//

#if os(macOS)
import Foundation
import XCTest
@testable import Malinois

final class Item188VerifierReportTests: XCTestCase {

    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("Item188Verifier-\(UUID().uuidString)")
    private let shared = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2") ?? UUID()
    private let photo = Data("a photo's bytes".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    func testCountersMadeAndNotKeptAreReportedAndTheBundlePasses() throws {
        let phone = try TestPhone()
        let outcome = MalinoisVerifier.run([try bundle(phone, naming: true).path, "--root", try rootFile(phone).path],
                                           appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains("\nPASS\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("  counter 3: unkept statement, signed "), outcome.text)
        XCTAssertTrue(outcome.text.contains(" by Malinois 1.11 (83): counter 2 was made by App Attest and not kept by the phone\n"),
                      outcome.text)
        XCTAssertTrue(outcome.text.contains("; retired: none; made by App Attest and not kept by the phone: 2; none missing\n"),
                      outcome.text)
    }

    func testSeveralCountersMadeAndNotKeptAreSaidSo() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)                                                      // 1
        try phone.sign(record(other), kept: false)                                                    // 2: made, not kept
        try phone.sign(record(other), kept: false)                                                    // 3: made, not kept
        try phone.sign(unkept([2...3]), shown: true)                                                  // 4
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1, 4...4])]), shown: true)  // 5
        let outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains(": counters 2\u{2026}3 were made by App Attest and not kept by the phone\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("; made by App Attest and not kept by the phone: 2\u{2026}3; none missing\n"), outcome.text)
    }

    func testTheSameGapUnnamedIsAProblem() throws {
        let phone = try TestPhone()
        let outcome = MalinoisVerifier.run([try bundle(phone, naming: false).path, "--root", try rootFile(phone).path],
                                           appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("counters missing: 2"), outcome.text)
        XCTAssertFalse(outcome.text.contains("not kept by the phone"), outcome.text)
    }

    /// Item 193's codex-2 (the owner's "a"): a bundle whose format label is not what it holds ends in problems, either way.
    func testAFormatLabelThatIsNotWhatTheBundleHoldsEndsInProblems() throws {
        let named = try TestPhone()
        let second = try bundle(named, naming: true)
        try relabel(second, from: "malinois-evidence-bundle/2", to: "malinois-evidence-bundle/1")
        var outcome = MalinoisVerifier.run([second.path, "--root", try rootFile(named).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("  - the bundle names the format malinois-evidence-bundle/1, but what it holds is in "
                                            + "malinois-evidence-bundle/2 (it holds an unkept statement)\n"), outcome.text)
        let plain = try TestPhone()
        let first = try bundle(plain, gap: false)
        try relabel(first, from: "malinois-evidence-bundle/1", to: "malinois-evidence-bundle/2")
        outcome = MalinoisVerifier.run([first.path, "--root", try rootFile(plain).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("  - the bundle names the format malinois-evidence-bundle/2, but what it holds is in "
                                            + "malinois-evidence-bundle/1 (it holds no unkept statement)\n"), outcome.text)
    }

    /// A statement names counters below its own alone: one naming a counter at or above its own leaves that counter
    /// missing, a problem.
    func testACounterNamedAtOrAboveTheStatementsOwnIsStillMissing() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)                                                      // 1
        try phone.sign(unkept([3...3]), shown: true)                                                  // 2
        try phone.sign(record(other), kept: false)                                                    // 3: made, not kept
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)  // 4
        let outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("counters missing: 3"), outcome.text)
    }

    /// ADR 0073, decision 6 (the owner's "A"): 1.10's verifier, as a reader builds it from its release's source, refuses
    /// a bundle that holds an unkept statement as one in another format, which says a newer verifier is needed rather
    /// than that the bundle is damaged; and it still checks every other bundle.
    func testTheVerifierOf1Point10RefusesTheSecondFormatAndChecksTheFirst() throws {
        let source = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MALINOIS_EARLIER_SOURCE"],
                                                        "the 1.10 source the macOS lane names"))
        let files = try ["MalinoisEvidence", "MalinoisVerifier"].flatMap { folder in
            try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent(folder).path)
                .filter { $0.hasSuffix(".swift") }.sorted().map { source.appendingPathComponent("\(folder)/\($0)").path }
        }
        let program = base.appendingPathComponent("malinois-verify-1.10")
        try runTool("/usr/bin/xcrun", ["swiftc", "-O"] + files + ["-o", program.path])
        let named = try TestPhone(appIDHash: MalinoisVerifier.appIDHash)
        var (status, text) = try launch(program, [try bundle(named, naming: true).path, "--root", try rootFile(named).path])
        XCTAssertEqual(status, 2, text)
        XCTAssertTrue(text.contains("is not a bundle this verifier reads (is in another format (malinois-evidence-bundle/2)): "
                                    + "nothing was checked."), text)
        let plain = try TestPhone(appIDHash: MalinoisVerifier.appIDHash)
        (status, text) = try launch(program, [try bundle(plain, gap: false).path, "--root", try rootFile(plain).path])
        XCTAssertEqual(status, 0, text)
        XCTAssertTrue(text.hasSuffix("PASS\n"), text)
    }

    // MARK: - Helpers

    private var testAppHash: Data { TestApp.sha256(Data(TestApp.id.utf8)) }

    /// A bundle as the phone writes it: the shared record's revision, a signature App Attest made and the file did not
    /// keep (unless not `gap`), named in an unkept statement when `naming`, then the export statement naming what it shows.
    private func bundle(_ phone: TestPhone, naming: Bool = false, gap: Bool = true) throws -> URL {
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)                                                      // 1
        var shown: [UInt32] = [1]
        if gap {
            try phone.sign(record(other), kept: false)                                                // 2: made, not kept
            if naming {
                try phone.sign(unkept([2...2]), shown: true)                                          // 3
                shown.append(3)
            }
        }
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: EvidenceForm.counterRanges(shown))]),
                       shown: true)
        return try written(phone)
    }

    /// The shared record's revision `number`, its photo attached.
    private func revision(_ number: Int64) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: shared, revision: number, signedAt: 1_793_000_000_000 + number, app: "1.11 (83)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                    attachments: [EvidenceForm.Attachment(name: "primary", digest: EvidenceHash.digest(of: photo))]))
    }

    private func record(_ id: UUID) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: id, revision: 1, signedAt: 1_793_000_000_100, app: "1.11 (83)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_100))], attachments: []))
    }

    private func unkept(_ counters: [ClosedRange<UInt32>]) -> EvidenceForm.Statement {
        .unkept(EvidenceForm.Unkept(signedAt: 1_793_000_000_700, app: "1.11 (83)", counters: counters))
    }

    private func export(_ number: Int64, shown: [EvidenceForm.KeyCounters]) -> EvidenceForm.Statement {
        .export(EvidenceForm.Export(record: shared, revision: number, signedAt: 1_793_000_009_000, app: "1.11 (83)", shown: shown))
    }

    /// A bundle of `phone`'s signatures as they stand, with the photo attached, in a folder named as Share names it.
    private func written(_ phone: TestPhone) throws -> URL {
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
                                               attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                       source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-11-04 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        return folder
    }

    /// The bundle's index naming the format `to` where it named `from`.
    private func relabel(_ folder: URL, from: String, to: String) throws {
        let index = folder.appendingPathComponent(EvidenceBundle.indexName)
        let text = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(#"{"format":""# + from + #"","#))
        try Data(text.replacingOccurrences(of: #"{"format":""# + from + #"","#, with: #"{"format":""# + to + #"","#).utf8).write(to: index)
    }

    /// The test chain's root, as a reader would pass Apple's: a PEM file.
    private func rootFile(_ phone: TestPhone) throws -> URL {
        let file = base.appendingPathComponent("root-\(UUID().uuidString).pem")
        let body = phone.chain.rootDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        try Data("-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n".utf8).write(to: file)
        return file
    }

    /// Runs `program` with `arguments`: its exit status and what it printed.
    private func launch(_ program: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: printed, encoding: .utf8) ?? "")
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)")
    }
}
#endif
