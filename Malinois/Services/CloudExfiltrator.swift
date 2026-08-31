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
            case .error: return "iCloud error — check iCloud in iOS Settings"
            }
        }
        var isReady: Bool { self == .available }

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
    /// silent. A correctly-worded "your device was disarmed" push would need its own
    /// subscription and is deliberately not bundled in here.
    nonisolated static let stateRecordTypeV2 = "TamperEventStateV2"

    /// Watches `metaRecordTypeV2`. A **new ID on purpose**: a `CKQuerySubscription`'s record
    /// type is fixed when it is created, so reusing the 1.0 ID would leave the owner's other
    /// devices subscribed to a type nothing writes to any more — cross-device push would go
    /// quiet with no error raised anywhere. The old subscription is deleted whenever this one
    /// is established.
    private static let subscriptionID = "malinois-tamper-meta-v2-sub"
    private static let legacySubscriptionID = "malinois-tamper-meta-sub"

    /// Set once the container can't be created (simulator, or a device build whose
    /// CloudKit entitlement isn't applied) — surfaced on Home so the local-only fallback
    /// isn't mistaken for a bug.
    @Published private(set) var cloudUnavailable = false

    /// Whether the last `fetchRecentEvents` had at least one query **fail**, as opposed to
    /// returning nothing. Without this the two are indistinguishable — every query returns `[]`
    /// on error — and the background-push path would report success to iOS for a fetch that
    /// never ran.
    private(set) var lastFetchFailed = false

    /// Highest metadata revision successfully submitted this session, per event.
    ///
    /// In memory on purpose: the only writer that can be *stale* is the sparse pre-capture
    /// fact, which exists only during a live trigger. After a relaunch every re-push carries the
    /// stored event, so there is no older writer left to lose a race to.
    private var submittedMetaRevisions: [UUID: Int] = [:]

    private static let containerProbeKey = "com.malinois.cloud.containerProbe"

    /// The build (CFBundleVersion) currently running. The probe is scoped to it so a *new*
    /// build always gets a fresh attempt (V-02).
    private static var currentBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
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
                                        build: Self.currentBuild)
        guard strikes < Self.probeStrikeLimit else {
            markCloudUnavailable()       // THIS build died here repeatedly — don't try again
            return nil
        }
        defaults.set("\(Self.currentBuild)|\(strikes + 1)", forKey: Self.containerProbeKey)
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

    /// Called on arm: check account status and (if enabled) set up the push
    /// subscription so the user's OTHER devices are alerted the moment a trip
    /// lands. Warms the connection to cut cold-start latency at trigger time.
    func warmUp(notifyOtherDevices: Bool) async {
        await refreshAccountState()
        guard accountState.isReady, let database else { return }
        switch Self.subscriptionActionOnArm(notifyWanted: notifyOtherDevices) {
        case .ensure:     await ensureSubscription()
        case .remove:     await removeSubscription()
        case .leaveAlone: break
        }
        // A cheap no-op query to establish the connection early.
        _ = try? await database.records(
            matching: CKQuery(recordType: Self.metaRecordTypeV2,
                              predicate: NSPredicate(value: false)),
            resultsLimit: 1)
    }

    /// Re-establish (or tear down) the cross-device push subscription after a
    /// connectivity restore. `warmUp` sets this up at arm, but if the network was
    /// down then the setup silently failed and the owner's other devices would get
    /// no push for the entire armed session. Calling this the moment a path returns
    /// recovers it. Idempotent — `ensureSubscription` no-ops if it already exists.
    func refreshSubscription(notifyOtherDevices: Bool) async {
        await refreshAccountState()
        guard accountState.isReady, database != nil else { return }
        switch Self.subscriptionActionOnArm(notifyWanted: notifyOtherDevices) {
        case .ensure:     await ensureSubscription()
        case .remove:     await removeSubscription()
        case .leaveAlone: break
        }
    }

    /// How long the account-status preflight may wait for cloudd's answer. It runs INSIDE
    /// the per-event upload chain (`pushFact` → `enqueue`) and the retry sweep's
    /// single-flight window, so a stall here used to jam both for the rest of the process —
    /// the same never-fails-so-nothing-escalates hazard as a stalled save (fourth-pass
    /// R3-1, completing sixth-review F1 through the door its deadline didn't cover).
    /// Generous: a healthy answer is near-instant.
    nonisolated static let accountStatusDeadline: TimeInterval = 10

    func refreshAccountState() async {
        guard let container else { accountState = .noAccount; return }
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
            switch status {
            case .available:            accountState = .available
            case .noAccount:            accountState = .noAccount
            case .restricted:           accountState = .restricted
            case .couldNotDetermine:    accountState = .error("could not determine")
            case .temporarilyUnavailable: accountState = .error("temporarily unavailable")
            @unknown default:           accountState = .error("unknown")
            }
        } catch {
            // Timeout lands here as a network-class error: `canAttempt` stays optimistic,
            // so the caller proceeds into the DEADLINE-BOUNDED save, which is the judge —
            // the point is that nothing above it can hang, not that a slow answer aborts.
            accountState = .error(error.localizedDescription)
        }
    }

    // MARK: - Per-event upload serialization (1.2 coordinator; ADR 0003)

    /// The tail of each event's upload chain, plus a token so the last write out can clear
    /// its entry. Every CloudKit write for one event runs strictly after the previous write
    /// for that event has FINISHED — which closes review B2's residual race for good: two
    /// writes can no longer both preflight before either lands, so a stale fact retry can
    /// never overwrite a richer record from this process. Chains for different events stay
    /// concurrent; `retryPendingSync`'s bounded parallelism is unaffected.
    private var uploadChains: [UUID: Task<Void, Never>] = [:]
    private var uploadChainTokens: [UUID: Int] = [:]

    /// Runs `op` after everything already queued for `id`. Internal rather than private
    /// only so the ordering property is pinned by a test.
    func enqueue<T>(_ id: UUID, _ op: @escaping @MainActor () async -> T) async -> T {
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
        return await work.value
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
    func pushFact(_ event: Event) async {
        await enqueue(event.id) { [self] in
            // The cached state is an optimization, not an authority: a single transient
            // `.couldNotDetermine` at arm must not silently kill exfiltration for the whole
            // watch. Re-check once if it looks unavailable, and abort only on a hard no.
            if !accountState.isReady { await refreshAccountState() }
            guard accountState.canAttempt else { return }
            let bgTask = beginBackgroundTask()
            defer { endBackgroundTask(bgTask) }
            _ = await pushMetaRecord(event)
        }
    }

    /// Pushes the event. Returns the final sync state to persist, with the meta failure's
    /// classification when there was one (32.R1).
    /// `fullMediaURL` is the on-disk full-res still or clip (may be nil);
    /// `secondaryMediaURL` is the second capture from the "Both" camera option.
    func exfiltrate(_ event: Event, fullMediaURL: URL?, secondaryMediaURL: URL? = nil) async -> ExfilOutcome {
        await enqueue(event.id) { [self] in
            await exfiltrateNow(event, fullMediaURL: fullMediaURL, secondaryMediaURL: secondaryMediaURL)
        }
    }

    private func exfiltrateNow(_ event: Event, fullMediaURL: URL?, secondaryMediaURL: URL?) async -> ExfilOutcome {
        if !accountState.isReady { await refreshAccountState() }
        guard accountState.canAttempt else {
            // A definitive no-account / restricted is an ANSWER about this device's iCloud,
            // not interference — it must never sound the siren (32.R1).
            return ExfilOutcome(syncState: .localOnly, metaFailureWasInterference: false)
        }

        // Hold a background-task assertion for the whole operation.
        let bgTask = beginBackgroundTask()
        defer { endBackgroundTask(bgTask) }

        // ---- Shot 1: tiny record (fast path) ----
        let metaError = await pushMetaRecord(event)

        // ---- Shot 2: full-resolution follow-up(s) ----
        // Record names carry the camera ("photo-front" / "photo-rear") so they're
        // easy to tell apart in the CloudKit Console.
        var fullLanded = true
        if let url = fullMediaURL {
            fullLanded = await pushPhotoRecord(event, mediaURL: url,
                                               suffix: "photo-\(event.primaryMediaToken)")
        }
        if let url = secondaryMediaURL {
            fullLanded = await pushPhotoRecord(event, mediaURL: url,
                                               suffix: "photo-\(event.secondaryMediaToken)") && fullLanded
        }

        if let metaError {
            return ExfilOutcome(syncState: .localOnly,
                                metaFailureWasInterference: Self.failureSuggestsInterference(metaError))
        }
        // Core evidence up; a missing full-res follow-up retries later.
        return ExfilOutcome(syncState: fullLanded ? .synced : .pending,
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
    /// what is actually being written: the sparse pre-capture fact is 1, the post-capture
    /// record carrying evidence (a thumbnail or a stored media file) is 2, and an
    /// owner-attributed re-push is 3. Every component only ever becomes true, so the number
    /// only ever rises.
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
    /// Known residual, recorded in BACKLOG 34: a camera-off event's rich push stays at
    /// revision 1 (equal to its fact, so only its endDate/duration can regress). The
    /// same-revision preflight race is CLOSED as of 1.2 — every write for one event runs
    /// through the per-event chain (`enqueue`), strictly after the previous one finished.
    nonisolated static func metaRevision(for event: Event) -> Int {
        var revision = 1
        if event.thumbnailData != nil || event.mediaFilename != nil
            || event.secondaryMediaFilename != nil { revision += 1 }
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

    /// Returns nil when the record landed (or a richer one already stands — the stale-skip),
    /// else the terminal error, so the caller can classify it (32.R1).
    private func pushMetaRecord(_ event: Event) async -> Error? {
        // Inline the few-KB thumbnail as an asset. The temp file backing the
        // CKAsset is deleted once the upload finishes (see defer) so it doesn't
        // accumulate one orphan per event.
        var tempAssetURL: URL?
        if let thumb = event.thumbnailData {
            tempAssetURL = writeTemp(thumb, ext: "jpg")
        }
        defer { if let tempAssetURL { try? FileManager.default.removeItem(at: tempAssetURL) } }

        let revision = Self.metaRevision(for: event)
        guard Self.mayWrite(revision: revision, alreadySubmitted: submittedMetaRevisions[event.id]) else {
            // A richer record is already on the server; this is a stale retry of an earlier one.
            // Reported as landed, because the event *is* in iCloud — just in better shape than
            // this write would have left it.
            Log.cloud.info("Skipped a stale meta write (revision \(revision, privacy: .public))")
            return nil
        }
        let record = Self.makeMetaRecord(event,
                                         deviceName: DeviceInfo.name,
                                         thumbnailURL: tempAssetURL)
        do {
            try await save([record])
            submittedMetaRevisions[event.id] = max(submittedMetaRevisions[event.id] ?? 0, revision)
            return nil
        } catch {
            Log.cloud.error("Meta push failed: \(String(describing: error), privacy: .public)")
            if Self.indicatesEncryptedDataReset(error) { encryptedDataResetDetected = true }
            return error
        }
    }

    private func pushPhotoRecord(_ event: Event, mediaURL: URL, suffix: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: mediaURL.path) else { return false }
        let record = Self.makePhotoRecord(event, mediaURL: mediaURL, suffix: suffix)

        do {
            try await save([record])
            return true
        } catch {
            Log.cloud.error("Photo push failed: \(String(describing: error), privacy: .public)")
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
    func pushStateChange(_ event: Event) async -> Bool {
        guard let kind = event.stateChange else { return false }
        return await enqueue(event.id) { [self] in
            await refreshAccountState()
            guard accountState.isReady else { return false }
            let record = Self.makeStateRecord(event, kind: kind, deviceName: DeviceInfo.name)
            do {
                try await save([record])
                return true
            } catch {
                Log.cloud.error("State push failed: \(String(describing: error), privacy: .public)")
                if Self.indicatesEncryptedDataReset(error) { encryptedDataResetDetected = true }
                return false
            }
        }
    }

    // MARK: - Reading back (BACKLOG 9b)

    /// A thumbnail is a few KB by construction (`CameraController.thumbnail`, JPEG q0.4 at
    /// ≤200 px). A fetched "thumbnail" beyond this is not one — a corrupted or hand-crafted
    /// record — and inlining it would bloat the log the mirror fetch is meant to keep small.
    nonisolated static let maxThumbnailBytes = 512 * 1024

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

    /// Device labels from the cloud are display strings, not protocol — cap them (F6; the
    /// outbound side is already sanitized at entry, this bounds a hand-crafted record).
    nonisolated static func sanitizedDeviceName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "another device" }
        return String(raw.prefix(64))
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
        // loses a detail; inventing a case would corrupt the record.
        let sensors = ((customField("triggeredSensors", of: record) as? String) ?? "")
            .split(separator: ",")
            .compactMap { SensorType(rawValue: String($0)) }
            .sorted { $0.rawValue < $1.rawValue }

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
        var capturedOffline: Bool?
        var sustainedCount: Int?
        var primaryCamera: String?, secondaryCamera: String?
        var primaryDuration: Double?, secondaryDuration: Double?
        var mediaDiscarded: Bool?
        var manifest: [String]?
        if let json = customField("metadataJSON", of: record) as? String,
           let data = json.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            interrupted = obj["interrupted"] as? Bool
            capturedOffline = obj["capturedOffline"] as? Bool
            sustainedCount = Self.validSustainedCount(obj["sustainedCount"] as? Int)
            primaryCamera = Self.validCameraToken(obj["primaryCamera"] as? String)
            secondaryCamera = Self.validCameraToken(obj["secondaryCamera"] as? String)
            primaryDuration = Self.validDuration(obj["primaryDuration"] as? Double)
            secondaryDuration = Self.validDuration(obj["secondaryDuration"] as? Double)
            mediaDiscarded = obj["mediaDiscarded"] as? Bool
            if let raw = obj["media"] as? [Any] {
                let tokens = raw.compactMap { $0 as? String }
                                .filter { Self.allowedMediaTokens.contains($0) }
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
            sourceDevice: Self.sanitizedDeviceName(customField("deviceName", of: record) as? String),
            // Lets a mirrored copy be replaced by a later revision of itself instead of being
            // frozen at whichever one arrived first (see `EventStore.supersedes`). The merge
            // trusts this ordering, so a nonsensical value is dropped rather than obeyed.
            cloudRevision: Self.validRevision(customField("revision", of: record) as? Int),
            mediaDiscarded: mediaDiscarded,
            cloudMediaManifest: manifest)
    }

    /// The only camera tokens a cloud payload may name. The manifest's feed record-name
    /// construction on the retrieval side, so anything else is dropped, not obeyed (the
    /// validation-caps rule: allow-list whatever becomes an identifier).
    nonisolated static let allowedMediaTokens: Set<String> = ["front", "rear", "primary", "secondary"]
    /// Camera display fields are narrower still: only the two real cameras.
    nonisolated static func validCameraToken(_ raw: String?) -> String? {
        raw.flatMap { $0 == "front" || $0 == "rear" ? $0 : nil }
    }
    /// A clip duration from the cloud: finite, non-negative, and no longer than a day.
    nonisolated static func validDuration(_ raw: Double?) -> Double? {
        raw.flatMap { $0.isFinite && $0 >= 0 && $0 <= 86_400 ? $0 : nil }
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
              ["armed", "disarmed", "gaLifted"].contains(kind)
        else { return nil }
        let start = clampedStartDate(rawStart, recordCreated: record.creationDate, now: Date())
        return Event(id: id, startDate: start, endDate: start,
                     triggeredSensors: [],
                     cloudSyncState: .synced,
                     stateChange: kind,
                     sourceDevice: sanitizedDeviceName(customField("deviceName", of: record) as? String))
    }

    /// Pulls recent evidence **and** the arm/disarm audit trail out of the owner's private
    /// database.
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
        await refreshAccountState()
        guard accountState.isReady, let database else { return [] }
        let metaV2 = await fetch(Self.metaRecordTypeV2, from: database,
                                 limit: limit, decode: Self.event(from:))
        let metaV1 = await fetch(Self.metaRecordType, from: database,
                                 limit: limit, decode: Self.event(from:))
        let stateV2 = await fetch(Self.stateRecordTypeV2, from: database,
                                  limit: limit, decode: Self.stateEvent(from:))
        let stateV1 = await fetch(Self.stateRecordType, from: database,
                                  limit: limit, decode: Self.stateEvent(from:))
        lastFetchFailed = [metaV2, metaV1, stateV2, stateV1].contains { !$0.ok }
        let evidence = metaV2.events + metaV1.events
        let stateChanges = stateV2.events + stateV1.events
        Log.cloud.info("Fetched \(evidence.count, privacy: .public) event(s) + \(stateChanges.count, privacy: .public) state record(s)")
        return evidence + stateChanges
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
    /// Returns the decoded events **and whether the query actually ran**. The two are not the
    /// same: an unindexed record type makes the query *fail*, and reporting that as "no events"
    /// is how a broken restore looks identical to an empty one.
    private func fetch(_ recordType: String,
                       from database: CKDatabase,
                       limit: Int,
                       decode: (CKRecord) -> Event?) async -> (events: [Event], ok: Bool) {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var out: [Event] = []
        var cursor: CKQueryOperation.Cursor?
        do {
            // Follow the cursor. A single `records(matching:)` returns one page and hands back a
            // cursor for the rest; discarding it silently capped a restore at one page per record
            // type, however much was actually in iCloud. The owner passed 90 events in August, so
            // this was days away from quietly dropping the oldest evidence from every restore —
            // and a restore that returns *most* of the log looks exactly like one that worked.
            repeat {
                let matches: [(CKRecord.ID, Result<CKRecord, any Error>)]
                let next: CKQueryOperation.Cursor?
                if let cursor {
                    (matches, next) = try await database.records(continuingMatchFrom: cursor,
                                                                 resultsLimit: Self.fetchPageSize)
                } else {
                    (matches, next) = try await database.records(matching: query,
                                                                 resultsLimit: Self.fetchPageSize)
                }
                out += matches.compactMap { _, result -> Event? in
                    guard case .success(let record) = result else { return nil }
                    return decode(record)
                }
                cursor = next
            } while cursor != nil && out.count < limit
            return (out, true)
        } catch {
            Log.cloud.error("Fetch of \(recordType, privacy: .public) failed after \(out.count, privacy: .public) record(s): \(String(describing: error), privacy: .public)")
            // Partial results are kept: half a restore is worth more than none, and the `false`
            // tells the push path to report `.failed` so iOS knows to try again.
            return (out, false)
        }
    }

    // MARK: - Full-media retrieval (BACKLOG 34.B1)

    /// What a downloaded full-resolution capture arrived as: which camera the record name
    /// carries (nil for the legacy "primary"/"secondary" fallbacks), and the CloudKit-managed
    /// temp file holding its content.
    struct FetchedMedia {
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
        let slots = manifest ?? ["front", "rear", "primary", "secondary"]
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

    /// Fetches this event's full-resolution capture records by their deterministic IDs and
    /// returns the assets found, deduplicated per slot with v2 preferred. Returns nil when
    /// the FETCH failed (network, account) as opposed to the records not existing — the UI
    /// must tell "iCloud holds nothing" apart from "iCloud was unreachable".
    ///
    /// This is the retrieval half of the Pro backup promise (34.B1): before it, full media
    /// reached iCloud and nothing — not restore, not the push path, not any UI — could ever
    /// bring it back; after a theft the owner held thumbnails of their own evidence.
    func fetchFullMedia(for eventID: UUID, manifest: [String]? = nil) async -> [FetchedMedia]? {
        await refreshAccountState()
        guard accountState.isReady, let database else { return nil }
        let names = Self.fullMediaRecordNames(for: eventID, manifest: manifest)
        do {
            let results = try await database.records(for: names.map { CKRecord.ID(recordName: $0) })
            var bySlot: [String: FetchedMedia] = [:]
            // Walk in candidate order (v2 first) so a record present in both generations is
            // taken once, from the newer one. A missing ID is an .unknownItem per-ID result,
            // not a thrown error — absence is an answer here, not a failure.
            for name in names {
                let slot = name.dropFirst("photo-".count).split(separator: "-").first.map(String.init) ?? name
                guard bySlot[slot] == nil,
                      case .success(let record)? = results[CKRecord.ID(recordName: name)],
                      let asset = record["media"] as? CKAsset, let url = asset.fileURL else { continue }
                bySlot[slot] = FetchedMedia(camera: Self.cameraFromPhotoRecordName(name), fileURL: url)
            }
            Log.cloud.info("Full-media fetch found \(bySlot.count, privacy: .public) capture(s)")
            return Array(bySlot.values)
        } catch {
            Log.cloud.error("Full-media fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Full-media retention (32.R2)

    /// The absolute protection floor: nothing newer than this many days can be deleted from
    /// iCloud in ANY retention mode, by anyone. Its job is anti-tamper, not tidiness: a
    /// PIN-holder must not be able to "free up iCloud space" to destroy the evidence of
    /// what they just did. Enforced structurally inside `purgeFullMedia` itself (eighth
    /// review, L1) — `purgeCutoff` clamps too, but the entry point no longer trusts its
    /// callers to have used it, so no caller — UI, automation, or future code — can pass
    /// a date that violates it.
    nonisolated static let retentionFloorDays = 30

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

    /// Deletes **full-resolution photo records** older than `cutoff` from the owner's
    /// private database — and nothing else, ever: meta facts, thumbnails, and arm/disarm
    /// audit records are kept in every retention mode. Old events are found by paging the
    /// (indexed) meta records oldest-first, and their photo records are addressed by their
    /// deterministic names — the same no-query, no-schema-dependency trick as retrieval
    /// (ADR 0002), so this touches nothing that could fail silently in Production.
    func purgeFullMedia(olderThan requestedCutoff: Date) async -> CloudPurgeResult {
        // The 30-day floor is a property of THIS function, not a caller convention (L1).
        let cutoff = Self.effectivePurgeCutoff(requested: requestedCutoff, now: Date())
        await refreshAccountState()
        guard accountState.isReady, let database else {
            return CloudPurgeResult(eventsExamined: 0, recordsDeleted: 0, failed: true)
        }
        let bgTask = beginBackgroundTask()
        defer { endBackgroundTask(bgTask) }

        var eventIDs: [UUID] = []
        var anyQueryFailed = false
        for type in [Self.metaRecordTypeV2, Self.metaRecordType] {
            let page = await eventIDsOfMetaRecords(olderThan: cutoff, type: type, database: database)
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
            let result = await delete(chunk, from: database)
            deleted += result.deleted
            deleteFailed = deleteFailed || result.failed
        }
        Log.cloud.info("Retention purge: \(deleted, privacy: .public) photo record(s) deleted across \(eventIDs.count, privacy: .public) event(s)")
        return CloudPurgeResult(eventsExamined: eventIDs.count, recordsDeleted: deleted,
                                failed: anyQueryFailed || deleteFailed)
    }

    /// Event IDs of one meta type's records created before `cutoff`, paged oldest-first so
    /// the walk stops at the cutoff instead of reading the whole database.
    private func eventIDsOfMetaRecords(olderThan cutoff: Date, type: String,
                                       database: CKDatabase) async -> (ids: [UUID], ok: Bool) {
        let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var ids: [UUID] = []
        var cursor: CKQueryOperation.Cursor?
        do {
            paging: repeat {
                let matches: [(CKRecord.ID, Result<CKRecord, any Error>)]
                let next: CKQueryOperation.Cursor?
                if let cursor {
                    (matches, next) = try await database.records(continuingMatchFrom: cursor,
                                                                 resultsLimit: Self.fetchPageSize)
                } else {
                    (matches, next) = try await database.records(matching: query,
                                                                 resultsLimit: Self.fetchPageSize)
                }
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
            return (ids, true)
        } catch {
            Log.cloud.error("Retention query of \(type, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return (ids, false)
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
                        from database: CKDatabase) async -> (deleted: Int, failed: Bool) {
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
        op.qualityOfService = .utility
        let results = PerRecordDeleteResults()
        op.perRecordDeleteBlock = { id, result in results.record(id, result) }
        do {
            return try await Self.awaitWithDeadline(
                Self.saveAttemptDeadline,
                onDeadline: { [weak op] in
                    Log.cloud.error("Purge delete stalled — cancelling the operation")
                    op?.cancel()
                },
                timeoutError: CKError(.networkFailure),
                start: { (resume: @escaping @Sendable (Result<(deleted: Int, failed: Bool), Error>) -> Void) in
                    op.modifyRecordsResultBlock = { result in
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
                    database.add(op)
                })
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
    }

    /// Awaits a callback-style operation with a deadline: `start` installs the completion,
    /// and if the deadline wins the race, `onDeadline` runs (cancelling the operation) and
    /// the wait ends with `timeoutError`. Exactly one resume wins; the loser's callback is
    /// a no-op. Unit-tested directly — including with a start that never calls back, which
    /// is the stall this exists to bound.
    nonisolated static func awaitWithDeadline<T: Sendable>(
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
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard latch.claim() else { return }
                onDeadline()
                cont.resume(throwing: timeoutError)
            }
        }
    }

    /// Saves records, retrying transient CloudKit failures with backoff. A single
    /// dropped push at trigger time can mean lost evidence (a stolen device never
    /// reaches `retryPendingSync`), so it's worth a few quick attempts — but bounded
    /// so it always finishes inside the background-task window rather than hanging.
    /// Each attempt builds a fresh operation (a CKOperation can only be added once),
    /// and each attempt races `saveAttemptDeadline` — a stalled operation is cancelled
    /// and reported as a network-class failure, so it feeds the same retry/escalation
    /// classification as a lost connection instead of hanging silently (F1).
    ///
    /// Success requires EVERY record's own per-record confirmation, not the
    /// operation-level result — see `saveError` for the incident that made this rule.
    private func save(_ records: [CKRecord]) async throws {
        guard let database else { throw CKError(.notAuthenticated) }
        let expected = records.map(\.recordID)
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                let op = CKModifyRecordsOperation(recordsToSave: records)
                op.qualityOfService = .userInitiated   // jump the queue
                op.savePolicy = .allKeys
                let results = PerRecordResults()
                op.perRecordSaveBlock = { id, result in results.record(id, result) }
                try await Self.awaitWithDeadline(
                    Self.saveAttemptDeadline,
                    onDeadline: { [weak op] in
                        Log.cloud.error("Save attempt stalled past \(Self.saveAttemptDeadline, privacy: .public)s — cancelling the operation")
                        op?.cancel()
                    },
                    timeoutError: CKError(.networkFailure),  // stall ≈ lost path: retry, count, escalate
                    start: { (resume: @escaping @Sendable (Result<Void, Error>) -> Void) in
                    // Fires after every perRecordSaveBlock — the final word on the operation.
                    op.modifyRecordsResultBlock = { result in
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
                    database.add(op)
                })
                return
            } catch {
                guard attempt < maxAttempts,
                      let delay = Self.retryDelay(for: error, attempt: attempt) else { throw error }
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

    /// Backoff for a transient CloudKit error: the server's suggested Retry-After
    /// if it gave one, else a capped exponential fallback. Returns nil for errors
    /// that aren't worth retrying (auth, quota, permission…).
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
        if let suggested = (ck as NSError).userInfo[CKErrorRetryAfterKey] as? TimeInterval {
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
    nonisolated static func subscriptionActionOnToggle(enabled: Bool) -> SubscriptionAction {
        enabled ? .ensure : .remove
    }

    /// The Settings toggle's direct line (H6, option A): applies the account-wide state
    /// immediately, from any device, in both directions — ON heals a deleted or failed-setup
    /// subscription with no re-arm anywhere; OFF removes it for every device. Returns whether
    /// the change landed so Settings can say so — a failed OFF has no backstop (arm and
    /// reconnect are create-only), so the owner must retry the flip.
    func setCrossDeviceAlerts(_ enabled: Bool) async -> Bool {
        await refreshAccountState()
        guard accountState.isReady, database != nil else { return false }
        switch Self.subscriptionActionOnToggle(enabled: enabled) {
        case .ensure:     return await ensureSubscription()
        case .remove:     return await removeSubscription()
        case .leaveAlone: return true
        }
    }

    @discardableResult
    private func ensureSubscription() async -> Bool {
        guard let database else { return false }
        let existing = (try? await database.allSubscriptions()) ?? []
        // The 1.0 subscription watched the plaintext meta type, which nothing writes to any
        // more. Left in place it would sit there firing on nothing, so it goes as soon as its
        // replacement is being established. Deleted only when actually present, to keep a
        // routine arm from spending a network round trip on a no-op every time.
        if existing.contains(where: { $0.subscriptionID == Self.legacySubscriptionID }) {
            await deleteSubscriptions([Self.legacySubscriptionID])
        }
        // Skip if it already exists.
        if existing.contains(where: { $0.subscriptionID == Self.subscriptionID }) {
            return true
        }
        let subscription = CKQuerySubscription(
            recordType: Self.metaRecordTypeV2,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation])

        let info = CKSubscription.NotificationInfo()
        info.title = "Malinois"
        info.alertBody = "Tamper detected on your device."
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        do {
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription])
            op.qualityOfService = .utility
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.modifySubscriptionsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                database.add(op)
            }
            return true
        } catch {
            Log.cloud.error("Subscription setup failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Removes the cross-device push subscription so every device stops being alerted
    /// (only the explicit toggle flip calls this — see `SubscriptionAction`).
    ///
    /// Deletes the 1.0 subscription alongside the current one: turning the option off has to
    /// silence *every* subscription this app has ever created, not just the newest, or a
    /// device that armed under 1.0 would keep pushing after the owner opted out.
    @discardableResult
    private func removeSubscription() async -> Bool {
        await deleteSubscriptions([Self.subscriptionID, Self.legacySubscriptionID])
    }

    /// Deletes subscriptions by ID. A "not found" is fine — it just means there was nothing
    /// to remove — which is why this is safe to call speculatively.
    @discardableResult
    private func deleteSubscriptions(_ ids: [String]) async -> Bool {
        guard let database else { return false }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let op = CKModifySubscriptionsOperation(subscriptionIDsToDelete: ids)
                op.qualityOfService = .utility
                op.modifySubscriptionsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                database.add(op)
            }
            return true
        } catch {
            Log.cloud.error("Subscription removal failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Utilities

    private func writeTemp(_ data: Data, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do { try data.write(to: url, options: .atomic); return url }
        catch { return nil }
    }

    /// Starts a background-task assertion whose expiration handler ends it, so
    /// iOS doesn't kill the app if the upload outlives our background time.
    /// Per-call `id` keeps concurrent uploads independent.
    /// Boxes the identifier so the expiration handler's `.invalid` write is visible to
    /// the caller's `defer` (F-22): with a plain value, the handler ended the task and
    /// the `defer` then ended it a *second* time on a stale copy.
    final class BGTaskBox { var id: UIBackgroundTaskIdentifier = .invalid }

    private func beginBackgroundTask() -> BGTaskBox {
        let box = BGTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "malinois-exfil") {
            // Time expired before the upload finished. The event keeps its .pending
            // state and is retried on the next sync — log it so the drop is visible.
            Log.cloud.error("Background time expired mid-upload; event stays pending and will retry")
            if box.id != .invalid {
                UIApplication.shared.endBackgroundTask(box.id)
                box.id = .invalid
            }
        }
        return box
    }

    private func endBackgroundTask(_ box: BGTaskBox) {
        guard box.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(box.id)
        box.id = .invalid
    }
}
