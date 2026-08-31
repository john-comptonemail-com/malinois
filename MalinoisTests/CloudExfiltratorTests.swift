//
//  CloudExfiltratorTests.swift
//  MalinoisTests
//
//  Pure-logic coverage for the exfiltration retry backoff. The network path itself
//  needs CloudKit, but `retryDelay` — which decides whether and how long to wait
//  before retrying a failed push — is a pure function of the error, and it guards
//  the "evidence must escape before power-off" race, so it's worth pinning.
//

import XCTest
import CloudKit
@testable import Malinois

final class CloudExfiltratorTests: XCTestCase {

    private func ckError(_ code: CKError.Code, retryAfter: TimeInterval? = nil) -> Error {
        var info: [String: Any] = [:]
        if let retryAfter { info[CKErrorRetryAfterKey] = retryAfter }
        return NSError(domain: CKError.errorDomain, code: code.rawValue, userInfo: info)
    }

    func testNonTransientErrorsAreNotRetried() {
        XCTAssertNil(CloudExfiltrator.retryDelay(for: ckError(.notAuthenticated), attempt: 1))
        XCTAssertNil(CloudExfiltrator.retryDelay(for: ckError(.quotaExceeded), attempt: 1))
        XCTAssertNil(CloudExfiltrator.retryDelay(for: ckError(.permissionFailure), attempt: 1))
        // A non-CloudKit error is never retried.
        XCTAssertNil(CloudExfiltrator.retryDelay(for: URLError(.badURL), attempt: 1))
    }

