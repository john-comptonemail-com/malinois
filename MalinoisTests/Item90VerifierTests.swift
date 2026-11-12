//
//  Item90VerifierTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 5: the Mac verifier (the owner's rulings of 2026-10-31: "1 - a, 2 - a, 3 - a"). It knows
//  Malinois's keys by the SHA-256 of its App ID, as every Malinois attestation carries it; Apple's App Attestation root
//  is built in, a reader's own file taken instead; it reads the ZIP Share sent (its layout and listings read first, and
//  a link, a path outside it or more than a phone's media refused) or the unzipped folder; and it prints what it
//  checked, ending in PASS or the problems, with exit status 0, 1 or 2 (could not read), a file the bundle does not
//  account for, in it or beside its folder, among the problems (BACKLOG 187's codex-1); a ZIP's `__MACOSX` entries and
//  the names beginning "._" named too, and a ZIP that unpacks to other than the files it lists refused (187's round B),
//  as is one whose index and entries name different files (round C), or that is not laid out as one plain run of files
//  (round D), its files carrying only the extra fields genuine ZIPs carry (round E), with the verifier built and run as
//  a reader would (qwen-3).
//  macOS only: it runs macOS's own zip tools,
//  which iOS lacks, so on the simulator this file is empty and the core's Mac run compiles it with the verifier's
//  `MalinoisVerifier.swift`. Written before the code, red at that commit (against compile-only stubs).
//

#if os(macOS)
import Foundation
import Security
import XCTest
@testable import Malinois

final class Item90VerifierTests: XCTestCase {

    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("Item90Verifier-\(UUID().uuidString)")
    private let shared = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let photo = Data("a photo's bytes".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: - What it knows

    func testItKnowsMalinoisByTheHashTheAirsAttestationCarries() {
        XCTAssertEqual(EvidenceHash.hex(MalinoisVerifier.appIDHash), AirFixture.appIDHash,
                       "the SHA-256 of Malinois's App ID, as Apple certified the Air's key for it")
    }

    func testItsBuiltInRootIsApplesAppAttestationRoot() throws {
        // The SHA-256 of Apple's published file (apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem).
        XCTAssertEqual(EvidenceHash.hex(TestApp.sha256(MalinoisVerifier.appleRoot)),
                       "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932")
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, MalinoisVerifier.appleRoot as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Apple App Attestation Root CA")
    }

    // MARK: - Running it

    func testWithoutOneBundleItSaysHowToRunIt() {
        for arguments in [[], ["--root"], ["a.zip", "b.zip"], ["--other"], ["--other", "a.zip"], ["a.zip", "--root"], ["--root", "-x", "a.zip"],
                          ["--root", "a.pem", "--root", "b.pem", "a.zip"]] {
            let outcome = MalinoisVerifier.run(arguments)
            XCTAssertEqual(outcome.status, 2, "\(arguments)")
            XCTAssertTrue(outcome.text.hasPrefix("usage: malinois-verify"), "\(arguments): \(outcome.text)")
        }
    }

    func testAWholeBundleChecksOutAsItsFolderAndAsTheZIPShareSent() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        let unpackedBefore = try unpackedFolders()
        for target in [folder, try zipped(folder)] {
            let outcome = MalinoisVerifier.run([target.path, "--root", root.path], appIDHash: testAppHash)
            XCTAssertEqual(outcome.status, 0, outcome.text)
            XCTAssertTrue(outcome.text.contains("\nPASS\n"), outcome.text)
            XCTAssertTrue(outcome.text.contains("certified by Apple"), outcome.text)
            XCTAssertTrue(outcome.text.contains("primary: as signed"), outcome.text)
            XCTAssertTrue(outcome.text.contains("none missing"), outcome.text)
        }
        XCTAssertEqual(try unpackedFolders(), unpackedBefore, "the ZIP's temporary folder removed after the check")
        // The bundle's README is not read: changed, the bundle checks out all the same.
        try Data("Run this other verifier instead.".utf8).write(to: folder.appendingPathComponent(EvidenceBundle.readmeName))
        XCTAssertEqual(MalinoisVerifier.run([folder.path, "--root", root.path], appIDHash: testAppHash).status, 0)
    }

