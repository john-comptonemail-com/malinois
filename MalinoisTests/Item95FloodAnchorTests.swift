//
//  Item95FloodAnchorTests.swift
//  MalinoisTests
//
//  BACKLOG 95 (found 2026-09-29 by the review of item 94). A flood's onset record is its anchor,
//  and the engine kept its own copy of it. When the onset's capture failed for an interruption,
//  item 54's one retry attached the photo to the STORED record once the camera came back, but
//  the next coalesced trip extended the engine's old copy and wrote it back whole: the photo
//  reference was erased, and the launch sweep deleted the file. The coalescer now works on the
//  stored record. The review of that fix found the same pattern in the retry itself: it held
//  the record across its capture and wrote that copy back, walking back the trips coalesced
//  meanwhile. It now attaches the photo to the record as it is when the photo lands.
//

import XCTest
@testable import Malinois

@MainActor
final class Item95FloodAnchorTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem95")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeRig() -> Rig {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sustainedIdleClear = 10     // the flood outlasts every step of a test
        timing.floodCaptureInterval = 60   // and no cadence still takes the camera from the retry
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.captureMode = .photo
        settings.cameraPosition = .front
        let camera = FakeCamera()
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera,
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        return Rig(engine: engine, camera: camera, store: store)
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func record(_ id: UUID?, in rig: Rig) -> Event? {
        rig.store.events.first { $0.id == id }
    }

    /// Arms, makes ten ordinary trips, then the flood's onset, whose still fails while the
    /// session is interrupted, so item 54 parks its one retry. Returns the anchor's id.
    private func floodWithAFailedOnset(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) -> UUID? {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "armed", file: file, line: line)
        for _ in 0..<MonitoringEngine.floodTripThreshold {
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3), file: file, line: line)
        }
        rig.camera.stillError = CameraController.CameraError.captureFailed
        rig.camera.interruptionReasonValue = .background
        rig.engine.handleTrip(.motion)
        let onset = { rig.store.events.first { !$0.isStateChange && $0.sustainedCount != nil && $0.captureFailure != nil } }
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && onset() != nil }, timeout: 3),
                      "the onset's record, its capture failed", file: file, line: line)
        XCTAssertNil(onset()?.mediaFilename, file: file, line: line)
        XCTAssertEqual(onset()?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue, file: file, line: line)
        rig.camera.stillError = nil
        rig.camera.interruptionReasonValue = nil
        return onset()?.id
    }

    /// The retry attaches a photo when the camera comes back, and a coalesced trip after it
    /// keeps the photo on the anchor.
    func testARetriedPhotoOnTheFloodAnchorSurvivesTheNextCoalescedTrip() {
        let rig = makeRig()
        let anchor = floodWithAFailedOnset(rig)
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.mediaFilename != nil }, timeout: 3),
                      "the retry attached a photo")
        let photo = record(anchor, in: rig)?.mediaFilename

        rig.engine.handleTrip(.motion)   // the flood goes on
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.sustainedCount == 2 }, timeout: 3),
                      "the trip was coalesced")
        XCTAssertEqual(record(anchor, in: rig)?.mediaFilename, photo, "the photo is still on the record")
        XCTAssertEqual(record(anchor, in: rig)?.primaryCamera, "front")
        rig.engine.disarm()
    }

    /// Trips coalesced while the retry's still is being taken stay counted: the photo joins the
    /// record as it is when the photo lands.
    func testTripsCoalescedDuringTheRetrysCaptureStayOnTheAnchor() {
        let rig = makeRig()
        let anchor = floodWithAFailedOnset(rig)
        let stillsBefore = rig.camera.stills.count
        rig.camera.holdStills = true
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == stillsBefore + 1 }, timeout: 3),
                      "the retry's still is being taken")
        for count in 2...4 {
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.sustainedCount == count }, timeout: 3),
                          "a trip coalesced while the retry's still was held")
        }
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.mediaFilename != nil }, timeout: 3),
                      "the retry's photo landed")
        XCTAssertEqual(record(anchor, in: rig)?.sustainedCount, 4, "the three trips are still counted")
        rig.engine.disarm()
    }
}
