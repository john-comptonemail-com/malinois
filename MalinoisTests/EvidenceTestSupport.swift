//
//  EvidenceTestSupport.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 1: what the evidence tests make for themselves, without the code they test (only its value
//  types). A CBOR writer, a DER writer, and certificate chains made at run time with CryptoKit keys, in the shape of
//  Apple's App Attest chain (a P-384 root and intermediate; the key's P-256 certificate, signed with SHA-256, valid from
//  a day before its certification to two days after, carrying the nonce in Apple's extension). Apple's real certificate
//  from the Air names the developer's team ID, which stays out of the repository, so the chain rules are checked on
//  these instead. The keys exist only while a test runs.
//

import CryptoKit
import DeviceCheck
import Foundation
import Security
@testable import Malinois

/// CBOR as App Attest writes it: definite lengths, each in its shortest form.
enum TestCBOR {
    static func encode(_ value: EvidenceCBOR) -> Data {
        switch value {
        case .unsigned(let n): return head(0, n)
        case .negative(let n): return head(1, n)
        case .bytes(let data): return head(2, UInt64(data.count)) + data
        case .text(let text): return head(3, UInt64(text.utf8.count)) + Data(text.utf8)
        case .array(let items): return items.reduce(head(4, UInt64(items.count))) { $0 + encode($1) }
        case .map(let pairs): return pairs.reduce(head(5, UInt64(pairs.count))) { $0 + encode($1.key) + encode($1.value) }
        case .simple(let code): return code < 24 ? Data([0xE0 | code]) : Data([0xF8, code])
        }
    }

    static func head(_ major: UInt8, _ n: UInt64) -> Data {
        let type = major << 5
        switch n {
        case ..<24: return Data([type | UInt8(n)])
        case ..<0x100: return Data([type | 24, UInt8(n)])
        case ..<0x1_0000: return Data([type | 25]) + bigEndian(n, 2)
        case ..<0x1_0000_0000: return Data([type | 26]) + bigEndian(n, 4)
        default: return Data([type | 27]) + bigEndian(n, 8)
        }
    }

    static func bigEndian(_ n: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: n >> (8 * UInt64($0))) })
    }

    /// A map with text keys, in the order given.
    static func map(_ entries: [(String, EvidenceCBOR)]) -> EvidenceCBOR {
        .map(entries.map { EvidenceCBOR.Pair(key: .text($0.0), value: $0.1) })
    }

    /// Apple's two iOS 27 extensions as the Air wrote them: the category as four bytes, little-endian.
    static func iOS27Extensions(category: UInt32 = 3, bundleVersion: String = "81") -> EvidenceCBOR {
        let le = Data((0..<4).map { UInt8(truncatingIfNeeded: category >> (8 * UInt32($0))) })
        return map([("apple_bundle_version_01", .text(bundleVersion)), ("apple_validation_category_01", .bytes(le))])
    }
}

/// DER, for the certificates these tests make.
enum TestDER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }

    static func length(_ n: Int) -> Data {
        guard n >= 0x80 else { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var rest = n
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ parts: [Data]) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: [Data]) -> Data { tlv(0x31, parts.reduce(Data(), +)) }

    /// A non-negative INTEGER, minimal.
    static func integer(_ n: UInt64) -> Data {
        var bytes = Array(TestCBOR.bigEndian(n, 8).drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func oid(_ arcs: [UInt64]) -> Data {
        var body = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            body += chunk
        }
        return tlv(0x06, Data(body))
    }

    static func utf8String(_ text: String) -> Data { tlv(0x0C, Data(text.utf8)) }
    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }
    static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data { tlv(0x03, Data([unusedBits]) + data) }
    static func boolean(_ value: Bool) -> Data { tlv(0x01, Data([value ? 0xFF : 0x00])) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }

    /// UTCTime (YYMMDDHHMMSSZ) for 1950 to 2049 and GeneralizedTime (YYYYMMDDHHMMSSZ) for other years, as X.509 requires.
    static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 0
        let generalized = !(1_950...2_049).contains(year)
        let digits = generalized ? String(format: "%04d", year) : String(format: "%02d", year % 100)
        let text = digits + String(format: "%02d%02d%02d%02d%02dZ", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
                                    parts.minute ?? 0, parts.second ?? 0)
        return tlv(generalized ? 0x18 : 0x17, Data(text.utf8))
    }
}

