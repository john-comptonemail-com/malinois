import Foundation
import LocalAuthentication
import UIKit

/// Installation-bound permission to use one iCloud account. No PIN or evidence is stored here.
/// The file is excluded from backup and disappears with the app container on uninstall; a restore rebuilds it holding
/// every restored record (`holdRestoredEvents`, codex-7).
@MainActor
final class CloudEnrollment: ObservableObject {
    private static let production = CloudEnrollment()
    #if DEBUG
    /// Tests inject a per-test file; already-created services retain their own policy instance.
    static var sharedForTesting: CloudEnrollment?
    /// The writes synced to the storage medium this process (item 153's MAL-07).
    nonisolated(unsafe) static var fullSyncsForTesting = 0
    #endif
    static var shared: CloudEnrollment {
        #if DEBUG
        if let sharedForTesting { return sharedForTesting }
        #endif
        return production
    }

    struct Lease: Equatable, Sendable {
        let account: String
        let generation: UUID
    }

    /// Presentation only; never grants cloud permission or changes an event's account binding.
    enum UploadHoldReason: String, CaseIterable {
        case unknownAccount, differentAccount, verificationRequired, unavailable
        /// Recorded while iCloud backup was off (item 115): Malinois never uploads it.
        case backupOff

        var explanation: String {
            switch self {
            case .unknownAccount:
                return "These events have no verified iCloud account. Malinois won't upload them, and Retry can't. Use Share on an event to save a copy elsewhere."
            case .differentAccount:
                return "These events belong to a different iCloud account and cannot upload to the current account."
            case .verificationRequired:
                return "Verify iCloud access in Settings before uploading these events."
            case .unavailable:
                return "Cloud verification information is unavailable. Unlock this device and check Settings → iCloud."
            case .backupOff:
                return "These events were recorded while iCloud backup was off. Malinois will never upload them, even after backup is turned back on. Use Share on an event to save a copy elsewhere."
            }
        }
    }

    /// Explains a local upload hold using already-known state, without prompting or resolving iCloud.
    func uploadHoldReason(for event: Event) -> UploadHoldReason? {
        guard !event.isMirrored, event.cloudSyncState != .synced else { return nil }
        if event.keptLocal == true { return .backupOff }   // item 115: kept on this device by choice
        guard let state else { return .unavailable }
        guard let owner = state.owners[event.id.uuidString], !owner.isEmpty else { return .unknownAccount }
        guard let account = resolvedAccount ?? state.observedDifferentAccount ?? state.account else {
            return .verificationRequired
        }
        guard owner == account else { return .differentAccount }
        guard state.account == account, state.observedDifferentAccount == nil, !captureHeld else {
            return .verificationRequired
        }
        // A durable grant makes same-account offline events retryable, even before identity
        // can be resolved again. The cloud service still obtains a fresh lease before upload.
        return nil
    }

    private struct State: Codable {
        var version = 1
        var installation = UUID()
        var account: String?
        var observedDifferentAccount: String?
        var owners: [String: String] = [:]
        var remoteOwners: [String: String] = [:]
        var migrationSeeded = false
        /// The first-hand records the restore's rebuild held, their upload history unknown (item 166's codex-29), written
        /// with their bindings (codex-31). Optional: a file written before it has none.
        var restoredHolds: Set<String>?
    }

    @Published private(set) var verified = false
    @Published private(set) var notice = "Verify this installation in Settings before using iCloud. Local monitoring remains available."
    private let file: URL
    private let authenticate: @MainActor (String) async -> Bool
    private let guidedAccess: @MainActor () -> Bool
    private let persist: (Data, URL) throws -> Void
    @Published private var state: State?
    private var generation = UUID()
    private var resolvedAccount: String?
    private var authenticating = false
    private var captureHeld = false

