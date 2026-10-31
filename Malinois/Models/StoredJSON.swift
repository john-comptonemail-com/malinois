import Foundation
import Darwin

/// Decodes the UTF-8 JSON written by this app's persisted-data encoders. Some older Foundation decoders
/// fatally trap while constructing keyed containers from damaged strings, before they can throw an error.
/// Validate string encoding and escapes first, then decode the original bytes with the original numeric and
/// duplicate-key behavior. Callers retain their existing quarantine, skip-line, and fail-closed policies.
enum StoredJSON {
    nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateStrings(in: data)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Preflight strings only: parsing whole objects would convert unknown numbers that Codable can skip.
    /// Writers use JSONEncoder's UTF-8 format. Bounded C searches skip large thumbnail strings efficiently
    /// even in Debug builds; no input is treated as NUL-terminated, repaired, or re-encoded.
    nonisolated private static func validateStrings(in data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw invalidString() }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var cursor = 0
            while let start = offset(of: 0x22, in: bytes, from: cursor, until: bytes.count) {
                var search = start + 1
                var end: Int?
                while let quote = offset(of: 0x22, in: bytes, from: search, until: bytes.count) {
                    var slashStart = quote
                    while slashStart > start + 1, bytes[slashStart - 1] == 0x5C { slashStart -= 1 }
                    if (quote - slashStart).isMultiple(of: 2) { end = quote; break }
                    search = quote + 1
                }
                // Incomplete structure is rejected by JSONDecoder before it constructs a keyed container.
                guard let end else { return }
                if offset(of: 0x5C, in: bytes, from: start + 1, until: end) != nil {
                    // The separate throwing parser checks escapes, surrogate pairs AND raw controls here.
                    // Discard its result; typed decoding receives the original evidence bytes.
                    let fragment = Data(bytes: base.advanced(by: start), count: end - start + 1)
                    _ = try JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed)
                } else {
                    // Without escapes, strict UTF-8 and the absence of raw controls establish string validity.
                    for control in UInt8(0)..<32 where offset(of: control, in: bytes, from: start + 1, until: end) != nil {
                        throw invalidString()
                    }
                }
                cursor = end + 1
            }
        }
    }

    /// Returns a byte offset in the raw buffer, independent of the original Data's possibly nonzero startIndex.
    nonisolated private static func offset(of byte: UInt8, in buffer: UnsafeRawBufferPointer,
                                           from start: Int, until end: Int) -> Int? {
        guard start < end, let base = buffer.baseAddress,
              let found = memchr(base.advanced(by: start), Int32(byte), end - start) else { return nil }
        return base.distance(to: UnsafeRawPointer(found))
    }

    nonisolated private static func invalidString() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Stored JSON contains a malformed UTF-8 string."))
    }
}
