//
//  Item90EvidenceDecodingTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 1: the readers under the verifier's rules. CBOR as App Attest writes it, read strictly; the
//  parts of a certificate the verifier reads itself (validity, key, Apple's nonce extension); and App Attest's
//  authenticator data, where a key's attestation carries the credential and a signature never does, even with iOS 27's
//  "credential follows" flag set (Phase 0 on the iPhone Air), and where iOS 27's two fields are read. Written before the
//  code, red at that commit (against compile-only stubs).
//

import CryptoKit
import XCTest
@testable import Malinois

final class Item90EvidenceDecodingTests: XCTestCase {

    // MARK: - CBOR

    func testCBORReadsTheShapesAppAttestWrites() throws {
        let value = EvidenceCBOR.map([
            EvidenceCBOR.Pair(key: .text("fmt"), value: .text("apple-appattest")),
            EvidenceCBOR.Pair(key: .unsigned(1), value: .unsigned(2)),
            EvidenceCBOR.Pair(key: .negative(0), value: .negative(6)),
            EvidenceCBOR.Pair(key: .text("bytes"), value: .array([.bytes(Data()), .bytes(Data(repeating: 7, count: 300))])),
            EvidenceCBOR.Pair(key: .text("é"), value: .array([.simple(20), .simple(21), .simple(22)])),
            EvidenceCBOR.Pair(key: .text("numbers"),
                              value: .array(([23, 24, 255, 256, 65_535, 65_536, 1 << 32, UInt64.max] as [UInt64]).map { EvidenceCBOR.unsigned($0) })),
        ])
        let decoded = try EvidenceCBOR.decode(TestCBOR.encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["fmt"]?.textValue, "apple-appattest")
        XCTAssertEqual(decoded[1]?.unsignedValue, 2)
        XCTAssertEqual(decoded[-1], .negative(6))
        XCTAssertEqual(decoded["bytes"]?.arrayValue?.last?.bytesValue?.count, 300)
        XCTAssertNil(decoded["missing"])
        XCTAssertNil(decoded["fmt"]?.bytesValue)
        let two = TestCBOR.encode(.text("first")) + TestCBOR.encode(.unsigned(9))
        let prefix = try EvidenceCBOR.decodePrefix(two)
        XCTAssertEqual(prefix.value, .text("first"))
        XCTAssertEqual(prefix.length, 6)
    }

