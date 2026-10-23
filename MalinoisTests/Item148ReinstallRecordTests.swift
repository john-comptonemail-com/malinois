//
//  Item148ReinstallRecordTests.swift
//  MalinoisTests
//
//  BACKLOG 148's point 5, item 145 step 9 (the owner's "do the small items", 2026-10-21). A reinstall is recognised at
//  launch (a PIN survived in the Keychain while the setup flag did not; the owner then resumes with that PIN, or
//  resets it), but the new log said nothing about the old one being gone. Now the finished recovery notes that a
//  record is owed, when no earlier log survived either, and the record "Malinois was reinstalled on this iPhone: the
//  log it kept before is gone" is written once: at the first successful Verify iCloud access, tied to the verified
//  account so that with Pro it uploads and the owner's other devices see it, or at the first watch if that comes
//  first, when it stays on this phone. A damaged credential (`.lostHash`) and a fresh install owe nothing. The rigs
//  are free installs, so no record leaves for CloudKit (absent from the Simulator); the account binding is read from
//  the enrollment, which decides whether a record may upload. RootView's call is checked in its source: a real
//  reinstall needs the real Keychain (a TestFlight check). Written before the change, red at that commit (against
//  compile-only stubs).
//

import XCTest
import UIKit
@testable import Malinois

