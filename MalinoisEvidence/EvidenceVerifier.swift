//
//  EvidenceVerifier.swift
//  MalinoisEvidence
//
//  The verifier's rules (BACKLOG item 90): that Apple certified a key in Malinois on a genuine device, that a signature
//  is that key's over a statement's hash, and what a key's signature counters say about the sequence. The app never
//  judges a record with these; the Mac verifier does, outside the phone, and the app's tests check them. A rule that
//  fails says what it found, as a fact: a counter nothing accounts for is "missing", never "tampered"; a verifier that
//  cannot read something says so and judges nothing. Shared by the app and the Mac verifier.
//

import CryptoKit
import Foundation
import Security

/// What a check found instead of what it needed.
enum EvidenceProblem: Error, Equatable, Sendable {
    /// The bytes are not in the shape expected (CBOR, DER, authenticator data): the reason, for the report.
    case unreadable(String)
    /// A statement in another format than this verifier's, named.
    case unknownFormat(String)
    /// A statement not in its format's fixed form.
    case formNotFixed
    /// An attestation in another format than Apple's App Attest.
    case notAppAttest
    /// Apple's certificate chain does not check out to the given root, at the moment the key was certified.
    case chainNotTrusted
    /// Apple's certificate is for another statement than the one given.
    case notForThisStatement
    /// The key ID, the certificate's key, the credential and the statement do not name one key.
    case keyMismatch
    /// The key belongs to another app.
    case otherApp
    /// A key's attestation with a signature counter above zero.
    case counterNotZero
    /// An attestation from an environment Apple's documents do not name.
    case unknownEnvironment
    /// A statement whose SHA-256 is not the hash that was signed.
    case formHashMismatch
    /// A signature that is not the key's over the hash given.
    case signatureMismatch
    /// A signature by a key the bundle does not certify: one its index does not list, or whose certification failed.
    case notCertified
    /// A file the bundle names that is not in it: its path in the bundle.
    case fileMissing(String)
    /// The format the index names, when it is not the format of what the bundle holds: "/2" exactly when the bundle holds
    /// an unkept statement (ADR 0073's decision 6; item 193's codex-2, the owner's "a"). The label is the phone's word, not
    /// signed.
    case formatNotAsHeld(String)
}

/// Apple's App Attest environment, from the attestation's AAGUID: a Debug build attests in development.
enum EvidenceEnvironment: String, Equatable, Sendable {
    case production
    case development

    /// The environment an AAGUID names; nil for any other.
    init?(aaguid: Data?) {
        switch aaguid {
        case Data("appattest".utf8) + Data(repeating: 0, count: 7): self = .production
        case Data("appattestdevelop".utf8): self = .development
        default: return nil
        }
    }
}

/// A key whose certification by Apple checks out, and what it says.
struct EvidenceCertifiedKey: Equatable, Sendable {
    /// SHA-256 of the key's uncompressed point.
    let keyID: Data
    /// The key's 65-byte uncompressed P-256 point.
    let publicKey: Data
    let appIDHash: Data
    let environment: EvidenceEnvironment
    /// Apple's certificate's own validity: about a day before the key was certified to two days after.
    let certificateLife: ClosedRange<Date>
    /// The moment the chain was judged at: a third of the way into the certificate's life, which is when Apple
    /// certified the key under its practice seen on the Air (valid from a day before to two days after).
    let judgedAt: Date
    /// Apple's launch validation category and the bundle version, from the attestation (iOS 27 and later).
    let category: UInt32?
    let bundleVersion: String?
    let statement: EvidenceForm.KeyStatement
}

/// A signature that checks out under its key.
struct EvidenceSignedEntry: Equatable, Sendable {
    let keyID: Data
    let counter: UInt32
    let formHash: Data
    let category: UInt32?
    let bundleVersion: String?
    /// The statement signed, when the export carries it; nil when it carries only the statement's hash (another
    /// record's signature, kept so the counters can be accounted for).
    let statement: EvidenceForm.Statement?
}

/// What one key's signature counters say about the sequence.
struct EvidenceSequence: Equatable, Sendable {
    /// A record whose revisions are not all here.
    struct MissingRevisions: Equatable, Sendable {
        let id: UUID
        let revisions: [Int64]
    }

