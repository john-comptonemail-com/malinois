//
//  Item90EvidenceAirTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 1: the verifier's rules on what a real iPhone wrote. Phase 0 (item 78, 2026-10-30) ran Codex's
//  App Attest spike on the owner's iPhone Air (iOS 27.0.1, a development build of 1.8.2 (79)): one key, certified by
//  Apple, then ten signatures over small sample statements. Its ten signatures and the key's public half are here,
//  byte for byte. Apple's certificate and receipt from the same run are not: they name the developer's team ID, which
//  stays out of the repository (the chain rules are checked on test chains, Item90EvidenceVerifierTests). These
//  signatures carry iOS 27's encodings that a verifier written from Apple's documents alone got wrong: the "credential
//  follows" flag set with no credential, and the channel as four bytes, little-endian. Written before the code, red at
//  that commit (against compile-only stubs).
//

import CryptoKit
import XCTest
@testable import Malinois

final class Item90EvidenceAirTests: XCTestCase {

    /// The Air's key as its certification (checked in Phase 0, outside the repository) gave it.
    private var airKey: EvidenceCertifiedKey {
        let keyID = EvidenceHash.bytes(hex: AirFixture.keyID) ?? Data()
        return EvidenceCertifiedKey(
            keyID: keyID, publicKey: Data(base64Encoded: AirFixture.publicKey) ?? Data(),
            appIDHash: EvidenceHash.bytes(hex: AirFixture.appIDHash) ?? Data(), environment: .development,
            certificateLife: AirFixture.certificateFrom...AirFixture.certificateUntil,
            judgedAt: AirFixture.certificateFrom.addingTimeInterval(86_400), category: 3, bundleVersion: "79",
            // The spike certified its own challenge, not a Malinois key statement.
            statement: EvidenceForm.KeyStatement(keyID: keyID, signedAt: 0, app: "1.8.2 (79)", follows: nil))
    }

    func testTheAirsTenSignaturesCheckOut() throws {
        var entries: [EvidenceSignedEntry] = []
        for (index, signature) in AirFixture.signatures.enumerated() {
            let assertion = try XCTUnwrap(Data(base64Encoded: signature.assertion))
            let entry = try EvidenceVerifier.check(assertion: assertion, formHash: TestApp.sha256(Data(signature.clientData.utf8)),
                                                   form: nil, under: airKey)
            XCTAssertEqual(entry.counter, UInt32(index + 1))
            XCTAssertEqual(entry.category, 3, "a development build")
            XCTAssertEqual(entry.bundleVersion, "79")
            XCTAssertNil(entry.statement)
            entries.append(entry)
        }
        let report = EvidenceVerifier.sequence(of: entries, keyID: airKey.keyID, followers: [])
        XCTAssertEqual(report.counters, Array(1...10))
        XCTAssertEqual(report.missing, [])
        XCTAssertEqual(report.repeated, [])
        XCTAssertEqual(report.signedAgain, [])
    }

    func testTheAirsSignaturesSetTheCredentialFlagWithNoCredential() throws {
        for signature in AirFixture.signatures {
            let object = try EvidenceCBOR.decode(try XCTUnwrap(Data(base64Encoded: signature.assertion)))
            let authData = try XCTUnwrap(object["authenticatorData"]?.bytesValue)
            XCTAssertEqual(authData.count, 100)
            let auth = try EvidenceAuthenticatorData.assertion(authData)
            XCTAssertEqual(auth.flags, 0xC0, "the credential and extensions flags")
            XCTAssertNil(auth.credentialID)
            XCTAssertEqual(auth.extensions?["apple_validation_category_01"]?.bytesValue, Data([3, 0, 0, 0]))
            XCTAssertEqual(auth.appIDHash, airKey.appIDHash)
        }
    }

    func testAChangedByteInAnAirSignatureFails() throws {
        let first = AirFixture.signatures[0], second = AirFixture.signatures[1]
        let assertion = try XCTUnwrap(Data(base64Encoded: first.assertion))
        let cases: [(String, Data, String, EvidenceCertifiedKey)] = [
            ("another statement", assertion, second.clientData, airKey),
            ("one character changed", assertion, first.clientData.replacingOccurrences(of: "sample", with: "Sample"), airKey),
            ("another record's signature", try XCTUnwrap(Data(base64Encoded: second.assertion)), first.clientData, airKey),
            ("another key", assertion, first.clientData, key(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation)),
        ]
        for (why, assertion, clientData, key) in cases {
            XCTAssertThrowsError(try EvidenceVerifier.check(assertion: assertion, formHash: TestApp.sha256(Data(clientData.utf8)),
                                                            form: nil, under: key), why) {
                XCTAssertEqual($0 as? EvidenceProblem, .signatureMismatch, why)
            }
        }
        XCTAssertThrowsError(try EvidenceVerifier.check(assertion: assertion, formHash: TestApp.sha256(Data(first.clientData.utf8)),
                                                        form: nil, under: key(appIDHash: Data(repeating: 0, count: 32)))) {
            XCTAssertEqual($0 as? EvidenceProblem, .otherApp)
        }
    }

