//
//  CloudExfiltrator.swift
//  Malinois
//
//  Pushes tamper evidence to the user's PRIVATE CloudKit database the instant a
//  trigger fires, so evidence survives a subsequent power-off of the device.
//
//  Two-shot design:
//    1. A TINY record (metadata JSON + few-KB thumbnail) is saved first, with
//       high QoS, so the core evidence lands in well under a second.
//    2. The full-resolution photo/clip follows as a separate record.
//  Both are wrapped in a UIApplication background-task assertion so a fast
//  app-switch or power-off doesn't kill the upload mid-flight.
//
//  The CKContainer connection is warmed on arm (accountStatus + a no-op fetch)
//  to avoid cold-start latency at trigger time.
//

import Foundation
import OSLog
import CloudKit
import UIKit

@MainActor
final class CloudExfiltrator: ObservableObject {

    enum AccountState: Equatable {
        case unknown, available, noAccount, restricted, error(String)

        var displayName: String {
            switch self {
            case .unknown:    return "Checking iCloud…"
            case .available:  return "iCloud ready"
            case .noAccount:  return "No iCloud account"
            case .restricted: return "iCloud restricted"
            // Fixed string (eighth review, L5): the raw CloudKit message rendered on the
            // unauthenticated Home screen; the detail still goes to the log where it's set.
            case .error: return "iCloud error - check iCloud in iOS Settings"
            }
        }
        var isReady: Bool { self == .available }
        /// iCloud's answer that the account is not there to use: no account, or restricted. Anything else that is not
        /// ready is a temporary answer or an error (item 155's A2).
        var isDefinitiveAbsence: Bool { self == .noAccount || self == .restricted }

        /// Whether it's worth *attempting* a push. `.unknown` and transient `.error`
        /// (e.g. `.couldNotDetermine` during a network transition) are optimistic — we
        /// let CloudKit itself be the judge, since it fails fast when the account really
        /// is gone. Only a definitive no — no account, or restricted — aborts.
        var canAttempt: Bool {
            switch self {
            case .noAccount, .restricted: return false
            default:                      return true
            }
        }
    }

    @Published private(set) var accountState: AccountState = .unknown

    /// Cloud operations stay local-only until this installation verifies the resolved account.
    /// The screens show that state from the policy itself (`verified`, `notice`).
    let enrollment: CloudEnrollment
    /// The engine's live iCloud-backup rule for one record (item 115; ADR 0047), wired at the
    /// engine's init and read before every upload step and every save attempt (item 116, R2).
    /// Allows everything until wired.
    var backupPermits: (Event) -> Bool = { _ in true }
    /// Whether iCloud backup is on (item 115), read before a heartbeat is sent: it carries no event.
    var backupOn: () -> Bool = { true }
    /// The engine's log's copy of an event as it is now (item 162's A10), wired at the engine's init: a push reads it
    /// when its turn comes in the event's queue, so it writes the event as the log holds it then, never an older copy
    /// (the pending sweep's, read at its pass's start). Nil until wired, and for an event the log no longer holds.
    var storedEvent: (UUID) -> Event? = { _ in nil }
    /// Told when a capture's full file has reached iCloud, with its camera token (item 166's codex-23): the engine notes it
    /// on the event (`Event.uploadedMedia`).
    var mediaLanded: (UUID, String, Int?) -> Void = { _, _, _ in }
    /// A fact permitted by backup policy did not finish. Called with its actual snapshot inside the event's queue,
    /// before the next write starts, so the engine can reopen a still-matching synced row without racing a later save.
    var factFailed: (Event) -> Void = { _ in }
    private var identityGeneration = UUID()
    private var resolvedAccount: String?
    // NotificationCenter's token is only registered/removed here; it has no actor-bound state.
    nonisolated(unsafe) private var accountObserver: NSObjectProtocol?
    private var activeOperations: [UUID: CKOperation] = [:]

