//
//  Item154ClipThumbnailTests.swift
//  MalinoisTests
//
//  BACKLOG 154 (the owner's idea and his refinement; 1.8.2's step 35): a clip's thumbnail was its frame about 1 s in,
//  often the empty room a Vision trip had just seen change. The finished clip is now sampled two frames a second (24
//  at most), each sample scored with the Vision tripwire's own measure against the clip's first frame, and the first
//  sample reaching 80% of the clip's greatest score is the thumbnail; the 1 s frame stays for a clip too short to
//  sample or one where nothing changed. The clips here are written in the test: 192 by 144 pixels (the tripwire's
//  32 by 24 cells are then 6 by 6 pixels each), a grey room (100) and blocks of a lighter grey (125) for the subject.
//

import XCTest
import AVFoundation
import UIKit
@testable import Malinois

final class Item154ClipThumbnailTests: XCTestCase {

    /// A block of the frame in pixels, and its grey.
    struct Block: Sendable {
        let x: Int, y: Int, width: Int, height: Int
        let luma: UInt8
    }

    /// The subject: the left half's top 15 cell rows, 240 of the 768 cells (31.25%).
    static let subject = Block(x: 0, y: 0, width: 96, height: 90, luma: 125)
    /// A larger change (a hand over the lens, say): 288 cells (37.5%) at the bottom right.
    static let hand = Block(x: 84, y: 48, width: 108, height: 96, luma: 125)

    // MARK: - The rule

    /// The owner's rule: the first sample whose score reaches 80% of the clip's greatest; none when even the greatest
    /// is below the most sensitive trip (2%), so nothing in the clip changed.
    func testTheFirstSampleNearThePeakIsChosen() {
        XCTAssertEqual(CameraController.thumbnailSampleIndex(scores: [0, 0.01, 0.3, 0.5, 0.45, 0.9, 0.2]), 5)
        XCTAssertEqual(CameraController.thumbnailSampleIndex(scores: [0, 0.4, 0.5, 0.45]), 1, "80% of 0.5 is 0.4")
        XCTAssertEqual(CameraController.thumbnailSampleIndex(scores: [0, 0.05, 0.02]), 1)
        XCTAssertNil(CameraController.thumbnailSampleIndex(scores: [0, 0.01, 0.015]), "nothing changed")
        XCTAssertNil(CameraController.thumbnailSampleIndex(scores: []))
    }