    func testTransientErrorsUseCappedExponentialBackoff() {
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: ckError(.networkUnavailable), attempt: 1), 0.5)
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: ckError(.networkFailure), attempt: 2), 1.0)
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: ckError(.serviceUnavailable), attempt: 3), 2.0)
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: ckError(.zoneBusy), attempt: 10), 4, "capped at 4s")
    }

    func testServerRetryAfterIsHonoredButCapped() {
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: ckError(.requestRateLimited, retryAfter: 2), attempt: 1), 2)
        // A large server hint must not push retries past the background-task window.
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: ckError(.requestRateLimited, retryAfter: 100), attempt: 1), 4)
    }

    /// Regression guard for the arm-time crash on the **simulator** (the test host): the
    /// `#if targetEnvironment(simulator)` guard means creating a CKContainer is never even
    /// attempted here, so `refreshAccountState()` degrades to a non-ready state (and flips
    /// `cloudUnavailable`) instead of raising the uncatchable entitlement exception. This
    /// does NOT exercise the *device* path — a signed device build without the entitlement
    /// (a free Apple Developer account) still crashes once; the persisted probe breadcrumb
    /// (M-01) is what makes that one crash a permanent local-only fallback, and it can only
    /// be verified on hardware.
    @MainActor
    func testRefreshAccountStateDegradesOnSimulator() async {
        let cloud = CloudExfiltrator()
        await cloud.refreshAccountState()
        XCTAssertFalse(cloud.accountState.isReady)
        XCTAssertTrue(cloud.cloudUnavailable, "the simulator must report cloud as unavailable, not ready")
    }

    /// F-10: a transient failure wrapped in a `.partialFailure` (how CKModifyRecordsOperation
    /// reports per-record problems) must be unwrapped and retried, not treated as permanent.
    func testPartialFailureUnwrapsToTransientRetry() {
        let inner = ckError(.networkUnavailable)
        let partial = NSError(domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue,
                              userInfo: [CKPartialErrorsByItemIDKey: [UUID(): inner]])
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: partial, attempt: 1), 0.5,
                       "the nested transient error drives the retry")
        // A partial failure wrapping a permanent error is still not retried.
        let permInner = ckError(.permissionFailure)
        let permPartial = NSError(domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue,
                                  userInfo: [CKPartialErrorsByItemIDKey: [UUID(): permInner]])
        XCTAssertNil(CloudExfiltrator.retryDelay(for: permPartial, attempt: 1))
    }

    // MARK: - Cloud input validation (34 review, 1.2)

    /// Mirrored input is data, not instructions: unknown state kinds are dropped (they used
    /// to render as "Signal loss"), and a nonsensical revision is ignored rather than
    /// steering the merge.
    func testCloudInputIsValidatedNotObeyed() {
        let state = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2,
                             recordID: CKRecord.ID(recordName: "state-v2-x"))
        state.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        state.encryptedValues["startDate"] = Date() as CKRecordValue
        state.encryptedValues["kind"] = "self-destructed" as CKRecordValue
        XCTAssertNil(CloudExfiltrator.stateEvent(from: state),
                     "an unknown state kind is dropped, never rendered")
        state.encryptedValues["kind"] = "disarmed" as CKRecordValue
        XCTAssertNotNil(CloudExfiltrator.stateEvent(from: state))

        let meta = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2,
                            recordID: CKRecord.ID(recordName: "meta-v2-x"))
        meta.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        meta.encryptedValues["startDate"] = Date() as CKRecordValue
        meta.encryptedValues["revision"] = -5 as CKRecordValue
        XCTAssertNil(CloudExfiltrator.event(from: meta)?.cloudRevision,
                     "a nonsensical revision must not steer the merge")
    }

    /// Fourth-pass R3-4, the clamp half: `startDate` was the one scalar the F6 suite
    /// missed. A future-dated value sorts ahead of first-hand evidence and, at the event
    /// cap, drives eviction — so it is believed at most a day past the record's own
    /// server creation stamp ("now" for a record that never got one). Clamped, not
    /// dropped: the event may be real and only its source clock wrong.
    func testDecodeClampsFutureStartDate() {
        let meta = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2,
                            recordID: CKRecord.ID(recordName: "meta-v2-future"))
        meta.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        meta.encryptedValues["startDate"] = Date().addingTimeInterval(10 * 86_400) as CKRecordValue
        let decoded = CloudExfiltrator.event(from: meta)
        XCTAssertNotNil(decoded, "a future-dated record is clamped, not dropped")
        XCTAssertLessThanOrEqual(decoded!.startDate, Date().addingTimeInterval(86_400 + 60),
                                 "evidence startDate is believed at most a day ahead")

        let state = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2,
                             recordID: CKRecord.ID(recordName: "state-v2-future"))
        state.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        state.encryptedValues["startDate"] = Date().addingTimeInterval(10 * 86_400) as CKRecordValue
        state.encryptedValues["kind"] = "armed" as CKRecordValue
        let decodedState = CloudExfiltrator.stateEvent(from: state)
        XCTAssertNotNil(decodedState)
        XCTAssertLessThanOrEqual(decodedState!.startDate, Date().addingTimeInterval(86_400 + 60),
                                 "state records take the same clamp")
    }

    /// A "thumbnail" the size of a photo is refused — the mirror fetch must stay small.
    func testOversizedThumbnailAssetIsRefused() throws {
        let big = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try Data(count: CloudExfiltrator.maxThumbnailBytes + 1).write(to: big)
        defer { try? FileManager.default.removeItem(at: big) }
        let meta = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2,
                            recordID: CKRecord.ID(recordName: "meta-v2-y"))
        meta.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        meta.encryptedValues["startDate"] = Date() as CKRecordValue
        meta["thumbnail"] = CKAsset(fileURL: big)
        XCTAssertNil(CloudExfiltrator.event(from: meta)?.thumbnailData)
    }

    // MARK: - Encrypted-data reset recognition (34.H13)

    /// A reset purges the zone; saves answer zoneNotFound/userDeletedZone — including
    /// nested inside a partialFailure. Anything else is not a reset.
    func testEncryptedDataResetIsRecognizedByItsCodes() {
        XCTAssertTrue(CloudExfiltrator.indicatesEncryptedDataReset(ckError(.zoneNotFound)))
        XCTAssertTrue(CloudExfiltrator.indicatesEncryptedDataReset(ckError(.userDeletedZone)))
        let nested = NSError(domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue,
                             userInfo: [CKPartialErrorsByItemIDKey: [UUID(): ckError(.zoneNotFound)]])
        XCTAssertTrue(CloudExfiltrator.indicatesEncryptedDataReset(nested))
        XCTAssertFalse(CloudExfiltrator.indicatesEncryptedDataReset(ckError(.quotaExceeded)))
        XCTAssertFalse(CloudExfiltrator.indicatesEncryptedDataReset(NSError(domain: "x", code: 1)))
    }

    // MARK: - Per-event upload serialization (1.2 coordinator / ADR 0003)

    /// The B2 residual: two writes for one event could both preflight before either landed,
    /// letting a stale earlier write finish last. The chain makes that impossible — a write
    /// starts only after the previous write for that event has FINISHED.
    @MainActor
    func testUploadsForOneEventRunStrictlyInOrder() async {
        let cloud = CloudExfiltrator()
        let id = UUID()
        var log: [Int] = []
        async let first: Void = cloud.enqueue(id) {
            log.append(1)
            try? await Task.sleep(nanoseconds: 150_000_000)
            log.append(2)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)   // let the first op begin
        async let second: Void = cloud.enqueue(id) { log.append(3) }
        _ = await (first, second)
        XCTAssertEqual(log, [1, 2, 3], "the second write waits for the first to FINISH, not just start")
    }

    /// Serialization is per event — one slow event must not stall another's evidence.
    @MainActor
    func testChainsForDifferentEventsStayConcurrent() async {
        let cloud = CloudExfiltrator()
        var log: [String] = []
        async let slow: Void = cloud.enqueue(UUID()) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            log.append("slow")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        async let fast: Void = cloud.enqueue(UUID()) { log.append("fast") }
        _ = await (slow, fast)
        XCTAssertEqual(log, ["fast", "slow"], "a different event's write does not queue behind it")
    }

    // MARK: - Cloud retention (32.R2)

    /// The 30-day protection floor is absolute: whatever age is requested, the cutoff can
    /// never reach into the last 30 days — a PIN-holder must not be able to "free up iCloud
    /// space" to destroy the evidence of what they just did.
    func testPurgeCutoffNeverViolatesTheProtectionFloor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let floor = now.addingTimeInterval(-30 * 86_400)
        XCTAssertLessThanOrEqual(CloudExfiltrator.purgeCutoff(monthsOld: 0, now: now), floor,
                                 "even a zero-month request is clamped to the floor")
        XCTAssertLessThanOrEqual(CloudExfiltrator.purgeCutoff(monthsOld: 1, now: now), floor)
        let yearAgo = CloudExfiltrator.purgeCutoff(monthsOld: 12, now: now)
        XCTAssertLessThan(yearAgo, now.addingTimeInterval(-300 * 86_400),
                          "a 12-month request reaches roughly a year back")
    }

    /// The purge derives event IDs from meta record names when the field is unreadable —
    /// both generations, garbage refused.
    func testEventIDRecoveryFromMetaRecordNames() {
        let id = UUID()
        XCTAssertEqual(CloudExfiltrator.eventID(fromMetaRecordName: "meta-v2-" + id.uuidString), id)
        XCTAssertEqual(CloudExfiltrator.eventID(fromMetaRecordName: "meta-" + id.uuidString), id)
        XCTAssertNil(CloudExfiltrator.eventID(fromMetaRecordName: "photo-front-v2-" + id.uuidString))
        XCTAssertNil(CloudExfiltrator.eventID(fromMetaRecordName: "meta-v2-not-a-uuid"))
    }

    // MARK: - Full-media retrieval (34.B1)

    /// Retrieval works by deterministic record ID — no query, no index, no schema change —
    /// so the candidate list must cover every name either generation ever wrote, v2 first.
    func testFullMediaCandidateNamesCoverBothGenerationsV2First() {
        let id = UUID()
        let names = CloudExfiltrator.fullMediaRecordNames(for: id)
        XCTAssertEqual(names.count, 8)
        XCTAssertEqual(names[0], "photo-front-v2-" + id.uuidString)
        XCTAssertTrue(names.contains("photo-rear-v2-" + id.uuidString))
        XCTAssertTrue(names.contains("photo-primary-" + id.uuidString),
                      "the 1.0 fallback name is still reachable")
        XCTAssertTrue(names.contains("photo-secondary-v2-" + id.uuidString))
        XCTAssertEqual(names.prefix(4).filter { $0.contains("-v2-") }.count, 4,
                       "v2 names come first so dedupe prefers the newer generation")
    }

    /// The camera token comes back out of the record name; the primary/secondary fallbacks
    /// name a slot, not a camera, and must not masquerade as one.
    func testCameraTokenExtractionFromPhotoRecordNames() {
        let id = UUID().uuidString
        XCTAssertEqual(CloudExfiltrator.cameraFromPhotoRecordName("photo-front-v2-" + id), "front")
        XCTAssertEqual(CloudExfiltrator.cameraFromPhotoRecordName("photo-rear-" + id), "rear")
        XCTAssertNil(CloudExfiltrator.cameraFromPhotoRecordName("photo-primary-v2-" + id))
        XCTAssertNil(CloudExfiltrator.cameraFromPhotoRecordName("meta-v2-" + id))
    }

    /// A downloaded asset carries no type field, so the kind is decided from its leading
    /// bytes: JPEG's FF D8 FF, or the "ftyp" box every QuickTime/MP4 container opens with.
    func testMediaKindIsSniffedFromLeadingBytes() {
        XCTAssertEqual(CloudExfiltrator.mediaKind(ofPrefix: [0xFF, 0xD8, 0xFF, 0xE0]), .jpeg)
        let mov: [UInt8] = [0x00, 0x00, 0x00, 0x14] + Array("ftypqt  ".utf8)
        XCTAssertEqual(CloudExfiltrator.mediaKind(ofPrefix: mov), .movie)
        XCTAssertNil(CloudExfiltrator.mediaKind(ofPrefix: [0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00]),
                     "an unknown payload is refused, never guessed")
        XCTAssertNil(CloudExfiltrator.mediaKind(ofPrefix: []))
    }

    // MARK: - Per-record save confirmation (ADR 0004)
    //
    // Regression coverage for the 2026-08-28 stranded-evidence incident: offline, a
    // CKModifyRecordsOperation carrying assets "finished" with no operation-level error
    // after its asset-token fetch failed — no per-record save ever ran, nothing reached
    // the server, and trusting the operation result marked unsent evidence `.synced`
    // (which also exempted it from every retry sweep). The operation itself cannot run
    // in the Simulator, so the rule is pinned as a pure function, per the house testing
    // rule for paths CloudKit owns.

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name) }

    /// THE incident shape: operation says success, no record was ever reported on.
    /// Under the old operation-level trust this was a "successful" save.
    func testOperationSuccessWithNoPerRecordResultsIsAFailure() {
        let id = recordID("meta-v2-incident")
        let error = CloudExfiltrator.saveError(operationError: nil,
                                               succeeded: [], failed: [:],
                                               expecting: [id])
        XCTAssertNotNil(error, "silence about a record must read as failure, not success")
    }

    /// The synthesized silence-failure must stay out of the interference class (a lying
    /// framework is not evidence of jamming — ADR 0001) and out of the in-save retry
    /// loop (the operation just lied once; the pending sweeps own the retry).
    func testSilenceFailureIsTerminalAndNeverInterference() throws {
        let error = try XCTUnwrap(CloudExfiltrator.saveError(operationError: nil,
                                                             succeeded: [], failed: [:],
                                                             expecting: [recordID("r")]))
        XCTAssertNil(CloudExfiltrator.retryDelay(for: error, attempt: 1))
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(error),
                       "a fabricated network class could sound the siren on nothing")
    }

    /// A reported per-record failure outranks the synthesized one — the real error
    /// carries the class the retry/interference logic needs.
    func testReportedPerRecordFailureIsSurfacedAsIs() throws {
        let id = recordID("photo-v2-a")
        let error = try XCTUnwrap(CloudExfiltrator.saveError(
            operationError: nil,
            succeeded: [], failed: [id: ckError(.networkUnavailable)],
            expecting: [id]))
        XCTAssertEqual((error as? CKError)?.code, .networkUnavailable)
        XCTAssertNotNil(CloudExfiltrator.retryDelay(for: error, attempt: 1),
                        "a real transient error keeps its in-save retries")
    }

    /// An operation-level error stands untouched — `.partialFailure` unwrapping and
    /// classification downstream already expect exactly that shape.
    func testOperationErrorWinsUnchanged() {
        let error = CloudExfiltrator.saveError(operationError: ckError(.networkFailure),
                                               succeeded: [], failed: [:],
                                               expecting: [recordID("r")])
        XCTAssertEqual((error as? CKError)?.code, .networkFailure)
    }

    /// Every record confirmed → success. One confirmed, one silent → failure: a
    /// multi-record save may not round up.
    func testAllRecordsMustBeIndividuallyConfirmed() {
        let meta = recordID("meta"), photo = recordID("photo")
        XCTAssertNil(CloudExfiltrator.saveError(operationError: nil,
                                                succeeded: [meta, photo], failed: [:],
                                                expecting: [meta, photo]))
        XCTAssertNotNil(CloudExfiltrator.saveError(operationError: nil,
                                                   succeeded: [meta], failed: [:],
                                                   expecting: [meta, photo]),
                        "one unconfirmed record fails the save")
    }

    // MARK: - Failure classification (32.R1 / ADR 0001)

    /// Only the network class — no path, a request that vanished — is evidence of
    /// interference. Everything Apple's servers ANSWER with is a refusal: a full quota, an
    /// auth lapse, a schema mismatch, an encrypted-key reset's zoneNotFound (34.H13). The
    /// blackout siren keys on this, so a full iCloud must never sound it.
    func testOnlyNetworkClassFailuresSuggestInterference() {
        XCTAssertTrue(CloudExfiltrator.failureSuggestsInterference(ckError(.networkUnavailable)))
        XCTAssertTrue(CloudExfiltrator.failureSuggestsInterference(ckError(.networkFailure)))
        XCTAssertTrue(CloudExfiltrator.failureSuggestsInterference(ckError(.serverResponseLost)))
        XCTAssertTrue(CloudExfiltrator.failureSuggestsInterference(URLError(.timedOut)))
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(ckError(.quotaExceeded)),
                       "a full iCloud is an answer, not a jam")
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(ckError(.notAuthenticated)))
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(ckError(.zoneNotFound)),
                       "an encrypted-key reset must not sound the siren (34.H13)")
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(ckError(.serviceUnavailable)),
                       "an Apple outage answered; it is not interference")
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(NSError(domain: "Other", code: 1)),
                       "unknown errors are not evidence")
    }

    /// The real operation reports per-record problems as `.partialFailure` — the class must
    /// come from the nested error, exactly as `retryDelay` already unwraps it.
    func testPartialFailureClassifiesByItsNestedError() {
        let network = NSError(domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue,
                              userInfo: [CKPartialErrorsByItemIDKey: [UUID(): ckError(.networkFailure)]])
        XCTAssertTrue(CloudExfiltrator.failureSuggestsInterference(network))
        let quota = NSError(domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue,
                            userInfo: [CKPartialErrorsByItemIDKey: [UUID(): ckError(.quotaExceeded)]])
        XCTAssertFalse(CloudExfiltrator.failureSuggestsInterference(quota))
    }

    /// F-05: a stale/transient account state must not silently disable exfiltration.
    /// Only a *definitive* no (no account / restricted) aborts a push; everything else —
    /// including a transient `.couldNotDetermine` → `.error` — is worth attempting.
    func testAccountStateCanAttempt() {
        XCTAssertTrue(CloudExfiltrator.AccountState.available.canAttempt)
        XCTAssertTrue(CloudExfiltrator.AccountState.unknown.canAttempt)
        XCTAssertTrue(CloudExfiltrator.AccountState.error("could not determine").canAttempt,
                      "a transient error is optimistic — let CloudKit be the judge")
        XCTAssertFalse(CloudExfiltrator.AccountState.noAccount.canAttempt)
        XCTAssertFalse(CloudExfiltrator.AccountState.restricted.canAttempt)
    }

    // MARK: - Reading records back (BACKLOG 9b)
    //
    // The fetch path itself cannot run here — CloudKit is unavailable in the Simulator — but
    // `CKRecord(recordType:)` constructs fine without a container, so the decoder can be
    // covered against real records. That matters: decoding is the one place in this feature
    // where a mistake silently corrupts the evidence log.

    /// Builds a record shaped exactly as the **1.0 schema** stored one: custom fields in the
    /// clear, on the pre-migration record type. These are no longer written, but they are
    /// still read (BACKLOG 19), and the owner has real evidence in this shape.
    private func metaRecord(id: UUID = UUID(),
                            start: Date = Date(timeIntervalSince1970: 1_700_000_000),
                            end: Date? = nil,
                            sensors: String = "motion,touch",
                            device: String = "John's iPhone",
                            ownerAttributed: Int? = nil,
                            metadataJSON: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudExfiltrator.metaRecordType,
                              recordID: CKRecord.ID(recordName: "meta-" + id.uuidString))
        record["eventID"] = id.uuidString as CKRecordValue
        record["startDate"] = start as CKRecordValue
        record["endDate"] = (end ?? start.addingTimeInterval(3)) as CKRecordValue
        record["triggeredSensors"] = sensors as CKRecordValue
        record["deviceName"] = device as CKRecordValue
        if let ownerAttributed { record["ownerAttributed"] = ownerAttributed as CKRecordValue }
        if let metadataJSON { record["metadataJSON"] = metadataJSON as CKRecordValue }
        return record
    }

    func testDecodesAMetaRecordIntoAMirroredEvent() {
        let id = UUID()
        let record = metaRecord(id: id, ownerAttributed: 1)
        let event = CloudExfiltrator.event(from: record)

        XCTAssertEqual(event?.id, id, "identity must survive — it is what dedupes the merge")
        XCTAssertEqual(event?.triggeredSensors, [.motion, .touch])
        XCTAssertEqual(event?.ownerAttributed, true)
        XCTAssertEqual(event?.sourceDevice, "John's iPhone")
        XCTAssertTrue(event?.isMirrored == true, "a fetched copy is never first-hand evidence")
        XCTAssertEqual(event?.cloudSyncState, .synced, "it came from the cloud by definition")
    }

    /// The safety property that keeps a mirror from showing a broken image: the full capture
    /// lives in a separate record that a mirror fetch deliberately does not pull, so naming a
    /// local file would point at nothing. EventDetailView already renders the absent case.
    func testDecodedEventNamesNoLocalMediaFile() {
        let event = CloudExfiltrator.event(from: metaRecord())
        XCTAssertNil(event?.mediaFilename, "the media file is not on this device")
        XCTAssertNil(event?.secondaryMediaFilename)
    }

    /// A record missing an identifying field yields nil rather than a half-built Event — a
    /// partial record in the evidence log is worse than no record.
    func testUnusableRecordsDecodeToNil() {
        let noID = metaRecord()
        noID["eventID"] = nil
        XCTAssertNil(CloudExfiltrator.event(from: noID), "no id means nothing can dedupe it")

        let badID = metaRecord()
        badID["eventID"] = "not-a-uuid" as CKRecordValue
        XCTAssertNil(CloudExfiltrator.event(from: badID))

        let noStart = metaRecord()
        noStart["startDate"] = nil
        XCTAssertNil(CloudExfiltrator.event(from: noStart), "no timestamp means nothing to show")
    }

    /// SensorType is a closed enum, so an older build merging from a newer one cannot
    /// represent a sensor it has never heard of. Dropping the unknown one loses a detail;
    /// the alternative — failing the whole record — would lose the evidence.
    func testUnknownSensorRawValuesAreDroppedNotFatal() {
        let event = CloudExfiltrator.event(from: metaRecord(sensors: "motion,teleportation,touch"))
        XCTAssertEqual(event?.triggeredSensors, [.motion, .touch],
                       "known sensors survive an unknown one alongside them")
        XCTAssertNotNil(CloudExfiltrator.event(from: metaRecord(sensors: "")),
                        "even a record with no decodable sensors is still a timestamped event")
    }

    /// `interrupted` and `capturedOffline` live only inside the JSON blob — they were never
    /// promoted to top-level record fields, so losing them here would silently drop the
    /// "Monitoring interrupted" marker, which is the Guided-Access-kill signal.
    func testRecoversInterruptedAndOfflineFlagsFromTheJSONBlob() {
        let json = #"{"interrupted":true,"capturedOffline":true}"#
        let event = CloudExfiltrator.event(from: metaRecord(metadataJSON: json))
        XCTAssertEqual(event?.interrupted, true)
        XCTAssertEqual(event?.capturedOffline, true)

        let plain = CloudExfiltrator.event(from: metaRecord())
        XCTAssertNil(plain?.interrupted, "absent stays absent rather than defaulting to false")
    }

    // MARK: - Arm/disarm audit records (BACKLOG 8)

    private func stateRecord(id: UUID = UUID(),
                             kind: String? = "disarmed",
                             start: Date = Date(timeIntervalSince1970: 1_700_000_000),
                             device: String = "John's iPhone") -> CKRecord {
        let record = CKRecord(recordType: CloudExfiltrator.stateRecordType,
                              recordID: CKRecord.ID(recordName: "state-" + id.uuidString))
        record["eventID"] = id.uuidString as CKRecordValue
        if let kind { record["kind"] = kind as CKRecordValue }
        record["startDate"] = start as CKRecordValue
        record["deviceName"] = device as CKRecordValue
        return record
    }

    /// Regression, and the reason this decoder exists at all: state records were being pushed
    /// and never read back, which left the arm/disarm audit trail write-only — the exact flaw
    /// the read path was built to fix, on the one record type whose entire purpose is
    /// surviving an attacker who deletes the app and takes the local log with it.
    func testDecodesAnArmDisarmRecord() {
        let id = UUID()
        let event = CloudExfiltrator.stateEvent(from: stateRecord(id: id, kind: "armed"))

        XCTAssertEqual(event?.id, id)
        XCTAssertEqual(event?.stateChange, "armed")
        XCTAssertTrue(event?.isStateChange == true,
                      "it must read as a state change, not as a tamper — the log counts them differently")
        XCTAssertEqual(event?.sourceDevice, "John's iPhone")
        XCTAssertTrue(event?.triggeredSensors.isEmpty == true, "an arm/disarm has no sensors")
        XCTAssertNil(event?.mediaFilename, "and no media")
        XCTAssertEqual(event?.cloudSyncState, .synced)
    }

    func testStateRecordWithoutAKindDecodesToNil() {
        XCTAssertNil(CloudExfiltrator.stateEvent(from: stateRecord(kind: nil)),
                     "without a kind there is nothing to say happened")
        let noStart = stateRecord()
        noStart["startDate"] = nil
        XCTAssertNil(CloudExfiltrator.stateEvent(from: noStart),
                     "an audit record with no timestamp proves nothing")
    }

    /// The two decoders must not be interchangeable. Feeding one the other's record has to
    /// fail cleanly rather than produce a half-built event — they are selected by record type
    /// at the call site, and a mix-up there should surface as nothing rather than as garbage.
    func testTheTwoDecodersRejectEachOthersRecords() {
        XCTAssertNil(CloudExfiltrator.stateEvent(from: metaRecord()),
                     "a tamper record has no `kind`")
        let decodedAsTamper = CloudExfiltrator.event(from: stateRecord())
        XCTAssertTrue(decodedAsTamper?.triggeredSensors.isEmpty ?? true)
        XCTAssertNil(decodedAsTamper?.stateChange,
                     "the tamper decoder never sets stateChange, so a state record decoded by it would silently lose what it was")
    }

    // MARK: - Encrypted metadata (BACKLOG 19)
    //
    // The migration's whole claim is that the metadata around the evidence — which sensors
    // tripped, when, on which device — is encrypted toward the owner's keys rather than
    // Apple's. That claim is only worth as much as the check that no field slipped through in
    // the clear, so these tests build the exact records that ship and read both namespaces.

    private func sampleEvent(id: UUID = UUID(),
                             start: Date = Date(timeIntervalSince1970: 1_700_000_000),
                             sensors: [SensorType] = [.motion, .touch],
                             ownerAttributed: Bool? = nil,
                             capturedOffline: Bool? = nil,
                             interrupted: Bool? = nil) -> Event {
        Event(id: id,
              startDate: start,
              endDate: start.addingTimeInterval(3),
              triggeredSensors: sensors,
              capturedOffline: capturedOffline,
              ownerAttributed: ownerAttributed,
              interrupted: interrupted)
    }

    /// A file on disk for the asset fields. `CKAsset` construction needs a URL, and a real
    /// one keeps the test honest about what ships.
    private func tempFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The core property of the migration: nothing identifying is readable through the plain
    /// subscript. If CloudKit ever surfaced an encrypted value there too, the fallback in
    /// `customField` would still decode fine and this claim would be quietly false — so the
    /// assertion is on the *absence* from the clear namespace, not just the presence in the
    /// encrypted one.
    func testEveryCustomFieldOnATamperRecordIsEncrypted() throws {
        let event = sampleEvent(ownerAttributed: true, interrupted: true)
        let record = CloudExfiltrator.makeMetaRecord(event,
                                                     deviceName: "John's iPhone",
                                                     thumbnailURL: try tempFile("thumb.jpg"))

        // `revision` is on this list because it was added later, and a field added later is
        // exactly the one that slips past a guard written earlier.
        for key in ["eventID", "startDate", "endDate", "duration", "triggeredSensors",
                    "deviceName", "ownerAttributed", "metadataJSON", "revision"] {
            XCTAssertNil(record[key], "\(key) must not be readable in the clear")
            XCTAssertNotNil(record.encryptedValues[key], "\(key) must be present, encrypted")
        }
    }

    /// The one field that deliberately stays in the clear namespace, and the reason it is
    /// safe: a CKAsset cannot be an encrypted value, and in a private database its *content*
    /// is already encrypted toward the owner's keys. Pinning it here so a later "encrypt
    /// everything" pass doesn't silently break asset upload trying to fix a non-problem.
    func testTheThumbnailAssetStaysInThePlainNamespace() throws {
        let record = CloudExfiltrator.makeMetaRecord(sampleEvent(),
                                                     deviceName: "John's iPhone",
                                                     thumbnailURL: try tempFile("thumb.jpg"))
        XCTAssertTrue(record["thumbnail"] is CKAsset, "the asset rides the record in the clear")
        XCTAssertNil(record.encryptedValues["thumbnail"], "a CKAsset cannot be an encrypted value")
    }

    /// Write half and read half, against each other. This is the test the project learned to
    /// write the hard way: the arm/disarm trail once wrote to one record type and read from
    /// another, so every field landed in iCloud and none of it ever came back.
    func testAMetaRecordRoundTripsThroughItsOwnDecoder() throws {
        let id = UUID()
        let original = sampleEvent(id: id,
                                   sensors: [.motion, .power],
                                   ownerAttributed: true,
                                   capturedOffline: true,
                                   interrupted: true)
        let decoded = CloudExfiltrator.event(
            from: CloudExfiltrator.makeMetaRecord(original,
                                                  deviceName: "John's iPhone",
                                                  thumbnailURL: nil))

        XCTAssertEqual(decoded?.id, id)
        XCTAssertEqual(decoded?.startDate, original.startDate)
        XCTAssertEqual(decoded?.endDate, original.endDate)
        XCTAssertEqual(decoded?.triggeredSensors, [.motion, .power])
        XCTAssertEqual(decoded?.ownerAttributed, true)
        XCTAssertEqual(decoded?.interrupted, true, "the JSON blob survives encryption")
        XCTAssertEqual(decoded?.capturedOffline, true)
        XCTAssertEqual(decoded?.sourceDevice, "John's iPhone")
        XCTAssertEqual(decoded?.cloudSyncState, .synced)
    }

    /// Same round trip for the audit trail — the record type whose entire job is surviving an
    /// attacker who deletes the app, and the one that has already shipped write-only once.
    func testAStateRecordIsEncryptedAndRoundTrips() {
        let id = UUID()
        let event = Event(id: id,
                          startDate: Date(timeIntervalSince1970: 1_700_000_000),
                          endDate: Date(timeIntervalSince1970: 1_700_000_000),
                          triggeredSensors: [],
                          stateChange: "disarmed")
        let record = CloudExfiltrator.makeStateRecord(event, kind: "disarmed", deviceName: "John's iPhone")

        for key in ["eventID", "kind", "startDate", "deviceName"] {
            XCTAssertNil(record[key], "\(key) must not be readable in the clear")
        }
        let decoded = CloudExfiltrator.stateEvent(from: record)
        XCTAssertEqual(decoded?.id, id)
        XCTAssertEqual(decoded?.stateChange, "disarmed")
        XCTAssertEqual(decoded?.sourceDevice, "John's iPhone")
    }

    func testAPhotoRecordEncryptsItsMetadataButNotTheMedia() throws {
        let record = CloudExfiltrator.makePhotoRecord(sampleEvent(),
                                                      mediaURL: try tempFile("full.jpg"),
                                                      suffix: "photo-front")
        XCTAssertNil(record["eventID"], "even the id it belongs to is metadata")
        XCTAssertNil(record["capturedAt"])
        XCTAssertNotNil(record.encryptedValues["eventID"])
        XCTAssertTrue(record["media"] is CKAsset)
    }

    /// A `CKRecord.ID` is unique per *zone*, not per record type. Reusing a 1.0 record name
    /// for a V2 record would collide with whatever is already sitting there for any event the
    /// owner pushed before upgrading — and re-pushes are routine, so the collision would fail
    /// the save permanently and silently, on exactly the evidence that already exists.
    func testTheTwoGenerationsCannotShareARecordName() throws {
        let id = UUID()
        let event = sampleEvent(id: id)
        let v2Names = [
            CloudExfiltrator.makeMetaRecord(event, deviceName: "d", thumbnailURL: nil).recordID.recordName,
            CloudExfiltrator.makeStateRecord(event, kind: "armed", deviceName: "d").recordID.recordName,
            CloudExfiltrator.makePhotoRecord(event, mediaURL: try tempFile("m.jpg"), suffix: "photo-front").recordID.recordName
        ]
        let legacyNames = ["meta-" + id.uuidString,
                           "state-" + id.uuidString,
                           "photo-front-" + id.uuidString]
        for name in v2Names {
            XCTAssertFalse(legacyNames.contains(name), "\(name) collides with a 1.0 record name")
        }
        XCTAssertEqual(Set(v2Names).count, 3, "and the three V2 records must not collide with each other")
    }

    /// Guards the typo that would make the "new" types silently be the old ones — which would
    /// deploy as an attempt to add encrypted fields to an existing type, and fail.
    func testTheV2TypesAreDistinctFromTheOnesTheyReplace() {
        XCTAssertNotEqual(CloudExfiltrator.metaRecordTypeV2, CloudExfiltrator.metaRecordType)
        XCTAssertNotEqual(CloudExfiltrator.photoRecordTypeV2, CloudExfiltrator.photoRecordType)
        XCTAssertNotEqual(CloudExfiltrator.stateRecordTypeV2, CloudExfiltrator.stateRecordType)
    }

    /// The migration must not orphan what is already in the owner's database: 1.0-shaped
    /// plaintext records still have to decode, through the same decoder, unchanged.
    func testPlaintextRecordsFromTheOldSchemaStillDecode() {
        let id = UUID()
        let event = CloudExfiltrator.event(from: metaRecord(id: id, ownerAttributed: 1))
        XCTAssertEqual(event?.id, id, "evidence pushed before the migration is still readable")
        XCTAssertEqual(event?.ownerAttributed, true)
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: stateRecord(kind: "armed"))?.stateChange, "armed")
    }

    /// The fetch queries both generations, so one event can come back twice — once as the 1.0
    /// record and once as the V2 record a later build re-pushed. The merge dedupes on the
    /// event id, which is why reading both is safe rather than duplicate-producing.
    func testAnEventPresentInBothGenerationsMergesOnce() {
        let id = UUID()
        let fromLegacy = CloudExfiltrator.event(from: metaRecord(id: id))
        let fromV2 = CloudExfiltrator.event(
            from: CloudExfiltrator.makeMetaRecord(sampleEvent(id: id),
                                                  deviceName: "John's iPhone",
                                                  thumbnailURL: nil))
        let merged = EventStore.merged(local: [], incoming: [fromV2, fromLegacy].compactMap { $0 })

        XCTAssertEqual(merged.count, 1, "the same event in two schemas is still one event")
        XCTAssertEqual(merged.first?.id, id)
    }

    // MARK: - The alert subscription is account state (H6, option A)

    /// Pinned live by the build-24 pair: the personal phone received alerts from a
    /// subscription only the test device ever created — CloudKit pushes a subscription to
    /// EVERY device on the account, which is also why per-device subscription IDs were
    /// rejected (N subscriptions = N duplicate pushes to everyone, not per-device receipt).
    /// So an arm may HEAL the subscription but never delete it: arming with a local toggle
    /// off used to remove it for the whole account and stay broken until that device
    /// re-armed. Only the explicit Settings flip removes — and it works both directions
    /// immediately, from any device.
    func testArmingNeverDeletesTheAccountsAlertSubscription() {
        XCTAssertEqual(CloudExfiltrator.subscriptionActionOnArm(notifyWanted: true), .ensure,
                       "arm heals a deleted or failed-setup subscription")
        XCTAssertEqual(CloudExfiltrator.subscriptionActionOnArm(notifyWanted: false), .leaveAlone,
                       "a local toggle must not speak for the whole account at arm time")
        XCTAssertEqual(CloudExfiltrator.subscriptionActionOnToggle(enabled: false), .remove,
                       "the explicit flip is the one remover")
        XCTAssertEqual(CloudExfiltrator.subscriptionActionOnToggle(enabled: true), .ensure)
    }

    // MARK: - The count freezer (found live 2026-08-30, build-25 pair)

    /// The coalesced flood count is the ONE field whose value grows WITHIN a revision, so a
    /// mirror that first fetched rev 2 at count 1 could never be repaired — every later
    /// fetch carried the same revision, failed strictly-greater, and the personal device
    /// showed a plain row while the capturing device said "sustained ×14" (34.H8's
    /// thumbnail freeze, resurfaced through count progress). Equal-revision mirrors may now
    /// be superseded by a strictly HIGHER count — monotonic, so replays and stale
    /// duplicates still lose, and first-hand evidence stays untouchable whatever a cloud
    /// copy claims.
    func testEqualRevisionMirrorsRepairOnAHigherSustainedCount() {
        func mirror(rev: Int, count: Int?) -> Event {
            Event(startDate: Date(timeIntervalSince1970: 1_000),
                  endDate: Date(timeIntervalSince1970: 1_060),
                  triggeredSensors: [.motion], sustainedCount: count,
                  sourceDevice: "Desk iPhone", cloudRevision: rev)
        }
        XCTAssertTrue(EventStore.supersedes(incoming: mirror(rev: 2, count: 14),
                                            existing: mirror(rev: 2, count: 1)),
                      "the frozen mirror must accept the true count")
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(rev: 2, count: 14),
                                             existing: mirror(rev: 2, count: 14)),
                       "an identical replay changes nothing")
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(rev: 2, count: 1),
                                             existing: mirror(rev: 2, count: 14)),
                       "a stale duplicate must not walk the count backward")
        XCTAssertTrue(EventStore.supersedes(incoming: mirror(rev: 3, count: 1),
                                            existing: mirror(rev: 2, count: 14)),
                      "a strictly higher revision still outranks, whatever its count")
        var firstHand = mirror(rev: 2, count: 1)
        firstHand.sourceDevice = nil
        XCTAssertFalse(EventStore.supersedes(incoming: mirror(rev: 2, count: 14),
                                             existing: firstHand),
                       "first-hand evidence is never displaced, whatever a cloud copy claims")
    }

    // MARK: - Payload v2: mirrors keep what the capturing device knew (34's metadataJSON item)

    /// The fields a mirror used to LOSE — sustained-flood count, camera identities, clip
    /// durations, the pre-upload discard marker, and the media manifest — now ride the
    /// encrypted JSON payload and decode back. A cross-device copy of "sustained ×14, both
    /// cameras, 40 s clip" must not read as a bare tamper on the other phone.
    func testMirrorKeepsSustainedCountCamerasDurationsAndManifest() {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion],
                          mediaFilename: "a.mov", secondaryMediaFilename: "b.mov",
                          primaryCamera: "front", primaryDuration: 40,
                          secondaryCamera: "rear", secondaryDuration: 39.5,
                          sustainedCount: 14)
        event.mediaDiscarded = true
        let mirror = CloudExfiltrator.event(
            from: CloudExfiltrator.makeMetaRecord(event, deviceName: "Desk iPhone",
                                                  thumbnailURL: nil))
        XCTAssertEqual(mirror?.sustainedCount, 14, "the flood count must survive the mirror")
        XCTAssertEqual(mirror?.primaryCamera, "front")
        XCTAssertEqual(mirror?.primaryDuration, 40)
        XCTAssertEqual(mirror?.secondaryCamera, "rear")
        XCTAssertEqual(mirror?.secondaryDuration, 39.5)
        XCTAssertEqual(mirror?.mediaDiscarded, true,
                       "a pre-upload loss must not read as intact on the other device")
        XCTAssertEqual(mirror?.cloudMediaManifest, ["front", "rear"],
                       "retrieval fetches exactly what the capturing device says exists (B1)")
        XCTAssertNil(mirror?.mediaFilename, "the file itself is still not on this device")
    }

    /// Manifest tokens feed record-name construction on the retrieval side, so they are
    /// allow-listed on decode — a hostile or corrupt record's tokens are dropped, never
    /// obeyed (the validation-caps rule). Bounds on the numeric fields fail the same
    /// direction: a nonsensical value is dropped, not displayed.
    func testHostileManifestTokensAndNonsenseValuesAreDroppedOnDecode() {
        let record = CloudExfiltrator.makeMetaRecord(sampleEvent(id: UUID()),
                                                     deviceName: "x", thumbnailURL: nil)
        record.encryptedValues["metadataJSON"] = """
        {"media": ["front", "../evil", 7, "rear"], "sustainedCount": -4, \
        "primaryCamera": "photo-injection", "primaryDuration": -1}
        """ as CKRecordValue
        let mirror = CloudExfiltrator.event(from: record)
        XCTAssertEqual(mirror?.cloudMediaManifest, ["front", "rear"],
                       "unknown tokens are dropped; known ones survive")
        XCTAssertNil(mirror?.sustainedCount, "a negative count is nonsense, not data")
        XCTAssertNil(mirror?.primaryCamera, "camera names outside front/rear are dropped")
        XCTAssertNil(mirror?.primaryDuration, "a negative duration is dropped")
    }

    /// A pre-manifest (v1) payload decodes exactly as before: every new field reads nil,
    /// and retrieval falls back to the blind four-slot probe.
    func testV1PayloadsDecodeWithNilManifest() {
        let mirror = CloudExfiltrator.event(from: metaRecord(id: UUID()))
        XCTAssertNotNil(mirror)
        XCTAssertNil(mirror?.cloudMediaManifest)
        XCTAssertNil(mirror?.sustainedCount)
    }

    /// The manifest narrows retrieval to the records that exist; nil keeps the blind probe
    /// (old records), and both generations' names are still produced for each slot.
    func testFullMediaRecordNamesHonorTheManifest() {
        let id = UUID()
        let manifested = CloudExfiltrator.fullMediaRecordNames(for: id, manifest: ["front"])
        XCTAssertEqual(manifested, ["photo-front-v2-" + id.uuidString,
                                    "photo-front-" + id.uuidString])
        XCTAssertEqual(CloudExfiltrator.fullMediaRecordNames(for: id).count, 8,
                       "no manifest — the blind probe still tries all four slots, both generations")
    }

    // MARK: - Write ordering and mirror updates (review findings 4 and 5)

    /// One event is written to iCloud more than once — a sparse "fact" the instant a tripwire
    /// fires, then the full record once capture finishes — and both use the same deterministic
    /// record name with `.allKeys`, which overwrites server values without comparing change
    /// tags. So a fact that stalls and retries can complete *after* the rich record and replace
    /// a thumbnail and final duration with nothing.
    func testAStaleWriteIsRefusedButARetryOfTheSameOneIsNot() {
        XCTAssertTrue(CloudExfiltrator.mayWrite(revision: 1, alreadySubmitted: nil),
                      "first write of an event")
        XCTAssertTrue(CloudExfiltrator.mayWrite(revision: 2, alreadySubmitted: 1),
                      "the richer record supersedes the fact")
        XCTAssertTrue(CloudExfiltrator.mayWrite(revision: 2, alreadySubmitted: 2),
                      "an ordinary retry of the same payload must still go through")
        XCTAssertFalse(CloudExfiltrator.mayWrite(revision: 1, alreadySubmitted: 2),
                       "the stalled fact must not land on top of the captured record")
    }

    /// The revision is derived from the event so it cannot disagree with what is being written.
    func testRevisionRisesAsTheEventBecomesRicher() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fact = Event(startDate: start, endDate: start, triggeredSensors: [.motion])
        let captured = Event(startDate: start, endDate: start.addingTimeInterval(5),
                             triggeredSensors: [.motion], thumbnailData: Data([0xFF]))
        let attributed = Event(startDate: start, endDate: start.addingTimeInterval(5),
                               triggeredSensors: [.motion], thumbnailData: Data([0xFF]),
                               ownerAttributed: true)
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: fact), 1)
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: captured), 2)
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: attributed), 3)
    }

    /// 34.B2: `respond()` creates the fact with `endDate: Date()` against a `startDate` taken
    /// from an earlier sensor sample, so `endDate > startDate` from birth. Deriving the
    /// capture stage from `endDate` made that fact revision 2 — equal to the rich record —
    /// so the stale-overwrite guard never applied on the primary path. The stage must be
    /// keyed on evidence actually attached, never on time having passed.
    func testTheRealFactIsRevisionOneDespiteItsLaterEndDate() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fact = Event(startDate: start, endDate: start.addingTimeInterval(0.4),
                         triggeredSensors: [.motion])
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: fact), 1,
                       "a pre-capture fact carries no evidence and must be revision 1, whatever its endDate")
    }

    /// F5: the subscription fires on record *creation*, and the fast fact is what creates the
    /// record — so another device fetched a thumbnail-less stub and the merge, which rejected
    /// any id it already held, could never repair it. A mirror may now be superseded by a later
    /// revision of itself, while first-hand evidence stays untouchable.
    func testAMirroredCopyAcceptsALaterRevisionOfItself() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func mirror(_ revision: Int, thumb: Data?) -> Event {
            Event(id: id, startDate: start, endDate: start, triggeredSensors: [.motion],
                  thumbnailData: thumb, sourceDevice: "John's iPhone", cloudRevision: revision)
        }
        let stub = mirror(1, thumb: nil)
        let rich = mirror(2, thumb: Data([0xFF]))

        XCTAssertEqual(EventStore.merged(local: [stub], incoming: [rich]).first?.cloudRevision, 2,
                       "the enriched copy replaces the stub")
        XCTAssertEqual(EventStore.merged(local: [rich], incoming: [stub]).first?.cloudRevision, 2,
                       "and an older revision arriving later does not undo it")
        XCTAssertEqual(EventStore.merged(local: [stub], incoming: [rich]).count, 1)
    }

    /// The rule the merge exists to protect, unchanged: a copy from the cloud never displaces
    /// this device's own record of what it saw, whatever revision it claims.
    func testFirstHandEvidenceIsNeverReplacedByAMirror() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let firstHand = Event(id: id, startDate: start, endDate: start,
                              triggeredSensors: [.motion], mediaFilename: "local.jpg")
        let mirror = Event(id: id, startDate: start, endDate: start, triggeredSensors: [.motion],
                           sourceDevice: "Another iPhone", cloudRevision: 99)

        let out = EventStore.merged(local: [firstHand], incoming: [mirror])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.mediaFilename, "local.jpg", "the local capture stands")
        XCTAssertFalse(out.first?.isMirrored ?? true)
    }

    // MARK: - The save-attempt deadline (sixth-review F1)

    /// The stall this bound exists for: a CloudKit operation that never calls back. The
    /// deadline must cancel it (onDeadline) and resolve exactly once with the timeout error.
    func testAwaitWithDeadlineTimesOutAStalledOperation() async {
        let cancelled = expectation(description: "onDeadline ran (the operation was cancelled)")
        do {
            let _: Void = try await CloudExfiltrator.awaitWithDeadline(
                0.2,
                onDeadline: { cancelled.fulfill() },
                timeoutError: CKError(.networkFailure),
                start: { _ in /* never resumes - the stall */ })
            XCTFail("a stalled operation must not succeed")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure,
                           "a stall reports as a network-class failure so retry/escalation classify it")
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    /// A healthy fast result wins the race; the late deadline must neither cancel nor
    /// double-resume (the latch's whole job - a double resume would crash the continuation).
    func testAwaitWithDeadlineFastResultWinsAndDeadlineStaysQuiet() async throws {
        let cancelled = expectation(description: "onDeadline must NOT run after a fast result")
        cancelled.isInverted = true
        let value: Int = try await CloudExfiltrator.awaitWithDeadline(
            0.15,
            onDeadline: { cancelled.fulfill() },
            timeoutError: CKError(.networkFailure),
            start: { resume in resume(.success(7)) })
        XCTAssertEqual(value, 7)
        await fulfillment(of: [cancelled], timeout: 0.5)   // waits past the deadline: no late fire
    }

    /// A real CloudKit failure propagates unchanged - the deadline only replaces silence.
    func testAwaitWithDeadlineErrorPropagates() async {
        do {
            let _: Void = try await CloudExfiltrator.awaitWithDeadline(
                5,
                onDeadline: { XCTFail("deadline must not fire for a fast failure") },
                timeoutError: CKError(.networkFailure),
                start: { resume in resume(.failure(CKError(.quotaExceeded))) })
            XCTFail("the failure must propagate")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .quotaExceeded)
        }
    }

    // MARK: - Purge delete honesty (sixth-review F5, the delete-side ADR 0004)

    private func rid(_ n: Int) -> CKRecord.ID { CKRecord.ID(recordName: "r\(n)") }

    /// A purge may claim success ONLY when every expected record is individually confirmed
    /// absent. The old rule mapped .partialFailure to success and dropped per-record errors,
    /// so Settings said "Deleted" while media remained.
    func testDeleteFailedDemandsEveryRecordConfirmedAbsent() {
        let ids = [rid(1), rid(2), rid(3)]

        XCTAssertFalse(CloudExfiltrator.deleteFailed(operationError: nil,
                                                     confirmedAbsent: [rid(1), rid(2), rid(3)],
                                                     failures: [:], expecting: ids),
                       "all confirmed absent - deleted or already gone - is the one success shape")

        XCTAssertTrue(CloudExfiltrator.deleteFailed(operationError: CKError(.partialFailure),
                                                    confirmedAbsent: [rid(1), rid(2)],
                                                    failures: [rid(3): CKError(.serverRejectedRequest)],
                                                    expecting: ids),
                      "a per-record failure inside .partialFailure is a FAILED purge, not a success")

        XCTAssertTrue(CloudExfiltrator.deleteFailed(operationError: nil,
                                                    confirmedAbsent: [rid(1), rid(2)],
                                                    failures: [:], expecting: ids),
                      "a record with no per-record answer at all is unconfirmed - failed")

        XCTAssertTrue(CloudExfiltrator.deleteFailed(operationError: CKError(.networkFailure),
                                                    confirmedAbsent: [], failures: [:], expecting: ids),
                      "a non-partial operation error fails the batch")
    }

    /// Eighth-review L1: the 30-day floor is structural at the purge entry point - a caller
    /// asking to purge "everything since yesterday" still purges nothing newer than 30 days.
    func testEffectivePurgeCutoffClampsToTheFloor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let floor = now.addingTimeInterval(-30 * 86_400)

        let tooNew = now.addingTimeInterval(-86_400)               // "purge since yesterday"
        XCTAssertEqual(CloudExfiltrator.effectivePurgeCutoff(requested: tooNew, now: now), floor,
                       "a request inside the floor is clamped to it")

        let old = now.addingTimeInterval(-60 * 86_400)
        XCTAssertEqual(CloudExfiltrator.effectivePurgeCutoff(requested: old, now: now), old,
                       "a request past the floor runs as asked")
    }

    // MARK: - The container crash probe carries strikes (sixth-review F7)

    /// One unlucky kill inside the probe window must cost one launch, not the whole build;
    /// only repeated deaths - the entitlement-crash signature - reach the latch limit.
    func testProbeStrikesCountPerBuildAndTolerateOneOffKills() {
        XCTAssertEqual(CloudExfiltrator.probeStrikes(recorded: nil, build: "28"), 0)
        XCTAssertEqual(CloudExfiltrator.probeStrikes(recorded: "28|1", build: "28"), 1,
                       "one recorded death is below the limit - the next launch retries")
        XCTAssertEqual(CloudExfiltrator.probeStrikes(recorded: "28|2", build: "28"), 2,
                       "two deaths reach the latch limit")
        XCTAssertEqual(CloudExfiltrator.probeStrikes(recorded: "27|2", build: "28"), 0,
                       "a new build always gets a clean first attempt (V-02)")
        XCTAssertEqual(CloudExfiltrator.probeStrikes(recorded: "28", build: "28"), 1,
                       "a legacy bare-build marker reads as one strike, not an instant latch")
        XCTAssertEqual(CloudExfiltrator.probeStrikes(recorded: "28|junk", build: "28"), 1,
                       "garbage counts read as one - something died, but never latch on garbage")
        XCTAssertLessThan(CloudExfiltrator.probeStrikes(recorded: "28|1", build: "28"),
                          CloudExfiltrator.probeStrikeLimit,
                          "the single-death marker must stay under the limit or one-off kills still latch")
    }

    // MARK: - Cloud scalar clamps (sixth-review F6, the cheap half)

    /// Revision and sustained count decide who supersedes whom on mirrors - a giant value
    /// freezes that ordering forever (mirror poisoning). Bounded generously, dropped when
    /// absurd.
    func testCloudScalarClampsDropPoisonValues() {
        XCTAssertEqual(CloudExfiltrator.validRevision(3), 3)
        XCTAssertNil(CloudExfiltrator.validRevision(0))
        XCTAssertNil(CloudExfiltrator.validRevision(Int.max),
                     "a poison revision would freeze supersedes for every honest update")
        XCTAssertEqual(CloudExfiltrator.validSustainedCount(14), 14)
        XCTAssertNil(CloudExfiltrator.validSustainedCount(Int.max),
                     "a poison count would freeze the equal-revision count repair")

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CloudExfiltrator.clampedEndDate(start.addingTimeInterval(90), start: start),
                       start.addingTimeInterval(90), "a sane endDate passes")
        XCTAssertEqual(CloudExfiltrator.clampedEndDate(start.addingTimeInterval(-5), start: start),
                       start, "endDate before start collapses to start")
        XCTAssertEqual(CloudExfiltrator.clampedEndDate(start.addingTimeInterval(400 * 86_400), start: start),
                       start.addingTimeInterval(86_400), "no single event spans more than a day")

        XCTAssertEqual(CloudExfiltrator.sanitizedDeviceName(nil), "another device")
        XCTAssertEqual(CloudExfiltrator.sanitizedDeviceName("iPhone Air"), "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.sanitizedDeviceName(String(repeating: "x", count: 500)).count, 64,
                       "labels are display strings, capped - not protocol")
    }

    /// R3-4's pure rule: a startDate is believed at most a day past the record's own
    /// server creation stamp ("now" when the record never got one); the past passes free.
    func testClampedStartDateRule() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CloudExfiltrator.clampedStartDate(created.addingTimeInterval(-3600),
                                                         recordCreated: created, now: created),
                       created.addingTimeInterval(-3600),
                       "past values pass — old evidence is legitimate, and it self-harms an attacker")
        XCTAssertEqual(CloudExfiltrator.clampedStartDate(created.addingTimeInterval(90 * 86_400),
                                                         recordCreated: created, now: created),
                       created.addingTimeInterval(86_400),
                       "future values clamp to creation + a day")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CloudExfiltrator.clampedStartDate(now.addingTimeInterval(90 * 86_400),
                                                         recordCreated: nil, now: now),
                       now.addingTimeInterval(86_400),
                       "no creation stamp — an unsaved or hand-built record — takes 'now' as the reference")
    }
}