    let keyID: Data
    /// The counters of the key's signatures here, ascending, each once.
    let counters: [UInt32]
    /// Counters before the last one here that are not here, which a retention statement accounts for.
    let retired: [ClosedRange<UInt32>]
    /// Counters before the last one here that are not here, which no retention statement accounts for and an unkept
    /// statement of the key's own names below its own counter: made by App Attest and not kept by the phone (item 188,
    /// ADR 0073). Information, not a problem.
    let unkept: [ClosedRange<UInt32>]
    /// Counters before the last one here that are not here, which nothing here accounts for: a fact, not an accusation
    /// (a signature the phone made and did not keep leaves one until its unkept statement names it, and on an earlier key
    /// for good).
    let missing: [ClosedRange<UInt32>]
    /// Counters carried by two different signed statements: App Attest's count went back, as a forced restart can take it, and
    /// gave them out again (item 205, ADR 0077). Only the key can make either, so neither is forged. Information, not a problem.
    let repeated: [UInt32]
    /// Counters whose statement an earlier counter had already signed.
    let signedAgain: [UInt32]
    /// Records whose revision numbers do not rise with their counters.
    let revisionsOutOfOrder: [UUID]
    /// Records with revisions below their highest one that are not here.
    let missingRevisions: [MissingRevisions]
}

enum EvidenceVerifier {
    /// Checks Apple's certification of a key: the attestation's chain to one of `roots` (Apple's App Attestation root
    /// certificate, DER) at the moment the key was certified, that the certificate is for `statement` and for the key it
    /// names, that the key belongs to `appID`, its counter is zero and its environment one Apple names, and that
    /// `statement` is that key's statement in the fixed form.
    static func certify(attestation: Data, statement: Data, appID: String, roots: [Data]) throws -> EvidenceCertifiedKey {
        try certify(attestation: attestation, statement: statement, appIDHash: EvidenceHash.sha256(Data(appID.utf8)), roots: roots)
    }

    /// As `certify(attestation:statement:appID:roots:)`, for the app whose App ID has the SHA-256 `appIDHash`: what every
    /// attestation carries, so a verifier can know an app's keys without its team ID (item 90, phase 5).
    static func certify(attestation: Data, statement: Data, appIDHash: Data, roots: [Data]) throws -> EvidenceCertifiedKey {
        let object = try EvidenceCBOR.decode(attestation)
        guard let format = object["fmt"]?.textValue else { throw EvidenceProblem.unreadable("an attestation without its format") }
        guard format == "apple-appattest" else { throw EvidenceProblem.notAppAttest }
        guard let listed = object["attStmt"]?["x5c"]?.arrayValue, let leafDER = listed.first?.bytesValue,
              let authBytes = object["authData"]?.bytesValue else {
            throw EvidenceProblem.unreadable("an attestation without its certificates or authenticator data")
        }
        let chain = listed.compactMap(\.bytesValue)
        guard chain.count == listed.count else { throw EvidenceProblem.unreadable("a certificate that is not bytes") }
        let leaf = try EvidenceDER.certificate(leafDER)
        guard leaf.validFrom < leaf.validUntil else { throw EvidenceProblem.unreadable("a certificate whose life ends before it starts") }
        // Judged when the key was certified: the certificate lives three days, and an export is read long after.
        let judgedAt = leaf.validFrom.addingTimeInterval(leaf.validUntil.timeIntervalSince(leaf.validFrom) / 3)
        guard chainHolds(chain, roots: roots, at: judgedAt) else { throw EvidenceProblem.chainNotTrusted }
        guard try EvidenceDER.appAttestNonce(in: leaf) == EvidenceHash.sha256(authBytes + EvidenceHash.sha256(statement)) else {
            throw EvidenceProblem.notForThisStatement
        }
        // App Attest's key is P-256; any other fails the credential and COSE checks below as well.
        guard let point = leaf.p256PublicKey else { throw EvidenceProblem.keyMismatch }
        let keyID = EvidenceHash.sha256(point)
        let auth = try EvidenceAuthenticatorData.attestation(authBytes)
        guard auth.credentialID == keyID, coseKey(auth.credentialKey, isPoint: point) else { throw EvidenceProblem.keyMismatch }
        guard auth.appIDHash == appIDHash else { throw EvidenceProblem.otherApp }
        guard auth.counter == 0 else { throw EvidenceProblem.counterNotZero }
        guard let environment = EvidenceEnvironment(aaguid: auth.environment) else { throw EvidenceProblem.unknownEnvironment }
        guard case .key(let keyStatement) = try EvidenceForm.read(statement) else { throw EvidenceProblem.notForThisStatement }
        guard keyStatement.keyID == keyID else { throw EvidenceProblem.keyMismatch }
        return EvidenceCertifiedKey(keyID: keyID, publicKey: point, appIDHash: auth.appIDHash, environment: environment,
                                    certificateLife: leaf.validFrom...leaf.validUntil, judgedAt: judgedAt, category: auth.category,
                                    bundleVersion: auth.bundleVersion, statement: keyStatement)
    }

