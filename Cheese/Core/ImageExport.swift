import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// A captured or edited image at native pixel resolution, with the display scale it came from.
struct CapturedImage: Sendable {
    var image: CGImage
    /// Pixels per point: 2 on Retina displays. Recorded in the PNG so apps show it at the right size.
    var scale: CGFloat

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

enum ImageExportError: LocalizedError {
    case encodingFailed

    var errorDescription: String? { "The image couldn't be encoded as PNG." }
}

/// PNG encoding, copying and saving shared by screenshots, the editor and scrolling capture.
enum ImageExport {
    static func pngData(for captured: CapturedImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageExportError.encodingFailed
        }
        let dpi = 72 * captured.scale
        let properties = ["DPIWidth": dpi, "DPIHeight": dpi] as CFDictionary
        CGImageDestinationAddImage(destination, captured.image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ImageExportError.encodingFailed }
        return data as Data
    }

    /// Encodes off the main actor, since large captures take a while.
    @concurrent
    static func pngDataInBackground(for captured: CapturedImage) async throws -> Data {
        try pngData(for: captured)
    }

    @MainActor
    static func copyToPasteboard(_ png: Data, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    /// Encodes and copies. Returns false (after logging) when encoding fails.
    @MainActor
    @discardableResult
    static func copy(_ captured: CapturedImage) async -> Bool {
        do {
            copyToPasteboard(try await pngDataInBackground(for: captured))
            return true
        } catch {
            Logger.core.error("Couldn't copy image: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Writes a PNG into `folder` with a timestamped name and returns where it went.
    @concurrent
    static func save(_ captured: CapturedImage, in folder: URL, date: Date = .now) async throws -> URL {
        let data = try pngData(for: captured)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ScreenshotNaming.uniqueURL(in: folder, date: date) { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// File names for saved screenshots: `Cheese 2026-10-22 at 14.05.09.png`.
enum ScreenshotNaming {
    static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "Cheese \(c.year ?? 0)-\(pad(c.month))-\(pad(c.day)) at \(pad(c.hour)).\(pad(c.minute)).\(pad(c.second))"
    }

    /// The first name that doesn't exist yet, adding " (2)", " (3)"… for captures within the same second.
    static func uniqueURL(in folder: URL, date: Date, timeZone: TimeZone = .current, exists: (URL) -> Bool) -> URL {
        let base = baseName(for: date, timeZone: timeZone)
        var candidate = folder.appending(path: base + ".png", directoryHint: .notDirectory)
        var counter = 2
        while exists(candidate) {
            candidate = folder.appending(path: "\(base) (\(counter)).png", directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }
}
