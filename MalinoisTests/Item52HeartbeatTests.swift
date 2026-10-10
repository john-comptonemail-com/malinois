//
//  Item52HeartbeatTests.swift
//  MalinoisTests
//
//  BACKLOG 52 (ruled "all as recommended" 2026-09-28; the reader's choice (a) the same night):
//  while a watch is live on Pro, the phone sends a small encrypted beat to iCloud every five
//  minutes: a write-once trail record and the session's latest record, saved over at each beat.
//  Another of the owner's phones shows "Last heard from" on that watch's arm record, from the
//  latest record's server time. A beat that cannot be sent is dropped, never sent late. iCloud
//  cannot run in the Simulator, so the engine is driven through its stand-ins. Written before
//  the change, red at that commit.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item52HeartbeatTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem52")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// The characterization timing, with a beat every fifth of a second.
    private static let beatTiming: EngineTiming = {
        var t = EngineCharacterizationTests.fastTiming
        t.heartbeatInterval = 0.2
        return t
    }()

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    private func makeRig(pro: Bool = true) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: pro ? .trial : .free),
                                                          timing: Self.beatTiming))
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

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "should reach .armed", file: file, line: line)
    }

    private let session = UUID(uuidString: "5F0B5E2A-0000-4000-8000-000000000052")!

    // MARK: - The records

    /// The trail's record is named by the session and the beat's number; the session's latest by
    /// the session alone, so a reader finds it by name.
    func testTheRecordsAreNamedBySessionAndSequence() {
        XCTAssertEqual(CloudExfiltrator.beatRecordName(session: session, sequence: 3), "beat-v2-\(session.uuidString)-3")
        XCTAssertEqual(CloudExfiltrator.latestBeatRecordName(session: session), "beat-latest-v2-\(session.uuidString)")
    }

    /// A beat writes two records, the trail's and the latest, of one type, every field encrypted.
    func testABeatWritesTheTrailAndTheLatestAllEncrypted() {
        let beat = HeartbeatBeat(session: session, sequence: 3, deviceName: "iPhone Air", batteryLevel: 0.42, charging: true)
        let records = CloudExfiltrator.makeBeatRecords(beat)
        XCTAssertEqual(records.map(\.recordID.recordName),
                       [CloudExfiltrator.beatRecordName(session: session, sequence: 3),
                        CloudExfiltrator.latestBeatRecordName(session: session)])
        for record in records {
            XCTAssertEqual(record.recordType, "TamperEventBeatV2")
            // Absent from the clear namespace, key by key, as `testEveryCustomFieldOnATamperRecordIsEncrypted`
            // checks the tamper record (`allKeys()` lists the encrypted keys too).
            for key in ["sessionID", "sequence", "deviceName", "batteryLevel", "charging"] {
                XCTAssertNil(record[key], "\(key) must not be readable in the clear")
            }
            XCTAssertEqual(record.encryptedValues["sessionID"] as? String, session.uuidString)
            XCTAssertEqual(record.encryptedValues["sequence"] as? Int, 3)
            XCTAssertEqual(record.encryptedValues["deviceName"] as? String, "iPhone Air")
            XCTAssertEqual(record.encryptedValues["batteryLevel"] as? Double, 0.42)
            XCTAssertEqual(record.encryptedValues["charging"] as? Bool, true)
        }
    }

    /// A battery level iOS does not know (-1) is left out, not sent as a number.
    func testAnUnknownBatteryLevelIsLeftOut() {
        XCTAssertNil(Heartbeat.batteryLevel(fromIOS: -1))
        XCTAssertEqual(Heartbeat.batteryLevel(fromIOS: 0.5), 0.5)
        let beat = HeartbeatBeat(session: session, sequence: 1, deviceName: "iPhone Air", batteryLevel: nil, charging: false)
        XCTAssertNil(CloudExfiltrator.makeBeatRecords(beat).first?.encryptedValues["batteryLevel"])
    }

    /// A beat goes out only on a Pro session, and only online.
    func testABeatGoesOutOnlyOnProAndOnline() {
        XCTAssertTrue(Heartbeat.beatAllowed(sessionPro: true, online: true))
        XCTAssertFalse(Heartbeat.beatAllowed(sessionPro: false, online: true), "the free tier has no heartbeat")
        XCTAssertFalse(Heartbeat.beatAllowed(sessionPro: true, online: false), "offline: dropped, never sent late")
    }

    // MARK: - The engine

    /// Going live sends the first beat at once, for the session of the watch's "armed" record;
    /// the rest follow the interval, numbered upward from 1.
    func testGoingLiveSendsTheFirstBeatAndTheRestFollow() {
        let rig = makeRig()
        var beats: [HeartbeatBeat] = []
        rig.engine.beatSendForTesting = { beat in beats.append(beat); return true }
        arm(rig)
        XCTAssertTrue(pump(until: { beats.count >= 3 }, timeout: 3), "three beats")
        let armed = rig.store.events.first { $0.stateChange == "armed" }
        XCTAssertNotNil(armed)
        XCTAssertEqual(beats.map(\.sequence), Array(1...max(beats.count, 1)))
        XCTAssertTrue(beats.allSatisfy { $0.session == armed?.id }, "every beat names the watch's arm record")
        rig.engine.disarm()
    }

    /// A disarm stops the beats.
    func testADisarmStopsTheBeats() {
        let rig = makeRig()
        var beats: [HeartbeatBeat] = []
        rig.engine.beatSendForTesting = { beat in beats.append(beat); return true }
        arm(rig)
        XCTAssertTrue(pump(until: { !beats.isEmpty }, timeout: 3), "beating while armed")
        rig.engine.disarm()
        pump(until: { false }, timeout: 0.05)   // a send already under way lands
        let sent = beats.count
        pump(until: { false }, timeout: 0.6)
        XCTAssertEqual(beats.count, sent, "no beat after the disarm")
    }

    /// Offline, a beat is dropped, not queued: the first one sent after the connection returns
    /// carries a later number, so the gap shows in the trail.
    func testAnOfflineBeatIsDroppedNotSentLate() {
        let rig = makeRig()
        var beats: [HeartbeatBeat] = []
        rig.engine.beatSendForTesting = { beat in beats.append(beat); return true }
        rig.engine.simulateConnectivityForTesting(online: false)
        arm(rig)
        pump(until: { false }, timeout: 0.5)
        XCTAssertTrue(beats.isEmpty, "nothing sent offline")
        rig.engine.simulateConnectivityForTesting(online: true)
        XCTAssertTrue(pump(until: { !beats.isEmpty }, timeout: 3), "beating again online")
        XCTAssertGreaterThan(beats.first?.sequence ?? 0, 1, "the dropped beats are a gap, not a backlog")
        rig.engine.disarm()
    }

    /// The free tier sends no beats.
    func testTheFreeTierSendsNoBeats() {
        let rig = makeRig(pro: false)
        var beats: [HeartbeatBeat] = []
        rig.engine.beatSendForTesting = { beat in beats.append(beat); return true }
        arm(rig)
        pump(until: { false }, timeout: 0.5)
        XCTAssertTrue(beats.isEmpty)
        rig.engine.disarm()
    }

    // MARK: - The reader

    /// "Last heard from" shows on an arm record from another phone, on Pro, and nowhere else.
    func testTheRowShowsOnlyOnAnotherPhonesArmRecordOnPro() {
        func record(_ kind: String, from device: String?) -> Event {
            Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced,
                  stateChange: kind, sourceDevice: device)
        }
        XCTAssertTrue(Heartbeat.showsLastHeard(for: record("armed", from: "iPhone Air"), pro: true))
        XCTAssertFalse(Heartbeat.showsLastHeard(for: record("armed", from: nil), pro: true), "this phone's own watch")
        XCTAssertFalse(Heartbeat.showsLastHeard(for: record("disarmed", from: "iPhone Air"), pro: true))
        XCTAssertFalse(Heartbeat.showsLastHeard(for: record("armed", from: "iPhone Air"), pro: false))
    }

    /// The row says when, in the Event Log's own date words, or plainly why it cannot.
    func testTheRowSaysWhenInPlainWords() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(Heartbeat.lastHeardText(.at(date)), date.formatted(date: .abbreviated, time: .standard))
        XCTAssertEqual(Heartbeat.lastHeardText(.never), "No heartbeat on record")
        XCTAssertEqual(Heartbeat.lastHeardText(.unknown), "Could not check iCloud")
        XCTAssertEqual(Heartbeat.lastHeardText(nil), "Checking iCloud")
    }

    /// The reader asks iCloud for the session's latest beat and passes on what it found.
    func testTheReaderAsksForTheSessionsLatestBeat() async {
        let rig = makeRig()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var asked: UUID?
        rig.engine.latestBeatFetchForTesting = { session in asked = session; return .at(date) }
        let heard = await rig.engine.lastHeard(session: session)
        XCTAssertEqual(asked, session)
        XCTAssertEqual(heard, .at(date))
    }
}