/// The object identifiers these certificates use.
enum TestOID {
    static let ecPublicKey: [UInt64] = [1, 2, 840, 10_045, 2, 1]
    static let p256: [UInt64] = [1, 2, 840, 10_045, 3, 1, 7]
    static let p384: [UInt64] = [1, 3, 132, 0, 34]
    static let ecdsaSHA256: [UInt64] = [1, 2, 840, 10_045, 4, 3, 2]
    static let ecdsaSHA384: [UInt64] = [1, 2, 840, 10_045, 4, 3, 3]
    static let commonName: [UInt64] = [2, 5, 4, 3]
    static let basicConstraints: [UInt64] = [2, 5, 29, 19]
    static let keyUsage: [UInt64] = [2, 5, 29, 15]
    static let subjectKeyID: [UInt64] = [2, 5, 29, 14]
    static let authorityKeyID: [UInt64] = [2, 5, 29, 35]
    static let appAttestNonce: [UInt64] = [1, 2, 840, 113_635, 100, 8, 2]
}

/// Dates and names the tests share.
enum TestApp {
    static let id = "TESTTEAM00.com.example.malinois-tests"
    static let development = Data("appattestdevelop".utf8)
    static let production = Data("appattest".utf8) + Data(repeating: 0, count: 7)

    /// A UTC time, to the second.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    /// Bytes as UTF-8 text, for comparing a statement with its expected spelling.
    static func text(_ data: Data) -> String { String(bytes: data, encoding: .utf8) ?? "(not UTF-8)" }

    /// A key statement in the fixed form, written out by hand so the verifier's tests do not lean on the form's writer.
    static func keyStatement(keyID: Data, signedAt: Int64 = 1_793_000_000_000, app: String = "1.10 (81)") -> Data {
        Data(#"{"format":"malinois-evidence/1","type":"key","key":"\#(hex(keyID))","signedAt":\#(signedAt),"app":"\#(app)","follows":null}"#.utf8)
    }
}

/// A chain in the shape of Apple's App Attest chain, made with keys that exist only for one test.
struct TestAttestationChain {
    let root = P384.Signing.PrivateKey()
    let intermediate = P384.Signing.PrivateKey()
    let rootDER: Data
    let intermediateDER: Data
    private let rootName = TestAttestationChain.name("Malinois Test Attestation Root")
    private let intermediateName = TestAttestationChain.name("Malinois Test Attestation CA 1")

    init(rootLife: ClosedRange<Date> = TestApp.date(2020, 1, 1)...TestApp.date(2045, 1, 1),
         intermediateLife: ClosedRange<Date> = TestApp.date(2020, 1, 1)...TestApp.date(2040, 1, 1)) throws {
        let root = self.root, intermediate = self.intermediate
        rootDER = try Self.certificate(
            serial: 1, issuer: rootName, subject: rootName, life: rootLife,
            keyInfo: Self.keyInfo(root.publicKey.x963Representation, curve: TestOID.p384),
            extensions: Self.authorityExtensions(subjectKey: root.publicKey.x963Representation, issuerKey: nil),
            algorithm: TestOID.ecdsaSHA384) { try root.signature(for: $0).derRepresentation }
        intermediateDER = try Self.certificate(
            serial: 2, issuer: rootName, subject: intermediateName, life: intermediateLife,
            keyInfo: Self.keyInfo(intermediate.publicKey.x963Representation, curve: TestOID.p384),
            extensions: Self.authorityExtensions(subjectKey: intermediate.publicKey.x963Representation,
                                                 issuerKey: root.publicKey.x963Representation),
            algorithm: TestOID.ecdsaSHA384) { try root.signature(for: $0).derRepresentation }
    }

    /// The certificate for `key` carrying `nonce`, as Apple writes a key's: valid from a day before `certifiedAt` to
    /// two days after, unless `life` says otherwise.
    func leaf(for key: P256.Signing.PublicKey, nonce: Data, certifiedAt: Date, life: ClosedRange<Date>? = nil,
              nonceExtension: Data? = nil) throws -> Data {
        let day: TimeInterval = 86_400
        let window = life ?? certifiedAt.addingTimeInterval(-day)...certifiedAt.addingTimeInterval(2 * day)
        let nonceValue = nonceExtension ?? TestDER.sequence([TestDER.explicit(1, TestDER.octetString(nonce))])
        let extensions = [
            Self.extensionDER(TestOID.basicConstraints, critical: true, TestDER.sequence([])),
            Self.extensionDER(TestOID.keyUsage, critical: true, TestDER.bitString(Data([0x80]), unusedBits: 7)),
            Self.extensionDER(TestOID.appAttestNonce, critical: false, nonceValue),
        ]
        let intermediate = self.intermediate
        return try Self.certificate(
            serial: 3, issuer: intermediateName, subject: Self.name(TestApp.hex(TestApp.sha256(key.x963Representation))),
            life: window, keyInfo: Self.keyInfo(key.x963Representation, curve: TestOID.p256), extensions: extensions,
            algorithm: TestOID.ecdsaSHA256) { try intermediate.signature(for: SHA256.hash(data: $0)).derRepresentation }
    }