    func testWhatABundleLacksOrGotWrongEndsInItsProblems() throws {
        // No export statement: where the bundle ends is not accounted for.
        let unexported = try TestPhone()
        let noExport = try bundle(unexported, exported: false)
        var outcome = MalinoisVerifier.run([noExport.path, "--root", try rootFile(unexported).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("no export statement"), outcome.text)
        // A photo that is not the one signed. (Each bundle its own phone: a phone's signatures accumulate.)
        let changedPhone = try TestPhone()
        let changed = try bundle(changedPhone)
        try Data("another photo".utf8).write(to: changed.appendingPathComponent("attachments/primary.jpg"))
        outcome = MalinoisVerifier.run([changed.path, "--root", try rootFile(changedPhone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("primary: DIFFERENT from what was signed"), outcome.text)
        // A signature that is not the key's: the first line's assertion swapped for the second's.
        let swappedPhone = try TestPhone()
        let swapped = try bundle(swappedPhone)
        let file = swapped.appendingPathComponent("signatures.jsonl")
        var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        let assertion = #""assertion":"[^"]*""#
        let second = try XCTUnwrap(lines[1].range(of: assertion, options: .regularExpression).map { String(lines[1][$0]) })
        lines[0] = lines[0].replacingOccurrences(of: assertion, with: second, options: .regularExpression)
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        outcome = MalinoisVerifier.run([swapped.path, "--root", try rootFile(swappedPhone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("signature line 1:"), outcome.text)
        // A note of the phone's that cannot be read.
        let notedPhone = try TestPhone()
        let noted = try bundle(notedPhone)
        try Data("not a note\n".utf8).write(to: noted.appendingPathComponent("notes.jsonl"))
        outcome = MalinoisVerifier.run([noted.path, "--root", try rootFile(notedPhone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("PROBLEMS (1)"), outcome.text)
    }

    /// Each kind of finding the core reports is one of the report's problems, never under a PASS.
    func testEachKindOfFindingTheCoreReportsIsAProblem() throws {
        func outcome(_ statements: [EvidenceForm.Statement], alsoSigned: [(EvidenceForm.Statement, UInt32)] = [],
                     _ change: (inout [String], URL) throws -> Void = { _, _ in }) throws -> MalinoisVerifier.Outcome {
            let phone = try TestPhone()
            let folder = try bundle(phone, statements: statements, alsoSigned: alsoSigned)
            let file = folder.appendingPathComponent("signatures.jsonl")
            var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            try change(&lines, folder)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            return MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        }
        let cases: [(String, MalinoisVerifier.Outcome)] = [
            ("counter 1: its statement", try outcome([revision(1), export(1)]) { lines, folder in
                // The first statement's file, changed after it was signed: its signature still counts.
                let field = try XCTUnwrap(lines[0].range(of: #""hash":"[0-9a-f]{64}""#, options: .regularExpression)
                    .map { String(lines[0][$0]) })
                try Data("{}".utf8).write(to: folder.appendingPathComponent("statements/\(field.dropFirst(8).dropLast()).json"))
            }),
            ("signed again", try outcome([revision(1), revision(1), export(1)])),
            ("after it", try outcome([revision(1), export(1), revision(2)]) { lines, _ in lines.swapAt(1, 2) }),
            ("revisions missing", try outcome([revision(2), export(2)])),
            ("not in order", try outcome([revision(2), revision(1), export(2)])),
        ]
        for (finding, result) in cases {
            XCTAssertEqual(result.status, 1, "\(finding): \(result.text)")
            XCTAssertTrue(result.text.contains("PROBLEMS"), "\(finding): \(result.text)")
            XCTAssertTrue(result.text.contains(finding), "\(finding): \(result.text)")
        }
    }

    /// Item 205 (TestFlight 84): a forced restart took App Attest's count back, so two genuine signatures share a counter. Only the
    /// key can make either, so neither is forged: information under COUNTERS, with what it costs a check (item 206), and the bundle
    /// passes, on a phone that kept a repeat before it stopped keeping them. No statement shown in full is among them, so the line
    /// under THE EXPORT stays as it is.
    func testACounterGivenOutTwiceIsInformationNotAProblem() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(otherRecord(1))
        try phone.sign(otherRecord(2))
        phone.rollBackCount(by: 2)
        try phone.sign(otherRecord(3))
        try phone.sign(otherRecord(4))
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1])]), shown: true)
        let outcome = try checked(phone)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains(repeatNote(key.keyID, at: "2…3") + "\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("  the statements it names as shown: all in the bundle\n"), outcome.text)
        XCTAssertFalse(outcome.text.contains("counters repeated"), outcome.text)
        XCTAssertTrue(outcome.text.contains("\nPASS"), outcome.text)
    }

    /// Item 206 (Codex-1): an export names what a bundle shows by counter, and whether a statement is shown is not signed. So at a
    /// counter two statements share, either one satisfies it, and a sender can cut the other down to its fingerprint with nothing
    /// to catch. The bundle passes, and the report says so under THE EXPORT (the owner's "a", the words approved).
    func testAStatementCutDownToItsFingerprintAtANamedCounterIsSaidUnderTheExport() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(otherRecord(1), shown: true)
        phone.rollBackCount(by: 1)
        try phone.sign(otherRecord(2))
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
        let outcome = try checked(phone)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains(repeatNote(key.keyID, at: "2") + "\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("  the statements it names as shown: all in the bundle by counter; \(secondSignature(at: "2"))\n"),
                      outcome.text)
        XCTAssertTrue(outcome.text.contains("  the statements shown in full: all named by it\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("\nPASS"), outcome.text)
    }

    /// Item 206 (Codex-1), the limit SECURITY.md states: a statement saying a record left the phone's log can share a counter too.
    /// Shown, it ends the bundle in problems. Cut down to its fingerprint it is no longer read, and what is left is the two lines
    /// saying what such a counter costs. Nothing a check can see tells that bundle from a phone's own.
    func testAnAbsenceCutDownToItsFingerprintAtARepeatedCounterIsNoLongerRead() throws {
        let gone = UUID(uuidString: "0C0FFEE0-0000-4000-8000-000000000002") ?? UUID()
        func outcome(shown: Bool) throws -> MalinoisVerifier.Outcome {
            let phone = try TestPhone()
            let key = try phone.certifyKey()
            try phone.sign(revision(1), shown: true)
            try phone.sign(otherRecord(1), shown: true)
            phone.rollBackCount(by: 1)
            try phone.sign(.absence(EvidenceForm.Absence(signedAt: 1_793_000_008_000, app: "1.10 (81)",
                                                         records: [EvidenceForm.Absent(id: gone, revision: 2, startDate: 1_793_000_000_000)])),
                           shown: shown)
            try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
            return try checked(phone)
        }
        let whole = try outcome(shown: true)
        XCTAssertEqual(whole.status, 1, whole.text)
        XCTAssertTrue(whole.text.contains("left its log other than by its limit: \(gone.uuidString)"), whole.text)
        XCTAssertTrue(whole.text.contains("  the statements it names as shown: all in the bundle\n"), whole.text)
        let cut = try outcome(shown: false)
        XCTAssertEqual(cut.status, 0, cut.text)
        XCTAssertFalse(cut.text.contains(gone.uuidString), cut.text)
        XCTAssertTrue(cut.text.contains(secondSignature(at: "2")), cut.text)
        XCTAssertTrue(cut.text.contains("\nPASS"), cut.text)
    }

    /// Guard: the line speaks only of a counter where a statement is shown in full. Beside a repeat, a statement the export names and
    /// the bundle hides stays a problem, and "all in the bundle" gives way to what the bundle lacks.
    func testAStatementHiddenAtACounterOfItsOwnStaysAProblemBesideARepeat() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(otherRecord(1), shown: true)
        phone.rollBackCount(by: 1)
        try phone.sign(otherRecord(2))
        try phone.sign(otherRecord(3))
        phone.rollBackCount(by: 1)
        try phone.sign(otherRecord(4))
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...3])]), shown: true)
        let outcome = try checked(phone)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("  the statements it names as shown: NOT all in the bundle; \(secondSignature(at: "2"))\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("the export names statements the bundle does not show: key \(short(key.keyID)) 3"), outcome.text)
    }

    /// Guard: the line speaks only of a counter the export names. A statement shown in full that it does not name is a problem of
    /// its own, whatever shares its counter.
    func testAFingerprintBesideAStatementTheExportDoesNotNameIsNotSaidUnderTheExport() throws {
        // Past the last counter it names, and between two it names.
        for named: [ClosedRange<UInt32>] in [[1...1], [1...1, 3...3]] {
            let phone = try TestPhone()
            let key = try phone.certifyKey()
            try phone.sign(revision(1), shown: true)
            try phone.sign(otherRecord(1), shown: true)
            phone.rollBackCount(by: 1)
            try phone.sign(otherRecord(2))
            try phone.sign(otherRecord(3), shown: true)
            try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: named)]), shown: true)
            let outcome = try checked(phone)
            XCTAssertEqual(outcome.status, 1, outcome.text)
            XCTAssertTrue(outcome.text.contains("statements shown in full that the export does not name: key \(short(key.keyID)) 2"), outcome.text)
            XCTAssertTrue(outcome.text.contains("  the statements it names as shown: all in the bundle\n"), outcome.text)
        }
    }

    /// Guard: one signature listed twice is one signature, so its fingerprint beside its own statement is no second signature.
    func testASignatureListedAgainAsItsFingerprintIsNoSecondSignature() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(otherRecord(1), shown: true)
        let listed = try XCTUnwrap(phone.signatures.last)
        phone.signatures.append(EvidenceBundle.Signature(key: listed.key, assertion: listed.assertion, statement: listed.statement, shown: false))
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
        let outcome = try checked(phone)
        XCTAssertTrue(outcome.text.contains("  the statements it names as shown: all in the bundle\n"), outcome.text)
        XCTAssertFalse(outcome.text.contains("two signatures each"), outcome.text)
    }

    /// Where more than one key holds such a counter, the line says which, and a key's counter is named by its own key's ranges alone.
    func testTheLineNamesEachKeyWhenTwoHoldSuchACounter() throws {
        let phone = try TestPhone()
        let older = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(otherRecord(1), shown: true)
        phone.rollBackCount(by: 1)
        try phone.sign(otherRecord(2))
        let newer = try phone.certifyKey(follows: older.keyID)
        try phone.sign(otherRecord(3), shown: true)
        phone.rollBackCount(by: 1)
        try phone.sign(otherRecord(4))
        // An export lists its keys in ascending order, whichever the phone made first.
        let named = [EvidenceForm.KeyCounters(keyID: older.keyID, counters: [1...2]), EvidenceForm.KeyCounters(keyID: newer.keyID, counters: [1...1])]
            .sorted { $0.keyID.lexicographicallyPrecedes($1.keyID) }
        try phone.sign(export(1, shown: named), shown: true)
        let outcome = try checked(phone)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        let places = named.map { "\($0.keyID == older.keyID ? "2" : "1") of key \(short($0.keyID))" }.joined(separator: " and ")
        XCTAssertTrue(outcome.text.contains("  the statements it names as shown: all in the bundle by counter; \(secondSignature(at: places))\n"),
                      outcome.text)
    }

    /// A bundle whose phone signed that records left its log other than by its limit (item 182): the verifier names each
    /// record and ends in PROBLEMS.
    func testRecordsThatLeftThePhonesLogOtherThanByItsLimitEndInProblems() throws {
        let phone = try TestPhone()
        let gone = UUID(uuidString: "0C0FFEE0-0000-4000-8000-000000000001") ?? UUID()
        let absence = EvidenceForm.Statement.absence(EvidenceForm.Absence(
            signedAt: 1_793_000_008_000, app: "1.10 (81)",
            records: [EvidenceForm.Absent(id: gone, revision: 2, startDate: 1_793_000_000_000)]))
        let folder = try bundle(phone, statements: [revision(1), absence, export(1)])
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("left its log other than by its limit"), outcome.text)
        XCTAssertTrue(outcome.text.contains(gone.uuidString), outcome.text)
        XCTAssertFalse(outcome.text.contains("\nPASS"), outcome.text)
    }

    /// A statement the export names as shown, sent as its fingerprint by someone passing the bundle on (item 182, the
    /// owner's "B"): a problem.
    func testAStatementTheExportNamesButTheBundleHidesEndsInProblems() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(.record(EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_002, app: "1.10 (81)",
                                                   facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_001))], attachments: [])),
                       shown: false)
        try phone.sign(.export(EvidenceForm.Export(record: shared, revision: 1, signedAt: 1_793_000_009_000, app: "1.10 (81)",
                                                   shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])])), shown: true)
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
                                               attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                       source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-10-31 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("the export names statements the bundle does not show"), outcome.text)
    }

    /// codex-2 on 73441cbe (the owner's "2 - a"): a key a later key follows (a restore from a backup) may have signed after
    /// its last signature in the bundle, and nothing in the bundle can show it did not: the verifier says so, as a limit
    /// of what it can check, not a problem. Item 198's Fable-1: it says only what the later key says, since another iPhone
    /// can make a key that follows this one: nothing in a bundle shows both were on one iPhone.
    func testAKeyALaterKeyFollowsIsSaidToEndUnaccountedFor() throws {
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.certifyKey(follows: first.keyID)
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: first.keyID, counters: [1...1])]), shown: true)
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
                                               attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                       source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-10-31 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        let short = String(EvidenceHash.hex(first.keyID).prefix(8)) + "…"
        XCTAssertTrue(outcome.text.contains("key \(short): a later key says it follows it (as after a restore from a backup, "
                                            + "though nothing here shows both were on one iPhone), so any signatures it "
                                            + "made after counter 1, its last here, cannot be accounted for"), outcome.text)
        XCTAssertFalse(outcome.text.contains("the phone's key changed"), outcome.text)
        XCTAssertTrue(outcome.text.contains("\nPASS"), outcome.text)
    }

    /// codex-2 on 417158fe: the line is said for every key a certified key follows, also one the bundle's unsigned index
    /// leaves out, with none of its counters at hand.
    func testAKeyALaterKeyFollowsIsSaidToEndUnaccountedForWhenTheIndexLeavesItOut() throws {
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(.record(EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_001, app: "1.10 (81)",
                                                   facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_001))],
                                                   attachments: [])))
        let second = try phone.certifyKey(follows: first.keyID)
        try phone.sign(revision(1), shown: true)
        try phone.sign(export(1), shown: true)
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys.filter { $0.id == second.keyID },
                                               signatures: phone.signatures.filter { $0.key == second.keyID }, notes: [],
                                               attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                       source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-10-31 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        let short = String(EvidenceHash.hex(first.keyID).prefix(8)) + "…"
        XCTAssertTrue(outcome.text.contains("key \(short): a later key says it follows it (as after a restore from a backup, "
                                            + "though nothing here shows both were on one iPhone), so any signatures it "
                                            + "made cannot be accounted for"), outcome.text)
    }

    /// Item 185's ds4agent-3: an attachment an earlier revision signed and the last does not (the phone's storage limit
    /// removed the photo and the record was signed again): said, not a problem, so a recipient learns it was there.
    func testAnAttachmentAnEarlierRevisionSignedIsNamed() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(.record(EvidenceForm.Record(id: shared, revision: 2, signedAt: 1_793_000_000_002, app: "1.10 (81)",
                                                   facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                                   attachments: [])), shown: true)
        try phone.sign(export(2, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
                                               attachments: [])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-10-31 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains("primary: signed in revision 1 but not in the last revision"), outcome.text)
    }

    /// Item 190's codex-3 (the owner's "A4 a"): an attachment the last revision signed under a name an earlier revision
    /// signed with other bytes (a photo replaced under its name in iCloud, downloaded and signed again): said, so a
    /// recipient learns the bytes changed; not a problem, since a thumbnail may change honestly.
    func testAnAttachmentWhoseBytesChangedUnderItsNameIsSaid() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        let original = Data("the photo first signed".utf8)
        try phone.sign(.record(EvidenceForm.Record(id: shared, revision: 1, signedAt: 1_793_000_000_001, app: "1.10 (81)",
                                                   facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                                   attachments: [EvidenceForm.Attachment(name: "primary",
                                                                                         digest: EvidenceHash.digest(of: original))])),
                       shown: true)
        try phone.sign(revision(2), shown: true)
        try phone.sign(export(2, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])]), shown: true)
        let outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains("primary: as signed"), outcome.text)
        XCTAssertTrue(outcome.text.contains("primary: signed with other bytes in revision 1; the bundle contains the last revision's"),
                      outcome.text)
        // Unchanged, nothing is said.
        let unchanged = try TestPhone()
        let unchangedKey = try unchanged.certifyKey()
        try unchanged.sign(revision(1), shown: true)
        try unchanged.sign(revision(2), shown: true)
        try unchanged.sign(export(2, shown: [EvidenceForm.KeyCounters(keyID: unchangedKey.keyID, counters: [1...2])]), shown: true)
        let plain = MalinoisVerifier.run([try written(unchanged).path, "--root", try rootFile(unchanged).path], appIDHash: testAppHash)
        XCTAssertEqual(plain.status, 0, plain.text)
        XCTAssertFalse(plain.text.contains("signed with other bytes"), plain.text)
        // Changed twice: the first revision with other bytes is the one named.
        let twice = try TestPhone()
        let twiceKey = try twice.certifyKey()
        for (number, bytes) in [(Int64(1), original), (2, Data("another photo again".utf8))] {
            try twice.sign(.record(EvidenceForm.Record(id: shared, revision: number, signedAt: 1_793_000_000_000 + number,
                                                       app: "1.10 (81)",
                                                       facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                                       attachments: [EvidenceForm.Attachment(name: "primary",
                                                                                             digest: EvidenceHash.digest(of: bytes))])),
                           shown: true)
        }
        try twice.sign(revision(3), shown: true)
        try twice.sign(export(3, shown: [EvidenceForm.KeyCounters(keyID: twiceKey.keyID, counters: [1...3])]), shown: true)
        let named = MalinoisVerifier.run([try written(twice).path, "--root", try rootFile(twice).path], appIDHash: testAppHash)
        XCTAssertEqual(named.status, 0, named.text)
        XCTAssertTrue(named.text.contains("primary: signed with other bytes in revision 1;"), named.text)
    }

    /// Item 190's codex-1: with a restore's two keys, the older key's signatures come first whatever order the file gives
    /// the lines: each key counts from 1, so counters alone cannot order them.
    func testTheOlderKeysSignaturesComeFirstWhateverTheFilesOrder() throws {
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        let second = try phone.certifyKey(follows: first.keyID)
        try phone.sign(revision(2), shown: true)
        let named = [first.keyID, second.keyID].sorted { $0.lexicographicallyPrecedes($1) }
            .map { EvidenceForm.KeyCounters(keyID: $0, counters: [1...1]) }
        try phone.sign(export(2, shown: named), shown: true)
        var lines = phone.signatures
        lines.swapAt(0, 1)
        let outcome = MalinoisVerifier.run([try written(phone, signatures: lines).path, "--root", try rootFile(phone).path],
                                           appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        let older = try XCTUnwrap(outcome.text.range(of: "key \(short(first.keyID)) counter 1:"), outcome.text)
        let newer = try XCTUnwrap(outcome.text.range(of: "key \(short(second.keyID)) counter 1:"), outcome.text)
        XCTAssertLessThan(older.lowerBound, newer.lowerBound, outcome.text)
    }

    /// Item 190's codex-1 and deepseek-4: a statement shown in full that the export does not name (copied in from another
    /// of the phone's bundles by someone passing this one on) ends in PROBLEMS, named by its key and counter.
    func testAStatementShownThatTheExportDoesNotNameEndsInProblems() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(.record(EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_002, app: "1.10 (81)",
                                                   facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_001)),
                                                           EvidenceJSON.Member("stateChange", .string("pinChanged"))],
                                                   attachments: [])), shown: true)
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1])]), shown: true)
        let outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("the statements shown in full: NOT all named by it"), outcome.text)
        XCTAssertTrue(outcome.text.contains("statements shown in full that the export does not name: key \(short(key.keyID)) 2"),
                      outcome.text)
        XCTAssertFalse(outcome.text.contains("\nPASS"), outcome.text)
    }

    /// Item 190's codex-1: another phone's key, certified by Apple as every phone's is, with a status it signed, put in
    /// beside this phone's: PROBLEMS, the key named as neither the export's nor one it follows.
    func testAnotherPhonesKeyBesideThisPhonesEndsInProblems() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...1])]), shown: true)
        let stranger = TestPhone(chain: phone.chain)
        let strangerKey = try stranger.certifyKey()
        try stranger.sign(.record(EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_002, app: "1.10 (81)",
                                                      facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_001)),
                                                              EvidenceJSON.Member("stateChange", .string("disarmed"))],
                                                      attachments: [])), shown: true)
        let folder = try written(phone, keys: stranger.bundleKeys + phone.bundleKeys, signatures: stranger.signatures + phone.signatures)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("key \(short(strangerKey.keyID)): neither the export's key nor a key it follows"),
                      outcome.text)
        XCTAssertFalse(outcome.text.contains("\nPASS"), outcome.text)
    }

    /// Item 190's deepseek-1 and deepseek-6 on 29d6501: a backup edited to take out the last key's lines and keep the
    /// earlier keys'. The earlier keys still end the check in problems, the history being cut, but named as cut off from
    /// the export's key by the key the bundle lacks, not as another phone's; and the signatures' heading says that those
    /// of keys outside the export's chain come after it (the owner's "b").
    func testKeysCutOffByAKeyTheBundleLacksAreNamedAsCutOff() throws {
        // deepseek-2 on b7702f5 (the owner's "a"): words true of any key the chain cannot reach, a stranger's among them,
        // and of the key the chain stops at whether or not the bundle holds its line uncertified.
        func cutOff(_ keyID: Data, at stop: Data) -> String {
            "key \(short(keyID)): cannot be tied to the export's key; the export's chain stops at key \(short(stop)), "
                + "which this bundle does not certify"
        }
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        let lost = Data(repeating: 0xC3, count: 32)   // the key the edit took out: no line of it in the bundle
        _ = try phone.certifyKey(follows: lost)
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: first.keyID, counters: [1...1])]), shown: true)
        let stranger = TestPhone(chain: phone.chain)   // another install's key beside them, a root of its own
        let strangerKey = try stranger.certifyKey()
        let folder = try written(phone, keys: stranger.bundleKeys + phone.bundleKeys, signatures: phone.signatures)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains(cutOff(first.keyID, at: lost)), outcome.text)
        XCTAssertTrue(outcome.text.contains(cutOff(strangerKey.keyID, at: lost)), outcome.text)
        XCTAssertFalse(outcome.text.contains("neither the export's key nor a key it follows"), outcome.text)
        XCTAssertTrue(outcome.text.contains("\nSIGNATURES, in the phone's order, then those of keys outside the export's chain\n"),
                      outcome.text)
        // The key the chain stops at in the bundle, its certification not checking out: the same words.
        let held = try TestPhone()
        let earlier = try held.certifyKey()
        try held.sign(revision(1), shown: true)
        let spoiled = try held.certifyKey(follows: earlier.keyID)
        _ = try held.certifyKey(follows: spoiled.keyID)
        try held.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: earlier.keyID, counters: [1...1])]), shown: true)
        var keys = held.bundleKeys
        keys[1] = EvidenceBundle.Key(id: spoiled.keyID, statement: spoiled.statement, attestation: Data("not Apple's".utf8))
        let heldOutcome = MalinoisVerifier.run([try written(held, keys: keys).path, "--root", try rootFile(held).path],
                                               appIDHash: testAppHash)
        XCTAssertTrue(heldOutcome.text.contains(cutOff(earlier.keyID, at: spoiled.keyID)), heldOutcome.text)
        // With every key in the export's chain, the heading is as it was.
        let whole = try TestPhone()
        let plain = MalinoisVerifier.run([try bundle(whole).path, "--root", try rootFile(whole).path], appIDHash: testAppHash)
        XCTAssertTrue(plain.text.contains("\nSIGNATURES, in the phone's order\n"), plain.text)
    }

    /// Item 190's codex-1: with more than one key (a restore from a backup), each signature's line names its key, since
    /// each key counts from 1; with one, the lines are as before.
    func testWithMoreThanOneKeyEachSignatureNamesItsKey() throws {
        let phone = try TestPhone()
        let first = try phone.certifyKey()
        try phone.sign(revision(1), shown: true)
        let second = try phone.certifyKey(follows: first.keyID)
        try phone.sign(export(1, shown: [EvidenceForm.KeyCounters(keyID: first.keyID, counters: [1...1])]), shown: true)
        let outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains("  key \(short(first.keyID)) counter 1: THE RECORD SHARED"), outcome.text)
        XCTAssertTrue(outcome.text.contains("  key \(short(second.keyID)) counter 1: EXPORT"), outcome.text)
        let single = try TestPhone()
        let plain = MalinoisVerifier.run([try bundle(single).path, "--root", try rootFile(single).path], appIDHash: testAppHash)
        XCTAssertTrue(plain.text.contains("\n  counter 1: THE RECORD SHARED"), plain.text)
    }

    /// Item 190's codex-1: the signatures are shown in the order their keys and counters prove, the oldest key first,
    /// whatever order the bundle's file puts its lines in, so "the phone's order" is never the file's word alone.
    func testTheSignaturesAreShownInTheOrderTheirKeysAndCountersProve() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let file = folder.appendingPathComponent("signatures.jsonl")
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.swapAt(0, 1)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        let one = try XCTUnwrap(outcome.text.range(of: "  counter 1: "), outcome.text)
        let two = try XCTUnwrap(outcome.text.range(of: "  counter 2: "), outcome.text)
        XCTAssertLessThan(one.lowerBound, two.lowerBound, outcome.text)
    }

    /// Codex's codex-1 on 09d997f: a file the bundle's layout does not name, in the bundle or beside its folder, given as a
    /// folder or as a ZIP, is one of the report's problems, named; Finder's own `.DS_Store` files are named and not judged
    /// (the owner's "codex-1 a").
    func testAFileTheBundleDoesNotAccountForEndsInProblemsInsideOrBesideIt() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let holder = folder.deletingLastPathComponent()
        let root = try rootFile(phone)
        func run(_ target: URL) -> MalinoisVerifier.Outcome {
            MalinoisVerifier.run([target.path, "--root", root.path], appIDHash: testAppHash)
        }
        // Finder's own files, in the bundle and beside it: named, and the bundle still checks out.
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try Data().write(to: holder.appendingPathComponent(".DS_Store"))
        var outcome = run(holder)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.contains("  .DS_Store: "), outcome.text)
        // A photo added in the bundle: a problem, given as its folder and as the ZIP of it.
        try Data("another photo".utf8).write(to: folder.appendingPathComponent("attachments/added.jpg"))
        for target in [folder, try zipped(folder)] {
            outcome = run(target)
            XCTAssertEqual(outcome.status, 1, outcome.text)
            XCTAssertTrue(outcome.text.contains("not part of the bundle: attachments/added.jpg"), outcome.text)
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("attachments/added.jpg"))
        try FileManager.default.removeItem(at: holder.appendingPathComponent("\(folder.lastPathComponent).zip"))
        // A photo beside the bundle's folder: a problem, given as the folder holding both and as a ZIP of both.
        try Data("another photo".utf8).write(to: holder.appendingPathComponent("added.jpg"))
        let both = base.appendingPathComponent("both-\(UUID().uuidString).zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", holder.path, both.path])
        for target in [holder, both] {
            outcome = run(target)
            XCTAssertEqual(outcome.status, 1, outcome.text)
            XCTAssertTrue(outcome.text.contains("not part of the bundle: added.jpg, beside its folder"), outcome.text)
            XCTAssertTrue(outcome.text.contains("PROBLEMS (1)"), "Finder's files beside it no problem: \(outcome.text)")
        }
    }

    /// Codex's codex-2 on 07b7134 (item 187's round B): a ZIP's `__MACOSX` entries, which macOS's unzip tool took as file
    /// metadata and wrote no file for, are unpacked as files and named; and codex-1 on 07b7134: a folder in the README's
    /// place, a photo in it, ends in problems, as a folder and as a ZIP.
    func testWhatAZIPCanHideUnderMacOSsFoldersOrTheREADMEEndsInProblems() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let holder = folder.deletingLastPathComponent()
        let root = try rootFile(phone)
        func run(_ target: URL) -> MalinoisVerifier.Outcome {
            MalinoisVerifier.run([target.path, "--root", root.path], appIDHash: testAppHash)
        }
        // `__MACOSX` entries beside the bundle's folder, as zip writes them.
        let mac = holder.appendingPathComponent("__MACOSX/\(folder.lastPathComponent)", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try Data("unsigned bytes".utf8).write(to: mac.appendingPathComponent("._unsigned-photo.jpg"))
        let withMac = base.appendingPathComponent("macosx-\(UUID().uuidString).zip")
        try runTool("/usr/bin/zip", ["-q", "-r", "-y", withMac.path, folder.lastPathComponent, "__MACOSX"], in: holder)
        var outcome = run(withMac)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("not part of the bundle: __MACOSX, beside its folder"), outcome.text)
        try FileManager.default.removeItem(at: holder.appendingPathComponent("__MACOSX"))
        // A folder in the README's place, a photo in it.
        let readme = folder.appendingPathComponent(EvidenceBundle.readmeName)
        try FileManager.default.removeItem(at: readme)
        try FileManager.default.createDirectory(at: readme, withIntermediateDirectories: false)
        try Data("another photo".utf8).write(to: readme.appendingPathComponent("unsigned-photo.jpg"))
        for target in [folder, try zipped(folder)] {
            outcome = run(target)
            XCTAssertEqual(outcome.status, 1, outcome.text)
            XCTAssertTrue(outcome.text.contains("not part of the bundle: README.txt"), outcome.text)
        }
    }

    /// Item 187's round B (Claude's, found with codex-2 on 07b7134): a ZIP with two entries for one file, the same name or
    /// names that differ only in letter case, unpacks to one, the last, so the first's bytes were never checked though
    /// another unzip tool may show them. Such a ZIP is refused, nothing checked.
    func testAZIPThatUnpacksToFewerFilesThanItListsIsRefused() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        for decoy in ["attachments/primary.jpg", "attachments/PRIMARY.jpg"] {
            let zip = base.appendingPathComponent("twice-\(UUID().uuidString).zip")
            try runTool("/usr/bin/python3", ["-I", "-c", Self.zipWithADecoy, folder.path, zip.path, decoy])
            let outcome = MalinoisVerifier.run([zip.path, "--root", root.path], appIDHash: testAppHash)
            XCTAssertEqual(outcome.status, 2, "\(decoy): \(outcome.text)")
            XCTAssertTrue(outcome.text.contains("fewer files than it lists"), outcome.text)
        }
    }

    /// The count itself: a listing's file entries (not its folders), against the plain files a ZIP unpacked to.
    func testTheFilesAZIPListsAreCountedAgainstWhatItUnpackedTo() throws {
        let fields = "  2.0 unx        2 b-        2 stor 26-Oct-31 15:10 "
        let listing = "Archive:  x.zip\nZip file size: 10 bytes, number of entries: 5\n"
            + "drwxr-xr-x" + fields + "bundle/\n" + "-rw-r--r--" + fields + "bundle/a\n" + "-rw-r--r--" + fields + "bundle/a\n"
            + "?rw-------" + fields + "bundle/b\n" + "?rwxr-xr-x" + fields + "bundle/c/\n"
            + "5 files, 4 bytes uncompressed, 4 bytes compressed:  0.0%\n"
        // An entry of no stated type, as Python's zipfile writes one, is a file unless its name ends in "/".
        XCTAssertEqual(MalinoisVerifier.fileEntries(inListing: listing), 3)
        XCTAssertNil(MalinoisVerifier.fileEntries(inListing: "garbage"), "a listing it cannot read")
        let folder = base.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: folder.appendingPathComponent("bundle/a"))
        XCTAssertNotNil(MalinoisVerifier.refusal(ofUnpacked: folder, listedFiles: 2), "two entries, one file")
        XCTAssertNil(MalinoisVerifier.refusal(ofUnpacked: folder, listedFiles: 1))
        // A file whose name begins "._", which Foundation's folder listings on macOS leave out, counts as the file it is.
        try Data("bytes".utf8).write(to: folder.appendingPathComponent("bundle/._b"))
        XCTAssertNil(MalinoisVerifier.refusal(ofUnpacked: folder, listedFiles: 2), "two files, one named ._b")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofUnpacked: folder, listedFiles: 1))
    }

    /// Item 187's round B (Claude's, found while fixing codex-2 on 07b7134): Foundation's folder listings on macOS leave
    /// out every name that begins "._", so a photo added under such a name, in the bundle or beside its folder, passed
    /// the check unseen, as a folder and as a ZIP. Each is named among the problems now.
    func testANameBeginningWithADotAndAnUnderscoreEndsInProblems() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let holder = folder.deletingLastPathComponent()
        let root = try rootFile(phone)
        func run(_ target: URL) -> MalinoisVerifier.Outcome {
            MalinoisVerifier.run([target.path, "--root", root.path], appIDHash: testAppHash)
        }
        let inside = folder.appendingPathComponent("._unsigned-photo.jpg")
        try Data("an unsigned photo".utf8).write(to: inside)
        for target in [folder, try zipped(folder)] {
            let outcome = run(target)
            XCTAssertEqual(outcome.status, 1, outcome.text)
            XCTAssertTrue(outcome.text.contains("not part of the bundle: ._unsigned-photo.jpg"), outcome.text)
        }
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.removeItem(at: holder.appendingPathComponent("\(folder.lastPathComponent).zip"))
        try Data("an unsigned photo".utf8).write(to: holder.appendingPathComponent("._unsigned-photo.jpg"))
        let outcome = run(holder)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("not part of the bundle: ._unsigned-photo.jpg, beside its folder"), outcome.text)
    }

    /// Item 187's round B (Claude's, found while fixing codex-2 on 07b7134): a ZIP that `ditto` makes on a Mac from files
    /// with extended attributes holds a "._" entry after each, which macOS's unzip tool folds into the file before it as
    /// metadata, writing no file for it, so what the entry held reached no check. Such a ZIP unpacks to fewer files than
    /// it lists, and is refused, nothing checked.
    func testAZIPWhoseEntriesMacOSFoldsIntoOtherFilesIsRefused() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        let index = folder.appendingPathComponent(EvidenceBundle.indexName)
        XCTAssertEqual(setxattr(index.path, "com.example.malinois-test", "x", 1, 0, 0), 0, "an extended attribute set")
        let zip = base.appendingPathComponent("folded-\(UUID().uuidString).zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
        let outcome = MalinoisVerifier.run([zip.path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        XCTAssertTrue(outcome.text.contains("fewer files than it lists"), outcome.text)
    }

    /// Codex's codex-1 on fde1689 (item 187's round C): a ZIP's index and each entry's own header can name the entry
    /// differently, and macOS's unzip tool writes the header's name. An earlier entry the index names as a folder was
    /// unpacked as one of the bundle's files and written over by it, so the counts matched and its bytes reached no
    /// check; and a reader that reads a ZIP front to back shows an entry the index leaves out. A ZIP whose readings
    /// disagree is refused, nothing checked, while the bundle it was made from passes as its ZIP. Since round D the
    /// layout refuses those two first, and their three readings, taken as the verifier takes them, refuse them on their
    /// own; an entry that holds bytes while the index's attributes call it a folder is laid out plainly, and its
    /// readings refuse it: a reader that goes by the index makes a folder of it, and its bytes would reach no check.
    func testAZIPWhoseIndexAndEntriesDisagreeIsRefused() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        func run(_ target: URL) -> MalinoisVerifier.Outcome {
            MalinoisVerifier.run([target.path, "--root", root.path], appIDHash: testAppHash)
        }
        let plain = try zipped(folder)
        XCTAssertEqual(run(plain).status, 0, "the bundle passes as its ZIP")
        try FileManager.default.removeItem(at: plain)
        for (how, refused) in [("named-as-a-folder", "it is not laid out as one plain ZIP"),
                               ("left-out-of-the-index", "it is not laid out as one plain ZIP"),
                               ("called-a-folder", "its index and its entries name different files")] {
            let zip = base.appendingPathComponent("\(how)-\(UUID().uuidString).zip")
            try runTool("/usr/bin/python3", ["-I", "-c", Self.zipWithAHiddenEntry, folder.path, zip.path, "attachments/primary.jpg", how])
            let outcome = run(zip)
            XCTAssertEqual(outcome.status, 2, "\(how): \(outcome.text)")
            XCTAssertTrue(outcome.text.contains(refused), "\(how): \(outcome.text)")
            let listing = try XCTUnwrap(MalinoisVerifier.listing(of: zip), how)
            let read = try XCTUnwrap(MalinoisVerifier.readings(of: zip), how)
            XCTAssertEqual(MalinoisVerifier.refusal(ofListing: listing, unpacking: read.unpacking, streaming: read.streaming),
                           "its index and its entries name different files", how)
        }
    }

    /// Codex's codex-1 on 3096c70 (item 187's round D): readings whose names agree can still be of different bytes. A ZIP
    /// made of two archives, an altered copy of the bundle first and the real one's index moved past it, reads the real
    /// files by its index and the altered ones front to back; an index whose key statement and attestation swap names
    /// reads each file's bytes under the other's name in a reader that goes by the index. Both passed the check. A ZIP
    /// that is not laid out as one plain run of files is refused, nothing checked, while the bundle passes as a plain ZIP.
    func testAZIPThatReadersCanReadDifferentlyIsRefused() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        let made = base.appendingPathComponent("layouts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
        try runTool("/usr/bin/python3", ["-I", "-c", Self.zipLayouts, folder.path, made.path])
        func run(_ name: String) -> MalinoisVerifier.Outcome {
            MalinoisVerifier.run([made.appendingPathComponent(name).path, "--root", root.path], appIDHash: testAppHash)
        }
        let plain = run("plain.zip")
        XCTAssertEqual(plain.status, 0, "the bundle passes as a plain ZIP: \(plain.text)")
        for name in ["two-archives.zip", "names-swapped.zip"] {
            let outcome = run(name)
            XCTAssertEqual(outcome.status, 2, "\(name): \(outcome.text)")
            XCTAssertTrue(outcome.text.contains("it is not laid out as one plain ZIP"), "\(name): \(outcome.text)")
        }
    }

    /// Codex's codex-3 on c68e3ec (item 187's round E): a file's own header can carry a second name, the Info-ZIP Unicode
    /// Path field, which `bsdtar` unpacks it under, in both its readings, while the index and readers that go by it keep
    /// the first. A bundle's key statement and attestation trading bytes under their names, each header naming the other,
    /// passed every check as the genuine bundle, while a reader that goes by the index shows the two swapped. A ZIP whose
    /// files carry an extra field other than those genuine ZIPs carry is refused, nothing checked.
    func testAZIPWhoseFilesTradeNamesInTheirHeadersIsRefused() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        let zip = base.appendingPathComponent("second-names-\(UUID().uuidString).zip")
        try runTool("/usr/bin/python3", ["-I", "-c", Self.zipWithSecondNames, folder.path, zip.path])
        let outcome = MalinoisVerifier.run([zip.path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        XCTAssertTrue(outcome.text.contains("it is not laid out as one plain ZIP (a file carries an extra field the check does not allow)"),
                      outcome.text)
    }

    /// The layout itself (item 187's rounds D and E): a plain ZIP passes, as `ditto`, Info-ZIP's `zip` or Python writes
    /// it, with files' sizes after their data (each data descriptor signed or not), an empty stored file's after it, an
    /// ordinary comment, and the extra fields the phone's ZIPs carry; every other way out of one plain run of files is
    /// refused for its own reason, each of the check's conditions held by a ZIP of its own (`zipLayouts`); a ZIP cut
    /// short, a file that is no ZIP and one that is not there are refused. A compressed file whose stream ends before the
    /// size the index gives it has plain headers, so the layout passes it: `bsdtar` refuses it as it unpacks it, and the
    /// verifier with it (DeepSeek's deepseek-2 on c68e3ec).
    func testOnlyOnePlainRunOfFilesIsAZIPsLayout() throws {
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        for (path, bytes) in [("bundle.json", "{}"), ("keys/aa.json", "k"), ("keys/aa.cbor", "c"), ("attachments/primary.jpg", "photo")] {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes.utf8).write(to: file)
        }
        let made = base.appendingPathComponent("layouts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
        try runTool("/usr/bin/python3", ["-I", "-c", Self.zipLayouts, folder.path, made.path])
        try runTool("/usr/bin/zip", ["-q", "-r", made.appendingPathComponent("info-zip.zip").path, folder.lastPathComponent],
                    in: folder.deletingLastPathComponent())
        func refusal(_ name: String) -> String? { MalinoisVerifier.refusal(ofLayout: made.appendingPathComponent(name)) }
        XCTAssertNil(MalinoisVerifier.refusal(ofLayout: try zipped(folder)), "as ditto zips it")
        for name in ["plain.zip", "deflated-after.zip", "descriptor-unsigned.zip", "stored-empty-after.zip", "info-zip.zip",
                     "unix-extras.zip", "comment-text.zip", "deflate-early.zip"] {
            XCTAssertNil(refusal(name), name)
        }
        let early = MalinoisVerifier.run([made.appendingPathComponent("deflate-early.zip").path])
        XCTAssertEqual(early.status, 2, early.text)
        XCTAssertTrue(early.text.contains("was not unpacked: macOS could not unpack it. Nothing was checked."), early.text)
        let refused = [
            ("comment-sig.zip", "its comment contains an end record's signature"),
            ("comment-sig-24.zip", "its comment contains an end record's signature"),
            ("comment-fake-end.zip", "its index is not where its end record says"),
            ("unicode-path.zip", "a file carries an extra field the check does not allow"),
            ("unicode-path-index.zip", "a file carries an extra field the check does not allow"),
            ("extra-not-a-list.zip", "a file's extra fields are not one list of fields"),
            ("extra-past-its-end.zip", "a file's extra fields are not one list of fields"),
            ("stored-zero-after.zip", "a stored file's sizes come after its data"),
            ("stored-short.zip", "a stored file's two sizes differ"),
            ("stored-after-short.zip", "a stored file's sizes come after its data"),
            ("folder-with-bytes.zip", "a folder's entry contains bytes"),
            ("folder-deflated.zip", "a folder's entry contains bytes"),
            ("folder-sized.zip", "a folder's entry contains bytes"),
            ("index-extra-long.zip", "its index is not one list of files"),
            ("leading.zip", "its index is not where its end record says"),
            ("trailing.zip", "bytes after its end"),
            ("split-disk.zip", "a ZIP64 or split archive"),
            ("split-index-disk.zip", "a ZIP64 or split archive"),
            ("split-entries.zip", "a ZIP64 or split archive"),
            ("zip64-count.zip", "a ZIP64 or split archive"),
            ("zip64-index-size.zip", "a ZIP64 or split archive"),
            ("zip64-index-offset.zip", "a ZIP64 or split archive"),
            ("index-gap.zip", "its index is not where its end record says"),
            ("index-too-large.zip", "its index is not where its end record says"),
            ("index-count-high.zip", "its index is not one list of files"),
            ("index-signature.zip", "its index is not one list of files"),
            ("index-disk.zip", "its index is not one list of files"),
            ("index-name-long.zip", "its index is not one list of files"),
            ("index-padding.zip", "its index is not one list of files"),
            ("two-archives.zip", "a file is not where the run of files puts it"),
            ("encrypted.zip", "a file is encrypted, ZIP64 or compressed another way"),
            ("bzip2.zip", "a file is encrypted, ZIP64 or compressed another way"),
            ("zip64-size.zip", "a file is encrypted, ZIP64 or compressed another way"),
            ("zip64-compressed.zip", "a file is encrypted, ZIP64 or compressed another way"),
            ("stored-after.zip", "a stored file's sizes come after its data"),
            ("local-signature.zip", "a file's own header names another file"),
            ("flags-differ.zip", "a file's own header names another file"),
            ("method-differs.zip", "a file's own header names another file"),
            ("names-swapped.zip", "a file's own header names another file"),
            ("local-name-long.zip", "it ends too soon"),
            ("sizes-differ.zip", "a file's sizes differ between its header and the index"),
            ("zero-sizes.zip", "a file's sizes differ between its header and the index"),
            ("after-local-sizes.zip", "a file's sizes differ between its header and the index"),
            ("between-files-and-index.zip", "bytes between its files and its index"),
            ("descriptor-differs.zip", "a file's data descriptor is not the index's"),
        ]
        for (name, reason) in refused {
            XCTAssertEqual(refusal(name), "it is not laid out as one plain ZIP (\(reason))", name)
        }
        XCTAssertEqual(refusal("truncated.zip"), "it is not a ZIP that macOS can read", "cut short")
        try Data("not a zip".utf8).write(to: made.appendingPathComponent("not.zip"))
        XCTAssertEqual(refusal("not.zip"), "it is not a ZIP that macOS can read", "no ZIP")
        XCTAssertEqual(refusal("missing.zip"), "it could not be read", "no file")
    }

    /// The three readings compared (item 187's round C): the same entries, names and kinds in any order pass; a name, a
    /// kind or an entry more in one reading, or a reading that cannot be read, refuses.
    func testTheThreeReadingsOfAZIPMustNameTheSameEntries() throws {
        func index(_ entries: [(String, String)]) -> String {
            "Archive:  x.zip\nZip file size: 10 bytes, number of entries: \(entries.count)\n"
                + entries.map { $0.0 + "  2.0 unx        2 b-        2 stor 26-Oct-31 15:10 " + $0.1 + "\n" }.joined()
                + "\(entries.count) files, 4 bytes uncompressed, 4 bytes compressed:  0.0%\n"
        }
        func reading(_ entries: [(String, String)]) -> String {
            entries.map { $0.0 + "  0 501    20           2 Oct 31 15:10 " + $0.1 + "\n" }.joined()
        }
        let listed = index([("drwxr-xr-x", "bundle/"), ("-rw-r--r--", "bundle/a b"), ("?rw-------", "bundle/c")])
        let same = reading([("-rw-r--r--", "bundle/c"), ("drwxr-xr-x", "bundle/"), ("-rw-rw-r--", "bundle/a b")])
        XCTAssertNil(MalinoisVerifier.refusal(ofListing: listed, unpacking: same, streaming: same), "the same, in another order")
        let renamed = reading([("drwxr-xr-x", "bundle/"), ("-rw-r--r--", "bundle/a b"), ("-rw-r--r--", "bundle/d")])
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listed, unpacking: renamed, streaming: same), "a name")
        let folderInIndex = index([("drwxr-xr-x", "bundle/"), ("-rw-r--r--", "bundle/a b"), ("?rw-------", "bundle/c/")])
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: folderInIndex, unpacking: same, streaming: same), "a folder")
        let folderRead = reading([("drwxr-xr-x", "bundle/"), ("-rw-r--r--", "bundle/a b"), ("drwxr-xr-x", "bundle/c")])
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listed, unpacking: same, streaming: folderRead), "a kind")
        let more = reading([("drwxr-xr-x", "bundle/"), ("-rw-r--r--", "bundle/a b"), ("-rw-r--r--", "bundle/a b"),
                            ("-rw-r--r--", "bundle/c")])
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listed, unpacking: same, streaming: more), "an entry more")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listed, unpacking: same, streaming: "garbage"), "unreadable")
    }

    /// Qwen's qwen-3 on 09d997f (item 187's round B): the verifier as a reader builds it, with the README's one command,
    /// run as a program: on a bundle certified for Malinois's App ID (by the test chain, given with --root) it prints
    /// PASS and exits 0; with a file added, it names it and exits 1. The gate's macOS lane names the source it builds the
    /// program from (`MALINOIS_SOURCE`).
    func testTheVerifierAsAReaderBuildsItChecksABundleAsAProgram() throws {
        let source = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MALINOIS_SOURCE"],
                                                        "the source the macOS lane names"))
        let files = try ["MalinoisEvidence", "MalinoisVerifier"].flatMap { folder in
            try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent(folder).path)
                .filter { $0.hasSuffix(".swift") }.sorted().map { source.appendingPathComponent("\(folder)/\($0)").path }
        }
        let program = base.appendingPathComponent("malinois-verify")
        try runTool("/usr/bin/xcrun", ["swiftc", "-O"] + files + ["-o", program.path])
        let phone = try TestPhone(appIDHash: MalinoisVerifier.appIDHash)
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        var (status, text) = try launch(program, [try zipped(folder).path, "--root", root.path])
        XCTAssertEqual(status, 0, text)
        XCTAssertTrue(text.contains("\nPASS\n"), text)
        try Data("another photo".utf8).write(to: folder.appendingPathComponent("attachments/added.jpg"))
        (status, text) = try launch(program, [folder.path, "--root", root.path])
        XCTAssertEqual(status, 1, text)
        XCTAssertTrue(text.contains("not part of the bundle: attachments/added.jpg"), text)
    }

    /// Item 185's ds4agent-4: what a ZIP unpacked to is checked after the listing it gave of itself: anything but plain
    /// files and folders is refused.
    func testWhatAZIPUnpackedToMustBePlainFilesAndFolders() throws {
        let folder = base.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inside"), withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: folder.appendingPathComponent("inside/plain.txt"))
        XCTAssertNil(MalinoisVerifier.refusal(ofUnpacked: folder), "plain files and folders")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("inside/link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNotNil(MalinoisVerifier.refusal(ofUnpacked: folder), "a link is refused")
    }

    func testABundleWithAProblemEndsInItsProblemsWithStatusOne() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone, losing: 2)   // a counter whose signature the bundle lost
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertFalse(outcome.text.contains("PASS"), outcome.text)
        XCTAssertTrue(outcome.text.contains("missing: 2"), outcome.text)
    }

    func testWithoutAReadersRootItChecksAgainstApplesAndATestChainFailsIt() throws {
        let phone = try TestPhone()
        let outcome = MalinoisVerifier.run([try bundle(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("Apple's certificate chain does not check out"), outcome.text)
    }

    func testAnotherAppsKeyFailsAgainstMalinoissHash() throws {
        let phone = try TestPhone()
        let outcome = MalinoisVerifier.run([try bundle(phone).path, "--root", try rootFile(phone).path])
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertTrue(outcome.text.contains("belongs to another app"), outcome.text)
    }

    func testWhatIsNotABundleIsSaidSoWithStatusTwo() throws {
        let empty = base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let notAZip = base.appendingPathComponent("not.zip")
        try Data("not a zip".utf8).write(to: notAZip)
        let notARoot = base.appendingPathComponent("root.pem")
        try Data("not a certificate".utf8).write(to: notARoot)
        let cases = [[empty.path], [notAZip.path], [base.appendingPathComponent("absent.zip").path]]
        for arguments in cases {
            let outcome = MalinoisVerifier.run(arguments)
            XCTAssertEqual(outcome.status, 2, "\(arguments): \(outcome.text)")
            XCTAssertFalse(outcome.text.isEmpty, "\(arguments): it says why")
        }
        // A root that is not a certificate: refused before a whole bundle is checked.
        let outcome = MalinoisVerifier.run([try bundle(try TestPhone()).path, "--root", notARoot.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        XCTAssertTrue(outcome.text.hasPrefix("No root certificate could be read"), outcome.text)
    }

    func testAZIPWithALinkIsRefusedBeforeItIsUnpacked() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: base)
        let outcome = MalinoisVerifier.run([try zipped(folder, keepingLinks: true).path, "--root", try rootFile(phone).path],
                                           appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        XCTAssertTrue(outcome.text.contains("a link"), outcome.text)
    }

    func testAZIPsListingIsReadForLinksPathsOutsideItAndItsSize() {
        let header = "Archive:  x.zip\nZip file size: 10 bytes, number of entries: 1\n"
        func listing(_ entry: String, uncompressed: String = "2") -> String {
            header + entry + "\n1 file, \(uncompressed) bytes uncompressed, 2 bytes compressed:  0.0%\n"
        }
        let fields = "  2.0 unx        2 b-        2 stor 26-Oct-31 15:10 "
        XCTAssertNil(MalinoisVerifier.refusal(ofListing: listing("-rw-r--r--" + fields + "Malinois evidence 2026-10-31 0100/bundle.json")))
        XCTAssertNil(MalinoisVerifier.refusal(ofListing: listing("drwxr-xr-x" + fields + "Malinois evidence 2026-10-31 0100/")))
        XCTAssertEqual(MalinoisVerifier.refusal(ofListing: listing("lrwxr-xr-x" + fields + "bundle/linked")),
                       "it contains a link (bundle/linked)", "a link")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listing("-rw-r--r--" + fields + "../escaped.txt")), "outside")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listing("-rw-r--r--" + fields + "a/../../escaped.txt")), "outside, further in")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listing("-rw-r--r--" + fields + "/etc/escaped")), "a path from the root")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listing("-rw-r--r--" + fields + "big.bin", uncompressed: "5000000000")),
                        "more than a phone keeps of media")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: header + "\n"), "entries it cannot find")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: "garbage"), "a listing it cannot read")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listing("garbage")), "an entry it cannot read")
        XCTAssertNotNil(MalinoisVerifier.refusal(ofListing: listing("-rw-r--r--" + fields + "a.json").replacingOccurrences(
            of: "number of entries: 1", with: "number of entries: 2")), "fewer entries than its header says")
    }

    // MARK: - What a pass says (item 192's step 3), and a ZIP named by its own name (item 187's deepseek-9)

    /// The words the owner approved (2026-11-04: "approved"; item 198, 2026-11-05, and item 206, 2026-11-06: "wording approved"),
    /// printed under PASS and only there.
    private static let passWords =
        "A pass shows: each signature was made by a key Apple certified for Malinois; the record, and each photo, clip "
        + "and trace in this ZIP, is byte for byte what was signed; and the ZIP accounts for every counter of the export's "
        + "key up to the export.\n"
        + "It cannot show: which iPhone made the ZIP or whose (any Malinois on any iPhone signs the same way), that the "
        + "phone's clock was right, what the event means, that the phone was not compromised, that the app that signed "
        + "was the App Store's (the KEYS line names each key's Apple environment, and from iOS 27 its kind of build), or "
        + "that every signature at a counter the phone's count went back over is here: a check sees the counters, not how "
        + "many times each was given out.\n"
        + "Both lists in full: SECURITY.md in Malinois's repository, \"Evidence someone else can check\".\n"

    /// A pass ends in PASS, a blank line, and the approved words: what a check shows and what it cannot.
    func testAPassEndsWithWhatItShowsAndWhatItCannot() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        for target in [folder, try zipped(folder)] {
            let outcome = MalinoisVerifier.run([target.path, "--root", root.path], appIDHash: testAppHash)
            XCTAssertEqual(outcome.status, 0, outcome.text)
            XCTAssertTrue(outcome.text.hasSuffix("\nPASS\n\n" + Self.passWords), outcome.text)
        }
    }

    /// Guard: a check that ends in problems says nothing of what a pass shows.
    func testProblemsSayNothingOfWhatAPassShows() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone, exported: false)
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        XCTAssertFalse(outcome.text.contains("A pass shows:"), outcome.text)
        XCTAssertFalse(outcome.text.contains("It cannot show:"), outcome.text)
    }

    /// Guard: the words follow SECURITY.md's "Evidence someone else can check", which they point to: the section is
    /// there, and its two lists hold what the words name.
    func testThePassWordsFollowTheSectionOfSecurityMDTheyPointTo() throws {
        let source = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MALINOIS_SOURCE"],
                                                        "the source the macOS lane names"))
        let text = try String(contentsOf: source.appendingPathComponent("SECURITY.md"), encoding: .utf8)
        let section = try XCTUnwrap(text.components(separatedBy: "\n## Evidence someone else can check\n").dropFirst().first,
                                    "the section the words name")
        let body = section.components(separatedBy: "\n## ").first ?? section
        func flat(_ part: String) -> String { part.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let shows = flat(try XCTUnwrap(body.components(separatedBy: "A check that passes shows:").dropFirst().first?
            .components(separatedBy: "It cannot show:").first, "what a pass shows"))
        let cannot = flat(try XCTUnwrap(body.components(separatedBy: "It cannot show:").dropFirst().first, "what it cannot"))
        for claim in ["made by a key Apple certified for Malinois", "is byte for byte what was signed",
                      "accounts for every counter of the export's key up to the export"] {
            XCTAssertTrue(shows.contains(claim), claim)
        }
        for limit in ["which iPhone made the ZIP, or whose", "that the phone's clock was right", "what an event means",
                      "that the phone was not compromised", "that the app that signed was the one on the App Store",
                      "that a key which follows an earlier one was made on the same iPhone",
                      "that every signature at a counter the count went back over is in the ZIP"] {
            XCTAssertTrue(cannot.contains(limit), limit)
        }
    }

    /// Item 187's deepseek-9: a ZIP whose index lies at its root (its files zipped without their folder) is named by its
    /// own name in the report's first line, never by the verifier's temporary folder; one that holds the bundle's folder,
    /// as the phone writes it, still by that folder.
    func testAZIPWhoseIndexLiesAtItsRootIsNamedByItsOwnName() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        let zip = base.appendingPathComponent("Malinois evidence at its root.zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", folder.path, zip.path])
        var outcome = MalinoisVerifier.run([zip.path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.hasPrefix("Malinois evidence check of Malinois evidence at its root.zip\n"), outcome.text)
        XCTAssertFalse(outcome.text.contains("malinois-verify-"), outcome.text)
        outcome = MalinoisVerifier.run([try zipped(folder).path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        XCTAssertTrue(outcome.text.hasPrefix("Malinois evidence check of \(folder.lastPathComponent)\n"), outcome.text)
    }

    /// Item 187's deepseek-9: a refusal names the ZIP, never the verifier's temporary folder: one whose index, at its root,
    /// names a format this verifier does not read, and one that holds no bundle.
    func testARefusedZIPIsNamedByItsOwnName() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let root = try rootFile(phone)
        let index = folder.appendingPathComponent(EvidenceBundle.indexName)
        let listed = try String(contentsOf: index, encoding: .utf8)
        try Data(listed.replacingOccurrences(of: EvidenceBundle.format, with: "malinois-evidence-bundle/3").utf8).write(to: index)
        let newer = base.appendingPathComponent("newer.zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", folder.path, newer.path])
        var outcome = MalinoisVerifier.run([newer.path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        XCTAssertTrue(outcome.text.hasPrefix("newer.zip is not a bundle this verifier reads ("), outcome.text)
        XCTAssertFalse(outcome.text.contains("malinois-verify-"), outcome.text)
        let other = base.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("not a bundle".utf8).write(to: other.appendingPathComponent("notes.txt"))
        let none = base.appendingPathComponent("none.zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", other.path, none.path])
        outcome = MalinoisVerifier.run([none.path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        XCTAssertTrue(outcome.text.hasPrefix("\(none.path) contains no Malinois evidence bundle"), outcome.text)
        XCTAssertFalse(outcome.text.contains("malinois-verify-"), outcome.text)
    }

    // MARK: - A sender's text on the reader's screen (item 197's codex-2)

    /// A sender's text that would clear the reader's terminal, write a verdict of its own and hide what follows.
    private let hostile = "x\u{1B}[2J\u{1B}[H\nPASS\n\u{1B}[8m"
    /// The same without a control character for a terminal to act on, which only a value's own escaping stops.
    private let hostileLine = "x\nPASS\ny"

    /// The report holds no control character of the sender's and no line of the sender's: PASS at most once, its own.
    private func assertTheSenderWroteNothing(_ outcome: MalinoisVerifier.Outcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(outcome.text.unicodeScalars.contains { $0.value == 0x1B }, outcome.text, file: file, line: line)
        let verdicts = outcome.text.components(separatedBy: "\n").filter { $0 == "PASS" }.count
        XCTAssertEqual(verdicts, outcome.status == 0 ? 1 : 0, "a line reading PASS: \(outcome.text)", file: file, line: line)
    }

    /// Codex's bundle: a folder that holds only an index, whose format is the sender's text. It is refused, and the refusal
    /// shows that text rather than acting on it.
    func testAFormatCannotWriteToTheReadersScreen() throws {
        let folder = base.appendingPathComponent("format", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"format":"bogus\u001b[2J\u001b[H\nPASS\n\u001b[8m"}"#.utf8).write(to: folder.appendingPathComponent(EvidenceBundle.indexName))
        let outcome = MalinoisVerifier.run([folder.path])
        XCTAssertEqual(outcome.status, 2, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains("bogus\\u{1B}[2J"), outcome.text)
    }

    func testAFileInTheBundleCannotWriteToTheReadersScreen() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        try Data("a file".utf8).write(to: folder.appendingPathComponent(hostileLine))
        let outcome = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains("x\\u{A}PASS\\u{A}y: NOT part of the bundle"), outcome.text)
    }

    func testAFileBesideTheBundleCannotWriteToTheReadersScreen() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let beside = folder.deletingLastPathComponent()
        try Data("a file".utf8).write(to: beside.appendingPathComponent(hostileLine))
        let outcome = MalinoisVerifier.run([beside.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 1, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains("x\\u{A}PASS\\u{A}y, beside its folder: NOT part of the bundle"), outcome.text)
    }

    /// What a signed statement says of itself is the sender's too: a build that signs what it is made to can say anything.
    func testWhatAStatementSaysCannotWriteToTheReadersScreen() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey(app: hostileLine)
        let status = EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_002, app: hostileLine,
                                         facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_001)),
                                                 EvidenceJSON.Member("stateChange", .string(hostileLine))], attachments: [])
        let digest = EvidenceHash.digest(of: photo)
        let shared = EvidenceForm.Record(id: self.shared, revision: 1, signedAt: 1_793_000_000_003, app: hostileLine,
                                         facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                         attachments: [EvidenceForm.Attachment(name: "primary", digest: digest),
                                                       EvidenceForm.Attachment(name: hostileLine, digest: digest)])
        let gone = EvidenceForm.Absent(id: UUID(), revision: 1, startDate: 1_793_000_000_001)
        try phone.sign(.record(status), shown: true)                                                               // 1
        try phone.sign(.record(shared), shown: true)                                                               // 2
        try phone.sign(.record(status), kept: false)                                                               // 3: made, not kept
        try phone.sign(.unkept(EvidenceForm.Unkept(signedAt: 1_793_000_000_005, app: hostileLine, counters: [3...3])), shown: true)   // 4
        try phone.sign(.absence(EvidenceForm.Absence(signedAt: 1_793_000_000_006, app: hostileLine, records: [gone])), shown: true)   // 5
        try phone.sign(.export(EvidenceForm.Export(record: self.shared, revision: 1, signedAt: 1_793_000_009_000, app: hostileLine,
                                                   shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2, 4...5])])), shown: true)
        let outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        assertTheSenderWroteNothing(outcome)
        XCTAssertFalse(outcome.text.contains("Malinois x\n"), outcome.text)
        XCTAssertTrue(outcome.text.contains("status x\\u{A}PASS\\u{A}y, revision 1"), outcome.text)
        XCTAssertTrue(outcome.text.contains("  x\\u{A}PASS\\u{A}y: signed, but not in the bundle"), outcome.text)
    }

    /// An attachment an earlier revision signed and the last does not, and one the last signed with other bytes, each named
    /// under ATTACHMENTS.
    func testAnEarlierRevisionsAttachmentCannotWriteToTheReadersScreen() throws {
        let phone = try TestPhone()
        let key = try phone.certifyKey()
        func revision(_ number: Int64, _ attachments: [EvidenceForm.Attachment]) -> EvidenceForm.Statement {
            .record(EvidenceForm.Record(id: shared, revision: number, signedAt: 1_793_000_000_000 + number, app: "1.11 (83)",
                                        facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))], attachments: attachments))
        }
        let digest = EvidenceHash.digest(of: photo), other = EvidenceHash.digest(of: Data("other bytes".utf8))
        try phone.sign(revision(1, [EvidenceForm.Attachment(name: "primary", digest: digest),
                                    EvidenceForm.Attachment(name: hostileLine, digest: digest)]), shown: true)
        try phone.sign(revision(2, [EvidenceForm.Attachment(name: "primary", digest: digest)]), shown: true)
        try phone.sign(.export(EvidenceForm.Export(record: shared, revision: 2, signedAt: 1_793_000_009_000, app: "1.11 (83)",
                                                   shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: [1...2])])), shown: true)
        var outcome = MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains("  x\\u{A}PASS\\u{A}y: signed in revision 1 but not in the last revision"), outcome.text)

        let changed = try TestPhone()
        let second = try changed.certifyKey()
        let name = hostileLine
        func attached(_ number: Int64, _ bytes: EvidenceForm.Digest) -> EvidenceForm.Statement {
            .record(EvidenceForm.Record(id: shared, revision: number, signedAt: 1_793_000_000_000 + number, app: "1.11 (83)",
                                        facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                        attachments: [EvidenceForm.Attachment(name: name, digest: bytes)]))
        }
        try changed.sign(attached(1, other), shown: true)
        try changed.sign(attached(2, digest), shown: true)
        try changed.sign(.export(EvidenceForm.Export(record: shared, revision: 2, signedAt: 1_793_000_009_000, app: "1.11 (83)",
                                                     shown: [EvidenceForm.KeyCounters(keyID: second.keyID, counters: [1...2])])), shown: true)
        outcome = MalinoisVerifier.run([try written(changed).path, "--root", try rootFile(changed).path], appIDHash: testAppHash)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains("  x\\u{A}PASS\\u{A}y: signed with other bytes in revision 1"), outcome.text)
    }

    /// A name given on the command line is the sender's too when it is the file's own: every way a name reaches the report.
    func testANameCannotWriteToTheReadersScreen() throws {
        var outcome = MalinoisVerifier.run([base.appendingPathComponent(hostileLine).path])
        XCTAssertEqual(outcome.status, 2, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.hasPrefix("There is no file or folder at "), outcome.text)

        let phone = try TestPhone()
        let folder = try bundle(phone)
        outcome = MalinoisVerifier.run([folder.path, "--root", base.appendingPathComponent(hostileLine).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.hasPrefix("No root certificate could be read from "), outcome.text)

        let root = base.appendingPathComponent(hostileLine + ".pem")
        try FileManager.default.copyItem(at: try rootFile(phone), to: root)
        outcome = MalinoisVerifier.run([folder.path, "--root", root.path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains("Checked against the root certificate in "), outcome.text)

        let empty = base.appendingPathComponent(hostileLine, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        outcome = MalinoisVerifier.run([empty.path])
        XCTAssertEqual(outcome.status, 2, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.contains(" contains no Malinois evidence bundle"), outcome.text)

        let named = folder.deletingLastPathComponent().appendingPathComponent(hostileLine, isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: named)
        outcome = MalinoisVerifier.run([named.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 0, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.hasPrefix("Malinois evidence check of x\\u{A}PASS\\u{A}y\n"), outcome.text)
    }

    /// A ZIP that holds no bundle is named by its path, and one the check refuses by its own name.
    func testAZIPsNameCannotWriteToTheReadersScreen() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let index = folder.appendingPathComponent(EvidenceBundle.indexName)
        let listed = try String(contentsOf: index, encoding: .utf8)
        try Data(listed.replacingOccurrences(of: EvidenceBundle.format, with: "malinois-evidence-bundle/3").utf8).write(to: index)
        let zip = base.appendingPathComponent(hostileLine + ".zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", folder.path, zip.path])
        let outcome = MalinoisVerifier.run([zip.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(outcome.status, 2, outcome.text)
        assertTheSenderWroteNothing(outcome)
        XCTAssertTrue(outcome.text.hasPrefix("x\\u{A}PASS\\u{A}y.zip is not a bundle this verifier reads ("), outcome.text)
    }

    /// What is shown, and what is left as it is. A value keeps no line break of its own, and the whole report keeps its own.
    func testAValueShowsItsControlsAsTextAndTheReportKeepsItsLines() {
        XCTAssertEqual(MalinoisVerifier.shown("a\u{1B}[2J\u{7}b\u{7F}c\u{9B}d"), "a\\u{1B}[2J\\u{7}b\\u{7F}c\\u{9B}d", "C0, DEL and C1")
        XCTAssertEqual(MalinoisVerifier.shown("a\nb\r\tc"), "a\\u{A}b\\u{D}\\u{9}c", "line breaks and tabs")
        XCTAssertEqual(MalinoisVerifier.shown("a\u{2028}b\u{2029}c"), "a\\u{2028}b\\u{2029}c", "Unicode's line and paragraph separators")
        XCTAssertEqual(MalinoisVerifier.shown("a\u{202E}b\u{2066}c\u{200F}d"), "a\\u{202E}b\\u{2066}c\\u{200F}d", "text that reorders a line")
        XCTAssertEqual(MalinoisVerifier.shown("Malinois évidence 1.11 (83) \u{2026} ✓"), "Malinois évidence 1.11 (83) \u{2026} ✓", "ordinary text as it is")
        XCTAssertEqual(MalinoisVerifier.displayed("a\nb\u{1B}[2J\n"), "a\nb\\u{1B}[2J\n", "the report's own lines stay")
    }

    /// Each problem's words hold what the bundle said only as text, the build's label too, and so does an error of any
    /// other kind.
    func testAProblemsWordsHoldTheSendersTextOnlyAsText() {
        struct Other: Error, CustomStringConvertible { let description: String }
        let escaped = "x\\u{A}PASS\\u{A}y"
        XCTAssertEqual(MalinoisVerifier.describe(EvidenceProblem.unreadable(hostileLine)), "cannot be read: \(escaped)")
        XCTAssertEqual(MalinoisVerifier.describe(EvidenceProblem.unknownFormat(hostileLine)), "is in another format (\(escaped))")
        XCTAssertEqual(MalinoisVerifier.describe(EvidenceProblem.fileMissing(hostileLine)), "\(escaped) is not in the bundle")
        XCTAssertTrue(MalinoisVerifier.describe(EvidenceProblem.formatNotAsHeld(hostileLine)).hasPrefix("the bundle names the format \(escaped), "))
        XCTAssertEqual(MalinoisVerifier.describe(Other(description: hostileLine) as Error), escaped)
        XCTAssertEqual(MalinoisVerifier.channel(2, hostileLine), "; a TestFlight build, build \(escaped)")
    }

    /// Whatever a value's own escaping misses, the report that leaves `run` holds no control character.
    func testNoControlLeavesInAnyReport() throws {
        let phone = try TestPhone()
        let folder = try bundle(phone)
        let pass = MalinoisVerifier.run([folder.path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
        XCTAssertEqual(pass.status, 0, pass.text)
        XCTAssertEqual(MalinoisVerifier.displayed(pass.text), pass.text, "a whole bundle's report is as it was")
        for report in [pass.text, MalinoisVerifier.usage, MalinoisVerifier.passWords] {
            XCTAssertFalse(report.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x0A }, report)
        }
        let raw = MalinoisVerifier.run([]) { _, _ in MalinoisVerifier.Outcome(text: "a\u{1B}[2J\n", status: 1) }
        XCTAssertEqual(raw, MalinoisVerifier.Outcome(text: "a\\u{1B}[2J\n", status: 1), "text a value's own escaping missed")
    }

    // MARK: - Helpers

    private var testAppHash: Data { TestApp.sha256(Data(TestApp.id.utf8)) }

    /// The verifier's folders for an unpacked ZIP, in the temporary folder.
    private func unpackedFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("malinois-verify-") }.sorted()
    }

    /// A bundle as the phone writes it, in a folder named as Share names it: one key; the shared record's revision with
    /// its photo; a status record; the export statement, unless not `exported`. `losing` a counter: its signature left
    /// out, as one lost.
    private func bundle(_ phone: TestPhone, statements given: [EvidenceForm.Statement]? = nil,
                        alsoSigned: [(EvidenceForm.Statement, UInt32)] = [], losing: UInt32? = nil, exported: Bool = true) throws -> URL {
        try phone.certifyKey()
        var statements = given ?? [
            revision(1),
            .record(EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_002, app: "1.10 (81)",
                                        facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_001))], attachments: [])),
        ]
        if given == nil, exported {
            // Naming what the bundle shows, as the phone's export does: every statement signed and kept before it.
            let key = try XCTUnwrap(phone.keys.last)
            let kept = (1...UInt32(statements.count)).filter { $0 != losing }
            statements.append(export(1, shown: [EvidenceForm.KeyCounters(keyID: key.keyID, counters: EvidenceForm.counterRanges(kept))]))
        }
        for (offset, statement) in statements.enumerated() {
            try phone.sign(statement, shown: true, kept: UInt32(offset + 1) != losing)
        }
        // A statement signed under a counter of the test's choosing, after the first line.
        for (statement, counter) in alsoSigned {
            let key = try XCTUnwrap(phone.keys.last)
            let bytes = EvidenceForm.bytes(statement)
            let assertion = try TestAttestation.assertion(by: key.key, formHash: TestApp.sha256(bytes), counter: counter)
            phone.signatures.insert(EvidenceBundle.Signature(key: key.keyID, assertion: assertion, statement: bytes, shown: true), at: 1)
        }
        let contents = EvidenceBundle.Contents(record: shared, keys: phone.bundleKeys, signatures: phone.signatures, notes: [],
                                               attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                       source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-10-31 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        return folder
    }

    /// The shared record's revision `number`, its photo attached.
    private func revision(_ number: Int64) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: shared, revision: number, signedAt: 1_793_000_000_000 + number, app: "1.10 (81)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_000))],
                                    attachments: [EvidenceForm.Attachment(name: "primary", digest: EvidenceHash.digest(of: photo))]))
    }

    private func export(_ number: Int64, shown: [EvidenceForm.KeyCounters] = []) -> EvidenceForm.Statement {
        .export(EvidenceForm.Export(record: shared, revision: number, signedAt: 1_793_000_009_000, app: "1.10 (81)", shown: shown))
    }

    /// A bundle of `phone`'s signatures as they stand, with the photo attached, in a folder of its own.
    private func written(_ phone: TestPhone, keys: [EvidenceBundle.Key]? = nil,
                         signatures: [EvidenceBundle.Signature]? = nil) throws -> URL {
        let contents = EvidenceBundle.Contents(record: shared, keys: keys ?? phone.bundleKeys, signatures: signatures ?? phone.signatures,
                                               notes: [], attachments: [EvidenceBundle.Attachment(name: "primary", file: "primary.jpg",
                                                                                                  source: .bytes(photo))])
        let folder = base.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Malinois evidence 2026-10-31 0100", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EvidenceBundle.write(contents, to: folder)
        return folder
    }

    private func short(_ keyID: Data) -> String { String(EvidenceHash.hex(keyID).prefix(8)) + "…" }

    /// `phone`'s bundle as it stands, checked against its chain's root.
    private func checked(_ phone: TestPhone) throws -> MalinoisVerifier.Outcome {
        MalinoisVerifier.run([try written(phone).path, "--root", try rootFile(phone).path], appIDHash: testAppHash)
    }

    /// A statement of a record other than the one shared.
    private func otherRecord(_ number: Int64) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: UUID(), revision: 1, signedAt: 1_793_000_000_100 + number, app: "1.10 (81)",
                                    facts: [EvidenceJSON.Member("startDate", .int(1_793_000_000_100 + number))], attachments: []))
    }

    /// The words under COUNTERS for a key's repeat (item 206, the owner: "wording approved").
    private func repeatNote(_ keyID: Data, at counters: String) -> String {
        "key \(short(keyID)): two signatures each at \(counters): the phone's count went back, as after a forced restart. At these "
            + "counters a statement taken out, or cut down to its fingerprint, leaves no gap, even one the export names or one saying a "
            + "record left the phone's log"
    }

    /// The words under THE EXPORT for a fingerprint beside a statement shown in full at a counter it names (item 206).
    private func secondSignature(at places: String) -> String {
        "at \(places) a second signature is only a fingerprint, and the export does not say which of the two it names"
    }

    /// The test chain's root, as a reader would pass Apple's: a PEM file.
    private func rootFile(_ phone: TestPhone) throws -> URL {
        let file = base.appendingPathComponent("root-\(UUID().uuidString).pem")
        let body = phone.chain.rootDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        try Data("-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n".utf8).write(to: file)
        return file
    }

    /// `folder` zipped beside it, its name the ZIP's one folder, as iOS zips a bundle for Share (`ditto`, with no "._"
    /// entries: the Air's ZIPs hold none), or with `zip` keeping links as links.
    private func zipped(_ folder: URL, keepingLinks: Bool = false) throws -> URL {
        let zip = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent).zip")
        if keepingLinks {
            try runTool("/usr/bin/zip", ["-q", "-r", "-y", zip.path, folder.lastPathComponent], in: folder.deletingLastPathComponent())
        } else {
            try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", folder.path, zip.path])
        }
        return zip
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

    /// Writes the bundle's folder (the first argument) as a ZIP (the second), its folder at the root, with a decoy entry
    /// before the real files under the path the third argument names in the bundle.
    private static let zipWithADecoy = """
        import os, sys, zipfile
        folder, out, decoy = sys.argv[1], sys.argv[2], sys.argv[3]
        name = os.path.basename(folder)
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr(name + "/" + decoy, b"a decoy the check never saw")
            for here, _, files in os.walk(folder):
                for file in sorted(files):
                    path = os.path.join(here, file)
                    archive.write(path, os.path.join(name, os.path.relpath(path, folder)))
        """

    /// As `zipWithADecoy`, then the decoy hidden as the fourth argument says (Codex's codex-1 on fde1689):
    /// "named-as-a-folder" changes the last letter of its name in the ZIP's index to "/", its own header unchanged;
    /// "left-out-of-the-index" drops it from the index, its bytes left in place; "called-a-folder" (item 187's round D)
    /// gives it a folder's attributes in the index, its name and bytes unchanged.
    private static let zipWithAHiddenEntry = """
        import os, struct, sys, zipfile
        folder, out, decoy, how = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
        name = os.path.basename(folder)
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr(name + "/" + decoy, b"a decoy the check never saw")
            for here, folders, files in os.walk(folder):
                folders.sort()
                for file in sorted(files):
                    path = os.path.join(here, file)
                    archive.write(path, os.path.join(name, os.path.relpath(path, folder)))
        if how == "named-as-a-folder":
            data = bytearray(open(out, "rb").read())
            end = data.rfind(b"PK\\x05\\x06")
            start, = struct.unpack("<I", data[end + 16:end + 20])
            length, = struct.unpack("<H", data[start + 28:start + 30])
            data[start + 46 + length - 1] = ord("/")
            open(out, "wb").write(data)
        elif how == "left-out-of-the-index":
            archive = zipfile.ZipFile(out, "a")
            archive.filelist.remove(archive.filelist[0])
            archive._didModify = True
            archive.close()
        elif how == "called-a-folder":
            data = bytearray(open(out, "rb").read())
            end = data.rfind(b"PK\\x05\\x06")
            start, = struct.unpack("<I", data[end + 16:end + 20])
            data[start + 38:start + 42] = struct.pack("<I", 0o40755 << 16)
            open(out, "wb").write(data)
        else:
            sys.exit("unknown: " + how)
        """

    /// Writes the bundle's folder (the first argument) as a ZIP (the second), its folder at the root, every file stored,
    /// by hand, but for its key statement and attestation (Codex's codex-3 on c68e3ec): each holds the other's bytes under
    /// its own name, and its own header gives it the other's name in a Unicode Path field (0x7075), so `bsdtar` unpacks
    /// the genuine bundle while the index and readers that go by it pair each name with the other file's bytes.
    private static let zipWithSecondNames = """
        import os, struct, sys, zlib
        folder, out = sys.argv[1], sys.argv[2]
        files = {}
        for here, folders, names in os.walk(folder):
            folders.sort()
            for name in sorted(names):
                path = os.path.join(here, name)
                files[os.path.relpath(path, os.path.dirname(folder))] = open(path, "rb").read()
        statement = next(name for name in sorted(files) if "/keys/" in name and name.endswith(".json"))
        attestation = statement[:-4] + "cbor"
        other = {statement: attestation, attestation: statement}
        def upath(raw, new):
            body = struct.pack("<BI", 1, zlib.crc32(raw.encode())) + new.encode()
            return struct.pack("<HH", 0x7075, len(body)) + body
        data, listed = bytearray(), bytearray()
        for name in sorted(files):
            payload = files[other.get(name, name)]
            extra = upath(name, other[name]) if name in other else b""
            n, crc, offset = name.encode(), zlib.crc32(payload), len(data)
            data += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0x21, crc, len(payload), len(payload), len(n),
                                len(extra)) + n + extra + payload
            listed += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 0x031E, 20, 0, 0, 0, 0x21, crc, len(payload),
                                  len(payload), len(n), 0, 0, 0, 0, 0o100644 << 16, offset) + n
        start = len(data)
        data += listed + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(files), len(files), len(listed), start, 0)
        open(out, "wb").write(bytes(data))
        """

    /// Writes the bundle's folder (the first argument) into the folder the second names as ZIPs, its folder at the root.
    /// Four plain ones: plain.zip as Python's zipfile writes it, deflated-after.zip as it writes one to a stream (each
    /// file's sizes after its data), descriptor-unsigned.zip (the same, each data descriptor's signature left out) and
    /// stored-empty-after.zip (an empty stored file, its sizes after it). Then, from them, one for each way out of one
    /// plain run of files: bytes before or after it (leading, trailing); a split or ZIP64 end record (split-disk,
    /// split-index-disk, split-entries, zip64-count, zip64-index-size, zip64-index-offset); an index not right before its
    /// end record (index-gap) or over 16 MiB (index-too-large); an index that is not one list of files (index-count-high,
    /// index-signature, index-disk, index-name-long, index-padding); two archives in one (two-archives: a copy with the
    /// photo's bytes zeroed first, the real archive's index moved past it, Codex's codex-1 on 3096c70); an encrypted,
    /// ZIP64 or bzip2 file (encrypted, zip64-size, zip64-compressed, bzip2); a stored file whose sizes come after its data
    /// (stored-after); a file's own header other than its index entry (local-signature, flags-differ, method-differs,
    /// names-swapped: its key statement's and attestation's names swapped in the index) or with a name past the end
    /// (local-name-long); its sizes other than the index's (sizes-differ, zero-sizes, after-local-sizes); bytes between
    /// the files and the index (between-files-and-index); a data descriptor other than the index's (descriptor-differs);
    /// and a ZIP cut short in its end record (truncated). Written by hand (item 187's round E): unix-extras (the extended
    /// timestamp and Unix owner fields the phone's ZIPs carry) and comment-text (an ordinary comment), both plain; a
    /// comment that holds the end record's signature (comment-sig, comment-sig-24) or a whole end record of its own
    /// (comment-fake-end); a file named anew by the Unicode Path field in its header or in the index (unicode-path,
    /// unicode-path-index: Codex's codex-3 on c68e3ec); extra fields that are not one list (extra-not-a-list,
    /// extra-past-its-end) or that run past the index (index-extra-long); a stored file whose sizes come after its data
    /// and claim bytes it does not hold or hold bytes it does not claim (stored-zero-after, stored-after-short), or whose
    /// two sizes differ (stored-short: DeepSeek's deepseek-1); a folder's entry that holds bytes, stored or compressed,
    /// in either size (folder-with-bytes, folder-deflated, folder-sized); and a compressed file whose stream ends before
    /// the size it is given (deflate-early: deepseek-2).
    private static let zipLayouts = """
        import io, os, struct, sys, zipfile, zlib
        folder, outdir = sys.argv[1], sys.argv[2]
        class Stream:
            def __init__(self, f):
                self.f = f
            def write(self, data):
                return self.f.write(data)
            def flush(self):
                pass
        def plain(replace=None, streamed=False):
            buffer = io.BytesIO()
            method = zipfile.ZIP_DEFLATED if streamed else zipfile.ZIP_STORED
            with zipfile.ZipFile(Stream(buffer) if streamed else buffer, "w", method) as archive:
                for here, folders, files in os.walk(folder):
                    folders.sort()
                    for file in sorted(files):
                        path = os.path.join(here, file)
                        name = os.path.relpath(path, os.path.dirname(folder))
                        data = open(path, "rb").read()
                        archive.writestr(name, bytes(len(data)) if replace and name.endswith(replace) else data)
            return bytearray(buffer.getvalue())
        def index(data):
            end = data.rfind(b"PK\\x05\\x06")
            start, = struct.unpack_from("<I", data, end + 16)
            found, cursor = [], start
            while data[cursor:cursor + 4] == b"PK\\x01\\x02":
                n, e, c = struct.unpack_from("<HHH", data, cursor + 28)
                found.append((cursor, bytes(data[cursor + 46:cursor + 46 + n])))
                cursor += 46 + n + e + c
            return end, start, found
        def u(data, form, at):
            return struct.unpack_from(form, data, at)[0]
        def changed(data, *changes):
            out = bytearray(data)
            for at, form, value in changes:
                struct.pack_into(form, out, at, value)
            return out
        def write(name, data):
            open(os.path.join(outdir, name), "wb").write(bytes(data))
        def streamed(name, data):
            buffer = io.BytesIO()
            with zipfile.ZipFile(Stream(buffer), "w") as archive:
                archive.writestr(name, data)
            return buffer.getvalue()
        base = plain()
        end, start, found = index(base)
        first, last, count = found[0][0], found[-1][0], len(found)
        crc, flags = u(base, "<I", first + 16), u(base, "<H", first + 8)
        write("plain.zip", base)
        write("leading.zip", b"junk" + base)
        write("trailing.zip", base + b"junk")
        write("split-disk.zip", changed(base, (end + 4, "<H", 1)))
        write("split-index-disk.zip", changed(base, (end + 6, "<H", 1)))
        write("split-entries.zip", changed(base, (end + 8, "<H", count - 1)))
        write("zip64-count.zip", changed(base, (end + 8, "<H", 0xFFFF), (end + 10, "<H", 0xFFFF)))
        write("zip64-index-size.zip", changed(base, (end + 12, "<I", 0xFFFFFFFF)))
        write("zip64-index-offset.zip", changed(base, (end + 16, "<I", 0xFFFFFFFF)))
        write("index-gap.zip", base[:end] + b"junk" + base[end:])
        write("index-too-large.zip", bytes(17 << 20) + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, 17 << 20, 0, 0))
        write("index-count-high.zip", changed(base, (end + 8, "<H", count + 1), (end + 10, "<H", count + 1)))
        write("index-signature.zip", changed(base, (first, "<I", 0x03014B50)))
        write("index-disk.zip", changed(base, (first + 34, "<H", 1)))
        write("index-name-long.zip", changed(base, (last + 28, "<H", u(base, "<H", last + 28) + 100)))
        write("index-padding.zip", changed(base[:end] + b"junk" + base[end:], (end + 4 + 12, "<I", end - start + 4)))
        front, back = plain(replace="attachments/primary.jpg"), bytearray(base)
        for cursor, _ in found:
            struct.pack_into("<I", back, cursor + 42, u(back, "<I", cursor + 42) + len(front))
        struct.pack_into("<I", back, end + 16, start + len(front))
        write("two-archives.zip", front + back)
        write("encrypted.zip", changed(base, (6, "<H", flags | 1), (first + 8, "<H", flags | 1)))
        write("bzip2.zip", changed(base, (8, "<H", 12), (first + 10, "<H", 12)))
        write("zip64-size.zip", changed(base, (22, "<I", 0xFFFFFFFF), (first + 24, "<I", 0xFFFFFFFF)))
        write("zip64-compressed.zip", changed(base, (18, "<I", 0xFFFFFFFF), (first + 20, "<I", 0xFFFFFFFF)))
        write("stored-after.zip", streamed("bundle/a.txt", b"stored bytes"))
        write("stored-empty-after.zip", streamed("bundle/empty.txt", b""))
        write("local-signature.zip", changed(base, (0, "<I", 0x05034B50)))
        write("flags-differ.zip", changed(base, (first + 8, "<H", flags | 0x0800)))
        write("method-differs.zip", changed(base, (first + 10, "<H", 8)))
        swapped = bytearray(base)
        json = next(entry for entry in found if entry[1].endswith(b".json") and b"/keys/" in entry[1])
        cbor = next(entry for entry in found if entry[1] == json[1][:-4] + b"cbor")
        swapped[json[0] + 46:json[0] + 46 + len(json[1])] = cbor[1]
        swapped[cbor[0] + 46:cbor[0] + 46 + len(cbor[1])] = json[1]
        write("names-swapped.zip", swapped)
        write("local-name-long.zip", changed(base, (u(base, "<I", last + 42) + 26, "<H", 0xFFFF)))
        write("sizes-differ.zip", changed(base, (first + 16, "<I", crc ^ 1)))
        write("zero-sizes.zip", changed(base, (14, "<I", 0), (18, "<I", 0), (22, "<I", 0)))
        write("between-files-and-index.zip", changed(base[:start] + b"junk" + base[start:], (end + 4 + 16, "<I", start + 4)))
        write("truncated.zip", base[:-10])
        after = plain(streamed=True)
        write("deflated-after.zip", after)
        write("after-local-sizes.zip", changed(after, (14, "<I", 1)))
        end, start, found = index(after)
        descriptor = 30 + u(after, "<H", 26) + u(after, "<H", 28) + u(after, "<I", found[0][0] + 20)
        write("descriptor-differs.zip", changed(after, (descriptor + 4, "<I", u(after, "<I", descriptor + 4) ^ 1)))
        cuts = []
        for cursor, _ in found:
            local = u(after, "<I", cursor + 42)
            at = local + 30 + u(after, "<H", local + 26) + u(after, "<H", local + 28) + u(after, "<I", cursor + 20)
            if after[at:at + 4] == b"PK\\x07\\x08":
                cuts.append(at)
        def moved(position):
            return position - 4 * sum(1 for at in cuts if at < position)
        unsigned, cursor = bytearray(), 0
        for at in cuts:
            unsigned += after[cursor:at]
            cursor = at + 4
        unsigned += after[cursor:]
        struct.pack_into("<I", unsigned, moved(end) + 16, moved(start))
        for central, _ in found:
            struct.pack_into("<I", unsigned, moved(central) + 42, moved(u(after, "<I", central + 42)))
        write("descriptor-unsigned.zip", unsigned)
        def by_hand(entries, comment=b""):
            out, listed = bytearray(), bytearray()
            for name, flags, method, crc, compressed, size, payload, local_extra, index_extra, descriptor in entries:
                n, offset = name.encode(), len(out)
                sizes = (0, 0, 0) if flags & 8 else (crc, compressed, size)
                out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, 0, 0x21, *sizes, len(n), len(local_extra))
                out += n + local_extra + payload + descriptor
                mode = 0o40755 if name.endswith("/") else 0o100644
                listed += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 0x031E, 20, flags, method, 0, 0x21, crc, compressed,
                                      size, len(n), len(index_extra), 0, 0, 0, mode << 16, offset) + n + index_extra
            start = len(out)
            out += listed + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(listed), start,
                                        len(comment)) + comment
            return out
        def stored(name, data, local_extra=b"", index_extra=b""):
            return (name, 0, 0, zlib.crc32(data), len(data), len(data), data, local_extra, index_extra, b"")
        def upath(raw, new):
            body = struct.pack("<BI", 1, zlib.crc32(raw.encode())) + new.encode()
            return struct.pack("<HH", 0x7075, len(body)) + body
        top = os.path.basename(folder)
        first, second = top + "/a.txt", top + "/b.txt"
        owner = struct.pack("<HHBI", 0x5455, 5, 1, 1700000000) + struct.pack("<HHBBIBI", 0x7875, 11, 1, 4, 501, 4, 20)
        write("unix-extras.zip", by_hand([stored(first, b"first", owner, owner), stored(second, b"second", owner, owner)]))
        def commented(comment):
            return base[:-2] + struct.pack("<H", len(comment)) + comment
        signature = struct.pack("<I", 0x06054B50)
        write("comment-text.zip", commented(b"an ordinary comment"))
        write("comment-sig.zip", commented(signature))
        write("comment-sig-24.zip", commented(b"a comment ending in:" + signature))
        write("comment-fake-end.zip", commented(signature + bytes(18)))
        write("unicode-path.zip", by_hand([stored(first, b"first", upath(first, second)),
                                           stored(second, b"second", upath(second, first))]))
        write("unicode-path-index.zip", by_hand([stored(first, b"first", b"", upath(first, second)),
                                                 stored(second, b"second", b"", upath(second, first))]))
        write("extra-not-a-list.zip", by_hand([stored(first, b"first", b"UT\\x05")]))
        write("extra-past-its-end.zip", by_hand([stored(first, b"first", struct.pack("<HHB", 0x5455, 9, 1))]))
        zeros = bytes(20)
        write("stored-zero-after.zip", by_hand([(first, 8, 0, zlib.crc32(zeros), 0, 20, b"", b"", b"",
                                                 struct.pack("<IIII", 0x08074B50, zlib.crc32(zeros), 0, 20))]))
        hundred = b"x" * 100
        write("stored-short.zip", by_hand([(first, 0, 0, zlib.crc32(hundred), 5, 100, hundred[:5], b"", b"", b"")]))
        write("folder-with-bytes.zip", by_hand([stored(top + "/x/", b"hidden"), stored(first, b"first")]))
        write("index-extra-long.zip", changed(base, (last + 30, "<H", u(base, "<H", last + 30) + 100)))
        write("stored-after-short.zip", by_hand([(first, 8, 0, 0, 5, 0, b"bytes", b"", b"",
                                                  struct.pack("<IIII", 0x08074B50, 0, 5, 0))]))
        empty = zlib.compressobj(9, zlib.DEFLATED, -15).flush()
        write("folder-deflated.zip", by_hand([(top + "/x/", 0, 8, 0, len(empty), 0, empty, b"", b"", b"")]))
        write("folder-sized.zip", by_hand([(top + "/x/", 0, 8, 0, 0, 6, b"", b"", b"", b"")]))
        text = b"the file's real bytes"
        packer = zlib.compressobj(9, zlib.DEFLATED, -15)
        early = packer.compress(text) + packer.flush() + bytes(40)
        write("deflate-early.zip", by_hand([(first, 0, 8, zlib.crc32(text), len(early), len(text), early, b"", b"", b"")]))
        """

    private func runTool(_ path: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)")
    }
}
#endif
