//
//  Item105ImageDecodingTests.swift
//  MalinoisTests
//
//  BACKLOG 105, F-10 (1.6): thumbnails and the event views decoded images with `UIImage(data:)`,
//  which has no pixel bound. A byte cap does not cap decoded size: a small file can declare an
//  enormous image, and an image in a cloud record may come from another device. Images now
//  decode through `BoundedImageDecoder`: the header's size is checked first, an image over the
//  cap is refused undecoded, and an accepted one is downsampled with its orientation applied.
//  Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Malinois

final class Item105ImageDecodingTests: XCTestCase {

    // MARK: - Fixtures

    /// A valid PNG of `width` × `height` black pixels whose compressed data is tiny: 7100 × 7100
    /// (50.4 million pixels) is 318 KB. A small file that decodes to an enormous image, as a hostile
    /// asset would be. (A PNG with its pixel data simply missing is no fixture: ImageIO refuses
    /// one that size outright.) Building it allocates nothing near the decoded size.
    static func pngOfZeros(width: UInt32, height: UInt32) -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typeBytes = Array(type.utf8)
            return bigEndian(UInt32(body.count)) + typeBytes + body + bigEndian(crc32(typeBytes + body))
        }
        let header = bigEndian(width) + bigEndian(height) + [8, 0, 0, 0, 0]   // 8-bit grayscale, no interlace
        let rawCount = Int(height) * (Int(width) + 1)                         // each row: a filter byte + pixels
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", header) + chunk("IDAT", zlibOfZeros(count: rawCount)) + chunk("IEND", []))
    }

    /// A zlib stream of `count` zero bytes: one fixed-Huffman deflate block holding a literal 0,
    /// then length-258, distance-1 copies, then literal zeros for the remainder (RFC 1950/1951).
    static func zlibOfZeros(count: Int) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var buffer: UInt32 = 0
        var filled = 0
        func put(_ value: UInt32, _ bits: Int) {   // deflate packs bits least significant first
            buffer |= value << UInt32(filled)
            filled += bits
            while filled >= 8 { out.append(UInt8(buffer & 0xFF)); buffer >>= 8; filled -= 8 }
        }
        func code(_ value: UInt32, _ bits: Int) {  // Huffman codes go most significant bit first
            var reversed: UInt32 = 0
            for i in 0..<bits { reversed |= ((value >> UInt32(i)) & 1) << UInt32(bits - 1 - i) }
            put(reversed, bits)
        }
        put(1, 1); put(1, 2)                        // final block, fixed Huffman codes
        code(0x30, 8)                               // literal 0
        for _ in 0..<(count - 1) / 258 { code(0xC5, 8); code(0, 5) }   // length 258, distance 1
        for _ in 0..<(count - 1) % 258 { code(0x30, 8) }
        code(0, 7)                                  // end of block
        if filled > 0 { out.append(UInt8(buffer & 0xFF)) }
        let adler = UInt32(count % 65_521) << 16 | 1   // Adler-32 of zeros: a = 1, b = count
        return out + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    /// The PNG chunk checksum (CRC-32, ISO 3309).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// A real JPEG of `width` × `height` stored pixels, optionally tagged with an EXIF orientation
    /// (6 = stored landscape, shown portrait, as a phone held upright records it).
    static func jpeg(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The decoded image's size in pixels, as it would be shown.
    static func pixelSize(_ image: UIImage?) -> CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    // MARK: - The decoder

    /// The declared size must be positive and within the cap; the multiplication cannot overflow.
    func testDeclaredDimensionsAreBoundedWithoutOverflow() {
        let cap = BoundedImageDecoder.maxSourcePixels
        XCTAssertTrue(BoundedImageDecoder.acceptsDimensions(width: 4032, height: 3024, maxPixels: cap))
        XCTAssertTrue(BoundedImageDecoder.acceptsDimensions(width: 8064, height: 6048, maxPixels: cap))   // 48 MP
        XCTAssertFalse(BoundedImageDecoder.acceptsDimensions(width: 9000, height: 9000, maxPixels: cap))
        XCTAssertFalse(BoundedImageDecoder.acceptsDimensions(width: 0, height: 100, maxPixels: cap))
        XCTAssertFalse(BoundedImageDecoder.acceptsDimensions(width: -5, height: -5, maxPixels: cap))
        XCTAssertFalse(BoundedImageDecoder.acceptsDimensions(width: Int.max, height: 2, maxPixels: cap))
    }

    /// An image declaring more pixels than the cap is refused, not decoded.
    func testAnImageDeclaringMorePixelsThanTheCapIsRefused() {
        let data = Self.pngOfZeros(width: 7100, height: 7100)   // 50.4 million pixels in 318 KB
        XCTAssertNil(BoundedImageDecoder.image(from: data, maxPixelSize: 4096))
    }

    /// Where a thumbnail is expected, a much smaller cap applies.
    func testAThumbnailOverItsSmallerCapIsRefused() {
        let data = Self.pngOfZeros(width: 2100, height: 2100)   // 4.4 million: a photo, not a thumbnail
        XCTAssertNil(BoundedImageDecoder.image(from: data, maxPixelSize: 600,
                                               maxSourcePixels: BoundedImageDecoder.maxThumbnailSourcePixels))
    }

    /// An accepted image comes back no larger than asked for.
    func testDecodingDownsamplesToTheRequestedSize() throws {
        let size = Self.pixelSize(BoundedImageDecoder.image(from: try Self.jpeg(width: 800, height: 600), maxPixelSize: 256))
        XCTAssertEqual(max(size.width, size.height), 256, accuracy: 1)
        XCTAssertEqual(size.width / size.height, 800.0 / 600.0, accuracy: 0.02)
    }

    /// The camera's orientation is applied, and a small image is not enlarged.
    func testDecodingKeepsTheOrientationAndNeverEnlarges() throws {
        let size = Self.pixelSize(BoundedImageDecoder.image(from: try Self.jpeg(width: 300, height: 200, orientation: 6),
                                                            maxPixelSize: 1000))
        XCTAssertEqual(size.width, 200, accuracy: 1)
        XCTAssertEqual(size.height, 300, accuracy: 1)
    }

    // MARK: - Thumbnails made from captures

    /// The thumbnail maker refuses an image declaring more pixels than the cap.
    func testCameraThumbnailsRefuseOversizedImages() {
        XCTAssertNil(CameraController.thumbnail(from: Self.pngOfZeros(width: 7100, height: 7100)))
    }

    /// Thumbnails stay within 200 pixels and keep the camera's orientation.
    func testCameraThumbnailsStayWithinTheirSizeAndOrientation() throws {
        let thumbnail = try XCTUnwrap(CameraController.thumbnail(from: try Self.jpeg(width: 1200, height: 800, orientation: 6)))
        let size = Self.pixelSize(UIImage(data: thumbnail))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 200.5)
        XCTAssertGreaterThan(size.height, size.width)
    }
}
