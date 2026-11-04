//
//  EvidenceKeyService.swift
//  Malinois
//
//  The phone's side of App Attest that evidence signing uses (BACKLOG item 90, phase 2): a key made in the Secure
//  Enclave, Apple's certification of it (the one time the app contacts Apple for it), and signatures by it, offline.
//  A protocol, so the tests stand in a key they make themselves: App Attest does not run in the Simulator.
//

import DeviceCheck
import Foundation

protocol EvidenceKeyService: Sendable {
    /// Whether this device can make and use App Attest keys: never in the Simulator or on a Mac.
    var isSupported: Bool { get }
    /// A new key in the Secure Enclave; its identifier is its key ID, base64.
    func generateKey() async throws -> String
    /// Apple's certification of the key `keyID` for `clientDataHash` (the key statement's SHA-256): the attestation
    /// object. Needs the network once; retried with the same key and hash when Apple's service is unavailable.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    /// A signature by the certified key `keyID` over `clientDataHash` (a statement's SHA-256): the assertion object.
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// App Attest itself.
struct AppAttestKeyService: EvidenceKeyService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}
