import Foundation
import LocalAuthentication
import UIKit

/// Installation-bound permission to use one iCloud account. No PIN or evidence is stored here.
/// The file is excluded from backup and disappears with the app container on uninstall.
@MainActor
final class CloudEnrollment: ObservableObject {
    private static let production = CloudEnrollment()
    #if DEBUG
    /// Tests inject a per-test file; already-created services retain their own policy instance.
    static var sharedForTesting: CloudEnrollment?
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

        var explanation: String {
            switch self {
            case .unknownAccount:
                return "These events have no verified iCloud account. They stay on this device; Retry cannot upload them. Use Share on an event to save a copy elsewhere."
            case .differentAccount:
                return "These events belong to a different iCloud account and cannot upload to the current account."
            case .verificationRequired:
                return "Verify iCloud access in Settings before uploading these events."
            case .unavailable:
                return "Cloud verification information is unavailable. Unlock this device and check Settings → iCloud."
            }
        }
    }

    /// Explains a local upload hold using already-known state, without prompting or resolving iCloud.
    func uploadHoldReason(for event: Event) -> UploadHoldReason? {
        guard !event.isMirrored, event.cloudSyncState != .synced else { return nil }
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
    }

    @Published private(set) var verified = false
    @Published private(set) var notice = "Verify this installation in Settings before using iCloud. Local monitoring remains available."
    private let file: URL
    private let authenticate: @MainActor (String) async -> Bool
    private let persist: (Data, URL) throws -> Void
    @Published private var state: State?
    private var generation = UUID()
    private var resolvedAccount: String?
    private var authenticating = false
    private var captureHeld = false

    init(file: URL? = nil,
         authenticate: @escaping @MainActor (String) async -> Bool = CloudEnrollment.deviceAuthentication,
         persist: @escaping (Data, URL) throws -> Void = CloudEnrollment.write) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudEnrollment/state.json")
        self.authenticate = authenticate
        self.persist = persist
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
            notice = "Verification did not complete. Local monitoring remains available; retry while disarmed."
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
        next.owners[id.uuidString] = captureHeld || next.observedDifferentAccount != nil ? "" : (next.account ?? "")
        _ = commit(next)
    }

    /// Migrates only records already tied to an account by the prior release. Unknown history is held locally.
    /// Called once a complete local log is readable; a locked or partial log must not settle migration.
    func seedLegacyEvents(_ events: [Event], knownAccount: String?) {
        guard load(), var next = state, !next.migrationSeeded else { return }
        for event in events {
            if event.isMirrored {
                if next.remoteOwners[event.id.uuidString] == nil {
                    next.remoteOwners[event.id.uuidString] = knownAccount ?? ""
                }
            } else if next.owners[event.id.uuidString] == nil {
                next.owners[event.id.uuidString] = knownAccount ?? ""
            }
        }
        next.migrationSeeded = true
        _ = commit(next)
    }

    /// Binds newly restored mirrors to the account that supplied them without relabeling existing evidence.
    func registerRemoteEvents(_ events: [Event], lease: Lease) -> Bool {
        guard isCurrent(lease), var next = state else { return false }
        for event in events where next.remoteOwners[event.id.uuidString] == nil {
            next.remoteOwners[event.id.uuidString] = lease.account
        }
        return commit(next)
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

    /// Read failures remain unresolved and are retried after unlock; corrupt or future-version files are never overwritten.
    private func load() -> Bool {
        if state != nil { return true }
        do {
            let bytes = try Data(contentsOf: file)
            let stored = try JSONDecoder().decode(State.self, from: bytes)
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

    /// Atomic, protected, non-backed-up installation state. A failed write never opens the cloud gate.
    nonisolated static func write(_ data: Data, to file: URL) throws {
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func deviceAuthentication(_ reason: String) async -> Bool {
        guard UIApplication.shared.applicationState == .active, !UIAccessibility.isGuidedAccessEnabled else { return false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}
