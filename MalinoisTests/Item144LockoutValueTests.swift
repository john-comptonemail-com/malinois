//
//  Item144LockoutValueTests.swift
//  MalinoisTests
//
//  BACKLOG 144 (b) and (f), from a reader's audit (2026-10-21; the owner's "sure"). (f) A damaged lockout value in the
//  Keychain used to read as "not locked" (garbage) or could lock the pad for good (an absurd deadline): a stored value
//  is now well-formed only in the two shapes the app writes, the remaining wait is bounded by the longest lockout, and
//  the live read replaces a damaged value with a fresh deadline from the failure count. (b) The lockout's comment no
//  longer claims an offline defence: it slows guessing on the phone itself.
//

import XCTest
@testable import Malinois

@MainActor
final class Item144LockoutValueTests: XCTestCase {

    // MARK: - (f) The pure rule

    /// Well-formed: two finite numbers, the deadline at or after its set time and at most the longest wait ahead, or
    /// one finite legacy wall-clock epoch, zero or more and at most the longest wait past the clock (item 155's A4:
    /// a legacy deadline far in the future used to read as the longest wait on every read, for good). Everything
    /// else is damage.
    func testAStoredLockoutValueIsWellFormedOnlyInTheTwoShapes() {
        let now = 1_760_000_000.0
        for good in ["1030|1000", "1000|1000", "4600|1000", "100", "0", "1760000000.5", "1760003600"] {
            XCTAssertTrue(KeychainService.lockoutValueIsWellFormed(good, wallNow: now), good)
        }
        for bad in ["", "garbage", "inf|0", "1030|inf", "nan|nan", "1030|1000|5", "1000|1030", "4601|1000", "-5", "1e400",
                    "|", "1030|", "|1000", " 1030|1000", "1760003601", "90000000000"] {
            XCTAssertFalse(KeychainService.lockoutValueIsWellFormed(bad, wallNow: now), bad)
        }
    }

    /// The wait can never exceed the longest lockout, whatever the stored numbers say.
    func testTheRemainingWaitIsBoundedByTheLongestLockout() {
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "100000|1000", uptime: 1000, wallNow: 0), 3600,
                       accuracy: 0.001)
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "90000000000", uptime: 0, wallNow: 1_000_000), 3600,
                       accuracy: 0.001)
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "1030|1000", uptime: 1010, wallNow: 0), 20,
                       accuracy: 0.001, "a normal wait is unchanged")
    }

    // MARK: - (f) The live path, against a real Keychain

    private func lockOutWithFiveFailures() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"), "Keychain unavailable in this build")
        KeychainService.resetAttempts()
        for _ in 0..<5 { _ = KeychainService.recordFailure() }
        KeychainService.clearMirroredLockoutForTesting()   // the in-process copy would mask the stored damage
    }

    /// Five failures, then the stored deadline replaced by garbage: the pad is locked for the five-failure wait, the
    /// stored value is well-formed again, and the wait ends as the uptime passes it.
    func testADamagedLockoutValueLocksThePadForTheRightTime() throws {
        try lockOutWithFiveFailures()
        defer { KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.writeLockoutValueForTesting("garbage")
        XCTAssertEqual(KeychainService.lockoutRemaining(), 30, accuracy: 1, "locked for the five-failure wait, not 0")
        let repaired = try XCTUnwrap(KeychainService.lockoutValueForTesting)
        XCTAssertTrue(KeychainService.lockoutValueIsWellFormed(repaired, wallNow: Date().timeIntervalSince1970), repaired)
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: repaired, uptime: ProcessInfo.processInfo.systemUptime + 31,
                                                        wallNow: 0), 0, "the wait ends as the uptime passes it")
    }

    /// An absurd deadline, years ahead, is damage too: the right wait, not a pad locked for good.
    func testAnAbsurdDeadlineIsReplacedNotHonoured() throws {
        try lockOutWithFiveFailures()
        defer { KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.writeLockoutValueForTesting("99999999|1000")
        XCTAssertEqual(KeychainService.lockoutRemaining(), 30, accuracy: 1)
    }

    /// Below the threshold there is nothing to lock: the damaged value is removed and the pad is open.
    func testADamagedLockoutValueBelowTheThresholdIsRemoved() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"), "Keychain unavailable in this build")
        defer { KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.resetAttempts()
        for _ in 0..<2 { _ = KeychainService.recordFailure() }
        KeychainService.writeLockoutValueForTesting("inf|0")
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0, accuracy: 0.001)
        XCTAssertNil(KeychainService.lockoutValueForTesting, "the damaged value is gone")
    }

    // MARK: - (a) The lockout's state on the main actor

    /// The in-process mirrors of the failure count and the deadline, and the functions that read or write them, are
    /// main-actor isolated, so the compiler holds what used to be a promise in a comment (the reader's point 5). The
    /// isolation has no run-time form, so this test reads the source; the build is the real check. The two Debug-only
    /// test switches the Keychain primitives read keep their `nonisolated(unsafe)`, and nothing else does.
    func testTheLockoutsStateIsMainActorIsolated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Malinois/Services/KeychainService.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("@MainActor private static var mirroredFailures"), "the failure count's mirror")
        XCTAssertTrue(source.contains("@MainActor private static var mirroredLockout"), "the deadline's mirror")
        for function in ["static func verify(", "static func recordFailure(", "static func resetAttempts(",
                         "static func lockoutRemaining() ->", "static func setPIN("] {
            XCTAssertTrue(source.contains("@MainActor\n    " + function), "\(function) is main-actor isolated")
        }
        XCTAssertEqual(source.components(separatedBy: "nonisolated(unsafe)").count - 1, 2,
                       "only the two Debug-only test switches keep nonisolated(unsafe)")
        XCTAssertFalse(source.contains("nonisolated(unsafe) private static var mirrored"))
    }

    // MARK: - (b) The comment

    /// The lockout slows guessing on the phone itself; it is no offline defence (the reader's point 8), and the comment
    /// on `lockoutDelay` says so. A comment has no run-time form, so this test reads the source.
    func testTheLockoutsCommentClaimsNoOfflineDefence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Malinois/Services/KeychainService.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("offline brute-force"), "the comment on lockoutDelay still claims an offline defence")
        XCTAssertTrue(source.contains("guessing on the phone itself stays impractical"))
    }

    // MARK: - Item 155's A4 (step 22): a legacy deadline far in the future is damage too

    /// Codex's P5. A legacy single-number value whose deadline lies years ahead is not a lockout anyone set: it is
    /// repaired from the failure count like other damage, and the repaired wait ends. Red at the step's red commit:
    /// the value read as the longest wait on every read, for good.
    func testAnAbsurdLegacyDeadlineIsRepairedAndExpires() throws {
        try lockOutWithFiveFailures()
        defer { KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.writeLockoutValueForTesting("90000000000")
        XCTAssertEqual(KeychainService.lockoutRemaining(), 30, accuracy: 1, "the five-failure wait, not the longest")
        let repaired = try XCTUnwrap(KeychainService.lockoutValueForTesting)
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: repaired, uptime: ProcessInfo.processInfo.systemUptime + 3601,
                                                        wallNow: Date().timeIntervalSince1970 + 3601), 0, "and it ends")
    }
}
