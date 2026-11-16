//
//  Item237ThumbnailCameraTests.swift
//  MalinoisTests
//
//  BACKLOG item 237's second half (1.13, item 240's list; docs/design/1.13-fixes.md, part 4b; the owner, 2026-11-12:
//  "as you recommend, wording approved": D5 (a), W5: no new words) and item 227's Codex-2. Another device's record from
//  before 1.2 (31) names no cameras; its thumbnail came from one camera. A download that brings only the other camera's
//  photo puts it in the first, unnamed place and names that place after its camera; once the storage limit removed the
//  file, the old thumbnail showed under the other camera's name. Now the event notes that its thumbnail's camera is not
//  known, in the download and in the merge that carries a downloaded file into a newer copy, and no write-back from
//  before takes the note away; the screen then names no camera over that thumbnail when it stands in for a missing file.
//  Through the engine's own download and the store's merge, with real pictures, and the screen laid out for real.
//  Written before the fix, red at that commit (where nothing sets the note, and the screen ignores it).
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item237ThumbnailCameraTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem237Thumb")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The download and the merge

    /// A download names the first, unnamed place after the rear photo it brings, while the record's thumbnail came with no
    /// camera named: the event notes that its thumbnail's camera is not known.
    func testADownloadNamingAnUnnamedPlaceOverAnOlderThumbnailMarksItsCameraNotKnown() async throws {
        let rig = makeRig()
        let mirror = merged(rig, thumbnail: try Self.jpeg(width: 16, height: 12, colour: .red))
        try iCloudHands(rig, camera: "rear")
        let result = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertTrue(result.landed)
        let after = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertEqual(after.primaryCamera, "rear", "the place takes the file's camera")
        XCTAssertEqual(after.thumbnailData, mirror.thumbnailData, "the old thumbnail stays")
        XCTAssertEqual(after.thumbnailCameraUnknown, true, "its camera not known")
    }

    /// A guard, green before the fix and after: a download into a place with no thumbnail gives the record its file's own
    /// thumbnail, whose camera is the file's.
    func testADownloadIntoAPlaceWithNoThumbnailTakesTheFilesOwn() async throws {
        let rig = makeRig()
        let mirror = merged(rig, thumbnail: nil)
        try iCloudHands(rig, camera: "rear")
        _ = await rig.engine.downloadFullEvidence(for: mirror.id)
        let after = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertNotNil(after.thumbnailData, "the file's own thumbnail")
        XCTAssertNil(after.thumbnailCameraUnknown)
    }

    /// A newer copy of the record from iCloud with no thumbnail of its own, carrying the downloaded file into its place,
    /// keeps the note with the thumbnail it keeps.
    func testANewerCopyCarryingTheDownloadedFileKeepsTheCameraNotKnown() async throws {
        let rig = makeRig()
        let thumbnail = try Self.jpeg(width: 16, height: 12, colour: .red)
        let mirror = merged(rig, thumbnail: thumbnail)
        try iCloudHands(rig, camera: "rear")
        _ = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertEqual(rig.store.events.first { $0.id == mirror.id }?.thumbnailCameraUnknown, true, "noted by the download")
        let newer = Event(id: mirror.id, startDate: mirror.startDate, endDate: mirror.endDate, triggeredSensors: [.motion],
                          cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 3)
        rig.store.merge([newer])
        let after = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertEqual(after.cloudRevision, 3, "the newer copy taken")
        XCTAssertNotNil(after.mediaFilename, "the downloaded file carried")
        XCTAssertEqual(after.primaryCamera, "rear")
        XCTAssertEqual(after.thumbnailData, thumbnail, "the thumbnail kept")
        XCTAssertEqual(after.thumbnailCameraUnknown, true, "the note carried")
    }

    /// A newer copy naming the first place's camera itself: the thumbnail's camera is known again from the record, the
    /// note goes, and the downloaded file takes its own camera's place.
    func testANewerCopyNamingTheFirstCameraClearsTheNote() async throws {
        let rig = makeRig()
        let thumbnail = try Self.jpeg(width: 16, height: 12, colour: .red)
        let mirror = merged(rig, thumbnail: thumbnail)
        try iCloudHands(rig, camera: "rear")
        _ = await rig.engine.downloadFullEvidence(for: mirror.id)
        XCTAssertEqual(rig.store.events.first { $0.id == mirror.id }?.thumbnailCameraUnknown, true, "noted by the download")
        let newer = Event(id: mirror.id, startDate: mirror.startDate, endDate: mirror.endDate, triggeredSensors: [.motion],
                          thumbnailData: thumbnail, primaryCamera: "front", cloudSyncState: .synced,
                          sourceDevice: "iPhone Air", cloudRevision: 3)
        rig.store.merge([newer])
        let after = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertEqual(after.primaryCamera, "front")
        XCTAssertNil(after.thumbnailCameraUnknown, "its camera known from the record")
        XCTAssertEqual(after.secondaryCamera, "rear", "the downloaded file in its own camera's place")
        XCTAssertNotNil(after.secondaryMediaFilename)
    }

    /// A newer copy naming no camera, over a place whose name came from the older copy and whose file was downloaded: the
    /// merge names the place after the file, and notes the newer copy's thumbnail's camera not known.
    func testANewerCopyNamingNoCameraOverItsThumbnailMarksItsCameraNotKnown() async throws {
        let rig = makeRig()
        let thumbnail = try Self.jpeg(width: 16, height: 12, colour: .red)
        let at = Date().addingTimeInterval(-600)
        let named = Event(startDate: at, endDate: at, triggeredSensors: [.motion], thumbnailData: thumbnail,
                          primaryCamera: "rear", cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 2)
        rig.store.merge([named])
        try iCloudHands(rig, camera: "rear")
        _ = await rig.engine.downloadFullEvidence(for: named.id)
        XCTAssertNil(rig.store.events.first { $0.id == named.id }?.thumbnailCameraUnknown, "the record named the camera")
        let newer = Event(id: named.id, startDate: at, endDate: at, triggeredSensors: [.motion], thumbnailData: thumbnail,
                          cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 3)
        rig.store.merge([newer])
        let after = try XCTUnwrap(rig.store.events.first { $0.id == named.id })
        XCTAssertEqual(after.primaryCamera, "rear", "named after the file")
        XCTAssertEqual(after.thumbnailCameraUnknown, true, "the newer copy's thumbnail came with no camera named")
    }

    /// A guard: a newer copy with no thumbnail, naming no camera, over a place the older copy named: the merge names the
    /// place after the downloaded file, and the thumbnail it keeps came with that name, so no note.
    func testANewerCopyWithNoThumbnailOverANamedPlaceAddsNoNote() async throws {
        let rig = makeRig()
        let thumbnail = try Self.jpeg(width: 16, height: 12, colour: .red)
        let at = Date().addingTimeInterval(-600)
        let named = Event(startDate: at, endDate: at, triggeredSensors: [.motion], thumbnailData: thumbnail,
                          primaryCamera: "rear", cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 2)
        rig.store.merge([named])
        try iCloudHands(rig, camera: "rear")
        _ = await rig.engine.downloadFullEvidence(for: named.id)
        let newer = Event(id: named.id, startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .synced,
                          sourceDevice: "iPhone Air", cloudRevision: 3)
        rig.store.merge([newer])
        let after = try XCTUnwrap(rig.store.events.first { $0.id == named.id })
        XCTAssertEqual(after.primaryCamera, "rear")
        XCTAssertEqual(after.thumbnailData, thumbnail, "the older copy's thumbnail kept")
        XCTAssertNil(after.thumbnailCameraUnknown)
    }

    /// A write-back of a copy from before the note does not take it away.
    func testAWriteBackFromBeforeTheNoteKeepsIt() async throws {
        let rig = makeRig()
        let mirror = merged(rig, thumbnail: try Self.jpeg(width: 16, height: 12, colour: .red))
        try iCloudHands(rig, camera: "rear")
        _ = await rig.engine.downloadFullEvidence(for: mirror.id)
        var stale = try XCTUnwrap(rig.store.events.first { $0.id == mirror.id })
        XCTAssertEqual(stale.thumbnailCameraUnknown, true, "noted by the download")
        stale.thumbnailCameraUnknown = nil
        rig.store.update(stale)
        XCTAssertEqual(rig.store.events.first { $0.id == mirror.id }?.thumbnailCameraUnknown, true)
    }

    // MARK: - The screen

    /// The file gone, the thumbnail standing in for it: no camera named over it, and the thumbnail's own words stay.
    func testTheScreenNamesNoCameraOverTheThumbnailOnceTheFileIsGone() async throws {
        let rig = makeRig()
        let event = try added(rig, file: false, cameraNotKnown: true)
        let shown = try await shownOnScreen(screen(rig, event), until: { $0.contains(EvidenceMediaView.thumbnailOnly) }).shown
        XCTAssertTrue(shown.contains(EvidenceMediaView.thumbnailOnly), "the thumbnail stands in: \(shown)")
        XCTAssertFalse(shown.contains("Rear camera"), "no camera named over it: \(shown)")
    }

    /// A guard, green before the fix and after: while the file is here, its camera is named over it.
    func testTheScreenNamesTheCameraWhileItsFileIsHere() async throws {
        let rig = makeRig()
        let event = try await addedWithFile(rig)
        let shown = try await shownOnScreen(screen(rig, event), until: { $0.contains("Rear camera") }).shown
        XCTAssertTrue(shown.contains("Rear camera"), "\(shown)")
    }

    /// A guard, green before the fix and after: an ordinary record's thumbnail, standing in for its file, keeps its camera.
    func testAnOrdinaryThumbnailKeepsItsCamera() async throws {
        let rig = makeRig()
        let event = try added(rig, file: false, cameraNotKnown: false, camera: "front")
        let shown = try await shownOnScreen(screen(rig, event), until: { $0.contains(EvidenceMediaView.thumbnailOnly) }).shown
        XCTAssertTrue(shown.contains("Front camera"), "\(shown)")
    }

    /// The note is not evidence: a label for the screen, on this phone's copies.
    func testTheNoteIsNotEvidence() {
        XCTAssertNotNil(Event.notEvidenceFields["thumbnailCameraUnknown"])
    }

    // MARK: - Helpers

    private struct Rig {
        let store: EventStore
        let engine: MonitoringEngine
        let entitlements: ProEntitlements
    }

    private func makeRig() -> Rig {
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        addTeardownBlock { @MainActor in store.drainIOForTesting() }
        return Rig(store: store, engine: engine, entitlements: entitlements)
    }

    /// Another device's record from before 1.2 (31), held here without its photos: no camera named.
    private func merged(_ rig: Rig, thumbnail: Data?) -> Event {
        let at = Date().addingTimeInterval(-600)
        let mirror = Event(startDate: at, endDate: at, triggeredSensors: [.motion], thumbnailData: thumbnail,
                           cloudSyncState: .synced, sourceDevice: "iPhone Air", cloudRevision: 2)
        rig.store.merge([mirror])
        return mirror
    }

    /// iCloud's answer to the download: one photo, saved under `camera`'s name.
    private func iCloudHands(_ rig: Rig, camera: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem237-\(UUID().uuidString).jpg")
        try Self.jpeg(width: 40, height: 30, colour: .blue).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: camera, camera: camera, fileURL: url)],
                                            complete: true)
        }
    }

    /// A record of this phone's with a thumbnail and its first place named `camera`, its file not here.
    private func added(_ rig: Rig, file: Bool, cameraNotKnown: Bool, camera: String = "rear") throws -> Event {
        let at = Date().addingTimeInterval(-600)
        var event = Event(startDate: at, endDate: at, triggeredSensors: [.motion],
                          thumbnailData: try Self.jpeg(width: 16, height: 12, colour: .red), primaryCamera: camera,
                          cloudSyncState: .synced)
        if cameraNotKnown { event.thumbnailCameraUnknown = true }
        rig.store.add(event)
        return event
    }

    /// The same, with the rear photo's file here and the note set.
    private func addedWithFile(_ rig: Rig) async throws -> Event {
        let stored = await rig.store.store(.still(try Self.jpeg(width: 40, height: 30, colour: .blue)), ext: "jpg")
        let at = Date().addingTimeInterval(-600)
        var event = Event(startDate: at, endDate: at, triggeredSensors: [.motion],
                          mediaFilename: try XCTUnwrap(stored?.filename),
                          thumbnailData: try Self.jpeg(width: 16, height: 12, colour: .red), primaryCamera: "rear",
                          cloudSyncState: .synced)
        event.thumbnailCameraUnknown = true
        rig.store.add(event)
        return event
    }

    private func screen(_ rig: Rig, _ event: Event) -> some View {
        NavigationStack { EventDetailView(event: event) }
            .environmentObject(rig.store).environmentObject(rig.engine).environmentObject(rig.entitlements)
    }

    /// A real JPEG of one colour.
    private static func jpeg(width: Int, height: Int, colour: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }
}