    /// - Parameters:
    ///   - file: where the grant is kept (tests pass their own).
    ///   - authenticate: the device-owner check (Face ID, Touch ID or the passcode).
    ///   - persist: the grant's write.
    ///   - guidedAccess: whether Guided Access is on, read when a verification fails (item 135).
    init(file: URL? = nil,
         authenticate: @escaping @MainActor (String) async -> Bool = CloudEnrollment.deviceAuthentication,
         persist: @escaping (Data, URL) throws -> Void = CloudEnrollment.write,
         guidedAccess: @escaping @MainActor () -> Bool = { UIAccessibility.isGuidedAccessEnabled }) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudEnrollment/state.json")
        self.authenticate = authenticate
        self.persist = persist
        self.guidedAccess = guidedAccess
        _ = load()
    }

    /// Only a positively resolved identity may issue an operation lease. Background callers never prompt.
    func authorize(account: String) -> Lease? {
        guard !account.isEmpty, load() else { invalidateAccount(); return nil }
        if resolvedAccount != account {
            generation = UUID()
            resolvedAccount = account
        }
        if var next = state, let granted = next.account {
            if granted != account {
                captureHeld = true
                if next.observedDifferentAccount != account {
                    next.observedDifferentAccount = account
                    // A restrictive observation must survive a failed save in memory so
                    // a later successful event write cannot silently drop the hold.
                    state?.observedDifferentAccount = account
                    guard commit(next) else { return nil }
                }
            } else if next.observedDifferentAccount != nil || captureHeld {
                next.observedDifferentAccount = nil
                guard commit(next) else { return nil }
                captureHeld = false
            }
        }
        verified = state?.account == account
        guard verified else {
            notice = "iCloud is paused. Verify this installation and account in Settings; your local evidence is kept."
            return nil
        }
        notice = "This installation is verified for iCloud. Evidence from an unknown or different account stays local."
        return Lease(account: account, generation: generation)
    }

    /// Recheck after every suspension before using a result or starting the next cloud operation.
    func isCurrent(_ lease: Lease) -> Bool {
        verified && lease.generation == generation && lease.account == resolvedAccount && state?.account == lease.account
    }

    /// Invalidates in-flight work immediately. A transient identity failure does not erase a durable grant.
    func invalidateAccount() {
        generation = UUID()
        resolvedAccount = nil
        verified = false
    }

    /// What a verification that fails with Guided Access on says (item 135): iOS holds the Face ID / passcode sheet
    /// until Guided Access ends (BACKLOG 44), so `deviceAuthentication` refuses at once.
    static let guidedAccessNotice = "Verification did not complete: Guided Access was on. Local monitoring remains available."

    /// Explicit foreground enrollment. A changed account, cancellation, or failed durable write grants nothing.
    func enroll(account: String, resolve: @escaping @MainActor () async -> String?) async -> Bool {
        guard !Task.isCancelled, !authenticating, !account.isEmpty, load() else { return false }
        authenticating = true
        defer { authenticating = false }
        let attempt = generation
        guard await authenticate("Verify access to Malinois iCloud evidence on this installation."),
              !Task.isCancelled, generation == attempt,
              await resolve() == account,
              !Task.isCancelled, generation == attempt,
              var next = state else {
            // Read now, not when the tap came: Guided Access may have started during the attempt (item 135).
            notice = guidedAccess() ? Self.guidedAccessNotice
                : "Verification did not complete. Local monitoring remains available; retry while disarmed."
            return false
        }
        next.account = account
        next.observedDifferentAccount = nil
        guard commit(next) else { return false }
        captureHeld = false
        resolvedAccount = account
        generation = UUID()
        verified = true
        notice = "This installation is verified for iCloud. Evidence from an unknown or different account stays local."
        return true
    }

    /// Account-wide alert removal always needs a new system authentication, even for an enrolled installation.
    func authorizeAccountControl(account: String) async -> Lease? {
        guard !Task.isCancelled, !authenticating, let lease = authorize(account: account) else { return nil }
        authenticating = true
        defer { authenticating = false }
        guard await authenticate("Turn off Malinois cross-device alerts for this entire iCloud account."),
              !Task.isCancelled, isCurrent(lease) else { return nil }
        return lease
    }

    /// Whether an event recorded now is recorded while iCloud backup is off (item 115); the engine
    /// supplies it. Such an event is registered to no account (item 116, R3): the hold every
    /// version since 1.5.1 keeps, so an older version installed over this one, which ignores
    /// `Event.keptLocal`, still never uploads it.
    var holdsNewEventsLocal: () -> Bool = { false }

    /// Whether an event recorded now is held on this device, tied to no account (`register`): a different account was
    /// seen since the grant, or iCloud backup is off.
    private var holdsNewEvents: Bool {
        captureHeld || state?.observedDifferentAccount != nil || holdsNewEventsLocal()
    }

    /// Whether an event recorded now is tied to this installation's verified account, so it uploads once iCloud names
    /// that account again, with no new verification (item 140's codex-1): true while a verified installation waits
    /// for iCloud, offline or after a relaunch. False before the first verification, after another account was seen
    /// and while iCloud backup is off: Malinois does not upload those events. Presentation only; it grants nothing.
    var newEventsBindToVerifiedAccount: Bool {
        guard let account = state?.account, !account.isEmpty else { return false }
        return !holdsNewEvents
    }

    /// Registers ownership at capture time, never opportunistically when an upload is attempted.
    func registerLocalEvent(_ event: Event) {
        guard !event.isMirrored else { return }
        register(id: event.id)
    }

    /// A watch's heartbeat shares the arm record's identity and account ownership.
    func registerSession(_ id: UUID) { register(id: id) }

    private func register(id: UUID) {
        guard load(), var next = state, next.owners[id.uuidString] == nil else { return }
        // Empty binding is a durable hold, so a later cloud mirror cannot adopt this local ID.
        // Offline captures retain their verified owner unless a different account was positively
        // observed. That hold survives relaunch and later identity failures; only new verification
        // or positively resolving the original account permits binding future captures again.
        // Recorded while iCloud backup is off: held the same way, for good (item 116, R3).
        // The same rule as Home's iCloud row and line (`newEventsBindToVerifiedAccount`).
        next.owners[id.uuidString] = holdsNewEvents ? "" : (next.account ?? "")
        _ = commit(next)
    }

    /// The bindings' one-time rebuild when their file is missing: after a restore from a device backup, which leaves this
    /// file out, or an update from before 1.5.1. Called once a complete local log is readable; a locked or partial log
    /// must not settle it. Hold rather than guess (codex-7 on 1.8.2, twice; the owner's ruling (a)): nothing the backup
    /// keeps proves which account a restored record went to, or that it was held, so every first-hand record is held,
    /// tied to no account; other devices' copies are left unbound, for the next fetch from the verified account to bind
    /// (`registerRemoteEvents`). A binding already there is never relabelled. Each record it holds is noted as restored,
    /// its upload history unknown (`restoredHolds`; item 166's codex-29), in the same write as its binding, so no kill
    /// can keep one without the other (codex-31).
    func holdRestoredEvents(_ events: [Event]) {
        guard load(), var next = state, !next.migrationSeeded else { return }
        var restored = next.restoredHolds ?? []
        for event in events where !event.isMirrored && next.owners[event.id.uuidString] == nil {
            next.owners[event.id.uuidString] = ""
            restored.insert(event.id.uuidString)
        }
        next.restoredHolds = restored.isEmpty ? nil : restored
        next.migrationSeeded = true
        _ = commit(next)
    }

    /// Whether this phone cannot know where its own record `event` went (item 166's codex-29): one the restore's rebuild
    /// held (`holdRestoredEvents`), or one with no binding at all, as a restored record has until the rebuild runs, which
    /// waits for a readable log (codex-32); every record this app makes is bound at birth. A record recorded while the
    /// installation was not uploading is bound to no account at birth, and is not one of these: it never went up.
    func uploadHistoryUnknown(for event: Event) -> Bool {
        guard load(), let state, !event.isMirrored else { return false }
        let key = event.id.uuidString
        return state.owners[key] == nil || state.restoredHolds?.contains(key) == true
    }

    /// Binds newly restored mirrors to the account that supplied them without relabeling existing evidence. A fetch
    /// that brings no new record leaves the file as it is (1.8.2's step 32, item 152's lead 20): every write reaches
    /// the storage medium (item 153's MAL-07), and every push from iCloud runs a fetch.
    func registerRemoteEvents(_ events: [Event], lease: Lease) -> Bool {
        guard isCurrent(lease), var next = state else { return false }
        var added = false
        for event in events where next.remoteOwners[event.id.uuidString] == nil {
            next.remoteOwners[event.id.uuidString] = lease.account
            added = true
        }
        return !added || commit(next)
    }

    func authorizeUpload(event: Event, lease: Lease) -> Bool {
        !event.isMirrored && isCurrent(lease) && state?.owners[event.id.uuidString] == lease.account
    }

    func authorizeRecord(_ id: UUID, lease: Lease) -> Bool {
        guard isCurrent(lease) else { return false }
        if let owner = state?.owners[id.uuidString] { return owner == lease.account }
        return state?.remoteOwners[id.uuidString] == lease.account
    }

    func authorizeSession(session: UUID, startedAt: Date? = nil, lease: Lease) -> Bool {
        isCurrent(lease) && state?.owners[session.uuidString] == lease.account
    }

    /// The account this installation is verified for (its durable grant), or nil before the first verification or
    /// while the grant cannot be read. The iCloud-copies check reads it (item 152's lead 13); it grants nothing.
    var enrolledAccount: String? {
        guard load(), let account = state?.account, !account.isEmpty else { return nil }
        return account
    }

    /// Whether `event` was bound to `account` as it was recorded (`registerLocalEvent`): the records that may go up to
    /// that account, and the ones the iCloud-copies check looks for there (item 152's lead 13). Never a mirror. It
    /// grants nothing: an upload still needs a current lease (`authorizeUpload`).
    func isBound(_ event: Event, to account: String) -> Bool {
        guard load(), !event.isMirrored, !account.isEmpty else { return false }
        return state?.owners[event.id.uuidString] == account
    }

    /// Prunes the bindings no record needs any longer (item 153's MAL-08): one was kept per record ever recorded, and
    /// the whole file is rewritten at every new one. `keeping` is every ID that may still need its binding: the log's
    /// records (its own and copies), uploads under way, and the watches whose heartbeat records iCloud may hold. The
    /// hold rule stands for what the log holds; a record gone from it that comes back from iCloud comes back as a copy,
    /// bound to the account that supplies it (ADR 0039). Call only with the complete log read. Returns how many went.
    @discardableResult
    func pruneBindings(keeping: Set<UUID>) -> Int {
        guard load(), var next = state else { return 0 }
        let keep = Set(keeping.map(\.uuidString))
        let before = next.owners.count + next.remoteOwners.count
        next.owners = next.owners.filter { keep.contains($0.key) }
        next.remoteOwners = next.remoteOwners.filter { keep.contains($0.key) }
        next.restoredHolds = next.restoredHolds.map { $0.filter(keep.contains) }   // the notes go with their bindings
        let pruned = before - next.owners.count - next.remoteOwners.count
        guard pruned > 0, commit(next) else { return 0 }
        return pruned
    }

    /// Read failures remain unresolved and are retried after unlock; corrupt or future-version files are never overwritten.
    private func load() -> Bool {
        if state != nil { return true }
        do {
            let bytes = try Data(contentsOf: file)
            let stored = try StoredJSON.decode(State.self, from: bytes)
            guard stored.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            state = stored
            captureHeld = stored.observedDifferentAccount != nil
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = State()
            return true
        } catch {
            notice = "Cloud verification state is unavailable. Unlock this device and retry; local evidence is kept."
            return false
        }
    }

    private func commit(_ next: State) -> Bool {
        do {
            try persist(JSONEncoder().encode(next), file)
            state = next
            return true
        } catch {
            invalidateAccount()
            notice = "Cloud verification could not be saved. Free device storage and retry; local evidence is kept."
            return false
        }
    }

    /// Atomic, protected, non-backed-up installation state. A failed write never opens the cloud gate. The write
    /// reaches the storage medium before it returns (`F_FULLFSYNC`, as the journal's append does; item 153's MAL-07):
    /// an event's binding is written before its journal line, and left in the OS's caches, a forced restart within
    /// seconds of a trip could keep the line and lose the binding, the event then held as unknown account. A sync that
    /// fails is logged: the state written still survives a kill, not a power cut.
    nonisolated static func write(_ data: Data, to file: URL) throws {
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard let handle = try? FileHandle(forUpdating: file) else {
            Log.cloud.error("Enrollment full sync skipped: the file could not be opened — the state survives a kill, not a power cut")
            return
        }
        defer { try? handle.close() }
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1 else {
            let failure = errno
            Log.cloud.error("Enrollment full sync failed (errno \(failure, privacy: .public)) — the state survives a kill, not a power cut")
            return
        }
        #if DEBUG
        fullSyncsForTesting += 1
        #endif
    }

    /// Face ID, Touch ID or the passcode, asked only while the app is active. Under Guided Access iOS holds the
    /// sheet until Guided Access ends (BACKLOG 44), so this refuses at once rather than leave a request waiting;
    /// Settings greys out Verify iCloud access meanwhile and says why (item 135).
    static func deviceAuthentication(_ reason: String) async -> Bool {
        guard UIApplication.shared.applicationState == .active, !UIAccessibility.isGuidedAccessEnabled else { return false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}
