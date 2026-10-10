//
//  Item38ThermalSentinelTests.swift
//  MalinoisTests
//
//  Tests for BACKLOG 38, the thermal sentinel. Heat alone can make a phone shut itself down,
//  with no tripwire touched. While a watch is live, iOS's thermal state reaching "serious", and
//  then "critical", each leaves one audit record, so the log shows the heat before the silence.
//  No siren and no cross-device alert: ambient heat looks like induced heat (ADR 0001). Built on
//  Claude's recommended choices, pending the owner's ruling (the item's design pass).
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item38ThermalSentinelTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem38")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// `thermal`: iOS's answer, injected so a hot Mac cannot flake these tests (item 89, D1).
    private func makeRig(thermal: @escaping @MainActor () -> ProcessInfo.ThermalState = { .nominal }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: thermal))
        return Rig(engine: engine, store: store)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Arms through grace (0 s), calibration, and the calibration review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    /// The thermal records in the log, by kind, sorted.
    private func thermalRecords(_ rig: Rig) -> [String] {
        rig.store.events.compactMap(\.stateChange).filter { $0.hasPrefix("thermal") }.sorted()
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    // MARK: - The rule

    /// One record at the first "serious" of a session and one at the first "critical": a phone
    /// that flaps between fair and serious writes nothing more, and cooling is not news.
    func testEachLevelIsRecordedOncePerSession() {
        func kind(_ state: ProcessInfo.ThermalState, _ logged: Set<String>) -> String? {
            MonitoringEngine.thermalRecordKind(for: state, alreadyLogged: logged)
        }
        XCTAssertNil(kind(.nominal, []))
        XCTAssertNil(kind(.fair, []), "a warm phone is not news")
        XCTAssertEqual(kind(.serious, []), "thermalSerious")
        XCTAssertNil(kind(.serious, ["thermalSerious"]), "once a session")
        XCTAssertEqual(kind(.critical, ["thermalSerious"]), "thermalCritical")
        XCTAssertEqual(kind(.critical, []), "thermalCritical", "a jump straight to critical is recorded")
        XCTAssertNil(kind(.critical, ["thermalSerious", "thermalCritical"]))
        XCTAssertNil(kind(.serious, ["thermalCritical"]), "cooling from critical to serious is not a new record")
    }

    // MARK: - The engine

    /// Armed, a phone heating up writes one audit record per level, and nothing else changes:
    /// the watch carries on, with no alarm.
    func testAPhoneHeatingWhileArmedWritesOneRecordPerLevelAndNoAlarm() {
        let rig = makeRig()
        arm(rig)
        for state in [ProcessInfo.ThermalState.serious, .serious, .fair, .serious, .critical, .serious] {
            rig.engine.handleThermalStateChange(state)
        }
        XCTAssertEqual(thermalRecords(rig), ["thermalCritical", "thermalSerious"], "one record per level")
        XCTAssertEqual(rig.engine.state, .armed, "not a trip: the watch carries on")
        XCTAssertFalse(rig.engine.alertActive, "no siren, no alert")
        rig.engine.disarm()
    }

    /// Heat while disarmed is not recorded: the sentinel watches a live session only.
    func testNothingIsRecordedWhileDisarmed() {
        let rig = makeRig()
        rig.engine.handleThermalStateChange(.critical)
        XCTAssertTrue(thermalRecords(rig).isEmpty)
    }

    /// Each armed session starts afresh.
    func testANewSessionRecordsAgain() {
        let rig = makeRig()
        arm(rig)
        rig.engine.handleThermalStateChange(.serious)
        rig.engine.disarm()
        arm(rig)
        rig.engine.handleThermalStateChange(.serious)
        XCTAssertEqual(thermalRecords(rig), ["thermalSerious", "thermalSerious"], "one in each session")
        rig.engine.disarm()
    }

    // MARK: - The record elsewhere

    /// The owner's other devices read the record back: the cloud decoder's allow-list knows both
    /// kinds, and still drops a kind it does not know.
    func testThermalRecordsAreReadBackFromTheCloud() {
        for kind in ["thermalSerious", "thermalCritical"] {
            let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
            XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind, "another device's log shows \(kind)")
        }
        let unknown = CloudExfiltrator.makeStateRecord(stateEvent("someFutureKind"), kind: "someFutureKind", deviceName: "iPhone Air")
        XCTAssertNil(CloudExfiltrator.stateEvent(from: unknown), "an unknown kind is still dropped")
    }

    /// The Event Log names each record in plain words, with no em-dashes (screen text).
    func testTheLogNamesEachThermalRecord() {
        let serious = stateEvent("thermalSerious").sensorSummary
        let critical = stateEvent("thermalCritical").sensorSummary
        XCTAssertEqual(serious, "Phone running hot while armed")
        XCTAssertEqual(critical, "Phone overheating while armed: iOS may shut it down")
        XCTAssertFalse((serious + critical).contains("\u{2014}"), "no em-dashes on screens")
    }

    // MARK: - The review's follow-ups (item 89, D2) and choice 3

    /// A thermal record never rides the disarm alert's signal: it is an audit record, silent on
    /// the owner's other devices.
    func testThermalRecordsNeverRaiseTheDisarmAlert() {
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "thermalSerious"))
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "thermalCritical"))
    }

    /// Each of iOS's four states has its name on a record.
    func testTheStateNamesAreIOSs() {
        XCTAssertEqual(MonitoringEngine.thermalStateName(.nominal), "nominal")
        XCTAssertEqual(MonitoringEngine.thermalStateName(.fair), "fair")
        XCTAssertEqual(MonitoringEngine.thermalStateName(.serious), "serious")
        XCTAssertEqual(MonitoringEngine.thermalStateName(.critical), "critical")
    }

    /// Choice 3: a capture's record carries the phone's thermal state when it was made.
    func testACaptureCarriesThePhonesThermalState() {
        let rig = makeRig(thermal: { .serious })
        arm(rig)
        rig.engine.noteWrongDisarmPIN()   // a capture of its own (item 49)
        XCTAssertTrue(pump(until: { rig.store.events.contains { ($0.wrongPINCount ?? 0) > 0 } }, timeout: 5))
        let record = rig.store.events.first { ($0.wrongPINCount ?? 0) > 0 }
        XCTAssertEqual(record?.thermalState, "serious")
        rig.engine.disarm()
    }

    /// The thermal state rides the encrypted metadata to iCloud and comes back on another device;
    /// a value this build does not know is dropped.
    func testTheThermalStateRidesTheMetadataAndComesBack() throws {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thermalState: "critical")
        let json = try XCTUnwrap(event.metadataJSON)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(obj["thermalState"] as? String, "critical")
        let record = CloudExfiltrator.makeMetaRecord(event, deviceName: "iPhone Air", thumbnailURL: nil)
        XCTAssertEqual(CloudExfiltrator.event(from: record)?.thermalState, "critical", "another device reads it back")
        let bogus = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thermalState: "melting")
        let bogusRecord = CloudExfiltrator.makeMetaRecord(bogus, deviceName: "iPhone Air", thumbnailURL: nil)
        XCTAssertNil(CloudExfiltrator.event(from: bogusRecord)?.thermalState, "an unknown value is dropped")
    }

    /// The detail screen says it in plain words, without em-dashes.
    func testTheDetailScreenSaysItInPlainWords() {
        func summary(_ raw: String?) -> String? {
            Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thermalState: raw).thermalStateSummary
        }
        XCTAssertEqual(summary("nominal"), "Normal")
        XCTAssertEqual(summary("fair"), "Slightly warm")
        XCTAssertEqual(summary("serious"), "Hot: iOS is slowing the phone")
        XCTAssertEqual(summary("critical"), "Overheating: iOS may shut the phone down")
        XCTAssertNil(summary(nil))
        for raw in ["nominal", "fair", "serious", "critical"] {
            XCTAssertFalse(summary(raw)?.contains("\u{2014}") ?? false)
        }
    }
}
