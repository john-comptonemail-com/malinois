//
//  Item114UnsyncedRemovalTests.swift
//  MalinoisTests
//
//  BACKLOG 114 (from item 108, F5; the owner: the marker, and "fix that too" for the upload race).
//  Two things the 1.6 review found about retention:
//  1. Nothing protected an upload in flight: the storage cap could delete an event's media, or the
//     event limit the whole event, while its upload was reading it. Now an event whose media upload
//     is running is left alone by both, without a newer unsynced event dropped in its place; the
//     store applies its limits again when the upload ends, by when the event is usually in iCloud.
//  2. The event limit removed never-uploaded evidence without a trace. Now, on a Pro install, a
//     removal of events this phone was meant to upload leaves one quiet status entry per watch
//     (per day while disarmed). Events held for good (no verified account, a different account),
//     floods, mirrors and status entries do not count.
//  Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item114UnsyncedRemovalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem114Removal")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Uploads in flight

    /// The event limit leaves an uploading event alone, and takes no newer one in its place.
    func testTheEventLimitWaitsForAnUploadInsteadOfTakingANewerEvent() {
        let newest = UUID(), newer = UUID(), uploading = UUID()
        let rows = [EventStore.EvictionRow(id: newest),
                    EventStore.EvictionRow(id: newer),
                    EventStore.EvictionRow(id: uploading, inFlight: true)]
        XCTAssertEqual(EventStore.countEvictionOrder(events: rows, incidentCap: 2, auditCap: 100), [],
                       "the oldest is uploading: nothing goes until it ends")
        let idle = rows.map { EventStore.EvictionRow(id: $0.id) }
        XCTAssertEqual(EventStore.countEvictionOrder(events: idle, incidentCap: 2, auditCap: 100), [uploading],
                       "without an upload the oldest goes, as before")
    }

    /// The storage cap neither counts nor takes an uploading event's media, so a newer pending
    /// event keeps its media too.
    func testTheStorageCapLeavesAnUploadingEventsMedia() {
        let newer = UUID(), uploading = UUID()
        let sizes: [(id: UUID, isFlood: Bool, isSynced: Bool, bytes: Int64)] = [
            (newer, false, false, 10), (uploading, false, false, 10)]
        XCTAssertEqual(EventStore.mediaEvictionOrder(sizes: sizes, budget: 15, inFlight: [uploading]).evict, [],
                       "the uploading event's bytes wait for the upload; the newer event's media stays")
        XCTAssertEqual(EventStore.mediaEvictionOrder(sizes: sizes, budget: 15).evict, [uploading],
                       "without an upload the oldest pending media goes, as before")
    }

    /// Overlapping uploads of one event (a retry beside the response's own) keep it protected
    /// until the last one ends.
    func testOverlappingUploadsKeepTheEventProtectedUntilTheLastEnds() {
        let store = EventStore()
        let id = UUID()
        XCTAssertFalse(store.isUploading(id))
        store.beginUpload(id)
        store.beginUpload(id)
        XCTAssertTrue(store.isUploading(id))
        store.endUpload(id)
        XCTAssertTrue(store.isUploading(id), "one upload still reads it")
        store.endUpload(id)
        XCTAssertFalse(store.isUploading(id))
        store.endUpload(id)
        XCTAssertFalse(store.isUploading(id), "an extra end is harmless")
    }

    /// A removal held back for an upload happens when the upload ends: here the status budget
    /// (100) goes one over while its oldest entry uploads, and comes back when it ends.
    func testAHeldBackRemovalHappensWhenTheUploadEnds() {
        let store = EventStore()
        let entries = (0..<EventStore.maxAuditEvents).map { _ in
            Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced, stateChange: "armed")
        }
        entries.forEach { store.add($0) }
        let oldest = entries[0]
        store.beginUpload(oldest.id)
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced, stateChange: "disarmed"))
        XCTAssertEqual(store.events.count, EventStore.maxAuditEvents + 1, "one over while the oldest uploads")
        XCTAssertTrue(store.events.contains { $0.id == oldest.id })
        store.endUpload(oldest.id)
        XCTAssertEqual(store.events.count, EventStore.maxAuditEvents, "back within budget once it ends")
        XCTAssertFalse(store.events.contains { $0.id == oldest.id }, "the oldest went, as it would have")
    }

    /// The engine marks an event uploading for exactly as long as its media upload runs.
    func testAnUploadMarksItsEventUntilItEnds() async {
        let rig = makeRig(.trial)
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .pending)
        rig.store.add(event)
        var duringUpload: Bool?
        rig.engine.evidencePushForTesting = { [store = rig.store] pushed in
            duringUpload = store.isUploading(pushed.id)
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        defer { rig.engine.evidencePushForTesting = nil }
        await rig.engine.uploadSnapshotForTesting(event, throughSweep: false)
        XCTAssertEqual(duringUpload, true, "protected while the upload ran")
        XCTAssertFalse(rig.store.isUploading(event.id), "released when it ended")
    }

    // MARK: - The marker

    /// Only first-hand records this phone was meant to upload count; since 1.8.2 status records too (item 169's codex-1).
    func testOnlyEvidenceMeantForICloudCounts() {
        let meant = incident()
        let synced = incident(sync: .synced)
        let mirrored = incident(mirrored: true)
        let flood = incident(flood: true)
        let status = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                           stateChange: "armed")
        let unknownAccount = incident(), differentAccount = incident(), unverified = incident()
        let holds: [UUID: CloudEnrollment.UploadHoldReason] = [
            unknownAccount.id: .unknownAccount, differentAccount.id: .differentAccount, unverified.id: .verificationRequired]
        let missed = MonitoringEngine.missedUploads(
            in: [meant, synced, mirrored, flood, status, unknownAccount, differentAccount, unverified],
            holdReason: { holds[$0.id] })
        XCTAssertEqual(Set(missed.map(\.id)), [meant.id, unverified.id, status.id],
                       "pending, waiting-for-verification and status count; held-for-good, synced, mirrored and flood do not")
    }

    /// One marker per watch; while disarmed, one a day.
    func testOneMarkerPerWatchAndOneADayWhileDisarmed() {
        let now = Date(), watch = now.addingTimeInterval(-600)
        XCTAssertTrue(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: nil, armedSince: watch, now: now))
        XCTAssertFalse(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now.addingTimeInterval(-60), watch),
                                                                   armedSince: watch, now: now), "same watch")
        XCTAssertTrue(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now.addingTimeInterval(-60), watch.addingTimeInterval(-9_000)),
                                                                  armedSince: watch, now: now), "a new watch")
        XCTAssertFalse(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now.addingTimeInterval(-3_600), nil),
                                                                   armedSince: nil, now: now), "disarmed, within a day")
        XCTAssertTrue(MonitoringEngine.unsyncedRemovalMarkerIsDue(last: (now.addingTimeInterval(-90_000), nil),
                                                                  armedSince: nil, now: now), "disarmed, a day later")
    }

    /// On Pro, a removal of missed uploads leaves one status entry.
    /// The events are registered to a verified account, as every local event is when recorded:
    /// unregistered ones are held for good and rightly do not count.
    func testTheEngineRecordsOneMarkerOnPro() async {
        let gate = CloudEnrollment(file: (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"), authenticate: { _ in true })
        let enrolled = await gate.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(enrolled)
        let pro = makeRig(.trial, cloud: CloudExfiltrator(enrollment: gate))
        let first = incident(), second = incident()
        gate.registerLocalEvent(first)
        gate.registerLocalEvent(second)
        pro.engine.noteCountEviction([first])
        pro.engine.noteCountEviction([second])
        XCTAssertEqual(pro.store.events.compactMap(\.stateChange).filter { $0 == "unsyncedRemoved" }.count, 1,
                       "one entry, not one per removal")
        XCTAssertEqual(stateEvent("unsyncedRemoved").sensorSummary,
                       "Events not fully backed up to iCloud were removed to make room (log full)")   // item 116's wording
    }

    /// A free install's events never go to iCloud, so removal at the limit is ordinary retention.
    /// (Its own test: two stores in one test share the test's folder, so one loads the other's log.)
    func testAFreeInstallRecordsNoMarker() {
        let free = makeRig(.free)
        free.engine.noteCountEviction([incident()])
        XCTAssertFalse(free.store.events.contains { $0.stateChange == "unsyncedRemoved" })
    }

    /// Other devices read the marker back.
    func testTheMarkerIsReadBackFromTheCloud() {
        let record = CloudExfiltrator.makeStateRecord(stateEvent("unsyncedRemoved"), kind: "unsyncedRemoved", deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "unsyncedRemoved")
    }

    // MARK: - Helpers

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    private func makeRig(_ status: ProEntitlements.Status, cloud: CloudExfiltrator = CloudExfiltrator()) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: status),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        return Rig(engine: engine, store: store)
    }

    private func incident(sync: CloudSyncState = .pending, mirrored: Bool = false, flood: Bool = false) -> Event {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: sync)
        if mirrored { event.sourceDevice = "iPhone Air" }   // a copy from another device
        if flood { event.sustainedCount = 4 }
        return event
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }
}
