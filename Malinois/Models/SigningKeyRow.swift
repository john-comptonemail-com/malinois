//
//  SigningKeyRow.swift
//  Malinois
//
//  The signing key in Settings (BACKLOG item 199, from item 198's Fable-2 and DeepSeek-2; the owner, 2026-11-07: "as you
//  recommend, wording approved"). A check ties an evidence ZIP to the key that signed it; the row shows the owner that key,
//  as the verifier prints a key, with Copy for the whole ID, so they can give it to someone before sending one. Before
//  Apple has certified a key, it says the key waits for Apple. No row where this iPhone cannot sign.
//

import Foundation

/// What Settings shows of the phone's signing key (`EvidenceSigner.signingKey()`).
enum SigningKey: Equatable, Sendable {
    /// The certified key in use, by its ID.
    case certified(Data)
    /// No certified key yet: a new install or a new iPhone, or one App Attest lost, until Apple certifies the next.
    case waitingForApple
}

/// The Settings row for the signing key, in the owner's approved words. Pure, so the tests read it.
enum SigningKeyRow {
    static let title = "Signing key"
    static let waiting = "Waiting for Apple to certify it (needs a network connection)"
    /// Under the row while a key is certified: it names "these eight characters". "Each evidence ZIP", and "one" for the
    /// ZIP in the sentence after, since item 218's Codex-4 (the owner, 2026-11-09: "as you recommend, wording approved"):
    /// a set-aside log's ZIP, new in 1.12, is not signed, so "Each ZIP you share is signed with this key" did not hold.
    static let footer = "Each evidence ZIP you share is signed with this key, and its check names the key by these eight characters. "
        + "Give someone this ID before you send them one, and they can tell it was signed on this iPhone. Malinois makes "
        + "a new key after it is deleted and installed again, on a new iPhone, or if Apple's App Attest loses this one."
    static let copy = "Copy"

    /// The row's value: a certified key's first eight characters as the verifier prints a key ("5521c718…"), or that it
    /// waits for Apple.
    static func value(_ key: SigningKey) -> String {
        switch key {
        case .certified(let id): String(EvidenceHash.hex(id).prefix(8)) + "…"
        case .waitingForApple: waiting
        }
    }

    /// What Copy puts on the clipboard: the key's whole ID (64 characters); nil while there is no certified key.
    static func copyText(_ key: SigningKey) -> String? {
        guard case .certified(let id) = key else { return nil }
        return EvidenceHash.hex(id)
    }
}
