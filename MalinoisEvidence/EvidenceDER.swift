//
//  EvidenceDER.swift
//  MalinoisEvidence
//
//  The few parts of an X.509 certificate (DER, ITU-T X.690) that evidence checking reads itself: the certificate's
//  validity, its public key, and Apple's App Attest extension that carries the nonce. The chain's signatures are left to
//  the Security framework (SecTrust), which has no public way to read these parts on iOS. Shared by the app and the Mac
//  verifier (BACKLOG item 90).
//

import Foundation

enum EvidenceDER {
    /// One tag-length-value.
    struct Element: Equatable, Sendable {
        let tag: UInt8
        let content: Data
    }

    /// Exactly one element filling `data`; throws `EvidenceProblem.unreadable` for anything else (an indefinite or
    /// truncated length, bytes after it).
    static func element(_ data: Data) throws -> Element {
        let bytes = [UInt8](data)
        let (element, end) = try read(bytes, at: 0)
        guard end == bytes.count else { throw EvidenceProblem.unreadable("bytes after a DER element") }
        return element
    }

    /// The elements that fill `data` one after another, as a SEQUENCE's content holds them.
    static func elements(_ data: Data) throws -> [Element] {
        let bytes = [UInt8](data)
        var elements: [Element] = []
        var index = 0
        while index < bytes.count {
            let (element, end) = try read(bytes, at: index)
            elements.append(element)
            index = end
        }
        return elements
    }

    /// One extension of a certificate.
    struct Extension: Equatable, Sendable {
        let oid: [UInt64]
        let critical: Bool
        let value: Data
    }

    /// What a certificate says about itself, as its signer signed it.
    struct Certificate: Equatable, Sendable {
        let validFrom: Date
        let validUntil: Date
        /// The public key's algorithm and named curve, as object identifiers.
        let keyAlgorithm: [UInt64]
        let keyCurve: [UInt64]?
        /// The public key's bits: for an elliptic-curve key, its uncompressed point.
        let publicKey: Data
        let extensions: [Extension]

        /// The value of the extension `oid`, when the certificate has it once; nil when it has none or several.
        func extensionValue(_ oid: [UInt64]) -> Data? {
            let matches = extensions.filter { $0.oid == oid }
            return matches.count == 1 ? matches[0].value : nil
        }

        /// The public key when it is a P-256 key (App Attest's), as its 65-byte uncompressed point; nil otherwise.
        var p256PublicKey: Data? {
            guard keyAlgorithm == [1, 2, 840, 10_045, 2, 1], keyCurve == [1, 2, 840, 10_045, 3, 1, 7], publicKey.count == 65,
                  publicKey.first == 0x04 else { return nil }
            return publicKey
        }
    }

    /// Reads a certificate's validity, public key and extensions.
    static func certificate(_ der: Data) throws -> Certificate {
        let outer = try element(der)
        let parts = try elements(outer.content)
        guard outer.tag == 0x30, parts.count == 3, parts[0].tag == 0x30, parts[1].tag == 0x30, parts[2].tag == 0x03 else {
            throw EvidenceProblem.unreadable("not an X.509 certificate")
        }
        // TBSCertificate: [0] version (optional), serial, signature algorithm, issuer, validity, subject, key, then the
        // optional unique IDs and [3] extensions.
        let fields = try elements(parts[0].content)
        let at = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count >= at + 6, fields[at].tag == 0x02,
              fields[(at + 1)...(at + 5)].allSatisfy({ $0.tag == 0x30 }) else {
            throw EvidenceProblem.unreadable("a certificate without its fields")
        }
        let validity = try elements(fields[at + 3].content)
        guard validity.count == 2 else { throw EvidenceProblem.unreadable("a certificate's validity") }
        let keyInfo = try elements(fields[at + 5].content)
        guard keyInfo.count == 2, keyInfo[0].tag == 0x30, keyInfo[1].tag == 0x03 else {
            throw EvidenceProblem.unreadable("a certificate's public key")
        }
        let algorithm = try elements(keyInfo[0].content)
        guard let first = algorithm.first, first.tag == 0x06 else { throw EvidenceProblem.unreadable("a public key's algorithm") }
        let curve = algorithm.count > 1 && algorithm[1].tag == 0x06 ? try oid(algorithm[1].content) : nil
        let bits = keyInfo[1].content
        guard bits.first == 0 else { throw EvidenceProblem.unreadable("a public key with unused bits") }
        var extensions: [Extension] = []
        for field in fields[(at + 6)...] where field.tag == 0xA3 {
            let list = try element(field.content)
            guard list.tag == 0x30 else { throw EvidenceProblem.unreadable("a certificate's extensions") }
            for item in try elements(list.content) { extensions.append(try readExtension(item)) }
        }
        return Certificate(validFrom: try time(validity[0]), validUntil: try time(validity[1]), keyAlgorithm: try oid(first.content),
                           keyCurve: curve, publicKey: Data(bits.dropFirst()), extensions: extensions)
    }