    /// Checks one signature (`assertion`, as App Attest returned it) over `formHash` under `key`, and, when the export
    /// carries the statement, that its bytes are the ones hashed and in the fixed form.
    static func check(assertion: Data, formHash: Data, form: Data?, under key: EvidenceCertifiedKey) throws -> EvidenceSignedEntry {
        let object = try EvidenceCBOR.decode(assertion)
        guard let signature = object["signature"]?.bytesValue, let authBytes = object["authenticatorData"]?.bytesValue else {
            throw EvidenceProblem.unreadable("a signature without its two parts")
        }
        guard formHash.count == 32 else { throw EvidenceProblem.unreadable("a statement hash that is not 32 bytes") }
        let auth = try EvidenceAuthenticatorData.assertion(authBytes)
        guard auth.appIDHash == key.appIDHash else { throw EvidenceProblem.otherApp }
        guard holds(signature, authBytes: authBytes, formHash: formHash, publicKey: key.publicKey) else {
            throw EvidenceProblem.signatureMismatch
        }
        var statement: EvidenceForm.Statement?
        if let form {
            guard EvidenceHash.sha256(form) == formHash else { throw EvidenceProblem.formHashMismatch }
            statement = try EvidenceForm.read(form)
        }
        return EvidenceSignedEntry(keyID: key.keyID, counter: auth.counter, formHash: formHash, category: auth.category,
                                   bundleVersion: auth.bundleVersion, statement: statement)
    }

    /// The keys that follow `keyID` among `keys` (each key's certified statement): those whose statement names it as the
    /// key they follow, after a restore from a backup, and those that follow them. A key never follows itself.
    static func followers(of keyID: Data, among keys: [EvidenceForm.KeyStatement]) -> Set<Data> {
        var found = Set<Data>()
        var waiting = [keyID]
        // Each key is taken once, so keys that name each other (no phone writes them) end the search too.
        while let followed = waiting.popLast() {
            for key in keys where key.follows == followed && key.keyID != keyID && found.insert(key.keyID).inserted {
                waiting.append(key.keyID)
            }
        }
        return found
    }

