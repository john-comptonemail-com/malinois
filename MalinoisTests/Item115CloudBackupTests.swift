//
//  Item115CloudBackupTests.swift
//  MalinoisTests
//
//  BACKLOG 115 (item 108's decision 4, option C, and P-01; the owner chose option a): an "iCloud
//  backup" switch. On by default. Off stops this phone uploading anything (events, photos, clips,
//  status entries, heartbeats) except the entry recording that it was turned off, logged before
//  uploads stop so the cloud log shows it. Turning it off needs device authentication (the Settings
//  flow); turning it on does not. An event recorded while it is off stays on this phone for good,
//  even once it is back on: Retry and the sweep never offer it, the log says why, and item 114's
//  marker does not count it as a missed upload. Written before the change, red at that commit
//  (against compile-only stubs).
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item115CloudBackupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem115Backup")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The setting

    /// On by default, remembered, and on for settings saved before the switch existed.
    func testBackupIsOnByDefaultAndRemembered() throws {
        XCTAssertTrue(AppSettings().cloudBackup)
        let settings = AppSettings()
        settings.cloudBackup = false
        let data = try JSONEncoder().encode(settings)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: data).cloudBackup)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "cloudBackup")
        let older = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: older).cloudBackup, "an older install keeps uploading")
    }

    // MARK: - Recorded while off

    /// The store marks an event recorded while backup is off; one recorded while on is unmarked.
    func testAnEventRecordedWhileBackupIsOffIsMarkedToStayLocal() {
        let store = EventStore()
        var off = false
        store.keepsNewEventsLocal = { off }
        let before = incident()
        store.add(before)
        off = true
        let during = incident()
        store.add(during)
        XCTAssertNil(store.events.first { $0.id == before.id }?.keptLocal)
        XCTAssertEqual(store.events.first { $0.id == during.id }?.keptLocal, true)
    }

    // MARK: - The gate

    /// While off nothing uploads but the entry saying so; an event recorded while off never uploads.
    func testNothingUploadsWhileBackupIsOffExceptTheEntryThatSaysSo() {
        let rig = makeRig()
        let event = incident()
        rig.store.add(event)
        XCTAssertTrue(rig.engine.backupAllows(event))
        rig.engine.settings.cloudBackup = false
        XCTAssertFalse(rig.engine.backupAllows(event), "nothing uploads while off")
        XCTAssertTrue(rig.engine.backupAllows(stateEvent(Event.backupOffKind)), "except the entry recording it was turned off")
        rig.engine.settings.cloudBackup = true
        var kept = incident()
        kept.keptLocal = true
        rig.store.add(kept)
        XCTAssertFalse(rig.engine.backupAllows(kept), "recorded while off: never, even once it is back on")
    }

    /// A kept event's upload never reaches iCloud and lands as local only; an ordinary one uploads.
    func testAKeptEventsUploadNeverReachesICloud() async {
        let rig = makeRig()
        var pushes = 0
        rig.engine.evidencePushForTesting = { _ in
            pushes += 1
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        defer { rig.engine.evidencePushForTesting = nil }
        var kept = incident()
        kept.keptLocal = true
        rig.store.add(kept)
        await rig.engine.uploadSnapshotForTesting(kept, throughSweep: false)
        XCTAssertEqual(pushes, 0)
        XCTAssertEqual(rig.store.events.first { $0.id == kept.id }?.cloudSyncState, .localOnly)
        let ordinary = incident()
        rig.store.add(ordinary)
        await rig.engine.uploadSnapshotForTesting(ordinary, throughSweep: false)
        XCTAssertEqual(pushes, 1, "an ordinary event still uploads")
    }

    /// The pending sweep (Retry, reconnects, launches) never offers a kept event.
    func testTheSweepNeverOffersAKeptEvent() async {
        let rig = makeRig()
        var offered: [UUID] = []
        rig.engine.sweepUploadForTesting = { event in
            offered.append(event.id)
            return (.synced, nil)
        }
        defer { rig.engine.sweepUploadForTesting = nil }
        var kept = incident()
        kept.keptLocal = true
        let ordinary = incident()
        rig.store.add(kept)
        rig.store.add(ordinary)
        await rig.engine.retryPendingSync()
        XCTAssertTrue(offered.contains(ordinary.id))
        XCTAssertFalse(offered.contains(kept.id))
    }

    /// A watch armed with backup off sends no heartbeats.
    func testHeartbeatsStopWhileBackupIsOff() {
        let rig = makeRig(timing: Self.beatTiming)
        rig.engine.settings.cloudBackup = false
        var beats = 0
        rig.engine.beatSendForTesting = { _ in beats += 1; return true }
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5))
        pump(until: { false }, timeout: 0.8)
        XCTAssertEqual(beats, 0, "four beat intervals, no beat")
        rig.engine.disarm()
    }

    // MARK: - Turning it off and on

    /// Off is recorded first, in an entry that can still upload; on is recorded after; an event
    /// recorded in between stays local for good.
    func testTurningBackupOffIsRecordedFirstAndOnAfter() {
        let rig = makeRig()
        rig.engine.setCloudBackup(false)
        XCTAssertFalse(rig.engine.settings.cloudBackup)
        let off = rig.store.events.first { $0.stateChange == Event.backupOffKind }
        XCTAssertNotNil(off, "the off entry")
        XCTAssertNil(off?.keptLocal, "recorded before uploads stopped, so it can still upload")
        let during = incident()
        rig.store.add(during)
        XCTAssertEqual(rig.store.events.first { $0.id == during.id }?.keptLocal, true)
        rig.engine.setCloudBackup(true)
        XCTAssertTrue(rig.engine.settings.cloudBackup)
        XCTAssertNotNil(rig.store.events.first { $0.stateChange == Event.backupOnKind })
        XCTAssertEqual(rig.store.events.first { $0.id == during.id }?.keptLocal, true, "it stays local for good")
    }

    // MARK: - Words

    /// A kept event says why it is held, and item 114's marker does not count it.
    func testAKeptEventSaysWhyAndIsNoMissedUpload() {
        var kept = incident()
        kept.keptLocal = true
        let gate = CloudEnrollment(file: (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"), authenticate: { _ in true })
        XCTAssertEqual(gate.uploadHoldReason(for: kept), .backupOff)
        XCTAssertTrue(CloudEnrollment.UploadHoldReason.backupOff.explanation.contains("iCloud backup was off"))
        XCTAssertTrue(MonitoringEngine.missedUploads(in: [kept], holdReason: { _ in .backupOff }).isEmpty)
    }

    /// The two entries read plainly here and on other devices.
    func testTheBackupEntriesReadPlainlyEverywhere() {
        XCTAssertEqual(stateEvent(Event.backupOffKind).sensorSummary,
                       "iCloud backup turned off: events recorded while it is off stay on this iPhone")
        XCTAssertEqual(stateEvent(Event.backupOnKind).sensorSummary, "iCloud backup turned on")
        for kind in [Event.backupOffKind, Event.backupOnKind] {
            let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
            XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind)
        }
    }

    // MARK: - Helpers

    private static let beatTiming: EngineTiming = {
        var t = EngineCharacterizationTests.fastTiming
        t.heartbeatInterval = 0.2
        return t
    }()

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    private func makeRig(timing: EngineTiming = EngineCharacterizationTests.fastTiming) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing, thermalState: { .nominal }))
        engine.simulateConnectivityForTesting(online: true)
        return Rig(engine: engine, store: store)
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func incident() -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }
}