@MainActor
final class Item148ReinstallRecordTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let cloud: CloudExfiltrator
        let enrollment: CloudEnrollment
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem148Reinstall")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// A free install whose iCloud verification would succeed for "account-A".
    private func makeRig() -> Rig {
        let root = EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("enrollment-148/state.json"),
                                         authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "account-A" }
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        return Rig(engine: engine, store: store, cloud: cloud, enrollment: enrollment)
    }

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while rig.engine.state != .armed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(rig.engine.state, .armed, "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    private func verify(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async {
        let enrolled = await rig.cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled, "the verification succeeded", file: file, line: line)
        await rig.engine.cloudAccessVerified()
    }

    private func reinstallRecords(_ rig: Rig) -> [Event] {
        rig.store.events.filter { $0.stateChange == "reinstalled" }
    }

    private var owed: Bool { UserDefaults.standard.bool(forKey: MonitoringEngine.reinstallRecordOwedKey) }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    // MARK: - The rule

    /// Owed only for a recognised reinstall: a surviving PIN without its setup flag, and no earlier log either.
    func testOnlyARecognisedReinstallOwesTheRecord() {
        XCTAssertTrue(MonitoringEngine.reinstallRecordOwed(recovery: .lostSetupFlag, priorLocalEvidence: false),
                      "a PIN survived; the setup flag and the log did not")
        XCTAssertFalse(MonitoringEngine.reinstallRecordOwed(recovery: .lostSetupFlag, priorLocalEvidence: true),
                       "the log survived: the record's words would be false")
        XCTAssertFalse(MonitoringEngine.reinstallRecordOwed(recovery: .lostHash, priorLocalEvidence: false),
                       "a damaged credential, not a reinstall")
        XCTAssertFalse(MonitoringEngine.reinstallRecordOwed(recovery: .lostHash, priorLocalEvidence: true))
        XCTAssertFalse(MonitoringEngine.reinstallRecordOwed(recovery: nil, priorLocalEvidence: false), "a fresh install")
    }

    /// The finished recovery notes the debt for a reinstall and for nothing else.
    func testTheFinishedRecoveryNotesTheDebtOnlyForAReinstall() {
        let rig = makeRig()
        rig.engine.noteRecoveryFinished(.lostHash, priorLocalEvidence: false)
        XCTAssertFalse(owed)
        rig.engine.noteRecoveryFinished(nil, priorLocalEvidence: false)
        XCTAssertFalse(owed)
        rig.engine.noteRecoveryFinished(.lostSetupFlag, priorLocalEvidence: true)
        XCTAssertFalse(owed)
        rig.engine.noteRecoveryFinished(.lostSetupFlag, priorLocalEvidence: false)
        XCTAssertTrue(owed)
    }

    // MARK: - When it is written

    /// Verified first: the record is written at the verification, tied to the verified account (with Pro it uploads,
    /// and the owner's other devices see it), and only once.
    func testAtVerificationTheRecordIsTiedToTheVerifiedAccount() async {
        let rig = makeRig()
        rig.engine.noteRecoveryFinished(.lostSetupFlag, priorLocalEvidence: false)
        await verify(rig)
        XCTAssertEqual(reinstallRecords(rig).count, 1)
        if let record = reinstallRecords(rig).first {
            XCTAssertNil(rig.enrollment.uploadHoldReason(for: record), "tied to the verified account: it may upload")
        }
        XCTAssertFalse(owed, "the debt is paid")
        await rig.engine.cloudAccessVerified()
        XCTAssertEqual(reinstallRecords(rig).count, 1, "never twice")
    }

    /// The first watch comes before any verification: the record is written then, before the watch's "armed" record,
    /// held on this phone (tied to no account), and only once.
    func testAtTheFirstWatchOfAnUnverifiedInstallTheRecordStaysOnThisPhone() async {
        let rig = makeRig()
        rig.engine.noteRecoveryFinished(.lostSetupFlag, priorLocalEvidence: false)
        await arm(rig)
        XCTAssertEqual(reinstallRecords(rig).count, 1)
        if let record = reinstallRecords(rig).first, let armed = rig.store.events.first(where: { $0.stateChange == "armed" }) {
            XCTAssertLessThanOrEqual(record.startDate, armed.startDate, "written before the watch's armed record")
            XCTAssertEqual(rig.enrollment.uploadHoldReason(for: record), .unknownAccount, "held on this phone")
        }
        rig.engine.disarm()
        await arm(rig)
        XCTAssertEqual(reinstallRecords(rig).count, 1, "never twice")
        rig.engine.disarm()
    }

    /// Verified, then a watch: one record, written at the verification.
    func testVerificationThenAWatchWritesOneRecord() async {
        let rig = makeRig()
        rig.engine.noteRecoveryFinished(.lostSetupFlag, priorLocalEvidence: false)
        await verify(rig)
        await arm(rig)
        XCTAssertEqual(reinstallRecords(rig).count, 1, "never both")
        rig.engine.disarm()
    }

    /// A fresh install owes nothing: no record at the verification or at the first watch.
    func testAFreshInstallWritesNoRecord() async {
        let rig = makeRig()
        await verify(rig)
        await arm(rig)
        XCTAssertTrue(reinstallRecords(rig).isEmpty)
        rig.engine.disarm()
    }

    // MARK: - The record

    /// The record reads as a plain sentence in the log.
    func testTheRecordReadsAsAPlainSentence() {
        XCTAssertEqual(stateEvent("reinstalled").sensorSummary,
                       "Malinois was reinstalled on this iPhone: the log it kept before is gone")
    }

    /// The record has its own icon in the log, one iOS has.
    func testTheRecordHasItsOwnIconInTheLog() {
        let icon = EventRow.placeholderIcon(for: "reinstalled")
        XCTAssertEqual(icon, "arrow.down.app")
        XCTAssertNotNil(UIImage(systemName: icon), "an SF Symbol this iOS has")
    }

    /// The owner's other devices read the record back from iCloud.
    func testTheOwnersOtherDevicesReadTheRecordBack() {
        let record = CloudExfiltrator.makeStateRecord(stateEvent("reinstalled"), kind: "reinstalled", deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "reinstalled")
    }

    /// No alert anywhere: iCloud sends no disarm alert for it, and the watch relay sends nothing.
    func testTheRecordRaisesNoAlertOnAnotherDeviceOrTheWatch() {
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "reinstalled"), "no disarm alert through iCloud")
        XCTAssertTrue(WatchAlertRelay.alerts(for: [stateEvent("reinstalled")], alertsOn: true, proActive: true).isEmpty,
                      "nothing relayed to the watch")
    }

    // MARK: - The launch

    /// RootView tells the engine which recovery finished, before it reads the next one.
    func testRootViewNotesTheFinishedRecovery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Malinois/Views/RootView.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func finishRecovery() {"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            return XCTFail("RootView's finishRecovery was not found")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        guard let note = body.range(of: "engine.noteRecoveryFinished(recovery)") else {
            return XCTFail("finishRecovery does not tell the engine which recovery finished")
        }
        let next = try XCTUnwrap(body.range(of: "recovery = KeychainService.pendingRecovery"))
        XCTAssertLessThan(note.lowerBound, next.lowerBound, "noted before the next recovery is read")
    }
}
