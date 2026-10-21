//
//  Item129F3F4T1Tests.swift
//  MalinoisTests
//
//  BACKLOG 129 (Codex's full review of 1.7 (70), 2026-10-17): the findings the owner put in 1.8.
//  F3: a trip that landed during a capture was folded into whichever response finished next,
//  even one left over from an earlier armed session, and cleared from the event it belonged to.
//  F4: downloading full evidence from iCloud attached media without the media byte limit's
//  pass, so downloads could leave the phone over the limit until the next event or merge.
//  T1: the engine read the camera permission from iOS even with a test's fake camera, so seven
//  tests failed on a fresh simulator, whose camera had never been asked for.
//  Rewritten from Codex's probes (`_REVIEW_NOTES_codex/probes/`) as the project's tests. Named for its findings:
//  1.7.1's own `Item129ReviewTests` holds F1 and F2, and the two files meet when 1.7.1 is merged into 1.8.
//

import AVFoundation
import XCTest
@testable import Malinois

@MainActor
final class Item129F3F4T1Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem129F3F4T1")
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

    // MARK: - F3: a trip during a capture stays with its own session's event

    /// Touch, Power and the camera; one still per trigger; no delay before the watch goes live;
    /// the camera cold between captures.
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

    /// The control: a Power trip while the session's own still is being taken joins that event,
    /// on the phone and in its upload (34-review M1).
    func testATripDuringACaptureJoinsThatCapturesEvent() async throws {
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
        engine.handleTrip(.power)
        camera.releaseStills()
        let finished = await waitUntil(timeout: 4) { engine.state == .armed && pushed[id] != nil }
        XCTAssertTrue(finished, "the capture finishes and uploads")
        let saved = try XCTUnwrap(store.events.first { $0.id == id })
        XCTAssertEqual(Set(saved.triggeredSensors), [.touch, .power])
        XCTAssertEqual(Set(try XCTUnwrap(pushed[id]).triggeredSensors), [.touch, .power])
    }

    /// A response from the first watch is still saving when the owner disarms and arms again. A
    /// Power trip during the new watch's capture belongs to the new event: the old response, which
    /// finishes first, must not take it, and the new event must keep it, on the phone and in both
    /// uploads.
    func testATripDuringANewSessionsCaptureStaysWithThatSession() async throws {
        let (engine, camera, store) = sensorRig()
        let oldStored = expectation(description: "the first watch's media is saved and its response held")
        var releaseOld: CheckedContinuation<Void, Never>?
        var oldID: UUID?
        var pushed: [UUID: Event] = [:]
        engine.captureStoredForTesting = { id in
            oldID = id
            await withCheckedContinuation {
                releaseOld = $0
                oldStored.fulfill()
            }
        }
        engine.evidencePushForTesting = { event in
            pushed[event.id] = event
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        defer {
            releaseOld?.resume()
            camera.releaseStills()
            engine.captureStoredForTesting = nil
            engine.evidencePushForTesting = nil
            engine.disarm()
        }
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitUntil(timeout: 4, { engine.state == .armed }) else { return XCTFail("the first watch did not arm") }
        engine.handleTrip(.touch)
        await fulfillment(of: [oldStored], timeout: 5)
        let oldEventID = try XCTUnwrap(oldID)
        engine.captureStoredForTesting = nil

        engine.disarm()
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitUntil(timeout: 4, { engine.state == .armed }) else { return XCTFail("the second watch did not arm") }
        XCTAssertEqual(store.events.filter { $0.stateChange == "armed" }.count, 2, "two separate watches")
        camera.holdStills = true
        let stillsBefore = camera.stills.count
        engine.handleTrip(.touch)
        guard await waitUntil(timeout: 4, { camera.stills.count > stillsBefore }) else {
            return XCTFail("the second watch's capture did not start")
        }
        let newEventID = try XCTUnwrap(store.events.first { !$0.isStateChange && $0.id != oldEventID }?.id)
        engine.handleTrip(.power)   // lands during the second watch's capture

        releaseOld?.resume()
        releaseOld = nil
        let oldFinished = await waitUntil(timeout: 4) { pushed[oldEventID] != nil }
        XCTAssertTrue(oldFinished, "the first watch's response finishes while the second capture is still held")
        XCTAssertNil(pushed[newEventID], "the second capture has not finished yet")
        let savedOld = try XCTUnwrap(store.events.first { $0.id == oldEventID })
        XCTAssertEqual(Set(savedOld.triggeredSensors), [.touch],
                       "the first watch's event must not take the second watch's Power trip")
        XCTAssertEqual(Set(try XCTUnwrap(pushed[oldEventID]).triggeredSensors), [.touch])

        camera.releaseStills()
        let newFinished = await waitUntil(timeout: 4) { engine.state == .armed && pushed[newEventID] != nil }
        XCTAssertTrue(newFinished, "the second capture finishes and uploads")
        let savedNew = try XCTUnwrap(store.events.first { $0.id == newEventID })
        XCTAssertEqual(Set(savedNew.triggeredSensors), [.touch, .power],
                       "the second watch's event keeps its own Power trip")
        XCTAssertEqual(Set(try XCTUnwrap(pushed[newEventID]).triggeredSensors), [.touch, .power])
    }

    // MARK: - F4: downloads are held to the media byte limit

    /// A still as iCloud hands it over: four bytes that start like a JPEG.
    private func stillFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem129-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Three of another phone's records, held here without media, each downloaded in full: three
    /// 4-byte stills against an 8-byte limit. The limit's pass must run after the downloads, as it
    /// does after a new event or a merge, and bring the referenced media back under the limit.
    func testDownloadedEvidenceIsHeldToTheMediaByteLimit() async throws {
        let store = EventStore()
        store.mediaBudgetForTesting = 8
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let now = Date()
        let mirrors = (0..<3).map { index in
            Event(startDate: now.addingTimeInterval(Double(-index)), endDate: now,
                  triggeredSensors: [.motion], cloudSyncState: .synced,
                  sourceDevice: "iPhone Air", cloudRevision: 2)
        }
        var passes = 0
        store.mediaMeasuredForTesting = { passes += 1 }
        defer { store.mediaMeasuredForTesting = nil; store.drainIOForTesting() }
        store.merge(mirrors)
        await waitUntil(timeout: 4) { passes > 0 }
        XCTAssertGreaterThan(passes, 0, "the merge's own pass ran before any media arrived")
        let passesBeforeDownloads = passes
        let file = try stillFile()
        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front",
                                                                                  fileURL: file)],
                                            complete: true)
        }
        for mirror in mirrors {
            let result = await engine.downloadFullEvidence(for: mirror.id)
            XCTAssertTrue(result.landed)
        }
        func referencedBytes() -> Int {
            store.drainIOForTesting()
            return store.events.compactMap(\.mediaFilename).reduce(0) { total, name in
                total + ((try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(name)))?.count ?? 0)
            }
        }
        await waitUntil(timeout: 4) { passes > passesBeforeDownloads && referencedBytes() <= 8 }
        XCTAssertGreaterThan(passes, passesBeforeDownloads, "the limit's pass runs after the downloads")
        XCTAssertLessThanOrEqual(referencedBytes(), 8, "the downloads leave the media under the limit")
    }

    // MARK: - T1: the camera permission is the camera's answer, not the simulator's

    /// The engine reads the camera permission from its camera, so a test's fake decides it,
    /// whatever the simulator has been granted (seven tests failed on a fresh simulator, never
    /// asked). Never asked: the ARM tap warms nothing and says how to allow the camera. Denied: it
    /// says so. Allowed: the camera warms and nothing is said.
    func testTheArmTapReadsTheCameraPermissionFromItsCamera() async {
        let cases: [(permission: AVAuthorizationStatus, notice: String?, warms: Bool)] = [
            (.notDetermined, "The camera hasn't been allowed yet", false),
            (.denied, "Camera access is denied", true),
            (.authorized, nil, true),
        ]
        for (permission, notice, warms) in cases {
            let settings = AppSettings()
            settings.gracePeriodSeconds = 0
            settings.requireGuidedAccess = false
            settings.enabledSensors.insert(.camera)
            settings.cameraReadiness = .instant   // the camera warms at the ARM tap
            let camera = FakeCamera()
            camera.videoPermission = permission
            let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                              cloud: CloudExfiltrator(), camera: camera,
                                                              entitlements: ProEntitlements(resolvedAs: .trial),
                                                              timing: EngineCharacterizationTests.fastTiming))
            engine.beginArming()
            // The warm-up is decided at the tap; only an allowed or denied camera starts one.
            if warms { await waitUntil(timeout: 4) { !camera.warmUps.isEmpty } }
            XCTAssertEqual(!camera.warmUps.isEmpty, warms, "warm-up, camera \(permission.rawValue)")
            if let notice {
                XCTAssertTrue(engine.cameraNotice?.hasPrefix(notice) == true,
                              "camera \(permission.rawValue): \(String(describing: engine.cameraNotice))")
            } else {
                XCTAssertNil(engine.cameraNotice, "camera \(permission.rawValue)")
            }
            engine.cancelArming()
        }
    }
}
