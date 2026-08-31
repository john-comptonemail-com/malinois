//
//  KeychainServiceTests.swift
//  MalinoisTests
//

import XCTest
@testable import Malinois

final class KeychainServiceTests: XCTestCase {

    func testIsValidPINAcceptsFourToSixDigits() {
        XCTAssertTrue(KeychainService.isValidPIN("1234"))
        XCTAssertTrue(KeychainService.isValidPIN("12345"))
        XCTAssertTrue(KeychainService.isValidPIN("123456"))
    }

    func testIsValidPINRejectsBadInput() {
        XCTAssertFalse(KeychainService.isValidPIN("123"), "too short")
        XCTAssertFalse(KeychainService.isValidPIN("1234567"), "too long")
        XCTAssertFalse(KeychainService.isValidPIN("12a4"), "non-digit")
        XCTAssertFalse(KeychainService.isValidPIN(""), "empty")
    }

    func testSetVerifyRoundTripAndLength() throws {
        // Keychain writes need the app's entitlements; an unsigned test build
        // (CODE_SIGNING_ALLOWED=NO) can't use the Keychain, so skip there.
        try XCTSkipUnless(KeychainService.setPIN("4821"),
                          "Keychain unavailable in this build — round-trip skipped")
        XCTAssertTrue(KeychainService.verify("4821"))
        XCTAssertFalse(KeychainService.verify("0000"), "wrong PIN must reject")
        XCTAssertEqual(KeychainService.pinLength, 4)

        XCTAssertTrue(KeychainService.setPIN("135790"))
        XCTAssertTrue(KeychainService.verify("135790"))
        XCTAssertFalse(KeychainService.verify("4821"), "old PIN must no longer verify")
        XCTAssertEqual(KeychainService.pinLength, 6)
    }

    func testSetPINRejectsInvalidLength() {
        XCTAssertFalse(KeychainService.setPIN("12"))
        XCTAssertFalse(KeychainService.setPIN("1234567"))
    }