    func testAGenuineSignatureOverAStatementThatIsNotMalinoissIsNotARecord() throws {
        // The spike signed its own sample statements: genuine signatures, but no Malinois statement, so nothing to read.
        let first = AirFixture.signatures[0]
        let clientData = Data(first.clientData.utf8)
        XCTAssertThrowsError(try EvidenceVerifier.check(assertion: try XCTUnwrap(Data(base64Encoded: first.assertion)),
                                                        formHash: TestApp.sha256(clientData), form: clientData, under: airKey)) {
            XCTAssertEqual($0 as? EvidenceProblem, .formNotFixed)
        }
    }

    private func key(publicKey: Data? = nil, appIDHash: Data? = nil) -> EvidenceCertifiedKey {
        let air = airKey
        return EvidenceCertifiedKey(keyID: air.keyID, publicKey: publicKey ?? air.publicKey, appIDHash: appIDHash ?? air.appIDHash,
                                    environment: air.environment, certificateLife: air.certificateLife, judgedAt: air.judgedAt,
                                    category: air.category, bundleVersion: air.bundleVersion, statement: air.statement)
    }
}

/// Phase 0's run on the iPhone Air (2026-10-31 00:54 UTC): the key's public half, its ID (SHA-256 of the key), the hash
/// of the App ID it was certified for, Apple's certificate's life, and the ten statements with their signatures, as the
/// spike exported them.
enum AirFixture {   // also the Mac verifier's tests (Item90VerifierTests)
    static let appIDHash = "d7c30790792071e204e7f0d71a674ff9268cffc327fc89a5a5a238329def69e7"
    static let certificateFrom = TestApp.date(2026, 10, 30, 0, 53).addingTimeInterval(59)
    static let certificateUntil = TestApp.date(2026, 11, 2, 0, 53).addingTimeInterval(59)
    static let publicKey = "BI7jXLK1DTcoRCLyqZVLLJ2vByDulh+zzd/H2s8KQ8qnaSoaghuf9d0nD9yPWc8DUMEKmJnT9WyxriE3A4D30GQ="
    static let keyID = "44524fb3a6acc003c9f858970a0c7c56b7e454221bba85e2c5173cab12a82237"
    static let signatures: [(clientData: String, assertion: String)] = [
        (#"{"at":"2026-10-31T00:54:19Z","kind":"spike78","seq":1,"text":"sample record 1"}"#,
         "omlzaWduYXR1cmVYRzBFAiArdzdx+dAJThNRS+CkTGd78NxiONUXoMIFOhlgb+Te+AIhAJk0eOx53bqaQXhDduS+nqrfktqyS8OFn2Nn746g9GO4cWF1dGhlbnRpY2F0b3JEYXRhWGTXwweQeSBx4gTn8NcaZ0/5Joz/wyf8iaWlojgyne9p58AAAAABondhcHBsZV9idW5kbGVfdmVyc2lvbl8wMWI3OXgcYXBwbGVfdmFsaWRhdGlvbl9jYXRlZ29yeV8wMUQDAAAA"),
        (#"{"at":"2026-10-31T00:54:19Z","kind":"spike78","seq":2,"text":"sample record 2"}"#,
         "omlzaWduYXR1cmVYSDBGAiEA77GWLhi/sC4nkwsf/XP63Qsx9DZ1BaNYg1Um+ipqX9ICIQDQHGmhx8CIYV5Mg7lt87RNpFLByd8069XADxaMsl0BanFhdXRoZW50aWNhdG9yRGF0YVhk18MHkHkgceIE5/DXGmdP+SaM/8Mn/ImlpaI4Mp3vaefAAAAAAqJ3YXBwbGVfYnVuZGxlX3ZlcnNpb25fMDFiNzl4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAwAAAA=="),
        (#"{"at":"2026-10-31T00:54:19Z","kind":"spike78","seq":3,"text":"sample record 3"}"#,
         "omlzaWduYXR1cmVYSDBGAiEAy0XYiCOusfv3m7l9dHeso+YZjrE/iKK6ZGxKfXI0qnUCIQCjkh5Fx6KBVEhYhw6OO7+e6Ded5td+ne+QiYwCuVjnUXFhdXRoZW50aWNhdG9yRGF0YVhk18MHkHkgceIE5/DXGmdP+SaM/8Mn/ImlpaI4Mp3vaefAAAAAA6J3YXBwbGVfYnVuZGxlX3ZlcnNpb25fMDFiNzl4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAwAAAA=="),
        (#"{"at":"2026-10-31T00:54:19Z","kind":"spike78","seq":4,"text":"sample record 4"}"#,
         "omlzaWduYXR1cmVYSDBGAiEA8OEgGXy6Cjc1yN6715mgZoSFAhKrb9fJn+gkKf7bnesCIQDvfjJbySgss7e0UCeqyVhoFhcPht709adXkABiad4MV3FhdXRoZW50aWNhdG9yRGF0YVhk18MHkHkgceIE5/DXGmdP+SaM/8Mn/ImlpaI4Mp3vaefAAAAABKJ3YXBwbGVfYnVuZGxlX3ZlcnNpb25fMDFiNzl4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAwAAAA=="),
        (#"{"at":"2026-10-31T00:54:19Z","kind":"spike78","seq":5,"text":"sample record 5"}"#,
         "omlzaWduYXR1cmVYRzBFAiEA6tA04ZUAyueRppcMSlikt7g1eRChOxCgsrQ5Z4vqmLsCIGQtxVkofnibrmDCMM3QVaQOLxP069qnxrF10QMaew9RcWF1dGhlbnRpY2F0b3JEYXRhWGTXwweQeSBx4gTn8NcaZ0/5Joz/wyf8iaWlojgyne9p58AAAAAFondhcHBsZV9idW5kbGVfdmVyc2lvbl8wMWI3OXgcYXBwbGVfdmFsaWRhdGlvbl9jYXRlZ29yeV8wMUQDAAAA"),
        (#"{"at":"2026-10-31T00:54:35Z","kind":"spike78","seq":6,"text":"sample record 6"}"#,
         "omlzaWduYXR1cmVYRzBFAiEAu2CoJ9DXN9IEEU9YwTeQV9N1vI91NTX0sS9042+bjKgCID8A9Qsk3AjRgps87HntGQHkqAkanZbuOfc5qu8a7QPEcWF1dGhlbnRpY2F0b3JEYXRhWGTXwweQeSBx4gTn8NcaZ0/5Joz/wyf8iaWlojgyne9p58AAAAAGondhcHBsZV9idW5kbGVfdmVyc2lvbl8wMWI3OXgcYXBwbGVfdmFsaWRhdGlvbl9jYXRlZ29yeV8wMUQDAAAA"),
        (#"{"at":"2026-10-31T00:54:35Z","kind":"spike78","seq":7,"text":"sample record 7"}"#,
         "omlzaWduYXR1cmVYSDBGAiEAyMDAKRloEevtqZiQUAk+QK4Z3FLVc3ZH2bt9qCBXe0kCIQCjVgCNoRPxcTYZ54bdnGBhgOqqk24mbCSJlK75Kl/P+3FhdXRoZW50aWNhdG9yRGF0YVhk18MHkHkgceIE5/DXGmdP+SaM/8Mn/ImlpaI4Mp3vaefAAAAAB6J3YXBwbGVfYnVuZGxlX3ZlcnNpb25fMDFiNzl4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAwAAAA=="),
        (#"{"at":"2026-10-31T00:54:35Z","kind":"spike78","seq":8,"text":"sample record 8"}"#,
         "omlzaWduYXR1cmVYSDBGAiEAhjMQGrfV3D/2flqB79iOc7vAHO1JxRB3fYmAdfsN14oCIQD8MHrgTU6BdutudtXraagVi937DGnEr63kYAKgyDwEtXFhdXRoZW50aWNhdG9yRGF0YVhk18MHkHkgceIE5/DXGmdP+SaM/8Mn/ImlpaI4Mp3vaefAAAAACKJ3YXBwbGVfYnVuZGxlX3ZlcnNpb25fMDFiNzl4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAwAAAA=="),
        (#"{"at":"2026-10-31T00:54:35Z","kind":"spike78","seq":9,"text":"sample record 9"}"#,
         "omlzaWduYXR1cmVYRjBEAiAnY7Gqx5hUf89HnVrm6aur6JkEKprsYIaUFrvr1XxcMgIgRqEzSNxkd/VE7eL5cwDl/YZl6mhHrLkUVN/7TfWo4ThxYXV0aGVudGljYXRvckRhdGFYZNfDB5B5IHHiBOfw1xpnT/kmjP/DJ/yJpaWiODKd72nnwAAAAAmid2FwcGxlX2J1bmRsZV92ZXJzaW9uXzAxYjc5eBxhcHBsZV92YWxpZGF0aW9uX2NhdGVnb3J5XzAxRAMAAAA="),
        (#"{"at":"2026-10-31T00:54:35Z","kind":"spike78","seq":10,"text":"sample record 10"}"#,
         "omlzaWduYXR1cmVYRzBFAiA43TuNmEFzPVMc7uJCrLsYaszCKo10LmMdHWIIpN8DjAIhAMx7vxpsM4opZvJcuKdC9gbG6+Gn1JVeWFtM4Qu74qy0cWF1dGhlbnRpY2F0b3JEYXRhWGTXwweQeSBx4gTn8NcaZ0/5Joz/wyf8iaWlojgyne9p58AAAAAKondhcHBsZV9idW5kbGVfdmVyc2lvbl8wMWI3OXgcYXBwbGVfdmFsaWRhdGlvbl9jYXRlZ29yeV8wMUQDAAAA"),
    ]
}
