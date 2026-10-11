//
//  Item96DownloadTests.swift
//  MalinoisTests
//
//  BACKLOG 96 (found 2026-09-29 by the review of item 94; the pattern item 95 fixed in the flood
//  path). "Download full evidence" read the record before its fetch from iCloud and wrote that
//  copy back whole once the files were stored, so anything a fetch taught the record meanwhile
//  (a count, a failure reason, a later revision) was undone until the next fetch. The download
//  now adds its files to the record as it is when they land.
//

import XCTest
@testable import Malinois

@MainActor
final class Item96DownloadTests: XCTestCase {

    /// The async test and synchronous tearDown use this on the main thread, in sequence.
    /// XCTest does not mark tearDown main-actor isolated (ADR 0023).
    nonisolated(unsafe) private var release: CheckedContinuation<Void, Never>?

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem96")
    }

    override func tearDown() {
        release?.resume()
        release = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// A still as iCloud hands it over: a file whose bytes start like a JPEG.
    private func stillFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem96-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Another phone's record, held here without its media, fetched again while the download
    /// runs with a higher flood count: the download lands, and the count stays.
    func testADownloadKeepsWhatAFetchTaughtTheRecordMeanwhile() async throws {
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        func mirror(floods: Int) -> Event {
            Event(id: id, startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                  sustainedCount: floods, sourceDevice: "iPhone Air", cloudRevision: 2)
        }
        store.merge([mirror(floods: 3)])
        let file = try stillFile()
        engine.fullMediaFetchForTesting = { _, _ in
            await withCheckedContinuation { self.release = $0 }   // the fetch is in flight...
            return CloudExfiltrator.FullMediaFetch(
                media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: file)], complete: true)
        }
        let download = Task { await engine.downloadFullEvidence(for: id) }
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        XCTAssertNotNil(release, "the download is waiting on iCloud")

        store.merge([mirror(floods: 9)])   // ...when a later fetch brings the true count
        XCTAssertEqual(store.events.first { $0.id == id }?.sustainedCount, 9, "the fetch replaced the mirror")
        release?.resume()
        release = nil

        let result = await download.value
        XCTAssertTrue(result.landed, "the download landed")
        let held = store.events.first { $0.id == id }
        XCTAssertNotNil(held?.mediaFilename, "the downloaded still is on the record")
        XCTAssertEqual(held?.sustainedCount, 9, "and the count the fetch brought meanwhile stays")
    }

    /// Full metadata arrives during a sparse mirror's fetch. A rear-only result must use
    /// the newly learned rear slot and leave the front slot available for a later retry.
    func testPartialDownloadUsesCameraLabelsLearnedDuringFetchAndCanRetryFront() async throws {
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let sparse = Event(id: id, startDate: start, endDate: start.addingTimeInterval(5),
                           triggeredSensors: [.motion], sourceDevice: "iPhone Air", cloudRevision: 1)
        store.merge([sparse])
        let rear = try stillFile()
        let front = try stillFile()
        engine.fullMediaFetchForTesting = { _, _ in
            await withCheckedContinuation { self.release = $0 }
            return CloudExfiltrator.FullMediaFetch(
                media: [CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)], complete: false)
        }
        let download = Task { await engine.downloadFullEvidence(for: id) }
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        XCTAssertNotNil(release, "the download is waiting on iCloud")
        var full = sparse
        full.cloudRevision = 2
        full.primaryCamera = "front"
        full.secondaryCamera = "rear"
        full.cloudMediaManifest = ["front", "rear"]
        store.merge([full])
        release?.resume()
        release = nil

        let partial = await download.value
        XCTAssertTrue(partial.landed)
        XCTAssertFalse(partial.complete)
        let first = try XCTUnwrap(store.events.first { $0.id == id })
        XCTAssertEqual(first.primaryCamera, "front", "new metadata determines placement")
        XCTAssertEqual(first.secondaryCamera, "rear")
        XCTAssertNil(first.mediaFilename, "front is still missing")
        XCTAssertNotNil(first.secondaryMediaFilename, "rear belongs in its named slot")

        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(
                media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front)], complete: true)
        }
        let retried = await engine.downloadFullEvidence(for: id)
        XCTAssertTrue(retried.landed, "the missing front capture can still be attached")
        let held = try XCTUnwrap(store.events.first { $0.id == id })
        XCTAssertNotNil(held.mediaFilename)
        XCTAssertNotNil(held.secondaryMediaFilename)
        XCTAssertEqual(held.secondaryMediaFilename, first.secondaryMediaFilename, "the rear download survives retry")
        XCTAssertNotEqual(held.mediaFilename, held.secondaryMediaFilename)
        XCTAssertEqual(held.primaryCamera, "front")
        XCTAssertEqual(held.secondaryCamera, "rear")
    }

}
