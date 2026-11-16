//
//  Item235PurgeEntryTests.swift
//  MalinoisTests
//
//  BACKLOG item 235's second half, A10 (1.13, item 240's list; docs/design/1.13-fixes.md, part 3b; the owner, 2026-11-12:
//  "as you recommend, wording approved": D4 (a), W4). Settings' "Free up iCloud space..." (the Manual retention mode,
//  Pro) deletes iCloud's full photos and clips of the events older than the period chosen, and wrote no entry in the
//  Event Log. Now it goes through the engine, which writes a quiet status entry once a purge has sent its deletions: the
//  period and how many events' (not files: a name with nothing under it counts as deleted), with "some couldn't be
//  deleted" when part of it failed. The daily automatic retention writes none (D4 (a)). Through Settings laid out for
//  real, its button and its dialog pressed, with iCloud's side stood in for (`retentionAccessForTesting`). Written before
//  the fix, red at that commit (where the purge goes straight to iCloud and the kind is read by nothing).
//

import CloudKit
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item235PurgeEntryTests: XCTestCase {
    private static let freeUp = "Free up iCloud space…"
    private static let dialogTitle = "Delete full-resolution photos and clips from iCloud?"
    private static let sixMonths = "Older than 6 months: " + dialogTitle

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem235Purge")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Through Settings

    /// Settings' button and its dialog's "Older than 6 months", pressed: the purge goes through the engine, and the Event
    /// Log has an entry with the period and the events' count.
    func testSettingsFreeUpICloudSpaceLeavesAnEntry() async throws {
        let rig = makeRig(oldEvents: 3)
        let recorder = OnScreenRecorder()
        let screen = SettingsView()
            .environmentObject(rig.settings).environmentObject(rig.cloud)
            .environmentObject(rig.entitlements).environmentObject(rig.engine)
            .environmentObject(rig.store).environmentObject(CameraController())
        try await onScreen(screen, recorder) {
            try await waitUntil("the button offered") { recorder.actions[Self.freeUp] != nil }
            recorder.actions[Self.freeUp]?()
            try await waitUntil("the dialog's choice offered") { recorder.actions[Self.sixMonths] != nil }
            recorder.actions[Self.sixMonths]?()
            try await waitUntil("the purge's entry") { !self.purgeEntries(rig).isEmpty }
        }
        let entry = try XCTUnwrap(purgeEntries(rig).first)
        XCTAssertEqual(entry.stateChange.flatMap(Event.iCloudMediaPurged(kind:)),
                       Event.ICloudMediaPurged(months: 6, events: 3, failed: false))
        XCTAssertEqual(entry.sensorSummary, "Full photos and clips of 3 events older than 6 months were deleted from iCloud")
        XCTAssertFalse(entry.isMirrored, "this phone's own entry, signed and uploaded as its others are")
        XCTAssertGreaterThan(rig.probe.deleted, 0, "iCloud was asked to delete")
    }

    // MARK: - Through the engine

    /// A purge part of which failed says so.
    func testAPurgePartOfWhichFailedSaysSo() async throws {
        let rig = makeRig(oldEvents: 1, deleteFails: true)
        let result = await rig.engine.freeUpICloudSpace(monthsOld: 1)
        XCTAssertTrue(result.failed)
        let entry = try XCTUnwrap(purgeEntries(rig).first, "an entry")
        XCTAssertEqual(entry.sensorSummary,
                       "Full photos and clips of 1 event older than 1 month were deleted from iCloud; some couldn't be deleted")
    }

    /// No event old enough: nothing was asked of iCloud, and no entry is written.
    func testNoEntryWhenNoEventWasOldEnough() async {
        let rig = makeRig(oldEvents: 0)
        _ = await rig.engine.freeUpICloudSpace(monthsOld: 12)
        XCTAssertEqual(rig.probe.deleted, 0)
        XCTAssertFalse(rig.store.events.contains { $0.stateChange?.hasPrefix("iCloudMediaPurged.") == true },
                       "no entry of a purge, readable or not")
    }

    /// A guard, green before the fix and after (D4 (a)): the daily automatic retention writes no entry; it follows a
    /// setting whose changes are recorded.
    func testTheAutomaticRetentionWritesNoEntry() async {
        let defaults = UserDefaults.standard
        let keys = ["com.malinois.cloudRetention.lastRun", "com.malinois.cloudRetention.lastAttempt"]
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer { keys.forEach { defaults.removeObject(forKey: $0) } }
        let rig = makeRig(oldEvents: 2, retention: .months6)
        await rig.engine.enforceCloudRetentionIfDue()
        XCTAssertGreaterThan(rig.probe.deleted, 0, "the automatic pass ran")
        XCTAssertTrue(purgeEntries(rig).isEmpty, "and wrote no entry")
    }

    // MARK: - The kind and its words

    /// The kind reads only what it writes, and another device reads the entry from iCloud.
    func testTheKindReadsOnlyWhatItWrites() throws {
        let purged = Event.ICloudMediaPurged(months: 6, events: 37, failed: false)
        XCTAssertEqual(Event.iCloudMediaPurgedKind(purged), "iCloudMediaPurged.6.37.0")
        XCTAssertEqual(Event.iCloudMediaPurged(kind: "iCloudMediaPurged.6.37.0"), purged)
        XCTAssertEqual(Event.iCloudMediaPurged(kind: "iCloudMediaPurged.1.1.1"),
                       Event.ICloudMediaPurged(months: 1, events: 1, failed: true))
        for malformed in ["iCloudMediaPurged", "iCloudMediaPurged.6.37", "iCloudMediaPurged.6.37.0.0", "iCloudMediaPurged.0.37.0",
                          "iCloudMediaPurged.13.37.0", "iCloudMediaPurged.6.0.0", "iCloudMediaPurged.6.37.2",
                          "iCloudMediaPurged.06.37.0", "iCloudMediaPurged.6.037.0", "iCloudMediaPurged.6.1000001.0",
                          "iCloudMediaPurged.6.-1.0", "iCloudMediaPurged.x.37.0", "icloudmediapurged.6.37.0", "disarmed"] {
            XCTAssertNil(Event.iCloudMediaPurged(kind: malformed), malformed)
        }
        let record = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2, recordID: CKRecord.ID(recordName: "state-x"))
        record["eventID"] = UUID().uuidString as CKRecordValue
        record["kind"] = "iCloudMediaPurged.6.37.0" as CKRecordValue
        record["startDate"] = Date(timeIntervalSince1970: 1_762_520_000) as CKRecordValue
        record["deviceName"] = "iPhone Air" as CKRecordValue
        let copy = try XCTUnwrap(CloudExfiltrator.stateEvent(from: record), "another device reads it")
        XCTAssertEqual(copy.stateChange, "iCloudMediaPurged.6.37.0")
    }

    /// W4, word for word (the owner's "wording approved", 2026-11-12), with its singulars and its failed part; the row
    /// shows the whole sentence.
    func testTheWordsAreTheApprovedOnes() {
        XCTAssertEqual(Event.iCloudMediaPurgedSummary(kind: "iCloudMediaPurged.6.37.0"),
                       "Full photos and clips of 37 events older than 6 months were deleted from iCloud")
        XCTAssertEqual(Event.iCloudMediaPurgedSummary(kind: "iCloudMediaPurged.1.1.0"),
                       "Full photos and clips of 1 event older than 1 month were deleted from iCloud")
        XCTAssertEqual(Event.iCloudMediaPurgedSummary(kind: "iCloudMediaPurged.12.2.1"),
                       "Full photos and clips of 2 events older than 12 months were deleted from iCloud; some couldn't be deleted")
        let at = Date(timeIntervalSince1970: 1_762_520_000)
        let entry = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "iCloudMediaPurged.6.37.0")
        XCTAssertEqual(entry.sensorSummary, "Full photos and clips of 37 events older than 6 months were deleted from iCloud")
        XCTAssertNil(EventRow.summaryLineLimit(for: entry), "the row shows the whole sentence")
        XCTAssertEqual(EventRow.placeholderIcon(for: "iCloudMediaPurged.6.37.0"), "trash")
    }

    // MARK: - Helpers

    private struct Rig {
        let settings: AppSettings
        let store: EventStore
        let cloud: CloudExfiltrator
        let entitlements: ProEntitlements
        let engine: MonitoringEngine
        let probe: PurgeProbe
    }

    /// What iCloud's stand-in was asked to delete.
    @MainActor
    private final class PurgeProbe {
        var deleted = 0
    }

    /// Settings on Pro with `retention`, and iCloud's side stood in for: `oldEvents` events older than any period, their
    /// deletions answered as done, or as failed.
    private func makeRig(oldEvents: Int, deleteFails: Bool = false, retention: CloudRetention = .manual) -> Rig {
        let settings = AppSettings()
        settings.cloudRetention = retention
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let probe = PurgeProbe()
        let ids = (0..<oldEvents).map { _ in UUID() }
        cloud.retentionAccessForTesting = CloudExfiltrator.RetentionAccess(
            serverDate: { type in type == CloudExfiltrator.stateRecordTypeV2 ? Date() : nil },
            mediaEvents: { _, type in (type == CloudExfiltrator.metaRecordTypeV2 ? ids : [], true) },
            beatRecords: { _, _ in [:] },
            delete: { records in
                probe.deleted += records.count
                return (records.count, deleteFails)
            })
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        addTeardownBlock { @MainActor in store.drainIOForTesting() }
        return Rig(settings: settings, store: store, cloud: cloud, entitlements: entitlements, engine: engine, probe: probe)
    }

    private func purgeEntries(_ rig: Rig) -> [Event] {
        rig.store.events.filter { $0.stateChange.flatMap(Event.iCloudMediaPurged(kind:)) != nil }
    }

    /// Lays `view` out in a window tall enough for every row of Settings, `recorder` reading it, while `body` runs.
    private func onScreen<V: View>(_ view: V, _ recorder: OnScreenRecorder, _ body: () async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 12_000)
        let host = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body()
    }

    /// Lets the main run loop turn until `condition` holds; after ten seconds, fails the test, naming what it waited for.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("waited ten seconds: \(what)")
                throw TimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct TimedOut: Error {
    let what: String
}