    func testCBORRefusesWhatAppAttestNeverWrites() {
        let cases: [(String, Data)] = [
            ("nothing", Data()),
            ("an indefinite-length array", Data([0x9F, 0x01, 0xFF])),
            ("a half-precision float", Data([0xF9, 0x3C, 0x00])),
            ("a tag", Data([0xC0, 0x61, 0x61])),
            ("bytes after the value", TestCBOR.encode(.unsigned(1)) + Data([0x01])),
            ("a repeated key", TestCBOR.encode(TestCBOR.map([("a", .unsigned(1)), ("a", .unsigned(2))]))),
            ("a byte string longer than its data", Data([0x4A, 1, 2, 3])),
            ("a length beyond any data", Data([0x5B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
            ("an array longer than its data", Data([0x9A, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])),
            ("a reserved length", Data([0x1C])),
            ("invalid UTF-8 text", Data([0x62, 0xC3, 0x28])),
            ("a simple value in the two-byte form below 32", Data([0xF8, 0x14])),
            ("nesting deeper than the limit", Data(repeating: 0x81, count: EvidenceCBOR.maximumDepth + 1) + Data([0x01])),
        ]
        for (why, data) in cases {
            XCTAssertThrowsError(try EvidenceCBOR.decode(data), why) { XCTAssertTrue(Self.isUnreadable($0), "\(why): \($0)") }
        }
        let deepest = Data(repeating: 0x81, count: EvidenceCBOR.maximumDepth) + Data([0x01])
        XCTAssertNoThrow(try EvidenceCBOR.decode(deepest))
        // Read at the start of longer data (the key inside an attestation), a value the reader does not understand is
        // refused too, not taken as a shorter one.
        for (why, data) in [("a half-precision float", Data([0xF9, 0x3C, 0x00])), ("a tag", Data([0xC0, 0x61, 0x61])),
                            ("a break", Data([0xFF, 0x01]))] {
            XCTAssertThrowsError(try EvidenceCBOR.decodePrefix(data), why) { XCTAssertTrue(Self.isUnreadable($0), "\(why): \($0)") }
        }
    }

    // MARK: - DER

    func testDERReadsElementsAndRefusesBadLengths() throws {
        XCTAssertEqual(try EvidenceDER.element(Data([0x04, 0x02, 0xAA, 0xBB])), EvidenceDER.Element(tag: 0x04, content: Data([0xAA, 0xBB])))
        let long = Data(repeating: 0x5A, count: 300)
        XCTAssertEqual(try EvidenceDER.element(TestDER.octetString(long)).content, long)
        XCTAssertEqual(try EvidenceDER.element(Data([0x04, 0x81, 0x80]) + Data(repeating: 1, count: 128)).content.count, 128)
        let three = TestDER.integer(1) + TestDER.boolean(true) + TestDER.octetString(Data([9]))
        XCTAssertEqual(try EvidenceDER.elements(three).map(\.tag), [0x02, 0x01, 0x04])
        XCTAssertEqual(try EvidenceDER.elements(Data()), [])
        let cases: [(String, Data)] = [
            ("nothing", Data()),
            ("an indefinite length", Data([0x30, 0x80, 0x00, 0x00])),
            ("a truncated length", Data([0x04, 0x82, 0x01])),
            ("content shorter than its length", Data([0x04, 0x05, 0x01])),
            ("a five-byte length", Data([0x04, 0x85, 0, 0, 0, 0, 1, 0])),
            ("a nine-byte length", Data([0x04, 0x89, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])),
            ("a multi-byte tag", Data([0x1F, 0x01, 0x00])),
            ("bytes after the element", Data([0x04, 0x01, 0x01, 0x00])),
        ]
        for (why, data) in cases {
            XCTAssertThrowsError(try EvidenceDER.element(data), why) { XCTAssertTrue(Self.isUnreadable($0), "\(why): \($0)") }
        }
    }

    func testACertificatesValidityKeyAndExtensionsAreRead() throws {
        let chain = try TestAttestationChain()
        let key = P256.Signing.PrivateKey()
        let nonce = Data(repeating: 0x5C, count: 32)
        let certifiedAt = TestApp.date(2026, 10, 31, 0, 54)
        let leaf = try EvidenceDER.certificate(chain.leaf(for: key.publicKey, nonce: nonce, certifiedAt: certifiedAt))
        XCTAssertEqual(leaf.validFrom, TestApp.date(2026, 10, 30, 0, 54))
        XCTAssertEqual(leaf.validUntil, TestApp.date(2026, 11, 2, 0, 54))
        XCTAssertEqual(leaf.keyAlgorithm, TestOID.ecPublicKey)
        XCTAssertEqual(leaf.keyCurve, TestOID.p256)
        XCTAssertEqual(leaf.publicKey, key.publicKey.x963Representation)
        XCTAssertEqual(leaf.p256PublicKey, key.publicKey.x963Representation)
        XCTAssertEqual(leaf.extensions.map(\.oid), [TestOID.basicConstraints, TestOID.keyUsage, TestOID.appAttestNonce])
        XCTAssertEqual(leaf.extensions.map(\.critical), [true, true, false])
        XCTAssertEqual(try EvidenceDER.appAttestNonce(in: leaf), nonce)
        let intermediate = try EvidenceDER.certificate(chain.intermediateDER)
        XCTAssertEqual(intermediate.keyCurve, TestOID.p384)
        XCTAssertNil(intermediate.p256PublicKey, "a P-384 key is not App Attest's")
        XCTAssertThrowsError(try EvidenceDER.appAttestNonce(in: intermediate)) { XCTAssertTrue(Self.isUnreadable($0)) }
        // A life past 2049 is written as GeneralizedTime.
        let late = try EvidenceDER.certificate(chain.leaf(for: key.publicKey, nonce: nonce, certifiedAt: certifiedAt,
                                                          life: TestApp.date(2049, 12, 31)...TestApp.date(2061, 1, 2, 3, 4)))
        XCTAssertEqual(late.validFrom, TestApp.date(2049, 12, 31))
        XCTAssertEqual(late.validUntil, TestApp.date(2061, 1, 2, 3, 4))
    }

    func testOnlyAnUncompressedP256KeyIsAppAttests() throws {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        func key(algorithm: [UInt64] = TestOID.ecPublicKey, curve: [UInt64] = TestOID.p256, bits: Data? = nil) throws -> Data? {
            let info = TestDER.sequence([TestDER.sequence([TestDER.oid(algorithm), TestDER.oid(curve)]), TestDER.bitString(bits ?? point)])
            return try EvidenceDER.certificate(Self.unsignedCertificate(keyInfo: info)).p256PublicKey
        }
        XCTAssertEqual(try key(), point)
        XCTAssertNil(try key(algorithm: [1, 3, 132, 1, 12]), "another algorithm")
        XCTAssertNil(try key(curve: TestOID.p384), "another curve")
        XCTAssertNil(try key(bits: point.prefix(64)), "a point a byte short")
        XCTAssertNil(try key(bits: Data([0x03]) + point.dropFirst()), "a point not uncompressed")
    }

    func testAppleNonceMustHaveItsShape() throws {
        let chain = try TestAttestationChain()
        let key = P256.Signing.PrivateKey()
        let at = TestApp.date(2026, 10, 31)
        let shapes: [(String, Data)] = [
            ("the nonce bare", TestDER.octetString(Data(repeating: 1, count: 32))),
            ("a short nonce", TestDER.sequence([TestDER.explicit(1, TestDER.octetString(Data(repeating: 1, count: 31)))])),
            ("another tag", TestDER.sequence([TestDER.explicit(2, TestDER.octetString(Data(repeating: 1, count: 32)))])),
            ("in a SET", TestDER.set([TestDER.explicit(1, TestDER.octetString(Data(repeating: 1, count: 32)))])),
            ("not an OCTET STRING", TestDER.sequence([TestDER.explicit(1, TestDER.tlv(0x02, Data(repeating: 1, count: 32)))])),
        ]
        for (why, value) in shapes {
            let leaf = try EvidenceDER.certificate(chain.leaf(for: key.publicKey, nonce: Data(), certifiedAt: at, nonceExtension: value))
            XCTAssertThrowsError(try EvidenceDER.appAttestNonce(in: leaf), why) { XCTAssertTrue(Self.isUnreadable($0), why) }
        }
        // An extension given twice names neither value.
        let twice = EvidenceDER.Certificate(validFrom: at, validUntil: at, keyAlgorithm: TestOID.ecPublicKey, keyCurve: TestOID.p256,
                                            publicKey: key.publicKey.x963Representation,
                                            extensions: [EvidenceDER.Extension(oid: TestOID.appAttestNonce, critical: false, value: Data([1])),
                                                         EvidenceDER.Extension(oid: TestOID.appAttestNonce, critical: false, value: Data([2]))])
        XCTAssertNil(twice.extensionValue(TestOID.appAttestNonce))
    }

    func testACertificateWithAnImpossibleTimeIsUnreadable() throws {
        for (why, time) in [("month 13", "261301000000Z"), ("hour 24", "261031240000Z"), ("no zone", "261031000000"),
                            ("a short year", "2610310000Z"), ("month 0", "260001000000Z"), ("the 30th of February", "260230000000Z"),
                            ("the 29th of February 2027", "270229000000Z"), ("minute 60", "261031006000Z"),
                            ("second 60", "261031000060Z"), ("a letter in it", "261031000A00Z"),
                            ("a digit where the zone goes", "2610310000000")] {
            let validity = TestDER.sequence([TestDER.tlv(0x17, Data(time.utf8)), TestDER.time(TestApp.date(2026, 11, 2))])
            XCTAssertThrowsError(try EvidenceDER.certificate(Self.unsignedCertificate(validity: validity)), why) {
                XCTAssertTrue(Self.isUnreadable($0), why)
            }
        }
        let fine = TestDER.sequence([TestDER.time(TestApp.date(2026, 10, 30)), TestDER.time(TestApp.date(2026, 11, 2))])
        XCTAssertNoThrow(try EvidenceDER.certificate(Self.unsignedCertificate(validity: fine)))
        // UTCTime's two-digit years run from 1950 to 2049; a leap year's 29 February is a day.
        for (text, date) in [("490101000000Z", TestApp.date(2049, 1, 1)), ("500101000000Z", TestApp.date(1950, 1, 1)),
                             ("280229235959Z", TestApp.date(2028, 2, 29, 23, 59).addingTimeInterval(59))] {
            let validity = TestDER.sequence([TestDER.tlv(0x17, Data(text.utf8)), TestDER.time(TestApp.date(2061, 1, 1))])
            XCTAssertEqual(try EvidenceDER.certificate(Self.unsignedCertificate(validity: validity)).validFrom, date, text)
        }
        // A century is a leap year only every 400 years: 29 February 2000 was a day, 29 February 2100 will not be.
        let y2000 = TestDER.sequence([TestDER.tlv(0x17, Data("000229000000Z".utf8)), TestDER.time(TestApp.date(2061, 1, 1))])
        XCTAssertEqual(try EvidenceDER.certificate(Self.unsignedCertificate(validity: y2000)).validFrom, TestApp.date(2000, 2, 29))
        let y2100 = TestDER.sequence([TestDER.time(TestApp.date(2026, 10, 30)), TestDER.tlv(0x18, Data("21000229000000Z".utf8))])
        XCTAssertThrowsError(try EvidenceDER.certificate(Self.unsignedCertificate(validity: y2100)), "29 February 2100") {
            XCTAssertTrue(Self.isUnreadable($0))
        }
        let otherType = TestDER.sequence([TestDER.tlv(0x13, Data("261030000000Z".utf8)), TestDER.time(TestApp.date(2026, 11, 2))])
        XCTAssertThrowsError(try EvidenceDER.certificate(Self.unsignedCertificate(validity: otherType)), "a time of another type") {
            XCTAssertTrue(Self.isUnreadable($0))
        }
    }

    func testObjectIdentifiersAreReadArcByArc() throws {
        XCTAssertEqual(try EvidenceDER.oid(Data([0x2A, 0x86, 0x48])), [1, 2, 840])
        XCTAssertEqual(try EvidenceDER.oid(Data([0x55, 0x1D, 0x13])), [2, 5, 29, 19], "a first byte of 80 or more is arc 2")
        let cases: [(String, Data)] = [
            ("nothing", Data()),
            ("an arc cut short", Data([0x2A, 0x86])),
            ("a first byte in base 128", Data([0x81, 0x01])),
            ("an arc beyond 64 bits", Data([0x2A] + Array(repeating: 0xFF, count: 9) + [0x7F])),
        ]
        for (why, data) in cases {
            XCTAssertThrowsError(try EvidenceDER.oid(data), why) { XCTAssertTrue(Self.isUnreadable($0), why) }
        }
    }

    func testACertificateOutOfItsShapeIsUnreadable() throws {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let algorithm = TestDER.sequence([TestDER.oid(TestOID.ecdsaSHA256)])
        let name = TestAttestationChain.name("Shape")
        let validity = TestDER.sequence([TestDER.time(TestApp.date(2026, 10, 30)), TestDER.time(TestApp.date(2026, 11, 2))])
        let keyAlgorithm = TestDER.sequence([TestDER.oid(TestOID.ecPublicKey), TestDER.oid(TestOID.p256)])
        let nonceValue = TestDER.octetString(TestDER.sequence([TestDER.explicit(1, TestDER.octetString(Data(repeating: 1, count: 32)))]))
        let nonceOID = TestDER.oid(TestOID.appAttestNonce)
        func fields(serial: Data = TestDER.integer(1), issuer: Data? = nil, validity times: Data? = nil, keyInfo: Data? = nil,
                    extensions: [Data]? = nil, extensionsTag: UInt8 = 0x30) -> [Data] {
            [TestDER.explicit(0, TestDER.integer(2)), serial, algorithm, issuer ?? name, times ?? validity, name,
             keyInfo ?? TestDER.sequence([keyAlgorithm, TestDER.bitString(point)]),
             TestDER.explicit(3, TestDER.tlv(extensionsTag, (extensions ?? [TestDER.sequence([nonceOID, nonceValue])]).reduce(Data(), +)))]
        }
        func certificate(_ signed: [Data]? = nil, signedTag: UInt8 = 0x30, outer: UInt8 = 0x30, algorithmPart: Data? = nil,
                         signature: Data? = nil, parts: Int = 3) -> Data {
            let all = [TestDER.tlv(signedTag, (signed ?? fields()).reduce(Data(), +)), algorithmPart ?? algorithm,
                       signature ?? TestDER.bitString(Data([0x30, 0x00]))]
            return TestDER.tlv(outer, all.prefix(parts).reduce(Data(), +))
        }
        XCTAssertNoThrow(try EvidenceDER.certificate(certificate()), "the certificate the others are not")
        let time = TestDER.time(TestApp.date(2026, 10, 30))
        let variants: [(String, Data)] = [
            ("in a SET", certificate(outer: 0x31)),
            ("two parts", certificate(parts: 2)),
            ("the signed part not a SEQUENCE", certificate(signedTag: 0x31)),
            ("the algorithm not a SEQUENCE", certificate(algorithmPart: TestDER.set([TestDER.oid(TestOID.ecdsaSHA256)]))),
            ("the signature not a BIT STRING", certificate(signature: TestDER.octetString(Data([0x30, 0x00])))),
            ("fields missing", certificate(Array(fields().prefix(5)))),
            ("the serial not an INTEGER", certificate(fields(serial: TestDER.octetString(Data([1]))))),
            ("the issuer not a SEQUENCE", certificate(fields(issuer: TestDER.set([])))),
            ("three times in the validity", certificate(fields(validity: TestDER.sequence([time, time, time])))),
            ("the key in three parts", certificate(fields(keyInfo: TestDER.sequence([keyAlgorithm, TestDER.bitString(point), time])))),
            ("the key's algorithm not a SEQUENCE",
             certificate(fields(keyInfo: TestDER.sequence([TestDER.set([TestDER.oid(TestOID.ecPublicKey)]), TestDER.bitString(point)])))),
            ("the key not a BIT STRING",
             certificate(fields(keyInfo: TestDER.sequence([keyAlgorithm, TestDER.octetString(Data([0]) + point)])))),
            ("the key's algorithm named by no object identifier",
             certificate(fields(keyInfo: TestDER.sequence([TestDER.sequence([TestDER.octetString(Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))]),
                                                          TestDER.bitString(point)])))),
            ("the key with unused bits",
             certificate(fields(keyInfo: TestDER.sequence([keyAlgorithm, TestDER.bitString(point, unusedBits: 1)])))),
            ("the extensions not a SEQUENCE", certificate(fields(extensionsTag: 0x31))),
            ("an extension not a SEQUENCE", certificate(fields(extensions: [TestDER.set([nonceOID, nonceValue])]))),
            ("an extension of one part", certificate(fields(extensions: [TestDER.sequence([nonceOID])]))),
            ("an extension of four parts",
             certificate(fields(extensions: [TestDER.sequence([nonceOID, TestDER.boolean(true), TestDER.boolean(true), nonceValue])]))),
            ("an extension named by no object identifier",
             certificate(fields(extensions: [TestDER.sequence([TestDER.octetString(Data([1])), nonceValue])]))),
            ("an extension whose value is not an OCTET STRING",
             certificate(fields(extensions: [TestDER.sequence([nonceOID, TestDER.bitString(Data([1]))])]))),
            ("a critical flag that is not a BOOLEAN",
             certificate(fields(extensions: [TestDER.sequence([nonceOID, TestDER.integer(1), nonceValue])]))),
            ("a critical flag of two bytes",
             certificate(fields(extensions: [TestDER.sequence([nonceOID, TestDER.tlv(0x01, Data([0xFF, 0xFF])), nonceValue])]))),
        ]
        for (why, der) in variants {
            XCTAssertThrowsError(try EvidenceDER.certificate(der), why) { XCTAssertTrue(Self.isUnreadable($0), "\(why): \($0)") }
        }
    }

    // MARK: - Authenticator data

    func testAnAttestationsAuthenticatorDataCarriesTheCredential() throws {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        let keyID = TestApp.sha256(point)
        let data = TestAttestation.authenticatorData(shape: TestAttestationShape(), keyID: keyID, point: point)
        let auth = try EvidenceAuthenticatorData.attestation(data)
        XCTAssertEqual(auth.appIDHash, TestApp.sha256(Data(TestApp.id.utf8)))
        XCTAssertEqual(auth.flags, 0xC0)
        XCTAssertEqual(auth.counter, 0)
        XCTAssertEqual(auth.environment, TestApp.development)
        XCTAssertEqual(auth.credentialID, keyID)
        XCTAssertEqual(auth.credentialKey, TestAttestation.coseKey(point))
        XCTAssertEqual(auth.category, 3)
        XCTAssertEqual(auth.bundleVersion, "81")
        var older = TestAttestationShape()
        older.extensions = nil
        let plain = try EvidenceAuthenticatorData.attestation(TestAttestation.authenticatorData(shape: older, keyID: keyID, point: point))
        XCTAssertEqual(plain.flags, 0x40)
        XCTAssertNil(plain.extensions)
        XCTAssertNil(plain.category)
        XCTAssertNil(plain.bundleVersion)
        let plainBytes = TestAttestation.authenticatorData(shape: older, keyID: keyID, point: point)
        var noCredentialFlag = data
        noCredentialFlag[32] = 0x80
        var extensionsFlagOnly = plainBytes
        extensionsFlagOnly[32] = 0xC0
        var longCredential = data
        longCredential[53] = 0xFF
        longCredential[54] = 0xFF
        let cases: [(String, Data)] = [
            ("no credential flag", noCredentialFlag),
            ("cut inside the environment", data.prefix(45)),
            ("a credential longer than the data", longCredential),
            ("bytes after the key with no extensions flag", plainBytes + Data([0xA0])),
            ("the extensions flag with nothing after the key", extensionsFlagOnly),
            ("shorter than the header", Data(repeating: 0, count: 36)),
        ]
        for (why, bytes) in cases {
            XCTAssertThrowsError(try EvidenceAuthenticatorData.attestation(bytes), why) { XCTAssertTrue(Self.isUnreadable($0), why) }
        }
    }

    func testASignaturesAuthenticatorDataNeverReadsACredential() throws {
        let header = TestApp.sha256(Data(TestApp.id.utf8))
        let extensions = TestCBOR.iOS27Extensions(category: 2, bundleVersion: "81")
        // iOS 27, as on the Air: the credential and extensions flags, the counter, then only the extensions.
        let current = try EvidenceAuthenticatorData.assertion(header + Data([0xC0, 0, 0, 0, 7]) + TestCBOR.encode(extensions))
        XCTAssertEqual(current.counter, 7)
        XCTAssertNil(current.credentialID)
        XCTAssertNil(current.environment)
        XCTAssertEqual(current.category, 2)
        XCTAssertEqual(current.bundleVersion, "81")
        // An older iOS: the credential flag, nothing after the counter.
        let older = try EvidenceAuthenticatorData.assertion(header + Data([0x40, 0, 0, 1, 0]))
        XCTAssertEqual(older.counter, 256)
        XCTAssertNil(older.extensions)
        XCTAssertNil(older.category)
        let cases: [(String, Data)] = [
            ("shorter than the header", header + Data([0x40, 0, 0, 1])),
            ("bytes after the counter with no extensions flag", header + Data([0x40, 0, 0, 0, 1]) + TestCBOR.encode(extensions)),
            ("extensions that are not a map", header + Data([0xC0, 0, 0, 0, 1]) + TestCBOR.encode(.array([]))),
            ("bytes after the extensions", header + Data([0xC0, 0, 0, 0, 1]) + TestCBOR.encode(extensions) + Data([0x00])),
        ]
        for (why, bytes) in cases {
            XCTAssertThrowsError(try EvidenceAuthenticatorData.assertion(bytes), why) { XCTAssertTrue(Self.isUnreadable($0), why) }
        }
    }

    func testIOS27sTwoFieldsAreReadInEitherSpelling() throws {
        let header = TestApp.sha256(Data(TestApp.id.utf8)) + Data([0xC0, 0, 0, 0, 1])
        func read(_ entries: [(String, EvidenceCBOR)]) throws -> EvidenceAuthenticatorData {
            try EvidenceAuthenticatorData.assertion(header + TestCBOR.encode(TestCBOR.map(entries)))
        }
        XCTAssertEqual(try read([("apple_validation_category_01", .bytes(Data([4, 0, 0, 0])))]).category, 4)
        XCTAssertEqual(try read([("apple_validation_category_01", .bytes(Data([4, 3, 2, 1])))]).category, 0x0102_0304)
        XCTAssertEqual(try read([("apple_validation_category_01", .unsigned(2))]).category, 2)
        XCTAssertEqual(try read([("validationCategory", .bytes(Data([3, 0, 0, 0]))), ("bundleVersion", .text("79"))]).category, 3)
        XCTAssertEqual(try read([("validationCategory", .unsigned(3)), ("bundleVersion", .text("79"))]).bundleVersion, "79")
        XCTAssertNil(try read([("apple_validation_category_01", .bytes(Data([4, 0, 0])))]).category, "three bytes")
        XCTAssertNil(try read([("apple_validation_category_01", .text("4"))]).category, "text")
        XCTAssertNil(try read([("apple_validation_category_01", .unsigned(1 << 32))]).category, "beyond 32 bits")
        XCTAssertNil(try read([("apple_bundle_version_01", .bytes(Data("81".utf8)))]).bundleVersion, "bytes, not text")
    }

    // MARK: - Helpers

    static func isUnreadable(_ error: Error) -> Bool {
        if case .unreadable = error as? EvidenceProblem { return true }
        return false
    }

    /// A certificate's bytes with the given validity and key, signed by nobody: the reader checks no signature.
    static func unsignedCertificate(validity: Data? = nil, keyInfo: Data? = nil) -> Data {
        let algorithm = TestDER.sequence([TestDER.oid(TestOID.ecdsaSHA256)])
        let name = TestAttestationChain.name("Unsigned")
        let tbs = TestDER.sequence([
            TestDER.explicit(0, TestDER.integer(2)), TestDER.integer(1), algorithm, name,
            validity ?? TestDER.sequence([TestDER.time(TestApp.date(2026, 10, 30)), TestDER.time(TestApp.date(2026, 11, 2))]), name,
            keyInfo ?? TestAttestationChain.keyInfo(P256.Signing.PrivateKey().publicKey.x963Representation, curve: TestOID.p256),
            TestDER.explicit(3, TestDER.sequence([])),
        ])
        return TestDER.sequence([tbs, algorithm, TestDER.bitString(Data([0x30, 0x00]))])
    }
}
