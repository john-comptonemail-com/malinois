import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item175ThumbnailRetryTests: XCTestCase {
    @MainActor private final class Calls {
        var lookups = 0
        var meta: [Event] = []
        var photos: [String] = []
        var attributedFacts = 0
        var factSaves = 0
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisThumbnailRetry")
    }

    override func tearDown() {
        MainActor.assumeIsolated { CloudExfiltrator.thumbnailTempRootForTesting = nil }
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func rig() async throws -> (MonitoringEngine, CloudExfiltrator, EventStore, Event) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let policy = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let enrolled = await policy.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let cloud = CloudExfiltrator(enrollment: policy)
        let calls = Calls()
        cloud.accountIdentityForTesting = { calls.lookups += 1; return nil }
        let store = EventStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
            camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
            timing: EngineCharacterizationTests.fastTiming))
        let settled = await eventually { calls.lookups >= 2 && !engine.pendingSweepActive && !engine.cloudRestoreInProgress }
        XCTAssertTrue(settled, "initial sweep and restore finished with no account")
        cloud.accountIdentityForTesting = { "account-a" }
        var event = Event(startDate: Date().addingTimeInterval(-60), endDate: Date().addingTimeInterval(-59),
                          triggeredSensors: [.motion], thumbnailData: Data([0xff, 0xd8, 0xff]), cloudSyncState: .pending)
        event.primaryCamera = "front"
        event.secondaryCamera = "rear"
        event.mediaFilename = UUID().uuidString + ".jpg"
        event.secondaryMediaFilename = UUID().uuidString + ".jpg"
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        for name in [event.mediaFilename, event.secondaryMediaFilename].compactMap({ $0 }) {
            try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(name))
        }
        policy.registerLocalEvent(event)
        store.add(event)
        return (engine, cloud, store, event)
    }

    private func failStaging() throws {
        let obstacle = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("not-a-directory")
        try Data([1]).write(to: obstacle)
        CloudExfiltrator.thumbnailTempRootForTesting = obstacle
    }

    /// The actual staging write fails, while both the sparse fact and camera records can still land.
    func testAStagingFailureKeepsTheCapturePendingAndTheNextAttemptRepairsIt() async throws {
        let (engine, cloud, store, event) = try await rig()
        try failStaging()
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            for record in records {
                if record.recordType == CloudExfiltrator.metaRecordTypeV2 {
                    calls.meta.append(try XCTUnwrap(CloudExfiltrator.event(from: record)))
                } else if record.recordID.recordName.hasPrefix("photo-") { calls.photos.append(record.recordID.recordName) }
            }
        }
        let first = await engine.exfiltrate(event)
        XCTAssertFalse(first, "a thumbnail remains owed")
        let pending = try XCTUnwrap(store.events.first { $0.id == event.id })
        XCTAssertEqual(pending.cloudSyncState, .pending)
        XCTAssertEqual(Set(pending.uploadedMedia ?? []), ["front", "rear"])
        XCTAssertEqual(calls.photos.count, 2, "neither full-file upload waits on thumbnail staging")
        XCTAssertEqual(calls.meta.count, 1, "the sparse record still reached iCloud")
        XCTAssertNil(calls.meta.first?.thumbnailData)
        XCTAssertFalse(engine.cloudPushRefused, "a local write failure is no server refusal or interference")
        CloudExfiltrator.thumbnailTempRootForTesting = nil
        let second = await engine.exfiltrate(pending)
        XCTAssertTrue(second)
        XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .synced)
        XCTAssertEqual(calls.meta.last?.thumbnailData, event.thumbnailData)
        XCTAssertEqual(calls.meta.first?.cloudRevision, calls.meta.last?.cloudRevision, "same-revision retry is permitted")
    }

    /// A correct PIN's real attribution path reopens an already-synced event when its thumbnail could not stage.
    func testAnOwnerAttributionReopensTheEventWhenItsThumbnailIsOwed() async throws {
        let (engine, cloud, store, event) = try await rig()
        store.setSyncState(.synced, for: event.id)
        try failStaging()
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            calls.attributedFacts += records.filter {
                $0.recordType == CloudExfiltrator.metaRecordTypeV2
                    && ($0.encryptedValues["ownerAttributed"] as? NSNumber)?.boolValue == true
            }.count
        }
        engine.disarmEntry.noteCandidate()
        engine.disarmEntry.noteCandidateEvent(event.id)
        engine.disarm()
        let reopened = await eventually { store.events.first { $0.id == event.id }?.cloudSyncState == .pending }
        XCTAssertTrue(reopened, "pushFact must report its owed thumbnail so attribution reopens the event")
        XCTAssertEqual(calls.attributedFacts, 1, "the attribution's sparse fact did land")
        XCTAssertEqual(store.events.first { $0.id == event.id }?.ownerAttributed, true)
    }

    func testAnEqualRevisionMirrorLearnsTheThumbnailWithoutRegressingItsOtherEvidence() throws {
        var old = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion],
                        sourceDevice: "Other phone", cloudRevision: 2)
        old.mediaFilename = "already-downloaded.jpg"
        old.sustainedCount = 4
        old.captureFailure = "captureFailed"
        var rich = old
        rich.mediaFilename = nil
        rich.thumbnailData = Data([0xff, 0xd8, 0xff])
        let merged = try XCTUnwrap(EventStore.merged(local: [old], incoming: [rich]).first)
        XCTAssertEqual(merged.thumbnailData, rich.thumbnailData)
        XCTAssertEqual(merged.mediaFilename, old.mediaFilename)
        var replay = rich
        replay.thumbnailData = nil
        replay.sustainedCount = 5
        XCTAssertEqual(EventStore.merged(local: [merged], incoming: [replay]).first?.thumbnailData, rich.thumbnailData)
        var lowerCount = rich
        lowerCount.sustainedCount = 3
        XCTAssertFalse(EventStore.supersedes(incoming: lowerCount, existing: old))
        var lostReason = rich
        lostReason.captureFailure = nil
        XCTAssertFalse(EventStore.supersedes(incoming: lostReason, existing: old))
        var older = rich
        older.cloudRevision = 1
        XCTAssertFalse(EventStore.supersedes(incoming: older, existing: old))
        var firsthand = old
        firsthand.sourceDevice = nil
        XCTAssertEqual(EventStore.merged(local: [firsthand], incoming: [rich]).first, firsthand)
    }

    func testNoThumbnailIsCompleteAndARealMetaFailureKeepsItsClassification() async throws {
        let (_, cloud, _, event) = try await rig()
        try failStaging()
        cloud.storedEvent = { _ in nil }
        cloud.saveAttemptForTesting = { _ in }
        var bare = event
        bare.thumbnailData = nil
        let complete = await cloud.exfiltrate(bare, fullMediaURL: nil)
        XCTAssertEqual(complete.syncState, .synced)
        XCTAssertNil(complete.metaFailureWasInterference)
        let owed = await cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(owed.syncState, .pending)
        XCTAssertNil(owed.metaFailureWasInterference, "a local staging error is not an interference verdict")
        cloud.saveAttemptForTesting = { _ in throw CKError(.quotaExceeded) }
        let failed = await cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(failed.syncState, .localOnly)
        XCTAssertEqual(failed.metaFailureWasInterference, false)
    }
    /// Sustained-count and final-flush facts also carry a previously synced capture's thumbnail.
    func testAFailedBackgroundFactReopensTheSyncedCapture() async throws {
        let (engine, cloud, store, event) = try await rig()
        store.setSyncState(.synced, for: event.id)
        try failStaging()
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            calls.factSaves += records.filter { $0.recordType == CloudExfiltrator.metaRecordTypeV2 }.count
        }
        engine.pushFactIfCloud(event)
        let reopened = await eventually { store.events.first { $0.id == event.id }?.cloudSyncState == .pending }
        XCTAssertTrue(reopened)
        XCTAssertEqual(calls.factSaves, 1, "the sparse fact landed but its thumbnail remains owed")
    }

    /// The actual failed snapshot cannot demote a richer attribution written during its save.
    func testAFailedFactDoesNotReopenANewerSyncedSnapshot() async throws {
        let (engine, cloud, store, event) = try await rig()
        store.setSyncState(.synced, for: event.id)
        try failStaging()
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            guard records.contains(where: { $0.recordType == CloudExfiltrator.metaRecordTypeV2 }) else { return }
            var newer = try XCTUnwrap(store.events.first { $0.id == event.id })
            newer.ownerAttributed = true
            store.update(newer)
            calls.factSaves += 1
        }
        engine.pushFactIfCloud(event)
        let saved = await eventually { calls.factSaves == 1 }
        XCTAssertTrue(saved)
        _ = await cloud.enqueue(event.id) { true }   // the failed fact's completion ran before this queue turn
        let held = try XCTUnwrap(store.events.first { $0.id == event.id })
        XCTAssertEqual(held.cloudSyncState, .synced)
        XCTAssertEqual(held.ownerAttributed, true)
    }

    /// A pre-save identity refusal must retain the owner's attribution retry when no metadata operation ran.
    func testAnOwnerAttributionStillReopensWhenIdentityCannotBeResolved() async throws {
        let (engine, cloud, store, event) = try await rig()
        store.setSyncState(.synced, for: event.id)
        cloud.accountIdentityForTesting = { nil }
        cloud.saveAttemptForTesting = { _ in XCTFail("no identity grants no database operation") }
        engine.disarmEntry.noteCandidate()
        engine.disarmEntry.noteCandidateEvent(event.id)
        engine.disarm()
        let reopened = await eventually { store.events.first { $0.id == event.id }?.cloudSyncState == .pending }
        XCTAssertTrue(reopened)
        XCTAssertEqual(store.events.first { $0.id == event.id }?.ownerAttributed, true)
    }

    func testADeliberateBackupBlockDoesNotReopenAnAlreadySyncedFact() async throws {
        let (engine, cloud, store, event) = try await rig()
        store.setSyncState(.synced, for: event.id)
        engine.settings.cloudBackup = false
        cloud.saveAttemptForTesting = { _ in XCTFail("backup policy refused this operation") }
        for account in ["account-a", nil] as [String?] {
            cloud.accountIdentityForTesting = { account }
            let landed = await cloud.pushFact(event)
            XCTAssertFalse(landed)
            XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .synced)
        }
    }

    func testAFailedFactDoesNotReopenANewerReceiptGeneration() async throws {
        let (engine, cloud, store, event) = try await rig()
        store.setSyncState(.synced, for: event.id)
        try failStaging()
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            guard records.contains(where: { $0.recordType == CloudExfiltrator.metaRecordTypeV2 }) else { return }
            var newer = try XCTUnwrap(store.events.first { $0.id == event.id })
            newer.receiptEpoch = 1
            store.update(newer)
            calls.factSaves += 1
        }
        engine.pushFactIfCloud(event)
        let saved = await eventually { calls.factSaves == 1 }
        XCTAssertTrue(saved)
        _ = await cloud.enqueue(event.id) { true }
        XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .synced)
        XCTAssertEqual(store.events.first { $0.id == event.id }?.receiptEpoch, 1)
    }

    func testARejectedMirrorFactNeverReopensAnotherDevicesCopy() async throws {
        let (_, cloud, store, _) = try await rig()
        let mirror = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion],
                           cloudSyncState: .synced, sourceDevice: "Other phone", cloudRevision: 2)
        store.add(mirror)
        let before = try XCTUnwrap(store.events.first { $0.id == mirror.id })
        cloud.saveAttemptForTesting = { _ in XCTFail("a mirror cannot upload under this device's provenance") }
        let landed = await cloud.pushFact(mirror)
        XCTAssertFalse(landed)
        XCTAssertEqual(store.events.first { $0.id == mirror.id }, before)
    }

    /// A current positive presence answer can finish while the fact's thumbnail remains owed.
    func testACompletedPresenceCheckDoesNotEraseAFailedFactsThumbnailRetry() async throws {
        let (engine, cloud, store, event) = try await rig()
        var waiting = event
        waiting.mediaFilename = nil
        waiting.secondaryMediaFilename = nil
        waiting.mediaDiscardUnchecked = true
        store.update(waiting)
        store.setSyncState(.synced, for: event.id)
        try failStaging()
        let calls = Calls()
        let epoch = waiting.receiptEpoch
        cloud.saveAttemptForTesting = { records in
            for record in records where record.recordType == CloudExfiltrator.metaRecordTypeV2 {
                let sparse = try XCTUnwrap(CloudExfiltrator.event(from: record))
                XCTAssertNil(sparse.thumbnailData, "the real staging failure produced a sparse save")
                // A presence lookup is independent of the event's write queue and can finish during this save.
                store.resolveDiscardCheck(event.id, landed: ["front"], epoch: epoch)
                calls.factSaves += 1
            }
        }
        let landed = await cloud.pushFact(waiting)
        XCTAssertFalse(landed, "the sparse fact landed but its thumbnail remains owed")
        XCTAssertEqual(calls.factSaves, 1)
        let after = try XCTUnwrap(store.events.first { $0.id == event.id })
        XCTAssertNil(after.mediaDiscardUnchecked, "the positive check really completed")
        XCTAssertEqual(after.uploadedMedia, ["front"])
        XCTAssertEqual(after.receiptEpoch, waiting.receiptEpoch)
        XCTAssertNotEqual(after.mediaDiscarded, true)
        XCTAssertEqual(after.cloudSyncState, .pending, "local check completion must not erase the thumbnail retry")
        XCTAssertFalse(engine.applyUploadCompletion(.synced, snapshot: waiting),
                       "ordinary upload completions still compare the changed local check state strictly")
        XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .pending)
        store.drainIOForTesting()
        XCTAssertEqual(EventStore().events.first { $0.id == event.id }?.cloudSyncState, .pending)

        // Defensive callback control: a genuinely changed loss payload remains protected, like the separate
        // newer-attribution and newer-receipt-generation tests. This is a helper boundary, not a second cloud save.
        var newerLoss = after
        newerLoss.mediaDiscarded = true
        store.update(newerLoss)
        store.setSyncState(.synced, for: event.id)
        engine.reopenAfterFailedFact(after)
        XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .synced,
                       "a changed durable loss payload is still a different snapshot")
    }

    /// Facts hold an account binding, not a full-media upload pin, so the real byte cap can prune during their save.
    func testAByteCapPruneDuringASparseFactSaveStillOwesTheThumbnail() async throws {
        let (_, cloud, store, event) = try await rig()
        var backed = event
        backed.uploadedMedia = ["front", "rear"]
        store.update(backed)
        store.setSyncState(.synced, for: event.id)
        let snapshot = try XCTUnwrap(store.events.first { $0.id == event.id })
        try failStaging()
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            guard records.contains(where: { $0.recordType == CloudExfiltrator.metaRecordTypeV2 }) else { return }
            XCTAssertFalse(store.isUploading(event.id), "a fact does not pin the full-media cache")
            store.mediaBudgetForTesting = 10
            store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch]))
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !store.byteCapPruneIdleForTesting, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(store.byteCapPruneIdleForTesting)
            let pruned = try XCTUnwrap(store.events.first { $0.id == event.id })
            XCTAssertNil(pruned.mediaFilename)
            XCTAssertNil(pruned.secondaryMediaFilename)
            XCTAssertNil(pruned.mediaDiscardUnchecked, "the synced cache prune owes no cloud-loss check")
            XCTAssertNotEqual(pruned.mediaDiscarded, true)
            XCTAssertEqual(pruned.cloudSyncState, .synced)
            XCTAssertEqual(pruned.mediaManifest, snapshot.mediaManifest, "current receipts retain both cloud files")
            XCTAssertEqual(CloudExfiltrator.metaRevision(for: pruned), CloudExfiltrator.metaRevision(for: snapshot))
            calls.factSaves += 1
        }
        let landed = await cloud.pushFact(snapshot)
        XCTAssertFalse(landed)
        XCTAssertEqual(calls.factSaves, 1)
        let after = try XCTUnwrap(store.events.first { $0.id == event.id })
        XCTAssertEqual(after.cloudSyncState, .pending, "pruning local cache paths cannot erase the thumbnail retry")
        XCTAssertEqual(after.thumbnailData, snapshot.thumbnailData)
        XCTAssertEqual(after.uploadedMedia, snapshot.uploadedMedia)
        XCTAssertNotEqual(after.mediaDiscarded, true)
        store.drainIOForTesting()
        for name in [snapshot.mediaFilename, snapshot.secondaryMediaFilename].compactMap({ $0 }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaDirectory.appendingPathComponent(name).path))
        }
        XCTAssertEqual(EventStore().events.first { $0.id == event.id }?.cloudSyncState, .pending)
    }

    /// The real downloader can refill either cache slot while a failed fact awaits; unchanged capture content still retries.
    func testADownloadDuringASparseFactSaveStillOwesTheThumbnailAndKeepsNewPayloadStrict() async throws {
        let (engine, cloud, store, event) = try await rig()
        var cached = event
        cached.mediaFilename = nil
        cached.secondaryMediaFilename = nil
        cached.uploadedMedia = ["front", "rear"]
        store.update(cached)
        store.setSyncState(.synced, for: event.id)
        let snapshot = try XCTUnwrap(store.events.first { $0.id == event.id })
        for name in [event.mediaFilename, event.secondaryMediaFilename].compactMap({ $0 }) {
            try FileManager.default.removeItem(at: store.mediaDirectory.appendingPathComponent(name))
        }
        let source = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("download-source.jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: source)
        try failStaging()
        engine.requiresCloudLeaseForTesting = true
        engine.fullMediaFetchForTesting = { _, manifest in
            XCTAssertEqual(manifest, ["front", "rear"])
            return CloudExfiltrator.FullMediaFetch(media: [
                CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: source),
                CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: source)
            ], complete: true)
        }
        defer { cloud.saveAttemptForTesting = nil; engine.fullMediaFetchForTesting = nil }
        let calls = Calls()
        cloud.saveAttemptForTesting = { records in
            guard records.contains(where: { $0.recordType == CloudExfiltrator.metaRecordTypeV2 }) else { return }
            let downloaded = await engine.downloadFullEvidence(for: event.id)
            XCTAssertTrue(downloaded.landed)
            XCTAssertTrue(downloaded.complete)
            let current = try XCTUnwrap(store.events.first { $0.id == event.id })
            XCTAssertNotNil(current.mediaFilename)
            XCTAssertNotNil(current.secondaryMediaFilename)
            XCTAssertEqual(current.thumbnailData, snapshot.thumbnailData, "an existing thumbnail is kept")
            XCTAssertEqual(current.primaryCamera, snapshot.primaryCamera)
            XCTAssertEqual(current.secondaryCamera, snapshot.secondaryCamera)
            XCTAssertEqual(current.mediaManifest, snapshot.mediaManifest)
            XCTAssertEqual(CloudExfiltrator.metaRevision(for: current), CloudExfiltrator.metaRevision(for: snapshot))
            calls.factSaves += 1
        }
        let landed = await cloud.pushFact(snapshot)
        XCTAssertFalse(landed)
        XCTAssertEqual(calls.factSaves, 1)
        let downloaded = try XCTUnwrap(store.events.first { $0.id == event.id })
        XCTAssertEqual(downloaded.cloudSyncState, .pending, "refilling cache paths cannot erase the thumbnail retry")
        XCTAssertFalse(engine.applyUploadCompletion(.synced, snapshot: snapshot),
                       "a full-upload completion still compares cache paths strictly")
        XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .pending)

        // These direct callback controls isolate changed evidence from cache bookkeeping. Existing tests separately
        // protect new attribution, receipt epoch, confirmed loss, mirrors and backup policy.
        let changes: [(String, (inout Event) -> Void)] = [
            ("thumbnail", { $0.thumbnailData = Data([1, 2, 3]) }),
            ("primary camera", { $0.primaryCamera = "rear" }),
            ("secondary camera", { $0.secondaryCamera = "front" }),
            ("primary duration", { $0.primaryDuration = 2 }),
            ("secondary duration", { $0.secondaryDuration = 3 }),
            ("sustained count", { $0.sustainedCount = 4 }),
            ("wrong PIN count", { $0.wrongPINCount = 2 }),
            ("capture failure", { $0.captureFailure = "captureFailed" })
        ]
        for (name, change) in changes {
            var newer = downloaded
            change(&newer)
            store.update(newer)
            store.setSyncState(.synced, for: event.id)
            engine.reopenAfterFailedFact(downloaded)
            XCTAssertEqual(store.events.first { $0.id == event.id }?.cloudSyncState, .synced, name)
        }
        store.drainIOForTesting()
    }

}
