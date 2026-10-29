//
//  Item155LaunchScanTests.swift
//  MalinoisTests
//
//  1.8.2's step 33 (item 155's A14, the fresh review's fable-8): at launch the event store reads its pending photo
//  and clip saves (the attachment intents) on the main thread, up to 1,200 of them, before the first screen. The plan:
//  measure first, and move the read off the launch path only if it stalls. Measured here at the bound, each intent
//  made through the real save and carrying the largest thumbnail the app makes (a 200-pixel picture of pure noise),
//  against a launch with none. A real phone holds an intent only from a save until the next write of the log (a
//  handful at most); the Simulator reads from the Mac's warm file cache, a phone at launch may not.
//

import XCTest
import UIKit
@testable import Malinois

@MainActor
final class Item155LaunchScanTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem155Scan")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// 1,200 pending saves add less than a second to a launch on the Simulator: measured on 2026-10-24 at 0.351 s,
    /// against 0.001 s with none (the times are printed as a "step 33:" line), so the read stays where it is. Each is
    /// read whole, decoded and checked against its file, and none is lost: a relaunch keeps every one, since none
    /// belongs to a record in the log.
    func testALaunchReadsTheMostPendingSavesQuickly() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let fm = FileManager.default
        let intents = root.appendingPathComponent("MediaAttachments")
        let media = root.appendingPathComponent("Media")

        // One save through the real path; its record never learns the file, so the intent stays.
        let store = EventStore()
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .localOnly)
        store.add(event)
        let still = try XCTUnwrap(Self.noiseImage(side: 200).jpegData(compressionQuality: 1))
        let stored = await store.store(.still(still), ext: "jpg", attachingTo: event, camera: "rear")
        let filename = try XCTUnwrap(stored?.filename, "one save through the real path")
        store.drainIOForTesting()
        let stem = String(filename.dropLast(4))
        let manifest = intents.appendingPathComponent(stem + ".json")
        let original = try Data(contentsOf: manifest)
        var intent = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        let thumbnail = try XCTUnwrap(intent["thumbnail"] as? String, "the intent carries its thumbnail")
        XCTAssertGreaterThan(thumbnail.utf8.count, 20_000, "the largest thumbnail the app makes, in base64")
        let photo = try Data(contentsOf: media.appendingPathComponent(filename))
        try fm.removeItem(at: manifest)
        try fm.removeItem(at: media.appendingPathComponent(filename))

        func launch() -> TimeInterval {
            let start = Date()
            let relaunched = EventStore()
            let elapsed = Date().timeIntervalSince(start)
            relaunched.drainIOForTesting()
            return elapsed
        }
        func median(_ runs: Int, _ measure: () -> TimeInterval) -> TimeInterval {
            (0..<runs).map { _ in measure() }.sorted()[runs / 2]
        }
        let without = median(3, launch)

        // 1,200 intents, the bound the store reads, each for a record not in the log: read and checked, then kept.
        for _ in 0..<1_200 {
            let copy = UUID().uuidString
            intent["filename"] = copy + ".jpg"
            intent["eventID"] = UUID().uuidString
            try JSONSerialization.data(withJSONObject: intent).write(to: intents.appendingPathComponent(copy + ".json"))
            try photo.write(to: media.appendingPathComponent(copy + ".jpg"))
        }
        let with = median(3, launch)
        let kept = try fm.contentsOfDirectory(atPath: intents.path).filter { $0.hasSuffix(".json") }.count
        print(String(format: "step 33: launch %.3f s without pending saves, %.3f s with 1,200 (%.0f KB of intents)",
                     without, with, Double(original.count * 1_200) / 1_000))
        XCTAssertEqual(kept, 1_200, "every pending save kept")
        XCTAssertLessThan(with - without, 1, "1,200 pending saves add \(with - without) s to a launch")
    }

    /// A square of pure color noise, one pixel per point, from a fixed seed.
    private static func noiseImage(side: Int) -> UIImage {
        var rng = SeededGenerator(seed: 0x4A0B_0033)
        var bytes = (0..<(side * side * 4)).map { index in index % 4 == 3 ? UInt8(255) : UInt8.random(in: 0...255, using: &rng) }
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
        return UIImage(cgImage: image!)
    }
}
