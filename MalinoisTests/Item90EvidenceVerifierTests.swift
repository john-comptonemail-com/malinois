//
//  Item90EvidenceVerifierTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 1: the verifier's rules, on keys certified by test chains made at run time. Apple's chain is
//  judged at the moment the key was certified (its certificate lives three days, Phase 0), so an export checked years
//  later still checks out; each part of a certification must name the same key, app and statement; a signature must be
//  the key's over the statement's hash; and a key's counters account for every signature, a gap being retired (a
//  retention statement names it) or missing (a fact, never an accusation). Phase 4: only the key's own retention
//  statement, or that of a key that follows it after a restore, retires its counters. Written before the code, red at
//  that commit (against compile-only stubs).
//

import CryptoKit
import Security
import XCTest
@testable import Malinois

final class Item90EvidenceVerifierTests: XCTestCase {

    private let certifiedAt = TestApp.date(2026, 10, 31, 0, 54)
    private let recordID = UUID(uuidString: "0D7E4B1A-2C3F-4A5B-8C9D-0E1F2A3B4C5D") ?? UUID()

    // MARK: - The test chain itself

    func testTheTestChainIsOneTheSecurityFrameworkTrusts() throws {
        let chain = try TestAttestationChain()
        let key = P256.Signing.PrivateKey()
        let leaf = try chain.leaf(for: key.publicKey, nonce: Data(repeating: 1, count: 32), certifiedAt: certifiedAt)
        XCTAssertTrue(trusts([leaf, chain.intermediateDER], root: chain.rootDER, at: certifiedAt))
        XCTAssertFalse(trusts([leaf, chain.intermediateDER], root: chain.rootDER, at: certifiedAt.addingTimeInterval(3 * 86_400)),
                       "after the key's certificate expired")
        XCTAssertFalse(trusts([leaf, chain.intermediateDER], root: try TestAttestationChain().rootDER, at: certifiedAt), "another root")
    }

    // MARK: - Certifying a key

