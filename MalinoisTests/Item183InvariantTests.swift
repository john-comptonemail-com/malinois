//
//  Item183InvariantTests.swift
//  MalinoisTests
//
//  BACKLOG item 183's 7 (the owner, 2026-11-04: "drafts approved; add tests"): the public README names, under each of
//  its invariants, the tests that pin it, and two parts had no test of their own. "PIN keys are not touch trips": while
//  the disarm pad is up, the armed screen holds no Touch layer under it, so no key reaches the tripwire. "Without Pro,
//  Malinois itself sends none of your events off the phone": a free install's watch, trip and disarm stay on this
//  phone, and nothing so much as looks up the iCloud account. Both on the real armed screen and the real engine.
//  Item 195 (the owner, 2026-11-05: "3 a") found a third: "If that write fails, the response still goes ahead and Home
//  reports the failure": with neither the journal nor the log written, a trip is still answered, with the flags Home
//  shows up; and on a disk that refuses the capture too, the record says so and the watch goes on.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item183InvariantTests: XCTestCase {
    private static let touchLayer = "Touch tripwire"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem183Invariants")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// An engine with its own settings, store, cloud sender and camera, answering the Pro check with `status`.
    private func engine(_ status: ProEntitlements.Status, camera: FakeCamera = FakeCamera())
        -> (engine: MonitoringEngine, settings: AppSettings, store: EventStore, cloud: CloudExfiltrator) {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.captureMode = .photo
        settings.cameraPosition = .front
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: camera,
                                                          entitlements: ProEntitlements(resolvedAs: status),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, settings, store, cloud)
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

    /// Arms through grace (0 s), calibration and its review, to `.armed`.
    private func arm(_ engine: MonitoringEngine, file: StaticString = #filePath, line: UInt = #line) {
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.state == .armed }, timeout: 5), "armed", file: file, line: line)
    }

    /// "PIN keys are not touch trips": the armed screen's Touch layer, which turns a press into a Touch trip, is not
    /// on screen while the disarm pad is up, so a key the owner types lands on the pad and nowhere else; when the pad
    /// closes, the layer is back.
    func testWhileThePINPadIsUpTheArmedScreenHasNoTouchLayer() throws {
        let (engine, settings, _, _) = engine(.trial)
        arm(engine)
        let armed = ArmedView().environmentObject(engine).environmentObject(settings)
            .environmentObject(CameraController())
        XCTAssertTrue(try shownOnScreen(armed).shown.contains(Self.touchLayer), "the armed screen's Touch layer")
        engine.beginDisarmEntry()
        XCTAssertTrue(pump(until: { engine.disarmEntryActive }, timeout: 3), "the pad opened")
        let withThePad = try shownOnScreen(armed).shown
        XCTAssertTrue(withThePad.contains("Enter PIN to disarm"), "the pad is on screen: \(withThePad)")
        XCTAssertFalse(withThePad.contains(Self.touchLayer), "no Touch layer under the PIN pad's keys: \(withThePad)")
        engine.endDisarmEntry()
        XCTAssertTrue(pump(until: { !engine.disarmEntryActive }, timeout: 3), "the pad closed")
        XCTAssertTrue(try shownOnScreen(armed).shown.contains(Self.touchLayer), "the Touch layer is back")
        engine.disarm()
    }

    /// An armed free install on a store that can write neither its journal nor its log, with both flags Home shows up,
    /// for `body`; they are still up after it. A folder where the journal file goes fails every append, as in
    /// Item73RegressionTests, and a closed store folder refuses the log's replacement, as in Item165ReviewTests.
    /// `captureFoldersOpen`: the capture's own folders are made first, and only the record's writes are refused.
    private func onAStoreThatRefusesTheRecord(captureFoldersOpen: Bool,
                                              _ body: (MonitoringEngine, EventStore, FakeCamera) -> Void) throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("events.journal"), withIntermediateDirectories: true)
        let camera = FakeCamera()
        let (engine, _, store, _) = engine(.free, camera: camera)
        if captureFoldersOpen {
            _ = store.mediaDirectory
            try files.createDirectory(at: root.appendingPathComponent("MediaAttachments"), withIntermediateDirectories: true)
        }
        let permissions = try XCTUnwrap(files.attributesOfItem(atPath: root.path)[.posixPermissions])
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? files.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        arm(engine)
        XCTAssertTrue(pump(until: { store.journalDegraded && store.persistDegraded }, timeout: 5),
                      "neither write landed: journal \(store.journalDegraded), log \(store.persistDegraded)")
        body(engine, store, camera)
        XCTAssertTrue(store.journalDegraded, "Home still says the journal cannot be written")
        XCTAssertTrue(store.persistDegraded, "Home still says the log cannot be written")
        engine.disarm()
    }

    /// "If that write fails, the response still goes ahead and Home reports the failure": with neither the journal nor
    /// the log written, a trip is still answered: the camera takes its still, and the record holds it in memory, where
    /// the disk refused the log.
    func testATripWhoseRecordCannotBeWrittenStillResponds() throws {
        try onAStoreThatRefusesTheRecord(captureFoldersOpen: true) { engine, store, camera in
            engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: {
                engine.state == .armed && store.events.contains { !$0.isStateChange && $0.mediaFilename != nil }
            }, timeout: 5), "the trip is answered, its still on its record")
            XCTAssertEqual(camera.stills.count, 1, "the camera took it")
        }
    }

    /// The same on a disk that refuses the capture too, as a full one does: the camera still answers, the record says
    /// the capture could not be stored and names no still the disk did not keep, and the watch goes on.
    func testATripOnAStoreThatCanWriteNothingStillEndsAndTheWatchGoesOn() throws {
        try onAStoreThatRefusesTheRecord(captureFoldersOpen: false) { engine, store, camera in
            engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: {
                engine.state == .armed && store.events.contains {
                    !$0.isStateChange && $0.captureFailure == CaptureFailureReason.storageFailed.rawValue
                }
            }, timeout: 5), "the record says why it has no still, and the watch goes on")
            XCTAssertEqual(camera.stills.count, 1, "the camera took it")
            XCTAssertNil(store.events.first { !$0.isStateChange }?.mediaFilename, "no still the disk did not keep")
        }
    }

    /// "Without Pro, Malinois itself sends none of your events off the phone": a free install arms, records a trip
    /// with its still and disarms, and every record stays on this phone (local only). The trip's evidence push is
    /// never asked for, the pending-upload sweep hands nothing out, and nothing looks up the iCloud account, which
    /// every upload, fact push and status record's push does first.
    /// Synchronous, as the engine's other arming tests are: an async test's run loop does not run the main actor's
    /// queued work while it spins, and the arm never comes.
    func testAFreeInstallsRecordsStayOnThePhone() {
        let (engine, _, store, cloud) = engine(.free)
        var lookups = 0
        cloud.accountIdentityForTesting = {
            lookups += 1
            return "an-account"
        }
        var evidencePushes = 0
        engine.evidencePushForTesting = { _ in
            evidencePushes += 1
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        var sweepUploads = 0
        engine.sweepUploadForTesting = { _ in
            sweepUploads += 1
            return (state: .synced, transient: nil)
        }
        arm(engine)
        engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: {
            engine.state == .armed && store.events.contains { !$0.isStateChange && $0.mediaFilename != nil }
        }, timeout: 5), "the trip is recorded with its still")
        engine.disarm()
        let swept = TestFlag()
        Task {
            await engine.retryPendingSync()
            swept.value = true
        }
        XCTAssertTrue(pump(until: { swept.value }, timeout: 5), "the pending-upload sweep returned")
        let settled = pump(until: {
            !store.events.isEmpty && store.events.allSatisfy { $0.cloudSyncState == .localOnly }
        }, timeout: 5)
        let states = store.events.map { "\($0.stateChange ?? "incident"): \($0.cloudSyncState)" }
        XCTAssertTrue(settled, "every record stays on this phone: \(states)")
        XCTAssertTrue(store.events.contains { $0.stateChange == "armed" }, "the watch's own records: \(states)")
        XCTAssertTrue(store.events.contains { $0.stateChange == "disarmed" }, "the disarm: \(states)")
        XCTAssertEqual(evidencePushes, 0, "no upload of the trip's evidence is asked for without Pro")
        XCTAssertEqual(sweepUploads, 0, "the pending-upload sweep runs only with Pro")
        XCTAssertEqual(lookups, 0, "nothing looks up the iCloud account without Pro")
    }
}