    init(enrollment: CloudEnrollment = .shared) {
        self.enrollment = enrollment
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateAccountResolution() }
            }
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    /// Discards only current resolution/work; the durable enrollment is owned by the policy.
    private func invalidateAccountResolution() {
        identityGeneration = UUID()
        resolvedAccount = nil
        submittedMetaRevisions.removeAll()
        encryptedDataResetDetected = false
        lastTransientFailure = nil
        lastFetchComplete = false
        enrollment.invalidateAccount()
        for operation in activeOperations.values { operation.cancel() }
        activeOperations.removeAll()
    }

    /// Resolves identity afresh without prompting. Every database entry point needs this lease.
    func acquireCloudLease() async -> CloudEnrollment.Lease? {
        guard let account = await userRecordName() else { return nil }
        return enrollment.authorize(account: account)
    }

    /// Explicit foreground enrollment; the policy verifies identity again before durable grant.
    func enrollCloudAccess() async -> Bool {
        guard let account = await userRecordName() else { return false }
        let enrolled = await enrollment.enroll(account: account, resolve: { [weak self] in
            await self?.userRecordName()
        })
        guard enrolled, let lease = await acquireCloudLease(), lease.account == account else { return false }
        return enrollment.isCurrent(lease)
    }

    /// Ownership (ADR 0039) and the iCloud backup switch (ADR 0047), checked together before every
    /// upload step, after each wait (item 116, R2): turning backup off stops anything new from
    /// starting, even in an upload already under way. What CloudKit already accepted stays.
    private func mayUpload(_ event: Event, lease: CloudEnrollment.Lease) -> Bool {
        enrollment.authorizeUpload(event: event, lease: lease) && backupPermits(event)
    }

    private func requireCurrent(_ lease: CloudEnrollment.Lease) throws {
        guard enrollment.isCurrent(lease), !Task.isCancelled else { throw CKError(.notAuthenticated) }
    }

    /// The final synchronous gate immediately before an explicit CloudKit operation is submitted.
    private func submit(_ operation: CKDatabaseOperation, to database: CKDatabase,
                        lease: CloudEnrollment.Lease, rejected: () -> Void) {
        guard enrollment.isCurrent(lease), !Task.isCancelled else {
            operation.cancel()
            rejected()
            return
        }
        database.add(operation)
    }

    /// Queue work with its original account, checking both sides of the queue/operation waits.
    func enqueueAuthorized<T: Sendable>(_ id: UUID, lease: CloudEnrollment.Lease, declined: T,
                                        _ operation: @escaping @MainActor () async -> T) async -> T {
        guard enrollment.isCurrent(lease) else { return declined }
        return await enqueue(id) { [self] in await underLease(lease, declined: declined, operation) }
    }

    /// Runs `operation` while `lease` stays current: declined when the lease has lapsed, or the task was cancelled, on
    /// either side of it.
    private func underLease<T: Sendable>(_ lease: CloudEnrollment.Lease, declined: T,
                                         _ operation: @MainActor () async -> T) async -> T {
        guard enrollment.isCurrent(lease), !Task.isCancelled else { return declined }
        let result = await operation()
        guard enrollment.isCurrent(lease), !Task.isCancelled else { return declined }
        return result
    }

    #if DEBUG
    /// Replaces only account identity discovery; it grants no database permission. Nil is iCloud's "no account"; a
    /// thrown error is classified as the real lookup's would be (`identityLookup`).
    var accountIdentityForTesting: (@MainActor () async throws -> String?)?
    /// Replaces only iOS's account-status answer in `refreshAccountState` (item 140's codex-1: the Simulator has no
    /// container, so Home's own check always found no account); it grants no database permission.
    var accountStatusForTesting: AccountState?
    /// Replaces one save attempt's CloudKit operation (item 116): everything before it runs as
    /// shipped, and a thrown error takes the shipped retry path. The Simulator has no container.
    var saveAttemptForTesting: (@MainActor ([CKRecord]) async throws -> Void)?
    /// Takes the save's operation in place of the database (item 152's lead 2): the test drives its blocks as
    /// CloudKit would, progress included, and sees the cancel. Everything else runs as shipped.
    var submitForTesting: (@MainActor (CKModifyRecordsOperation) -> Void)?
    /// A test's stall and asset cap, in place of the production 20 s and 600 s.
    var saveDeadlinesForTesting: (stall: TimeInterval, assetCap: TimeInterval)?
    /// Replace the account's subscriptions as CloudKit lists them, one subscription's save, and a removal (item 165's
    /// A3, Codex's codex-19 and codex-21): the Simulator has no container. The lease and the choice of what to save run
    /// as shipped.
    var existingSubscriptionsForTesting: (@MainActor () async throws -> [CKSubscription])?
    var subscriptionSaveForTesting: (@MainActor (CKQuerySubscription) async -> Bool)?
    var subscriptionRemovalForTesting: (@MainActor ([String]) async -> Bool)?
    /// Drives a subscription deletion's real callbacks in place of CloudKit; authentication and lease gates still run.
    var subscriptionDeleteSubmitForTesting: (@MainActor (CKModifySubscriptionsOperation) -> Void)?
    /// Told when an automatic setup of the alert subscriptions (the arm's warm-up, a reconnect's refresh) begins and
    /// when it has finished (Codex's note on 946b248..b00a120): a test waits on these instead of sleeping.
    var automaticSetupBeganForTesting: (@MainActor () -> Void)?
    var automaticSetupFinishedForTesting: (@MainActor () -> Void)?
    /// Replaces only the presence check's database fetch (item 166's codex-28): each name's result, in the order given
    /// (CloudKit's own order is a dictionary's, with none to rely on: codex-30), or a thrown error. The lease and the
    /// reading of the results run as shipped.
    var presenceFetchForTesting: (@MainActor ([String]) async throws -> [(String, Result<Void, any Error>)])?
    /// How long an iCloud read may wait for its answer in a test, in place of `saveAttemptDeadline` (BACKLOG 180's A2).
    var readDeadlineForTesting: TimeInterval?
    /// Takes an iCloud read's operation in place of the database (BACKLOG 180's codex-4): the test answers it as CloudKit
    /// would, or withholds the answer, and sees the cancel. Everything else runs as shipped.
    var readSubmitForTesting: (@MainActor (CKDatabaseOperation) -> Void)?
    #endif

    // MARK: - Record types
    //
    // Two generations live side by side (BACKLOG 19). The V2 types carry every custom field
    // inside `encryptedValues`, so the metadata *around* the evidence — which sensors tripped,
    // when, and on which device — is encrypted toward the owner's own keys rather than Apple's.
    // The 1.0-era types hold those same fields in the clear.
    //
    // Why new types instead of encrypting the existing fields: a deployed CloudKit field
    // cannot be converted to an encrypted one. So the app **writes V2 only and reads both**,
    // which keeps evidence pushed before the migration readable instead of orphaning it.

    // `nonisolated` on all of these: the record builders and decoders are deliberately
    // `nonisolated static` so they can be unit-tested without a container, and a main-actor
    // constant can't be read from there. Swift 5 says warning; Swift 6 says error. They are
    // immutable Strings, so there is nothing for the isolation to protect.

    /// 1.0 schema — **read-only**. Nothing writes these any more.
    nonisolated static let metaRecordType = "TamperEventMeta"
    nonisolated static let photoRecordType = "TamperEventPhoto"
    nonisolated static let stateRecordType = "TamperEventState"

    /// 1.1 schema — every custom field encrypted.
    nonisolated static let metaRecordTypeV2 = "TamperEventMetaV2"
    nonisolated static let photoRecordTypeV2 = "TamperEventPhotoV2"

    /// Arm/disarm audit records (BACKLOG 8). A **separate record type on purpose**: the
    /// cross-device subscription watches the meta type with `NSPredicate(value: true)`
    /// and a static "Tamper detected on your device." body, so pushing a routine arm/disarm
    /// as a meta record would fire that alert — wrong, and noisy enough to train the owner
    /// to ignore it. Nothing subscribes to this type, so these records are durable and
    /// silent. The correctly-worded "disarmed" push rides `disarmSignalRecordTypeV2`.
    nonisolated static let stateRecordTypeV2 = "TamperEventStateV2"

    /// The disarm signal (BACKLOG 59). A tiny record written beside the audit record on
    /// every **disarm**, whose only job is to be subscribed to: the audit record's `kind` is
    /// encrypted, and encrypted fields cannot be queried, so no subscription can pick disarms
    /// out of `stateRecordTypeV2` — and a plaintext copy of `kind` would reverse part of
    /// BACKLOG 19. A separate type leaks exactly what a plaintext field would (the platform
    /// sees that a disarm record exists, and when; SECURITY.md says so) while every field
    /// stays encrypted. Failure-isolated by construction: if the type is not yet deployed to
    /// Production, only this write fails and the audit record still lands. Never fetched —
    /// the audit record is what the other devices' logs show.
    nonisolated static let disarmSignalRecordTypeV2 = "TamperEventDisarmV2"

    /// Watches `metaRecordTypeV2`. A **new ID on purpose**: a `CKQuerySubscription`'s record
    /// type is fixed when it is created, so reusing the 1.0 ID would leave the owner's other
    /// devices subscribed to a type nothing writes to any more — cross-device push would go
    /// quiet with no error raised anywhere. The old subscription is deleted whenever this one
    /// is established.
    nonisolated private static let subscriptionID = "malinois-tamper-meta-v2-sub"
    nonisolated private static let legacySubscriptionID = "malinois-tamper-meta-sub"
    /// Watches `disarmSignalRecordTypeV2` (BACKLOG 59). Its own ID for the reason above: a
    /// subscription's record type is fixed at creation.
    nonisolated private static let disarmSubscriptionID = "malinois-disarm-v2-sub"
    /// Every ID this app has ever created — what the explicit OFF flip must delete, or a
    /// device that armed under an older build keeps pushing after the owner opted out.
    nonisolated static let subscriptionIDsToRemove = [subscriptionID, disarmSubscriptionID, legacySubscriptionID]

    /// Set once the container can't be created (simulator, or a device build whose
    /// CloudKit entitlement isn't applied) — surfaced on Home so the local-only fallback
    /// isn't mistaken for a bug.
    @Published private(set) var cloudUnavailable = false

    /// Whether the last `fetchRecentEvents` had at least one query **fail**, as opposed to
    /// returning nothing. Without this the two are indistinguishable — every query returns `[]`
    /// on error — and the background-push path would report success to iOS for a fetch that
    /// never ran.
    private(set) var lastFetchFailed = false

    /// Whether the last `fetchRecentEvents` reached iCloud and ran every query to the end: the
    /// account was ready and none failed. An owed restore (item 89, C1) is settled only then;
    /// `lastFetchFailed` alone cannot say it, since an account that is not ready never queries.
    private(set) var lastFetchComplete = false

    /// Highest metadata revision successfully submitted this session, per event.
    ///
    /// In memory on purpose: the only writer that can be *stale* is the sparse pre-capture
    /// fact, which exists only during a live trigger. After a relaunch every re-push carries the
    /// stored event, so there is no older writer left to lose a race to.
    private var submittedMetaRevisions: [UUID: Int] = [:]

    private static let containerProbeKey = "com.malinois.cloud.containerProbe"

    /// The probe's identity for the build currently running — marketing version + build
    /// (R3-6). The probe is scoped to it so a *new* build always gets a fresh attempt
    /// (V-02); CFBundleVersion alone collided across release lines (a dev "1.3 (28)"
    /// marker would leak its strikes into any future build numbered 28).
    private static var currentProbeIdentity: String {
        probeIdentity(marketingVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                      build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    /// Pure (unit-tested): marketing version + build as one marker key — unique per
    /// archive under the repo's bump-before-archive convention. Old bare-build markers
    /// never match a pair identity, so every updated install starts at zero strikes
    /// (one clean re-attempt — the safe direction for a marker that only suppresses).
    nonisolated static func probeIdentity(marketingVersion: String?, build: String?) -> String {
        "\(marketingVersion ?? "0")+\(build ?? "0")"
    }

    // Creating a CKContainer whose CloudKit entitlement isn't applied to the running
    // binary raises an UNCATCHABLE Obj-C exception (a hard crash on arm). The simulator
    // (CODE_SIGNING_ALLOWED=NO) is the common case, excluded at compile time. But a
    // *device* build without the entitlement — a free Apple Developer account can't make
    // iCloud containers — hits it too (M-01). Since the exception can't be caught and iOS
    // has no runtime entitlement read, a persisted "probe" catches it: record THIS build's
    // version before the risky call, clear it after. If the same build's version is still
    // recorded next launch, that build died creating the container → stay local-only for it.
    // Scoping to the build version (not a bare bool) means installing a properly-entitled
    // build later gets a clean first attempt instead of inheriting the old build's failure
    // via UserDefaults, which survives app updates (V-02).
    private var _container: CKContainer?
    private var container: CKContainer? {
        if let _container { return _container }
        #if targetEnvironment(simulator)
        markCloudUnavailable()
        return nil
        #else
        guard let id = Self.containerIdentifier else { return nil }
        let defaults = UserDefaults.standard
        let strikes = Self.probeStrikes(recorded: defaults.string(forKey: Self.containerProbeKey),
                                        build: Self.currentProbeIdentity)
        guard strikes < Self.probeStrikeLimit else {
            markCloudUnavailable()       // THIS build died here repeatedly — don't try again
            return nil
        }
        defaults.set("\(Self.currentProbeIdentity)|\(strikes + 1)", forKey: Self.containerProbeKey)
        defaults.synchronize()           // must be on disk BEFORE the (possible) crash
        let c = CKContainer(identifier: id)
        defaults.removeObject(forKey: Self.containerProbeKey)   // survived → clear the probe
        defaults.synchronize()           // the CLEAR must land too (sixth review, F7): an
                                         // unrelated crash before an async flush left the
                                         // marker standing after a SUCCESSFUL probe
        _container = c
        return c
        #endif
    }

    /// A one-off kill in the probe window must cost one launch's cloud, not the whole
    /// build (sixth review, F7): the marker carries a strike count, and only repeated
    /// deaths — the actual entitlement-crash signature — latch local-only. V-02's build
    /// scoping stands: a different build always starts at zero.
    nonisolated static let probeStrikeLimit = 2

    /// Pure (unit-tested): how many times THIS build has died inside the probe window.
    /// Legacy markers (a bare build string, no count) read as one strike; a marker from
    /// another build reads as zero; malformed counts read as one (a marker existed, so
    /// something died — but never instantly latch on garbage).
    nonisolated static func probeStrikes(recorded: String?, build: String) -> Int {
        guard let recorded else { return 0 }
        let parts = recorded.split(separator: "|", maxSplits: 1)
        guard let markerBuild = parts.first, markerBuild == build else { return 0 }
        guard parts.count == 2 else { return 1 }                   // legacy bare-build marker
        return Int(parts[1]).map { max(1, $0) } ?? 1
    }

    /// Flips `cloudUnavailable` without re-publishing when it's already set — the getter is
    /// hit on every `refreshAccountState`, and a redundant assignment would fire
    /// `objectWillChange` each time (V-02).
    private func markCloudUnavailable() {
        if !cloudUnavailable { cloudUnavailable = true }
    }
    private static var containerIdentifier: String? {
        Bundle.main.bundleIdentifier.map { "iCloud.\($0)" }
    }
    private var database: CKDatabase? { container?.privateCloudDatabase }

    // MARK: - Warm-up

    /// Settings' switch (`setCrossDeviceAlerts`) counts each change of the owner's alerts choice as it begins and as it
    /// ends, and how many are under way (codex-21). The switch reads the owner's old choice until a change lands, so an
    /// automatic setup (the arm's warm-up, a reconnect's refresh) that has seen a change begin or end since it began,
    /// or that reaches a step while one is under way, is superseded: it saves nothing more.
    private var alertsChoiceChanges = 0
    private var alertsChoiceChangesUnderWay = 0

    /// An automatic setup's live choice: the caller's (`wanted`, asked each time), while no change of the owner's
    /// choice has begun or ended since this setup began, and none is under way.
    private func automaticSetupWanted(_ wanted: @escaping @MainActor () -> Bool) -> @MainActor () -> Bool {
        let changesAtStart = alertsChoiceChanges
        return { [self] in
            alertsChoiceChanges == changesAtStart && alertsChoiceChangesUnderWay == 0 && wanted()
        }
    }

    /// Called on arm: check account status and (if the owner wants alerts) set up the push
    /// subscription after verifying this installation's current enrollment, so other devices
    /// are alerted the moment a trip lands. Warms the connection to cut cold-start latency at trigger time.
    /// `alertsWanted` is the owner's live choice, asked after the account lookup, after the listing and before each
    /// save, and a change made with the switch meanwhile supersedes it: an arm whose warm-up waits must not set the
    /// subscriptions up again once the owner has turned alerts off (codex-21). Never removes: automatic paths never
    /// perform account-wide OFF. Only the no-op query needs the database here: the subscription steps check for it
    /// themselves (without one the listing fails and nothing is saved), so the Simulator's seams reach them.
    func warmUp(alertsWanted: @escaping @MainActor () -> Bool) async {
        signalAutomaticSetup(finished: false)
        defer { signalAutomaticSetup(finished: true) }
        let stillWanted = automaticSetupWanted(alertsWanted)
        guard let lease = await acquireCloudLease() else { return }
        switch Self.subscriptionActionOnArm(notifyWanted: stillWanted()) {
        case .ensure:     await ensureSubscription(lease: lease, stillWanted: stillWanted)
        case .remove:     break // Automatic paths never perform account-wide OFF.
        case .leaveAlone: break
        }
        // A cheap no-op query to establish the connection early, only while enrolled, on an operation of its own
        // within the read deadline (BACKLOG 180's codex-4).
        guard enrollment.isCurrent(lease) else { return }
        let query = CKQueryOperation(query: CKQuery(recordType: Self.metaRecordTypeV2, predicate: NSPredicate(value: false)))
        query.resultsLimit = 1
        _ = try? await operationRead(query, lease: lease) { (resume: @escaping @Sendable (Result<Void, Error>) -> Void) in
            query.queryResultBlock = { @Sendable result in resume(result.map { _ in () }) }
        }
    }

    /// Re-establish the cross-device push subscription after a connectivity restore. `warmUp`
    /// sets this up at arm, but if the network was down then the setup silently failed and the
    /// owner's other devices would get no push for the entire armed session. Calling this the
    /// moment a path returns recovers it. Idempotent — `ensureSubscription` saves only what is
    /// missing. `stillWanted` is the owner's live choice, asked before and after each wait: a
    /// refresh nobody wants any more (the switch turned off, or the stored settings loaded with it
    /// off, meanwhile) sets nothing up (item 165's A3, Codex's codex-19), nor one that a change made
    /// with the switch has superseded, an "off" still waiting on Face ID included (codex-21). Never
    /// removes: automatic paths never perform account-wide OFF.
    func refreshSubscription(stillWanted wanted: @escaping @MainActor () -> Bool) async {
        signalAutomaticSetup(finished: false)
        defer { signalAutomaticSetup(finished: true) }
        let stillWanted = automaticSetupWanted(wanted)
        guard stillWanted(), let lease = await acquireCloudLease(), stillWanted() else { return }
        _ = await ensureSubscription(lease: lease, stillWanted: stillWanted)
    }

    /// Tells a test that an automatic setup of the alert subscriptions began or finished; nothing outside Debug.
    private func signalAutomaticSetup(finished: Bool) {
        #if DEBUG
        (finished ? automaticSetupFinishedForTesting : automaticSetupBeganForTesting)?()
        #endif
    }

    /// How long the account-status preflight may wait for cloudd's answer. It runs INSIDE
    /// the per-event upload chain (`pushFact` → `enqueue`) and the retry sweep's
    /// single-flight window, so a stall here used to jam both for the rest of the process —
    /// the same never-fails-so-nothing-escalates hazard as a stalled save (fourth-pass
    /// R3-1, completing sixth-review F1 through the door its deadline didn't cover).
    /// Generous: a healthy answer is near-instant.
    nonisolated static let accountStatusDeadline: TimeInterval = 10

    /// Applies iOS's account status (item 155's A2): no account and restricted invalidate the resolution, as the identity
    /// lookup's "no account" does; a temporary answer or an error only goes on record as a transient failure, every
    /// lease in flight, every save under way and the verified state standing, as the lookup's transient failure does
    /// since item 152's lead 1. Home's and Settings' refresh used to revoke everything on either.
    private func applyAccountStatus(_ state: AccountState) {
        accountState = state
        if state.isDefinitiveAbsence { invalidateAccountResolution() } else if !state.isReady { noteTransientFailure(TransientFailure(retryAfter: nil)) }
    }

    func refreshAccountState() async {
        let generation = identityGeneration
        #if DEBUG
        if let accountStatusForTesting {
            applyAccountStatus(accountStatusForTesting)
            return
        }
        #endif
        guard let container else {
            applyAccountStatus(.noAccount)
            return
        }
        do {
            let status: CKAccountStatus = try await Self.awaitWithDeadline(
                Self.accountStatusDeadline,
                onDeadline: { Log.cloud.error("accountStatus stalled past \(Self.accountStatusDeadline, privacy: .public)s — treating as an error state") },
                timeoutError: CKError(.networkFailure),
                start: { resume in
                    container.accountStatus { status, error in
                        if let error { resume(.failure(error)) } else { resume(.success(status)) }
                    }
                })
            guard generation == identityGeneration else { return }
            let state: AccountState
            switch status {
            case .available:            state = .available
            case .noAccount:            state = .noAccount
            case .restricted:           state = .restricted
            case .couldNotDetermine:    state = .error("could not determine")
            case .temporarilyUnavailable: state = .error("temporarily unavailable")
            @unknown default:           state = .error("unknown")
            }
            applyAccountStatus(state)
        } catch {
            guard generation == identityGeneration else { return }
            // A status error, the deadline included, is a temporary answer: nothing is revoked (item 155's A2).
            applyAccountStatus(.error(error.localizedDescription))
        }
    }

    // MARK: - Per-event upload serialization (1.2 coordinator; ADR 0003)

    /// The tail of each event's upload chain, plus a token so the last write out can clear
    /// its entry. Every CloudKit write for one event runs strictly after the previous write
    /// for that event has FINISHED — which closes review B2's residual race for good: two
    /// writes can no longer both preflight before either lands, so a stale fact retry can
    /// never overwrite a richer record from this process. Since 1.8.2 (item 162's A10) a push
    /// joins its event's chain before its identity lookup, which it makes at its turn, so the
    /// writes go out in the order they were asked for, not in the order their lookups answered;
    /// and each writes the log's copy of the event as it is then (`storedEvent`). Chains for
    /// different events stay concurrent; `retryPendingSync`'s bounded parallelism is unaffected.
    private var uploadChains: [UUID: Task<Void, Never>] = [:]
    private var uploadChainTokens: [UUID: Int] = [:]

    /// Runs `op` after everything already queued for `id`. Caller cancellation reaches only
    /// this work task; the chain still waits for it to drain before admitting the next writer.
    /// `op` observes cancellation cooperatively (the authorized wrapper declines canceled work).
    /// Internal rather than private so ordering and cancellation are pinned by tests.
    func enqueue<T: Sendable>(_ id: UUID, _ op: @escaping @MainActor () async -> T) async -> T {
        let previous = uploadChains[id]
        let token = (uploadChainTokens[id] ?? 0) + 1
        uploadChainTokens[id] = token
        let work = Task { () -> T in
            _ = await previous?.value
            return await op()
        }
        uploadChains[id] = Task { [weak self] in
            _ = await work.result
            // The last write out clears the entry, so the map never grows per-event forever.
            if let self, self.uploadChainTokens[id] == token {
                self.uploadChains[id] = nil
                self.uploadChainTokens[id] = nil
            }
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Two-shot exfiltration

    /// Outcome of an exfiltration attempt: the sync state to persist, plus — when the meta
    /// record failed terminally — whether that failure looked like interference or a refusal.
    /// `nil` when the meta record landed (only the heavy follow-up, if anything, is pending).
    struct ExfilOutcome: Equatable {
        let syncState: CloudSyncState
        let metaFailureWasInterference: Bool?
    }

    /// Whether a terminal CloudKit failure is consistent with *interference* — the network
    /// class: no path, a request that vanished — as opposed to a **refusal**, where Apple's
    /// servers answered and said no (a full quota, an auth lapse, a schema mismatch, an
    /// encrypted-key reset's `zoneNotFound`). The distinction decides whether the engine may
    /// treat a failed push as suspected jamming and go loud (32.R1): a refusal *reached the
    /// server*, so nothing is being jammed — sounding the blackout siren on a full iCloud
    /// would be a permanent false alarm asserting an attack that is not happening, in the
    /// owner's absence. See ADR 0001.
    ///
    /// Apple-side throttles and outages (`serviceUnavailable`, `requestRateLimited`,
    /// `zoneBusy`) are classified as refusals too: each is an *answer*, not a blocked path —
    /// and all three are retried with backoff before anyone consults this.
    nonisolated static func failureSuggestsInterference(_ error: Error) -> Bool {
        if var ck = error as? CKError {
            if ck.code == .partialFailure,
               let inner = ck.partialErrorsByItemID?.values.compactMap({ $0 as? CKError }).first {
                ck = inner
            }
            switch ck.code {
            case .networkUnavailable, .networkFailure, .serverResponseLost:
                return true
            default:
                return false
            }
        }
        // A bare transport error is network-class; any other unknown error is not evidence
        // of interference, and only evidence may escalate.
        return error is URLError
    }

    /// Pushes ONLY the metadata record — the "fact" of the tamper (+ the cross-device
    /// alert) — so it reaches iCloud immediately, before a possibly-long clip finishes
    /// recording. The full meta (with thumbnail) + media follow later via `exfiltrate`.
    /// Returns whether the record and any thumbnail it carries landed, so a caller re-pushing a record that was
    /// already `.synced` can reopen it for the sweep when either remains owed (item 65, finding 3).
    @discardableResult
    func pushFact(_ event: Event) async -> Bool {
        // Held from the first step, the queue wait and the identity lookup included (item 153's MAL-01): a push begun as
        // the phone is locked or the app killed runs under iOS's extra time.
        let assertion = BackgroundAssertion.begin("malinois-fact")
        defer { assertion.end() }
        // The event's queue first, the identity lookup at its turn (item 162's A10): the writes for one event go out in
        // the order they were asked for, not in the order their lookups answered, each with the log's copy as it is then.
        return await enqueue(event.id) { [self] in
            guard let lease = await acquireCloudLease() else {
                let current = storedEvent(event.id) ?? event
                if backupPermits(current) { factFailed(current) }
                return false
            }
            let current = storedEvent(event.id) ?? event
            let retryWanted = backupPermits(current)
            let landed = await underLease(lease, declined: false) {
                guard mayUpload(current, lease: lease) else { return false }
                return (await pushMetaRecord(current, lease: lease)).complete
            }
            // Within the queue: no newer queued save can finish before this failure is reconciled. Backup policy
            // that refused the attempt owes no retry; one already allowed can remain pending while backup is off.
            if !landed, retryWanted { factFailed(current) }
            return landed
        }
    }

    /// Pushes the event. Returns the final sync state to persist, with the meta failure's
    /// classification when there was one (32.R1).
    /// `fullMediaURL` is the on-disk full-res still or clip (may be nil);
    /// `secondaryMediaURL` is the second capture from the "Both" camera option.
    func exfiltrate(_ event: Event, fullMediaURL: URL?, secondaryMediaURL: URL? = nil) async -> ExfilOutcome {
        let declined = ExfilOutcome(syncState: .localOnly, metaFailureWasInterference: nil)
        let assertion = BackgroundAssertion.begin("malinois-evidence")   // from the queue wait on (item 153's MAL-01)
        defer { assertion.end() }
        // The event's queue first, the identity lookup at its turn, and the log's copy (item 162's A10), as `pushFact`.
        return await enqueue(event.id) { [self] in
            let attempt = await leaseAttempt()
            guard let lease = attempt.lease else {
                // A lookup that failed for want of a network is this push's network-class failure (item 152's lead 1),
                // and one the server throttled is a refusal (item 155's A3): the escalation's verdict hears each as it
                // would a save's (ADR 0001). A hold is no verdict, as before.
                return attempt.transient ? ExfilOutcome(syncState: .localOnly, metaFailureWasInterference: attempt.interference) : declined
            }
            let current = storedEvent(event.id) ?? event
            // `exfiltrateNow` declines an upload the event's account or the backup switch does not allow.
            return await underLease(lease, declined: declined) {
                await exfiltrateNow(current, fullMediaURL: fullMediaURL, secondaryMediaURL: secondaryMediaURL, lease: lease)
            }
        }
    }

    private func exfiltrateNow(_ event: Event, fullMediaURL: URL?, secondaryMediaURL: URL?,
                               lease: CloudEnrollment.Lease) async -> ExfilOutcome {
        guard enrollment.isCurrent(lease), mayUpload(event, lease: lease) else {
            // Authorization held the record locally; no server refusal or interference occurred.
            return ExfilOutcome(syncState: .localOnly, metaFailureWasInterference: nil)
        }

        // ---- Shot 1: tiny record (fast path) ----
        let meta = await pushMetaRecord(event, lease: lease)

        // ---- Shot 2: full-resolution follow-up(s) ----
        // Record names carry the camera ("photo-front" / "photo-rear") so they're
        // easy to tell apart in the CloudKit Console.
        // Each file that lands is noted on the event (`mediaLanded`), so a capture part of which is in iCloud is never
        // marked lost before upload (item 166's codex-23).
        var fullLanded = true
        if let url = fullMediaURL {
            fullLanded = await pushPhotoRecord(event, mediaURL: url,
                                               suffix: "photo-\(event.primaryMediaToken)", lease: lease)
            if fullLanded { mediaLanded(event.id, event.primaryMediaToken, event.receiptEpoch) }
        }
        if let url = secondaryMediaURL {
            let landed = await pushPhotoRecord(event, mediaURL: url,
                                               suffix: "photo-\(event.secondaryMediaToken)", lease: lease)
            if landed { mediaLanded(event.id, event.secondaryMediaToken, event.receiptEpoch) }
            fullLanded = landed && fullLanded
        }

        if let metaError = meta.error {
            return ExfilOutcome(syncState: .localOnly,
                                metaFailureWasInterference: Self.failureSuggestsInterference(metaError))
        }
        // Core evidence up; a thumbnail still owed or a missing full-res follow-up retries later.
        return ExfilOutcome(syncState: fullLanded && !meta.thumbnailPending ? .synced : .pending,
                            metaFailureWasInterference: nil)
    }

    // MARK: - Building records
    //
    // Split out of the push methods so the *write* half is testable without CloudKit:
    // `CKRecord` constructs fine with no container, so a unit test can build exactly the
    // record that ships, assert every custom field landed in the encrypted namespace, and
    // hand it to the decoder. That round trip is the guard against this project's one
    // shipped CloudKit bug — a record type that wrote fine and could never be read back.

    /// Builds the tamper-evidence record.
    ///
    /// Record names are **prefixed per generation** (`meta-v2-` here, `meta-` in 1.0). A
    /// `CKRecord.ID` is unique per *zone*, not per record type, so a V2 record reusing the
    /// 1.0 name would collide with the record already sitting there for any event pushed
    /// before the upgrade — and re-pushes are routine (a pending event flushed on reconnect,
    /// an owner attribution updating the record in place). That collision fails the save
    /// permanently and silently, on exactly the evidence that already exists.
    ///
    /// `thumbnailURL` backs the inlined thumbnail asset; the caller owns that temp file and
    /// deletes it once the upload finishes.
    /// The monotonic revision of this event's metadata record.
    ///
    /// Derived from the event rather than passed in by the caller, so it cannot disagree with
    /// what is actually being written: the sparse pre-capture fact is 1; each camera slot
    /// carrying evidence adds 1 (the first slot: a thumbnail, a stored media file, or a capture marked lost after
    /// local eviction; the second: its stored file or its camera's name,
    /// which survives the byte cap's eviction); an
    /// owner attribution adds 1. So a one-camera capture is 2, both cameras 3, and an
    /// owner-attributed re-push one more. The slots count separately because the second
    /// camera's evidence can arrive after the first's, as late evidence (item 108, CE-02): a
    /// device holding the first copy refused the copy that added the other camera, its equal
    /// revision. Counting confirmed loss preserves the first-slot increment after eviction (item 166's A2,
    /// Codex's codex-2). Without that term, a capture without a thumbnail could go back a revision when the byte
    /// cap took its file, and the copy that says the photo was lost was refused as older, here and on other devices.
    ///
    /// The capture stage is keyed on **evidence actually attached — never on `endDate`**
    /// (34-review B2). It used to be `endDate > startDate`, and the real fact is *born* that
    /// way: `respond()` stamps `endDate: Date()` against a `startDate` taken from an earlier
    /// sensor sample, so the "sparse" fact started at revision 2, equal revisions passed
    /// `mayWrite`, and the stale-fact-overwrites-rich regression this guard exists to stop
    /// was reachable the whole time. The Production check that "verified" the old guard —
    /// revisions 2 and 3 present, none stuck at 1 — was the flaw's own fingerprint: no
    /// record was ever 1.
    ///
    /// A camera-off event's rich push stays at revision 1, equal to its fact (BACKLOG 34), so
    /// revisions cannot order those two; the per-event chain (`enqueue`) does. Every write for
    /// one event runs through it, strictly after the previous one finished (1.2), in the order
    /// the pushes were asked for, each writing the log's copy as it is at its turn (1.8.2, item
    /// 162's A10: before, a push's identity lookup came first, so a slow one let the sparse
    /// fact land after the richer record and take back what the trip had added).
    nonisolated static func metaRevision(for event: Event) -> Int {
        var revision = 1
        if event.thumbnailData != nil || event.mediaFilename != nil || event.mediaDiscarded == true { revision += 1 }
        if event.secondaryMediaFilename != nil || event.secondaryCamera != nil { revision += 1 }
        if event.ownerAttributed == true { revision += 1 }
        return revision
    }

    /// Whether a write may proceed, given what has already reached the server for this event.
    ///
    /// Equal revisions are allowed — that is an ordinary retry of the same payload. Only a
    /// **strictly older** one is refused, which is the case that loses evidence: the fast fact
    /// stalls, the post-capture record with the thumbnail lands, and then the fact's retry
    /// completes last and replaces it with the sparse version. `.allKeys` overwrites server
    /// values without comparing change tags, so nothing below this stops it.
    nonisolated static func mayWrite(revision: Int, alreadySubmitted: Int?) -> Bool {
        guard let alreadySubmitted else { return true }
        return revision >= alreadySubmitted
    }

    nonisolated static func makeMetaRecord(_ event: Event,
                                           deviceName: String,
                                           thumbnailURL: URL?) -> CKRecord {
        let record = CKRecord(recordType: metaRecordTypeV2,
                              recordID: CKRecord.ID(recordName: "meta-v2-" + event.id.uuidString))
        record.encryptedValues["eventID"] = event.id.uuidString as CKRecordValue
        record.encryptedValues["startDate"] = event.startDate as CKRecordValue
        record.encryptedValues["endDate"] = event.endDate as CKRecordValue
        record.encryptedValues["duration"] = event.duration as CKRecordValue
        // Stored as a comma-joined string to avoid CKRecordValue array casting.
        record.encryptedValues["triggeredSensors"] =
            event.triggeredSensors.map { $0.rawValue }.joined(separator: ",") as CKRecordValue
        record.encryptedValues["deviceName"] = deviceName as CKRecordValue
        record.encryptedValues["revision"] = metaRevision(for: event) as CKRecordValue
        // Still a discrete field rather than a key inside the JSON blob, so a re-push after
        // owner attribution updates it in place (R-06). It is no longer *queryable* —
        // encrypted fields cannot be indexed — which costs nothing here: every query this
        // class makes is `NSPredicate(value: true)` over system fields.
        record.encryptedValues["ownerAttributed"] = ((event.ownerAttributed ?? false) ? 1 : 0) as CKRecordValue
        if let json = event.metadataJSON, let jsonString = String(data: json, encoding: .utf8) {
            record.encryptedValues["metadataJSON"] = jsonString as CKRecordValue
        }
        // The asset stays in the plain namespace: a `CKAsset` cannot be an encrypted value.
        // Its *content* is already encrypted toward the owner's keys by the private database,
        // which is why the media was never the exposed part — the metadata around it was.
        if let thumbnailURL {
            record["thumbnail"] = CKAsset(fileURL: thumbnailURL)
        }
        return record
    }

    /// Builds the full-resolution capture record. Same generation prefix rule as
    /// `makeMetaRecord`; `suffix` carries the camera so the two captures of a "Both" event
    /// are told apart in the CloudKit Console.
    nonisolated static func makePhotoRecord(_ event: Event, mediaURL: URL, suffix: String) -> CKRecord {
        let record = CKRecord(recordType: photoRecordTypeV2,
                              recordID: CKRecord.ID(recordName: "\(suffix)-v2-" + event.id.uuidString))
        record.encryptedValues["eventID"] = event.id.uuidString as CKRecordValue
        record.encryptedValues["capturedAt"] = event.startDate as CKRecordValue
        record["media"] = CKAsset(fileURL: mediaURL)
        return record
    }

    /// Builds an arm/disarm audit record — "protection went on/off at this time, on this
    /// device", and nothing else.
    nonisolated static func makeStateRecord(_ event: Event, kind: String, deviceName: String) -> CKRecord {
        let record = CKRecord(recordType: stateRecordTypeV2,
                              recordID: CKRecord.ID(recordName: "state-v2-" + event.id.uuidString))
        record.encryptedValues["eventID"] = event.id.uuidString as CKRecordValue
        record.encryptedValues["kind"] = kind as CKRecordValue
        record.encryptedValues["startDate"] = event.startDate as CKRecordValue
        record.encryptedValues["deviceName"] = deviceName as CKRecordValue
        return record
    }

    /// Pure (unit-tested; item 87): the name of the record an event goes up as: an audit
    /// record's state record, any other event's meta record (the builders' own names).
    nonisolated static func cloudRecordName(for event: Event) -> String {
        (event.isStateChange ? "state-v2-" : "meta-v2-") + event.id.uuidString
    }

    /// Pure (unit-tested; item 87): every name an event's record can be under in iCloud: its own
    /// (`cloudRecordName`) and, for evidence, also 1.0's `meta-<id>`. 1.0 uploaded evidence under
    /// that name and no audit records; 1.1 moved to `meta-v2-` and renamed nothing already in
    /// iCloud (see `makeMetaRecord`), so a record 1.0 uploaded is still there under it.
    nonisolated static func cloudRecordNames(for event: Event) -> [String] {
        let own = cloudRecordName(for: event)
        return event.isStateChange ? [own] : [own, "meta-" + event.id.uuidString]
    }

    /// Item 87: which of these record names the private database still holds, fetching no fields;
    /// nil when the answer is not conclusive (no account, a network error, any failure other
    /// than "no such record"). A transient failure goes on record for the pending sweep, as a
    /// save's does (item 166's codex-28).
    func presentRecordNames(_ names: [String]) async -> Set<String>? {
        guard !names.isEmpty else { return [] }
        guard let lease = await acquireCloudLease() else { return nil }
        return await presentRecordNames(names, lease: lease)
    }

    /// The same under a lease the caller holds, with no identity lookup of its own (item 166's codex-24: the pending
    /// sweep's pass asks under its own lease); nil too when that lease is no longer current.
    func presentRecordNames(_ names: [String], lease: CloudEnrollment.Lease) async -> Set<String>? {
        guard !names.isEmpty else { return [] }
        guard enrollment.isCurrent(lease) else { return nil }
        do {
            guard let results = try await presenceResults(names, lease: lease) else { return nil }
            try requireCurrent(lease)
            var present = Set<String>()
            var conclusive = true
            // Every result is read, so each failure's wait goes on record: one met first hides none after it (codex-30).
            for (name, result) in results {
                switch result {
                case .success:
                    present.insert(name)
                case .failure(let error):
                    if (error as? CKError)?.code == .unknownItem { continue }
                    noteIfTransient(error)
                    conclusive = false
                }
            }
            return conclusive ? present : nil
        } catch {
            noteIfTransient(error)
            return nil
        }
    }

    /// A transient failure of the presence fetch goes on record for the pending sweep, as a save's does (item 79): a
    /// wait iCloud named reaches the follow-up, and closes the pass's door before its uploads (item 166's codex-28).
    /// Each failure a partial one nests is read, and the longest wait stands (codex-30).
    private func noteIfTransient(_ error: Error) {
        for transient in Self.transientFailures(in: error) { noteTransientFailure(transient) }
    }

    /// Pure (unit-tested; item 166's codex-30): the transient failures `error` carries: its own, or each one a partial
    /// failure nests, where `transientFailure(from:)` reads only the first it finds.
    nonisolated static func transientFailures(in error: Error) -> [TransientFailure] {
        if let ck = error as? CKError, ck.code == .partialFailure, let nested = ck.partialErrorsByItemID?.values {
            return nested.flatMap { transientFailures(in: $0) }
        }
        return transientFailure(from: error).map { [$0] } ?? []
    }

    /// The presence check's fetch, fieldless: each name's result from the private database, in the order given; nil with
    /// no database. On an operation of its own within the read deadline (BACKLOG 180's A2 and codex-4); a test's
    /// stand-in for the fetch meets the deadline too.
    private func presenceResults(_ names: [String],
                                 lease: CloudEnrollment.Lease) async throws -> [(String, Result<Void, any Error>)]? {
        #if DEBUG
        if let fetch = presenceFetchForTesting { return try await withinReadDeadline { try await fetch(names) } }
        let heldByATest = readSubmitForTesting != nil
        #else
        let heldByATest = false
        #endif
        guard heldByATest || database != nil else { return nil }
        let results = try await recordsByID(names.map { CKRecord.ID(recordName: $0) }, desiredKeys: [], lease: lease)
        return names.map { name in
            (name, results[CKRecord.ID(recordName: name)]?.map { _ in () } ?? .failure(CKError(.networkFailure)))
        }
    }

    /// What an identity lookup found (item 152's lead 1; ADR 0039 amended for 1.8.1).
    enum IdentityLookup: Equatable {
        /// The signed-in account's record name.
        case named(String)
        /// iCloud's answer that there is none (or an empty name): invalidates, as it always has.
        case noAccount
        /// No answer: the network, a throttle, the deadline, or an account that is there but not ready yet (item
        /// 155's S2). Denies this caller only. `interference` is the network class, `retryAfter` the server's wait
        /// when it gave one (item 155's A3).
        case transient(interference: Bool, retryAfter: TimeInterval?)
        /// Resolved under a generation since replaced: void, and it changes nothing.
        case stale
    }

    /// Pure (unit-tested): the lookup's result classified.
    nonisolated static func identityLookup(_ result: Result<String?, Error>) -> IdentityLookup {
        switch result {
        case .success(let name):
            guard let name, !name.isEmpty else { return .noAccount }
            return .named(name)
        case .failure(let error):
            // The network class and the deadline (which is reported as a network failure), as `retryDelay` and
            // `failureSuggestsInterference` classify them; iCloud's "not authenticated" and anything unclassified
            // keep invalidating, as before.
            if let transient = Self.transientFailure(from: error) {
                return .transient(interference: Self.failureSuggestsInterference(error), retryAfter: transient.retryAfter)
            }
            if error is URLError { return .transient(interference: true, retryAfter: nil) }
            // iCloud's "the account is there but not ready" (item 155's S2, Codex's second look): a temporary answer,
            // as the status refresh's "temporarily unavailable" is (A2), not a missing account. Kept out of
            // `retryDelay`'s set on purpose: a save is not retried within milliseconds for it; the sweep's follow-up
            // and the next trigger re-ask.
            if (error as? CKError)?.code == .accountTemporarilyUnavailable { return .transient(interference: false, retryAfter: nil) }
            return .noAccount
        }
    }

    /// Item 87: the signed-in iCloud account's user record name (opaque, this app's own), or nil.
    func userRecordName() async -> String? {
        if case .named(let name) = await resolveIdentity() { return name }
        return nil
    }

    /// Resolves the account identity and applies what it found: a name resolves it, a different name invalidating
    /// first; no account invalidates; a transient failure (item 152's lead 1) denies this caller only, and goes on
    /// record as a network-class transient failure for the pending sweep's follow-up, leaving every lease in flight,
    /// every save under way and the verified state as they are. The account-changed notice still invalidates.
    private func resolveIdentity() async -> IdentityLookup {
        let generation = identityGeneration
        let lookup = await lookUpIdentity()
        guard generation == identityGeneration else { return .stale }
        switch lookup {
        case .named(let name):
            if let resolvedAccount, resolvedAccount != name { invalidateAccountResolution() }
            resolvedAccount = name
            accountState = .available
        case .noAccount:
            invalidateAccountResolution()
        case .transient(_, let retryAfter):
            noteTransientFailure(TransientFailure(retryAfter: retryAfter))
        case .stale:
            break
        }
        return lookup
    }

    /// A lease, or why not (item 152's lead 1): a transient identity failure is this caller's own network-class
    /// failure, which an evidence push reports as its verdict (`exfiltrate`).
    private func leaseAttempt() async -> (lease: CloudEnrollment.Lease?, transient: Bool, interference: Bool) {
        let lookup = await resolveIdentity()
        if case .named(let name) = lookup { return (enrollment.authorize(account: name), false, false) }
        if case .transient(let interference, _) = lookup { return (nil, true, interference) }
        return (nil, false, false)
    }

    /// The lookup itself: the test seam's answer, or iCloud's.
    private func lookUpIdentity() async -> IdentityLookup {
        #if DEBUG
        if let accountIdentityForTesting {
            do { return Self.identityLookup(.success(try await accountIdentityForTesting())) } catch {
                return Self.identityLookup(.failure(error))
            }
        }
        #endif
        return await fetchAccountIdentity()
    }

    private func fetchAccountIdentity() async -> IdentityLookup {
        guard let container else { return .noAccount }
        do {
            let name: String = try await Self.awaitWithDeadline(
                Self.accountStatusDeadline, onDeadline: {}, timeoutError: CKError(.networkFailure),
                start: { resume in
                    container.fetchUserRecordID { id, error in
                        if let error { resume(.failure(error)) }
                        else if let id { resume(.success(id.recordName)) }
                        else { resume(.failure(CKError(.notAuthenticated))) }
                    }
                })
            return Self.identityLookup(.success(name))
        } catch {
            return Self.identityLookup(.failure(error))
        }
    }

    /// Builds the disarm signal (BACKLOG 59) — see `disarmSignalRecordTypeV2`. Carries only
    /// what a mirror would need to correlate it: the event id, when, and which device — all
    /// encrypted, like the audit record it accompanies.
    nonisolated static func makeDisarmSignalRecord(_ event: Event, deviceName: String) -> CKRecord {
        let record = CKRecord(recordType: disarmSignalRecordTypeV2,
                              recordID: CKRecord.ID(recordName: "disarm-v2-" + event.id.uuidString))
        record.encryptedValues["eventID"] = event.id.uuidString as CKRecordValue
        record.encryptedValues["startDate"] = event.startDate as CKRecordValue
        record.encryptedValues["deviceName"] = deviceName as CKRecordValue
        return record
    }

    /// Pure (unit-tested): the disarm alert fires for a disarm and for a cancelled countdown
    /// (review 3, R3.2) — both stop future protection, which is what the alert exists to tell
    /// the owner's other devices; the mirrored record carries the exact reason. Arms, Guided
    /// Access lifts and a kill's launch-time record stay silent, which is the whole reason the
    /// audit type has no subscription of its own.
    nonisolated static func disarmSignalWanted(kind: String) -> Bool {
        kind == "disarmed" || kind == "armingCancelled"
    }

    /// The metadata save's result, including a thumbnail still owed after a successful sparse save.
    private struct MetaPushResult {
        let error: Error?
        let thumbnailPending: Bool
        var complete: Bool { error == nil && !thumbnailPending }
    }

    /// Saves the fact even when its thumbnail cannot stage. A successful sparse save with a thumbnail owed stays
    /// pending for retry; a save error keeps its classification. A richer record already submitted is complete.
    private func pushMetaRecord(_ event: Event, lease: CloudEnrollment.Lease) async -> MetaPushResult {
        guard enrollment.isCurrent(lease), mayUpload(event, lease: lease) else {
            return MetaPushResult(error: CKError(.notAuthenticated), thumbnailPending: false)
        }
        // Inline the few-KB thumbnail as an asset. The temp file backing the
        // CKAsset is deleted once the upload finishes (see defer) so it doesn't
        // accumulate one orphan per event.
        var tempAssetURL: URL?
        if let thumb = event.thumbnailData {
            tempAssetURL = writeTemp(thumb, ext: "jpg")
        }
        defer { if let tempAssetURL { Self.removeTemporaryThumbnail(tempAssetURL) } }

        let revision = Self.metaRevision(for: event)
        guard Self.mayWrite(revision: revision, alreadySubmitted: submittedMetaRevisions[event.id]) else {
            // A richer record is already on the server; this is a stale retry of an earlier one.
            // Reported as landed, because the event *is* in iCloud — just in better shape than
            // this write would have left it.
            Log.cloud.info("Skipped a stale meta write (revision \(revision, privacy: .public))")
            return MetaPushResult(error: nil, thumbnailPending: false)
        }
        let record = Self.makeMetaRecord(event,
                                         deviceName: DeviceInfo.name,
                                         thumbnailURL: tempAssetURL)
        do {
            try await save([record], lease: lease, permitted: { backupPermits(event) })
            submittedMetaRevisions[event.id] = max(submittedMetaRevisions[event.id] ?? 0, revision)
            return MetaPushResult(error: nil, thumbnailPending: event.thumbnailData != nil && tempAssetURL == nil)
        } catch {
            Log.cloud.error("Meta push failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            if Self.indicatesEncryptedDataReset(error) { encryptedDataResetDetected = true }
            return MetaPushResult(error: error, thumbnailPending: false)
        }
    }

    private func pushPhotoRecord(_ event: Event, mediaURL: URL, suffix: String,
                                 lease: CloudEnrollment.Lease) async -> Bool {
        guard enrollment.isCurrent(lease), mayUpload(event, lease: lease) else { return false }
        guard FileManager.default.fileExists(atPath: mediaURL.path) else { return false }
        let record = Self.makePhotoRecord(event, mediaURL: mediaURL, suffix: suffix)

        do {
            try await save([record], lease: lease, permitted: { backupPermits(event) })
            return true
        } catch {
            Log.cloud.error("Photo push failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            // The encrypted-data reset is visible on ANY save, not only meta pushes
            // (eighth review, L7) — recovery used to wait for the next meta failure.
            if Self.indicatesEncryptedDataReset(error) { encryptedDataResetDetected = true }
            return false
        }
    }

    /// Pushes an arm/disarm record to the owner's private database (BACKLOG 8).
    ///
    /// Why this exists: the local arm/disarm log is what proves *when* protection stopped,
    /// and it is the one record a PIN-holding attacker most wants gone. They cannot delete
    /// it through the UI, but deleting the whole app takes the local log with it. A cloud
    /// copy survives that. Silent by construction — see `stateRecordType`.
    @discardableResult
    func pushStateChange(_ event: Event, disarmSignal: Bool = true) async -> Bool {
        let assertion = BackgroundAssertion.begin("malinois-state")   // from the lookup on (item 153's MAL-01)
        defer { assertion.end() }
        guard let kind = event.stateChange, let lease = await acquireCloudLease(),
              mayUpload(event, lease: lease) else { return false }
        return await enqueueAuthorized(event.id, lease: lease, declined: false) { [self] in
            // A queued state change must retain the account that owned it at creation.
            guard enrollment.isCurrent(lease), mayUpload(event, lease: lease) else { return false }
            let record = Self.makeStateRecord(event, kind: kind, deviceName: DeviceInfo.name)
            do {
                try await save([record], lease: lease, permitted: { backupPermits(event) })
            } catch {
                Log.cloud.error("State push failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                if Self.indicatesEncryptedDataReset(error) { encryptedDataResetDetected = true }
                return false
            }
            // The disarm signal rides BEHIND the audit record, never in front of it (BACKLOG
            // 59): the record that proves WHEN protection stopped is the one that must land;
            // the push is a courtesy on top. Its failure — most likely the type not yet
            // deployed to Production — is logged and otherwise ignored, so the audit record's
            // sync state stays truthful.
            // `disarmSignal` false: a late disarm the pending sweep does not alert for (item 74 line 9).
            if disarmSignal, Self.disarmSignalWanted(kind: kind) {
                let signal = Self.makeDisarmSignalRecord(event, deviceName: DeviceInfo.name)
                do {
                    try await save([signal], lease: lease, permitted: { backupPermits(event) })
                } catch {
                    Log.cloud.error("Disarm signal push failed (the audit record landed): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                }
            }
            return true
        }
    }

    /// The disarm signal alone, for a late disarm whose audit record has already landed: the pending sweep's one
    /// "disarmed" alert, when the newest late disarm of the pass, which was to carry it, did not land (item 162's
    /// ds4f1-1017-6). As in `pushStateChange`, its failure is logged and otherwise ignored.
    func pushDisarmSignal(_ event: Event) async {
        guard let kind = event.stateChange, Self.disarmSignalWanted(kind: kind) else { return }
        let assertion = BackgroundAssertion.begin("malinois-state")
        defer { assertion.end() }
        guard let lease = await acquireCloudLease(), mayUpload(event, lease: lease) else { return }
        _ = await enqueueAuthorized(event.id, lease: lease, declined: false) { [self] in
            guard enrollment.isCurrent(lease), mayUpload(event, lease: lease) else { return false }
            let signal = Self.makeDisarmSignalRecord(event, deviceName: DeviceInfo.name)
            do {
                try await save([signal], lease: lease, permitted: { backupPermits(event) })
                return true
            } catch {
                Log.cloud.error("Late disarm signal push failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
                return false
            }
        }
    }

    // MARK: - Reading back (BACKLOG 9b)

    /// A thumbnail is at most 200 px, a JPEG at q0.4 (a still's, `CameraController.thumbnail`)
    /// or q0.5 (a clip's, `videoThumbnail`): a few KB for a real scene, and about 21 KB and
    /// 27 KB for pure noise, the most one can be. A fetched "thumbnail" beyond 64 KiB is not
    /// one — a corrupted or hand-crafted record — and inlining it would bloat the log the
    /// mirror fetch is meant to keep small. The bound was 512 KiB until 1.8.2's step 32 (item
    /// 152's lead 9): each copy could then add about 683 KB to the log every launch reads whole.
    nonisolated static let maxThumbnailBytes = 64 * 1024

    /// Upper bounds for cloud scalars (sixth review, F6). Generous by orders of magnitude —
    /// real revisions are 1–3 and counts grow one per trip — but bounded, because a giant
    /// revision freezes `supersedes` and a giant count freezes the count-repair ordering:
    /// mirror poisoning through the two fields that decide who supersedes whom.
    nonisolated static let maxCloudRevision = 1_000
    nonisolated static let maxCloudSustainedCount = 100_000

    nonisolated static func validRevision(_ n: Int?) -> Int? {
        n.flatMap { (1...maxCloudRevision).contains($0) ? $0 : nil }
    }

    nonisolated static func validSustainedCount(_ n: Int?) -> Int? {
        n.flatMap { (1...maxCloudSustainedCount).contains($0) ? $0 : nil }
    }

    /// Wrong-PIN attempts on one record (item 49). The lockout allows five quick tries and then
    /// waits 30 s, doubling, so one capture's window holds a handful at most; the bound is
    /// generous by orders of magnitude, and zero or negative is not a count.
    nonisolated static let maxCloudWrongPINCount = 1_000

    nonisolated static func validWrongPINCount(_ n: Int?) -> Int? {
        n.flatMap { (1...maxCloudWrongPINCount).contains($0) ? $0 : nil }
    }

    /// A cloud endDate is believed only within (start, start + 24 h] — no single event
    /// spans a day (until-clear caps at 120 s), and an absurd value poisons durations.
    nonisolated static func clampedEndDate(_ end: Date?, start: Date) -> Date {
        guard let end, end > start else { return start }
        return min(end, start.addingTimeInterval(86_400))
    }

    /// A cloud startDate is believed at most a day past the record's own server-stamped
    /// `creationDate` — or "now" for a record that never got one (fourth-pass R3-4: the
    /// one scalar the F6 clamp suite missed). Future-dated values sort ahead of first-hand
    /// evidence and, at the event cap, drive eviction — the lever that turned bounded
    /// mirror insertion (R2-F3) into local-evidence destruction. Clamped rather than
    /// dropped: the event may be real and only its source clock wrong. The past stays
    /// unbounded — old evidence is legitimate, and it self-harms an attacker (evicts
    /// first).
    nonisolated static func clampedStartDate(_ start: Date, recordCreated: Date?, now: Date) -> Date {
        min(start, (recordCreated ?? now).addingTimeInterval(86_400))
    }

    /// A device label's bytes (1.8.2's step 32, item 152's lead 9): 64 characters can be any number of bytes, since
    /// a letter with any number of accent marks is one character. 2,048 hold any real label (a phone sends at most 40
    /// characters).
    nonisolated static let maxDeviceNameBytes = 2_048

    /// Device labels from the cloud are display strings, not protocol — cap them (F6; the
    /// outbound side is already sanitized at entry, this bounds a hand-crafted record): 64
    /// characters and, since 1.8.2's step 32, `maxDeviceNameBytes`, cut between characters.
    /// A label with nothing left reads as an empty one does.
    nonisolated static func sanitizedDeviceName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "another device" }
        var kept = ""
        var bytes = 0
        for character in raw.prefix(64) {
            bytes += character.utf8.count
            guard bytes <= maxDeviceNameBytes else { break }
            kept.append(character)
        }
        return kept.isEmpty ? "another device" : kept
    }

    /// File size via metadata, checked BEFORE any read (sixth review, F6): a hostile
    /// asset the size of a movie must be rejected without ever being loaded.
    nonisolated static func fileSizeAcceptable(_ url: URL, limit: Int) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return size <= limit
    }

    /// Reads one custom field, preferring the encrypted namespace and falling back to the
    /// plain one, so a single decoder covers both record generations (BACKLOG 19).
    ///
    /// The two namespaces are strictly separate in CloudKit: a value written plainly is
    /// invisible through `encryptedValues`, and an encrypted one is invisible through the
    /// plain subscript. That is what makes this unambiguous — for any given field exactly one
    /// of the two can hold a value, so the fallback can never read a stale or wrong copy.
    nonisolated static func customField(_ key: String, of record: CKRecord) -> Any? {
        record.encryptedValues[key] ?? record[key]
    }

    /// Decodes a tamper-evidence record — either generation — into an `Event`, or `nil` if it
    /// is unusable.
    ///
    /// Deliberately `nonisolated static` and free of any container or database reference, so
    /// it is unit-testable on the Simulator where CloudKit itself is unavailable. That
    /// matters more than usual here: this is the only part of the fetch path that can be
    /// covered locally, and decoding is where a mistake would quietly corrupt the evidence
    /// log. `CKRecord(recordType:)` constructs fine without a container, so tests build real
    /// records rather than a stand-in.
    ///
    /// Returns `nil` rather than a half-populated `Event` when an identifying field is
    /// missing — a partial record in the evidence log is worse than no record.
    nonisolated static func event(from record: CKRecord) -> Event? {
        guard let idString = customField("eventID", of: record) as? String,
              let id = UUID(uuidString: idString),
              let rawStart = customField("startDate", of: record) as? Date
        else { return nil }
        let start = clampedStartDate(rawStart, recordCreated: record.creationDate, now: Date())

        // Unknown raw values are dropped: SensorType is a closed enum, so an older build
        // merging from a newer one cannot represent a sensor it has never heard of. Dropping
        // loses a detail; inventing a case would corrupt the record. Each tripwire is kept
        // once (1.8.2's step 32, item 152's lead 12): a list naming one thousands of times
        // names that one.
        let sensors = Self.uniqueSensors(((customField("triggeredSensors", of: record) as? String) ?? "")
            .split(separator: ",")
            .compactMap { SensorType(rawValue: String($0)) })

        // The few-KB thumbnail rides the meta record, in the plain namespace in both
        // generations — a CKAsset cannot be encrypted, and does not need to be. The
        // full-resolution capture lives in a separate photo record and is deliberately NOT
        // pulled here — a mirror fetch must stay small enough to run on a push wake-up.
        var thumbnail: Data?
        if let asset = record["thumbnail"] as? CKAsset, let url = asset.fileURL,
           Self.fileSizeAcceptable(url, limit: Self.maxThumbnailBytes),   // judge by metadata BEFORE reading (F6)
           let data = try? Data(contentsOf: url),
           data.count <= Self.maxThumbnailBytes {   // a "thumbnail" the size of a photo is not one
            thumbnail = data
        }

        // Fields that exist only inside the JSON blob — never promoted to top-level record
        // fields. Payload v2 (34's metadataJSON item) added what a mirror used to lose:
        // sustained count, camera identities, durations, the discard marker, and the media
        // manifest. Every value is bounded or allow-listed on the way in — this is cloud
        // input, and a nonsensical value is dropped rather than obeyed, same as `revision`.
        var interrupted: Bool?
        var interruptionCause: String?
        var capturedOffline: Bool?
        var sustainedCount: Int?
        var primaryCamera: String?, secondaryCamera: String?
        var primaryDuration: Double?, secondaryDuration: Double?
        var mediaDiscarded: Bool?
        var captureFailure: String?
        var captureFailuresByCamera: [String: String]?
        var manifest: [String]?
        var wrongPINCount: Int?
        var thermalState: String?
        if let json = customField("metadataJSON", of: record) as? String,
           let data = json.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            interrupted = obj["interrupted"] as? Bool
            interruptionCause = Self.validInterruptionCause(obj["interruptionCause"] as? String)
            capturedOffline = obj["capturedOffline"] as? Bool
            sustainedCount = Self.validSustainedCount(obj["sustainedCount"] as? Int)
            primaryCamera = Self.validCameraToken(obj["primaryCamera"] as? String)
            secondaryCamera = Self.validCameraToken(obj["secondaryCamera"] as? String)
            primaryDuration = Self.validDuration(obj["primaryDuration"] as? Double)
            secondaryDuration = Self.validDuration(obj["secondaryDuration"] as? Double)
            mediaDiscarded = obj["mediaDiscarded"] as? Bool
            captureFailure = Self.validCaptureFailure(obj["captureFailure"] as? String)
            if let raw = obj["captureFailuresByCamera"] as? [String: Any] {
                var failures: [String: String] = [:]
                for camera in ["front", "rear"] {
                    if let reason = Self.validCaptureFailure(raw[camera] as? String) { failures[camera] = reason }
                }
                captureFailuresByCamera = failures.isEmpty ? nil : failures
            }
            wrongPINCount = Self.validWrongPINCount(obj["wrongPINCount"] as? Int)
            thermalState = Self.validThermalState(obj["thermalState"] as? String)
            if let raw = obj["media"] as? [Any] {
                let tokens = Self.uniqueMediaTokens(raw.compactMap { $0 as? String })
                manifest = tokens.isEmpty ? nil : tokens
            }
        }

        return Event(
            id: id,
            startDate: start,
            endDate: Self.clampedEndDate(customField("endDate", of: record) as? Date, start: start),
            triggeredSensors: sensors,
            // mediaFilename is intentionally left nil: the file is not on this device, and
            // EventDetailView renders "full media not on this device" — with an on-demand
            // download (34.B1) — for exactly this case. Naming a file that isn't there
            // would be a broken image instead.
            thumbnailData: thumbnail,
            primaryCamera: primaryCamera,
            primaryDuration: primaryDuration,
            secondaryCamera: secondaryCamera,
            secondaryDuration: secondaryDuration,
            cloudSyncState: .synced,          // it came *from* the cloud
            capturedOffline: capturedOffline,
            sustainedCount: sustainedCount,
            ownerAttributed: (customField("ownerAttributed", of: record) as? Int).map { $0 == 1 },
            interrupted: interrupted,
            interruptionCause: interruptionCause,
            sourceDevice: Self.sanitizedDeviceName(customField("deviceName", of: record) as? String),
            // Lets a mirrored copy be replaced by a later revision of itself instead of being
            // frozen at whichever one arrived first (see `EventStore.supersedes`). The merge
            // trusts this ordering, so a nonsensical value is dropped rather than obeyed.
            cloudRevision: Self.validRevision(customField("revision", of: record) as? Int),
            mediaDiscarded: mediaDiscarded,
            captureFailure: captureFailure,
            captureFailuresByCamera: captureFailuresByCamera,
            cloudMediaManifest: manifest,
            wrongPINCount: wrongPINCount,
            thermalState: thermalState)
    }

    /// A thermal state from the cloud (item 38): only the four iOS names; anything else is dropped.
    nonisolated static func validThermalState(_ raw: String?) -> String? {
        raw.flatMap { ["nominal", "fair", "serious", "critical"].contains($0) ? $0 : nil }
    }

    /// The only camera tokens a cloud payload may name. The manifest's feed record-name
    /// construction on the retrieval side, so anything else is dropped, not obeyed (the
    /// validation-caps rule: allow-list whatever becomes an identifier).
    nonisolated static let allowedMediaTokens: Set<String> = ["front", "rear", "primary", "secondary"]

    /// Pure (unit-tested): a media list's allowed names, each once, in the order it first came: four at most (1.8.2's
    /// step 32, item 152's lead 11). The decoder's rule, and the download's (codex-13: whatever list a record holds).
    nonisolated static func uniqueMediaTokens(_ raw: [String]) -> [String] {
        var tokens: [String] = []
        for token in raw where allowedMediaTokens.contains(token) && !tokens.contains(token) {
            tokens.append(token)
        }
        return tokens
    }

    /// Pure (unit-tested): each tripwire once, in the decoder's order (1.8.2's step 32, item 152's lead 12).
    nonisolated static func uniqueSensors(_ sensors: [SensorType]) -> [SensorType] {
        Set(sensors).sorted { $0.rawValue < $1.rawValue }
    }

    /// A copy from iCloud held to what a real record carries, as the decoder holds a record it reads (1.8.2's step 32):
    /// each tripwire and each media name once, a thumbnail of at most `maxThumbnailBytes`, a device name within
    /// `sanitizedDeviceName`'s limits, and a status kind's number in its canonical form (`Event.canonicalStatusKind`).
    /// For the copies an older version saved before those limits (codex-13 on 1.8.2, twice): the log applies it as it
    /// loads. This iPhone's own records pass unchanged.
    nonisolated static func boundedCopy(_ event: Event) -> Event {
        guard event.isMirrored else { return event }
        var copy = event
        copy.triggeredSensors = uniqueSensors(event.triggeredSensors)
        copy.cloudMediaManifest = event.cloudMediaManifest.map(uniqueMediaTokens).flatMap { $0.isEmpty ? nil : $0 }
        if let thumbnail = event.thumbnailData, thumbnail.count > maxThumbnailBytes { copy.thumbnailData = nil }
        copy.sourceDevice = sanitizedDeviceName(event.sourceDevice)
        copy.stateChange = event.stateChange.map(Event.canonicalStatusKind)
        return copy
    }
    /// Camera display fields are narrower still: only the two real cameras.
    nonisolated static func validCameraToken(_ raw: String?) -> String? {
        raw.flatMap { $0 == "front" || $0 == "rear" ? $0 : nil }
    }
    /// A clip duration from the cloud: finite, non-negative, and no longer than a day.
    nonisolated static func validDuration(_ raw: Double?) -> Double? {
        raw.flatMap { $0.isFinite && $0 >= 0 && $0 <= 86_400 ? $0 : nil }
    }
    /// An interruption cause from the cloud (BACKLOG 53): only the values this build knows.
    /// Anything else — a newer build's vocabulary, or garbage — is dropped, and the record
    /// stays a bare "interrupted" (`Event.sensorSummary` reads nil as unclassified).
    nonisolated static func validInterruptionCause(_ raw: String?) -> String? {
        raw.flatMap { InterruptionCause(rawValue: $0)?.rawValue }
    }
    /// A capture-failure reason from the cloud (item 54): only the values this build knows.
    nonisolated static func validCaptureFailure(_ raw: String?) -> String? {
        raw.flatMap { CaptureFailureReason(rawValue: $0)?.rawValue }
    }

    /// Decodes an arm/disarm audit record — either generation — into an `Event`.
    ///
    /// These carry no sensors, no media and no traces; the whole record is "protection went
    /// on/off at this time, on this device". `kind` is the `stateChange` string, so a restored
    /// entry renders exactly like a locally-logged one.
    nonisolated static func stateEvent(from record: CKRecord) -> Event? {
        guard let idString = customField("eventID", of: record) as? String,
              let id = UUID(uuidString: idString),
              let rawStart = customField("startDate", of: record) as? Date,
              let kind = customField("kind", of: record) as? String,
              // Allow-list (34 review, validation): an unknown kind — a future build's new
              // state, or a corrupted field — must be dropped, not rendered. It used to fall
              // through `sensorSummary` and display as "Signal loss", which asserts an attack.
              ["armed", "disarmed", "gaLifted", "cameraError", "armingCancelled", "armingInterrupted",
               "thermalSerious", "thermalCritical",   // item 38
               "soundUnavailable", "soundRestored",   // item 105, F-09
               "motionStalled",   // item 144 (g)
               "reinstalled",   // item 148's 5
               "pinChanged", "guidedAccessEnded",   // item 153's MAL-03 and MAL-05
               "unsyncedRemoved",   // item 114
               "reArmSkipped",   // item 153's MAL-10
               "settingsReset",   // codex-10
               Event.backupOffKind, Event.backupOnKind].contains(kind)   // item 115
                || Event.isProtectionChangeKind(kind)   // item 91; the seven settings since 1.8.2's step 22
                || Event.clockChangeSeconds(kind: kind) != nil   // item 113
                || Event.resumedSeconds(kind: kind) != nil   // item 153's MAL-06
                || Event.sirenElsewhereDevice(kind: kind) != nil   // 1.8.2's step 26 (ADR 0062)
        else { return nil }
        let start = clampedStartDate(rawStart, recordCreated: record.creationDate, now: Date())
        return Event(id: id, startDate: start, endDate: start,
                     triggeredSensors: [],
                     cloudSyncState: .synced,
                     stateChange: kind,
                     sourceDevice: sanitizedDeviceName(customField("deviceName", of: record) as? String))
    }

    /// Pulls recent evidence **and** the arm/disarm audit trail out of the owner's private
    /// database, only with a current enrolled-account lease; stale results are discarded.
    ///
    /// Two record types, two queries. They live apart on purpose — see `stateRecordType`,
    /// where the split exists so a routine arm can't fire the "Tamper detected" alert — but
    /// both have to come back. Fetching only the evidence left the audit trail write-only,
    /// which is precisely the flaw this whole read path exists to fix, on the one record type
    /// whose only job is surviving an attacker who deletes the app.
    ///
    /// Four queries, because two generations of schema can hold the owner's evidence
    /// (BACKLOG 19): the encrypted V2 types everything is written to now, and the 1.0 types
    /// that may still hold records pushed before the migration. Reading both is what keeps
    /// that older evidence from being orphaned. `EventStore.merged` dedupes on the event id,
    /// so an event present in *both* generations — a 1.0 record a later build re-pushed as
    /// V2 — still lands in the log exactly once.
    ///
    /// ⚠️ Every queried record type must be **queryable** in the CloudKit schema (a
    /// `recordName` QUERYABLE index, plus `createdTimestamp` SORTABLE for the sort). An
    /// unindexed type makes the query *fail* rather than return nothing — which is why each
    /// query is isolated below: a missing index on one type must not take the others down
    /// with it, and during the migration the 1.0 types are exactly the ones most likely to be
    /// missing from a freshly-deployed container.
    func fetchRecentEvents(limit: Int = fetchPageSize) async -> [Event] {
        lastFetchComplete = false
        lastFetchFailed = true
        #if DEBUG
        let heldByATest = readSubmitForTesting != nil
        #else
        let heldByATest = false
        #endif
        guard let lease = await acquireCloudLease(), heldByATest || database != nil else { return [] }
        let metaV2 = await fetch(Self.metaRecordTypeV2,
                                 limit: limit, lease: lease, decode: Self.event(from:))
        let metaV1 = await fetch(Self.metaRecordType,
                                 limit: limit, lease: lease, decode: Self.event(from:))
        let stateV2 = await fetch(Self.stateRecordTypeV2,
                                  limit: limit, lease: lease, decode: Self.stateEvent(from:))
        let stateV1 = await fetch(Self.stateRecordType,
                                  limit: limit, lease: lease, decode: Self.stateEvent(from:))
        guard enrollment.isCurrent(lease) else { lastFetchFailed = true; return [] }
        lastFetchFailed = [metaV2, metaV1, stateV2, stateV1].contains { !$0.ok }
        lastFetchComplete = !lastFetchFailed
        let evidence = metaV2.events + metaV1.events
        let stateChanges = stateV2.events + stateV1.events
        Log.cloud.info("Fetched \(evidence.count, privacy: .public) event(s) + \(stateChanges.count, privacy: .public) state record(s)")
        let events = evidence + stateChanges
        guard enrollment.registerRemoteEvents(events, lease: lease) else {
            lastFetchComplete = false
            lastFetchFailed = true
            return []
        }
        let permitted = events.filter { enrollment.authorizeRecord($0.id, lease: lease) }
        if permitted.count != events.count {
            // An ID already belonging to another account (or unbound local evidence) is
            // not permission to replace its metadata during restore.
            lastFetchFailed = true
            lastFetchComplete = false
        }
        return permitted
    }

    /// How many records to ask for per round trip. Paging is bounded rather than unbounded so a
    /// push wake-up can't turn into twenty sequential requests.
    /// `nonisolated` for the same reason as the record-type constants above: it is a default
    /// argument of `fetchRecentEvents` and of the engine's `syncFromCloud`, and default
    /// arguments are evaluated in a nonisolated context — Swift 5 warns, Swift 6 refuses
    /// (33-review L1). An immutable Sendable Int needs no isolation.
    nonisolated static let fetchPageSize = 100

    /// One record type's worth of fetch-and-decode. Failures are contained to the caller's
    /// record type and logged with it named, so "restore brought back evidence but no
    /// arm/disarm rows" points straight at that type's index rather than at the fetch.
    /// `decode` is deliberately not `@Sendable`: it is called synchronously inside this
    /// function and never crosses an isolation boundary, and marking it so only produced a
    /// non-Sendable-conversion warning at every call site.
    /// Returns the decoded events **and whether the fetch was clean**: the query ran to the
    /// end AND every matched record was individually readable. The two failure shapes are not
    /// "no events": an unindexed record type makes the query *fail*, and a per-record failure
    /// inside a page is a record that exists but was not checked (R3-3) — reporting either as
    /// absence is how a broken restore looks identical to an empty one.
    private func fetch(_ recordType: String,
                       limit: Int,
                       lease: CloudEnrollment.Lease,
                       decode: (CKRecord) -> Event?) async -> (events: [Event], ok: Bool) {
        guard enrollment.isCurrent(lease) else { return ([], false) }
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var out: [Event] = []
        var sawRecordFailure = false
        var cursor: CKQueryOperation.Cursor?
        do {
            // Follow the cursor. A single `records(matching:)` returns one page and hands back a
            // cursor for the rest; discarding it silently capped a restore at one page per record
            // type, however much was actually in iCloud. The owner passed 90 events in August, so
            // this was days away from quietly dropping the oldest evidence from every restore —
            // and a restore that returns *most* of the log looks exactly like one that worked.
            repeat {
                try requireCurrent(lease)
                let (matches, next) = try await queryPage(query, from: cursor, lease: lease)
                try requireCurrent(lease)
                sawRecordFailure = sawRecordFailure || Self.queryPageSawFailure(matches)
                out += matches.compactMap { _, result -> Event? in
                    guard case .success(let record) = result else { return nil }
                    return decode(record)
                }
                cursor = next
            } while cursor != nil && out.count < limit
            if sawRecordFailure {
                Log.cloud.error("Fetch of \(recordType, privacy: .public): per-record failure(s) in the results — reporting the fetch incomplete")
            }
            return (out, !sawRecordFailure)
        } catch {
            Log.cloud.error("Fetch of \(recordType, privacy: .public) failed after \(out.count, privacy: .public) record(s): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            // Partial results are kept: half a restore is worth more than none, and the `false`
            // tells the push path to report `.failed` so iOS knows to try again.
            return enrollment.isCurrent(lease) ? (out, false) : ([], false)
        }
    }

    // MARK: - Full-media retrieval (BACKLOG 34.B1)

    /// What a downloaded full-resolution capture arrived as: which camera the record name
    /// carries (nil for the legacy "primary"/"secondary" fallbacks), and the CloudKit-managed
    /// temp file holding its content.
    struct FetchedMedia {
        /// The record-name slot token this capture lived under (front/rear, or the legacy
        /// primary/secondary) — its IDENTITY for reconciliation; arrival order means
        /// nothing (ext-review #2).
        let slot: String
        let camera: String?
        let fileURL: URL
    }

    /// Every record name this event's full-resolution captures could live under, across both
    /// schema generations, v2 first. Deterministic names are what make retrieval possible
    /// with NO schema change: a fetch by record ID needs no queryable index, so this works
    /// against the Production container exactly as deployed (ADR 0002). The camera token is
    /// the same set `exfiltrate` writes: front/rear, with primary/secondary as the fallback
    /// the uploader uses when an event carries no camera name.
    /// With a manifest (the payload's list of what the capturing device uploaded), retrieval
    /// fetches exactly those slots; without one — old records — the blind four-slot probe
    /// stands. Manifest tokens were allow-listed at decode, so nothing here builds a record
    /// name from unvalidated input.
    nonisolated static func fullMediaRecordNames(for eventID: UUID,
                                                 manifest: [String]? = nil) -> [String] {
        // Each allowed name once, whatever list the record holds (codex-13 on 1.8.2: a list saved before the limits).
        let slots = manifest.map(uniqueMediaTokens) ?? ["front", "rear", "primary", "secondary"]
        return slots.map { "photo-\($0)-v2-" + eventID.uuidString }
             + slots.map { "photo-\($0)-" + eventID.uuidString }
    }

    /// The camera token out of a photo record name — "photo-front-v2-…" → "front". Nil for
    /// the primary/secondary fallbacks, which name a slot, not a camera.
    nonisolated static func cameraFromPhotoRecordName(_ name: String) -> String? {
        guard name.hasPrefix("photo-") else { return nil }
        let token = name.dropFirst("photo-".count).split(separator: "-").first.map(String.init)
        return (token == "front" || token == "rear") ? token : nil
    }

    /// What a downloaded asset is, decided from its leading bytes — the photo record carries
    /// no type field (the uploader knew the extension; a downloader doesn't). JPEG opens
    /// FF D8 FF; every QuickTime/MP4 container carries "ftyp" at offset 4.
    enum MediaKind { case jpeg, movie }
    nonisolated static func mediaKind(ofPrefix bytes: [UInt8]) -> MediaKind? {
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpeg }
        if bytes.count >= 8, bytes[4...7].elementsEqual(Array("ftyp".utf8)) { return .movie }
        return nil
    }

    /// A full-media fetch that ran: the assets found, and whether every candidate slot was
    /// actually CHECKED. `complete == false` means some per-ID lookup failed (network,
    /// server) — captures may exist in iCloud beyond what came back, and the UI must not
    /// present the result as "iCloud holds nothing" (R3-3: failure is not absence).
    struct FullMediaFetch {
        let media: [FetchedMedia]
        let complete: Bool
    }

    /// Fetches this event's full-resolution capture records by their deterministic IDs and
    /// returns the assets found, deduplicated per slot with v2 preferred. Returns nil when
    /// the FETCH failed outright (network, account); a per-ID failure inside an otherwise
    /// successful fetch comes back as `complete == false` — the UI must tell "iCloud holds
    /// nothing" apart from "iCloud was unreachable" apart from "some slots went unchecked".
    ///
    /// This is the retrieval half of the Pro backup promise (34.B1): before it, full media
    /// reached iCloud and nothing — not restore, not the push path, not any UI — could ever
    /// bring it back; after a theft the owner held thumbnails of their own evidence.
    func fetchFullMedia(for eventID: UUID, manifest: [String]? = nil) async -> FullMediaFetch? {
        guard let lease = await acquireCloudLease(), enrollment.authorizeRecord(eventID, lease: lease) else { return nil }
        let names = Self.fullMediaRecordNames(for: eventID, manifest: manifest)
        // No name to ask for (this iPhone's record that names no camera, `Event.downloadManifest`):
        // every candidate is checked, and none holds a capture.
        guard !names.isEmpty else { return FullMediaFetch(media: [], complete: true) }
        do {
            let results = try await fetchMediaRecords(names.map { CKRecord.ID(recordName: $0) }, lease: lease)
            try requireCurrent(lease)
            var bySlot: [String: FetchedMedia] = [:]
            var slotOrder: [String] = []
            // Walk in candidate order (v2 first) so a record present in both generations is
            // taken once, from the newer one. A missing ID is an .unknownItem per-ID result,
            // not a thrown error — absence is an answer here. Any OTHER per-ID failure is a
            // slot that was not checked, and the result says so (R3-3).
            for name in names {
                let slot = name.dropFirst("photo-".count).split(separator: "-").first.map(String.init) ?? name
                if !slotOrder.contains(slot) { slotOrder.append(slot) }
                guard bySlot[slot] == nil,
                      case .success(let record)? = results[CKRecord.ID(recordName: name)],
                      let asset = record["media"] as? CKAsset, let url = asset.fileURL else { continue }
                bySlot[slot] = FetchedMedia(slot: slot,
                                            camera: Self.cameraFromPhotoRecordName(name),
                                            fileURL: url)
            }
            let complete = !Self.mediaFetchIncomplete(results)
            if !complete {
                Log.cloud.error("Full-media fetch: per-ID failure(s) — result reported incomplete")
            }
            Log.cloud.info("Full-media fetch found \(bySlot.count, privacy: .public) capture(s)")
            // Deterministic candidate-slot order — never a dictionary's whim (ext-review #2).
            return FullMediaFetch(media: slotOrder.compactMap { bySlot[$0] }, complete: complete)
        } catch {
            Log.cloud.error("Full-media fetch failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            return nil
        }
    }

    // MARK: - Heartbeat (item 52)

    /// Item 52: the heartbeat's record type. No subscription names it, so a beat never alerts.
    nonisolated static let beatRecordTypeV2 = "TamperEventBeatV2"

    /// Pure (unit-tested): the trail's record for one beat, created once.
    nonisolated static func beatRecordName(session: UUID, sequence: Int) -> String {
        "beat-v2-\(session.uuidString)-\(sequence)"
    }

    /// Pure (unit-tested): the session's latest record, saved over at each beat and fetched by this
    /// name (the owner's choice of reader, (a)): its server time is when the phone was last heard from.
    nonisolated static func latestBeatRecordName(session: UUID) -> String {
        "beat-latest-v2-\(session.uuidString)"
    }

    /// Pure (unit-tested): the two records one beat writes, the trail's and the session's latest, of
    /// one type, every field encrypted like every other field this app writes. A value iOS does not
    /// give (the battery level, a thermal state with no name) is left out rather than guessed.
    nonisolated static func makeBeatRecords(_ beat: HeartbeatBeat) -> [CKRecord] {
        [beatRecordName(session: beat.session, sequence: beat.sequence), latestBeatRecordName(session: beat.session)]
            .map { name in
                let record = CKRecord(recordType: beatRecordTypeV2, recordID: CKRecord.ID(recordName: name))
                record.encryptedValues["sessionID"] = beat.session.uuidString as CKRecordValue
                record.encryptedValues["sequence"] = beat.sequence as CKRecordValue
                record.encryptedValues["deviceName"] = beat.deviceName as CKRecordValue
                if let level = beat.batteryLevel { record.encryptedValues["batteryLevel"] = level as CKRecordValue }
                record.encryptedValues["charging"] = beat.charging as CKRecordValue
                if let thermal = beat.thermalState { record.encryptedValues["thermalState"] = thermal as CKRecordValue }
                return record
            }
    }

    /// The longest a beat waits for iCloud; past it the beat is dropped.
    nonisolated static let beatDeadline: TimeInterval = 30

    /// Item 52: sends one beat, both records in one attempt under `beatDeadline`; false when it
    /// could not, and the beat is dropped, never sent late. Its own path, not `save`: a beat that
    /// fails must not count as an evidence upload's transient failure, which the pending sweep
    /// reads to decide when to stop (item 79).
    func pushBeat(_ beat: HeartbeatBeat) async -> Bool {
        guard let lease = await acquireCloudLease(),
              enrollment.authorizeSession(session: beat.session, lease: lease), let database else { return false }
        guard backupOn() else { return false }   // the switch, after the account wait (item 116, R2)
        let records = Self.makeBeatRecords(beat)
        let operation = CKModifyRecordsOperation(recordsToSave: records)
        operation.savePolicy = .allKeys
        operation.isAtomic = false
        let results = PerRecordResults()
        operation.perRecordSaveBlock = { @Sendable id, result in results.record(id, result) }
        let token = UUID()
        activeOperations[token] = operation
        defer { activeOperations[token] = nil }
        do {
            try requireCurrent(lease)
            try await Self.awaitWithDeadline(Self.beatDeadline,
                onDeadline: { operation.cancel() }, timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<Void, Error>) -> Void) in
                    operation.modifyRecordsResultBlock = { @Sendable result in
                        let error: Error?
                        if case .failure(let failure) = result { error = failure } else { error = nil }
                        let (succeeded, failed) = results.snapshot()
                        if let error = Self.saveError(operationError: error, succeeded: succeeded,
                                                      failed: failed, expecting: records.map(\.recordID)) {
                            resume(.failure(error))
                        } else { resume(.success(())) }
                    }
                    submit(operation, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
            try requireCurrent(lease)
            return true
        } catch { return false }
    }

    /// Item 52: the session's latest beat, fetched by name. No such record: never heard from (a
    /// phone on 1.3.x, the free tier, or offline throughout); any other failure, a read past its
    /// deadline included (item 180's A2; on an operation of its own, codex-4): not known.
    func latestBeat(session: UUID) async -> LastHeard {
        guard let lease = await acquireCloudLease(), enrollment.authorizeRecord(session, lease: lease) else { return .unknown }
        let id = CKRecord.ID(recordName: Self.latestBeatRecordName(session: session))
        do {
            guard let answer = try await recordsByID([id], desiredKeys: nil, lease: lease)[id] else { return .unknown }
            let record = try answer.get()
            try requireCurrent(lease)
            return record.modificationDate.map(LastHeard.at) ?? .unknown
        } catch {
            guard enrollment.isCurrent(lease) else { return .unknown }
            return (error as? CKError)?.code == .unknownItem ? .never : .unknown
        }
    }

    /// Pure (unit-tested; item 52's follow-up 2): the names of one session's per-beat trail
    /// records, from the first beat to `sequence`, the number its latest record carries. Never
    /// the latest record itself.
    nonisolated static func beatTrailRecordNames(session: UUID, through sequence: Int) -> [String] {
        guard sequence > 0 else { return [] }
        return (1...sequence).map { beatRecordName(session: session, sequence: $0) }
    }

    /// Beats past the latest record's number that may still exist: a beat whose trail record
    /// saved while its latest record did not (the two save non-atomically), at the end of a watch.
    /// A trim fetches them first and goes ahead only when each found is older than the cutoff
    /// (`beatTailVerdict`): a phone asleep for days between its latest record's beat and them
    /// makes one newer than the latest.
    nonisolated static let beatTrailTailMargin = 12
    /// The most beats one watch can have: a year of beats five minutes apart. A latest record
    /// claiming more is not believed past this.
    nonisolated static let maxBeatsPerSession = 105_120

    /// Pure (unit-tested; item 52's follow-up 2): the last trail number a trim deletes through,
    /// given the latest record's `sequence`: capped, with the tail margin; nil when the record
    /// carries none it can be sure of.
    nonisolated static func beatTrailUpperBound(sequence: Int?) -> Int? {
        guard let sequence else { return nil }
        return min(max(sequence, 0), maxBeatsPerSession) + beatTrailTailMargin
    }

    /// Pure (unit-tested; item 52's follow-up 2): what one watch's latest record says to do, under
    /// the 30-day floor whatever cutoff is asked. Begun at or after the cutoff, or last heard from
    /// at or after it by the server's clock: not yet. No such record: nothing to trim (it never
    /// beat). A failed fetch, an answer that leaves the record out, or a record without its time
    /// or its number: failed, asked again at a later pass. Otherwise: look at the numbers past
    /// the latest's, then delete the trail through the bound.
    nonisolated static func beatTrimStep(start: Date, latest: Result<FetchedBeat, Error>?,
                                         requestedCutoff: Date, now: Date) -> BeatTrimStep {
        let cutoff = effectivePurgeCutoff(requested: requestedCutoff, now: now)
        guard start < cutoff else { return .stop(.notYet) }
        switch latest {
        case nil:
            return .stop(.failed)
        case .failure(let error)?:
            return .stop((error as? CKError)?.code == .unknownItem ? .trimmed : .failed)
        case .success(let beat)?:
            guard let lastBeat = beat.modified else { return .stop(.failed) }
            guard lastBeat < cutoff else { return .stop(.notYet) }   // it beat inside the window: the whole trail waits
            guard let upper = beatTrailUpperBound(sequence: beat.sequence) else { return .stop(.failed) }
            return .deleteThrough(upper)
        }
    }

    /// Pure (unit-tested; item 52's follow-up 2): the names a trim looks at before deleting, the
    /// last `beatTrailTailMargin` numbers through `upper`, which are those past the latest record's.
    nonisolated static func beatTailRecordNames(session: UUID, through upper: Int) -> [String] {
        guard upper > 0 else { return [] }
        return (max(1, upper - beatTrailTailMargin + 1)...upper).map { beatRecordName(session: session, sequence: $0) }
    }

    /// Pure (unit-tested; item 52's follow-up 2): the tail's answers, name by name. A time is a
    /// beat; "not found" is absence; anything else, a record without its time or a name the
    /// answer leaves out included, is unreadable (failure is not absence, R3-3).
    nonisolated static func beatTailRecords(_ names: [String], answers: [String: Result<FetchedBeat, Error>]) -> [BeatTailRecord] {
        names.map { name in
            switch answers[name] {
            case .success(let beat)?:
                return beat.modified.map(BeatTailRecord.at) ?? .unreadable
            case .failure(let error)?:
                return (error as? CKError)?.code == .unknownItem ? .absent : .unreadable
            case nil:
                return .unreadable
            }
        }
    }

    /// Pure (unit-tested; item 52's follow-up 2): whether the beats found past the latest record's
    /// number let a trim go ahead (nil) or stop it, under the 30-day floor whatever cutoff is
    /// asked: one at or after the cutoff means the watch beat inside the window after all (not
    /// yet); one that could not be read means ask again (failed).
    nonisolated static func beatTailVerdict(_ tail: [BeatTailRecord], requestedCutoff: Date, now: Date) -> BeatTrimOutcome? {
        let cutoff = effectivePurgeCutoff(requested: requestedCutoff, now: now)
        let beatInside = tail.contains { record in
            if case .at(let date) = record { return date >= cutoff }
            return false
        }
        if beatInside { return .notYet }
        return tail.contains(.unreadable) ? .failed : nil
    }

    /// Item 52's follow-up 2 (the owner's ruling (b), for 1.5): trims the per-beat trails of the
    /// given watches, keeping each one's latest record, which is all "Last heard from" reads. One
    /// account check and one background-task assertion for the batch. The decision is keyed on the
    /// server's time of each watch's LAST beat, never on its start alone: a watch begun before the
    /// cutoff may have beaten inside it. The 30-day floor lives inside each decision this makes
    /// (`beatTrimStep`, `beatTailVerdict`), whatever the caller asks (as in `purgeFullMedia`), so
    /// every beat newer than it is kept, in any mode. The month policy is evaluated against
    /// a CloudKit system-date lower bound; device time only influences the caller's scheduling.
    /// `stillWanted`: whether the owner's setting still asks for this trim, asked before each batch of deletions (item
    /// 169's codex-2): a setting changed while the trim waits on iCloud stops what it has not sent.
    func trimBeatTrails(_ sessions: [BeatSession], monthsOld months: Int,
                        stillWanted: @MainActor () -> Bool = { true }) async -> [UUID: BeatTrimOutcome] {
        var outcomes: [UUID: BeatTrimOutcome] = [:]
        guard !sessions.isEmpty else { return outcomes }
        guard let access = await retentionAccess() else {
            for session in sessions { outcomes[session.id] = .failed }
            return outcomes
        }
        let assertion = BackgroundAssertion.begin("malinois-exfil")
        defer { assertion.end() }
        guard let serverDate = await retentionServerDate(using: access), access.isCurrent(),
              let cutoff = Self.serverAnchoredPurgeCutoff(monthsOld: months, observedServerDate: serverDate) else {
            return Dictionary(sessions.map { ($0.id, .failed) }, uniquingKeysWith: { _, last in last })
        }
        for session in sessions {
            guard access.isCurrent(), access.permitsSession(session) else {
                outcomes[session.id] = .failed
                continue
            }
            outcomes[session.id] = await trimBeatTrail(session, requestedCutoff: cutoff, now: serverDate, using: access,
                                                       stillWanted: stillWanted)
        }
        let done = outcomes.values.filter { $0 == .trimmed }.count
        Log.cloud.info("Beat trails: \(done, privacy: .public) of \(sessions.count, privacy: .public) watch(es) trimmed")
        return outcomes
    }

    /// One watch's trim (see `trimBeatTrails`), its decisions made by the pure functions above:
    /// trimmed when nothing of its trail is left (deleted, already gone, or it never beat); not yet
    /// when its last beat is inside the cutoff, counted or not by its latest record; failed when a
    /// fetch or a delete failed or stalled, or its latest record came back without its time or
    /// its number.
    private func trimBeatTrail(_ session: BeatSession, requestedCutoff: Date, now: Date,
                               using access: RetentionAccess, stillWanted: @MainActor () -> Bool) async -> BeatTrimOutcome {
        guard access.isCurrent(), access.permitsSession(session) else { return .failed }
        let latestName = Self.latestBeatRecordName(session: session.id)
        guard let latest = await access.beatRecords([latestName], false), access.isCurrent() else { return .failed }
        let upper: Int
        switch Self.beatTrimStep(start: session.start, latest: latest[latestName], requestedCutoff: requestedCutoff, now: now) {
        case .stop(let outcome):
            if outcome == .failed {
                Log.cloud.error("Beat trail: the latest record was not read whole; the trail waits for a later pass")
            }
            return outcome
        case .deleteThrough(let number):
            upper = number
        }
        let tailNames = Self.beatTailRecordNames(session: session.id, through: upper)
        guard let tail = await access.beatRecords(tailNames, true), access.isCurrent() else { return .failed }
        if let stop = Self.beatTailVerdict(Self.beatTailRecords(tailNames, answers: tail),
                                           requestedCutoff: requestedCutoff, now: now) {
            return stop
        }
        let ids = Self.beatTrailRecordNames(session: session.id, through: upper).map { CKRecord.ID(recordName: $0) }
        var failed = false
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            guard access.isCurrent(), stillWanted() else { return .failed }
            failed = await access.delete(chunk).failed || failed
        }
        return (failed || !access.isCurrent()) ? .failed : .trimmed
    }

    /// Fetches beat records by name under the save deadline, as a trim reads them (item 52's
    /// follow-up 2): per name, its server time and number, or its own error (a missing record
    /// answers `unknownItem`); nil when the fetch as a whole failed or stalled. `timesOnly` asks
    /// for no fields. A stalled fetch is cancelled, as a stalled delete is, so it cannot hold the
    /// pass and its background task open. CloudKit runs both result callbacks on its own
    /// queue; their Sendable closures share only the locked collector and completion handler.
    private func fetchBeats(named names: [String], timesOnly: Bool,
                            in database: CKDatabase, lease: CloudEnrollment.Lease) async -> [String: Result<FetchedBeat, Error>]? {
        guard enrollment.isCurrent(lease) else { return nil }
        let op = CKFetchRecordsOperation(recordIDs: names.map { CKRecord.ID(recordName: $0) })
        if timesOnly { op.desiredKeys = [] }
        op.qualityOfService = .utility
        let results = PerRecordBeatResults()
        op.perRecordResultBlock = { @Sendable id, result in results.record(id, result) }
        let token = UUID()
        activeOperations[token] = op
        defer { activeOperations[token] = nil }
        do {
            let answer = try await Self.awaitWithDeadline(
                Self.saveAttemptDeadline,
                onDeadline: { [weak op] in
                    Log.cloud.error("Beat fetch stalled — cancelling the operation")
                    op?.cancel()
                },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<[String: Result<FetchedBeat, Error>], Error>) -> Void) in
                    op.fetchRecordsResultBlock = { @Sendable result in
                        switch result {
                        case .success:
                            resume(.success(results.snapshot()))
                        case .failure(let error):
                            // A partial failure is answered record by record, above; any other
                            // failure is the fetch's as a whole.
                            if (error as? CKError)?.code == .partialFailure {
                                resume(.success(results.snapshot()))
                            } else {
                                resume(.failure(error))
                            }
                        }
                    }
                    submit(op, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
            try requireCurrent(lease)
            return answer
        } catch {
            return nil
        }
    }

    /// Thread-safe collector for per-record FETCH results of beat records (item 52's follow-up 2),
    /// kept as a trim reads each: its server time and its number.
    private final class PerRecordBeatResults: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: Result<FetchedBeat, Error>] = [:]

        func record(_ id: CKRecord.ID, _ result: Result<CKRecord, Error>) {
            let answer = result.map { FetchedBeat(modified: $0.modificationDate, sequence: $0.encryptedValues["sequence"] as? Int) }
            lock.lock(); defer { lock.unlock() }
            answers[id.recordName] = answer
        }

        func snapshot() -> [String: Result<FetchedBeat, Error>] {
            lock.lock(); defer { lock.unlock() }
            return answers
        }
    }

    /// Narrow transport boundary shared by both retention entry points. Production operations
    /// remain CloudKit-backed; tests replace transport to verify that unsafe time never reaches
    /// candidate selection or deletion, without needing a signed CloudKit account.
    struct RetentionAccess: Sendable {
        var serverDate: @MainActor @Sendable (String) async -> Date?
        var mediaEvents: @MainActor @Sendable (Date, String) async -> (ids: [UUID], ok: Bool)
        var beatRecords: @MainActor @Sendable ([String], Bool) async -> [String: Result<FetchedBeat, Error>]?
        var delete: @MainActor @Sendable ([CKRecord.ID]) async -> (deleted: Int, failed: Bool)
        var isCurrent: @MainActor @Sendable () -> Bool = { true }
        var permitsSession: @MainActor @Sendable (BeatSession) -> Bool = { _ in true }
    }

    #if DEBUG
    var retentionAccessForTesting: RetentionAccess?
    #endif

    private func retentionAccess() async -> RetentionAccess? {
        #if DEBUG
        if let retentionAccessForTesting { return retentionAccessForTesting }
        #endif
        guard let lease = await acquireCloudLease(), let database else { return nil }
        return RetentionAccess(
            serverDate: { await self.newestServerCreationDate(type: $0, in: database, lease: lease) },
            mediaEvents: { await self.eventIDsOfMetaRecords(olderThan: $0, type: $1, lease: lease) },
            beatRecords: { await self.fetchBeats(named: $0, timesOnly: $1, in: database, lease: lease) },
            delete: { await self.delete($0, from: database, lease: lease) },
            isCurrent: { self.enrollment.isCurrent(lease) },
            permitsSession: { self.enrollment.authorizeSession(session: $0.id, startedAt: $0.start, lease: lease) })
    }

    /// Reads system creation timestamps from existing, already-indexed audit/fact types.
    /// This is a lower bound on server time, NOT a claim that an old record is current time.
    /// Stale observations delay deletion. No device date, custom field, new record or schema
    /// participates, and an unavailable observation disables deletion for this pass.
    private func retentionServerDate(using access: RetentionAccess) async -> Date? {
        guard access.isCurrent() else { return nil }
        async let audit = access.serverDate(Self.stateRecordTypeV2)
        async let fact = access.serverDate(Self.metaRecordTypeV2)
        let dates = await [audit, fact].compactMap { $0 }
        guard access.isCurrent() else { return nil }
        if let newest = dates.max() { return newest }
        // A legacy-only account can still clean up conservatively using its existing facts.
        return await access.serverDate(Self.metaRecordType)
    }

    private func newestServerCreationDate(type: String, in database: CKDatabase,
                                          lease: CloudEnrollment.Lease) async -> Date? {
        guard enrollment.isCurrent(lease) else { return nil }
        let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let operation = CKQueryOperation(query: query)
        operation.resultsLimit = 1
        operation.desiredKeys = []
        operation.qualityOfService = .utility
        let observation = RetentionClockObservation()
        operation.recordMatchedBlock = { @Sendable _, result in
            if case .success(let record) = result { observation.record(record.creationDate) }
        }
        let token = UUID()
        activeOperations[token] = operation
        defer { activeOperations[token] = nil }
        do {
            let answer = try await Self.awaitWithDeadline(
                Self.saveAttemptDeadline, onDeadline: { [weak operation] in operation?.cancel() },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<Date?, Error>) -> Void) in
                    operation.queryResultBlock = { @Sendable result in
                        switch result {
                        case .success: resume(.success(observation.snapshot()))
                        case .failure(let error): resume(.failure(error))
                        }
                    }
                    submit(operation, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
            try requireCurrent(lease)
            return answer
        } catch { return nil }
    }

    /// CloudKit invokes its callbacks off the main actor; the observed system date is
    /// guarded independently of operation completion and deadline cancellation.
    private final class RetentionClockObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date?

        func record(_ candidate: Date?) {
            guard let candidate, candidate.timeIntervalSince1970.isFinite else { return }
            lock.lock(); defer { lock.unlock() }
            date = max(date ?? candidate, candidate)
        }

        func snapshot() -> Date? {
            lock.lock(); defer { lock.unlock() }
            return date
        }
    }

    // MARK: - Full-media retention (32.R2)

    /// The protection floor for Malinois cleanup: no event/beat newer than this many days
    /// according to CloudKit system time is eligible. External iCloud deletion is separate. Its job is anti-tamper, not tidiness: a
    /// PIN-holder must not be able to "free up iCloud space" to destroy the evidence of
    /// what they just did. Enforced structurally inside `purgeFullMedia` itself (eighth
    /// review, L1) — `purgeCutoff` clamps too, but the entry point no longer trusts its
    /// callers to have used it, so no caller — UI, automation, or future code — can pass
    /// a date that violates it.
    nonisolated static let retentionFloorDays = 30

    /// A deletion cutoff derived only from a CloudKit system timestamp. Missing time
    /// must stop cleanup; an older observation can delay cleanup but cannot age evidence.
    nonisolated static func serverAnchoredPurgeCutoff(monthsOld months: Int, observedServerDate: Date?) -> Date? {
        guard (0...12).contains(months), let observedServerDate,
              observedServerDate.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let requested = calendar.date(byAdding: .month, value: -months, to: observedServerDate) else { return nil }
        return effectivePurgeCutoff(requested: requested, now: observedServerDate)
    }

    /// Pure (unit-tested): the cutoff a purge actually runs with — whatever was requested,
    /// clamped to the protection floor.
    nonisolated static func effectivePurgeCutoff(requested: Date, now: Date) -> Date {
        min(requested, now.addingTimeInterval(-Double(retentionFloorDays) * 86_400))
    }

    /// The newest creation date a purge may delete records before: the requested age,
    /// clamped to the protection floor. Pure (unit-tested).
    nonisolated static func purgeCutoff(monthsOld months: Int, now: Date) -> Date {
        let requested = Calendar(identifier: .gregorian)
            .date(byAdding: .month, value: -months, to: now) ?? now
        let floor = now.addingTimeInterval(-Double(retentionFloorDays) * 86_400)
        return min(requested, floor)
    }

    struct CloudPurgeResult: Equatable {
        let eventsExamined: Int
        let recordsDeleted: Int
        let failed: Bool
    }

    /// Deletes **full-resolution photo records** past the selected month policy from the
    /// owner's private database. A CloudKit system-date lower bound anchors both policy and
    /// protection floor; unavailable time fails closed, and stale time only delays cleanup.
    /// No other records are deleted: meta facts, thumbnails, and arm/disarm
    /// audit records are kept in every retention mode. Old events are found by paging the
    /// (indexed) meta records oldest-first, and their photo records are addressed by their
    /// deterministic names — the same no-query, no-schema-dependency trick as retrieval
    /// (ADR 0002), so this touches nothing that could fail silently in Production.
    /// `stillWanted`: whether the owner's setting still asks for this purge, asked before each batch of deletions (item
    /// 169's codex-2): Keep forever, Manual or another period chosen while the purge waits on iCloud stops what it has
    /// not sent. The owner's explicit purge in Settings asks nothing more.
    func purgeFullMedia(monthsOld months: Int, stillWanted: @MainActor () -> Bool = { true }) async -> CloudPurgeResult {
        guard let access = await retentionAccess() else {
            return CloudPurgeResult(eventsExamined: 0, recordsDeleted: 0, failed: true)
        }
        let assertion = BackgroundAssertion.begin("malinois-exfil")
        defer { assertion.end() }

        guard let cutoff = Self.serverAnchoredPurgeCutoff(
            monthsOld: months, observedServerDate: await retentionServerDate(using: access)), access.isCurrent() else {
            Log.cloud.error("Retention deferred: no usable CloudKit time observation")
            return CloudPurgeResult(eventsExamined: 0, recordsDeleted: 0, failed: true)
        }
        var eventIDs: [UUID] = []
        var anyQueryFailed = false
        for type in [Self.metaRecordTypeV2, Self.metaRecordType] {
            guard access.isCurrent() else {
                return CloudPurgeResult(eventsExamined: eventIDs.count, recordsDeleted: 0, failed: true)
            }
            let page = await access.mediaEvents(cutoff, type)
            guard access.isCurrent() else {
                return CloudPurgeResult(eventsExamined: eventIDs.count, recordsDeleted: 0, failed: true)
            }
            eventIDs += page.ids
            anyQueryFailed = anyQueryFailed || !page.ok
        }
        guard !eventIDs.isEmpty else {
            return CloudPurgeResult(eventsExamined: 0, recordsDeleted: 0, failed: anyQueryFailed)
        }
        let photoIDs = eventIDs.flatMap { Self.fullMediaRecordNames(for: $0) }
            .map { CKRecord.ID(recordName: $0) }
        var deleted = 0
        var deleteFailed = false
        for chunk in stride(from: 0, to: photoIDs.count, by: 200)
            .map({ Array(photoIDs[$0..<min($0 + 200, photoIDs.count)]) }) {
            guard access.isCurrent(), stillWanted() else {
                return CloudPurgeResult(eventsExamined: eventIDs.count, recordsDeleted: deleted, failed: true)
            }
            let result = await access.delete(chunk)
            deleted += result.deleted
            deleteFailed = deleteFailed || result.failed
        }
        Log.cloud.info("Retention purge: \(deleted, privacy: .public) photo record(s) deleted across \(eventIDs.count, privacy: .public) event(s)")
        return CloudPurgeResult(eventsExamined: eventIDs.count, recordsDeleted: deleted,
                                failed: anyQueryFailed || deleteFailed || !access.isCurrent())
    }

    /// Event IDs of one meta type's records created before `cutoff`, paged oldest-first so
    /// the walk stops at the cutoff instead of reading the whole database.
    /// `ok` demands a clean walk: a per-record failure is an event whose media this round
    /// cannot purge — skipping it is right (under-deletion is the safe direction), but the
    /// purge must then report FAILED rather than claim "Deleted" (R3-3).
    private func eventIDsOfMetaRecords(olderThan cutoff: Date, type: String,
                                       lease: CloudEnrollment.Lease) async -> (ids: [UUID], ok: Bool) {
        guard enrollment.isCurrent(lease) else { return ([], false) }
        let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var ids: [UUID] = []
        var sawRecordFailure = false
        var cursor: CKQueryOperation.Cursor?
        do {
            paging: repeat {
                try requireCurrent(lease)
                let (matches, next) = try await queryPage(query, from: cursor, lease: lease)
                try requireCurrent(lease)
                sawRecordFailure = sawRecordFailure || Self.queryPageSawFailure(matches)
                for (recordID, result) in matches {
                    guard case .success(let record) = result else { continue }
                    // A record with no creationDate must not end the whole walk (seventh
                    // review, #7): skip it out loud — under-deletion stays the safe
                    // direction, but observably so.
                    guard let created = record.creationDate else {
                        Log.cloud.error("Purge walk: record without creationDate skipped")
                        continue
                    }
                    guard created < cutoff else { break paging }
                    if let idString = Self.customField("eventID", of: record) as? String,
                       let id = UUID(uuidString: idString) {
                        ids.append(id)
                    } else if let id = Self.eventID(fromMetaRecordName: recordID.recordName) {
                        ids.append(id)
                    }
                }
                cursor = next
            } while cursor != nil
            if sawRecordFailure {
                Log.cloud.error("Purge walk of \(type, privacy: .public): per-record failure(s) — reporting the purge incomplete")
            }
            return (ids, !sawRecordFailure)
        } catch {
            Log.cloud.error("Retention query of \(type, privacy: .public) failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            return enrollment.isCurrent(lease) ? (ids, false) : ([], false)
        }
    }

    /// The event UUID out of a meta record name — "meta-v2-<uuid>" / "meta-<uuid>".
    /// Pure (unit-tested); the fallback when a record's eventID field is unreadable.
    nonisolated static func eventID(fromMetaRecordName name: String) -> UUID? {
        for prefix in ["meta-v2-", "meta-"] where name.hasPrefix(prefix) {
            return UUID(uuidString: String(name.dropFirst(prefix.count)))
        }
        return nil
    }

    /// Thread-safe collector for per-record DELETE results — the delete-side sibling of
    /// `PerRecordResults`. `unknownItem` counts as absent: absence is the goal, not an error.
    private final class PerRecordDeleteResults: @unchecked Sendable {
        private let lock = NSLock()
        private var absent: Set<CKRecord.ID> = []
        private var failures: [CKRecord.ID: Error] = [:]

        func record(_ id: CKRecord.ID, _ result: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result {
            case .success:
                absent.insert(id)
            case .failure(let error):
                if let ck = error as? CKError, ck.code == .unknownItem { absent.insert(id) }
                else { failures[id] = error }
            }
        }

        func snapshot() -> (absent: Set<CKRecord.ID>, failures: [CKRecord.ID: Error]) {
            lock.lock(); defer { lock.unlock() }
            return (absent, failures)
        }
    }

    /// Pure (unit-tested): whether any match in a query page individually failed. In a
    /// QUERY a per-record failure is never absence — matched records exist by definition —
    /// so one failed match means that page (and any restore or purge walk built on it) is
    /// incomplete. The read-side twin of `deleteFailed` below (ninth review, R3-3).
    nonisolated static func queryPageSawFailure(
        _ matches: [(CKRecord.ID, Result<CKRecord, any Error>)]) -> Bool {
        matches.contains { if case .failure = $0.1 { return true } else { return false } }
    }

    /// Pure (unit-tested): whether a by-ID media fetch left any slot unchecked.
    /// `.unknownItem` is absence — an answer; any other per-ID failure means that record
    /// may exist and could not be read, so the result must not present as "iCloud holds
    /// nothing" (ninth review, R3-3).
    nonisolated static func mediaFetchIncomplete(
        _ results: [CKRecord.ID: Result<CKRecord, any Error>]) -> Bool {
        results.values.contains {
            if case .failure(let error) = $0 {
                return (error as? CKError)?.code != .unknownItem
            }
            return false
        }
    }

    /// Pure (unit-tested): the delete-side twin of `saveError` (ADR 0004). A purge may claim
    /// success ONLY when every expected record was individually confirmed absent — deleted,
    /// or already gone. Any other per-record error, any record with no per-record answer at
    /// all, or a non-partial operation error is a failure the owner must see. The old rule
    /// dropped non-`unknownItem` per-record errors on the floor and mapped `.partialFailure`
    /// to success, so Settings said "Deleted" while media remained (sixth review, F5).
    nonisolated static func deleteFailed(operationError: Error?,
                                         confirmedAbsent: Set<CKRecord.ID>,
                                         failures: [CKRecord.ID: Error],
                                         expecting: [CKRecord.ID]) -> Bool {
        if let ck = operationError as? CKError, ck.code == .partialFailure {
            // Judged per record below — .partialFailure only says "not all succeeded".
        } else if operationError != nil {
            return true
        }
        if !failures.isEmpty { return true }
        return !expecting.allSatisfy { confirmedAbsent.contains($0) }
    }

    /// Batch delete under the same honesty rule as saves. A record already gone
    /// (`unknownItem`) counts as absent; anything else unconfirmed makes the batch FAILED,
    /// and a stalled operation is bounded by the save deadline rather than hanging the
    /// purge (sixth review F1's shape, applied here while reworking F5).
    private func delete(_ ids: [CKRecord.ID],
                        from database: CKDatabase, lease: CloudEnrollment.Lease) async -> (deleted: Int, failed: Bool) {
        guard enrollment.isCurrent(lease) else { return (0, true) }
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
        op.qualityOfService = .utility
        let results = PerRecordDeleteResults()
        // CloudKit calls an operation's blocks on its own queue: @Sendable, so Swift 6 never takes
        // them for main-actor code and the compiler checks what they touch (item 97).
        op.perRecordDeleteBlock = { @Sendable id, result in results.record(id, result) }
        let token = UUID()
        activeOperations[token] = op
        defer { activeOperations[token] = nil }
        do {
            let answer = try await Self.awaitWithDeadline(
                Self.saveAttemptDeadline,
                onDeadline: { [weak op] in
                    Log.cloud.error("Purge delete stalled — cancelling the operation")
                    op?.cancel()
                },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<(deleted: Int, failed: Bool), Error>) -> Void) in
                    op.modifyRecordsResultBlock = { @Sendable result in
                        let operationError: Error?
                        switch result {
                        case .success:            operationError = nil
                        case .failure(let error): operationError = error
                        }
                        let (absent, failures) = results.snapshot()
                        let failed = Self.deleteFailed(operationError: operationError,
                                                       confirmedAbsent: absent,
                                                       failures: failures, expecting: ids)
                        resume(.success((deleted: absent.count, failed: failed)))
                    }
                    submit(op, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
            try requireCurrent(lease)
            return answer
        } catch {
            // Deadline (or a refused start): nothing was confirmed — the purge reports it.
            return (deleted: 0, failed: true)
        }
    }

    // MARK: - Encrypted-data reset (34.H13)

    /// Set when a save failed in a way that indicates the user reset their iCloud encrypted
    /// data (Apple purges the zone's records; saves answer `zoneNotFound` /
    /// `userDeletedZone`). The engine reads this and requeues everything the device still
    /// holds — Apple's prescribed recovery is exactly a local re-upload. Cleared by
    /// `acknowledgeEncryptedDataReset`.
    private(set) var encryptedDataResetDetected = false
    func acknowledgeEncryptedDataReset() { encryptedDataResetDetected = false }

    /// Pure (unit-tested). This app writes only to the default zone, where these codes'
    /// realistic producer is the encrypted-data reset; either way the records are gone and
    /// re-upload is the correct response.
    nonisolated static func indicatesEncryptedDataReset(_ error: Error) -> Bool {
        guard var ck = error as? CKError else { return false }
        if ck.code == .partialFailure,
           let inner = ck.partialErrorsByItemID?.values.compactMap({ $0 as? CKError }).first {
            ck = inner
        }
        return ck.code == .zoneNotFound || ck.code == .userDeletedZone
    }

    /// How long one save attempt may wait for CloudKit's result callback. CloudKit's own
    /// resource timeout is measured in DAYS — a path that looks online but stalls used to
    /// hold `save()`'s continuation (and the per-event chain queued behind it) indefinitely.
    /// And a hang never *fails*, so the observed-failure escalation (ADR 0001) could not
    /// fire either: a stalling attacker muted both the evidence and the alarm about it
    /// (sixth-review F1). Generous — a healthy save finishes in ~1–3 s.
    nonisolated static let saveAttemptDeadline: TimeInterval = 20

    /// First-resume-wins latch (the warm-up `DeadlineLatch` shape; a class because the
    /// result callback and the deadline task share it).
    private final class ResumeLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
        /// Whether a resume was claimed: a deadline still waiting can stop.
        func done() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return resumed
        }
    }

    /// Awaits a callback-style operation with a deadline: `start` installs the completion,
    /// and if the deadline wins the race, `onDeadline` runs (cancelling the operation) and
    /// the wait ends with `timeoutError`. Exactly one resume wins; the loser's callback is
    /// a no-op. Unit-tested directly — including with a start that never calls back, which
    /// is the stall this exists to bound. On the main actor, where every caller is, so `start`
    /// runs there (item 97: Swift 6 will not send a main-actor closure off it); the deadline
    /// runs off the main actor, as it did before, so a busy main thread cannot hold it back.
    static func awaitWithDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        onDeadline: @escaping @Sendable () -> Void,
        timeoutError: Error,
        start: (_ resume: @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let latch = ResumeLatch()
            start { result in
                guard latch.claim() else { return }
                cont.resume(with: result)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard latch.claim() else { return }
                onDeadline()
                cont.resume(throwing: timeoutError)
            }
        }
    }

    #if DEBUG
    /// A test's stand-in for a read (the presence check's fetch, the subscription listing), within the read deadline:
    /// past it the caller goes on and the stand-in's task is cancelled. The shipped reads run on operations of their own
    /// (`operationRead`).
    private func withinReadDeadline<T: Sendable>(_ read: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await read() }
        return try await Self.awaitWithDeadline(
            readDeadline,
            onDeadline: { task.cancel() },
            timeoutError: CKError(.networkFailure),
            start: { (resume: @escaping @Sendable (Result<T, Error>) -> Void) in
                Task { resume(await task.result) }
            })
    }
    #endif

    /// The deadline a read that carries no file races: the save's 20 s, or a test's.
    private var readDeadline: TimeInterval {
        #if DEBUG
        if let readDeadlineForTesting { return readDeadlineForTesting }
        #endif
        return Self.saveAttemptDeadline
    }

    /// The stall and the cap a read that carries files races: the uploads' numbers, or a test's read deadline as the stall.
    private var readStallDeadlines: (stall: TimeInterval, cap: TimeInterval) { (readDeadline, Self.assetSaveCap) }

    /// Hands a read's operation to the database, or to a test in its place; `rejected` answers when it cannot go.
    private func submitRead(_ operation: CKDatabaseOperation, lease: CloudEnrollment.Lease, rejected: () -> Void) {
        #if DEBUG
        if let readSubmitForTesting { readSubmitForTesting(operation); return }
        #endif
        guard let database else { rejected(); return }
        submit(operation, to: database, lease: lease, rejected: rejected)
    }

    /// A read that carries no file, on a CloudKit operation of its own, within the read deadline (BACKLOG 180's A2 and
    /// codex-4). CloudKit's own resource timeout is measured in days, so a read on a path that looks online but passes
    /// nothing never answered, and it held its caller for the session: the presence check held the pending sweep's
    /// single-flight lock, and nothing pending uploaded again; the subscription listing held an automatic setup open.
    /// CloudKit's async calls could not be stopped either: before iOS 27 they wrap the callback calls with no
    /// cancellation. So the read is an operation, held in `activeOperations` (an account change cancels it) and cancelled
    /// at the deadline, where it fails as a network-class failure, as a stalled save does, for each caller's existing
    /// failure rule; a caller cancelled meanwhile cancels it and goes on at once (deepseek-3). `wire` sets the
    /// operation's blocks to answer through `resume`. Reads that carry files race a stall deadline instead: `queryPage`
    /// and `fetchMediaRecords`.
    private func operationRead<T: Sendable>(_ operation: CKDatabaseOperation, lease: CloudEnrollment.Lease,
                                            wire: (_ resume: @escaping @Sendable (Result<T, Error>) -> Void) -> Void)
        async throws -> T {
        let token = UUID()
        activeOperations[token] = operation
        defer { activeOperations[token] = nil }
        let bridge = ReadBridge<T>()
        return try await withTaskCancellationHandler {
            try await Self.awaitWithDeadline(
                readDeadline,
                onDeadline: { [weak operation] in
                    Log.cloud.error("An iCloud read stalled — cancelling the operation")
                    operation?.cancel()
                },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<T, Error>) -> Void) in
                    bridge.hold(resume)
                    wire(resume)
                    submitRead(operation, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
        } onCancel: { [weak operation] in
            operation?.cancel()
            bridge.fail(CancellationError())
        }
    }

    /// Records fetched by ID on an operation of their own, within the read deadline (`operationRead`), as `records(for:)`
    /// answered: each name's record or its own error; a name with no answer of its own was not checked.
    private func recordsByID(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?,
                             lease: CloudEnrollment.Lease) async throws -> FetchResults {
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        operation.desiredKeys = desiredKeys
        let fetched = FetchedRecords(expecting: ids)
        return try await operationRead(operation, lease: lease) { resume in
            operation.perRecordResultBlock = { @Sendable id, result in fetched.record(id, result) }
            operation.fetchRecordsResultBlock = { @Sendable result in resume(Self.fetchAnswer(result, fetched)) }
        }
    }

    /// A fetch by ID's answer as `records(for:)` gave it: a partial failure is answered record by record; any other
    /// failure is the fetch's as a whole.
    nonisolated private static func fetchAnswer(_ result: Result<Void, any Error>,
                                                _ fetched: FetchedRecords) -> Result<FetchResults, any Error> {
        switch result {
        case .success:
            return .success(fetched.snapshot())
        case .failure(let error):
            return (error as? CKError)?.code == .partialFailure ? .success(fetched.snapshot()) : .failure(error)
        }
    }

    /// One page of query results: each match in the query's order, and the cursor for the rest.
    typealias QueryPage = (matches: [(CKRecord.ID, Result<CKRecord, any Error>)], next: CKQueryOperation.Cursor?)
    /// A fetch by ID's answer: each name's record, or its own error.
    typealias FetchResults = [CKRecord.ID: Result<CKRecord, any Error>]

    /// One page of a query, from its start or from `cursor`, as `records(matching:)` and `records(continuingMatchFrom:)`
    /// answer it, under the stall deadline within the asset cap (BACKLOG 180's A2). A page can carry a hundred
    /// thumbnails, so a fixed 20 s could cut off a slow page that is still arriving: the clock restarts as each record
    /// arrives, and a page that stops arriving is cancelled and fails as a network-class failure, so the pull or the
    /// media-age walk reports itself incomplete instead of holding its caller for the session. A caller cancelled
    /// meanwhile cancels it and goes on at once (deepseek-3).
    private func queryPage(_ query: CKQuery, from cursor: CKQueryOperation.Cursor?,
                           lease: CloudEnrollment.Lease) async throws -> QueryPage {
        let operation: CKQueryOperation
        if let cursor { operation = CKQueryOperation(cursor: cursor) } else { operation = CKQueryOperation(query: query) }
        operation.resultsLimit = Self.fetchPageSize
        let matches = QueryPageMatches()
        let token = UUID()
        activeOperations[token] = operation
        defer { activeOperations[token] = nil }
        let deadlines = readStallDeadlines
        let bridge = ReadBridge<QueryPage>()
        return try await withTaskCancellationHandler {
            try await Self.awaitWithStallDeadline(
                stall: deadlines.stall, cap: deadlines.cap,
                onDeadline: { [weak operation] in
                    Log.cloud.error("A query page stalled — cancelling the operation")
                    operation?.cancel()
                },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<QueryPage, Error>) -> Void, progressed: @escaping @Sendable () -> Void) in
                    bridge.hold(resume)
                    operation.recordMatchedBlock = { @Sendable id, result in
                        matches.record(id, result)
                        progressed()   // the clock restarts
                    }
                    // Fires after every match: the final word on the page.
                    operation.queryResultBlock = { @Sendable result in
                        resume(result.map { (matches: matches.snapshot(), next: $0) })
                    }
                    submitRead(operation, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
        } onCancel: { [weak operation] in
            operation?.cancel()
            bridge.fail(CancellationError())
        }
    }

    /// The full download's fetch by ID, each record with its capture, as `records(for:)` answers it, under the stall
    /// deadline within the asset cap (BACKLOG 180's A2): a 60 s clip can take minutes on a slow link, so the clock
    /// restarts as CloudKit reports progress, and a fetch that stops moving is cancelled and fails as a network-class
    /// failure. A name with no answer of its own was not checked, and answers so, never as absent (R3-3). A caller
    /// cancelled meanwhile (the detail view closed) cancels it and goes on at once (deepseek-3).
    private func fetchMediaRecords(_ ids: [CKRecord.ID], lease: CloudEnrollment.Lease) async throws -> FetchResults {
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        let fetched = FetchedRecords(expecting: ids)
        let token = UUID()
        activeOperations[token] = operation
        defer { activeOperations[token] = nil }
        let deadlines = readStallDeadlines
        let bridge = ReadBridge<FetchResults>()
        return try await withTaskCancellationHandler {
            try await Self.awaitWithStallDeadline(
                stall: deadlines.stall, cap: deadlines.cap,
                onDeadline: { [weak operation] in
                    Log.cloud.error("Full-media fetch stalled — cancelling the operation")
                    operation?.cancel()
                },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<FetchResults, Error>) -> Void, progressed: @escaping @Sendable () -> Void) in
                    bridge.hold(resume)
                    operation.perRecordProgressBlock = { @Sendable _, _ in progressed() }   // the clock restarts
                    operation.perRecordResultBlock = { @Sendable id, result in
                        fetched.record(id, result)
                        progressed()
                    }
                    operation.fetchRecordsResultBlock = { @Sendable result in resume(Self.fetchAnswer(result, fetched)) }
                    submitRead(operation, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
        } onCancel: { [weak operation] in
            operation?.cancel()
            bridge.fail(CancellationError())
        }
    }

    /// The answer of a read's wait, kept so that its caller's cancel can end the wait too (BACKLOG 180's deepseek-3): an
    /// operation a test holds, or one CloudKit has not started, may never call its blocks back. `lock` guards `resume`.
    private final class ReadBridge<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resume: (@Sendable (Result<T, Error>) -> Void)?

        func hold(_ resume: @escaping @Sendable (Result<T, Error>) -> Void) { lock.withLock { self.resume = resume } }

        func fail(_ error: Error) { lock.withLock { resume }?(.failure(error)) }
    }

    /// Thread-safe collector for a subscription listing's answers (BACKLOG 180's codex-4).
    private final class ListedSubscriptions: @unchecked Sendable {
        private let lock = NSLock()
        private var subscriptions: [CKSubscription] = []

        func add(_ subscription: CKSubscription) { lock.withLock { subscriptions.append(subscription) } }

        func snapshot() -> [CKSubscription] { lock.withLock { subscriptions } }
    }

    /// Thread-safe collector for a query page's matches, in the order CloudKit gives them (item 180's A2): CloudKit
    /// runs the operation's blocks on its own queue.
    private final class QueryPageMatches: @unchecked Sendable {
        private let lock = NSLock()
        private var matches: [(CKRecord.ID, Result<CKRecord, any Error>)] = []

        func record(_ id: CKRecord.ID, _ result: Result<CKRecord, any Error>) {
            lock.lock(); defer { lock.unlock() }
            matches.append((id, result))
        }

        func snapshot() -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
            lock.lock(); defer { lock.unlock() }
            return matches
        }
    }

    /// Thread-safe collector for a fetch's per-record results (item 180's A2); an expected name with no answer of its
    /// own is reported as a failure, so the fetch reads as incomplete rather than that record as absent.
    private final class FetchedRecords: @unchecked Sendable {
        private let lock = NSLock()
        private let expected: [CKRecord.ID]
        private var answers: FetchResults = [:]

        init(expecting expected: [CKRecord.ID]) { self.expected = expected }

        func record(_ id: CKRecord.ID, _ result: Result<CKRecord, any Error>) {
            lock.lock(); defer { lock.unlock() }
            answers[id] = result
        }

        func snapshot() -> FetchResults {
            lock.lock(); defer { lock.unlock() }
            var all = answers
            for id in expected where all[id] == nil { all[id] = .failure(CKError(.networkFailure)) }
            return all
        }
    }

    /// Races an operation against a stall deadline (`awaitWithDeadline`'s shape, with progress; item 152's lead 2):
    /// the clock restarts whenever `progressed` is called, and `cap` bounds the whole wait. With no progress
    /// reported, or a cap equal to the stall, it is the fixed deadline it replaces. Timed on `ContinuousClock`, which
    /// no setting moves (item 162's A11); `now` is for tests.
    static func awaitWithStallDeadline<T: Sendable>(
        stall: TimeInterval, cap: TimeInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        onDeadline: @escaping @Sendable () -> Void,
        timeoutError: Error,
        start: (_ resume: @escaping @Sendable (Result<T, Error>) -> Void,
                _ progressed: @escaping @Sendable () -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let latch = ResumeLatch()
            let clock = StallClock(now: now)
            start({ result in
                guard latch.claim() else { return }
                cont.resume(with: result)
            }, { clock.noteProgress() })
            Task.detached {
                while !latch.done() {
                    let remaining = clock.remaining(stall: stall, cap: cap)
                    if remaining <= 0 { break }
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                guard latch.claim() else { return }
                onDeadline()
                cont.resume(throwing: timeoutError)
            }
        }
    }

    /// The stall deadline's clock: when the wait began, and when progress was last reported (CloudKit's progress
    /// block runs off the main actor), on `ContinuousClock`. On the calendar clock (item 162's A11), a clock set back
    /// during a stalled save lengthened its wait by up to the change, and one set forward cut the save short.
    final class StallClock: @unchecked Sendable {
        private let lock = NSLock()
        private let now: @Sendable () -> ContinuousClock.Instant
        private let began: ContinuousClock.Instant
        private var lastProgress: ContinuousClock.Instant

        /// `now` is for tests.
        init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
            self.now = now
            began = now()
            lastProgress = began
        }

        func noteProgress() { lock.withLock { lastProgress = now() } }

        /// Seconds until the deadline: the stall since the last progress, within the cap since the start.
        func remaining(stall: TimeInterval, cap: TimeInterval) -> TimeInterval {
            lock.withLock {
                let instant = now()
                return min(stall - (instant - lastProgress) / .seconds(1), cap - (instant - began) / .seconds(1))
            }
        }
    }

    /// Pure (unit-tested; item 152's lead 2): whether any record carries a `CKAsset` (a photo, a clip, a thumbnail).
    /// Its save may legitimately take longer than the fixed deadline while bytes move.
    nonisolated static func carriesAsset(_ records: [CKRecord]) -> Bool {
        records.contains { record in record.allKeys().contains { record[$0] is CKAsset } }
    }

    /// The whole wait an asset's save may take while progress keeps coming (item 152's lead 2): ten minutes, which
    /// a 60 s Until clear clip needs on a slow uplink; the stall deadline cuts off a save that stops moving sooner.
    nonisolated static let assetSaveCap: TimeInterval = 600

    /// The deadlines a save races: the production numbers, or a test's.
    private var saveDeadlines: (stall: TimeInterval, assetCap: TimeInterval) {
        #if DEBUG
        if let saveDeadlinesForTesting { return saveDeadlinesForTesting }
        #endif
        return (Self.saveAttemptDeadline, Self.assetSaveCap)
    }

    /// Saves records, retrying transient CloudKit failures with backoff. A single
    /// dropped push at trigger time can mean lost evidence (a stolen device never
    /// reaches `retryPendingSync`), so it's worth a few quick attempts — but bounded
    /// so it always finishes inside the background-task window rather than hanging.
    /// Each attempt builds a fresh operation (a CKOperation can only be added once),
    /// and each attempt races `saveAttemptDeadline` — a stalled operation is cancelled
    /// and reported as a network-class failure, so it feeds the same retry/escalation
    /// classification as a lost connection instead of hanging silently (F1). For a record
    /// carrying an asset the deadline is a stall deadline within `assetSaveCap` (item 152's
    /// lead 2): it restarts whenever CloudKit reports progress, so a clip that keeps moving
    /// is not cut off at 20 s on every attempt and every pass.
    ///
    /// Success requires EVERY record's own per-record confirmation, not the
    /// operation-level result — see `saveError` for the incident that made this rule.
    private func save(_ records: [CKRecord], lease: CloudEnrollment.Lease, permitted: () -> Bool) async throws {
        try requireCurrent(lease)
        let expected = records.map(\.recordID)
        let maxAttempts = 3
        var attempt = 0
        while true {
            try requireCurrent(lease)
            // The backup switch, before every attempt: a retry after it went off never goes out (item 116, R2).
            guard permitted() else { throw CKError(.notAuthenticated) }
            attempt += 1
            do {
                #if DEBUG
                if let saveAttemptForTesting {
                    try await saveAttemptForTesting(records)
                    try requireCurrent(lease)
                    return
                }
                #endif
                let op = CKModifyRecordsOperation(recordsToSave: records)
                op.qualityOfService = .userInitiated   // jump the queue
                op.savePolicy = .allKeys
                let token = UUID()
                activeOperations[token] = op
                defer { activeOperations[token] = nil }
                let results = PerRecordResults()
                // On CloudKit's queue, as the delete's blocks are (item 97).
                op.perRecordSaveBlock = { @Sendable id, result in results.record(id, result) }
                // A record carrying an asset races a stall deadline within a cap (item 152's lead 2): the 20 s restart
                // whenever CloudKit reports progress, so a clip that keeps moving on a slow uplink is not cut off;
                // a record without one keeps the fixed 20 s.
                let withAsset = Self.carriesAsset(records)
                let deadlines = saveDeadlines
                let cap = withAsset ? deadlines.assetCap : deadlines.stall
                try await Self.awaitWithStallDeadline(
                    stall: deadlines.stall, cap: cap,
                    onDeadline: { [weak op] in
                        Log.cloud.error("Save attempt stalled past \(deadlines.stall, privacy: .public)s — cancelling the operation")
                        op?.cancel()
                    },
                    timeoutError: CKError(.networkFailure),  // stall ≈ lost path: retry, count, escalate
                    start: { (resume: @escaping @Sendable (Result<Void, Error>) -> Void, progressed: @escaping @Sendable () -> Void) in
                    if withAsset { op.perRecordProgressBlock = { @Sendable _, _ in progressed() } }   // the clock restarts
                    // Fires after every perRecordSaveBlock — the final word on the operation.
                    op.modifyRecordsResultBlock = { @Sendable result in
                        let operationError: Error?
                        switch result {
                        case .success:                operationError = nil
                        case .failure(let error):     operationError = error
                        }
                        let (succeeded, failed) = results.snapshot()
                        if let error = Self.saveError(operationError: operationError,
                                                      succeeded: succeeded, failed: failed,
                                                      expecting: expected) {
                            resume(.failure(error))
                        } else {
                            resume(.success(()))
                        }
                    }
                    #if DEBUG
                    if let submitForTesting { submitForTesting(op); return }
                    #endif
                    guard let database else { resume(.failure(CKError(.notAuthenticated))); return }
                    submit(op, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
                })
                try requireCurrent(lease)
                return
            } catch {
                try requireCurrent(lease)
                guard attempt < maxAttempts,
                      let delay = Self.retryDelay(for: error, attempt: attempt) else {
                    // Giving up. When the reason is transient, say so for the pending sweep,
                    // which can wait as long as the server asked; this path cannot (item 79).
                    if let transient = Self.transientFailure(from: error) { noteTransientFailure(transient) }
                    throw error
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Thread-safe collector for `perRecordSaveBlock` results (CloudKit invokes it off
    /// the main actor, potentially once per record on different threads).
    private final class PerRecordResults: @unchecked Sendable {
        private let lock = NSLock()
        private var succeeded: Set<CKRecord.ID> = []
        private var failed: [CKRecord.ID: Error] = [:]

        func record(_ id: CKRecord.ID, _ result: Result<CKRecord, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result {
            case .success:            succeeded.insert(id)
            case .failure(let error): failed[id] = error
            }
        }

        func snapshot() -> (succeeded: Set<CKRecord.ID>, failed: [CKRecord.ID: Error]) {
            lock.lock(); defer { lock.unlock() }
            return (succeeded, failed)
        }
    }

    /// The error a finished save must surface — nil ONLY when every record was
    /// individually confirmed saved. Pure (unit-tested); see ADR 0004.
    ///
    /// The operation-level result alone is not proof. On 2026-08-28, on a device in
    /// Airplane Mode, a `CKModifyRecordsOperation` carrying `CKAsset`s "finished"
    /// with no error after its asset-token fetch failed offline: the per-record saves
    /// never ran, nothing reached the server, and the operation still reported success
    /// (unified log, operationIDs FA78E7096343CC14 / 7DD8B157BFD5BAA8). Trusting it
    /// marked unsent evidence `.synced` — which also exempted it from every later
    /// retry sweep, stranding the evidence on the device permanently.
    ///
    /// Rules, in order: an operation error stands as-is (it is what `retryDelay` and
    /// the interference classifier expect, `.partialFailure` included). Then a reported
    /// per-record failure stands — a real error classifies better than a synthesized
    /// one. Then a record with NO reported result is a failure: silence is not success.
    /// The synthesized error is deliberately NOT network-class — it must never feed
    /// the jamming escalation (ADR 0001) — and `retryDelay` treats it as terminal, so
    /// the event falls to `.localOnly` where the pending sweeps own the retry.
    nonisolated static func saveError(operationError: Error?,
                                      succeeded: Set<CKRecord.ID>,
                                      failed: [CKRecord.ID: Error],
                                      expecting: [CKRecord.ID]) -> Error? {
        if let operationError { return operationError }
        for id in expecting {
            if let recordError = failed[id] { return recordError }
            if !succeeded.contains(id) {
                return CKError(.internalError, userInfo: [
                    NSLocalizedDescriptionKey:
                        "CloudKit reported operation success without confirming record \(id.recordName)"
                ])
            }
        }
        return nil
    }

    /// What a save that finally FAILED for a transient reason tells the pending sweep (item 79):
    /// that another pass is worth making, and how long the server asked the app to stay away —
    /// the hint UNCAPPED, unlike `retryDelay`, whose 4 s ceiling exists for trigger-time pushes
    /// racing a power-off. A sweep has no such race; honouring the server's number is the point.
    struct TransientFailure: Equatable {
        let retryAfter: TimeInterval?
    }

    /// Pure (unit-tested): nil for an error that is not worth another pass (auth, quota, a
    /// record too large, anything unclassified); otherwise the transient failure, with the
    /// server's own Retry-After when it sent one. The same transient set and the same
    /// `.partialFailure` unwrapping as `retryDelay`, by construction: it asks `retryDelay`
    /// for the class.
    nonisolated static func transientFailure(from error: Error) -> TransientFailure? {
        guard retryDelay(for: error, attempt: 1) != nil, var ck = error as? CKError else { return nil }
        if ck.code == .partialFailure,
           let inner = ck.partialErrorsByItemID?.values.compactMap({ $0 as? CKError }).first {
            ck = inner
        }
        let hint = (ck as NSError).userInfo[CKErrorRetryAfterKey] as? TimeInterval
        // A hint that is not a usable number is no hint: the sweep falls back to its own wait.
        return TransientFailure(retryAfter: hint.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }

    /// Set by a save that GAVE UP on a transient failure — read by the pending sweep during
    /// and after a pass, cleared before the next (item 79). When several saves give up between
    /// clears, the longest wait the server asked for stands: coming back on the shortest would
    /// walk into the door the longest one named. Main-actor state like the rest of the class;
    /// the trigger-time paths set it too (it is the same server saying the same thing) and
    /// never consult it.
    private(set) var lastTransientFailure: TransientFailure?
    func clearTransientFailure() { lastTransientFailure = nil }

    /// Internal rather than private only so the longest-wait rule is pinned by a test.
    func noteTransientFailure(_ failure: TransientFailure) {
        let hints = [lastTransientFailure?.retryAfter, failure.retryAfter].compactMap { $0 }
        lastTransientFailure = TransientFailure(retryAfter: hints.max())
    }

    /// Backoff for a transient CloudKit error: the server's suggested Retry-After
    /// if it gave a usable one (finite, not negative), else a capped exponential fallback.
    /// Always a finite wait from 0 to 4 s. Returns nil for errors that aren't worth
    /// retrying (auth, quota, permission…).
    nonisolated static func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        guard var ck = error as? CKError else { return nil }
        // A CKModifyRecordsOperation reports per-record problems as `.partialFailure`
        // with the *real* code nested in `partialErrorsByItemID`. Unwrap it, or a
        // transient failure (network/rate-limit) looks permanent and the retry defense
        // is silently bypassed at the exact moment it matters most (F-10).
        if ck.code == .partialFailure,
           let inner = ck.partialErrorsByItemID?.values.compactMap({ $0 as? CKError }).first {
            ck = inner
        }
        // NOTE: `.limitExceeded` is deliberately NOT here. It means the record/asset is too
        // large for CloudKit — retrying can only fail again, and it would burn the whole
        // retry budget inside the sub-second window we're racing a power-off (F4). Treated
        // as permanent: fall back to `.localOnly` at once and let the reconnect path retry.
        let transient: Set<CKError.Code> = [.networkUnavailable, .networkFailure,
                                            .serviceUnavailable, .requestRateLimited, .zoneBusy,
                                            .serverResponseLost]
        guard transient.contains(ck.code) else { return nil }
        // Cap every wait — even the server's own Retry-After — so a large throttle
        // hint can't push the retries past our background-task window (better to
        // fall back to local-only and re-upload later than to be suspended waiting).
        let maxBackoff: TimeInterval = 4
        // A hint that is not a usable wait (negative, or not a number) is no hint, as for the
        // pending sweep (item 74, line 10): passed through, the save path's conversion to
        // nanoseconds would trap.
        if let suggested = (ck as NSError).userInfo[CKErrorRetryAfterKey] as? TimeInterval,
           suggested.isFinite, suggested >= 0 {
            return min(suggested, maxBackoff)
        }
        return min(0.5 * pow(2.0, Double(attempt - 1)), maxBackoff)   // 0.5s, 1s, 2s…
    }

    // MARK: - Subscription (cross-device push)

    /// What a caller may do to the ACCOUNT's alert subscription (H6, option A). Pure so the
    /// boundary is pinned: alerts are account state — one subscription, pushed by Apple to
    /// every device on the account (the build-24 pair proved the scoping live: the personal
    /// phone received alerts from a subscription only the test device ever created; this is
    /// also why per-device subscription IDs were considered and REJECTED — N subscriptions
    /// would mean N duplicate pushes to everyone, not per-device receipt). An arm may HEAL
    /// the subscription into existence but never delete it: arming with a local toggle off
    /// used to remove it for the whole account, then stay broken until that device re-armed
    /// (the owner's stuck-session finding). Only an explicit toggle flip
    /// (`setCrossDeviceAlerts`) removes.
    enum SubscriptionAction: Equatable { case ensure, leaveAlone, remove }
    nonisolated static func subscriptionActionOnArm(notifyWanted: Bool) -> SubscriptionAction {
        notifyWanted ? .ensure : .leaveAlone
    }

    /// The Settings toggle's direct line (H6, option A): applies the account-wide state
    /// immediately, from any device, in both directions — ON heals a deleted or failed-setup
    /// subscription with no re-arm anywhere; OFF removes it for every device. Returns whether
    /// the change landed so Settings can say so — a failed OFF has no backstop (arm and
    /// reconnect are create-only), so the owner must retry the flip. OFF requires fresh
    /// device-owner authentication and an unchanged account; background paths never prompt.
    /// A change under way supersedes the automatic setups in flight (`automaticSetupWanted`,
    /// codex-21): the switch reads the old choice until this returns.
    func setCrossDeviceAlerts(_ enabled: Bool) async -> Bool {
        alertsChoiceChanges += 1
        alertsChoiceChangesUnderWay += 1
        defer {
            alertsChoiceChangesUnderWay -= 1
            alertsChoiceChanges += 1
        }
        guard let lease = await acquireCloudLease() else { return false }
        if enabled { return await ensureSubscription(lease: lease) }
        guard let control = await enrollment.authorizeAccountControl(account: lease.account),
              enrollment.isCurrent(lease), enrollment.isCurrent(control),
              let account = await userRecordName(), account == lease.account,
              enrollment.isCurrent(control) else { return false }
        return await removeSubscription(lease: control)
    }

    /// Pure (unit-tested): the tamper subscription — `metaRecordTypeV2`, match everything,
    /// a static body (no field of the record is plaintext, so none could be interpolated).
    nonisolated static func makeTamperSubscription() -> CKQuerySubscription {
        makeSubscription(recordType: metaRecordTypeV2, id: subscriptionID,
                         body: "Tamper detected on your device.")
    }

    /// Pure (unit-tested): the disarm subscription (BACKLOG 59) — `disarmSignalRecordTypeV2`,
    /// match everything (only disarms and cancelled countdowns are written to it), the same static
    /// shape; its sentence names both (item 156, the owner's wording).
    nonisolated static func makeDisarmSubscription() -> CKQuerySubscription {
        makeSubscription(recordType: disarmSignalRecordTypeV2, id: disarmSubscriptionID,
                         body: "Malinois was disarmed, or arming was cancelled, on one of your devices.")
    }

    private nonisolated static func makeSubscription(recordType: String, id: String,
                                                     body: String) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: id,
            options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.title = "Malinois"
        info.alertBody = body
        info.soundName = "default"
        info.shouldSendContentAvailable = true   // wake the other device to pull the record into its log
        // Older enrolled clients may enrich mutable alerts. This maintenance build's extension
        // keeps generic text: it has no installation-bound grant for private-record reads.
        info.shouldSendMutableContent = true
        subscription.notificationInfo = info
        return subscription
    }

    /// Pure (unit-tested): which of the two current subscriptions to save, given what the account
    /// already has, in the order they are established — tamper first, so the alert that has
    /// shipped since 1.0 never waits on the newer one. A missing one is created; one without
    /// mutable pushes (made by 1.3.x) is saved again under its own ID (item 76), which replaces
    /// it: a new ID would make a device still on 1.3.x, which creates only missing IDs, add the
    /// old one back, and a mixed account would get two alerts per event. One that alerts with a
    /// retired sentence is saved again the same way (item 156), and only a sentence this build
    /// knows to be retired: a later build's is left alone, so devices on two builds never take
    /// turns saving their own.
    nonisolated static func subscriptionsToSave(existing: [String: StoredSubscription]) -> [CKQuerySubscription] {
        [makeTamperSubscription(), makeDisarmSubscription()].filter { wanted in
            guard let stored = existing[wanted.subscriptionID] else { return true }
            return !stored.mutable || stored.body.map(retiredSubscriptionBodies.contains) == true
        }
    }

    /// Sentences an earlier build's subscriptions alerted with (item 156): 1.8.1's disarm sentence,
    /// which did not say that a cancelled countdown sends the alert too.
    nonisolated static let retiredSubscriptionBodies: Set<String> = ["Malinois was disarmed on one of your devices."]

    /// What `subscriptionsToSave` reads of a subscription the account already has: whether it sends mutable pushes,
    /// and the sentence it alerts with.
    struct StoredSubscription: Equatable, Sendable {
        let mutable: Bool
        let body: String?
    }

    @discardableResult
    private func ensureSubscription(lease: CloudEnrollment.Lease,
                                    stillWanted: @MainActor () -> Bool = { true }) async -> Bool {
        guard enrollment.isCurrent(lease) else { return false }
        let existing: [CKSubscription]
        do {
            existing = try await allSubscriptions(lease: lease)
            try requireCurrent(lease)
        } catch { return false }
        guard stillWanted() else { return false }   // asked again after the fetch, and before each save (codex-19)
        let existingIDs = Set(existing.map(\.subscriptionID))
        // The 1.0 subscription watched the plaintext meta type, which nothing writes to any
        // more. Left in place it would sit there firing on nothing, so it goes as soon as its
        // replacement is being established. Deleted only when actually present, to keep a
        // routine arm from spending a network round trip on a no-op every time.
        var allSucceeded = true
        if existingIDs.contains(Self.legacySubscriptionID) {
            allSucceeded = await deleteSubscriptions([Self.legacySubscriptionID], lease: lease)
        }
        // One operation per subscription, on purpose: the disarm subscription's record type
        // may not be deployed yet (BACKLOG 59's Production prerequisite), and its failure must
        // not take the tamper alert down with it. The result reported to Settings is the
        // combined result; either subscription's failure remains visible and retryable.
        let storedByID = Dictionary(existing.map { subscription in
            (subscription.subscriptionID, StoredSubscription(mutable: subscription.notificationInfo?.shouldSendMutableContent ?? false,
                                                             body: subscription.notificationInfo?.alertBody))
        }, uniquingKeysWith: { first, _ in first })
        for subscription in Self.subscriptionsToSave(existing: storedByID) {
            guard stillWanted() else { return false }
            let saved = await saveSubscription(subscription, lease: lease)
            allSucceeded = saved && allSucceeded
        }
        return allSucceeded && enrollment.isCurrent(lease)
    }

    /// The account's subscriptions, as CloudKit lists them, on an operation of its own within the read deadline (item
    /// 180's A2 and codex-4); a test's stand-in for the listing meets the deadline too. A listing that fails in part
    /// fails as a whole, as `allSubscriptions()` did.
    private func allSubscriptions(lease: CloudEnrollment.Lease) async throws -> [CKSubscription] {
        #if DEBUG
        if let existing = existingSubscriptionsForTesting {
            return try await withinReadDeadline { try await existing() }
        }
        #endif
        let operation = CKFetchSubscriptionsOperation.fetchAllSubscriptionsOperation()
        let listed = ListedSubscriptions()
        return try await operationRead(operation, lease: lease) { resume in
            operation.perSubscriptionResultBlock = { @Sendable _, result in
                if case .success(let subscription) = result { listed.add(subscription) }
            }
            operation.fetchSubscriptionsResultBlock = { @Sendable result in resume(result.map { listed.snapshot() }) }
        }
    }

    private func saveSubscription(_ subscription: CKQuerySubscription, lease: CloudEnrollment.Lease) async -> Bool {
        #if DEBUG
        if let save = subscriptionSaveForTesting { return enrollment.isCurrent(lease) ? await save(subscription) : false }
        #endif
        guard enrollment.isCurrent(lease), let database else { return false }
        do {
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription])
            op.qualityOfService = .utility
            let token = UUID()
            activeOperations[token] = op
            defer { activeOperations[token] = nil }
            try await Self.awaitWithDeadline(Self.saveAttemptDeadline,
                onDeadline: { op.cancel() }, timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<Void, Error>) -> Void) in
                op.modifySubscriptionsResultBlock = { @Sendable result in
                    switch result {
                    case .success: resume(.success(()))
                    case .failure(let error): resume(.failure(error))
                    }
                }
                submit(op, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
            })
            try requireCurrent(lease)
            return true
        } catch {
            Log.cloud.error("Subscription setup failed (\(subscription.subscriptionID, privacy: .public)): \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            return false
        }
    }

    /// Removes the cross-device push subscription so every device stops being alerted
    /// (only the explicit toggle flip calls this — see `SubscriptionAction`).
    ///
    /// Deletes the 1.0 subscription alongside the current ones (tamper + disarm): turning the
    /// option off has to silence *every* subscription this app has ever created, not just
    /// the newest, or a device that armed under an older build would keep pushing after the
    /// owner opted out.
    @discardableResult
    private func removeSubscription(lease: CloudEnrollment.Lease) async -> Bool {
        await deleteSubscriptions(Self.subscriptionIDsToRemove, lease: lease)
    }

    /// CloudKit calls these blocks on its own queue; the lock protects every read and write of the results.
    /// Internal so tests can also check operation-level partial failures, which current Swift overlays normalize.
    final class SubscriptionDeleteResults: @unchecked Sendable {
        private let lock = NSLock()
        private var absent: Set<String> = []
        private var failed: Set<String> = []

        func record(_ id: String, _ result: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result {
            case .success: absent.insert(id)
            case .failure(let error):
                if (error as? CKError)?.code == .unknownItem { absent.insert(id) }
                else { failed.insert(id) }
            }
        }

        func complete(operationError: Error?, expecting: [String]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let operationError, (operationError as? CKError)?.code != .partialFailure { return false }
            return failed.isEmpty && expecting.allSatisfy { absent.contains($0) }
        }
    }

    /// Deletes subscriptions by ID. Each ID must be confirmed deleted or already absent (`unknownItem`); a real
    /// per-ID failure, an unanswered ID or a non-partial operation error leaves the removal unconfirmed.
    @discardableResult
    private func deleteSubscriptions(_ ids: [String], lease: CloudEnrollment.Lease) async -> Bool {
        #if DEBUG
        if let remove = subscriptionRemovalForTesting { return enrollment.isCurrent(lease) ? await remove(ids) : false }
        #endif
        guard enrollment.isCurrent(lease) else { return false }
        let op = CKModifySubscriptionsOperation(subscriptionIDsToDelete: ids)
        op.qualityOfService = .utility
        let results = SubscriptionDeleteResults()
        op.perSubscriptionDeleteBlock = { @Sendable id, result in results.record(id, result) }
        let token = UUID()
        activeOperations[token] = op
        defer { activeOperations[token] = nil }
        do {
            try await Self.awaitWithDeadline(Self.saveAttemptDeadline,
                onDeadline: { op.cancel() }, timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<Void, Error>) -> Void) in
                op.modifySubscriptionsResultBlock = { @Sendable result in
                    let operationError: Error?
                    switch result {
                    case .success: operationError = nil
                    case .failure(let error): operationError = error
                    }
                    if results.complete(operationError: operationError, expecting: ids) {
                        resume(.success(()))
                    } else {
                        resume(.failure(operationError ?? CKError(.internalError)))
                    }
                }
                #if DEBUG
                if let subscriptionDeleteSubmitForTesting { subscriptionDeleteSubmitForTesting(op); return }
                #endif
                guard let database else { resume(.failure(CKError(.notAuthenticated))); return }
                submit(op, to: database, lease: lease) { resume(.failure(CKError(.notAuthenticated))) }
            })
            try requireCurrent(lease)
            return true
        } catch {
            Log.cloud.error("Subscription removal failed: \(Log.ref(error), privacy: .public) \(error, privacy: .private)")
            return false
        }
    }

    // MARK: - Utilities

    #if DEBUG
    /// Replaces only the temporary directory; tests still use the real staging and launch cleanup paths.
    static var thumbnailTempRootForTesting: URL?
    #endif

    private static let thumbnailTempPrefix = "malinois-upload-thumbnail-"
    // Every staging write, sweep and defer runs synchronously on MainActor, across all uploader instances.
    private static var activeThumbnailFiles: Set<URL> = []

    private static var thumbnailTempRoot: URL {
        #if DEBUG
        if let root = thumbnailTempRootForTesting { return root }
        #endif
        return FileManager.default.temporaryDirectory
    }

    /// Removes only direct regular files named by this uploader, excluding every live upload in this process.
    /// Run synchronously before launch builds the engine. Ambiguous legacy names and symlinks stay untouched.
    /// A supplied directory isolates filesystem tests; enumeration or deletion failures leave files for later.
    static func sweepOrphanedThumbnails(in root: URL? = nil) {
        let fm = FileManager.default
        let directory = root ?? thumbnailTempRoot
        // Check the supplied root itself before resolving aliases for consistent enumeration and live-file keys.
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fm.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let files = try? fm.contentsOfDirectory(at: canonicalDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let basename = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jpg", basename.hasPrefix(thumbnailTempPrefix) else { continue }
            let identifier = String(basename.dropFirst(thumbnailTempPrefix.count))
            guard UUID(uuidString: identifier)?.uuidString == identifier,
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  !activeThumbnailFiles.contains(file.resolvingSymlinksInPath().standardizedFileURL) else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private static func removeTemporaryThumbnail(_ url: URL) {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        try? FileManager.default.removeItem(at: url)
        activeThumbnailFiles.remove(key)
    }

    private func writeTemp(_ data: Data, ext: String) -> URL? {
        let url = Self.thumbnailTempRoot
            .appendingPathComponent(Self.thumbnailTempPrefix + UUID().uuidString + "." + ext)
        do {
            try data.write(to: url, options: .atomic)
            Self.activeThumbnailFiles.insert(url.resolvingSymlinksInPath().standardizedFileURL)
            return url
        } catch { return nil }
    }
}
