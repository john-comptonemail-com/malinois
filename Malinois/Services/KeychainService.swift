//
//  KeychainService.swift
//  Malinois
//
//  Stores the disarm PIN in the Keychain as a salted PBKDF2 hash (never the PIN
//  itself), and rate-limits guessing. Hashes written before this used a single
//  salted SHA-256 round; those are verified and transparently upgraded to PBKDF2
//  on the next successful entry.
//

import Foundation
import Security
import CryptoKit
import CommonCrypto

enum KeychainService {

    private static let service = "Malinois"
    private static let account = "com.malinois.pin"
    private static let lengthAccount = "com.malinois.pin.length"
    private static let attemptsAccount = "com.malinois.pin.attempts"
    private static let lockoutAccount = "com.malinois.pin.lockout"

    private static let hashVersion: UInt8 = 2          // 1 = legacy SHA-256, 2 = PBKDF2
    private static let pbkdf2Iterations: UInt32 = 120_000
    private static let failuresBeforeLockout = 5

    // MARK: - Public API

    /// How the PIN hash reads RIGHT NOW — the distinction the lost-hash classification hangs
    /// on (found live 2026-08-30, the first day a CloudKit push could background-launch the
    /// app): the hash is stored `WhenUnlockedThisDeviceOnly`, so on a locked device — or in
    /// the unlock-transition instant of a lock-screen notification tap — the read fails with
    /// `errSecInteractionNotAllowed`. The item is SEALED, not absent. The old `hasPIN`
    /// collapsed every failure to "no PIN", and with `hasCompletedSetup` living in
    /// UserDefaults (readable while locked), a locked launch produced the exact lost-hash
    /// signature: a false "PIN unavailable" recovery screen over an intact PIN. Same class
    /// as V-01's locked event log — sealed defers; only a readable absence may classify.
    enum PINPresence { case present, absent, sealedByLock }

    static var pinPresence: PINPresence {
        let hash = readWithStatus(account: account)
        let salt = readWithStatus(account: account + ".salt")
        return Self.presence(hash: itemRead(status: hash.status, data: hash.data),
                             salt: itemRead(status: salt.status, data: salt.data))
    }

    /// One Keychain item's read outcome, with the locked-device seal kept distinct from
    /// genuine absence (V-01's discipline, now applied to every item presence consults).
    enum ItemRead: Equatable {
        case found(Data)
        case sealed
        case missing
    }

    /// Pure (unit-tested): maps a Keychain read to `ItemRead`. `errSecInteractionNotAllowed`
    /// is the locked-device seal — the item exists but cannot be judged; anything else
    /// unreadable is missing.
    nonisolated static func itemRead(status: OSStatus, data: Data?) -> ItemRead {
        if status == errSecInteractionNotAllowed { return .sealed }
        guard status == errSecSuccess, let data else { return .missing }
        return .found(data)
    }

    /// Pure (unit-tested): the presence rule, now judging STRUCTURE, not just length
    /// (seventh review, #2 + #3; legacy corrected by fourth-pass R1-M1). "Present" must
    /// mean "this PIN can actually verify":
    /// - the hash must be one of the two real shapes — a 32-byte legacy SHA-256 or a
    ///   33-byte blob carrying the current version byte. Any other shape can never verify,
    ///   and calling it present routed the owner to Home with an unwinnable pad;
    /// - BOTH generations additionally need the 16-byte salt. The legacy scheme is
    ///   SHA256(salt‖PIN) — this rule first shipped claiming legacy was salt-free, which
    ///   was false (R1-M1) and made a legacy-hash-with-lost-salt read as present. A
    ///   readable-ABSENT or malformed salt means an unwinnable pad (and the old verify
    ///   paths minted a fresh salt over the gap), so it classifies absent and routes to
    ///   the device-authenticated `.lostHash` re-setup;
    /// - a SEALED salt defers judgment entirely, exactly like a sealed hash — a locked
    ///   device must never classify (the 8372066 lesson, extended to the salt item).
    nonisolated static func presence(hash: ItemRead, salt: ItemRead) -> PINPresence {
        switch hash {
        case .sealed: return .sealedByLock
        case .missing: return .absent
        case .found(let blob):
            guard blob.count == 32 || (blob.count == 33 && blob.first == hashVersion) else { return .absent }
            switch salt {
            case .sealed: return .sealedByLock
            case .missing: return .absent
            case .found(let s): return s.count == 16 ? .present : .absent
            }
        }
    }

