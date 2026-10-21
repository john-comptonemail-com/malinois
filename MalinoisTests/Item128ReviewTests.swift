//
//  Item128ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 128: Codex's review of 1.8 (72) at 3e3d77d (2026-10-18). V1: a settings reset removed the damaged
//  settings and left the recovered ones to the 0.4-second autosave, so a relaunch inside that window started from
//  the defaults, iCloud backup on again. V2: a "Both" capture whose front failed lost its download offer once the
//  storage limit removed its rear photo, the only one it had. V3: media attached after an event was recorded (its
//  capture, a retry, a late file, a recovery) was held to the media byte limit only at the next event or merge.
//

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item128ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem128Review")
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

    // MARK: - V1: the reset's settings are stored at once

    private static let settingsKey = "com.malinois.settings"

    /// Runs `body` with `blob` as the stored settings, then puts back what was there and removes the stash the
    /// reset leaves (item 124's helper).
    private func withStoredSettings(_ blob: String, _ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.data(forKey: Self.settingsKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Self.settingsKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.settingsKey) }
            UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(Self.settingsKey + ".corrupt-") }
                .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        UserDefaults.standard.set(Data(blob.utf8), forKey: Self.settingsKey)
        try body()
    }

    /// The app is killed right after a reset, before the settings' 0.4-second autosave: the next launch reads what
    /// the reset stored, not the defaults. Backup stays off, readable alerts stay as they were.
    func testARelaunchRightAfterAResetKeepsTheResetsICloudChoices() {
        let cases: [(blob: String, alerts: Bool)] = [
            (#"{"gracePeriodSeconds":"not a number","cloudBackup":false,"notifyOtherDevices":false}"#, false),
            ("not json at all", true),
        ]
        for (blob, alerts) in cases {
            withStoredSettings(blob) {
                let reset = AppSettings.load()   // the reset, at launch
                XCTAssertFalse(reset.cloudBackup, blob)
                let relaunched = AppSettings.load()   // the next launch; no run loop turn, so no autosave ran
                XCTAssertFalse(relaunched.cloudBackup, "iCloud backup on again after a relaunch: \(blob)")
                XCTAssertEqual(relaunched.notifyOtherDevices, alerts, "cross-device alerts after a relaunch: \(blob)")
            }
        }
    }

    // MARK: - V2: a rear-only capture keeps its download offer

    private static let offer = "Download full evidence from iCloud"

    /// The rule alone: this iPhone's uploaded capture known only by its second camera's name.
    func testAnUploadedCaptureKnownOnlyByItsSecondCameraCanBeInICloud() {
        let rearOnly = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], secondaryCamera: "rear",
                             cloudSyncState: .synced)
        XCTAssertTrue(rearOnly.fullCaptureMayBeInICloud)
        let neverUploaded = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], secondaryCamera: "rear",
                                  cloudSyncState: .localOnly)
        XCTAssertFalse(neverUploaded.fullCaptureMayBeInICloud, "guard: a capture that never uploaded has no copy")
    }

    /// Through the engine: with "Both", the front camera fails and the rear photo is kept as the second capture,
    /// with no thumbnail. It uploads; the storage limit later removes the photo from the phone. The event detail
    /// still offers the download, as the copy is in iCloud.
    func testABothCaptureWhoseFrontFailedStillOffersItsDownloadAfterTheStorageLimit() async throws {
        let settings = AppSettings()
        settings.enabledSensors = [.touch, .camera]
        settings.captureMode = .photo
        settings.cameraPosition = .both
        settings.cameraReadiness = .batterySaver
        settings.responseMode = .stealth
        settings.illumination = .off
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let camera = FakeCamera()
        camera.supportsMultiCam = true
        camera.omittedBothCameras = ["front"]
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera, entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        var pushed: [UUID: Event] = [:]
        engine.evidencePushForTesting = { event in
            pushed[event.id] = event
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        defer { engine.evidencePushForTesting = nil }
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitUntil(timeout: 4, { engine.state == .armed }) else { return XCTFail("the watch did not arm") }
        engine.handleTrip(.touch)
        guard await waitUntil(timeout: 4, { store.events.contains { !$0.isStateChange } }) else {
            return XCTFail("the trip recorded no event")
        }
        let id = try XCTUnwrap(store.events.first { !$0.isStateChange }?.id)
        let uploaded = await waitUntil(timeout: 4) {
            engine.state == .armed && pushed[id] != nil && store.events.first { $0.id == id }?.cloudSyncState == .synced
        }
        XCTAssertTrue(uploaded, "the capture uploads")
        let captured = try XCTUnwrap(store.events.first { $0.id == id })
        XCTAssertNil(captured.mediaFilename, "the front photo failed")
        XCTAssertNotNil(captured.secondaryMediaFilename, "the rear photo is the second capture")
        XCTAssertEqual(captured.secondaryCamera, "rear")
        XCTAssertNil(captured.thumbnailData, "only a first capture makes the thumbnail")

        store.mediaBudgetForTesting = 0   // the storage limit, at its tightest
        engine.disarm()                   // its "disarmed" entry runs the limit's pass
        let removed = await waitUntil(timeout: 4) { store.events.first { $0.id == id }?.secondaryMediaFilename == nil }
        XCTAssertTrue(removed, "the limit removes the uploaded photo from the phone")
        let pruned = try XCTUnwrap(store.events.first { $0.id == id })
        XCTAssertTrue(pruned.fullCaptureMayBeInICloud, "the rear photo is in iCloud")
        let shown = try shownOnScreen(NavigationStack { EventDetailView(event: pruned) }
            .environmentObject(store)
            .environmentObject(engine)
            .environmentObject(entitlements)).shown
        XCTAssertTrue(shown.contains(Self.offer), "no download offer for the uploaded rear photo: \(shown)")
    }

    // MARK: - V3: media is held to the byte limit as it lands

    /// A still as iCloud hands it over: four bytes that start like a JPEG.
    private func stillFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem128-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Two of another phone's photos, 4 bytes each, fill an 8-byte limit. A trip's still (4 bytes) lands after the
    /// pass its event's birth ran: the limit's pass runs again once the capture is attached, and the oldest synced
    /// photo goes. Before, the 12 bytes stayed until the next event.
    func testACapturesMediaIsHeldToTheByteLimitOnceItLands() async throws {
        let settings = AppSettings()
        settings.enabledSensors = [.touch, .camera]
        settings.captureMode = .photo
        settings.cameraPosition = .front
        settings.cameraReadiness = .batterySaver
        settings.responseMode = .stealth
        settings.illumination = .off
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let camera = FakeCamera()
        let store = EventStore()
        store.mediaBudgetForTesting = 8
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera, entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        defer { store.drainIOForTesting() }
        func referencedBytes() -> Int {
            store.drainIOForTesting()
            return store.events.flatMap { [$0.mediaFilename, $0.secondaryMediaFilename].compactMap { $0 } }
                .reduce(0) { total, name in
                    total + ((try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(name)))?.count ?? 0)
                }
        }
        // Another phone's two photos, downloaded: 8 bytes, the limit exactly.
        let earlier = Date().addingTimeInterval(-3_600)
        let mirrors = (0..<2).map { index in
            Event(startDate: earlier.addingTimeInterval(Double(-index)), endDate: earlier, triggeredSensors: [.motion],
                  cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 2)
        }
        store.merge(mirrors)
        let file = try stillFile()
        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front",
                                                                                  fileURL: file)],
                                            complete: true)
        }
        for mirror in mirrors {
            let landed = await engine.downloadFullEvidence(for: mirror.id).landed
            XCTAssertTrue(landed)
        }
        await waitUntil(timeout: 2) { referencedBytes() == 8 }
        XCTAssertEqual(referencedBytes(), 8, "the two photos fill the limit")

        var pushed: [UUID: Event] = [:]
        engine.evidencePushForTesting = { event in
            pushed[event.id] = event
            return .init(syncState: .synced, metaFailureWasInterference: nil)
        }
        defer { camera.releaseStills(); engine.evidencePushForTesting = nil }
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        guard await waitUntil(timeout: 4, { engine.state == .armed }) else { return XCTFail("the watch did not arm") }
        camera.holdStills = true
        engine.handleTrip(.touch)
        // The event's birth runs a pass while its still is held, and nothing is over the limit yet. Every pass
        // owed so far ends before the still is let go, so none of them can be the one that keeps the limit.
        guard await waitUntil(timeout: 4, { store.events.contains { !$0.isStateChange && $0.sourceDevice == nil } }) else {
            return XCTFail("the trip recorded no event")
        }
        let id = try XCTUnwrap(store.events.first { !$0.isStateChange && $0.sourceDevice == nil }?.id)
        let quiet = await waitUntil(timeout: 4) { !camera.stills.isEmpty && store.byteCapPruneIdleForTesting }
        XCTAssertTrue(quiet, "the birth's pass ended while the still was held")
        XCTAssertEqual(referencedBytes(), 8)
        camera.releaseStills()
        let finished = await waitUntil(timeout: 4) { engine.state == .armed && pushed[id] != nil }
        XCTAssertTrue(finished, "the capture finishes and uploads")
        XCTAssertNotNil(store.events.first { $0.id == id }?.mediaFilename, "the still is attached")
        await waitUntil(timeout: 4) { referencedBytes() <= 8 }
        XCTAssertLessThanOrEqual(referencedBytes(), 8, "the capture's still left the phone over the limit")
    }
}