    static func name(_ commonName: String) -> Data {
        TestDER.sequence([TestDER.set([TestDER.sequence([TestDER.oid(TestOID.commonName), TestDER.utf8String(commonName)])])])
    }

    static func keyInfo(_ point: Data, curve: [UInt64]) -> Data {
        TestDER.sequence([TestDER.sequence([TestDER.oid(TestOID.ecPublicKey), TestDER.oid(curve)]), TestDER.bitString(point)])
    }

    static func extensionDER(_ oid: [UInt64], critical: Bool, _ value: Data) -> Data {
        let parts = critical ? [TestDER.oid(oid), TestDER.boolean(true), TestDER.octetString(value)]
                             : [TestDER.oid(oid), TestDER.octetString(value)]
        return TestDER.sequence(parts)
    }

    private static func authorityExtensions(subjectKey: Data, issuerKey: Data?) -> [Data] {
        let keyID = { (key: Data) in Data(Insecure.SHA1.hash(data: key)) }
        var extensions = [
            extensionDER(TestOID.basicConstraints, critical: true, TestDER.sequence([TestDER.boolean(true)])),
            extensionDER(TestOID.keyUsage, critical: true, TestDER.bitString(Data([0x06]), unusedBits: 1)),
            extensionDER(TestOID.subjectKeyID, critical: false, TestDER.octetString(keyID(subjectKey))),
        ]
        if let issuerKey {
            extensions.append(extensionDER(TestOID.authorityKeyID, critical: false,
                                           TestDER.sequence([TestDER.tlv(0x80, keyID(issuerKey))])))
        }
        return extensions
    }

    private static func certificate(serial: UInt64, issuer: Data, subject: Data, life: ClosedRange<Date>, keyInfo: Data,
                                    extensions: [Data], algorithm: [UInt64], sign: (Data) throws -> Data) throws -> Data {
        let algorithmID = TestDER.sequence([TestDER.oid(algorithm)])
        let tbs = TestDER.sequence([
            TestDER.explicit(0, TestDER.integer(2)),
            TestDER.integer(serial),
            algorithmID,
            issuer,
            TestDER.sequence([TestDER.time(life.lowerBound), TestDER.time(life.upperBound)]),
            subject,
            keyInfo,
            TestDER.explicit(3, TestDER.sequence(extensions)),
        ])
        return TestDER.sequence([tbs, algorithmID, TestDER.bitString(try sign(tbs))])
    }
}

/// A key certified end to end by a test chain: the attestation and the statement it covers.
struct TestCertifiedKey {
    let key: P256.Signing.PrivateKey
    let keyID: Data
    let statement: Data
    let attestation: Data
}

/// What a test may change in an attestation, one thing at a time.
struct TestAttestationShape {
    var appID = TestApp.id
    /// The App ID's hash, when not `appID`'s: Malinois's own, for the verifier run as a program (item 187).
    var appIDHash: Data?
    var environment = TestApp.development
    var counter: UInt32 = 0
    var credentialID: Data?
    var extensions: EvidenceCBOR? = TestCBOR.iOS27Extensions()
    var format = "apple-appattest"
    /// The statement Apple's certificate covers, when not the one given with the attestation.
    var certifiedStatement: Data?
    var life: ClosedRange<Date>?
    /// The key as COSE, from the certified key's point, when not the key itself.
    var coseKey: ((Data) -> EvidenceCBOR)?
    /// Entries after the intermediate in the certificate list.
    var extraCertificates: [EvidenceCBOR] = []
}

extension TestAttestationChain {
    /// A new key, certified by this chain at `certifiedAt` for the statement `statement(keyID)` builds.
    func certify(at certifiedAt: Date, shape: TestAttestationShape = TestAttestationShape(),
                 statement: (Data) -> Data = { TestApp.keyStatement(keyID: $0) }) throws -> TestCertifiedKey {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        let keyID = TestApp.sha256(point)
        let statementBytes = statement(keyID)
        let authData = TestAttestation.authenticatorData(shape: shape, keyID: shape.credentialID ?? keyID, point: point)
        let nonce = TestApp.sha256(authData + TestApp.sha256(shape.certifiedStatement ?? statementBytes))
        let leafDER = try leaf(for: key.publicKey, nonce: nonce, certifiedAt: certifiedAt, life: shape.life)
        let object = TestCBOR.map([
            ("fmt", .text(shape.format)),
            ("attStmt", TestCBOR.map([("x5c", .array([.bytes(leafDER), .bytes(intermediateDER)] + shape.extraCertificates)),
                                      ("receipt", .bytes(Data()))])),
            ("authData", .bytes(authData)),
        ])
        return TestCertifiedKey(key: key, keyID: keyID, statement: statementBytes, attestation: TestCBOR.encode(object))
    }
}

/// App Attest's authenticator data and signatures, as these tests make them.
enum TestAttestation {
    /// An attestation's: the App ID's hash, the flags (credential, and extensions when there are any), the counter, the
    /// environment, the credential ID and the key as COSE, then the extensions.
    static func authenticatorData(shape: TestAttestationShape, keyID: Data, point: Data) -> Data {
        var data = shape.appIDHash ?? TestApp.sha256(Data(shape.appID.utf8))
        data.append(shape.extensions == nil ? 0x40 : 0xC0)
        data += TestCBOR.bigEndian(UInt64(shape.counter), 4)
        data += shape.environment
        data += TestCBOR.bigEndian(UInt64(keyID.count), 2) + keyID
        data += TestCBOR.encode(shape.coseKey?(point) ?? coseKey(point))
        if let extensions = shape.extensions { data += TestCBOR.encode(extensions) }
        return data
    }

