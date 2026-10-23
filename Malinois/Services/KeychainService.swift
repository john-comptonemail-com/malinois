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
    /// The length the pad auto-submits at, confirmed by a successful PIN change or entry (item 106).
    private static let confirmedLengthAccount = "com.malinois.pin.confirmedLength"
    private static let attemptsAccount = "com.malinois.pin.attempts"
    private static let lockoutAccount = "com.malinois.pin.lockout"
    /// When the PIN was last entered correctly or set (ADR 0054): seconds since 1970, as text.
    private static let lastEntryAccount = "com.malinois.pin.lastEntry"
    /// The enrolled-biometrics state Face ID or Touch ID unlock was bound to when the owner turned it on (ADR 0056).
    private static let biometricStateAccount = "com.malinois.biometric.enrolledState"

    private static let hashVersion: UInt8 = 2          // 1 = legacy SHA-256, 2 = PBKDF2
    private static let pbkdf2Iterations: UInt32 = 120_000
    private static let failuresBeforeLockout = 5

    // MARK: - Public API

    /// Whether the credential can be judged right now. `sealedByLock` is the historical
    /// name for an unresolved read: locked storage, unexpected errors, and missing payloads
    /// all defer setup/recovery. None is evidence that the owner has no PIN.
    enum PINPresence { case present, absent, sealedByLock }

    static var pinPresence: PINPresence {
        guard rateLimitReadable else { return .sealedByLock }
        let length = readWithStatus(account: lengthAccount)
        guard itemRead(status: length.status, data: length.data) != .sealed else { return .sealedByLock }
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

    /// Maps only an explicit item-not-found result to absence. Other unreadable results
    /// defer judgment; callers of the shared ItemRead type must never mint over a seal.
    nonisolated static func itemRead(status: OSStatus, data: Data?) -> ItemRead {
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data else { return .sealed }
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
        // Either sealed component vetoes classification, even if the other is absent.
        if hash == .sealed || salt == .sealed { return .sealedByLock }
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
    /// The trial start as a three-way read (item 65, finding 13): found, SEALED by the lock,
    /// or missing. `trialStart` above collapses the seal to nil — right for a display, wrong
    /// for a decision that mints a start from "nothing there".
    static var trialStartRead: ItemRead {
        let r = readWithStatus(account: trialStartAccount)
        return itemRead(status: r.status, data: r.data)
    }
    @discardableResult
    static func setTrialStart(_ date: Date) -> Bool {
        write(Data("\(date.timeIntervalSince1970)".utf8), account: trialStartAccount)
    }

    /// Early-Access membership (BACKLOG 66, owner ruling 2026-09-04): an install that first ran
    /// while the program was open has Pro permanently. Kept in the Keychain so it survives
    /// deletion, and — unlike the trial start — as a **synchronizable** item, so iCloud Keychain
    /// carries it to the owner's next phone: the promise is to the person, not the device. If the
    /// synchronizable write is refused (no iCloud Keychain, a managed profile), it falls back to
    /// a device-only item so the promise at least holds here. Never cleared by
    /// `wipeStalePINData`; never cleared at all outside tests — a promise, once made, is kept.
    private static let earlyAccessAccount = "com.malinois.earlyAccess"
    static var earlyAccessMember: Bool {
        guard let data = readAny(account: earlyAccessAccount) else { return false }
        return String(data: data, encoding: .utf8) == "1"
    }
    @discardableResult
    static func markEarlyAccessMember() -> Bool {
        let value = Data("1".utf8)
        return writeSynchronizable(value, account: earlyAccessAccount) || write(value, account: earlyAccessAccount)
    }
    #if DEBUG
    /// Test-only: the marker is never cleared by the app.
    static func clearEarlyAccessMemberForTesting() {
        delete(account: earlyAccessAccount, synchronizable: true)
        delete(account: earlyAccessAccount)
    }
    #endif

    /// A launch state where the Keychain and the local setup flag disagree, and presenting an
    /// *unauthenticated* PIN setup would be wrong.
    enum RecoveryKind: Equatable {
        /// Setup completed before, but the hash can't be read. Re-setup, behind device auth.
        case lostHash
        /// A valid PIN survives but the setup flag is gone, including after reinstall.
        /// The PIN is legitimate — repair the flag rather than destroying it.
        case lostSetupFlag
    }

    /// Classifies local access without guessing whether missing files mean reinstall.
    /// Any surviving valid PIN must be verified and kept; known prior evidence without a
    /// usable PIN requires device-owner recovery. Unresolved storage never means fresh setup.
    nonisolated static func recoveryKind(pinPresence: PINPresence, hasCompletedSetup: Bool,
                                         containerHasPriorEvents: Bool) -> RecoveryKind? {
        guard pinPresence != .sealedByLock else { return nil }
        if pinPresence == .absent && (hasCompletedSetup || containerHasPriorEvents) { return .lostHash }
        if pinPresence == .present && !hasCompletedSetup { return .lostSetupFlag }
        return nil
    }

    /// Observes all local evidence, including journals, quarantined logs and media attachment
    /// intents, without creating files. Empty folders do not count. Inspection errors or
    /// symbolic links conservatively require recovery, rather than authorize fresh setup.
    static func hasPriorLocalEvidence(in root: URL) -> Bool {
        do {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return true }
            for child in try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                // EventStore creates these bookkeeping markers even on a genuinely new
                // install, before RootView appears. They are not recorded evidence.
                if ["seen.json", "restore-owed.json"].contains(child.lastPathComponent) { continue }
                let kind = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if kind.isSymbolicLink == true || kind.isDirectory != true { return true }
                if hasPriorLocalEvidence(in: child) { return true }
            }
            return false
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        } catch {
            return true
        }
    }

    /// Current local recovery state. Nil with an unresolved PIN still requires deferral.
    static var pendingRecovery: RecoveryKind? {
        recoveryKind(pinPresence: pinPresence, hasCompletedSetup: hasCompletedSetup,
                     containerHasPriorEvents: EventStore.containerHasPriorEvents || priorPINArtifacts)
    }

    /// Even damaged credential fragments demonstrate a previous PIN, despite lost markers.
    private static var priorPINArtifacts: Bool {
        [account, account + ".salt", lengthAccount, confirmedLengthAccount, attemptsAccount,
         lockoutAccount].contains { name in
            let result = readWithStatus(account: name)
            if case .found = itemRead(status: result.status, data: result.data) { return true }
            return false
        }
    }

    /// Repairs setup after successful existing-PIN verification. Refuses unresolved or
    /// absent credentials; it never replaces the PIN or clears its lockout on its own.
    @discardableResult
    static func markSetupCompleted() -> Bool {
        guard pinPresence == .present else { return false }
        UserDefaults.standard.set(true, forKey: setupCompletedKey)
        return hasCompletedSetup
    }

    #if DEBUG
    /// Test-fixture cleanup only. Production has no automatic credential-wipe path.
    /// Does not remove trial or Early-Access membership.
    @MainActor
    static func wipeStalePINData() {
        mirroredFailures = 0
        mirroredLockout = nil
        delete(account: account)
        delete(account: account + ".salt")
        delete(account: lengthAccount)
        delete(account: confirmedLengthAccount)
        delete(account: attemptsAccount)
        delete(account: lockoutAccount)
        delete(account: lastEntryAccount)
        delete(account: biometricStateAccount)
        UserDefaults.standard.removeObject(forKey: setupCompletedKey)
    }

    /// Test-only (ADR 0054): plants the stored time of the last correct entry, as text, or removes it.
    static func writeLastEntryForTesting(_ text: String) { _ = write(Data(text.utf8), account: lastEntryAccount) }
    static func removeLastEntryForTesting() { delete(account: lastEntryAccount) }
    #endif

    /// When the PIN was last entered correctly or set (ADR 0054), or nil when none is on record or the stored value is
    /// unreadable or not a finite time, either of which makes the ARM tap ask: the safe direction. This device only,
    /// readable while the phone is unlocked, like the lockout's deadline.
    static var lastCorrectEntry: Date? {
        guard let data = read(account: lastEntryAccount),
              let text = String(data: data, encoding: .utf8),
              let seconds = Double(text), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Records a correct entry now (ADR 0054): every successful `verify`, and every PIN set. Best effort: a refused
    /// write leaves the older time, and the next ARM tap may ask once more.
    private static func noteCorrectEntry() {
        write(Data(String(Date().timeIntervalSince1970).utf8), account: lastEntryAccount)
    }

    /// The enrolled-biometrics state the unlock is bound to (ADR 0056), nil when none is on record. This device only,
    /// readable while the phone is unlocked, like the lockout's deadline.
    static var enrolledBiometricState: Data? { read(account: biometricStateAccount) }

    /// Binds the unlock to `state` (ADR 0056): the state iOS reports when Settings turns the unlock on. False when the
    /// write is refused, in which case the unlock is unbound and the pad's first offer turns it off again.
    @discardableResult
    static func recordEnrolledBiometricState(_ state: Data) -> Bool { write(state, account: biometricStateAccount) }

    /// Clears the binding (ADR 0056): the unlock turned off, by Settings or by the pad.
    static func clearEnrolledBiometricState() { delete(account: biometricStateAccount) }

    /// The PIN's length as confirmed by a successful PIN change or entry (item 106): the pad
    /// auto-submits at it. Nil when unconfirmed, unreadable or out of range, and the pad then
    /// waits for the explicit submit. Never taken from `pinLength`, which builds before 1.6
    /// wrote without checking the write: a stale length would submit early and lock the owner out.
    static var confirmedPINLength: Int? {
        guard let data = read(account: confirmedLengthAccount),
              let text = String(data: data, encoding: .utf8),
              let length = Int(text), (4...6).contains(length) else { return nil }
        return length
    }

    /// Records `length` as confirmed. Best effort: a failed write leaves it unconfirmed, and the
    /// pad shows the explicit submit until the next successful entry.
    private static func confirmLength(_ length: Int) {
        guard confirmedPINLength != length else { return }
        write(Data("\(length)".utf8), account: confirmedLengthAccount)
    }

    #if DEBUG
    /// Test-only: removes the confirmed length alone, as after an upgrade from a build before 1.6.
    static func removeConfirmedLengthForTesting() { delete(account: confirmedLengthAccount) }
    #endif

    /// The digit-length of the stored PIN (4–6). Defaults to 4 if unset. Not used to
    /// auto-submit: see `confirmedPINLength` (item 106).
    static var pinLength: Int {
        guard let data = read(account: lengthAccount),
              let text = String(data: data, encoding: .utf8),
              let n = Int(text), (4...6).contains(n) else { return 4 }
        return n
    }

    /// Sets (or replaces) the PIN. Accepts 4–6 digits. Main-actor isolated: it clears the lockout (item 144's point 5).
    @discardableResult
    @MainActor
    static func setPIN(_ pin: String) -> Bool {
        guard isValidPIN(pin), pinPresence != .sealedByLock else { return false }
        let hash = versionedHash(pin)
        // Refuse to store a broken hash: a PBKDF2 failure yields an empty derive, and a
        // 1-byte "[version]" hash would be unverifiable — locking the owner out forever
        // rather than failing the setup cleanly (F-21).
        guard hash.count == 33 else { return false }
        // Unconfirm the length before the PIN changes (item 106): if anything below fails, the
        // pad waits for the explicit submit instead of submitting at the old PIN's length.
        delete(account: confirmedLengthAccount)
        guard read(account: confirmedLengthAccount) == nil else { return false }
        guard store(hash) else { return false }
        _ = write(Data("\(pin.count)".utf8), account: lengthAccount)
        confirmLength(pin.count)
        noteCorrectEntry()   // a PIN just chosen is a PIN remembered (ADR 0054)
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
    @MainActor
    static func verify(_ pin: String) -> Bool {
        guard pinPresence == .present, rateLimitReadable, lockoutRemaining() == 0 else { return false }
        guard let verified = verifyWithoutRateLimit(pin) else { return false }
        guard verified else {
            recordFailure()          // wrong guess → cost it, whoever asked
            return false
        }
        // Success clears the counter HERE, not in the caller (seventh review, #1): the
        // failure half of the contract already lived in the service, but the success half
        // sat in PINEntryView — so any future non-UI caller that verified successfully
        // would leave stale failures standing, and SECURITY.md's "a correct PIN clears
        // everything" was a property of one screen, not of the service it names.
        resetAttempts()
        confirmLength(pin.count)   // the pad may now auto-submit at it (item 106)
        noteCorrectEntry()   // the ARM tap's check counts from here (ADR 0054)
        return true
    }

    /// The cryptographic check alone, with no rate-limit read or failure accounting.
    /// Split out so `verify` can own the policy and stay readable.
    private static func verifyWithoutRateLimit(_ pin: String) -> Bool? {
        let hash = readWithStatus(account: account)
        let salt = readWithStatus(account: account + ".salt")
        let hashRead = itemRead(status: hash.status, data: hash.data)
        let saltRead = itemRead(status: salt.status, data: salt.data)
        guard hashRead != .sealed, saltRead != .sealed else { return nil }
        guard case .found(let stored) = hashRead, case .found(let s) = saltRead else { return false }
        if stored.count == 33, stored.first == hashVersion {
            // READ-ONLY: verification must never mint a salt (seventh review, #2). The
            // get-or-create `salt()` belongs to SETTING a PIN; here, a missing salt means
            // this hash can never verify — fail closed and leave the gap standing, so
            // `pinPresence` classifies it and routes to `.lostHash` recovery. The old path
            // minted a fresh salt over the gap, silently bricking the PIN with the
            // presence check still saying "present": no recovery route at all.
            return constantTimeEqual(Data(stored.dropFirst()), pbkdf2(pin, salt: s))
        }
        // Legacy single-SHA hash → verify, then upgrade in place to PBKDF2. Only store
        // the upgrade if it's well-formed: a nil salt would make versionedHash empty, and
        // overwriting a valid legacy hash with that would brick the PIN (N-02). The legacy
        // hash still verifies regardless, so a failed upgrade just retries next time.
        var legacy = SHA256()
        legacy.update(data: s)
        legacy.update(data: Data(pin.utf8))
        if constantTimeEqual(stored, Data(legacy.finalize())) {
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
    @MainActor
    static func recordFailure() -> TimeInterval {
        let failures = failedAttempts + 1
        setFailedAttempts(failures)
        let delay = lockoutDelay(forFailures: failures)
        guard delay > 0 else { return 0 }
        let uptime = ProcessInfo.processInfo.systemUptime
        let deadline = "\(uptime + delay)|\(uptime)"
        mirroredLockout = deadline   // held in-process whatever the Keychain accepts (item 73, R10)
        _ = write(Data(deadline.utf8), account: lockoutAccount)
        return delay
    }

    /// In-process mirror of the brute-force state (item 73, review 1 R10). A Keychain write
    /// that fails leaves the stored count and deadline where they were, so a run of failed
    /// guesses against a Keychain refusing writes never engaged the lockout — rate limiting
    /// failed open on a storage fault. The mirror keeps the count and the deadline for the
    /// life of the process; each read takes the stricter of the two, the Keychain stays the
    /// durable copy, and a correct PIN clears both. Main-actor isolated, with every function that
    /// reads or writes them (item 144's point 5): every caller is a PIN pad or the engine, and the
    /// compiler now holds what used to be a promise in this comment.
    @MainActor private static var mirroredFailures = 0
    @MainActor private static var mirroredLockout: String?

    /// Lockout backoff for a given cumulative failure count (pure; unit-tested).
    /// Zero below the threshold, then 30s doubling each further failure, capped at
    /// `maxLockoutDelay` (1 hour). The cap keeps escalating rather than plateauing at 5 min, so
    /// guessing on the phone itself stays impractical (F-09; item 144's point 8: no key derivation
    /// protects a 4-digit PIN offline, and this wait makes no such claim): the failure count is
    /// monotonic — it can't be un-done by resetting the clock — so each further guess
    /// costs more even if an attacker skips the current wait. (Guided Access, the
    /// recommended armed config, also blocks reaching Settings to change the clock.)
    static func lockoutDelay(forFailures failures: Int) -> TimeInterval {
        guard failures >= failuresBeforeLockout else { return 0 }
        let extra = Double(failures - failuresBeforeLockout)
        return min(30.0 * pow(2.0, extra), maxLockoutDelay)
    }

    /// The longest wait a lockout can impose; a stored deadline further ahead than this is damage (item 144's F3).
    static let maxLockoutDelay: TimeInterval = 3600

    @MainActor
    static func resetAttempts() {
        mirroredFailures = 0
        mirroredLockout = nil
        delete(account: attemptsAccount)
        delete(account: lockoutAccount)
    }

    /// Seconds until PIN entry is allowed again (0 if not locked out). Pure decision
    /// extracted for testing; measured against the monotonic uptime clock (F-09).
    @MainActor
    static func lockoutRemaining() -> TimeInterval {
        var stored = read(account: lockoutAccount).flatMap { String(data: $0, encoding: .utf8) }
        let uptime = ProcessInfo.processInfo.systemUptime
        let wallNow = Date().timeIntervalSince1970
        if let value = stored, !lockoutValueIsWellFormed(value, wallNow: wallNow) {
            // Damage (item 144's F3): a fresh deadline from the failure count, so the pad is locked for
            // the right time, neither not at all (garbage read as 0) nor for good (an absurd deadline).
            stored = repairLockout(uptime: uptime)
        }
        // The stricter of the durable copy and the in-process mirror (item 73, R10).
        return [stored, mirroredLockout].compactMap { $0 }
            .map { lockoutRemaining(stored: $0, uptime: uptime, wallNow: wallNow) }
            .max() ?? 0
    }

    /// Replaces a damaged lockout value with the deadline the stored failure count earns, written as
    /// `recordFailure` writes one and mirrored when nothing is mirrored yet; below the threshold there is
    /// nothing to lock, so the damaged value is removed. Returns the new stored value, or nil.
    @MainActor
    private static func repairLockout(uptime: Double) -> String? {
        let delay = lockoutDelay(forFailures: failedAttempts)
        guard delay > 0 else {
            delete(account: lockoutAccount)
            return nil
        }
        let deadline = "\(uptime + delay)|\(uptime)"
        if mirroredLockout == nil { mirroredLockout = deadline }
        _ = write(Data(deadline.utf8), account: lockoutAccount)
        return deadline
    }

    /// Pure (unit-tested; item 144's F3). Whether a stored lockout value is one this app could have written: two
    /// finite numbers `deadline|setAt` with the deadline at or after its set time and at most `maxLockoutDelay`
    /// ahead, or one finite legacy wall-clock epoch, zero or more and at most `maxLockoutDelay` past `wallNow` (a legacy
    /// deadline far ahead read as the longest wait on every read, for good: item 155's A4). Anything else is damage, and `lockoutRemaining()`
    /// replaces it with a fresh deadline from the failure count rather than reading it as "not locked" (garbage
    /// fell through to the legacy branch and gave 0) or as locked for good (an absurd deadline).
    nonisolated static func lockoutValueIsWellFormed(_ stored: String, wallNow: Double) -> Bool {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false).map { Double($0) }
        switch parts.count {
        case 2:
            guard let deadline = parts[0], let setAt = parts[1], deadline.isFinite, setAt.isFinite else { return false }
            return deadline >= setAt && deadline - setAt <= maxLockoutDelay
        case 1:
            guard let epoch = parts[0], epoch.isFinite else { return false }
            return epoch >= 0 && epoch - wallNow <= maxLockoutDelay   // a deadline past the longest wait is damage (item 155's A4)
        default:
            return false
        }
    }

    /// Pure (unit-tested). New format is `deadlineUptime|setUptime`; if the current uptime
    /// is below the set-uptime the device rebooted (uptime is monotonic and only resets on
    /// boot), so the stored deadline is stale → not locked. Falls back to the legacy
    /// single wall-clock epoch for a value written by an older build. Bounded by
    /// `maxLockoutDelay` (item 144's F3): the live read repairs a damaged value first, and
    /// this bound holds for whatever reaches it, the in-process mirror included.
    static func lockoutRemaining(stored: String, uptime: Double, wallNow: Double) -> TimeInterval {
        let parts = stored.split(separator: "|").compactMap { Double($0) }
        if parts.count == 2 {
            let (deadline, setAt) = (parts[0], parts[1])
            if uptime < setAt - 1 { return 0 }   // uptime went backward → rebooted → stale
            return min(max(0, deadline - uptime), maxLockoutDelay)
        }
        return min(max(0, (parts.first ?? 0) - wallNow), maxLockoutDelay)   // legacy wall-clock format
    }

    private static var rateLimitReadable: Bool {
        [attemptsAccount, lockoutAccount].allSatisfy { name in
            let result = readWithStatus(account: name)
            return itemRead(status: result.status, data: result.data) != .sealed
        }
    }

    @MainActor
    private static var failedAttempts: Int {
        let stored: Int
        if let data = read(account: attemptsAccount),
           let text = String(data: data, encoding: .utf8),
           let n = Int(text) { stored = n } else { stored = 0 }
        return max(stored, mirroredFailures)   // a refused write cannot lower the count (item 73, R10)
    }

    @MainActor
    private static func setFailedAttempts(_ n: Int) {
        mirroredFailures = n
        _ = write(Data(String(n).utf8), account: attemptsAccount)
    }

    // MARK: - Hashing

    /// A device-stable random salt kept in the Keychain, generated once. Returns nil —
    /// rather than an all-zero or un-persisted salt — if the CSPRNG fails OR the salt
    /// can't be stored, so callers fail the operation cleanly instead of baking in a weak
    /// salt or one that the next call would silently regenerate differently (F-21).
    private static func salt() -> Data? {
        let result = readWithStatus(account: account + ".salt")
        switch itemRead(status: result.status, data: result.data) {
        case .sealed: return nil
        case .found(let existing) where existing.count == 16: return existing
        case .found, .missing: break
        }
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

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: - Keychain primitives

    private static func store(_ data: Data) -> Bool { write(data, account: account) }
    @discardableResult
    private static func storeSalt(_ data: Data) -> Bool { write(data, account: account + ".salt") }
    private static func readSalt() -> Data? { read(account: account + ".salt") }

    #if DEBUG
    // Test seams: Debug-only so they don't ship in the Release binary (ninth review,
    // R2-F2). XCTest builds the Debug configuration, so the live-Keychain regression
    // tests keep compiling.

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
    /// Test-only: the stored hash's length, 32 for the legacy format and 33 for the current
    /// one (nil while unreadable), so the upgrade after a correct PIN can be seen.
    static var storedHashLengthForTesting: Int? { read(account: account)?.count }
    #endif

    #if DEBUG
    /// Test-only (item 144's F3): plants a lockout value as damage would leave it.
    static func writeLockoutValueForTesting(_ value: String) { _ = write(Data(value.utf8), account: lockoutAccount) }
    /// Test-only companion: the stored lockout value, nil when absent.
    static var lockoutValueForTesting: String? { read(account: lockoutAccount).flatMap { String(data: $0, encoding: .utf8) } }
    /// Test-only: forgets the in-process copy of the deadline, so a test sees what the stored value alone says.
    @MainActor static func clearMirroredLockoutForTesting() { mirroredLockout = nil }
    /// Test-only: every Keychain write reports failure, constructing the partial-failure state
    /// of item 73's R10 (reads fine, writes refused) against a live Keychain.
    nonisolated(unsafe) static var failWritesForTesting = false
    /// Test-only read failure injection; production always consults the Keychain.
    nonisolated(unsafe) static var readStatusForTesting: OSStatus?
    #endif

    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        #if DEBUG
        if failWritesForTesting { return false }
        #endif
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

    /// A synchronizable item: iCloud Keychain carries it to the owner's other devices. Such an
    /// item cannot be "this device only", so its accessibility is after-first-unlock — fine for
    /// a one-bit membership flag, which is not a secret. Update in place, add only when absent:
    /// the same discipline as `write`.
    private static func writeSynchronizable(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true
        ]
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Reads an item whether or not it is synchronizable (the marker may be either, see
    /// `markEarlyAccessMember`).
    private static func readAny(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    private static func read(account: String) -> Data? {
        let r = readWithStatus(account: account)
        return r.status == errSecSuccess ? r.data : nil
    }

    /// The raw read, status preserved — so presence classification can tell a SEALED item
    /// (locked device) from a missing one instead of collapsing both to nil (seventh
    /// review #2: that collapse is why a sealed salt read exactly like a lost one).
    private static func readWithStatus(account: String) -> (status: OSStatus, data: Data?) {
        #if DEBUG
        if let status = readStatusForTesting { return (status, nil) }
        #endif
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

    private static func delete(account: String, synchronizable: Bool = false) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if synchronizable { query[kSecAttrSynchronizable as String] = true }
        SecItemDelete(query as CFDictionary)
    }
}
