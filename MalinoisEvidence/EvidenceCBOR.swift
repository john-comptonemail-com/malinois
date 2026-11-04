//
//  EvidenceCBOR.swift
//  MalinoisEvidence
//
//  The CBOR (RFC 8949) that Apple's App Attest writes: a key's attestation, each signature (an "assertion"), the key
//  inside an attestation, and Apple's extensions. Only the subset App Attest uses is read, and strictly: definite lengths
//  only, no floating-point values or tags, no repeated map key, bounded depth, and nothing after the value. Shared by the
//  app and the Mac verifier (BACKLOG item 90).
//

import Foundation

/// A CBOR value.
indirect enum EvidenceCBOR: Equatable, Sendable {
    case unsigned(UInt64)
    /// The value -1 - n.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([EvidenceCBOR])
    case map([Pair])
    /// false (20), true (21), null (22), undefined (23).
    case simple(UInt8)

    /// One entry of a map, in its place.
    struct Pair: Equatable, Sendable {
        let key: EvidenceCBOR
        let value: EvidenceCBOR
    }

    /// The deepest nesting a reader takes: App Attest's is three deep.
    static let maximumDepth = 16

    /// Reads exactly one value from `data`; throws `EvidenceProblem.unreadable` for anything else.
    static func decode(_ data: Data) throws -> EvidenceCBOR {
        let (value, length) = try decodePrefix(data)
        guard length == data.count else { throw EvidenceProblem.unreadable("bytes after a CBOR value") }
        return value
    }

    /// Reads one value at the start of `data`, and how many bytes it took: the key inside an attestation's
    /// authenticator data, which Apple's extensions follow.
    static func decodePrefix(_ data: Data) throws -> (value: EvidenceCBOR, length: Int) {
        var reader = Reader(bytes: Array(data))
        let value = try reader.item(depth: 1)
        return (value, reader.index)
    }

    /// The value under a text key, when this is a map.
    subscript(key: String) -> EvidenceCBOR? { value(for: .text(key)) }

    /// The value under a whole-number key (COSE's keys), when this is a map.
    subscript(key: Int) -> EvidenceCBOR? {
        value(for: key >= 0 ? .unsigned(UInt64(key)) : .negative(UInt64(-1 - key)))
    }

    var bytesValue: Data? {
        guard case .bytes(let data) = self else { return nil }
        return data
    }

    var textValue: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }

    var arrayValue: [EvidenceCBOR]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    var unsignedValue: UInt64? {
        guard case .unsigned(let value) = self else { return nil }
        return value
    }

    private func value(for key: EvidenceCBOR) -> EvidenceCBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func byte() throws -> UInt8 {
            guard index < bytes.count else { throw EvidenceProblem.unreadable("CBOR cut short") }
            index += 1
            return bytes[index - 1]
        }

        /// The argument after an initial byte: its count, length or value.
        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24:
                return UInt64(info)
            case 24, 25, 26, 27:
                var value: UInt64 = 0
                for _ in 0..<(1 << Int(info - 24)) { value = value << 8 | UInt64(try byte()) }
                return value
            default:
                throw EvidenceProblem.unreadable("an indefinite or reserved CBOR length")
            }
        }

        mutating func take(_ count: UInt64) throws -> [UInt8] {
            guard count <= UInt64(bytes.count - index) else { throw EvidenceProblem.unreadable("a CBOR string longer than its data") }
            let end = index + Int(count)
            defer { index = end }
            return Array(bytes[index..<end])
        }

        mutating func item(depth: Int) throws -> EvidenceCBOR {
            let initial = try byte()
            let info = initial & 0x1F
            switch initial >> 5 {
            case 0:
                return .unsigned(try argument(info))
            case 1:
                return .negative(try argument(info))
            case 2:
                return .bytes(Data(try take(try argument(info))))
            case 3:
                guard let text = String(bytes: try take(try argument(info)), encoding: .utf8) else {
                    throw EvidenceProblem.unreadable("CBOR text that is not UTF-8")
                }
                return .text(text)
            case 4:
                let count = try container(info, depth: depth)
                var items: [EvidenceCBOR] = []
                for _ in 0..<count { items.append(try item(depth: depth + 1)) }
                return .array(items)
            case 5:
                let count = try container(info, depth: depth)
                var pairs: [Pair] = []
                for _ in 0..<count {
                    let key = try item(depth: depth + 1)
                    guard !pairs.contains(where: { $0.key == key }) else { throw EvidenceProblem.unreadable("a repeated CBOR map key") }
                    pairs.append(Pair(key: key, value: try item(depth: depth + 1)))
                }
                return .map(pairs)
            case 7:
                return .simple(try simple(info))
            default:
                throw EvidenceProblem.unreadable("a CBOR tag")
            }
        }

        /// An array's or map's count, within the depth limit. A count larger than the bytes left fails at the first
        /// item past them.
        mutating func container(_ info: UInt8, depth: Int) throws -> UInt64 {
            guard depth <= EvidenceCBOR.maximumDepth else { throw EvidenceProblem.unreadable("CBOR nested too deep") }
            return try argument(info)
        }

        mutating func simple(_ info: UInt8) throws -> UInt8 {
            switch info {
            case 0..<24:
                return info
            case 24:
                let value = try byte()
                guard value >= 32 else { throw EvidenceProblem.unreadable("a CBOR simple value in the wrong form") }
                return value
            default:
                throw EvidenceProblem.unreadable("a CBOR floating-point value or break")
            }
        }
    }
}
