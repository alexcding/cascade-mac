import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes an image too large to send small enough, as Synara's composer does
/// (`composerImagePreparation.ts`): the source's pixels are bounded before anything is decoded,
/// it is drawn at most 8192 pixels on its longer edge and 24 megapixels in all, and encoded as a
/// JPEG aimed at 8 MB, smaller again up to three times while it is over. Synchronous and heavy:
/// call it off the main actor.
enum ChatImageOptimizer {
    static let targetBytes = 8 * 1024 * 1024
    static let maxSourcePixels = 64_000_000
    static let maxSourceEdge = 16_384
    static let maxRenderPixels = 24_000_000
    static let maxRenderEdge = 8_192
    static let quality = 0.92
    static let maxResizeAttempts = 3

    enum Failure: Error, Equatable {
        /// No bitmap could be read from the data.
        case unreadable
        /// More pixels than are decoded safely.
        case tooManyPixels
    }

    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    /// The image's pixel size as its header gives it, without decoding it.
    static func pixelSize(of source: CGImageSource) -> Size? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return Size(width: width, height: height)
    }

    /// Synara's `boundedRenderSize`.
    static func boundedRenderSize(_ size: Size) -> Size {
        let width = Double(size.width), height = Double(size.height)
        let edgeScale = min(1, Double(maxRenderEdge) / max(width, height))
        let pixelScale = min(1, (Double(maxRenderPixels) / (width * height)).squareRoot())
        let scale = min(edgeScale, pixelScale)
        return Size(width: max(1, Int((width * scale).rounded())), height: max(1, Int((height * scale).rounded())))
    }

    /// Synara's `nextRenderSize`: smaller by what the last encoding overshot, between half and 90%.
    static func nextRenderSize(_ size: Size, encodedBytes: Int) -> Size {
        let estimated = (Double(targetBytes) / Double(encodedBytes)).squareRoot() * 0.94
        let scale = min(0.9, max(0.5, estimated))
        return Size(width: max(1, Int((Double(size.width) * scale).rounded())),
                    height: max(1, Int((Double(size.height) * scale).rounded())))
    }

    /// The image as a JPEG of at most `maxRenderEdge` on its longer edge, encoded until it is
    /// under `targetBytes` or out of attempts. The caller checks the result against what a
    /// message may carry. Transparency is laid on white, as Synara's JPEG is.
    static func optimize(_ data: Data) throws -> (data: Data, size: Size) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let original = pixelSize(of: source) else { throw Failure.unreadable }
        guard max(original.width, original.height) <= maxSourceEdge,
              original.width * original.height <= maxSourcePixels else { throw Failure.tooManyPixels }
        var size = boundedRenderSize(original)
        // Decoded once, already scaled down and turned upright.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw Failure.unreadable }
        // The transform may have turned it: the drawn size follows the decoded image's shape.
        size = boundedRenderSize(Size(width: image.width, height: image.height))
        var encoded = try encode(image, size: size)
        var attempt = 0
        while encoded.count > targetBytes, attempt < maxResizeAttempts {
            size = nextRenderSize(size, encodedBytes: encoded.count)
            encoded = try encode(image, size: size)
            attempt += 1
        }
        return (encoded, size)
    }

    private static func encode(_ image: CGImage, size: Size) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.unreadable }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let drawn = context.makeImage() else { throw Failure.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        CGImageDestinationAddImage(destination, drawn, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return output as Data
    }
}