    /// The score is the Vision tripwire's own measure against the clip's first frame: a change of light over the
    /// whole frame scores nothing, a lighter block over a quarter of the cells scores a quarter.
    func testTheScoreIsTheTripwiresMeasureAgainstTheFirstFrame() {
        let cells = VisionFrame.width * VisionFrame.height
        func frame(_ luma: (Int) -> UInt8) -> VisionFrame { VisionFrame(luma: (0..<cells).map(luma)) }
        let scores = CameraController.changeScores([frame { _ in 100 }, frame { _ in 160 }, frame { $0 < cells / 4 ? 125 : 100 }])
        XCTAssertEqual(scores.count, 3)
        XCTAssertEqual(scores.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(scores.dropFirst().first ?? -1, 0, accuracy: 0.0001, "the light alone changed")
        XCTAssertEqual(scores.last ?? -1, 0.25, accuracy: 0.0001)
    }

    // MARK: - Clips

    /// The subject arrives 2 s into a 5 s clip: the thumbnail is from then, and shows it.
    func testASubjectArrivingTwoSecondsInIsTheThumbnail() async throws {
        let clip = try await Self.clip(seconds: 5) { $0 >= 2 ? [Self.subject] : [] }
        let thumbnail = try XCTUnwrap(CameraController.videoThumbnail(from: clip))
        XCTAssertTrue(try Self.shows(Self.subject, in: thumbnail), "the thumbnail shows the subject, not the room at 1 s")
        let chosen = try XCTUnwrap(CameraController.contentFrame(of: clip), "a frame chosen by content")
        XCTAssertEqual(chosen.seconds, 2, accuracy: 0.05)
    }

    /// The only change comes 4 s into 5: the thumbnail is from then.
    func testAChangeNearTheEndIsTheThumbnail() async throws {
        let clip = try await Self.clip(seconds: 5) { $0 >= 4 ? [Self.subject] : [] }
        XCTAssertTrue(try Self.shows(Self.subject, in: XCTUnwrap(CameraController.videoThumbnail(from: clip))))
        let chosen = try XCTUnwrap(CameraController.contentFrame(of: clip), "a frame chosen by content")
        XCTAssertEqual(chosen.seconds, 4, accuracy: 0.05)
    }

    /// The subject arrives at 1.5 s and a larger change follows at 3 s for half a second: the first sample within 80%
    /// of the peak, the subject's, is the thumbnail, not the peak's.
    func testTheFirstSampleNearThePeakBeatsThePeak() async throws {
        let clip = try await Self.clip(seconds: 5) { time in
            if time >= 3, time < 3.5 { return [Self.hand] }
            return time >= 1.5 ? [Self.subject] : []
        }
        let thumbnail = try XCTUnwrap(CameraController.videoThumbnail(from: clip))
        XCTAssertTrue(try Self.shows(Self.subject, in: thumbnail))
        XCTAssertFalse(try Self.shows(Self.hand, in: thumbnail), "not the larger change")
        let chosen = try XCTUnwrap(CameraController.contentFrame(of: clip), "a frame chosen by content")
        XCTAssertEqual(chosen.seconds, 1.5, accuracy: 0.05)
    }

    /// The controls: a clip where only the light changes has no frame chosen by content and keeps the 1 s frame; so
    /// does a clip too short to sample twice; an unreadable file has no thumbnail at all.
    func testTheOneSecondFrameStaysWhenNothingChangesOrTheClipIsShort() async throws {
        let dimming = try await Self.clip(seconds: 3, room: { UInt8(100 + Int($0 * 10)) }, blocks: { _ in [] })
        XCTAssertNil(CameraController.contentFrame(of: dimming), "only the light changed")
        XCTAssertNotNil(CameraController.videoThumbnail(from: dimming), "the 1 s frame")
        let short = try await Self.clip(seconds: 0.3) { _ in [Self.subject] }
        XCTAssertNil(CameraController.contentFrame(of: short), "too short to sample twice")
        XCTAssertNotNil(CameraController.videoThumbnail(from: short), "its earliest frame")
        let unreadable = FileManager.default.temporaryDirectory.appendingPathComponent("Item154-\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: unreadable)
        addTeardownBlock { try? FileManager.default.removeItem(at: unreadable) }
        XCTAssertNil(CameraController.contentFrame(of: unreadable))
        XCTAssertNil(CameraController.videoThumbnail(from: unreadable))
    }

    /// The cost on the store's queue, which a response waits for before its alert (a clip's save comes first): a 5 s
    /// clip at full HD and 30 frames a second, as a phone records, sampled ten times. Printed as a "step 35:" line.
    func testSamplingAFiveSecondFullHDClipIsQuick() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Item154-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let quarter = Block(x: 0, y: 0, width: 960, height: 540, luma: 125)
        try await Task.detached(priority: .utility) {
            try await Self.writeClip(at: url, width: 1920, height: 1080, fps: 30, seconds: 5, room: { _ in 100 },
                                     blocks: { $0 >= 2 ? [quarter] : [] })
        }.value
        let start = Date()
        let chosen = CameraController.contentFrame(of: url)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "step 35: a 5 s full-HD clip sampled and scored in %.3f s", elapsed))
        XCTAssertEqual(try XCTUnwrap(chosen, "a frame chosen by content").seconds, 2, accuracy: 0.05)
        XCTAssertLessThan(elapsed, 1.5, "the response waits for this")
    }

    // MARK: - codex-15: the frame's edges

    /// codex-15 on c75f223: the subject arrives only in the last 12 rows of a wide clip (192 by 108, the shape a phone's
    /// 16:9 frame takes at the thumbnail's size), which the tripwire's whole cells left out: it is still chosen.
    func testASubjectInTheBottomStripOfAWideClipIsChosen() async throws {
        let strip = Block(x: 0, y: 96, width: 192, height: 12, luma: 125)
        let clip = try await Self.clip(width: 192, height: 108, seconds: 5) { $0 >= 2 ? [strip] : [] }
        addTeardownBlock { try? FileManager.default.removeItem(at: clip) }
        let chosen = try XCTUnwrap(CameraController.contentFrame(of: clip), "a frame chosen by content")
        XCTAssertEqual(chosen.seconds, 2, accuracy: 0.05)
        XCTAssertEqual([chosen.image.width, chosen.image.height], [192, 108], "the clip's own shape")
    }

    /// The same at the right edge of a tall clip (108 by 192, a portrait frame).
    func testASubjectInTheRightStripOfATallClipIsChosen() async throws {
        let strip = Block(x: 96, y: 0, width: 12, height: 192, luma: 125)
        let clip = try await Self.clip(width: 108, height: 192, seconds: 5) { $0 >= 2 ? [strip] : [] }
        addTeardownBlock { try? FileManager.default.removeItem(at: clip) }
        let chosen = try XCTUnwrap(CameraController.contentFrame(of: clip), "a frame chosen by content")
        XCTAssertEqual(chosen.seconds, 2, accuracy: 0.05)
        XCTAssertEqual([chosen.image.width, chosen.image.height], [108, 192], "the clip's own shape")
    }

    // MARK: - Helpers

    /// A clip written as the test describes it: `blocks` over the room at each moment, ten frames a second.
    static func clip(width: Int = 192, height: Int = 144, seconds: Double,
                     room: @escaping @Sendable (Double) -> UInt8 = { _ in 100 },
                     blocks: @escaping @Sendable (Double) -> [Block]) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Item154-\(UUID().uuidString).mov")
        try await Task.detached(priority: .utility) {
            try await writeClip(at: url, width: width, height: height, fps: 10, seconds: seconds, room: room, blocks: blocks)
        }.value
        return url
    }

    nonisolated static func writeClip(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                                      room: (Double) -> UInt8, blocks: (Double) -> [Block]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = max(1, Int((seconds * Double(fps)).rounded()))
        for index in 0..<frames {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData else { throw CocoaError(.fileWriteUnknown) }
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made) == kCVReturnSuccess,
                  let buffer = made else { throw CocoaError(.fileWriteUnknown) }
            let time = Double(index) / Double(fps)
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.fileWriteUnknown) }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            func fill(x: Int, y: Int, width: Int, height: Int, luma: UInt8) {
                var pattern: [UInt8] = [luma, luma, luma, 255]
                for row in y..<(y + height) {
                    memset_pattern4(base.advanced(by: row * rowBytes + x * 4), &pattern, width * 4)
                }
            }
            fill(x: 0, y: 0, width: width, height: height, luma: room(time))
            for block in blocks(time) {
                fill(x: block.x, y: block.y, width: block.width, height: block.height, luma: block.luma)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: CMTimeScale(fps)))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Whether a thumbnail shows `block`: the middle of its part no other block covers is lighter than the room.
    private static func shows(_ block: Block, in jpeg: Data) throws -> Bool {
        let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage, "the thumbnail decodes")
        let width = image.width, height = image.height
        XCTAssertEqual(width, 192, "the clip's own size: at most 200 pixels")
        var plane = [UInt8](repeating: 0, count: width * height)
        plane.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The part of the block the other block never covers, less a margin: the subject's top left, the hand's
        // bottom right.
        let own = block.x == 0 ? (x: 12, y: 6, width: 60, height: 36) : (x: 108, y: 96, width: 72, height: 42)
        var sum = 0
        for row in own.y..<(own.y + own.height) {
            for column in own.x..<(own.x + own.width) { sum += Int(plane[row * width + column]) }
        }
        return Double(sum) / Double(own.width * own.height) > 112.5
    }
}
