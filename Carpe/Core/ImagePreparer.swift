import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to send: PNG bytes no larger than the long-edge limit.
struct PreparedImage: Sendable {
    var data: Data
    var mediaType: String
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ImagePreparerError: LocalizedError {
    case unreadable

    var errorDescription: String? { "The screenshot couldn't be read." }
}

enum ImagePreparer {
    /// Retina captures are twice the size the text needs. 1600 px keeps normal
    /// UI text legible and the request small. Haiku 5.5 accepts up to 2576 px,
    /// so raise this if dense screenshots lose small print.
    static let maxLongEdge = 1600

    static func prepare(fileAt url: URL, maxLongEdge: Int = maxLongEdge) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImagePreparerError.unreadable }

        if max(width, height) <= maxLongEdge {
            return PreparedImage(
                data: try Data(contentsOf: url), mediaType: "image/png",
                pixelWidth: width, pixelHeight: height
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImagePreparerError.unreadable
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw ImagePreparerError.unreadable }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImagePreparerError.unreadable }

        return PreparedImage(
            data: output as Data, mediaType: "image/png",
            pixelWidth: scaled.width, pixelHeight: scaled.height
        )
    }
}
