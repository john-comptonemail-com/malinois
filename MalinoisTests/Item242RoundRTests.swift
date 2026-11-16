//
//  Item242RoundRTests.swift
//  MalinoisTests
//
//  Round r, from gpt6-astra's look at round q (BACKLOG 242; the owner, 2026-11-14: "a as you recommend, wording
//  approved"). gpt6-astra-q1: item 239's rule for turning the Vision still took the capture's turn less the tap's, and
//  the two mirror flags apart. A connection mirrors after it turns, so a mirrored tap reverses the turn that undoes it:
//  with the tap mirrored and a quarter turn from the capture, the still came out upside down. Whether a phone's tap is
//  mirrored, the source cannot show (the app sets no connection's turn or mirroring), so the camera log now names the
//  values at each session's setup.
//  Written before the fix, red at that commit (against a compile-only stub for the log's line).
//

import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import Malinois

final class Item242RoundRTests: XCTestCase {

    // MARK: - The still's turn, against Core Image's own geometry (all 64 cases)

    /// A mirrored tap a quarter turn from the capture: the still shows the view as the capture does (it came out upside
    /// down: the 16 cases the rule had wrong).
    func testAMirroredTapAQuarterTurnFromTheCaptureShowsTheCapturesView() {
        assertTheStillShowsTheCapturesView(count: 16) { capture, tap in tap.mirrored && (capture.angle - tap.angle + 360) % 180 == 90 }
    }

    /// gpt6-astra's case: the capture at 90° and not mirrored, the tap at 0° and mirrored: `.rightMirrored`.
    func testGpt6AstrasCaseIsTurnedRightAndMirrored() {
        XCTAssertEqual(CameraController.stillOrientation(photoAngle: 90, photoMirrored: false, tapAngle: 0, tapMirrored: true),
                       .rightMirrored)
    }

    /// An unmirrored tap is turned as before (32 cases).
    func testAnUnmirroredTapIsTurnedAsBefore() {
        assertTheStillShowsTheCapturesView(count: 32) { _, tap in !tap.mirrored }
    }

    /// A mirrored tap level with the capture or a half turn from it is turned as before (16 cases).
    func testAMirroredTapLevelOrAHalfTurnFromTheCaptureIsTurnedAsBefore() {
        assertTheStillShowsTheCapturesView(count: 16) { capture, tap in tap.mirrored && (capture.angle - tap.angle + 360) % 180 == 0 }
    }

    // MARK: - Through the still's own JPEG

    /// A frame from a mirrored tap a quarter turn from the capture, made into the still's JPEG, shows the capture's view.
    func testTheStillsJPEGFromAMirroredTapShowsTheCapturesView() throws {
        for (capture, tap) in [(Connection(angle: 90, mirrored: false), Connection(angle: 0, mirrored: true)),
                               (Connection(angle: 90, mirrored: true), Connection(angle: 0, mirrored: true)),
                               (Connection(angle: 270, mirrored: false), Connection(angle: 0, mirrored: true))] {
            try assertTheStillsJPEGShowsTheCapturesView(capture: capture, tap: tap)
        }
    }

    /// And from an unmirrored tap, as before.
    func testTheStillsJPEGFromAnUnmirroredTapShowsTheCapturesView() throws {
        for (capture, tap) in [(Connection(angle: 90, mirrored: false), Connection(angle: 0, mirrored: false)),
                               (Connection(angle: 90, mirrored: true), Connection(angle: 0, mirrored: false))] {
            try assertTheStillsJPEGShowsTheCapturesView(capture: capture, tap: tap)
        }
    }

    // MARK: - The camera log's line

    /// The line each session's setup writes: the session, both connections' turn and mirroring, and the orientation.
    func testTheCameraLogsLineNamesTheConnectionsAndTheTurn() {
        XCTAssertEqual(CameraController.stillOrientationNote(session: "front camera, clips", captureAngle: 90, captureMirrored: false,
                                                             tapAngle: 0, tapMirrored: true, orientation: .rightMirrored),
                       "Vision still (front camera, clips): the capture's connection 90°, the tap's 0° mirrored; "
                           + "the still turned by orientation 7")
        XCTAssertEqual(CameraController.stillOrientationNote(session: "rear camera, photos", captureAngle: 0, captureMirrored: true,
                                                             tapAngle: 270, tapMirrored: false, orientation: .left),
                       "Vision still (rear camera, photos): the capture's connection 0° mirrored, the tap's 270°; "
                           + "the still turned by orientation 8")
    }

    // MARK: - Helpers

    /// A connection's turn, clockwise in degrees, and whether it mirrors.
    private struct Connection {
        let angle: Int
        let mirrored: Bool
    }

    private static let connections = [0, 90, 180, 270].flatMap { angle in
        [false, true].map { Connection(angle: angle, mirrored: $0) }
    }

    /// Six blocks, no two alike, so that every turn and every mirror shows.
    private static let scene = [[0, 1, 2], [3, 4, 5]]

