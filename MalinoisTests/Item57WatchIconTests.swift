//
//  Item57WatchIconTests.swift
//  MalinoisTests
//
//  BACKLOG 57 (owner, 2026-10-13, after uploading 1.6 (63): "the watch icon doesn't look great
//  (cropped weirdly)"). watchOS shows app icons as a circle, and the watch app reused the iPhone's
//  square icon, whose wordmark and tagline run close to its bottom corners: the circle cut them.
//  The watch now has its own icon, the emblem alone, centred, with nothing near the circle's edge.
//  Written before the new icon, red at that commit.
//

import XCTest
import CoreGraphics
import ImageIO

final class Item57WatchIconTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let watchIcon = "MalinoisWatch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    private static let phoneIcon = "Malinois/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

    private func image(_ relativePath: String) throws -> CGImage {
        let url = Self.root.appendingPathComponent(relativePath)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), relativePath)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), relativePath)
    }

    /// The watch icon is a 1024-pixel square without transparency, as App Store Connect requires,
    /// and is not the iPhone's icon.
    func testTheWatchHasItsOwnOpaqueIcon() throws {
        let watch = try Data(contentsOf: Self.root.appendingPathComponent(Self.watchIcon))
        let phone = try Data(contentsOf: Self.root.appendingPathComponent(Self.phoneIcon))
        XCTAssertNotEqual(watch, phone, "the watch has its own icon, not the iPhone's with the wordmark")
        let icon = try image(Self.watchIcon)
        XCTAssertEqual(icon.width, 1024)
        XCTAssertEqual(icon.height, 1024)
        XCTAssertTrue([.none, .noneSkipLast, .noneSkipFirst].contains(icon.alphaInfo), "no transparency")
    }

    /// Only background near the circle's edge: in the outer 15% of the radius every pixel is dark,
    /// so the circle watchOS applies cuts no artwork.
    func testNothingButBackgroundNearTheCircleEdge() throws {
        let icon = try image(Self.watchIcon)
        let width = icon.width, height = icon.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(icon, in: CGRect(x: 0, y: 0, width: width, height: height))
        let radius = Double(width) / 2
        var brightest = 0
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - radius, dy = Double(y) + 0.5 - radius
                let distance = (dx * dx + dy * dy).squareRoot() / radius
                guard distance >= 0.85, distance <= 1 else { continue }
                let i = (y * width + x) * 4
                brightest = max(brightest, (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3)
            }
        }
        XCTAssertLessThan(brightest, 60, "artwork reaches the outer ring the watch's circle crops")
    }
}
