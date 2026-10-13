//
//  BoundedImageDecoder.swift
//  Malinois
//
//  Image decoding with explicit pixel bounds (item 105, F-10).
//

import ImageIO
import UIKit

/// Decodes images with explicit pixel bounds (item 105, F-10). A byte cap does not cap decoded
/// size: a 318 KB PNG can decode to 50 million pixels. Every image Malinois decodes for display or
/// for a thumbnail comes through here: the size declared in the file's header is read first, an
/// image over the cap is refused without being decoded, and an accepted one is decoded straight to
/// the size the caller asks for, with the camera's orientation applied. Images in cloud records can
/// come from another device, so this is defensive input handling; it does not judge whether an
/// image is genuine.
enum BoundedImageDecoder {
    /// The largest photo accepted, in pixels: well above anything Malinois captures (a 48-megapixel
    /// iPhone photo is about 48.8 million; this app's own captures are far smaller), and a bound on
    /// what any one image can cost to decode.
    static let maxSourcePixels = 50_000_000
    /// The largest image accepted where the stored image is itself a thumbnail (about 200 pixels: a
    /// log row's, or a cloud record's). Making a thumbnail from a full photo decodes that photo under
    /// `maxSourcePixels` (`CameraController.thumbnail`).
    static let maxThumbnailSourcePixels = 4_000_000
    /// Display sizes, in pixels on the longer side: a thumbnail in the log or the detail view, and
    /// a full photo in the detail view (more than a phone screen shows, so nothing visible is lost).
    static let thumbnailDisplayPixels = 600
    static let fullDisplayPixels = 4096

    /// Pure (unit-tested): whether a declared size is positive and at most `maxPixels` pixels,
    /// without overflowing on absurd values.
    static func acceptsDimensions(width: Int, height: Int, maxPixels: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maxPixels
    }

    /// The image in `data`, at most `maxPixelSize` pixels on its longer side (never enlarged), with
    /// its orientation applied. Nil for unreadable data, an image whose header declares no size,
    /// or one declaring more than `maxSourcePixels` pixels, which is never decoded.
    static func image(from data: Data, maxPixelSize: Int, maxSourcePixels: Int = maxSourcePixels) -> UIImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              acceptsDimensions(width: width, height: height, maxPixels: maxSourcePixels) else { return nil }
        let options: [CFString: Any] = [
            // Always from the image itself: an embedded thumbnail can show something else.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