    /// The escalation curve, tested without touching the Keychain: nothing below
    /// the 5-failure threshold, then 30s doubling each further failure, capped 1 hour.
    func testLockoutDelayEscalationMatchesSpec() {
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 0), 0)
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 4), 0, "no lockout before threshold")
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 5), 30)
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 6), 60)
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 7), 120)
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 8), 240)
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 9), 480, "keeps escalating (F-09)")
        // F-09: the cap keeps growing to 1 hour rather than plateauing at 5 min.
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 12), 3600, "capped at 1 hour")
        XCTAssertEqual(KeychainService.lockoutDelay(forFailures: 25), 3600, "stays capped")
    }

    /// F-09: "remaining" is measured against the monotonic uptime clock, so moving the
    /// device's date forward can't skip the wait; a reboot (uptime resets) clears it.
    func testLockoutRemainingUsesUptimeNotWallClock() {
        // New format `deadlineUptime|setUptime` — a 30 s lockout set at uptime 1000.
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "1030|1000", uptime: 1010, wallNow: 0),
                       20, accuracy: 0.001)
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "1030|1000", uptime: 1040, wallNow: 0),
                       0, "expired")
        // A forward wall-clock jump is irrelevant to the new format.
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "1030|1000", uptime: 1010, wallNow: 9_999_999_999),
                       20, accuracy: 0.001)
        // Reboot: uptime fell below the set point → stale → not locked.
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "1030|1000", uptime: 5, wallNow: 0),
                       0, "a reboot clears the current wait")
        // Legacy single wall-clock epoch is still honored.
        XCTAssertEqual(KeychainService.lockoutRemaining(stored: "100", uptime: 0, wallNow: 80),
                       20, accuracy: 0.001)
    }

    func testRateLimitLocksOutAfterRepeatedFailures() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"),
                          "Keychain unavailable in this build — rate-limit test skipped")
        KeychainService.resetAttempts()
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0)

        for _ in 0..<4 { _ = KeychainService.recordFailure() }
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0, "no lockout before the threshold")

        let delay = KeychainService.recordFailure()   // 5th failure
        XCTAssertGreaterThan(delay, 0, "locked out after 5 failures")
        XCTAssertGreaterThan(KeychainService.lockoutRemaining(), 0)

        KeychainService.resetAttempts()               // a correct PIN clears it
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0)
    }

    /// F2: the rate limit must live in the SERVICE, not the UI. Driving `verify()` directly —
    /// with no view in the loop, as any future entry point would — must still engage the
    /// lockout. Before this, only `PINEntryView` counted failures, so a non-UI caller got
    /// unlimited guesses and the lockout check inside `verify` could never fire.
    func testVerifyAloneEngagesLockoutWithNoUIInvolved() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"),
                          "Keychain unavailable in this build — rate-limit test skipped")
        KeychainService.resetAttempts()
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0)

        // Brute-force straight against the service.
        for _ in 0..<5 { XCTAssertFalse(KeychainService.verify("0000")) }

        XCTAssertGreaterThan(KeychainService.lockoutRemaining(), 0,
                             "verify() must count its own failures — the service owns rate limiting")
        // Fails closed while locked out: even the CORRECT PIN is refused.
        XCTAssertFalse(KeychainService.verify("4321"),
                       "a locked-out attempt never verifies, right PIN or not")

        KeychainService.resetAttempts()
        XCTAssertTrue(KeychainService.verify("4321"), "and works again once the lockout clears")
    }

    /// Seventh review #1: SECURITY.md's "a correct PIN clears everything" must be a property
    /// of the SERVICE, like the failure-counting half already is — not of whichever screen
    /// remembered to call resetAttempts(). Sub-threshold failures, then a success, then more
    /// sub-threshold failures must never sum across the success into a lockout.
    func testVerifySuccessClearsTheFailureCounterAtTheService() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"),
                          "Keychain unavailable in this build — success-reset test skipped")
        KeychainService.resetAttempts()

        for _ in 0..<3 { _ = KeychainService.verify("0000") }      // below the 5 threshold
        XCTAssertTrue(KeychainService.verify("4321"), "correct PIN verifies below threshold")

        for _ in 0..<4 { _ = KeychainService.verify("0000") }      // 4 more — still below 5
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0,
                       "the success must have cleared the counter: 3 + 4 across it is not 7")

        KeychainService.resetAttempts()
    }

    // MARK: - Launch-state classification (M2)

    /// The dangerous state is `hasPIN && !hasCompletedSetup`, which a genuine reinstall and a
    /// crash mid-`setPIN` both produce. Treating them alike either destroys a legitimate PIN or
    /// leaves an inherited one in place; the surviving event log is what tells them apart.
    func testRecoveryKindDistinguishesFreshInstallFromLostSetupFlag() {
        // Genuine reinstall: Keychain PIN inherited, container (and its log) gone → wipe, no auth.
        XCTAssertNil(KeychainService.recoveryKind(pinPresence: .present, hasCompletedSetup: false,
                                                  containerHasPriorEvents: false),
                     "a reinstall with no surviving log is a clean start, not a recovery")

        // Crash between setPIN's Keychain write and its (async) UserDefaults flag write. The PIN
        // is real and the evidence is still there — wiping would destroy the owner's PIN and
        // hand a stranger an open setup screen over the surviving log.
        XCTAssertEqual(KeychainService.recoveryKind(pinPresence: .present, hasCompletedSetup: false,
                                                    containerHasPriorEvents: true),
                       .lostSetupFlag)

        // Setup completed but the hash is READABLY absent → re-setup, behind device auth.
        XCTAssertEqual(KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: true,
                                                    containerHasPriorEvents: true),
                       .lostHash)
        XCTAssertEqual(KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: true,
                                                    containerHasPriorEvents: false),
                       .lostHash)

        // Both agree → no recovery, either direction.
        XCTAssertNil(KeychainService.recoveryKind(pinPresence: .present, hasCompletedSetup: true,
                                                  containerHasPriorEvents: true))
        XCTAssertNil(KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: false,
                                                  containerHasPriorEvents: false))
    }

    // MARK: - A sealed Keychain never classifies (found live 2026-08-30, build 24 pair test)

    /// The hash is `WhenUnlockedThisDeviceOnly`; a CloudKit push can background-launch the
    /// app on a LOCKED device (the first live cross-device day proved it), where the read
    /// fails with `errSecInteractionNotAllowed` — sealed, not absent. Classifying that as
    /// lost-hash showed "PIN unavailable" with a reset-your-PIN auth prompt over a perfectly
    /// intact PIN. Sealed must DEFER — no recovery, no setup, judged again after unlock —
    /// the same rule V-01 pinned for the locked event log.
    func testASealedKeychainDefersClassificationEntirely() {
        for completed in [true, false] {
            for prior in [true, false] {
                XCTAssertNil(KeychainService.recoveryKind(pinPresence: .sealedByLock,
                                                          hasCompletedSetup: completed,
                                                          containerHasPriorEvents: prior),
                             "sealed(completed: \(completed), prior: \(prior)) must defer, never classify")
            }
        }
    }

    /// The read→ItemRead mapping: only the lock's own error is a seal; everything else
    /// unreadable is missing; a readable payload is found.
    func testItemReadKeepsSealDistinctFromAbsence() {
        XCTAssertEqual(KeychainService.itemRead(status: errSecInteractionNotAllowed, data: nil), .sealed,
                       "the locked-device error is a seal even with no data returned")
        XCTAssertEqual(KeychainService.itemRead(status: errSecItemNotFound, data: nil), .missing)
        XCTAssertEqual(KeychainService.itemRead(status: errSecSuccess, data: nil), .missing,
                       "success with no payload is still nothing to judge")
        XCTAssertEqual(KeychainService.itemRead(status: errSecSuccess, data: Data([1])), .found(Data([1])))
    }

    /// Seventh review #2 + #3: "present" must mean "this PIN can actually verify" — the
    /// rule judges structure (version byte, salt), not just length, and the seal defers
    /// judgment for the SALT item exactly as it always did for the hash.
    func testPresenceJudgesStructureNotJustLength() {
        let v2 = Data([2]) + Data(repeating: 7, count: 32)     // current version byte
        let wrongVersion = Data([9]) + Data(repeating: 7, count: 32)
        let legacy = Data(repeating: 7, count: 32)
        let salt = Data(repeating: 1, count: 16)

        XCTAssertEqual(KeychainService.presence(hash: .found(v2), salt: .found(salt)), .present)
        XCTAssertEqual(KeychainService.presence(hash: .found(legacy), salt: .missing), .absent,
                       "legacy is SHA256(salt‖PIN) — no salt, no verify (R1-M1); recovery, not Home")
        XCTAssertEqual(KeychainService.presence(hash: .found(legacy), salt: .found(salt)), .present,
                       "a legacy hash with its salt intact verifies — present")
        XCTAssertEqual(KeychainService.presence(hash: .found(legacy), salt: .sealed), .sealedByLock,
                       "a sealed salt defers judgment for legacy exactly as for v2 (V-01)")
        XCTAssertEqual(KeychainService.presence(hash: .found(legacy), salt: .found(Data([1, 2]))), .absent,
                       "a malformed salt bricks a legacy hash the same as a missing one")
        XCTAssertEqual(KeychainService.presence(hash: .found(wrongVersion), salt: .found(salt)), .absent,
                       "a 33-byte blob with an unknown version byte can never verify — recovery, not Home")
        XCTAssertEqual(KeychainService.presence(hash: .found(Data([2, 3])), salt: .found(salt)), .absent,
                       "malformed routes to recovery, not Home (N-02)")
        XCTAssertEqual(KeychainService.presence(hash: .found(v2), salt: .missing), .absent,
                       "a v2 hash with no salt is unverifiable forever — it must route to .lostHash recovery")
        XCTAssertEqual(KeychainService.presence(hash: .found(v2), salt: .found(Data([1, 2]))), .absent,
                       "a malformed salt is the same brick as a missing one")
        XCTAssertEqual(KeychainService.presence(hash: .found(v2), salt: .sealed), .sealedByLock,
                       "a sealed salt defers judgment — a locked device must never classify (V-01)")
        XCTAssertEqual(KeychainService.presence(hash: .sealed, salt: .missing), .sealedByLock)
        XCTAssertEqual(KeychainService.presence(hash: .missing, salt: .found(salt)), .absent)
    }

    /// The live half of seventh-review #2, against a real Keychain: with the hash intact and
    /// the salt gone, a verify attempt must fail WITHOUT minting a fresh salt over the gap
    /// (the old path did — silently bricking the PIN), and presence must classify absent so
    /// the device-authenticated `.lostHash` recovery engages instead of an unwinnable pad.
    func testLostSaltFailsClosedWithoutMintingAndRoutesToRecovery() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"),
                          "Keychain unavailable in this build — salt regression skipped")
        KeychainService.resetAttempts()
        XCTAssertTrue(KeychainService.verify("4821"), "sanity: the fresh PIN verifies")

        KeychainService.removeSaltForTesting()
        XCTAssertFalse(KeychainService.verify("4821"), "no salt → nothing can verify")
        XCTAssertFalse(KeychainService.saltExistsForTesting,
                       "verification must NOT have minted a fresh salt over the gap")
        XCTAssertEqual(KeychainService.pinPresence, .absent,
                       "hash-without-salt classifies absent, so recoveryKind routes to .lostHash")

        // Recovery's own path still works: setting a PIN mints a new salt legitimately.
        XCTAssertTrue(KeychainService.setPIN("4821"))
        XCTAssertTrue(KeychainService.saltExistsForTesting)
        XCTAssertTrue(KeychainService.verify("4821"))
        KeychainService.resetAttempts()
    }

    /// R1-M1 (fourth pass, reviews 1+3 convergent): the LEGACY twin of the test above. The
    /// 1.0-era hash is SHA256(salt‖PIN) — salted, despite what this suite used to assert —
    /// so a lost salt must fail closed WITHOUT the old get-or-create path minting a fresh
    /// salt over the gap, and presence must classify absent so `.lostHash` recovery engages
    /// instead of an unwinnable pad.
    func testLegacyLostSaltFailsClosedWithoutMintingAndRoutesToRecovery() throws {
        try XCTSkipUnless(KeychainService.setLegacyPINForTesting("4821"),
                          "Keychain unavailable in this build — legacy salt regression skipped")
        KeychainService.resetAttempts()
        XCTAssertTrue(KeychainService.verify("4821"), "sanity: the legacy PIN verifies with its salt")
        // A successful legacy verify upgrades the hash to v2 in place — re-install the
        // legacy fixture so the state under test is the pre-upgrade one.
        XCTAssertTrue(KeychainService.setLegacyPINForTesting("4821"))

        KeychainService.removeSaltForTesting()
        XCTAssertFalse(KeychainService.verify("4821"), "no salt → a legacy hash can't verify either")
        XCTAssertFalse(KeychainService.saltExistsForTesting,
                       "legacy verification must NOT have minted a fresh salt over the gap (R1-M1)")
        XCTAssertEqual(KeychainService.pinPresence, .absent,
                       "legacy-hash-without-salt classifies absent → .lostHash recovery, not an unwinnable pad")

        // Recovery's own path still works: setting a PIN mints a new salt legitimately.
        XCTAssertTrue(KeychainService.setPIN("4821"))
        XCTAssertTrue(KeychainService.verify("4821"))
        KeychainService.resetAttempts()
    }
}
