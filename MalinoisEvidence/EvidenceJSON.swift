//
//  EvidenceJSON.swift
//  MalinoisEvidence
//
//  Evidence signing's fixed JSON form (BACKLOG item 90). The phone signs the SHA-256 of a statement's bytes, so a
//  statement must have exactly one spelling: objects keep their members in the order written, numbers are whole,
//  strings escape only what JSON requires, and there is no whitespace. A verifier reads bytes back only when writing
//  what it read gives the very same bytes. Shared by the app and the Mac verifier.
//

import Foundation

/// A value in evidence signing's fixed JSON form.
indirect enum EvidenceJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([EvidenceJSON])
    case object([Member])

    /// One member of an object, in its place.
    struct Member: Equatable, Sendable {
        let key: String
        let value: EvidenceJSON

        init(_ key: String, _ value: EvidenceJSON) {
            self.key = key
            self.value = value
        }
    }

    /// The deepest nesting a statement may have: a record's is three deep, a retention statement's five.
    static let maximumDepth = 8
    /// The largest statement a reader takes. A record's is under two kilobytes; anything near this is not one.
    static let maximumBytes = 1 << 20

    /// The value's fixed-form bytes: UTF-8, no whitespace, members in their order, and in strings only the quote, the
    /// backslash and the control characters escaped (the five with short escapes as `\b \f \n \r \t`, the rest as
    /// `\u00xx` in lowercase hex).
    var bytes: Data {
        var out = Data()
        write(to: &out)
        return out
    }

    /// Reads one value in the fixed form. Throws `EvidenceProblem.formNotFixed` for anything else: whitespace, another
    /// escape, a fraction or exponent, a number beyond 64 bits, a repeated key, nesting deeper than `maximumDepth`, more
    /// than `maximumBytes`, invalid UTF-8, or bytes after the value.
    init(fixedForm data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw EvidenceProblem.formNotFixed }
        var reader = Reader(bytes: Array(data))
        let value = try reader.value(depth: 1)
        // The one spelling: whatever the reader let through (bytes after the value, a raw control character, a leading
        // zero, an escaped letter), writing what it read must give the very same bytes.
        guard value.bytes == data else { throw EvidenceProblem.formNotFixed }
        self = value
    }

    /// The first member named `key`, when this is an object.
    subscript(key: String) -> EvidenceJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    // MARK: - Writing

    private func write(to out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let value): out.append(contentsOf: Array((value ? "true" : "false").utf8))
        case .int(let value): out.append(contentsOf: Array(String(value).utf8))
        case .string(let text): Self.write(text, to: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                item.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (index, member) in members.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                Self.write(member.key, to: &out)
                out.append(UInt8(ascii: ":"))
                member.value.write(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func write(_ text: String, to out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: Array(#"\u00"#.utf8))
                out.append(hexDigits[Int(scalar.value >> 4)])
                out.append(hexDigits[Int(scalar.value & 0x0F)])
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    // MARK: - Reading

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func take(_ byte: UInt8) -> Bool {
            guard peek() == byte else { return false }
            index += 1
            return true
        }

        mutating func expect(_ byte: UInt8) throws {
            guard take(byte) else { throw EvidenceProblem.formNotFixed }
        }

        mutating func value(depth: Int) throws -> EvidenceJSON {
            guard let byte = peek() else { throw EvidenceProblem.formNotFixed }
            switch byte {
            case UInt8(ascii: "{"):
                return try object(depth: depth)
            case UInt8(ascii: "["):
                return try array(depth: depth)
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .int(try integer())
            default:
                throw EvidenceProblem.formNotFixed
            }
        }

        mutating func object(depth: Int) throws -> EvidenceJSON {
            guard depth <= EvidenceJSON.maximumDepth else { throw EvidenceProblem.formNotFixed }
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            var keys = Set<String>()
            if take(UInt8(ascii: "}")) { return .object(members) }
            repeat {
                let key = try string()
                guard keys.insert(key).inserted else { throw EvidenceProblem.formNotFixed }
                try expect(UInt8(ascii: ":"))
                members.append(Member(key, try value(depth: depth + 1)))
            } while take(UInt8(ascii: ","))
            try expect(UInt8(ascii: "}"))
            return .object(members)
        }

        mutating func array(depth: Int) throws -> EvidenceJSON {
            guard depth <= EvidenceJSON.maximumDepth else { throw EvidenceProblem.formNotFixed }
            try expect(UInt8(ascii: "["))
            var items: [EvidenceJSON] = []
            if take(UInt8(ascii: "]")) { return .array(items) }
            repeat {
                items.append(try value(depth: depth + 1))
            } while take(UInt8(ascii: ","))
            try expect(UInt8(ascii: "]"))
            return .array(items)
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 { try expect(byte) }
        }

        /// A string: UTF-8, with the writer's escapes read back (the comparison with the writer's bytes refuses a raw
        /// control character and any escape the writer would not have written).
        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var collected: [UInt8] = []
            while true {
                guard let byte = peek() else { throw EvidenceProblem.formNotFixed }
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    // Invalid UTF-8 stops here; read leniently, it would fail the comparison with the writer's bytes too.
                    guard let text = String(bytes: collected, encoding: .utf8) else { throw EvidenceProblem.formNotFixed }
                    return text
                case 0x5C:
                    collected.append(try escaped())
                default:
                    collected.append(byte)
                }
            }
        }

        /// The byte an escape stands for: one of the short escapes, or `\u00` and two lowercase hex digits.
        mutating func escaped() throws -> UInt8 {
            guard let byte = peek() else { throw EvidenceProblem.formNotFixed }
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return 0x22
            case 0x5C: return 0x5C
            case UInt8(ascii: "b"): return 0x08
            case UInt8(ascii: "f"): return 0x0C
            case UInt8(ascii: "n"): return 0x0A
            case UInt8(ascii: "r"): return 0x0D
            case UInt8(ascii: "t"): return 0x09
            case UInt8(ascii: "u"):
                guard index + 4 <= bytes.count, bytes[index] == UInt8(ascii: "0"), bytes[index + 1] == UInt8(ascii: "0"),
                      let high = EvidenceJSON.hexDigits.firstIndex(of: bytes[index + 2]),
                      let low = EvidenceJSON.hexDigits.firstIndex(of: bytes[index + 3]) else { throw EvidenceProblem.formNotFixed }
                index += 4
                return UInt8(high << 4 | low)
            default:
                throw EvidenceProblem.formNotFixed
            }
        }

        /// A whole number within 64 bits (a leading zero or minus zero reads, and fails the comparison with the writer's
        /// bytes).
        mutating func integer() throws -> Int64 {
            let negative = take(UInt8(ascii: "-"))
            let start = index
            var magnitude: UInt64 = 0
            while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                let (times, overflowed) = magnitude.multipliedReportingOverflow(by: 10)
                let (sum, carried) = times.addingReportingOverflow(UInt64(byte - UInt8(ascii: "0")))
                guard !overflowed, !carried else { throw EvidenceProblem.formNotFixed }
                magnitude = sum
                index += 1
            }
            guard index > start else { throw EvidenceProblem.formNotFixed }
            let limit = UInt64(Int64.max)
            if negative {
                guard magnitude <= limit + 1 else { throw EvidenceProblem.formNotFixed }
                return magnitude == limit + 1 ? Int64.min : -Int64(magnitude)
            }
            guard magnitude <= limit else { throw EvidenceProblem.formNotFixed }
            return Int64(magnitude)
        }
    }
}
