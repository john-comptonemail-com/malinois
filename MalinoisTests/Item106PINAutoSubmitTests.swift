//
//  Item106PINAutoSubmitTests.swift
//  MalinoisTests
//
//  BACKLOG 106 (1.6; owner ruling 2026-10-12, "add both with 4 as the default"). A user asked for
//  the PIN to submit itself. The pad now submits once the PIN's length is typed, as the iPhone's
//  passcode does; every such entry is verified exactly like the explicit submit, so it counts
//  toward the lockout and, on the armed pad, the wrong-PIN record. The length used is one
//  confirmed by a successful PIN change or entry: older builds stored the length without checking
//  the write, and a stale length would submit early and lock the owner out. Without a confirmed
//  length the pad shows the explicit submit. New PINs are 4 digits by default, 6 available, and a
//  PIN among the easiest to guess draws a warning. Written before the change, red at that commit
//  (against compile-only stubs).
//

import XCTest
@testable import Malinois

@MainActor
final class Item106PINAutoSubmitTests: XCTestCase {

    // MARK: - The pad

    /// The entry pad submits at the confirmed length only; without one it waits for the explicit
    /// submit. Setup keeps submitting at its fixed length.
    func testTheEntryPadSubmitsAtTheConfirmedLengthOnly() {
        func submits(_ count: Int, auto: Int?, conceal: Bool = true, max: Int = 6) -> Bool {
            PINPad.submitsAutomatically(count: count, maxLength: max, conceal: conceal, autoSubmitLength: auto)
        }
        XCTAssertFalse(submits(3, auto: 4))
        XCTAssertTrue(submits(4, auto: 4), "a 4-digit PIN submits at the 4th digit")
        XCTAssertFalse(submits(4, auto: 6))
        XCTAssertTrue(submits(6, auto: 6), "a 6-digit PIN submits at the 6th digit")
        XCTAssertTrue(submits(5, auto: 5), "an existing 5-digit PIN submits at the 5th digit")
        XCTAssertFalse(submits(6, auto: nil), "no confirmed length: the explicit submit, as before")
        XCTAssertTrue(submits(4, auto: nil, conceal: false, max: 4), "setup advances at its fixed length")
    }

    /// The explicit submit key shows only when the length is not confirmed.
    func testTheSubmitKeyShowsOnlyWithoutAConfirmedLength() {
        XCTAssertTrue(PINPad.showsSubmitKey(conceal: true, autoSubmitLength: nil))
        XCTAssertFalse(PINPad.showsSubmitKey(conceal: true, autoSubmitLength: 4))
        XCTAssertFalse(PINPad.showsSubmitKey(conceal: true, autoSubmitLength: 6))
        XCTAssertFalse(PINPad.showsSubmitKey(conceal: false, autoSubmitLength: nil), "setup has no submit key")
    }

    /// New PINs are 4 digits by default, with 6 available.
    func testNewPINsDefaultToFourDigitsWithSixAvailable() {
        XCTAssertEqual(PINSetupView.defaultLength, 4)
        XCTAssertEqual(PINSetupView.allowedLengths, [4, 6])
    }

    // MARK: - The confirmed length (live Keychain)

    /// Each PIN set records its length as confirmed, including an existing 5-digit PIN's.
    func testTheConfirmedLengthFollowsEachNewPIN() throws {
        KeychainService.wipeStalePINData()
        defer { KeychainService.wipeStalePINData() }
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable in this build — skipped")
        XCTAssertEqual(KeychainService.confirmedPINLength, 4)
        XCTAssertTrue(KeychainService.setPIN("135790"))
        XCTAssertEqual(KeychainService.confirmedPINLength, 6)
        XCTAssertTrue(KeychainService.setPIN("13579"))
        XCTAssertEqual(KeychainService.confirmedPINLength, 5)
    }

    /// A PIN change that fails part-way leaves no confirmed length rather than a stale one, so the
    /// pad falls back to the explicit submit; the next successful entry confirms the length again.
    func testAFailedPINChangeLeavesNoStaleLength() throws {
        KeychainService.wipeStalePINData()
        defer {
            KeychainService.failWritesForTesting = false
            KeychainService.wipeStalePINData()
        }
        try XCTSkipUnless(KeychainService.setPIN("135790"), "Keychain unavailable in this build — skipped")
        KeychainService.failWritesForTesting = true
        XCTAssertFalse(KeychainService.setPIN("4821"), "the PIN write is refused")
        KeychainService.failWritesForTesting = false
        XCTAssertNil(KeychainService.confirmedPINLength, "never the new PIN's 4 while the old 6-digit PIN remains")
        XCTAssertTrue(KeychainService.verify("135790"), "the old PIN still works")
        XCTAssertEqual(KeychainService.confirmedPINLength, 6, "a successful entry confirms the length again")
    }

    /// The length older builds stored is not trusted on its own: until an entry succeeds, the pad
    /// waits for the explicit submit.
    func testALegacyStoredLengthAloneDoesNotDriveAutoSubmit() throws {
        KeychainService.wipeStalePINData()
        defer { KeychainService.wipeStalePINData() }
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable in this build — skipped")
        KeychainService.removeConfirmedLengthForTesting()
        XCTAssertEqual(KeychainService.pinLength, 4, "the older stored length is still there")
        XCTAssertNil(KeychainService.confirmedPINLength)
        XCTAssertFalse(KeychainService.verify("0000"))
        XCTAssertNil(KeychainService.confirmedPINLength, "a wrong entry confirms nothing")
        XCTAssertTrue(KeychainService.verify("4821"))
        XCTAssertEqual(KeychainService.confirmedPINLength, 4)
    }

    // MARK: - The easy-to-guess warning

    /// The PINs an intruder tries first are flagged: repeats, runs, repeated pairs and halves,
    /// keypad lines, years, and other well-known choices.
    func testEasyToGuessPINsAreFlagged() {
        let easy = ["0000", "1111", "1234", "4321", "0123", "6789", "1212", "1010", "6969", "1122", "2580",
                    "0852", "1470", "1357", "2468", "1984", "2001", "2025", "1004",
                    "000000", "123456", "654321", "012345", "111111", "121212", "123123", "112233",
                    "520520", "147258", "159753", "789456", "123321"]
        for pin in easy {
            XCTAssertTrue(PINStrength.isEasilyGuessed(pin), "\(pin) should draw the warning")
        }
    }

    /// Ordinary PINs pass without a warning.
    func testOrdinaryPINsAreNotFlagged() {
        for pin in ["4831", "7294", "3071", "8526", "582917", "305846", "927163", "61408"] {
            XCTAssertFalse(PINStrength.isEasilyGuessed(pin), "\(pin) should pass")
        }
    }
}