    /// A P-256 key as COSE writes it: kty 2 (EC2), alg -7 (ES256), crv 1 (P-256), x, y.
    static func coseKey(_ point: Data) -> EvidenceCBOR {
        .map([
            EvidenceCBOR.Pair(key: .unsigned(1), value: .unsigned(2)),
            EvidenceCBOR.Pair(key: .unsigned(3), value: .negative(6)),
            EvidenceCBOR.Pair(key: .negative(0), value: .unsigned(1)),
            EvidenceCBOR.Pair(key: .negative(1), value: .bytes(point.subdata(in: 1..<33))),
            EvidenceCBOR.Pair(key: .negative(2), value: .bytes(point.subdata(in: 33..<65))),
        ])
    }

    /// A signature by `key` over `formHash`, as App Attest returns one: the iOS 27 shape by default (the credential
    /// and extensions flags, Apple's two extensions); `flags: 0x40, extensions: nil` for an older iOS's.
    static func assertion(by key: P256.Signing.PrivateKey, formHash: Data, counter: UInt32, appID: String = TestApp.id,
                          appIDHash: Data? = nil, flags: UInt8 = 0xC0,
                          extensions: EvidenceCBOR? = TestCBOR.iOS27Extensions()) throws -> Data {
        let parts = try assertionParts(by: key, formHash: formHash, counter: counter, appID: appID, appIDHash: appIDHash,
                                       flags: flags, extensions: extensions)
        return assertion(signature: parts.signature, authData: parts.authData)
    }

    /// A signature's two parts, for a test that changes one of them after signing.
    static func assertionParts(by key: P256.Signing.PrivateKey, formHash: Data, counter: UInt32, appID: String = TestApp.id,
                               appIDHash: Data? = nil, flags: UInt8 = 0xC0,
                               extensions: EvidenceCBOR? = TestCBOR.iOS27Extensions())
        throws -> (signature: Data, authData: Data) {
        var authData = appIDHash ?? TestApp.sha256(Data(appID.utf8))
        authData.append(flags)
        authData += TestCBOR.bigEndian(UInt64(counter), 4)
        if let extensions { authData += TestCBOR.encode(extensions) }
        let nonce = TestApp.sha256(authData + formHash)
        return (try key.signature(for: nonce).derRepresentation, authData)
    }

