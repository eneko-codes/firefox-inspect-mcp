import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Brings a screenshot inside the size an image result may have: at most
/// `ToolCatalog.largestScreenshotSide` pixels on the long side and
/// `ToolCatalog.largestScreenshotBytes` bytes. ImageIO is part of macOS, so no dependency.
enum ScreenshotFitter {

    struct Fitted: Equatable {
        var base64: String
        var mimeType: String
        /// The pixel size Firefox returned and the size sent, when they differ in size or
        /// in format. `nil` when the screenshot was sent as it came.
        var adjustment: (from: (width: Int, height: Int), to: (width: Int, height: Int))?

        static func == (lhs: Fitted, rhs: Fitted) -> Bool {
            lhs.base64 == rhs.base64 && lhs.mimeType == rhs.mimeType
        }
    }

    static func fit(base64: String) throws -> Fitted {
        guard let data = Data(base64Encoded: base64),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw InspectError.screenshotUnreadable }

        let side = ToolCatalog.largestScreenshotSide
        if max(width, height) <= side, data.count <= ToolCatalog.largestScreenshotBytes {
            return Fitted(base64: base64, mimeType: "image/png", adjustment: nil)
        }

        var longSide = min(max(width, height), side)
        // PNG first, since it is lossless; then JPEG at falling quality; then a smaller
        // picture, until one fits.
        for _ in 0..<8 {
            guard
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: longSide,
                    ] as CFDictionary)
            else { throw InspectError.screenshotUnreadable }
            let size = (width: thumbnail.width, height: thumbnail.height)
            let attempts: [(UTType, Double?)] = [
                (.png, nil), (.jpeg, 0.85), (.jpeg, 0.7), (.jpeg, 0.5), (.jpeg, 0.3),
            ]
            for (type, quality) in attempts {
                guard let encoded = encode(thumbnail, as: type, quality: quality) else { continue }
                if encoded.count <= ToolCatalog.largestScreenshotBytes {
                    return Fitted(
                        base64: encoded.base64EncodedString(),
                        mimeType: type == .png ? "image/png" : "image/jpeg",
                        adjustment: (from: (width, height), to: size))
                }
            }
            longSide = longSide * 3 / 4
        }
        throw InspectError.screenshotTooLarge
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, type.identifier as CFString, 1, nil)
        else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
