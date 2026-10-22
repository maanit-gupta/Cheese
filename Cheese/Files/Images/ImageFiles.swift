import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Errors shared by the Files tools.
enum FileToolError: LocalizedError, Equatable {
    case unreadable(String)
    case writeFailed(String)
    case noSubjectFound
    case emptyDocument
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(name): "\(name) couldn't be opened."
        case let .writeFailed(name): "\(name) couldn't be written."
        case .noSubjectFound: "No subject found, so nothing was written."
        case .emptyDocument: "The document has no pages."
        case let .message(text): text
        }
    }
}

/// Output image formats. WebP is only offered when this Mac's ImageIO can write it.
enum ImageFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case png
    case jpeg
    case heic
    case tiff
    case gif
    case bmp
    case webp

    var id: Self { self }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .gif: "GIF (still)"
        case .bmp: "BMP"
        case .webp: "WebP"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .webp: .webP
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    /// Formats where a quality setting means something.
    var isLossy: Bool {
        self == .jpeg || self == .heic || self == .webp
    }

    var supportsAlpha: Bool {
        self != .jpeg && self != .bmp
    }

    /// The formats ImageIO can write on this Mac, in display order.
    static let writable: [ImageFormat] = {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { identifiers.contains($0.type.identifier) }
    }()

    /// The format of an existing file, if it's one of these.
    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              let match = Self.allCases.first(where: { type.conforms(to: $0.type) })
        else { return nil }
        self = match
    }
}

/// ImageIO reading and writing for the image tools. Keeps color profiles and the orientation tag.
enum ImageFiles {
    static func source(at url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { throw FileToolError.unreadable(url.lastPathComponent) }
        return source
    }

    static func properties(of source: CGImageSource) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// Full-resolution pixels, not rotated: the orientation tag travels separately in the properties.
    static func image(from source: CGImageSource, name: String) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw FileToolError.unreadable(name)
        }
        return image
    }

    /// Pixels with the EXIF orientation applied, so they're upright.
    static func uprightImage(from source: CGImageSource, name: String) throws -> CGImage {
        let props = properties(of: source)
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FileToolError.unreadable(name)
        }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// The image drawn over white, for formats without transparency.
    static func flattened(_ image: CGImage) -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Properties to write with an image: all of the source's, or when stripping only the orientation
    /// tag, color profile and DPI, which drops EXIF, GPS, IPTC and maker notes.
    static func outputProperties(from source: [CFString: Any], stripMetadata: Bool, quality: Double?) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if stripMetadata {
            for key in [kCGImagePropertyOrientation, kCGImagePropertyProfileName, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                properties[key] = source[key]
            }
        } else {
            properties = source
        }
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        return properties
    }

    /// Writes one image to `url` in `format`. Works from the source where possible so color
    /// profiles and metadata pass through untouched; flattens transparency for JPEG and BMP.
    static func write(
        source: CGImageSource,
        name: String,
        to url: URL,
        format: ImageFormat,
        quality: Double?,
        stripMetadata: Bool
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw FileToolError.writeFailed(url.lastPathComponent)
        }
        let sourceProperties = properties(of: source)
        let options = outputProperties(from: sourceProperties, stripMetadata: stripMetadata, quality: format.isLossy ? quality : nil)
        let image = try ImageFiles.image(from: source, name: name)
        if !format.supportsAlpha, hasAlpha(image) {
            CGImageDestinationAddImage(destination, flattened(image), options as CFDictionary)
        } else if stripMetadata {
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw FileToolError.writeFailed(url.lastPathComponent)
        }
    }

    /// Writes a decoded image, carrying over `properties` (orientation, color profile, metadata).
    static func write(_ image: CGImage, properties: [CFString: Any], to url: URL, format: ImageFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw FileToolError.writeFailed(url.lastPathComponent)
        }
        let pixels = !format.supportsAlpha && hasAlpha(image) ? flattened(image) : image
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FileToolError.writeFailed(url.lastPathComponent)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
