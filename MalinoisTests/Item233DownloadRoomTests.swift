//
//  Item233DownloadRoomTests.swift
//  MalinoisTests
//
//  BACKLOG item 233's (b) (1.13, item 240's list; docs/design/1.13-fixes.md, part 2; the owner, 2026-11-12: "as you
//  recommend, wording approved": D3 (a), W1). "Download full evidence from iCloud" saved the photo or clip and the size
//  limit then ran at once, so a large download could push out older photos and clips, the last copies wherever the
//  retention setting has since removed iCloud's; a face or finger can start one. Now a capture a download brings is added
//  only if it fits within the limit with the photos and clips the log names, measured again if a capture was saved
//  while they were measured; one that does not fit is not added, nothing is removed, the rest of the download goes on,
//  and the event's screen says so (W1), not that nothing came back. Through the engine's own download, with iCloud's
//  answer stood in for and a small budget; the screen laid out for real. Written before the fix, red at that commit
//  (where nothing yet measures, and every capture is added as before).
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item233DownloadRoomTests: XCTestCase {
    private static let download = "Download full evidence from iCloud"
    private static let nothingNote = "Nothing came back - the full capture may not be in iCloud, or iCloud isn't reachable."
    private static let incompleteNote = "A capture downloaded, but not everything could be checked - try again for the rest."

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem233")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Through the engine's download

    /// A guard, green before the fix and after: a capture that fits, to the byte, is added, and nothing is removed.
    func testADownloadThatFitsIsAddedAndNothingIsRemoved() async throws {
        let rig = makeRig(budget: 16)
        let older = try await savedPhoto(rig, bytes: 8, minutesAgo: 60)
        let mirror = merged(rig, cameras: ["front"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 8))])
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertTrue(result.landed)
        XCTAssertFalse(result.noRoom)
        await settle(rig)
        XCTAssertNotNil(rig.store.events.first { $0.id == mirror.id }?.mediaFilename, "added")
        XCTAssertTrue(hasFile(older, rig), "the older photo stays")
    }

    /// A capture that would take the photos and clips over the limit is not added; nothing is removed, and its file does
    /// not stay behind; the download is not incomplete for it.
    func testADownloadThatWouldGoOverIsNotAddedAndNothingIsRemoved() async throws {
        let rig = makeRig(budget: 16)
        let older = try await savedPhoto(rig, bytes: 12, minutesAgo: 60)
        let mirror = merged(rig, cameras: ["front"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 8))])
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertTrue(result.noRoom, "no room")
        XCTAssertFalse(result.landed)
        XCTAssertTrue(result.complete, "its slot was checked: nothing to try again for")
        await settle(rig)
        XCTAssertNil(rig.store.events.first { $0.id == mirror.id }?.mediaFilename, "not added")
        XCTAssertTrue(hasFile(older, rig), "nothing removed to make room")
        XCTAssertEqual(try photosOnThePhone(rig), [try XCTUnwrap(older.mediaFilename)], "the refused file does not stay")
    }

    /// One camera's capture does not fit, the other's does: the one that fits lands, the rest of the download goes on.
    func testAnotherCamerasPhotoThatFitsStillLands() async throws {
        let rig = makeRig(budget: 16)
        let older = try await savedPhoto(rig, bytes: 8, minutesAgo: 60)
        let mirror = merged(rig, cameras: ["front", "rear"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 12)), ("rear", try photoFile(bytes: 6))])
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertTrue(result.landed, "the rear's photo")
        XCTAssertTrue(result.noRoom, "the front's did not fit")
        XCTAssertTrue(result.complete)
        await settle(rig)
        let after = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertNil(after.mediaFilename, "the front's not added")
        XCTAssertNotNil(after.secondaryMediaFilename, "the rear's added")
        XCTAssertTrue(hasFile(older, rig), "nothing removed")
    }

    /// The first camera's capture fits and the second's, measured with it, does not: the second is not added.
    func testTheSecondCamerasPhotoThatDoesNotFitIsNotAdded() async throws {
        let rig = makeRig(budget: 16)
        let older = try await savedPhoto(rig, bytes: 8, minutesAgo: 60)
        let mirror = merged(rig, cameras: ["front", "rear"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 6)), ("rear", try photoFile(bytes: 12))])
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertTrue(result.landed, "the front's photo")
        XCTAssertTrue(result.noRoom, "the rear's did not fit")
        await settle(rig)
        let after = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertNotNil(after.mediaFilename, "the front's added")
        XCTAssertNil(after.secondaryMediaFilename, "the rear's not added")
        XCTAssertTrue(hasFile(older, rig), "nothing removed")
    }

    /// Captures saved through every measure: the room is not known, so the capture is not added and waits for another try,
    /// as an unchecked slot does; the download does not say there is no room.
    func testCapturesSavedThroughEveryMeasureLeaveTheCaptureForAnotherTry() async throws {
        let rig = makeRig(budget: 1_000)
        let mirror = merged(rig, cameras: ["front"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 8))])
        var saved = 0
        rig.store.downloadMeasuredForTesting = { [unowned self] in
            saved += 1
            _ = try? await self.savedPhoto(rig, bytes: 4, minutesAgo: 0)
        }
        defer { rig.store.downloadMeasuredForTesting = nil }
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertEqual(saved, 3, "measured three times")
        XCTAssertFalse(result.landed)
        XCTAssertFalse(result.noRoom, "not known is not no room")
        XCTAssertFalse(result.complete, "to try again")
        await settle(rig)
        XCTAssertNil(rig.store.events.first { $0.id == mirror.id }?.mediaFilename, "not added")
    }

    /// A capture saved while the files are measured is counted: the download measures again, and does not add a file
    /// that no longer fits.
    func testACaptureSavedWhileTheFilesAreMeasuredIsCounted() async throws {
        let rig = makeRig(budget: 16)
        let older = try await savedPhoto(rig, bytes: 8, minutesAgo: 60)
        let mirror = merged(rig, cameras: ["front"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 8))])
        var saved: Event?
        rig.store.downloadMeasuredForTesting = { [unowned self] in
            guard saved == nil else { return }
            saved = try? await self.savedPhoto(rig, bytes: 4, minutesAgo: 0)   // a trip's photo, saved meanwhile
        }
        defer { rig.store.downloadMeasuredForTesting = nil }
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertNotNil(saved, "the capture was saved while the files were measured")
        XCTAssertTrue(result.noRoom, "measured again, with the capture: 20 bytes would pass 16")
        await settle(rig)
        XCTAssertNil(rig.store.events.first { $0.id == mirror.id }?.mediaFilename, "not added")
        XCTAssertTrue(hasFile(older, rig), "the older photo stays")
        XCTAssertTrue(hasFile(try XCTUnwrap(saved), rig), "the new capture stays")
    }

    // MARK: - The event's screen, laid out for real

    /// "Download full evidence from iCloud" pressed with no room: the screen says so in the owner's words (W1), and not
    /// that nothing came back, nor that the rest is still to get.
    func testTheEventsScreenSaysThereIsNoRoomAndNotThatNothingCameBack() async throws {
        let rig = makeRig(budget: 16)
        _ = try await savedPhoto(rig, bytes: 12, minutesAgo: 60)
        let mirror = merged(rig, cameras: ["front"])
        try iCloudHands(rig, [("front", try photoFile(bytes: 8))])
        let recorder = OnScreenRecorder()
        let screen = NavigationStack { EventDetailView(event: mirror) }
            .environmentObject(rig.store).environmentObject(rig.engine).environmentObject(rig.entitlements)
        try await onScreen(screen, recorder) {
            try await waitUntil("the download offered") { recorder.actions[Self.download] != nil }
            XCTAssertFalse(recorder.shown.contains(EventDetailView.downloadNoRoomNote), "not before any download")
            recorder.actions[Self.download]?()
            try await waitUntil("the screen says there is no room") {
                recorder.shown.contains(EventDetailView.downloadNoRoomNote)
            }
            try await Task.sleep(for: .milliseconds(300))   // the screen settles
            XCTAssertFalse(recorder.shown.contains(Self.nothingNote), "not that nothing came back")
            XCTAssertFalse(recorder.shown.contains(Self.incompleteNote), "not that the rest is still to get")
        }
    }

    /// W1, word for word (the owner's "wording approved", 2026-11-12).
    func testTheWordsAreTheApprovedOnes() {
        XCTAssertEqual(EventDetailView.downloadNoRoomNote,
                       "A capture wasn't downloaded: there isn't room for it on this iPhone. Malinois stores up to 2 GB "
                       + "of photos and clips here, and a download never deletes others to make room.")
    }

    // MARK: - Helpers

    private struct Rig {
        let store: EventStore
        let engine: MonitoringEngine
        let entitlements: ProEntitlements
    }

    private func makeRig(budget: Int64) -> Rig {
        let store = EventStore()
        store.mediaBudgetForTesting = budget
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        addTeardownBlock { @MainActor in store.drainIOForTesting() }
        return Rig(store: store, engine: engine, entitlements: entitlements)
    }

    /// A photo of this phone's, `bytes` long, saved and named by an event `minutesAgo` old that iCloud has: the size
    /// limit would take it first of this phone's own.
    private func savedPhoto(_ rig: Rig, bytes: Int, minutesAgo: Double) async throws -> Event {
        let stored = await rig.store.store(.still(Self.photo(bytes: bytes)), ext: "jpg")
        let name = try XCTUnwrap(stored?.filename, "the photo saved")
        let at = Date().addingTimeInterval(-minutesAgo * 60)
        let event = Event(startDate: at, endDate: at, triggeredSensors: [.touch], mediaFilename: name,
                          primaryCamera: "front", cloudSyncState: .synced)
        rig.store.add(event)
        return event
    }

    /// Another phone's record, held here without its photos, naming `cameras`.
    private func merged(_ rig: Rig, cameras: [String]) -> Event {
        let at = Date().addingTimeInterval(-600)
        let mirror = Event(startDate: at, endDate: at, triggeredSensors: [.motion], primaryCamera: cameras.first,
                           secondaryCamera: cameras.dropFirst().first, cloudSyncState: .synced,
                           sourceDevice: "iPhone Air", cloudRevision: 2)
        rig.store.merge([mirror])
        return mirror
    }

    /// iCloud's answer to the download: each camera's photo, from these files.
    private func iCloudHands(_ rig: Rig, _ files: [(camera: String, url: URL)]) throws {
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: files.map {
                CloudExfiltrator.FetchedMedia(slot: $0.camera, camera: $0.camera, fileURL: $0.url)
            }, complete: true)
        }
    }

    /// A photo's bytes, `bytes` long: a JPEG's first bytes and its last two.
    private static func photo(bytes: Int) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x5A, count: max(0, bytes - 6)) + Data([0xFF, 0xD9])
    }

    /// A photo as iCloud hands it over, in a file of its own.
    private func photoFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem233-\(UUID().uuidString).jpg")
        try Self.photo(bytes: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Waits until no pass of the size limit runs or is owed, and the store's files are written and removed.
    private func settle(_ rig: Rig) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        try? await Task.sleep(for: .milliseconds(100))
        while !rig.store.byteCapPruneIdleForTesting, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        rig.store.drainIOForTesting()
    }

    private func hasFile(_ event: Event, _ rig: Rig) -> Bool {
        guard let name = event.mediaFilename,
              rig.store.events.first(where: { $0.id == event.id })?.mediaFilename == name else { return false }
        return FileManager.default.fileExists(atPath: rig.store.mediaDirectory.appendingPathComponent(name).path)
    }

    /// The photos in the store's media folder, by name.
    private func photosOnThePhone(_ rig: Rig) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: rig.store.mediaDirectory.path).filter { $0.hasSuffix(".jpg") }
    }

    /// Lays `view` out in a window the size of a 17 Pro's screen, `recorder` reading it, while `body` runs.
    private func onScreen<V: View>(_ view: V, _ recorder: OnScreenRecorder, _ body: () async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body()
    }

    /// Lets the main run loop turn until `condition` holds; after ten seconds, fails the test, naming what it waited for.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("waited ten seconds: \(what)")
                throw TimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct TimedOut: Error {
    let what: String
}
