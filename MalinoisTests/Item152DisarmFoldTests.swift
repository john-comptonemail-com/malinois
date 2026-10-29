//
//  Item152DisarmFoldTests.swift
//  MalinoisTests
//
//  BACKLOG 152's lead 14 (1.8.2's step 24; the owner's ruling (a)). Trips that land while a capture is running are folded
//  into that capture's record when it finishes (34-review M1). A disarm before the capture ended cleared them, so the
//  record lost the tripwires that fired during it, though SECURITY.md promises the record names every tripwire that
//  fired. They are now kept through a disarm, as wrong PINs typed during a capture already were (item 49); a new
//  watch's trips stay with the new watch (item 129's F3, `Item129F3F4T1Tests`). Written before the change, red at that
//  commit.
//

import XCTest
@testable import Malinois

@MainActor
final class Item152DisarmFoldTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152DisarmFold")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    /// Touch, Power and the camera; one still per trigger; no delay before the watch goes live.
    private func sensorRig() -> (engine: MonitoringEngine, camera: FakeCamera, store: EventStore) {
        let settings = AppSettings()
        settings.enabledSensors = [.touch, .camera, .power]
        settings.captureMode = .photo
        settings.cameraPosition = .front
        settings.cameraReadiness = .batterySaver
        settings.responseMode = .stealth
        settings.illumination = .off
        settings.jammingResponse = false
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let camera = FakeCamera()
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: camera,
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, camera, store)
    }

    /// Lead 14: a Power trip while the still is being taken, then the owner disarms before the capture ends. The record
    /// must still name Power, on the phone and in its upload.
    func testATripDuringACaptureStaysOnTheRecordAcrossADisarm() async throws {
        let (engine, camera, store) = sensorRig()
        var pushed: [UUID: Event] = [:]
        engine.evidencePushForTesting = { event in
            pushed[event.id] = event
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        defer {
            camera.releaseStills()
            engine.evidencePushForTesting = nil
            engine.disarm()
        }
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitUntil(timeout: 4, { engine.state == .armed }) else { return XCTFail("the watch did not arm") }
        camera.holdStills = true
        engine.handleTrip(.touch)
        guard await waitUntil(timeout: 4, { !camera.stills.isEmpty }) else { return XCTFail("the capture did not start") }
        let id = try XCTUnwrap(store.events.first { !$0.isStateChange }?.id)
        engine.handleTrip(.power)   // lands during the capture
        engine.disarm()             // before the capture ends
        XCTAssertEqual(engine.state, .disarmed)
        camera.releaseStills()
        let finished = await waitUntil(timeout: 4) { pushed[id] != nil }
        XCTAssertTrue(finished, "the capture finishes and uploads after the disarm")
        let saved = try XCTUnwrap(store.events.first { $0.id == id })
        XCTAssertEqual(Set(saved.triggeredSensors), [.touch, .power], "Power stays on the record")
        XCTAssertEqual(Set(try XCTUnwrap(pushed[id]).triggeredSensors), [.touch, .power], "and in its upload")
    }
}
