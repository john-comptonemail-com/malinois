//
//  Item239VerifierTests.swift
//  MalinoisTests
//
//  BACKLOG item 239 (ADR 0081, decision 4; the design's V2 (a), the owner's "V1-V3 (a)"): a slow Vision trip's still is
//  one more attachment, `visionReference`, and its time one more fact, `visionReferenceTakenAt`, in no new bundle format.
//  The Mac verifier checks attachments by name and reads a record's facts as an open list, so this release's verifier
//  and 1.10's, built as a reader builds it from the source of its release (`v1.10-b82`), both check a bundle with the
//  still and end in PASS, and both find a still altered after signing. macOS only, as the verifier's other tests: the
//  core's Mac run compiles it with the verifier's code and names the earlier source; on the simulator this file is
//  empty. A proof of the format, not of new code: it passes before the build, as it must.
//

#if os(macOS)
import Foundation
import XCTest
@testable import Malinois

final class Item239VerifierTests: XCTestCase {

    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("Item239Verifier-\(UUID().uuidString)")
    private let shared = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let photo = Data("a photo's bytes".utf8)
    private let still = Data("the reference still's bytes".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    func testThisVerifierChecksTheStillAsItChecksAPhoto() throws {
        let phone = try TestPhone(appIDHash: MalinoisVerifier.appIDHash)
        let bundle = try signedBundle(phone)
        var outcome = MalinoisVerifier.run([bundle.path, "--root", try rootFile(phone).path], appIDHash: MalinoisVerifier.appIDHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        // This verifier says what a pass shows after PASS (1.10's ends there).
        XCTAssertTrue(outcome.text.contains("\nPASS\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("visionReference"), "it names the still it checked: \(outcome.text)")
        try Data("altered".utf8).write(to: bundle.appendingPathComponent("\(EvidenceBundle.attachmentsFolder)/visionReference.jpg"))
        outcome = MalinoisVerifier.run([bundle.path, "--root", try rootFile(phone).path], appIDHash: MalinoisVerifier.appIDHash)
        XCTAssertEqual(outcome.status, 1, "a still altered after signing is a problem: \(outcome.text)")
    }

    func testTheVerifierOf1Point10ChecksTheStillAsItChecksAPhoto() throws {
        let source = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MALINOIS_EARLIER_SOURCE"],
                                                        "the 1.10 source the macOS lane names"))
        let files = try ["MalinoisEvidence", "MalinoisVerifier"].flatMap { folder in
            try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent(folder).path)
                .filter { $0.hasSuffix(".swift") }.sorted().map { source.appendingPathComponent("\(folder)/\($0)").path }
        }
        let program = base.appendingPathComponent("malinois-verify-1.10")
        try runTool("/usr/bin/xcrun", ["swiftc", "-O"] + files + ["-o", program.path])
        let phone = try TestPhone(appIDHash: MalinoisVerifier.appIDHash)
        let bundle = try signedBundle(phone)
        var (status, text) = try launch(program, [bundle.path, "--root", try rootFile(phone).path])
        XCTAssertEqual(status, 0, text)
        XCTAssertTrue(text.hasSuffix("PASS\n"), text)
        XCTAssertTrue(text.contains("visionReference"), "it names the still it checked: \(text)")
        try Data("altered".utf8).write(to: bundle.appendingPathComponent("\(EvidenceBundle.attachmentsFolder)/visionReference.jpg"))
        (status, text) = try launch(program, [bundle.path, "--root", try rootFile(phone).path])
        XCTAssertEqual(status, 1, "a still altered after signing is a problem: \(text)")
    }

    // MARK: - Helpers

    /// A bundle as 1.13 writes one for a slow trip: the record's revision, with its photo and its still attached and the
    /// still's time among its facts, then the export statement naming what it shows.
    private func signedBundle(_ phone: TestPhone) throws -> URL {
        let key = try phone.certifyKey()
        let facts = [EvidenceJSON.Member("startDate", .int(1_793_000_000_000)),
                     EvidenceJSON.Member("triggeredSensors", .array([.string("vision")])),
                     EvidenceJSON.Member("visionReferenceTakenAt", .int(1_792_998_200_000))]
        let attachments = [EvidenceForm.Attachment(name: "primary", digest: EvidenceHash.digest(of: photo)),
                           EvidenceForm.Attachment(name: "visionReference", digest: EvidenceHash.digest(of: still))]
        try phone.sign(.record(EvidenceForm.Record(id: shared, revision: 1, signedAt: 1_793_000_000_100, app: "1.13 (88)",
                                                   facts: facts, attachments: attachments)), shown: true)
        try phone.sign(.export(EvidenceForm.Export(record: shared, revision: 1, signedAt: 1_793_000_009_000, app: "1.13 (88)",
                                                   shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1])])),
                       shown: true)
        let contents = EvidenceBundle.Contents(
            record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
            attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg", source: .bytes(photo)),
                          EvidenceBundle.Attachment(name: "visionReference", file: "visionReference.jpg", source: .bytes(still))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-11-12 2100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        return folder
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
