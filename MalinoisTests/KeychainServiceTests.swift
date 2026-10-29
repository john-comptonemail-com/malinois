//
//  KeychainServiceTests.swift
//  MalinoisTests
//

import XCTest
@testable import Malinois

@MainActor
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

    /// A valid PIN is protected regardless of whether any local files survived reinstall.
    func testRecoveryKindPreservesPINAcrossReinstallAndLostSetupFlag() {
        // Genuine reinstall: inherit the PIN; require it before resuming local access.
        XCTAssertEqual(KeychainService.recoveryKind(pinPresence: .present, hasCompletedSetup: false,
                                                    containerHasPriorEvents: false), .lostSetupFlag,
                       "a surviving PIN protects access even after reinstall")

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

    /// Only explicit not-found means absence; all unreadable storage defers classification.
    func testItemReadKeepsSealDistinctFromAbsence() {
        XCTAssertEqual(KeychainService.itemRead(status: errSecInteractionNotAllowed, data: nil), .sealed,
                       "the locked-device error is a seal even with no data returned")
        XCTAssertEqual(KeychainService.itemRead(status: errSecItemNotFound, data: nil), .missing)
        XCTAssertEqual(KeychainService.itemRead(status: errSecSuccess, data: nil), .sealed,
                       "success without a readable payload must defer")
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

    /// Membership survives even explicit test-only credential cleanup.
    func testEarlyAccessMarkerRoundTripsAndSurvivesThePINWipe() throws {
        KeychainService.clearEarlyAccessMemberForTesting()
        XCTAssertFalse(KeychainService.earlyAccessMember)
        try XCTSkipUnless(KeychainService.markEarlyAccessMember(),
                          "Keychain unavailable in this build — round-trip skipped")
        defer { KeychainService.clearEarlyAccessMemberForTesting() }
        XCTAssertTrue(KeychainService.earlyAccessMember)
        XCTAssertTrue(KeychainService.markEarlyAccessMember(), "marking twice is a no-op, not a failure")
        KeychainService.wipeStalePINData()
        XCTAssertTrue(KeychainService.earlyAccessMember, "test-only credential cleanup does not affect membership")
    }

    func testPriorEvidenceWithoutSetupMarkerRequiresRecovery() {
        XCTAssertEqual(KeychainService.recoveryKind(pinPresence: .absent, hasCompletedSetup: false,
                                                    containerHasPriorEvents: true), .lostHash)
    }

    func testUnexpectedKeychainErrorsDeferClassification() {
        for status in [errSecNotAvailable, errSecAuthFailed, errSecDecode, errSecParam] {
            XCTAssertEqual(KeychainService.itemRead(status: status, data: nil), .sealed)
        }
        XCTAssertEqual(KeychainService.presence(hash: .missing, salt: .sealed), .sealedByLock)
        XCTAssertEqual(KeychainService.presence(hash: .found(Data()), salt: .sealed), .sealedByLock)
    }

    /// Setting a new PIN clears the old lockout: the owner, who has just authenticated to set it,
    /// is not locked out of the new PIN by the old one's failures (test-suite audit, KC23).
    func testANewPINClearsTheOldLockout() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer { KeychainService.resetAttempts() }
        for _ in 0..<5 { _ = KeychainService.recordFailure() }
        XCTAssertGreaterThan(KeychainService.lockoutRemaining(), 0, "locked out")
        XCTAssertTrue(KeychainService.setPIN("1357"))
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0, "the new PIN starts unlocked")
        XCTAssertTrue(KeychainService.verify("1357"))
    }

    /// A correct PIN against a hash in the old format (one SHA-256) upgrades it in place to the
    /// current one (PBKDF2), so an install from before 1.0's change does not keep the weaker
    /// hash for good (test-suite audit, KC26).
    func testACorrectPINUpgradesALegacyHash() throws {
        try XCTSkipUnless(KeychainService.setLegacyPINForTesting("4821"), "Keychain unavailable")
        defer { KeychainService.resetAttempts() }
        KeychainService.resetAttempts()
        XCTAssertEqual(KeychainService.storedHashLengthForTesting, 32, "the old format")
        XCTAssertTrue(KeychainService.verify("4821"))
        XCTAssertEqual(KeychainService.storedHashLengthForTesting, 33, "upgraded to the current format")
        XCTAssertTrue(KeychainService.verify("4821"), "and it still verifies")
    }

    func testKeychainReadFailureCannotReplacePINOrMutateLockout() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer {
            KeychainService.readStatusForTesting = nil
            KeychainService.resetAttempts()
        }
        for _ in 0..<4 { _ = KeychainService.recordFailure() }
        KeychainService.readStatusForTesting = errSecNotAvailable
        XCTAssertFalse(KeychainService.setPIN("1357"))
        XCTAssertFalse(KeychainService.verify("4821"))
        KeychainService.readStatusForTesting = nil
        XCTAssertEqual(KeychainService.lockoutRemaining(), 0, "an unreadable PIN is not a wrong guess")
        XCTAssertGreaterThan(KeychainService.recordFailure(), 0, "failed replacement preserves four failures")
        KeychainService.resetAttempts()
        XCTAssertTrue(KeychainService.verify("4821"), "the original credential survives")
        XCTAssertFalse(KeychainService.verify("1357"))
    }

    func testPriorLocalEvidenceIncludesJournalAndMediaWithoutLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(KeychainService.hasPriorLocalEvidence(in: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertFalse(KeychainService.hasPriorLocalEvidence(in: root))
        for relative in ["events.json", "events.journal", "Media/clip.mov", "MediaAttachments/intent.json"] {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("preserved".utf8).write(to: file)
            XCTAssertTrue(KeychainService.hasPriorLocalEvidence(in: root), relative)
            try FileManager.default.removeItem(at: file)
        }
    }

    @MainActor
    func testResetRequiresAuthenticationAndCancellationKeepsPIN() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer { KeychainService.resetAttempts() }
        let permission = PINResetPermission()
        XCTAssertFalse(permission.savePIN("1357"))
        XCTAssertFalse(permission.authenticationFinished(success: false))
        XCTAssertFalse(permission.savePIN("1357"))
        XCTAssertTrue(KeychainService.verify("4821"))
        XCTAssertTrue(permission.authenticationFinished(success: true))
        permission.revoke()
        XCTAssertFalse(permission.savePIN("1357"), "background/cancel revokes the permission")
        XCTAssertTrue(KeychainService.verify("4821"))
        XCTAssertFalse(PINResetPermission().authorized, "permission does not survive recreation")
    }

    @MainActor
    func testAuthenticatedReplacementPreservesOldPINOnWriteFailure() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer {
            KeychainService.failWritesForTesting = false
            KeychainService.resetAttempts()
        }
        let permission = PINResetPermission()
        XCTAssertTrue(permission.authenticationFinished(success: true))
        KeychainService.failWritesForTesting = true
        XCTAssertFalse(permission.savePIN("1357"))
        KeychainService.failWritesForTesting = false
        XCTAssertTrue(KeychainService.verify("4821"), "old PIN survives a refused replacement")
        XCTAssertTrue(permission.savePIN("1357"))
        XCTAssertFalse(permission.authorized, "successful replacement consumes permission")
        XCTAssertTrue(KeychainService.verify("1357"))
        XCTAssertFalse(KeychainService.verify("4821"))
    }

    @MainActor
    func testUnreadableStorageCannotGrantOrUseResetPermission() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer { KeychainService.readStatusForTesting = nil; KeychainService.resetAttempts() }
        let permission = PINResetPermission()
        KeychainService.readStatusForTesting = errSecInteractionNotAllowed
        XCTAssertFalse(permission.authenticationFinished(success: true))
        KeychainService.readStatusForTesting = nil
        XCTAssertTrue(permission.authenticationFinished(success: true))
        KeychainService.readStatusForTesting = errSecAuthFailed
        XCTAssertFalse(permission.savePIN("1357"))
        XCTAssertFalse(permission.authorized)
        XCTAssertFalse(KeychainService.markSetupCompleted())
        KeychainService.readStatusForTesting = nil
        XCTAssertTrue(KeychainService.verify("4821"))
    }

    func testExistingPINRepairsMarkerAndKeepsSurvivingLockout() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer { KeychainService.markSetupCompleted(); KeychainService.resetAttempts() }
        UserDefaults.standard.removeObject(forKey: "com.malinois.setupCompleted")
        for _ in 0..<5 { _ = KeychainService.recordFailure() }
        XCTAssertEqual(KeychainService.pendingRecovery, .lostSetupFlag)
        XCTAssertFalse(KeychainService.verify("4821"), "reinstall does not clear a lockout")
        XCTAssertFalse(KeychainService.hasCompletedSetup)
        KeychainService.resetAttempts() // represent waiting for the existing deadline
        XCTAssertTrue(KeychainService.verify("4821"))
        XCTAssertTrue(KeychainService.markSetupCompleted())
        XCTAssertTrue(KeychainService.hasCompletedSetup)
        XCTAssertTrue(KeychainService.verify("4821"))
    }

    func testFreshStoreBookkeepingDoesNotRequireRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("seen.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("restore-owed.json"))
        XCTAssertFalse(KeychainService.hasPriorLocalEvidence(in: root))
    }

    func testDamagedCredentialFragmentsStillRequireRecoveryWithoutMarker() throws {
        try XCTSkipUnless(KeychainService.setPIN("4821"), "Keychain unavailable")
        defer { _ = KeychainService.setPIN("4821"); KeychainService.resetAttempts() }
        KeychainService.removeSaltForTesting()
        UserDefaults.standard.removeObject(forKey: "com.malinois.setupCompleted")
        XCTAssertEqual(KeychainService.pinPresence, .absent)
        XCTAssertEqual(KeychainService.pendingRecovery, .lostHash)
    }

    // MARK: - Item 152's hardening (f) (1.8.2's step 12): the suite's own Keychain service

    /// The suite sets and clears PINs, lockouts and the Early-Access membership. On a developer's own iPhone the test host
    /// shares the installed app's Keychain items, so the suite keeps its own service: an item it writes is not under the
    /// app's. This test only reads the app's service, never writes or deletes there. Red at the step's red commit: the
    /// marker it planted was under the app's service. The marker is read back from the suite's own service first, so a
    /// Keychain refusing writes cannot pass the test by finding nothing anywhere (Codex's note on step 12).
    func testTheSuitesKeychainItemsAreNotTheInstalledApps() throws {
        let marker = String(Double(Int.random(in: 1_000_000...9_999_999)))   // a time no real entry carries
        KeychainService.writeLastEntryForTesting(marker)
        defer { KeychainService.removeLastEntryForTesting() }
        try XCTSkipUnless(KeychainService.lastCorrectEntry != nil, "Keychain unavailable in this build")
        XCTAssertEqual(KeychainService.lastCorrectEntry?.timeIntervalSince1970, Double(marker),
                       "the marker is in the suite's own service")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Malinois",
                                    kSecAttrAccount as String: "com.malinois.pin.lastEntry",
                                    kSecReturnData as String: true]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        let stored = (found as? Data).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertFalse(status == errSecSuccess && stored == marker, "the suite wrote under the installed app's service")
    }

    /// The installed app keeps the service it always had; a test run takes its own.
    func testTheAppKeepsItsServiceAndTheSuiteTakesItsOwn() {
        XCTAssertEqual(KeychainService.serviceName(testRunner: false), "Malinois")
        XCTAssertNotEqual(KeychainService.serviceName(testRunner: true), "Malinois")
    }

    // MARK: - Item 153's MAL-14 (a) (1.8.2's step 5): no false "Wrong PIN" record

    /// A lockout in force compares no PIN: the entry is not checked, so it is no wrong guess, the count does not move
    /// and the armed pad records nothing, even when the pad's ticker had not yet shown the lockout. Red at the step's
    /// red commit: every refusal read as a wrong guess, and the armed pad recorded one.
    func testALockoutInForceChecksNoPINAndRecordsNothing() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"), "Keychain unavailable in this build")
        defer { KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.resetAttempts()
        for _ in 0..<5 { _ = KeychainService.recordFailure() }
        XCTAssertEqual(KeychainService.verifyEntry("0000"), .notChecked)
        XCTAssertEqual(KeychainService.verifyEntry("4321"), .notChecked, "while locked, not even the right PIN is checked")
        XCTAssertFalse(PINEntryView.recordsAttempt(.notChecked))
        XCTAssertEqual(KeychainService.failedAttemptsValueForTesting, "5", "the count did not move")
    }

    /// A sealed Keychain (the phone locked, the item unreadable) compares no PIN either: not checked, not counted, not
    /// recorded.
    func testASealedKeychainChecksNoPINAndRecordsNothing() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"), "Keychain unavailable in this build")
        defer { KeychainService.readStatusForTesting = nil; KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.resetAttempts()
        KeychainService.readStatusForTesting = -25308   // errSecInteractionNotAllowed: sealed
        XCTAssertEqual(KeychainService.verifyEntry("0000"), .notChecked)
        KeychainService.readStatusForTesting = nil
        XCTAssertNil(KeychainService.failedAttemptsValueForTesting, "nothing was counted")
    }

    /// A real wrong guess is counted and recorded, and the right PIN is neither: the rule the two tests above narrow.
    func testARealWrongGuessIsCountedAndRecorded() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"), "Keychain unavailable in this build")
        defer { KeychainService.resetAttempts(); KeychainService.wipeStalePINData() }
        KeychainService.resetAttempts()
        XCTAssertEqual(KeychainService.verifyEntry("0000"), .wrong)
        XCTAssertTrue(PINEntryView.recordsAttempt(.wrong))
        XCTAssertEqual(KeychainService.failedAttemptsValueForTesting, "1")
        XCTAssertEqual(KeychainService.verifyEntry("4321"), .correct)
        XCTAssertFalse(PINEntryView.recordsAttempt(.correct))
    }
}