    /// Apple's App Attest extension (1.2.840.113635.100.8.2): SEQUENCE { [1] EXPLICIT OCTET STRING nonce }.
    static let appAttestNonceOID: [UInt64] = [1, 2, 840, 113_635, 100, 8, 2]

    /// The 32-byte nonce in a key's certificate.
    static func appAttestNonce(in certificate: Certificate) throws -> Data {
        guard let value = certificate.extensionValue(appAttestNonceOID) else {
            throw EvidenceProblem.unreadable("no App Attest nonce in the certificate")
        }
        let sequence = try element(value)
        guard sequence.tag == 0x30 else { throw EvidenceProblem.unreadable("an App Attest nonce not in its sequence") }
        let tagged = try element(sequence.content)
        guard tagged.tag == 0xA1 else { throw EvidenceProblem.unreadable("an App Attest nonce under another tag") }
        let octets = try element(tagged.content)
        guard octets.tag == 0x04, octets.content.count == 32 else { throw EvidenceProblem.unreadable("an App Attest nonce not 32 bytes") }
        return octets.content
    }

    // MARK: - Reading

    private static func read(_ bytes: [UInt8], at start: Int) throws -> (Element, Int) {
        guard bytes.count - start >= 2 else { throw EvidenceProblem.unreadable("DER cut short") }
        let tag = bytes[start]
        guard tag & 0x1F != 0x1F else { throw EvidenceProblem.unreadable("a multi-byte DER tag") }
        var index = start + 2
        var length = Int(bytes[start + 1])
        if length >= 0x80 {
            let count = length & 0x7F
            guard (1...4).contains(count), bytes.count - index >= count else {
                throw EvidenceProblem.unreadable("an indefinite or overlong DER length")
            }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length <= bytes.count - index else { throw EvidenceProblem.unreadable("DER content cut short") }
        return (Element(tag: tag, content: Data(bytes[index..<(index + length)])), index + length)
    }

    private static func readExtension(_ item: Element) throws -> Extension {
        let parts = try elements(item.content)
        guard item.tag == 0x30, parts.count == 2 || parts.count == 3, parts[0].tag == 0x06, parts[parts.count - 1].tag == 0x04 else {
            throw EvidenceProblem.unreadable("a certificate extension")
        }
        var critical = false
        if parts.count == 3 {
            guard parts[1].tag == 0x01, parts[1].content.count == 1 else { throw EvidenceProblem.unreadable("an extension's critical flag") }
            critical = parts[1].content.first != 0
        }
        return Extension(oid: try oid(parts[0].content), critical: critical, value: parts[parts.count - 1].content)
    }

    /// An object identifier's arcs. The first byte holds the first two arcs (40 × first + second); each later arc is
    /// base 128, high bit set on every byte but its last.
    static func oid(_ content: Data) throws -> [UInt64] {
        let bytes = [UInt8](content)
        guard let first = bytes.first, first < 0x80, bytes.last.map({ $0 & 0x80 == 0 }) == true else {
            throw EvidenceProblem.unreadable("an object identifier")
        }
        var arcs: [UInt64] = first < 80 ? [UInt64(first / 40), UInt64(first % 40)] : [2, UInt64(first - 80)]
        var value: UInt64 = 0
        for byte in bytes.dropFirst() {
            guard value >> 57 == 0 else { throw EvidenceProblem.unreadable("an object identifier arc beyond 64 bits") }
            value = value << 7 | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                arcs.append(value)
                value = 0
            }
        }
        return arcs
    }

    /// UTCTime (YYMMDDHHMMSSZ, years 1950 to 2049) or GeneralizedTime (YYYYMMDDHHMMSSZ), in UTC, as X.509 writes them.
    private static func time(_ element: Element) throws -> Date {
        let width: Int
        switch element.tag {
        case 0x17: width = 2
        case 0x18: width = 4
        default: throw EvidenceProblem.unreadable("a certificate time of an unknown type")
        }
        let characters = [UInt8](element.content)
        let digits = characters.dropLast().map { Int($0) - 48 }
        guard characters.count == width + 11, characters.last == UInt8(ascii: "Z"), digits.allSatisfy({ (0...9).contains($0) }) else {
            throw EvidenceProblem.unreadable("a certificate time not in X.509's form")
        }
        func number(_ at: Int, _ count: Int) -> Int { digits[at..<(at + count)].reduce(0) { $0 * 10 + $1 } }
        var year = number(0, width)
        if width == 2 { year += year < 50 ? 2_000 : 1_900 }
        let month = number(width, 2), day = number(width + 2, 2)
        let hour = number(width + 4, 2), minute = number(width + 6, 2), second = number(width + 8, 2)
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...monthLengths[month - 1]).contains(day), hour < 24, minute < 60, second < 60 else {
            throw EvidenceProblem.unreadable("an impossible certificate time")
        }
        let seconds = daysSince1970(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days from 1970-01-01 to a date of the proleptic Gregorian calendar (Howard Hinnant's days_from_civil).
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
