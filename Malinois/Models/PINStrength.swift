//
//  PINStrength.swift
//  Malinois
//
//  The easy-to-guess PIN check for setup and PIN changes (item 106).
//

import Foundation

/// Pure (unit-tested; item 106): whether a PIN is among the first an intruder would try. Setup and
/// Change PIN warn on these and offer "Use Anyway"; nothing is blocked. The rules cover the
/// patterns studies of real PINs find most common: one repeated digit, a run up or down in steps
/// of 1 or 2, a repeated pair or half, doubled digits, a mirror image, a year from 1900 to 2039,
/// and keypad lines and other well-known choices. Dates are not checked: they are a large share of
/// all 4-digit PINs, and a warning on so many would teach people to ignore it.
enum PINStrength {
    static func isEasilyGuessed(_ pin: String) -> Bool {
        let digits = pin.compactMap(\.wholeNumberValue)
        guard digits.count == pin.count, (4...6).contains(digits.count) else { return false }
        return isRun(digits) || repeatsWithPeriod(digits) || isDoubled(digits)
            || digits == digits.reversed() || isYear(digits) || wellKnown.contains(pin)
    }

    /// One digit repeated, or a constant step of 1 or 2 either way: 1111, 1234, 9876, 1357.
    private static func isRun(_ digits: [Int]) -> Bool {
        let step = digits[1] - digits[0]
        guard abs(step) <= 2 else { return false }
        return zip(digits, digits.dropFirst()).allSatisfy { $1 - $0 == step }
    }

    /// A repeated pair or half, when the length is a multiple of it: 1212, 121212, 123123.
    private static func repeatsWithPeriod(_ digits: [Int]) -> Bool {
        [2, 3].contains { period in
            digits.count > period && digits.count.isMultiple(of: period)
                && (period..<digits.count).allSatisfy { digits[$0] == digits[$0 - period] }
        }
    }

    /// Each digit doubled: 1122, 112233.
    private static func isDoubled(_ digits: [Int]) -> Bool {
        digits.count.isMultiple(of: 2)
            && stride(from: 0, to: digits.count, by: 2).allSatisfy { digits[$0] == digits[$0 + 1] }
    }

    /// A year from 1900 to 2039: the birth and anniversary years people choose.
    private static func isYear(_ digits: [Int]) -> Bool {
        digits.count == 4 && (1900...2039).contains(digits.reduce(0) { $0 * 10 + $1 })
    }

    /// Keypad lines and shapes, and other choices that lists of common PINs show.
    private static let wellKnown: Set<String> = [
        "2580", "0852", "1470", "0741", "3690", "0963", "1379", "9731", "1004",
        "147258", "258369", "369258", "852741", "147852", "741852", "963852",
        "159753", "159357", "753951", "789456", "456123", "102030"
    ]
}