    /// A PIN is only "set" if the stored hash is well-formed — a 33-byte versioned PBKDF2
    /// hash or a 32-byte legacy SHA-256. A malformed/empty value (which is still non-nil)
    /// must route to recovery, not Home (N-02). A sealed hash reads false here; every caller
    /// that could ACT on absence goes through the sealed-aware classification instead.
    static var hasPIN: Bool { pinPresence == .present }

    /// Set once a PIN has ever been created on this install. If this is set but
    /// `hasPIN` is false, we're in a lost-hash state — the app must NOT fall back to
    /// an open setup flow (that would let a stranger set a new PIN); RootView gates
    /// re-setup behind device authentication instead. Survives app kills; cleared only
    /// by deleting the app (a genuine fresh install).
    private static let setupCompletedKey = "com.malinois.setupCompleted"
    static var hasCompletedSetup: Bool { UserDefaults.standard.bool(forKey: setupCompletedKey) }

    /// Pro trial start, kept in the Keychain so it survives app deletion — a reinstall can't
    /// farm a fresh trial — without needing the iCloud KVS entitlement. Deliberately NOT
    /// cleared by `wipeStalePINData` (the trial persists across a reinstall by design).
    private static let trialStartAccount = "com.malinois.trial.start"
    static var trialStart: Date? {
        guard let data = read(account: trialStartAccount),
              let text = String(data: data, encoding: .utf8),
              let ts = Double(text) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
    @discardableResult
    static func setTrialStart(_ date: Date) -> Bool {
        write(Data("\(date.timeIntervalSince1970)".utf8), account: trialStartAccount)
    }

    /// A launch state where the Keychain and the local setup flag disagree, and presenting an
    /// *unauthenticated* PIN setup would be wrong.
    enum RecoveryKind: Equatable {
        /// Setup completed before, but the hash can't be read. Re-setup, behind device auth.
        case lostHash
        /// A PIN hash exists and the event log is still on disk, but the setup flag is gone.
        /// The PIN is legitimate — repair the flag rather than destroying it.
        case lostSetupFlag
    }

    /// Pure (unit-tested). Classifies the launch state from the three observable facts.
    ///
    /// The subtle case is `hasPIN && !hasCompletedSetup`, which two very different situations
    /// produce and which must NOT be treated the same:
    ///
    /// - **Genuine fresh install.** iOS keeps Keychain items across app deletion, so a reinstall
    ///   inherits the old PIN while its container — and the setup flag — is gone. Wiping and
    ///   starting clean is correct: the evidence went with the container, so nothing is lost.
    /// - **Lost flag, surviving container.** `setPIN` writes the Keychain hash first and the
    ///   `UserDefaults` flag second, and `UserDefaults` persists asynchronously — so a crash or
    ///   OOM kill in between leaves a *legitimately set* PIN with no flag. Wiping there destroys
    ///   the owner's PIN and hands whoever holds the device an open setup screen, which then
    ///   gates the still-present event log behind a PIN of the stranger's choosing.
    ///
    /// The event log on disk is what separates them: only the second still has one.
    nonisolated static func recoveryKind(pinPresence: PINPresence, hasCompletedSetup: Bool,
                                         containerHasPriorEvents: Bool) -> RecoveryKind? {
        // A sealed hash (locked device) is unreadable, not gone — classifying blind produced
        // a false "PIN unavailable" over an intact PIN the first day a CloudKit push could
        // background-launch the app (2026-08-30). Defer; RootView re-judges after unlock.
        guard pinPresence != .sealedByLock else { return nil }
        let hasPIN = pinPresence == .present
        if !hasPIN && hasCompletedSetup { return .lostHash }
        if hasPIN && !hasCompletedSetup && containerHasPriorEvents { return .lostSetupFlag }
        return nil
    }

    /// The current launch's recovery state, if any. Nil means "proceed normally".
    static var pendingRecovery: RecoveryKind? {
        recoveryKind(pinPresence: pinPresence, hasCompletedSetup: hasCompletedSetup,
                     containerHasPriorEvents: EventStore.containerHasPriorEvents)
    }

    /// Repairs a lost setup flag once the owner has authenticated with the device passcode.
    /// The PIN hash is intact, so nothing is destroyed — the owner keeps both their PIN and
    /// their evidence.
    static func markSetupCompleted() {
        UserDefaults.standard.set(true, forKey: setupCompletedKey)
    }

    /// Clears a PIN inherited from a previous install. Only fires on a *genuine* fresh install —
    /// a PIN in the Keychain, no setup flag, and no event log on disk — so a reinstall starts
    /// clean. An app *update* keeps its container (the flag stays true), and a lost flag with a
    /// surviving log is routed to `RecoveryKind.lostSetupFlag` instead of being wiped here.
    /// Call once at launch, before `hasPIN` is read.
    static func wipeStalePINDataOnFreshInstall() {
        // Never judge a sealed Keychain (locked launch): the guards below already fail safe
        // in that state, but destruction deserves an explicit refusal, not an accidental one.
        guard pinPresence != .sealedByLock else { return }
        guard pendingRecovery == nil, !hasCompletedSetup, hasPIN else { return }
        wipeStalePINData()
    }

    /// Removes all PIN-related Keychain items (hash, salt, length, brute-force counters). Does
    /// NOT touch the trial start — that must persist across a reinstall.
    static func wipeStalePINData() {
        delete(account: account)
        delete(account: account + ".salt")
        delete(account: lengthAccount)
        delete(account: attemptsAccount)
        delete(account: lockoutAccount)
        UserDefaults.standard.removeObject(forKey: setupCompletedKey)
    }

    /// The digit-length of the stored PIN (4–6). Defaults to 4 if unset.
    static var pinLength: Int {
        guard let data = read(account: lengthAccount),
              let text = String(data: data, encoding: .utf8),
              let n = Int(text), (4...6).contains(n) else { return 4 }
        return n
    }

    /// Sets (or replaces) the PIN. Accepts 4–6 digits.
    @discardableResult
    static func setPIN(_ pin: String) -> Bool {
        guard isValidPIN(pin) else { return false }
        let hash = versionedHash(pin)
        // Refuse to store a broken hash: a PBKDF2 failure yields an empty derive, and a
        // 1-byte "[version]" hash would be unverifiable — locking the owner out forever
        // rather than failing the setup cleanly (F-21).
        guard hash.count == 33 else { return false }
        guard store(hash) else { return false }
        _ = write(Data("\(pin.count)".utf8), account: lengthAccount)
        resetAttempts()   // a fresh PIN clears any lockout
        UserDefaults.standard.set(true, forKey: setupCompletedKey)
        return true
    }

    /// Verifies a PIN and owns the whole rate-limiting contract: a locked-out attempt never
    /// verifies, and a WRONG guess is counted here — not by the caller. Counting used to
    /// live only in `PINEntryView`, which meant any future non-UI caller got unlimited
    /// guesses: the lockout check below could never fire because nothing incremented the
    /// counter (F2). The service decides; the UI only renders.
    ///
    /// Callers must NOT also call `recordFailure()` — that would double-count and escalate
    /// the lockout at twice the intended rate.
    static func verify(_ pin: String) -> Bool {
        guard lockoutRemaining() == 0 else { return false }
        guard verifyWithoutRateLimit(pin) else {
            recordFailure()          // wrong guess → cost it, whoever asked
            return false
        }
        // Success clears the counter HERE, not in the caller (seventh review, #1): the
        // failure half of the contract already lived in the service, but the success half
        // sat in PINEntryView — so any future non-UI caller that verified successfully
        // would leave stale failures standing, and SECURITY.md's "a correct PIN clears
        // everything" was a property of one screen, not of the service it names.
        resetAttempts()
        return true
    }

    /// The cryptographic check alone, with no rate-limit read or failure accounting.
    /// Split out so `verify` can own the policy and stay readable.
    private static func verifyWithoutRateLimit(_ pin: String) -> Bool {
        guard let stored = readHash() else { return false }
        if stored.count == 33, stored.first == hashVersion {
            // READ-ONLY: verification must never mint a salt (seventh review, #2). The
            // get-or-create `salt()` belongs to SETTING a PIN; here, a missing salt means
            // this hash can never verify — fail closed and leave the gap standing, so
            // `pinPresence` classifies it and routes to `.lostHash` recovery. The old path
            // minted a fresh salt over the gap, silently bricking the PIN with the
            // presence check still saying "present": no recovery route at all.
            guard let s = readSalt() else { return false }
            return constantTimeEqual(Data(stored.dropFirst()), pbkdf2(pin, salt: s))
        }
        // Legacy single-SHA hash → verify, then upgrade in place to PBKDF2. Only store
        // the upgrade if it's well-formed: a nil salt would make versionedHash empty, and
        // overwriting a valid legacy hash with that would brick the PIN (N-02). The legacy
        // hash still verifies regardless, so a failed upgrade just retries next time.
        if constantTimeEqual(stored, legacySHA(pin)) {
            let upgraded = versionedHash(pin)
            if upgraded.count == 33 { _ = store(upgraded) }
            return true
        }
        return false
    }

    static func isValidPIN(_ pin: String) -> Bool {
        let digits = CharacterSet.decimalDigits
        return (4...6).contains(pin.count) &&
            pin.unicodeScalars.allSatisfy { digits.contains($0) }
    }

    // MARK: - Brute-force rate limiting

    /// Records a failed attempt; returns the resulting lockout duration (0 if not yet
    /// locked). Persists across app restarts (stored in the Keychain) so killing the app
    /// can't reset it. The deadline is stored against the monotonic **uptime** clock, not
    /// the wall clock, so an attacker can't skip the wait by moving the device's date
    /// forward (F-09). A reboot resets uptime and thus clears the current wait — but that
    /// buys an attacker nothing: after a restart iOS requires the *device passcode* before
    /// first unlock (biometrics don't apply, and `WhenUnlockedThisDeviceOnly` keeps this
    /// item unreadable until then), and the threat model excludes an attacker who has that
    /// passcode. So a reboot is a dead end, not a rate-limit — and the count survives too.
    @discardableResult
    static func recordFailure() -> TimeInterval {
        let failures = failedAttempts + 1
        setFailedAttempts(failures)
        let delay = lockoutDelay(forFailures: failures)
        guard delay > 0 else { return 0 }
        let uptime = ProcessInfo.processInfo.systemUptime
        _ = write(Data("\(uptime + delay)|\(uptime)".utf8), account: lockoutAccount)
        return delay
    }

    /// Lockout backoff for a given cumulative failure count (pure; unit-tested).
    /// Zero below the threshold, then 30s doubling each further failure, capped at
    /// 3600s (1 hour). The cap keeps escalating rather than plateauing at 5 min, so a
    /// determined offline brute-force stays impractical (F-09): the failure count is
    /// monotonic — it can't be un-done by resetting the clock — so each further guess
    /// costs more even if an attacker skips the current wait. (Guided Access, the
    /// recommended armed config, also blocks reaching Settings to change the clock.)
    static func lockoutDelay(forFailures failures: Int) -> TimeInterval {
        guard failures >= failuresBeforeLockout else { return 0 }
        let extra = Double(failures - failuresBeforeLockout)
        return min(30.0 * pow(2.0, extra), 3600)
    }

    static func resetAttempts() {
        delete(account: attemptsAccount)
        delete(account: lockoutAccount)
    }

    /// Seconds until PIN entry is allowed again (0 if not locked out). Pure decision
    /// extracted for testing; measured against the monotonic uptime clock (F-09).
    static func lockoutRemaining() -> TimeInterval {
        guard let data = read(account: lockoutAccount),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return lockoutRemaining(stored: text, uptime: ProcessInfo.processInfo.systemUptime,
                                wallNow: Date().timeIntervalSince1970)
    }

    /// Pure (unit-tested). New format is `deadlineUptime|setUptime`; if the current uptime
    /// is below the set-uptime the device rebooted (uptime is monotonic and only resets on
    /// boot), so the stored deadline is stale → not locked. Falls back to the legacy
    /// single wall-clock epoch for a value written by an older build.
    static func lockoutRemaining(stored: String, uptime: Double, wallNow: Double) -> TimeInterval {
        let parts = stored.split(separator: "|").compactMap { Double($0) }
        if parts.count == 2 {
            let (deadline, setAt) = (parts[0], parts[1])
            if uptime < setAt - 1 { return 0 }   // uptime went backward → rebooted → stale
            return max(0, deadline - uptime)
        }
        return max(0, (parts.first ?? 0) - wallNow)   // legacy wall-clock format
    }

    private static var failedAttempts: Int {
        guard let data = read(account: attemptsAccount),
              let text = String(data: data, encoding: .utf8),
              let n = Int(text) else { return 0 }
        return n
    }

    private static func setFailedAttempts(_ n: Int) {
        _ = write(Data(String(n).utf8), account: attemptsAccount)
    }

    // MARK: - Hashing

    /// A device-stable random salt kept in the Keychain, generated once. Returns nil —
    /// rather than an all-zero or un-persisted salt — if the CSPRNG fails OR the salt
    /// can't be stored, so callers fail the operation cleanly instead of baking in a weak
    /// salt or one that the next call would silently regenerate differently (F-21).
    private static func salt() -> Data? {
        if let existing = readSalt() { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        guard storeSalt(data) else { return nil }   // couldn't persist → don't hand it back
        return data
    }

    /// A [version byte] + 32-byte PBKDF2-HMAC-SHA256 digest. Empty if the salt is
    /// unavailable — `setPIN`'s length check rejects it and `verify` fails safe.
    private static func versionedHash(_ pin: String) -> Data {
        guard let s = salt() else { return Data() }
        var d = Data([hashVersion])
        d.append(pbkdf2(pin, salt: s))
        return d
    }

    private static func pbkdf2(_ pin: String, salt saltData: Data) -> Data {
        let pinData = Data(pin.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = saltData.withUnsafeBytes { saltPtr in
            pinData.withUnsafeBytes { pinPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinPtr.baseAddress?.assumingMemoryBound(to: Int8.self), pinData.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), saltData.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    pbkdf2Iterations,
                    &derived, derived.count)
            }
        }
        return status == kCCSuccess ? Data(derived) : Data()
    }

    private static func legacySHA(_ pin: String) -> Data {
        // READ-ONLY, like the v2 path (R1-M1, same rule as seventh-review #2): verification
        // must never mint. The old get-or-create call here manufactured a fresh salt over a
        // gap and silently bricked the legacy PIN — with presence still saying "present".
        guard let s = readSalt() else { return Data() }   // no salt → empty → verify fails safe
        var hasher = SHA256()
        hasher.update(data: s)
        hasher.update(data: Data(pin.utf8))
        return Data(hasher.finalize())
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: - Keychain primitives

    private static func store(_ data: Data) -> Bool { write(data, account: account) }
    private static func readHash() -> Data? { read(account: account) }
    @discardableResult
    private static func storeSalt(_ data: Data) -> Bool { write(data, account: account + ".salt") }
    private static func readSalt() -> Data? { read(account: account + ".salt") }

    /// Test-only: removes the salt item alone, constructing the partial-corruption state of
    /// seventh-review #2 (hash intact, salt gone) so the no-mint and recovery-routing rules
    /// can be regression-tested against a live Keychain.
    static func removeSaltForTesting() { delete(account: account + ".salt") }
    /// Test-only companion: whether a salt item currently exists.
    static var saltExistsForTesting: Bool { readSalt() != nil }
    /// Test-only: installs a LEGACY 32-byte SHA256(salt‖PIN) hash — the 1.0-era format —
    /// re-creating the pre-upgrade state so R1-M1's no-mint and recovery-routing rules can
    /// be regression-tested against a live Keychain. Ensures a salt exists first, because
    /// the legacy scheme was ALWAYS salted (R1-M1's core fact); minting here is legitimate
    /// — this is a set operation, not verification.
    static func setLegacyPINForTesting(_ pin: String) -> Bool {
        guard let s = salt() else { return false }
        var hasher = SHA256()
        hasher.update(data: s)
        hasher.update(data: Data(pin.utf8))
        return write(Data(hasher.finalize()), account: account)
    }

    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Update in place; only add when the item genuinely doesn't exist. NEVER
        // delete-then-add: if the add then failed (e.g. a write attempted while the
        // device is locked → errSecInteractionNotAllowed), the old value would already
        // be gone — destroying the PIN (or resetting the brute-force counter to zero).
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    private static func read(account: String) -> Data? {
        let r = readWithStatus(account: account)
        return r.status == errSecSuccess ? r.data : nil
    }

    /// The raw read, status preserved — so presence classification can tell a SEALED item
    /// (locked device) from a missing one instead of collapsing both to nil (seventh
    /// review #2: that collapse is why a sealed salt read exactly like a lost one).
    private static func readWithStatus(account: String) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
