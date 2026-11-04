//
//  EvidenceHash.swift
//  MalinoisEvidence
//
//  The hashes evidence signing uses (BACKLOG item 90): SHA-256 of bytes and of files, written in the fixed forms as
//  lowercase hex. Shared by the app and the Mac verifier.
//

import CryptoKit
import Foundation

enum EvidenceHash {
    /// SHA-256 of `data`.
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// The SHA-256 and length of bytes held in memory: a thumbnail, a sensor trace's bytes.
    static func digest(of data: Data) -> EvidenceForm.Digest {
        EvidenceForm.Digest(sha256: sha256(data), bytes: Int64(data.count))
    }

    /// The SHA-256 and length of the file at `url`, read a megabyte at a time, so a long clip is never held in memory
    /// whole.
    static func digest(ofFileAt url: URL) throws -> EvidenceForm.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        // The end of the file comes back as nil here; an empty piece is taken as the end too, so that a system that
        // answers with one cannot loop forever.
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
            count += Int64(piece.count)
        }
        return EvidenceForm.Digest(sha256: Data(hasher.finalize()), bytes: count)
    }

    /// Lowercase hex, as the fixed forms write hashes and key IDs.
    static func hex(_ data: Data) -> String {
        var text = ""
        text.reserveCapacity(data.count * 2)
        for byte in data {
            text.unicodeScalars.append(digits[Int(byte >> 4)])
            text.unicodeScalars.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// The bytes that lowercase hex spells; nil for an odd length or any other character, uppercase hex included, so
    /// each value has one spelling.
    static func bytes(hex text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = value(of: characters[index]), let low = value(of: characters[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static let digits = Array("0123456789abcdef".unicodeScalars)

    private static func value(of digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