    /// What the counters of `keyID`'s signatures among `entries` say: the counters here, the gaps a retention statement
    /// among `entries` accounts for, those the key's own unkept statements name, those nothing accounts for, and each
    /// record's revisions. A retention statement counts only when signed by the key itself (for the counters before its
    /// own) or by one of `followers`, the keys that follow it (`followers(of:among:)`); an unkept statement only when
    /// signed by the key itself, for the counters before its own (item 188, ADR 0073).
    static func sequence(of entries: [EvidenceSignedEntry], keyID: Data, followers: Set<Data>) -> EvidenceSequence {
        // One signature listed twice is one signature.
        var listed = Set<Signed>()
        let own = entries.filter { $0.keyID == keyID && listed.insert(Signed(counter: $0.counter, formHash: $0.formHash)).inserted }
            .sorted { $0.counter < $1.counter }
        var hashesAt: [UInt32: Set<Data>] = [:]
        var firstSigned: [Data: UInt32] = [:]
        for entry in own {
            hashesAt[entry.counter, default: []].insert(entry.formHash)
            firstSigned[entry.formHash] = min(firstSigned[entry.formHash] ?? entry.counter, entry.counter)
        }
        let counters = hashesAt.keys.sorted()
        let repeated = counters.filter { (hashesAt[$0]?.count ?? 0) > 1 }
        let signedAgain = counters.filter { counter in
            hashesAt[counter, default: []].contains { (firstSigned[$0] ?? counter) < counter }
        }
        var gaps: [ClosedRange<UInt32>] = []
        var next: UInt64 = 1
        for counter in counters {
            if UInt64(counter) > next { gaps.append(UInt32(next)...(counter - 1)) }
            next = max(next, UInt64(counter) + 1)
        }
        let coverage = merged(retiredCounters(of: keyID, in: entries, followers: followers))
        let named = merged(unkeptCounters(of: keyID, in: entries))
        var retired: [ClosedRange<UInt32>] = []
        var unkept: [ClosedRange<UInt32>] = []
        var missing: [ClosedRange<UInt32>] = []
        for gap in gaps {
            let parts = split(gap, by: coverage)
            retired += parts.inside
            for part in parts.outside {
                let rest = split(part, by: named)
                unkept += rest.inside
                missing += rest.outside
            }
        }
        let revisions = revisionReport(own)
        return EvidenceSequence(keyID: keyID, counters: counters, retired: retired, unkept: unkept, missing: missing, repeated: repeated,
                                signedAgain: signedAgain, revisionsOutOfOrder: revisions.outOfOrder,
                                missingRevisions: revisions.missing)
    }

    /// The P-256 point of the key `keyID`, from its attestation's certificate, when that certificate is for that key; nil
    /// otherwise. No chain or time is judged: the phone checks its own file's signatures with it before acting on them
    /// (item 182, codex-1 on ba2e282e), and a bundle's check judges the certification in full.
    static func publicKey(ofAttestation attestation: Data, keyID: Data) -> Data? {
        guard let object = try? EvidenceCBOR.decode(attestation),
              let leafDER = object["attStmt"]?["x5c"]?.arrayValue?.first?.bytesValue,
              let point = (try? EvidenceDER.certificate(leafDER))?.p256PublicKey,
              EvidenceHash.sha256(point) == keyID else { return nil }
        return point
    }

    /// Whether `assertion`, as App Attest returned it, signs `formHash` under the key whose point is `publicKey`.
    static func signs(_ assertion: Data, formHash: Data, publicKey: Data) -> Bool {
        guard let object = try? EvidenceCBOR.decode(assertion), let signature = object["signature"]?.bytesValue,
              let authBytes = object["authenticatorData"]?.bytesValue else { return false }
        return holds(signature, authBytes: authBytes, formHash: formHash, publicKey: publicKey)
    }

    // MARK: - Helpers

    /// Whether `signature` holds under the key whose point is `publicKey`: App Attest signs the SHA-256 of the
    /// authenticator data followed by the statement's hash.
    private static func holds(_ signature: Data, authBytes: Data, formHash: Data, publicKey: Data) -> Bool {
        let nonce = EvidenceHash.sha256(authBytes + formHash)
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(ecdsa, for: nonce)
    }

    private struct Signed: Hashable {
        let counter: UInt32
        let formHash: Data
    }

    /// Whether `chain` (the key's certificate first) holds to one of `roots` at `moment`, by the Security framework's
    /// basic X.509 rules, with no network fetch.
    private static func chainHolds(_ chain: [Data], roots: [Data], at moment: Date) -> Bool {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        let anchors = roots.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        // Every certificate given must be one: a root or chain entry that is not is not quietly left out.
        guard certificates.count == chain.count, anchors.count == roots.count else { return false }
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &made) == errSecSuccess,
              let trust = made,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(trust, moment as CFDate) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Whether a COSE key is the P-256 point `point`: EC2 (kty 2), ES256 (alg -7), P-256 (crv 1), and its x and y.
    private static func coseKey(_ key: EvidenceCBOR?, isPoint point: Data) -> Bool {
        guard let key, key[1] == .unsigned(2), key[3] == .negative(6), key[-1] == .unsigned(1),
              let x = key[-2]?.bytesValue, let y = key[-3]?.bytesValue else { return false }
        return x + y == point.dropFirst()
    }

