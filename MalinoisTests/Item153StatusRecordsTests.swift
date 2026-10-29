//
//  Item153StatusRecordsTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-03 and MAL-05, item 145 step 19 (ADR 0057). Two things left no trace in the log: a PIN change in
//  Settings, so a PIN-holder could lock the owner out without a record, and Guided Access ending while the watch was
//  live, the earliest sign of its passcode-holder, given while the phone is still online. Now each is a quiet status
//  entry on the silent audit type, like "disarmed" and "gaLifted": "pinChanged" when Settings' Change PIN saves the
//  new PIN, "guidedAccessEnded" when Guided Access goes from on to off while the watch is live (not while disarmed,
//  not during the countdown, not for off to on, once per ending), both allow-listed in the cloud decoder, with their
//  log sentences and icons, no alert anywhere. The rigs are trial installs verified on "account-A" with saves landing
//  at once, so the push can be seen land (CloudKit is absent from the Simulator). Written before the change, red at
//  that commit (against compile-only stubs). Item 162's G1 (1.8.2's step 21): ChangePINView's call was checked in its
//  source; Change PIN's save and its record are now one engine step (`changePIN`), driven here, red at its commit too.
//

import XCTest
import UIKit
@testable import Malinois

@MainActor
final class Item153StatusRecordsTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let cloud: CloudExfiltrator
        let enrollment: CloudEnrollment
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Records")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A trial install verified on "account-A" whose saves land at once; Guided Access not required, no grace unless asked.
    /// `review`: the calibration review's length, for a test that acts during it (the fast timing holds it 0.1 s).
    private func makeRig(grace: Int = 0, review: TimeInterval? = nil) async -> Rig {
        let root = EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("enrollment-153/state.json"),
                                         authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "account-A" }
        cloud.saveAttemptForTesting = { _ in }
        let settings = AppSettings()
        settings.gracePeriodSeconds = grace
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        var timing = EngineCharacterizationTests.fastTiming
        if let review { timing.calibrationReview = review }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing, thermalState: { .nominal }))
        let enrolled = await cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled, "the verification succeeded")
        await engine.cloudAccessVerified()
        return Rig(engine: engine, store: store, cloud: cloud, enrollment: enrollment)
    }

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        let live = await waitFor({ rig.engine.state == .armed }, timeout: 5)
        XCTAssertTrue(live, "grace 0 + calibration + review reach .armed", file: file, line: line)
    }

    private func records(_ rig: Rig, _ kind: String) -> [Event] {
        rig.store.events.filter { $0.stateChange == kind }
    }

    private func stateEvent(_ kind: String) -> Event {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [])
        event.stateChange = kind
        return event
    }

    /// Waits for `condition`, yielding the main actor meanwhile (the push under test runs only while this awaits).
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    // MARK: - A PIN change

    /// A change saved in Settings leaves one "pinChanged" status entry: Change PIN saves through the engine, which
    /// records the change as it saves it (item 162's G1).
    func testAPINChangeWritesOneRecord() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.engine.changePIN(to: "4821", save: { _ in true }), "saved")
        let written = records(rig, "pinChanged")
        XCTAssertEqual(written.count, 1, "one record")
        XCTAssertTrue(written.first?.isStateChange == true, "a status entry, not an event")
    }

    /// A save that fails changes nothing and records nothing; Change PIN's pad then asks again.
    func testAFailedPINSaveWritesNoRecord() async {
        let rig = await makeRig()
        XCTAssertFalse(rig.engine.changePIN(to: "4821", save: { _ in false }), "not saved")
        XCTAssertTrue(records(rig, "pinChanged").isEmpty, "nothing changed, nothing recorded")
    }

    /// Change PIN saves in the Keychain unless told otherwise: the new PIN then opens the pads, and the change is on
    /// the record.
    func testChangePINSavesTheNewPINInTheKeychain() async throws {
        defer { KeychainService.wipeStalePINData() }
        try XCTSkipUnless(KeychainService.setPIN("1111"), "Keychain unavailable")
        let rig = await makeRig()
        XCTAssertTrue(rig.engine.changePIN(to: "4821"), "saved")
        XCTAssertTrue(KeychainService.verify("4821"), "the new PIN opens the pads")
        XCTAssertEqual(records(rig, "pinChanged").count, 1, "on the record")
    }

    // MARK: - Guided Access ending during a watch

    /// Guided Access going from on to off while the watch is live leaves one "guidedAccessEnded" status entry, pushed
    /// to iCloud like the other audit records, and the watch keeps running.
    func testGuidedAccessEndingDuringAWatchWritesOneRecordAndPushesIt() async {
        let rig = await makeRig()
        rig.engine.simulateGuidedAccessForTesting(on: true)
        await arm(rig)
        rig.engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertEqual(records(rig, "guidedAccessEnded").count, 1, "one record")
        XCTAssertEqual(rig.engine.state, .armed, "the watch keeps running")
        let synced = await waitFor({ self.records(rig, "guidedAccessEnded").first?.cloudSyncState == .synced }, timeout: 5)
        XCTAssertTrue(synced, "pushed: \(String(describing: records(rig, "guidedAccessEnded").first?.cloudSyncState))")
        rig.engine.disarm()
    }

    /// No record while disarmed, and none during the countdown: those are the owner's.
    func testNoRecordWhileDisarmedOrDuringTheCountdown() async {
        let rig = await makeRig(grace: 5)
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertTrue(records(rig, "guidedAccessEnded").isEmpty, "disarmed: nothing")
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming, "the countdown")
        rig.engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertTrue(records(rig, "guidedAccessEnded").isEmpty, "the countdown: nothing")
        rig.engine.cancelArming()
    }

    /// Off to on records nothing; each ending records once, and a re-sample with the same value nothing.
    func testOffToOnRecordsNothingAndEachEndingRecordsOnce() async {
        let rig = await makeRig()
        rig.engine.simulateGuidedAccessForTesting(on: false)
        await arm(rig)
        rig.engine.simulateGuidedAccessForTesting(on: true)
        XCTAssertTrue(records(rig, "guidedAccessEnded").isEmpty, "off to on: nothing")
        rig.engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertEqual(records(rig, "guidedAccessEnded").count, 1, "the first ending")
        rig.engine.simulateGuidedAccessForTesting(on: false)
        rig.engine.refreshGuidedAccess()
        XCTAssertEqual(records(rig, "guidedAccessEnded").count, 1, "the same value again: nothing")
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertEqual(records(rig, "guidedAccessEnded").count, 2, "the second ending")
        rig.engine.disarm()
    }

    // MARK: - The records

    /// Both read as plain sentences in the log.
    func testTheRecordsReadAsPlainSentences() {
        XCTAssertEqual(stateEvent("pinChanged").sensorSummary,
                       "Malinois PIN changed in Settings; the current PIN was entered first")
        XCTAssertEqual(stateEvent("guidedAccessEnded").sensorSummary,
                       "Guided Access ended while armed; the watch kept running")   // item 155's A7: Face ID can end it too
    }

    /// Both have their own icon in the log, one iOS has.
    func testTheRecordsHaveTheirOwnIconsInTheLog() {
        let pin = EventRow.placeholderIcon(for: "pinChanged")
        XCTAssertEqual(pin, "key.fill")
        XCTAssertNotNil(UIImage(systemName: pin), "an SF Symbol this iOS has")
        let ended = EventRow.placeholderIcon(for: "guidedAccessEnded")
        XCTAssertEqual(ended, "lock.trianglebadge.exclamationmark")
        XCTAssertNotNil(UIImage(systemName: ended), "an SF Symbol this iOS has")
    }

    /// The owner's other devices read both back from iCloud: the decoder's allow-list admits the kinds.
    func testTheOwnersOtherDevicesReadTheRecordsBack() {
        for kind in ["pinChanged", "guidedAccessEnded"] {
            let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
            XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind, kind)
        }
    }

    /// No alert anywhere: iCloud sends no disarm alert for either, and the watch relay sends nothing.
    func testTheRecordsRaiseNoAlertOnAnotherDeviceOrTheWatch() {
        for kind in ["pinChanged", "guidedAccessEnded"] {
            XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: kind), "no disarm alert through iCloud: \(kind)")
        }
        let events = [stateEvent("pinChanged"), stateEvent("guidedAccessEnded")]
        XCTAssertTrue(WatchAlertRelay.alerts(for: events, alertsOn: true, proActive: true).isEmpty, "nothing relayed")
    }

    // MARK: - Item 155's A6 (step 23): the calibration review is live too

    /// Codex's P7. Guided Access ends during the six-second calibration review, when the sensors already watch: one
    /// record, once; reaching armed and a later re-sample add none. Red at the step's red commit: the record came
    /// only while armed or triggered.
    func testGuidedAccessEndingDuringTheCalibrationReviewIsRecorded() async {
        let rig = await makeRig(review: 2)   // long enough to act in, short enough to reach armed (item 168's deepseek-flash-2)
        defer { rig.engine.disarm() }
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        let reviewing = await waitFor({ rig.engine.showingCalibrationReview }, timeout: 5)
        XCTAssertTrue(reviewing, "the review is showing")
        XCTAssertEqual(rig.engine.state, .calibrating)
        XCTAssertNotNil(rig.engine.armedSince, "the sensors are live")
        rig.engine.simulateGuidedAccessForTesting(on: false)
        XCTAssertEqual(records(rig, "guidedAccessEnded").count, 1, "recorded during the review")
        _ = await waitFor({ rig.engine.state == .armed }, timeout: 5)
        rig.engine.refreshGuidedAccess()
        XCTAssertEqual(records(rig, "guidedAccessEnded").count, 1, "once")
    }
}