    /// The scene as a connection shows it: turned clockwise by its angle, then mirrored (a connection mirrors after it
    /// turns). Row 0 is the top.
    private static func shown(_ grid: [[Int]], by connection: Connection) -> [[Int]] {
        var turned = grid
        for _ in 0..<(connection.angle / 90) {
            let before = turned
            turned = (0..<before[0].count).map { row in (0..<before.count).map { column in before[before.count - 1 - column][row] } }
        }
        return connection.mirrored ? turned.map { Array($0.reversed()) } : turned
    }

    /// Where Core Image's `oriented(_:)`, which the still's JPEG applies, puts each block of `grid`: Core Image's own
    /// transform for the orientation, read without drawing.
    private static func oriented(_ grid: [[Int]], _ orientation: CGImagePropertyOrientation) -> [[Int]] {
        let rows = grid.count, columns = grid[0].count, side: CGFloat = 16
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(columns) * side, height: CGFloat(rows) * side))
        let transform = source.orientationTransform(for: orientation)
        let out = source.oriented(orientation).extent
        let outRows = Int((out.height / side).rounded()), outColumns = Int((out.width / side).rounded())
        var result = Array(repeating: Array(repeating: -1, count: outColumns), count: outRows)
        for row in 0..<rows {
            for column in 0..<columns {
                // Core Image's origin is the bottom left; row 0 is the top.
                let centre = CGPoint(x: (CGFloat(column) + 0.5) * side, y: (CGFloat(rows - 1 - row) + 0.5) * side).applying(transform)
                let outRow = outRows - 1 - Int((centre.y - out.minY) / side), outColumn = Int((centre.x - out.minX) / side)
                if (0..<outRows).contains(outRow), (0..<outColumns).contains(outColumn) { result[outRow][outColumn] = grid[row][column] }
            }
        }
        return result
    }

    private func assertTheStillShowsTheCapturesView(count: Int, file: StaticString = #filePath, line: UInt = #line,
                                                    where matches: (Connection, Connection) -> Bool) {
        var checked = 0
        for capture in Self.connections {
            for tap in Self.connections where matches(capture, tap) {
                checked += 1
                let orientation = CameraController.stillOrientation(photoAngle: CGFloat(capture.angle), photoMirrored: capture.mirrored,
                                                                    tapAngle: CGFloat(tap.angle), tapMirrored: tap.mirrored)
                XCTAssertEqual(Self.oriented(Self.shown(Self.scene, by: tap), orientation), Self.shown(Self.scene, by: capture),
                               "the capture at \(capture.angle)°\(capture.mirrored ? " mirrored" : ""), "
                                   + "the tap at \(tap.angle)°\(tap.mirrored ? " mirrored" : "")", file: file, line: line)
            }
        }
        XCTAssertEqual(checked, count, "the cases checked", file: file, line: line)
    }

    private static let colours: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255),
    ]

    /// The tap's frame as the tap shows the scene, the blocks 32 pixels a side, made into the still's JPEG, and its
    /// blocks read back by colour.
    private func assertTheStillsJPEGShowsTheCapturesView(capture: Connection, tap: Connection,
                                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try pixelBuffer(Self.shown(Self.scene, by: tap))
        let orientation = CameraController.stillOrientation(photoAngle: CGFloat(capture.angle), photoMirrored: capture.mirrored,
                                                            tapAngle: CGFloat(tap.angle), tapMirrored: tap.mirrored)
        let jpeg = try XCTUnwrap(CameraController.referenceStillJPEG(from: frame, orientation: orientation), file: file, line: line)
        let expected = Self.shown(Self.scene, by: capture)
        XCTAssertEqual(try blocks(of: jpeg, rows: expected.count, columns: expected[0].count), expected,
                       "the capture at \(capture.angle)°\(capture.mirrored ? " mirrored" : ""), "
                           + "the tap at \(tap.angle)°\(tap.mirrored ? " mirrored" : "")", file: file, line: line)
    }

    private func pixelBuffer(_ grid: [[Int]], side: Int = 32) throws -> CVPixelBuffer {
        let width = grid[0].count * side, height = grid.count * side
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &made),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let colour = Self.colours[grid[y / side][x / side]], pixel = base + y * bytesPerRow + x * 4
                pixel[0] = colour.blue
                pixel[1] = colour.green
                pixel[2] = colour.red
                pixel[3] = 255
            }
        }
        return buffer
    }

    /// The JPEG's blocks, each read at its centre and named by the nearest of the six colours. Row 0 is the top.
    private func blocks(of jpeg: Data, rows: Int, columns: Int) throws -> [[Int]] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<rows).map { row in
            (0..<columns).map { column in
                let x = column * width / columns + width / columns / 2, y = row * height / rows + height / rows / 2
                let index = (y * width + x) * 4
                func distance(_ colour: Int) -> Int {
                    abs(Int(Self.colours[colour].red) - Int(pixels[index])) + abs(Int(Self.colours[colour].green) - Int(pixels[index + 1]))
                        + abs(Int(Self.colours[colour].blue) - Int(pixels[index + 2]))
                }
                return Self.colours.indices.min { distance($0) < distance($1) } ?? -1
            }
        }
    }
}
