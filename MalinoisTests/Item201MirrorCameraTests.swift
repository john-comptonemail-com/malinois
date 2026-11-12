//
//  Item201MirrorCameraTests.swift
//  MalinoisTests
//
//  BACKLOG 201 (Codex's Codex-2 in item 198, CONFIRMED by running its test; the owner: "as you recommend"). Another
//  phone's record held here, from before payload v2, has a thumbnail and no camera labels. A download that brings its
//  rear photo alone puts it in the first slot, labelled "rear". When the source phone later writes a newer revision
//  with labels (front first, rear second), the merge kept the file in its position and took the new labels: the rear
//  photo read "Front camera", a retry of the front was skipped, and a retry of the rear filled the second slot with
//  another copy. Now each file goes to the slot the later record gives its camera. Mirrors only: this phone's own
//  records are never replaced by a copy. Written before the fix, red at that commit.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item201MirrorCameraTests: XCTestCase {
    /// The async tests and synchronous tearDown use this on the main thread, in sequence (as Item96DownloadTests).
    nonisolated(unsafe) private var release: CheckedContinuation<Void, Never>?

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem201")
    }

    override func tearDown() {
        release?.resume()
        release = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The merge

    /// Codex's test (item 198, Codex-2): a record from before payload v2, its rear photo downloaded, then the later
    /// revision with labels. The rear photo goes to the rear slot, and the front is still to download.
    func testALaterRecordKeepsADownloadedFilesCamera() throws {
        let id = UUID()
        let thumb = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: thumb)
        defer { try? FileManager.default.removeItem(at: thumb) }
        let old = CKRecord(recordType: "TamperEventMeta")
        old["eventID"] = id.uuidString as CKRecordValue
        old["startDate"] = Date(timeIntervalSince1970: 1_000_000) as CKRecordValue
        old["revision"] = 2 as CKRecordValue
        old["deviceName"] = "Other iPhone" as CKRecordValue
        old["thumbnail"] = CKAsset(fileURL: thumb)
        var held = try XCTUnwrap(CloudExfiltrator.event(from: old))
        XCTAssertTrue(held.isMirrored)
        XCTAssertEqual(MonitoringCloudCoordinator.placement(camera: "rear", slot: "rear", in: held), .primary(setLabel: true),
                       "with no labels, the rear photo takes the first slot")
        held.primaryCamera = "rear"   // as the rear-only download leaves it
        held.mediaFilename = "downloaded-rear.jpg"

        let later = Event(id: id, startDate: held.startDate, endDate: held.endDate, triggeredSensors: [.motion],
                          primaryCamera: "front", secondaryCamera: "rear", sourceDevice: "Other iPhone", cloudRevision: 3,
                          cloudMediaManifest: ["front", "rear"])
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertNil(result.mediaFilename, "the front has not been downloaded")
        XCTAssertEqual(result.secondaryMediaFilename, "downloaded-rear.jpg", "the rear photo in the rear slot")
        XCTAssertEqual(result.primaryCamera, "front")
        XCTAssertEqual(result.secondaryCamera, "rear")
        XCTAssertEqual(MonitoringCloudCoordinator.placement(camera: "front", slot: "front", in: result), .primary(setLabel: false),
                       "the front is still to download")
        XCTAssertEqual(MonitoringCloudCoordinator.placement(camera: "rear", slot: "rear", in: result), .skip,
                       "and a rear retry adds no second copy")
    }

    /// Two files each downloaded into the slot it found unnamed go to the slots the later record gives their cameras.
    func testTwoFilesGoToTheSlotsTheLaterRecordGivesTheirCameras() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "rear.jpg"
        held.primaryCamera = "rear"
        held.secondaryMediaFilename = "front.jpg"
        held.secondaryCamera = "front"
        let later = labelled(held, revision: 3, primary: "front", secondary: "rear")
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertEqual(result.mediaFilename, "front.jpg")
        XCTAssertEqual(result.secondaryMediaFilename, "rear.jpg")
        XCTAssertEqual(result.primaryCamera, "front")
        XCTAssertEqual(result.secondaryCamera, "rear")
    }

    /// A later record with no labels of its own (an older build's newer revision) keeps each file with its camera.
    func testALaterRecordWithoutLabelsKeepsEachFilesCamera() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "rear.jpg"
        held.primaryCamera = "rear"
        let later = labelled(held, revision: 3, primary: nil, secondary: nil)
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertEqual(result.mediaFilename, "rear.jpg")
        XCTAssertEqual(result.primaryCamera, "rear", "the file's camera, not lost")
        XCTAssertEqual(MonitoringCloudCoordinator.placement(camera: "rear", slot: "rear", in: result), .skip,
                       "so a rear retry adds no second copy")
    }

    /// A file whose camera the later record does not name, in a slot the later record gives another camera, takes the
    /// other slot, left unnamed, and gives it its camera: the front is still to download.
    func testALabelledFileTakesTheOtherUnnamedSlotWhenItsOwnIsAnothers() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "rear.jpg"
        held.primaryCamera = "rear"
        let later = labelled(held, revision: 3, primary: "front", secondary: nil)
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertNil(result.mediaFilename)
        XCTAssertEqual(result.secondaryMediaFilename, "rear.jpg")
        XCTAssertEqual(result.secondaryCamera, "rear")
        XCTAssertEqual(MonitoringCloudCoordinator.placement(camera: "front", slot: "front", in: result), .primary(setLabel: false))
    }

    /// A guard, green before the fix and after: a file the later copy carries itself is never replaced (a copy decoded
    /// from iCloud carries none, but the merge is pure and must not depend on that).
    func testAFileTheLaterCopyCarriesIsNeverReplaced() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "rear.jpg"
        held.primaryCamera = "rear"
        var later = labelled(held, revision: 3, primary: "front", secondary: "rear")
        later.secondaryMediaFilename = "later-rear.jpg"
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertEqual(result.secondaryMediaFilename, "later-rear.jpg")
        XCTAssertEqual(result.mediaFilename, "rear.jpg", "the file held stays, as before")
    }

    /// A guard, green before the fix and after: a file a legacy position placed (no camera known) keeps its position,
    /// and the later record's label for it.
    func testAFileFromALegacyPositionKeepsItsPosition() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "legacy-primary.jpg"
        let later = labelled(held, revision: 3, primary: "front", secondary: "rear")
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertEqual(result.mediaFilename, "legacy-primary.jpg")
        XCTAssertNil(result.secondaryMediaFilename)
        XCTAssertEqual(result.primaryCamera, "front")
    }

    /// A guard, green before the fix and after: files already in their cameras' slots stay there.
    func testFilesInTheirCamerasSlotsStayThere() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "front.jpg"
        held.primaryCamera = "front"
        held.secondaryMediaFilename = "rear.jpg"
        held.secondaryCamera = "rear"
        let later = labelled(held, revision: 3, primary: "front", secondary: "rear")
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertEqual(result.mediaFilename, "front.jpg")
        XCTAssertEqual(result.secondaryMediaFilename, "rear.jpg")
    }

    /// A guard, green before the fix and after: two files that would share one slot (a legacy position's file beside one
    /// placed by its camera) keep the slots they had: no file is dropped.
    func testTwoFilesThatWouldShareASlotKeepTheSlotsTheyHad() throws {
        var held = mirror(revision: 2)
        held.mediaFilename = "rear.jpg"
        held.primaryCamera = "rear"
        held.secondaryMediaFilename = "legacy-secondary.jpg"
        let later = labelled(held, revision: 3, primary: "front", secondary: "rear")
        let result = try XCTUnwrap(EventStore.merged(local: [held], incoming: [later]).first)
        XCTAssertEqual(result.mediaFilename, "rear.jpg")
        XCTAssertEqual(result.secondaryMediaFilename, "legacy-secondary.jpg")
    }

    // MARK: - Through the download

    /// The whole path: a rear-only download, then the later record, then a download that brings the front. The front
    /// lands in the front slot, the rear stays in the rear slot, and no second copy is added.
    func testARearDownloadThenTheLaterRecordThenTheFront() async throws {
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let sparse = mirror(revision: 2)
        store.merge([sparse])
        let rear = try stillFile(), front = try stillFile()
        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)],
                                            complete: false)
        }
        let first = await engine.downloadFullEvidence(for: sparse.id)
        XCTAssertTrue(first.landed)
        let afterRear = try XCTUnwrap(store.events.first { $0.id == sparse.id })
        XCTAssertEqual(afterRear.primaryCamera, "rear", "with no labels, the rear photo took the first slot")
        let rearFile = try XCTUnwrap(afterRear.mediaFilename)

        store.merge([labelled(afterRear, revision: 3, primary: "front", secondary: "rear")])
        let merged = try XCTUnwrap(store.events.first { $0.id == sparse.id })
        XCTAssertEqual(merged.secondaryMediaFilename, rearFile, "the rear photo in the rear slot")
        XCTAssertNil(merged.mediaFilename, "the front slot empty")

        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front),
                                                    CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)],
                                            complete: true)
        }
        let second = await engine.downloadFullEvidence(for: sparse.id)
        XCTAssertTrue(second.landed, "the front landed")
        let final = try XCTUnwrap(store.events.first { $0.id == sparse.id })
        XCTAssertNotNil(final.mediaFilename, "the front photo in the front slot")
        XCTAssertNotEqual(final.mediaFilename, rearFile)
        XCTAssertEqual(final.secondaryMediaFilename, rearFile, "the rear photo where it was, no second copy")
        XCTAssertEqual(final.primaryCamera, "front")
        XCTAssertEqual(final.secondaryCamera, "rear")
    }

    // MARK: - Helpers

    /// Another phone's record as a pre-v2 copy holds it: no camera labels, no files here.
    private func mirror(revision: Int) -> Event {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return Event(id: UUID(), startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                     sourceDevice: "Other iPhone", cloudRevision: revision)
    }

    /// The source phone's later revision of `held`, as iCloud's decoder makes it: its labels, no files.
    private func labelled(_ held: Event, revision: Int, primary: String?, secondary: String?) -> Event {
        Event(id: held.id, startDate: held.startDate, endDate: held.endDate, triggeredSensors: held.triggeredSensors,
              primaryCamera: primary, secondaryCamera: secondary, sourceDevice: held.sourceDevice, cloudRevision: revision,
              cloudMediaManifest: [primary, secondary].compactMap { $0 })
    }

    /// A still as iCloud hands it over: a file whose bytes start like a JPEG.
    private func stillFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem201-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