    /// The assertion object App Attest returns, from its two parts.
    static func assertion(signature: Data, authData: Data) -> Data {
        TestCBOR.encode(TestCBOR.map([("signature", .bytes(signature)), ("authenticatorData", .bytes(authData))]))
    }
}

extension TestAttestationChain {
    /// Apple's attestation object for `key`, certified at `certifiedAt` for `clientDataHash` (the key statement's
    /// SHA-256), as App Attest's attestKey returns it.
    func attestation(for key: P256.Signing.PrivateKey, clientDataHash: Data, certifiedAt: Date,
                     shape: TestAttestationShape = TestAttestationShape()) throws -> Data {
        let point = key.publicKey.x963Representation
        let authData = TestAttestation.authenticatorData(shape: shape, keyID: TestApp.sha256(point), point: point)
        let leafDER = try leaf(for: key.publicKey, nonce: TestApp.sha256(authData + clientDataHash), certifiedAt: certifiedAt)
        return TestCBOR.encode(TestCBOR.map([
            ("fmt", .text("apple-appattest")),
            ("attStmt", TestCBOR.map([("x5c", .array([.bytes(leafDER), .bytes(intermediateDER)])), ("receipt", .bytes(Data()))])),
            ("authData", .bytes(authData)),
        ]))
    }
}

// The app's tests only: the evidence core's macOS run (run-core-macos.zsh) builds the core alone, without the app's
// EvidenceKeyService, which this stand-in plays.
#if canImport(UIKit)
/// App Attest stood in for a test (BACKLOG item 90, phase 2): keys made with CryptoKit, certified by a test chain in
/// Apple's format, each signing with a counter that rises from 1, as the Air's did. It answers as App Attest does: a key
/// signs only once certified, and a key it has lost is invalid. What it was asked is kept for the test to read.
actor FakeKeyService: EvidenceKeyService {
    nonisolated let isSupported: Bool
    let chain: TestAttestationChain
    let certifiedAt: Date
    private var keys: [String: P256.Signing.PrivateKey] = [:]
    private var counters: [String: UInt32] = [:]
    private var certified: Set<String> = []
    private var lost: Set<String> = []
    private var attestFailures: [any Error] = []
    private var assertionFailures: [any Error] = []
    /// Each certification asked for, in order: the key and the hash.
    private(set) var attestRequests: [(key: String, hash: Data)] = []
    /// How many keys were made.
    private(set) var keysMade = 0
    /// How many keys were asked for, made or not.
    private(set) var keyRequests = 0
    /// How many signatures were asked for.
    private(set) var assertionRequests = 0
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var holdNextSignature = false
    private var heldSignature: CheckedContinuation<Void, Never>?

    init(supported: Bool = true, chain: TestAttestationChain, certifiedAt: Date = TestApp.date(2026, 10, 31, 1, 0),
         attestFailures: [any Error] = []) {
        isSupported = supported
        self.chain = chain
        self.certifiedAt = certifiedAt
        self.attestFailures = attestFailures
    }

    /// The next certifications fail with these, in order.
    func failNextAttestations(_ errors: [any Error]) { attestFailures = errors }
    /// The next signatures fail with these, in order.
    func failNextAssertions(_ errors: [any Error]) { assertionFailures = errors }
    /// App Attest no longer has `keyID` (a restore from a backup).
    func lose(_ keyID: String) { lost.insert(keyID) }
    /// The next certification, once asked for (in `attestRequests`), waits for `releaseHeldAttestation()`.
    func holdNextAttestation() { holdNext = true }
    func releaseHeldAttestation() {
        held?.resume()
        held = nil
    }
    /// The next signature, once asked for (in `assertionRequests`), waits for `releaseHeldAssertion()`.
    func holdNextAssertion() { holdNextSignature = true }
    func releaseHeldAssertion() {
        heldSignature?.resume()
        heldSignature = nil
    }

    func generateKey() async throws -> String {
        keyRequests += 1
        guard isSupported else { throw DCError(.featureUnsupported) }
        let key = P256.Signing.PrivateKey()
        let id = TestApp.sha256(key.publicKey.x963Representation).base64EncodedString()
        keys[id] = key
        keysMade += 1
        return id
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestRequests.append((keyID, clientDataHash))
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        if !attestFailures.isEmpty { throw attestFailures.removeFirst() }
        guard let key = keys[keyID], !lost.contains(keyID), !certified.contains(keyID) else { throw DCError(.invalidKey) }
        certified.insert(keyID)
        return try chain.attestation(for: key, clientDataHash: clientDataHash, certifiedAt: certifiedAt)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionRequests += 1
        if holdNextSignature {
            holdNextSignature = false
            await withCheckedContinuation { heldSignature = $0 }
        }
        if !assertionFailures.isEmpty { throw assertionFailures.removeFirst() }
        guard let key = keys[keyID], certified.contains(keyID), !lost.contains(keyID) else { throw DCError(.invalidKey) }
        let counter = (counters[keyID] ?? 0) + 1
        counters[keyID] = counter
        return try TestAttestation.assertion(by: key, formHash: clientDataHash, counter: counter)
    }
}
#endif