    /// Phase 5 (the owner's ruling of 2026-10-31, "1 - a"): the Mac verifier knows Malinois's key by the SHA-256 of its App
    /// ID, which every attestation already carries, so the published source never holds the team ID. Given the hash, a
    /// certification checks out as given the App ID; another app's hash, or the App ID where its hash belongs, is refused.
    func testAKeyIsCertifiedForTheAppIDsHashAsForTheAppID() throws {
        let chain = try TestAttestationChain()
        let made = try chain.certify(at: certifiedAt)
        let byID = try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                                roots: [chain.rootDER])
        let byHash = try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement,
                                                  appIDHash: TestApp.sha256(Data(TestApp.id.utf8)), roots: [chain.rootDER])
        XCTAssertEqual(byHash, byID)
        assertProblem(.otherApp, "another app's hash") {
            try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement,
                                         appIDHash: TestApp.sha256(Data("OTHERTEAM0.com.example.other".utf8)), roots: [chain.rootDER])
        }
        assertProblem(.otherApp, "the App ID where its hash belongs") {
            try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement,
                                         appIDHash: Data(TestApp.id.utf8), roots: [chain.rootDER])
        }
    }

    func testAKeyCertifiedByTheChainChecksOut() throws {
        let chain = try TestAttestationChain()
        let made = try chain.certify(at: certifiedAt)
        let key = try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                               roots: [chain.rootDER])
        XCTAssertEqual(key.keyID, made.keyID)
        XCTAssertEqual(key.publicKey, made.key.publicKey.x963Representation)
        XCTAssertEqual(key.appIDHash, TestApp.sha256(Data(TestApp.id.utf8)))
        XCTAssertEqual(key.environment, .development)
        XCTAssertEqual(key.certificateLife, certifiedAt.addingTimeInterval(-86_400)...certifiedAt.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(key.judgedAt, certifiedAt, "a third of the way into a life from a day before to two days after")
        XCTAssertEqual(key.category, 3)
        XCTAssertEqual(key.bundleVersion, "81")
        XCTAssertEqual(key.statement, EvidenceForm.KeyStatement(keyID: made.keyID, signedAt: 1_793_000_000_000, app: "1.10 (81)", follows: nil))
        var production = TestAttestationShape()
        production.environment = TestApp.production
        production.extensions = nil
        let released = try chain.certify(at: certifiedAt, shape: production)
        let releasedKey = try EvidenceVerifier.certify(attestation: released.attestation, statement: released.statement,
                                                       appID: TestApp.id, roots: [chain.rootDER])
        XCTAssertEqual(releasedKey.environment, .production)
        XCTAssertNil(releasedKey.category, "an iOS older than 27 names no channel")
        XCTAssertNil(releasedKey.bundleVersion)
    }

    func testTheChainIsJudgedWhenTheKeyWasCertifiedNotToday() throws {
        // An intermediate that expired at the start of 2021, and a key certified in 2020: the chain held then.
        let chain = try TestAttestationChain(intermediateLife: TestApp.date(2020, 1, 1)...TestApp.date(2021, 1, 1))
        let then = TestApp.date(2020, 6, 1, 12, 30)
        let made = try chain.certify(at: then)
        let key = try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                               roots: [chain.rootDER])
        XCTAssertEqual(key.judgedAt, then)
        // A key certified after the intermediate expired: the chain did not hold then.
        let late = try chain.certify(at: TestApp.date(2022, 6, 1))
        assertProblem(.chainNotTrusted, "certified after the intermediate expired") {
            try EvidenceVerifier.certify(attestation: late.attestation, statement: late.statement, appID: TestApp.id, roots: [chain.rootDER])
        }
    }

    func testAChainToAnotherRootIsNotTrusted() throws {
        let chain = try TestAttestationChain()
        let made = try chain.certify(at: certifiedAt)
        for (why, roots) in [("another root", [try TestAttestationChain().rootDER]), ("no root", [Data]())] {
            assertProblem(.chainNotTrusted, why) {
                try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id, roots: roots)
            }
        }
    }

    func testEveryCertificateGivenMustBeOne() throws {
        let chain = try TestAttestationChain()
        let made = try chain.certify(at: certifiedAt)
        assertProblem(.chainNotTrusted, "a root that is not a certificate, beside the right one") {
            try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                         roots: [Data([1, 2, 3]), chain.rootDER])
        }
        var extra = TestAttestationShape()
        extra.extraCertificates = [.bytes(Data([1, 2, 3]))]
        let padded = try chain.certify(at: certifiedAt, shape: extra)
        assertProblem(.chainNotTrusted, "an entry after the intermediate that is not a certificate") {
            try EvidenceVerifier.certify(attestation: padded.attestation, statement: padded.statement, appID: TestApp.id,
                                         roots: [chain.rootDER])
        }
    }

    func testTheAttestationsKeyMustBeTheCertificatesKey() throws {
        let chain = try TestAttestationChain()
        let other = P256.Signing.PrivateKey().publicKey.x963Representation
        func cose(kty: UInt64 = 2, alg: UInt64 = 6, crv: UInt64 = 1, point: Data? = nil) -> (Data) -> EvidenceCBOR {
            { own in
                let xy = point ?? own
                return .map([EvidenceCBOR.Pair(key: .unsigned(1), value: .unsigned(kty)),
                             EvidenceCBOR.Pair(key: .unsigned(3), value: .negative(alg)),
                             EvidenceCBOR.Pair(key: .negative(0), value: .unsigned(crv)),
                             EvidenceCBOR.Pair(key: .negative(1), value: .bytes(xy.subdata(in: 1..<33))),
                             EvidenceCBOR.Pair(key: .negative(2), value: .bytes(xy.subdata(in: 33..<65)))])
            }
        }
        var same = TestAttestationShape()
        same.coseKey = cose()
        let control = try chain.certify(at: certifiedAt, shape: same)
        XCTAssertNoThrow(try EvidenceVerifier.certify(attestation: control.attestation, statement: control.statement, appID: TestApp.id,
                                                      roots: [chain.rootDER]), "the key written out as the support writes it")
        for (why, key) in [("another key's point", cose(point: other)), ("another key type", cose(kty: 1)),
                           ("another algorithm", cose(alg: 7)), ("another curve", cose(crv: 2))] {
            var shape = TestAttestationShape()
            shape.coseKey = key
            let made = try chain.certify(at: certifiedAt, shape: shape)
            assertProblem(.keyMismatch, why) {
                try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                             roots: [chain.rootDER])
            }
        }
    }

    func testEachPartOfACertificationMustNameTheSameKeyAppAndStatement() throws {
        let chain = try TestAttestationChain()
        var otherFormat = TestAttestationShape()
        otherFormat.format = "packed"
        var otherStatement = TestAttestationShape()
        otherStatement.certifiedStatement = Data("another statement".utf8)
        var otherCredential = TestAttestationShape()
        otherCredential.credentialID = Data(repeating: 0x42, count: 32)
        var otherApp = TestAttestationShape()
        otherApp.appID = "OTHERTEAM0.com.example.other"
        var counted = TestAttestationShape()
        counted.counter = 1
        var unknownEnvironment = TestAttestationShape()
        unknownEnvironment.environment = Data(repeating: 0x41, count: 16)
        let cases: [(String, TestAttestationShape, EvidenceProblem)] = [
            ("not App Attest's format", otherFormat, .notAppAttest),
            ("Apple's certificate covers another statement", otherStatement, .notForThisStatement),
            ("a credential for another key", otherCredential, .keyMismatch),
            ("another app's key", otherApp, .otherApp),
            ("a counter above zero", counted, .counterNotZero),
            ("an environment Apple does not name", unknownEnvironment, .unknownEnvironment),
        ]
        for (why, shape, problem) in cases {
            let made = try chain.certify(at: certifiedAt, shape: shape)
            assertProblem(problem, why) {
                try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id, roots: [chain.rootDER])
            }
        }
        let statements: [(String, (Data) -> Data, EvidenceProblem)] = [
            ("a statement for another key", { _ in TestApp.keyStatement(keyID: Data(repeating: 0x42, count: 32)) }, .keyMismatch),
            ("a statement that is not a key's", { _ in
                Data((#"{"format":"malinois-evidence/1","type":"retention","signedAt":1,"app":"1.10 (81)","retired":"#
                      + #"[{"key":"\#(String(repeating: "42", count: 32))","counters":[[1,2]]}]}"#).utf8)
            }, .notForThisStatement),
            ("a statement not in the fixed form", { TestApp.keyStatement(keyID: $0) + Data(" ".utf8) }, .formNotFixed),
            ("a statement in a newer format", {
                Data(TestApp.text(TestApp.keyStatement(keyID: $0))
                    .replacingOccurrences(of: "malinois-evidence/1", with: "malinois-evidence/2").utf8)
            }, .unknownFormat("malinois-evidence/2")),
        ]
        for (why, statement, problem) in statements {
            let made = try chain.certify(at: certifiedAt, statement: statement)
            assertProblem(problem, why) {
                try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id, roots: [chain.rootDER])
            }
        }
    }

    func testAnUnreadableAttestationIsSaidToBe() throws {
        let chain = try TestAttestationChain()
        let made = try chain.certify(at: certifiedAt)
        XCTAssertNoThrow(try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                                      roots: [chain.rootDER]), "the attestation the others are not")
        let noChain = TestCBOR.encode(TestCBOR.map([("fmt", .text("apple-appattest")),
                                                    ("attStmt", TestCBOR.map([("x5c", .array([])), ("receipt", .bytes(Data()))])),
                                                    ("authData", .bytes(Data(repeating: 0, count: 37)))]))
        let notDER = TestCBOR.encode(TestCBOR.map([("fmt", .text("apple-appattest")),
                                                   ("attStmt", TestCBOR.map([("x5c", .array([.bytes(Data([1, 2, 3]))])), ("receipt", .bytes(Data()))])),
                                                   ("authData", .bytes(Data(repeating: 0, count: 37)))]))
        // A real attestation with one entry taken out, so nothing else stops it first.
        func without(_ name: String) throws -> Data {
            guard case .map(let pairs) = try EvidenceCBOR.decode(made.attestation) else { return Data() }
            return TestCBOR.encode(.map(pairs.filter { $0.key != .text(name) }))
        }
        let noFormat = try without("fmt")
        let noAuthData = try without("authData")
        let textLeaf = TestCBOR.encode(TestCBOR.map([("fmt", .text("apple-appattest")),
                                                     ("attStmt", TestCBOR.map([("x5c", .array([.text("a certificate")]))])),
                                                     ("authData", .bytes(Data(repeating: 0, count: 37)))]))
        var textIntermediate = TestAttestationShape()
        textIntermediate.extraCertificates = [.text("another certificate")]
        var noLife = TestAttestationShape()
        noLife.life = certifiedAt...certifiedAt
        let shaped = [("an entry after the intermediate that is not bytes", textIntermediate),
                      ("a certificate whose life ends where it starts", noLife)].map { ($0.0, try? chain.certify(at: certifiedAt, shape: $0.1)) }
        for (why, made) in shaped {
            guard let made else { return XCTFail("\(why): not made") }
            XCTAssertThrowsError(try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                                              roots: [chain.rootDER]), why) {
                XCTAssertTrue(Item90EvidenceDecodingTests.isUnreadable($0), "\(why): \($0)")
            }
        }
        for (why, attestation) in [("not CBOR", Data([0xFF, 0x00])), ("no certificates", noChain), ("a certificate that is not DER", notDER),
                                   ("no format", noFormat), ("no authenticator data", noAuthData), ("a certificate that is not bytes", textLeaf)] {
            XCTAssertThrowsError(try EvidenceVerifier.certify(attestation: attestation, statement: made.statement, appID: TestApp.id,
                                                              roots: [chain.rootDER]), why) {
                XCTAssertTrue(Item90EvidenceDecodingTests.isUnreadable($0), "\(why): \($0)")
            }
        }
    }

    // MARK: - Checking a signature

    func testASignatureChecksOutAndReadsItsStatement() throws {
        let (made, key) = try certifiedKey()
        let form = recordForm(revision: 1)
        let hash = TestApp.sha256(form)
        let entry = try EvidenceVerifier.check(assertion: TestAttestation.assertion(by: made.key, formHash: hash, counter: 1),
                                               formHash: hash, form: form, under: key)
        XCTAssertEqual(entry.keyID, made.keyID)
        XCTAssertEqual(entry.counter, 1)
        XCTAssertEqual(entry.formHash, hash)
        XCTAssertEqual(entry.category, 3)
        XCTAssertEqual(entry.bundleVersion, "81")
        guard case .record(let record)? = entry.statement else { return XCTFail("no record: \(String(describing: entry.statement))") }
        XCTAssertEqual(record.id, recordID)
        XCTAssertEqual(record.revision, 1)
        // Another record's signature, carried by its hash alone.
        let bare = try EvidenceVerifier.check(assertion: TestAttestation.assertion(by: made.key, formHash: hash, counter: 2),
                                              formHash: hash, form: nil, under: key)
        XCTAssertEqual(bare.counter, 2)
        XCTAssertNil(bare.statement)
        // An older iOS's signature: no channel, no version.
        let older = try EvidenceVerifier.check(
            assertion: TestAttestation.assertion(by: made.key, formHash: hash, counter: 3, flags: 0x40, extensions: nil),
            formHash: hash, form: form, under: key)
        XCTAssertEqual(older.counter, 3)
        XCTAssertNil(older.category)
        XCTAssertNil(older.bundleVersion)
    }

    func testAStatementThatIsNotWhatWasSignedIsNamed() throws {
        let (made, key) = try certifiedKey()
        let form = recordForm(revision: 1)
        let hash = TestApp.sha256(form)
        let assertion = try TestAttestation.assertion(by: made.key, formHash: hash, counter: 1)
        assertProblem(.formHashMismatch, "another revision's bytes") {
            try EvidenceVerifier.check(assertion: assertion, formHash: hash, form: self.recordForm(revision: 2), under: key)
        }
        // Signed, but not in the fixed form: no genuine Malinois writes it, and no verifier reads it.
        let loose = form + Data(" ".utf8)
        let looseHash = TestApp.sha256(loose)
        assertProblem(.formNotFixed, "a statement not in the fixed form") {
            try EvidenceVerifier.check(assertion: TestAttestation.assertion(by: made.key, formHash: looseHash, counter: 2),
                                       formHash: looseHash, form: loose, under: key)
        }
    }

    func testASignatureByAnotherKeyOrOverOtherBytesFails() throws {
        let (made, key) = try certifiedKey()
        let hash = TestApp.sha256(recordForm(revision: 1))
        let parts = try TestAttestation.assertionParts(by: made.key, formHash: hash, counter: 5)
        var recounted = parts.authData
        recounted[36] = 4
        var garbled = parts.signature
        garbled[garbled.count - 1] ^= 0x01
        let cases: [(String, Data, Data)] = [
            ("another key's signature", try TestAttestation.assertion(by: P256.Signing.PrivateKey(), formHash: hash, counter: 5), hash),
            ("the counter changed after signing", TestAttestation.assertion(signature: parts.signature, authData: recounted), hash),
            ("a signature over another hash", TestAttestation.assertion(signature: parts.signature, authData: parts.authData),
             TestApp.sha256(Data("other".utf8))),
            ("a changed signature", TestAttestation.assertion(signature: garbled, authData: parts.authData), hash),
            ("a signature that is not DER", TestAttestation.assertion(signature: Data([1, 2, 3]), authData: parts.authData), hash),
        ]
        for (why, assertion, formHash) in cases {
            assertProblem(.signatureMismatch, why) {
                try EvidenceVerifier.check(assertion: assertion, formHash: formHash, form: nil, under: key)
            }
        }
        let pointless = EvidenceCertifiedKey(keyID: key.keyID, publicKey: Data(repeating: 0, count: 65), appIDHash: key.appIDHash,
                                             environment: key.environment, certificateLife: key.certificateLife, judgedAt: key.judgedAt,
                                             category: key.category, bundleVersion: key.bundleVersion, statement: key.statement)
        assertProblem(.signatureMismatch, "a key that is not a point") {
            try EvidenceVerifier.check(assertion: TestAttestation.assertion(signature: parts.signature, authData: parts.authData),
                                       formHash: hash, form: nil, under: pointless)
        }
        assertProblem(.otherApp, "a signature for another app") {
            try EvidenceVerifier.check(assertion: TestAttestation.assertion(by: made.key, formHash: hash, counter: 6, appID: "OTHER.app"),
                                       formHash: hash, form: nil, under: key)
        }
    }

    func testAnUnreadableSignatureIsSaidToBe() throws {
        let (made, key) = try certifiedKey()
        let hash = TestApp.sha256(recordForm(revision: 1))
        let good = try TestAttestation.assertion(by: made.key, formHash: hash, counter: 1)
        XCTAssertNoThrow(try EvidenceVerifier.check(assertion: good, formHash: hash, form: nil, under: key), "the signature the others are not")
        let cases: [(String, Data, Data)] = [
            ("not CBOR", Data([0xFF]), hash),
            ("no signature", TestCBOR.encode(TestCBOR.map([("authenticatorData", .bytes(Data(repeating: 0, count: 37)))])), hash),
            ("no authenticator data", TestCBOR.encode(TestCBOR.map([("signature", .bytes(Data([0x30, 0x00])))])), hash),
            ("authenticator data cut short", TestAttestation.assertion(signature: Data([0x30, 0x00]), authData: Data(repeating: 0, count: 36)), hash),
            ("a hash of 31 bytes", good, Data(repeating: 1, count: 31)),
        ]
        for (why, assertion, formHash) in cases {
            XCTAssertThrowsError(try EvidenceVerifier.check(assertion: assertion, formHash: formHash, form: nil, under: key), why) {
                XCTAssertTrue(Item90EvidenceDecodingTests.isUnreadable($0), "\(why): \($0)")
            }
        }
    }

    // MARK: - The sequence

    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    func testAnUnbrokenSequenceHasNoGaps() {
        let report = EvidenceVerifier.sequence(of: (1...10).map { entry($0) }, keyID: keyA, followers: [])
        XCTAssertEqual(report.counters, Array(1...10))
        XCTAssertEqual(report.retired, [])
        XCTAssertEqual(report.missing, [])
        XCTAssertEqual(EvidenceVerifier.sequence(of: [], keyID: keyA, followers: []).counters, [])
    }

    func testAGapIsRetiredWhenARetentionStatementNamesItAndMissingOtherwise() {
        let retiring = entry(7, statement: retention([(keyA, [3...4])]))
        let accounted = EvidenceVerifier.sequence(of: [1, 2, 5, 6].map { entry($0) } + [retiring], keyID: keyA, followers: [])
        XCTAssertEqual(accounted.counters, [1, 2, 5, 6, 7])
        XCTAssertEqual(accounted.retired, [3...4])
        XCTAssertEqual(accounted.missing, [])
        let unaccounted = EvidenceVerifier.sequence(of: [1, 2, 5, 6].map { entry($0) }, keyID: keyA, followers: [])
        XCTAssertEqual(unaccounted.retired, [])
        XCTAssertEqual(unaccounted.missing, [3...4])
        let oldEnd = EvidenceVerifier.sequence(of: [3, 4, 5].map { entry($0) }, keyID: keyA, followers: [])
        XCTAssertEqual(oldEnd.missing, [1...2], "counters before the first here count from 1")
        let partly = EvidenceVerifier.sequence(of: [1, 2, 7].map { entry($0) } + [entry(8, statement: retention([(keyA, [4...5])]))], keyID: keyA, followers: [])
        XCTAssertEqual(partly.retired, [4...5])
        XCTAssertEqual(partly.missing, [3...3, 6...6])
    }

    func testARetentionStatementAccountsOnlyForWhatCameBeforeIt() {
        // Key A's statement at counter 3 names 2 to 6: it can retire 2, signed before it, but not 4 to 6, signed after.
        let own = EvidenceVerifier.sequence(of: [entry(1), entry(3, statement: retention([(keyA, [2...6])])), entry(7)], keyID: keyA, followers: [])
        XCTAssertEqual(own.retired, [2...2])
        XCTAssertEqual(own.missing, [4...6])
        // A key that follows it (after a restore) retires the old key's counters, whatever its own counter.
        let entries = [entry(1), entry(2), entry(5), entry(1, key: keyB, statement: retention([(keyA, [3...4])]))]
        let restored = EvidenceVerifier.sequence(of: entries, keyID: keyA, followers: [keyB])
        XCTAssertEqual(restored.counters, [1, 2, 5], "key B's own signature is not in key A's sequence")
        XCTAssertEqual(restored.repeated, [], "nor does it share a counter with key A's")
        XCTAssertEqual(restored.retired, [3...4])
        XCTAssertEqual(restored.missing, [])
        // A key that does not follow it retires none of them (phase 4's rule, 2026-10-31).
        let unrelated = EvidenceVerifier.sequence(of: entries, keyID: keyA, followers: [])
        XCTAssertEqual(unrelated.retired, [])
        XCTAssertEqual(unrelated.missing, [3...4])
    }

    func testTheKeysThatFollowAKeyAreThoseAfterItsRestoresNeverItself() {
        let keyC = Data(repeating: 0xC3, count: 32), keyD = Data(repeating: 0xD4, count: 32), keyE = Data(repeating: 0xE5, count: 32)
        let statements = [keyStatement(keyA, follows: nil), keyStatement(keyB, follows: keyA), keyStatement(keyC, follows: keyB),
                          keyStatement(keyD, follows: nil), keyStatement(keyE, follows: keyE)]
        XCTAssertEqual(EvidenceVerifier.followers(of: keyA, among: statements), [keyB, keyC], "B follows A, and C follows B")
        XCTAssertEqual(EvidenceVerifier.followers(of: keyB, among: statements), [keyC])
        XCTAssertEqual(EvidenceVerifier.followers(of: keyC, among: statements), [])
        XCTAssertEqual(EvidenceVerifier.followers(of: keyD, among: statements), [])
        XCTAssertEqual(EvidenceVerifier.followers(of: keyE, among: statements), [], "a key never follows itself")
        // Two keys naming each other (no phone writes it): each follows the other, neither itself, and the search ends.
        let loop = [keyStatement(keyA, follows: keyB), keyStatement(keyB, follows: keyA)]
        XCTAssertEqual(EvidenceVerifier.followers(of: keyA, among: loop), [keyB])
    }

    func testRetirementsThatOverlapOrComeOutOfOrderJoin() {
        let overlapping = EvidenceVerifier.sequence(of: [entry(1), entry(2), entry(7), entry(8, statement: retention([(keyA, [3...5])])),
                                                         entry(9, statement: retention([(keyA, [4...6])]))], keyID: keyA, followers: [])
        XCTAssertEqual(overlapping.retired, [3...6])
        XCTAssertEqual(overlapping.missing, [])
        let reversed = EvidenceVerifier.sequence(of: [entry(1), entry(2), entry(7), entry(8, statement: retention([(keyA, [5...6])])),
                                                      entry(9, statement: retention([(keyA, [3...4])]))], keyID: keyA, followers: [])
        XCTAssertEqual(reversed.retired, [3...6])
    }

    func testRepeatedAndReSignedStatementsAreNamed() {
        let same = TestApp.sha256(Data("one statement".utf8))
        let report = EvidenceVerifier.sequence(of: [entry(1), entry(2, hash: same), entry(3), entry(3), entry(4),
                                                    entry(4, hash: TestApp.sha256(Data("another".utf8))), entry(5, hash: same)],
                                               keyID: keyA, followers: [])
        XCTAssertEqual(report.counters, [1, 2, 3, 4, 5])
        XCTAssertEqual(report.repeated, [4], "counter 3 is one signature listed twice; counter 4 carries two statements")
        XCTAssertEqual(report.signedAgain, [5])
    }

    func testEachRecordsRevisionsRiseWithTheirCountersAndAreAllHere() {
        let x = UUID(uuidString: "00000000-0000-4000-8000-00000000000A") ?? UUID()
        let y = UUID(uuidString: "00000000-0000-4000-8000-00000000000B") ?? UUID()
        let z = UUID(uuidString: "00000000-0000-4000-8000-00000000000C") ?? UUID()
        let entries = [
            entry(1, statement: record(y, 1)), entry(2, statement: record(z, 1)), entry(3, statement: record(x, 2)),
            entry(4, statement: record(y, 3)), entry(5, statement: record(x, 1)), entry(6, statement: record(z, 1)),
        ]
        let report = EvidenceVerifier.sequence(of: entries, keyID: keyA, followers: [])
        XCTAssertEqual(report.revisionsOutOfOrder, [x, z].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(report.missingRevisions, [EvidenceSequence.MissingRevisions(id: y, revisions: [2])])
        // One signature listed twice is one signature: its record's revisions are not out of order.
        let w = UUID(uuidString: "00000000-0000-4000-8000-00000000000D") ?? UUID()
        let twice = EvidenceVerifier.sequence(of: [entry(1, statement: record(w, 1)), entry(1, statement: record(w, 1))], keyID: keyA, followers: [])
        XCTAssertEqual(twice.revisionsOutOfOrder, [])
        // A revision number no phone reaches lists its missing predecessors only up to the verifier's limit.
        let far = EvidenceVerifier.sequence(of: [entry(1, statement: record(w, 1_000_000))], keyID: keyA, followers: [])
        XCTAssertEqual(far.missingRevisions.first?.revisions.count, 9_999)
        XCTAssertEqual(far.missingRevisions.first?.revisions.last, 9_999)
    }

    // MARK: - Helpers

    private func certifiedKey() throws -> (TestCertifiedKey, EvidenceCertifiedKey) {
        let chain = try TestAttestationChain()
        let made = try chain.certify(at: certifiedAt)
        let key = try EvidenceVerifier.certify(attestation: made.attestation, statement: made.statement, appID: TestApp.id,
                                               roots: [chain.rootDER])
        return (made, key)
    }

    /// A record's statement written out by hand, so these tests do not lean on the form's writer.
    private func recordForm(revision: Int) -> Data {
        Data((#"{"format":"malinois-evidence/1","type":"record","id":"\#(recordID.uuidString)","revision":\#(revision),"#
              + #""signedAt":1793000006000,"app":"1.10 (81)","facts":{},"attachments":[]}"#).utf8)
    }

    private func entry(_ counter: UInt32, key: Data? = nil, hash: Data? = nil, statement: EvidenceForm.Statement? = nil) -> EvidenceSignedEntry {
        let keyID = key ?? keyA
        return EvidenceSignedEntry(keyID: keyID, counter: counter,
                                   formHash: hash ?? TestApp.sha256(Data("\(TestApp.hex(keyID))-\(counter)".utf8)),
                                   category: nil, bundleVersion: nil, statement: statement)
    }

    private func retention(_ retired: [(Data, [ClosedRange<UInt32>])]) -> EvidenceForm.Statement {
        .retention(EvidenceForm.Retention(signedAt: 1, app: "1.10 (81)", retired: retired.map { EvidenceForm.Retired(keyID: $0.0, counters: $0.1) }))
    }

    private func record(_ id: UUID, _ revision: Int64) -> EvidenceForm.Statement {
        .record(EvidenceForm.Record(id: id, revision: revision, signedAt: 1, app: "1.10 (81)", facts: [], attachments: []))
    }

    private func keyStatement(_ keyID: Data, follows: Data?) -> EvidenceForm.KeyStatement {
        EvidenceForm.KeyStatement(keyID: keyID, signedAt: 1, app: "1.10 (81)", follows: follows)
    }

    private func trusts(_ chain: [Data], root: Data, at moment: Date) -> Bool {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard certificates.count == chain.count, let anchor = SecCertificateCreateWithData(nil, root as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, moment as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private func assertProblem(_ problem: EvidenceProblem, _ why: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Any) {
        XCTAssertThrowsError(try body(), why, file: file, line: line) {
            XCTAssertEqual($0 as? EvidenceProblem, problem, why, file: file, line: line)
        }
    }
}
