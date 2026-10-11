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

    private func makeRig(cadenceInterval: TimeInterval = 60, retryWindow: TimeInterval = 120,
                         readiness: CameraReadiness = .auto) -> Rig {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sustainedIdleClear = 10     // the flood outlasts every step of a test
        timing.floodCaptureInterval = cadenceInterval
        timing.captureRetryWindow = retryWindow
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.captureMode = .photo
        settings.cameraPosition = .front
        settings.cameraReadiness = readiness
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

    /// Start a real flood-cadence capture and deliver the end notification while it owns
    /// the camera. No second notification is needed when that capture eventually releases it.
    private func holdCadenceOverRetry(_ rig: Rig) {
        rig.camera.holdStills = true
        let count = rig.camera.stills.count
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == count + 1 }, timeout: 3))
        rig.camera.onSessionEvent?(.interruptionEnded)
        pump(until: { false }, timeout: 0.1)
        XCTAssertEqual(rig.camera.stills.count, count + 1, "the retry must yield while busy")
    }

    func testBusyCadencePreservesRetryUntilCameraIsFree() {
        let rig = makeRig(cadenceInterval: 0)
        let anchor = floodWithAFailedOnset(rig)
        let count = rig.camera.stills.count
        holdCadenceOverRetry(rig)
        // Duplicate callbacks must neither consume the deferred slot nor multiply it.
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.1)
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.mediaFilename != nil }, timeout: 3),
                      "camera release must retry the original incident without another notification")
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.2)
        XCTAssertEqual(rig.camera.stills.count, count + 2, "one cadence still and exactly one retry")
        XCTAssertEqual(record(anchor, in: rig)?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
        rig.engine.disarm()
    }

    func testTriggerRacingWithEndNotificationPreservesRetry() {
        let rig = makeRig()
        let anchor = floodWithAFailedOnset(rig)
        let count = rig.camera.stills.count
        rig.camera.holdStills = true
        rig.camera.onSessionEvent?(.interruptionEnded)
        // The notification queues the retry; this trigger owns the camera before it runs.
        rig.engine.noteWrongDisarmPIN()
        XCTAssertTrue(pump(until: { rig.camera.stills.count == count + 1 }, timeout: 3))
        XCTAssertEqual(rig.engine.state, .triggered)
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.mediaFilename != nil }, timeout: 3))
        XCTAssertEqual(rig.camera.stills.count, count + 2)
        rig.engine.disarm()
    }

    func testDeferredRetryDoesNotCrossDisarmAndReplacementWatch() {
        let rig = makeRig(cadenceInterval: 0)
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let count = rig.camera.stills.count
        rig.engine.disarm()
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5))
        rig.camera.releaseStills()
        rig.camera.onSessionEvent?(.interruptionEnded)
        pump(until: { false }, timeout: 0.4)
        XCTAssertEqual(rig.camera.stills.count, count)
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        rig.engine.disarm()
    }

    func testDeferredRetryExpiresWhileCameraRemainsBusy() {
        let rig = makeRig(cadenceInterval: 0, retryWindow: 0.4)
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let count = rig.camera.stills.count
        pump(until: { false }, timeout: 0.5)
        rig.camera.releaseStills()
        rig.camera.onSessionEvent?(.interruptionEnded)
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.stills.count, count)
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        rig.engine.disarm()
    }

    func testDeferredRetryWaitsForANewerInterruptionToEnd() {
        let rig = makeRig(cadenceInterval: 0)
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let count = rig.camera.stills.count
        rig.camera.onSessionEvent?(.interrupted(.background))
        rig.camera.releaseStills()
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.stills.count, count, "a newer interruption still owns the camera")
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.mediaFilename != nil }, timeout: 3))
        XCTAssertEqual(rig.camera.stills.count, count + 1)
        rig.engine.disarm()
    }

    func testDisablingCameraWhileRetryIsParkedDiscardsTheAttempt() throws {
        let rig = makeRig(cadenceInterval: 0, readiness: .batterySaver)
        defer { rig.camera.releaseStills(); rig.engine.disarm() }
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let cadence = try XCTUnwrap(rig.store.events.first { !$0.isStateChange && $0.id != anchor && $0.mediaFilename == nil })
        let count = rig.camera.stills.count
        let attempts = rig.camera.attemptBegins

        rig.engine.settings.enabledSensors.remove(.camera)
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { self.record(cadence.id, in: rig)?.mediaFilename != nil }, timeout: 3),
                      "the already-started cadence capture finishes while new capture is disabled")
        pump(until: { false }, timeout: 0.2)
        XCTAssertEqual(rig.camera.attemptBegins, attempts, "the parked retry must not start")

        // Re-enabling capture must not resurrect the discarded incident's retry.
        rig.engine.settings.enabledSensors.insert(.camera)
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.attemptBegins, attempts)
        XCTAssertEqual(rig.camera.stills.count, count)
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        XCTAssertEqual(record(anchor, in: rig)?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
    }

    func testDeferredRetryDeniedPermissionAtWarmUpKeepsFailureAndCannotRepeat() {
        let rig = makeRig(cadenceInterval: 0, readiness: .batterySaver)
        defer { rig.camera.releaseStills(); rig.engine.disarm() }
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let count = rig.camera.stills.count
        let attempts = rig.camera.attemptBegins
        // The cadence has already warmed up. The next attempt encounters revoked permission.
        rig.camera.warmUpError = CameraController.CameraError.unauthorized
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: {
            rig.camera.attemptBegins == attempts + 1 &&
                rig.engine.cameraNotice?.contains("an evidence capture failed") == true
        }, timeout: 3), "the deferred retry reaches warm-up and reports the permission failure")
        XCTAssertEqual(rig.camera.stills.count, count, "denied permission must never reach the shutter")

        rig.camera.warmUpError = nil
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.attemptBegins, attempts + 1, "restoring permission does not grant another attempt")
        XCTAssertEqual(rig.camera.stills.count, count)
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        XCTAssertEqual(record(anchor, in: rig)?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
    }

    func testFailedDeferredAttemptCannotRetryAgain() {
        let rig = makeRig(cadenceInterval: 0)
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let count = rig.camera.stills.count
        // The held cadence already passed FakeCamera's error check. Only the retry fails.
        rig.camera.stillError = CameraController.CameraError.captureFailed
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.camera.stills.count == count + 1 }, timeout: 3))
        pump(until: { false }, timeout: 0.2)
        rig.camera.stillError = nil
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.stills.count, count + 1, "a failed retry still spends the single attempt")
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        rig.engine.disarm()
    }

    func testLatestInterruptedIncidentReplacesTheDeferredSlot() {
        let rig = makeRig(cadenceInterval: 0)
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        rig.camera.stillError = CameraController.CameraError.captureFailed
        rig.camera.interruptionReasonValue = .background
        rig.camera.onSessionEvent?(.interrupted(.background))
        rig.engine.noteWrongDisarmPIN()
        let newest = { rig.store.events.first { $0.wrongPINCount == 1 } }
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && newest()?.captureFailure != nil }, timeout: 3))
        let count = rig.camera.stills.count
        rig.camera.stillError = nil
        rig.camera.interruptionReasonValue = nil
        rig.camera.onSessionEvent?(.interruptionEnded)
        pump(until: { false }, timeout: 0.1)
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { newest()?.mediaFilename != nil }, timeout: 3))
        XCTAssertEqual(rig.camera.stills.count, count + 1, "only the latest interrupted incident is retried")
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        rig.engine.disarm()
    }

    func testDeferredRetrySkipsAnIncidentThatGainedMedia() throws {
        let rig = makeRig(cadenceInterval: 0)
        let anchor = floodWithAFailedOnset(rig)
        holdCadenceOverRetry(rig)
        let count = rig.camera.stills.count
        var event = try XCTUnwrap(record(anchor, in: rig))
        let existingPhoto = try XCTUnwrap(rig.store.events.compactMap(\.mediaFilename).first)
        event.mediaFilename = existingPhoto
        rig.store.update(event)
        rig.camera.releaseStills()
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.stills.count, count)
        XCTAssertEqual(record(anchor, in: rig)?.mediaFilename, existingPhoto)
        rig.engine.disarm()
    }

    func testReplacementWatchRetryWaitsForOldInFlightRetryAndRunsOnce() throws {
        let rig = makeRig(readiness: .batterySaver)
        defer { rig.camera.releaseStills(); rig.engine.disarm() }
        let anchor = floodWithAFailedOnset(rig)
        rig.camera.holdStills = true
        let count = rig.camera.stills.count
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == count + 1 }, timeout: 3))

        rig.engine.disarm()
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5))
        // Fail only the new watch's first shot; the old held retry can still succeed.
        rig.camera.stillFailuresRemaining = 1
        rig.camera.interruptionReasonValue = .anotherApp
        rig.camera.onSessionEvent?(.interrupted(.anotherApp))
        rig.engine.noteWrongDisarmPIN()
        let newest = { rig.store.events.first { $0.wrongPINCount == 1 } }
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && newest()?.captureFailure != nil }, timeout: 3))
        let replacement = try XCTUnwrap(newest())
        rig.camera.interruptionReasonValue = nil
        let attempts = rig.camera.attemptBegins
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.attemptBegins, attempts, "the old watch's in-flight retry still owns the camera")
        XCTAssertEqual(rig.camera.stills.count, count + 2, "only the old retry and new watch's failed shot started")
        XCTAssertNil(record(anchor, in: rig)?.mediaFilename)
        XCTAssertNil(record(replacement.id, in: rig)?.mediaFilename)

        // Release alone must wake the new watch's pending retry, without another end event.
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: {
            self.record(anchor, in: rig)?.mediaFilename != nil &&
                self.record(replacement.id, in: rig)?.mediaFilename != nil
        }, timeout: 3), "each watch's capture attaches to its own incident")
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.3)
        XCTAssertEqual(rig.camera.attemptBegins, attempts + 1)
        XCTAssertEqual(rig.camera.stills.count, count + 3, "the new incident receives exactly one retry")
        XCTAssertNotEqual(record(anchor, in: rig)?.mediaFilename, record(replacement.id, in: rig)?.mediaFilename)
        XCTAssertEqual(record(anchor, in: rig)?.captureFailure, CaptureFailureReason.interruptedInBackground.rawValue)
        XCTAssertEqual(record(replacement.id, in: rig)?.captureFailure, CaptureFailureReason.interruptedByAnotherApp.rawValue)
    }

    func testOldRetryCompletionDoesNotStandDownReplacementWatchCamera() {
        let rig = makeRig(readiness: .batterySaver)
        let anchor = floodWithAFailedOnset(rig)
        let count = rig.camera.stills.count
        rig.camera.holdStills = true
        rig.camera.onSessionEvent?(.interruptionEnded)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == count + 1 }, timeout: 3))
        // Repeated end notifications while the eligible retry is in flight do not duplicate it.
        for _ in 0..<3 { rig.camera.onSessionEvent?(.interruptionEnded) }
        pump(until: { false }, timeout: 0.1)
        XCTAssertEqual(rig.camera.stills.count, count + 1)
        rig.engine.disarm()
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5))
        pump(until: { false }, timeout: 0.2)
        let shutdowns = rig.camera.shutDowns
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { self.record(anchor, in: rig)?.mediaFilename != nil }, timeout: 3),
                      "evidence from the already-started attempt is still preserved")
        pump(until: { false }, timeout: 0.1)
        XCTAssertEqual(rig.camera.shutDowns, shutdowns, "old completion cannot shut down the replacement watch's camera")
        XCTAssertEqual(rig.camera.stills.count, count + 1)
        rig.engine.disarm()
    }

}
