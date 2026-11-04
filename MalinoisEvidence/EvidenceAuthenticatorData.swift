//
//  EvidenceAuthenticatorData.swift
//  MalinoisEvidence
//
//  App Attest's authenticator data (WebAuthn's layout): the hash of the App ID, a flags byte, the key's signature
//  counter, then, in a key's attestation only, the credential (Apple's environment, the key ID and the key), and last
//  Apple's extensions. From iOS 27 the extensions name the build's channel and version in the attestation and in every
//  signature; and every signature sets the "credential follows" flag with no credential after it (Phase 0, on the
//  iPhone Air, iOS 27.0.1), so a signature's data is never read as carrying one. Shared by the app and the Mac verifier
//  (BACKLOG item 90).
//

import Foundation

struct EvidenceAuthenticatorData: Equatable, Sendable {
    /// SHA-256 of the App ID the key belongs to (team ID, a dot, bundle ID).
    let appIDHash: Data
    let flags: UInt8
    /// The key's signature counter: 0 in its attestation, then one more for every signature.
    let counter: UInt32
    /// The attestation's AAGUID: Apple's environment, production or development.
    let environment: Data?
    /// The attestation's credential ID: the key ID.
    let credentialID: Data?
    /// The attestation's key, as COSE.
    let credentialKey: EvidenceCBOR?
    /// Apple's extensions, when there are any.
    let extensions: EvidenceCBOR?

    /// Reads a key attestation's authenticator data: the credential must follow the counter.
    static func attestation(_ data: Data) throws -> EvidenceAuthenticatorData {
        let bytes = [UInt8](data)
        let header = try Self.header(bytes)
        guard header.flags & 0x40 != 0 else { throw EvidenceProblem.unreadable("an attestation without its credential") }
        guard bytes.count >= 55 else { throw EvidenceProblem.unreadable("an attestation's credential cut short") }
        let idLength = Int(bytes[53]) << 8 | Int(bytes[54])
        guard idLength <= bytes.count - 55 else { throw EvidenceProblem.unreadable("a credential ID longer than its data") }
        let afterID = Data(bytes[(55 + idLength)...])
        let key = try EvidenceCBOR.decodePrefix(afterID)
        return EvidenceAuthenticatorData(
            appIDHash: header.appIDHash, flags: header.flags, counter: header.counter, environment: Data(bytes[37..<53]),
            credentialID: Data(bytes[55..<(55 + idLength)]), credentialKey: key.value,
            extensions: try extensions(Data(afterID.dropFirst(key.length)), flags: header.flags))
    }

    /// Reads a signature's authenticator data: never a credential, whatever the flags say; Apple's extensions when bytes
    /// follow the counter, which the extensions flag must then announce.
    static func assertion(_ data: Data) throws -> EvidenceAuthenticatorData {
        let bytes = [UInt8](data)
        let header = try Self.header(bytes)
        return EvidenceAuthenticatorData(appIDHash: header.appIDHash, flags: header.flags, counter: header.counter, environment: nil,
                                         credentialID: nil, credentialKey: nil,
                                         extensions: try extensions(Data(bytes.dropFirst(37)), flags: header.flags))
    }

    /// Apple's launch validation category (from iOS 27): how the build was signed, as Apple's list numbers it (2
    /// TestFlight, 3 development, 4 App Store, and others). Apple writes it as four bytes, little-endian; a whole number
    /// is read too. Nil when absent.
    var category: UInt32? {
        switch extensions?["apple_validation_category_01"] ?? extensions?["validationCategory"] {
        case .bytes(let data)? where data.count == 4:
            return data.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        case .unsigned(let value)? where value <= UInt64(UInt32.max):
            return UInt32(value)
        default:
            return nil
        }
    }

    /// The app's bundle version as Apple read it at launch (from iOS 27); nil when absent.
    var bundleVersion: String? {
        (extensions?["apple_bundle_version_01"] ?? extensions?["bundleVersion"])?.textValue
    }

    /// The 37 bytes every authenticator data starts with: the App ID's hash, the flags and the counter (big-endian).
    private static func header(_ bytes: [UInt8]) throws -> (appIDHash: Data, flags: UInt8, counter: UInt32) {
        guard bytes.count >= 37 else { throw EvidenceProblem.unreadable("authenticator data shorter than its 37-byte header") }
        return (Data(bytes[0..<32]), bytes[32], bytes[33..<37].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    /// Apple's extensions: one CBOR map filling what is left, present exactly when the extensions flag (0x80) says so.
    private static func extensions(_ rest: Data, flags: UInt8) throws -> EvidenceCBOR? {
        let announced = flags & 0x80 != 0
        guard announced == !rest.isEmpty else {
            throw EvidenceProblem.unreadable(announced ? "the extensions flag with no extensions" : "bytes after the last part")
        }
        guard announced else { return nil }
        let map = try EvidenceCBOR.decode(rest)
        guard case .map = map else { throw EvidenceProblem.unreadable("extensions that are not a map") }
        return map
    }
}
