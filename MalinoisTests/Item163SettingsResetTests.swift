//
//  Item163SettingsResetTests.swift
//  MalinoisTests
//
//  codex-10 on 1.8.2's step 22 (BACKLOG 163; the owner's ruling (a)). When the stored settings cannot be decoded, the
//  launch resets them to the defaults (ADR 0049, 0055), and the next arm compared them with the surviving baseline and
//  wrote each difference as an edit "in Settings" ("Arming grace period set to 15 s in Settings"), which nobody made.
//  Now the reset leaves its own record, "Settings couldn't be read and were reset to their defaults", and the baseline
//  is re-adopted at the reset, so the records after it show only real edits. Written before the change, red at that
//  commit (against a compile-only stub).
//

import CloudKit
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item163SettingsResetTests: XCTestCase {

    nonisolated private static let settingsKey = "com.malinois.settings"
    nonisolated private static let protectionKey = "com.malinois.protection.recorded"

    // Read and written by setUp and tearDown, which XCTest runs on the main thread without main-actor isolation
    // (item 97), so they are kept outside the actor.
    nonisolated(unsafe) private var savedSettings: Data?
    nonisolated(unsafe) private var canaryFolder = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem163Reset")
        savedSettings = UserDefaults.standard.data(forKey: Self.settingsKey)
        canaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem163Canary-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: canaryFolder, withIntermediateDirectories: true)
        AppSettings.canaryURLOverrideForTesting = canaryFolder.appendingPathComponent("canary")
        UserDefaults.standard.removeObject(forKey: Self.settingsKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedSettings { defaults.set(savedSettings, forKey: Self.settingsKey) }
        else { defaults.removeObject(forKey: Self.settingsKey) }
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.settingsKey + ".corrupt-") }
            .forEach { defaults.removeObject(forKey: $0) }
        defaults.removeObject(forKey: AppSettings.resetPendingKey)
        try? FileManager.default.removeItem(at: canaryFolder)
        AppSettings.canaryURLOverrideForTesting = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A complete 1.8.2 baseline from the owner's settings (a 60 s grace period, one-month retention, Guided Access not
    /// required), then a settings blob that no longer decodes, loaded as a launch loads it.
    private func damagedSettingsOverABaseline() throws -> AppSettings {
        let owners = AppSettings()
        owners.gracePeriodSeconds = 60
        owners.cloudRetention = .months1
        owners.requireGuidedAccess = false
        UserDefaults.standard.set(try JSONEncoder().encode(ProtectionSettings(owners)), forKey: Self.protectionKey)
        UserDefaults.standard.set(Data(#"{"gracePeriodSeconds":"not a number","cloudBackup":true}"#.utf8),
                                  forKey: Self.settingsKey)
        let loaded = AppSettings.load()
        XCTAssertTrue(loaded.wasResetAtLoad, "these are the defaults of a reset")
        return loaded
    }

    private func launch(_ settings: AppSettings) -> (engine: MonitoringEngine, store: EventStore) {
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, store)
    }

    /// The settings edits on the record, oldest first.
    private func edits(_ store: EventStore) -> [String] {
        store.events.compactMap(\.stateChange)
            .filter { $0.hasPrefix("settingOn.") || $0.hasPrefix("settingOff.") || $0.hasPrefix("settingSet.") }
            .reversed()
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced, stateChange: kind)
    }

    // MARK: - codex-10

    /// The reset is on the record once, and the next arm writes no edit "in Settings" for it.
    func testAResetLeavesItsOwnRecordAndNoEditsInSettings() throws {
        let (engine, store) = launch(try damagedSettingsOverABaseline())
        XCTAssertEqual(store.events.filter { $0.stateChange == "settingsReset" }.count, 1, "the reset on the record")
        engine.beginArming()   // records what changed before the session starts, as every arm does
        XCTAssertEqual(edits(store), [], "nobody edited Settings")
        engine.disarm()
    }

    /// A real edit after the reset is still recorded: the baseline is the reset's defaults, not the damaged settings.
    func testARealEditAfterTheResetIsRecorded() throws {
        let settings = try damagedSettingsOverABaseline()
        let (engine, store) = launch(settings)
        settings.responseMode = .stealth
        engine.recordProtectionChanges()   // Settings closes
        XCTAssertEqual(edits(store), ["settingSet.responseMode.stealth"])
    }

    /// Control: settings that load cleanly leave no reset record.
    func testAnOrdinaryLaunchLeavesNoResetRecord() {
        let (_, store) = launch(AppSettings())
        XCTAssertTrue(store.events.filter { $0.stateChange == "settingsReset" }.isEmpty)
    }

    /// The record's words (approved), its icon, its read-back from iCloud and its silence.
    func testTheResetRecordReadsAndTravelsLikeTheOtherStatusRecords() {
        XCTAssertEqual(stateEvent("settingsReset").sensorSummary,
                       "Settings couldn't be read and were reset to their defaults")
        let icon = EventRow.placeholderIcon(for: "settingsReset")
        XCTAssertNotEqual(icon, "camera.metering.none", "an icon of its own")
        XCTAssertNotNil(UIImage(systemName: icon), "an SF Symbol this iOS has")
        let record = CloudExfiltrator.makeStateRecord(stateEvent("settingsReset"), kind: "settingsReset",
                                                      deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "settingsReset", "read back from iCloud")
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "settingsReset"), "no alert")
        XCTAssertTrue(WatchAlertRelay.alerts(for: [stateEvent("settingsReset")], alertsOn: true, proActive: true).isEmpty)
    }

    // MARK: - codex-10's residual: the app ends before the engine starts

    /// codex-10 on c75f223 (its residual): the app ended after the reset was saved and before the engine started; the
    /// relaunch reads the saved defaults cleanly and still writes the reset's record, once, and the next arm writes no
    /// edit "in Settings". A later launch owes nothing.
    func testAResetSurvivesTheAppEndingBeforeTheEngineStarts() throws {
        _ = try damagedSettingsOverABaseline()   // the reset saved; the app ends before the engine starts
        let relaunched = AppSettings.load()
        XCTAssertTrue(relaunched.wasResetAtLoad, "the reset's record is still owed")
        let (engine, store) = launch(relaunched)
        XCTAssertEqual(store.events.filter { $0.stateChange == "settingsReset" }.count, 1, "the reset on the record")
        engine.beginArming()
        XCTAssertEqual(edits(store), [], "nobody edited Settings")
        engine.disarm()
        XCTAssertFalse(AppSettings.load().wasResetAtLoad, "nothing owed once it is on the record")
    }

    /// The app ended after writing the record and before noting it written: the next launch does not write it again.
    func testAResetRecordIsWrittenOnceWhenTheAppEndsAfterWritingIt() throws {
        let settings = try damagedSettingsOverABaseline()
        let noted = UserDefaults.standard.object(forKey: AppSettings.resetPendingKey)
        let first = launch(settings)   // writes the record
        first.store.drainIOForTesting()
        UserDefaults.standard.set(noted ?? Date().addingTimeInterval(-60).timeIntervalSince1970,
                                  forKey: AppSettings.resetPendingKey)   // as if it was never noted written
        let relaunched = AppSettings.load()
        XCTAssertTrue(relaunched.wasResetAtLoad, "owed, as far as the settings know")
        let (_, store) = launch(relaunched)   // reads the log the first launch wrote
        XCTAssertEqual(store.events.filter { $0.stateChange == "settingsReset" }.count, 1, "written once")
    }

    // MARK: - codex-17: whose reset it is

    /// codex-17 on d6908b7: another device's reset, its copy dated a minute ahead (that device's clock fast), is in the
    /// log when this phone's settings reset: this phone still writes its own record, once, keeps the copy, and the next
    /// arm writes no edit "in Settings".
    func testAnotherDevicesResetDoesNotStandInForThisPhones() throws {
        let before = EventStore()   // the log the last launch left, the other device's copy merged into it
        let record = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2)
        record.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
        record.encryptedValues["startDate"] = Date().addingTimeInterval(60) as CKRecordValue
        record.encryptedValues["kind"] = "settingsReset" as CKRecordValue
        record.encryptedValues["deviceName"] = "iPad" as CKRecordValue
        let copy = try XCTUnwrap(CloudExfiltrator.stateEvent(from: record), "the copy decodes")
        before.merge([copy])
        before.drainIOForTesting()

        let (engine, store) = launch(try damagedSettingsOverABaseline())
        let resets = store.events.filter { $0.stateChange == "settingsReset" }
        XCTAssertEqual(resets.filter { !$0.isMirrored }.count, 1, "this phone's own reset on the record")
        XCTAssertTrue(resets.contains { $0.id == copy.id }, "the other device's copy kept")
        engine.beginArming()
        XCTAssertEqual(edits(store), [], "nobody edited Settings")
        engine.disarm()
    }

    /// The control: an earlier reset of this phone's own, dated a minute ahead (its clock was fast then), does not stand
    /// in for a new one either.
    func testAnEarlierResetDatedAheadDoesNotStandInForANewOne() throws {
        let before = EventStore()
        let ahead = Date().addingTimeInterval(60)
        before.add(Event(startDate: ahead, endDate: ahead, triggeredSensors: [], cloudSyncState: .localOnly,
                         stateChange: "settingsReset"))
        before.drainIOForTesting()
        let (_, store) = launch(try damagedSettingsOverABaseline())
        XCTAssertEqual(store.events.filter { $0.stateChange == "settingsReset" && !$0.isMirrored }.count, 2,
                       "the new reset's own record as well")
    }

    // MARK: - codex-17's residual: a note that holds no identity

    /// codex-17 on ab40872 (its residual): the reset's note holds no identity (a timestamp an earlier build of 1.8.2
    /// wrote, or damage), and the app ends after the reset's record reaches the journal and before the note is cleared.
    /// The note as it was when the record was born must name that record, so the next launch finds it and writes none.
    private func assertWrittenOnceAfterTheAppEnds(withNote legacy: Any) throws {
        _ = try damagedSettingsOverABaseline()   // the reset saved its defaults; the app ended before the engine started
        UserDefaults.standard.set(legacy, forKey: AppSettings.resetPendingKey)
        let settings = AppSettings.load()
        XCTAssertTrue(settings.wasResetAtLoad, "the reset's record is owed")
        let store = EventStore()
        var atBirth: Any?
        store.journalSyncObserverForTesting = { [weak store] in
            // The reset's own journal line: synced before its record joins the log in memory.
            guard let store, !store.events.contains(where: { $0.stateChange == "settingsReset" }) else { return }
            atBirth = UserDefaults.standard.object(forKey: AppSettings.resetPendingKey)
        }
        _ = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                 camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                 timing: EngineCharacterizationTests.fastTiming))
        store.drainIOForTesting()
        let record = try XCTUnwrap(store.events.first { $0.stateChange == "settingsReset" }, "the reset's record")
        let noted = try XCTUnwrap(atBirth, "the note when the record reached the journal")
        XCTAssertEqual((noted as? String).flatMap(UUID.init(uuidString:)), record.id, "the note names the record")
        UserDefaults.standard.set(noted, forKey: AppSettings.resetPendingKey)   // the app ended before clearing it
        let relaunched = AppSettings.load()
        XCTAssertTrue(relaunched.wasResetAtLoad, "owed, as far as the settings know")
        let (_, again) = launch(relaunched)   // reads the log the first launch wrote
        XCTAssertEqual(again.events.filter { $0.stateChange == "settingsReset" }.map(\.id), [record.id], "written once")
    }

    /// A timestamp note, as an earlier build of 1.8.2 wrote it.
    func testAResetWhoseNoteHeldATimestampIsWrittenOnce() throws {
        try assertWrittenOnceAfterTheAppEnds(withNote: Date().addingTimeInterval(-60).timeIntervalSince1970)
    }

    /// A damaged note.
    func testAResetWhoseNoteWasDamagedIsWrittenOnce() throws {
        try assertWrittenOnceAfterTheAppEnds(withNote: "not an identity")
    }

    // MARK: - codex-12: a reset with iCloud backup off

    /// The record names the saves sent.
    @MainActor
    private final class Sent {
        private(set) var names: [String] = []
        func add(_ records: [CKRecord]) { names += records.map(\.recordID.recordName) }
    }

    /// codex-12 on 1.8.2: with iCloud backup off (as the damaged settings still show it, or failing closed where they
    /// cannot), the reset's record stays on this phone for good, as every record made with backup off does: tied to no
    /// account, marked to stay local, and still unsent after backup is turned on and the pending sweep runs. The launch
    /// wrote it before the engine installed the backup-off rules, so it was bound to the verified account.
    func testWithBackupOffTheResetRecordStaysOnThisPhone() async throws {
        let damaged = [#"{"gracePeriodSeconds":"not a number","cloudBackup":false}"#,
                       #"{"gracePeriodSeconds":"not a number","cloudBackup":"maybe"}"#]
        for blob in damaged {
            let file = try XCTUnwrap(EventStore.rootOverrideForTesting)
                .appendingPathComponent("grant-" + UUID().uuidString).appendingPathComponent("state.json")
            let enrollment = CloudEnrollment(file: file, authenticate: { _ in true })
            let verified = await enrollment.enroll(account: "account-A", resolve: { "account-A" })
            XCTAssertTrue(verified, "a verified installation")
            UserDefaults.standard.set(try JSONEncoder().encode(ProtectionSettings(AppSettings())), forKey: Self.protectionKey)
            UserDefaults.standard.set(Data(blob.utf8), forKey: Self.settingsKey)
            let settings = AppSettings.load()
            XCTAssertTrue(settings.wasResetAtLoad, "a reset: \(blob)")
            XCTAssertFalse(settings.cloudBackup, "backup off after the reset: \(blob)")
            let sent = Sent()
            let cloud = CloudExfiltrator(enrollment: enrollment)
            cloud.accountIdentityForTesting = { "account-A" }
            cloud.saveAttemptForTesting = { records in sent.add(records) }
            let store = EventStore()
            let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                              camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                              timing: EngineCharacterizationTests.fastTiming))
            let reset = try XCTUnwrap(store.events.first { $0.stateChange == "settingsReset" }, "the reset's record")
            XCTAssertEqual(reset.keptLocal, true, "marked to stay on this phone: \(blob)")
            let lease = try XCTUnwrap(enrollment.authorize(account: "account-A"))
            XCTAssertFalse(enrollment.authorizeUpload(event: reset, lease: lease), "tied to no account: \(blob)")
            XCTAssertTrue(engine.setCloudBackup(true), "backup turned on")
            await engine.retryPendingSync()
            XCTAssertFalse(sent.names.contains { $0.contains(reset.id.uuidString) },
                           "the reset's record is never sent: \(sent.names)")
            store.drainIOForTesting()
        }
    }
}
