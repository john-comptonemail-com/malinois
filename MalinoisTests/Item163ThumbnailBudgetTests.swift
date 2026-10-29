//
//  Item163ThumbnailBudgetTests.swift
//  MalinoisTests
//
//  codex-14 on 1.8.2's step 35: a clip's thumbnail waited on AVFoundation with no limit (the clip's length, then up to
//  24 frames), on the store's queue, which saves the clip and which a clip trip's response waits for before it re-arms
//  and alerts. When AVFoundation never answers, the thumbnail now gives up within its budget, and the clip is saved
//  without one. The stall is the test's (`CameraController.thumbnailStallsForTesting`): nothing then answers.
//

import XCTest
@testable import Malinois

@MainActor
final class Item163ThumbnailBudgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem163Budget")
    }

    override func tearDown() {
        CameraController.thumbnailStallsForTesting = false
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// What a thumbnail attempt off the main thread returned.
    private final class Returned: @unchecked Sendable {
        var thumbnail: Data?
    }

    /// What the store's save returned.
    @MainActor
    private final class Saved {
        var media: EventStore.StoredMedia?
    }

    /// AVFoundation never answers: the thumbnail gives up within its budget, with the clip's length unknown (a
    /// download) and known (a capture hands it over measured), and there is none.
    func testAThumbnailGivesUpWhenAVFoundationNeverAnswers() async throws {
        let clip = try await Item154ClipThumbnailTests.clip(seconds: 5) { $0 >= 2 ? [Item154ClipThumbnailTests.subject] : [] }
        addTeardownBlock { try? FileManager.default.removeItem(at: clip) }
        for length in [nil, 5.0] as [Double?] {
            CameraController.thumbnailStallsForTesting = true
            let returned = Returned()
            let finished = expectation(description: "the thumbnail returns (length \(String(describing: length)))")
            let start = Date()
            DispatchQueue.global().async {
                returned.thumbnail = CameraController.videoThumbnail(from: clip, duration: length)
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 6)
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "within the budget")
            XCTAssertNil(returned.thumbnail, "no thumbnail")
            CameraController.thumbnailStallsForTesting = false
        }
    }

    /// The store saves a clip whose thumbnail gives up, without one, within the budget, and its later work finishes.
    func testTheStoreSavesAClipWhoseThumbnailGivesUp() async throws {
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .localOnly)
        store.add(event)
        let clip = try await Item154ClipThumbnailTests.clip(seconds: 3) { _ in [] }
        CameraController.thumbnailStallsForTesting = true
        let saved = expectation(description: "the clip is saved")
        let start = Date()
        let result = Saved()
        Task {
            result.media = await store.store(.clip(clip), ext: "mov", attachingTo: event, camera: "rear", duration: 3)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "within the thumbnail's budget")
        // Stops here if the save never ended: the store's queue is then held for good, and waiting on it would hang.
        let media = try XCTUnwrap(result.media, "the clip is saved")
        XCTAssertNil(media.thumbnail, "without a thumbnail")
        CameraController.thumbnailStallsForTesting = false
        let later = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .localOnly)
        store.add(later)
        store.drainIOForTesting()
        XCTAssertNotNil(store.events.first { $0.id == later.id }, "the store's later work finished")
    }
}