    /// The counters of `keyID` the retention statements among `entries` name: a statement of one of `followers` may
    /// retire any, the key's own only those signed before the statement itself, and any other key's none.
    private static func retiredCounters(of keyID: Data, in entries: [EvidenceSignedEntry],
                                        followers: Set<Data>) -> [ClosedRange<UInt32>] {
        var ranges: [ClosedRange<UInt32>] = []
        for entry in entries {
            guard case .retention(let retention)? = entry.statement else { continue }
            let own = entry.keyID == keyID
            guard own || followers.contains(entry.keyID) else { continue }
            for retired in retention.retired where retired.keyID == keyID {
                for range in retired.counters {
                    guard own else {
                        ranges.append(range)
                        continue
                    }
                    if entry.counter > range.lowerBound { ranges.append(range.lowerBound...min(range.upperBound, entry.counter - 1)) }
                }
            }
        }
        return ranges
    }

    /// The counters of `keyID` its own unkept statements among `entries` name, each below the statement's own counter
    /// (item 188, ADR 0073): no other key's statement names them, a key that follows it included.
    private static func unkeptCounters(of keyID: Data, in entries: [EvidenceSignedEntry]) -> [ClosedRange<UInt32>] {
        entries.flatMap { entry -> [ClosedRange<UInt32>] in
            guard entry.keyID == keyID, case .unkept(let unkept)? = entry.statement else { return [] }
            return unkept.counters.compactMap { range in
                entry.counter > range.lowerBound ? range.lowerBound...min(range.upperBound, entry.counter - 1) : nil
            }
        }
    }

    /// Ranges sorted, with overlapping and touching ones joined: the signer keeps its keys' counters so too (item 188).
    static func merged(_ ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        var joined: [ClosedRange<UInt32>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = joined.last, UInt64(range.lowerBound) <= UInt64(last.upperBound) + 1 {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                joined.append(range)
            }
        }
        return joined
    }

    /// The parts of `gap` inside `coverage` (sorted and joined) and outside it.
    private static func split(_ gap: ClosedRange<UInt32>, by coverage: [ClosedRange<UInt32>])
        -> (inside: [ClosedRange<UInt32>], outside: [ClosedRange<UInt32>]) {
        var inside: [ClosedRange<UInt32>] = []
        var outside: [ClosedRange<UInt32>] = []
        var next = UInt64(gap.lowerBound)
        for range in coverage where range.upperBound >= gap.lowerBound && range.lowerBound <= gap.upperBound {
            let low = max(range.lowerBound, gap.lowerBound), high = min(range.upperBound, gap.upperBound)
            if UInt64(low) > next { outside.append(UInt32(next)...(low - 1)) }
            inside.append(low...high)
            next = UInt64(high) + 1
        }
        if next <= UInt64(gap.upperBound) { outside.append(UInt32(next)...gap.upperBound) }
        return (inside, outside)
    }

    /// The highest revision whose missing predecessors are listed: a genuine phone's are a handful; a statement naming
    /// more is reported only this far.
    static let revisionsListed: Int64 = 10_000

    /// Records whose revisions do not rise with their counters, and those missing a revision below their highest.
    private static func revisionReport(_ own: [EvidenceSignedEntry])
        -> (outOfOrder: [UUID], missing: [EvidenceSequence.MissingRevisions]) {
        var revisions: [UUID: [(counter: UInt32, revision: Int64)]] = [:]
        for entry in own {
            if case .record(let record)? = entry.statement {
                revisions[record.id, default: []].append((entry.counter, record.revision))
            }
        }
        var outOfOrder: [UUID] = []
        var missing: [EvidenceSequence.MissingRevisions] = []
        for (id, list) in revisions {
            let ordered = list.sorted { $0.counter < $1.counter }
            if zip(ordered, ordered.dropFirst()).contains(where: { $0.revision >= $1.revision }) { outOfOrder.append(id) }
            let present = Set(list.map(\.revision))
            let highest = max(1, min(present.max() ?? 1, revisionsListed))
            let absent = (1..<highest).filter { !present.contains($0) }
            if !absent.isEmpty { missing.append(EvidenceSequence.MissingRevisions(id: id, revisions: absent)) }
        }
        return (outOfOrder.sorted { $0.uuidString < $1.uuidString }, missing.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}
