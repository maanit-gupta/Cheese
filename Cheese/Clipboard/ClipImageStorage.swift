import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

struct StoredImage: Equatable, Sendable {
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ClipImageStorageError: Error {
    case unreadableImage
    case encodingFailed
}

/// PNG files for image history items. All file work happens on this actor, off the main thread.
actor ClipImageStorage {
    let directory: URL

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Cheese/Images", directoryHint: .isDirectory)
    }

    init(directory: URL = ClipImageStorage.defaultDirectory) {
        self.directory = directory
    }

    nonisolated func url(for fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    func hash(_ data: Data) -> String {
        ClipHasher.hash(imageData: data)
    }

    /// Writes the image as PNG, converting from TIFF/JPEG/HEIC when needed.
    func save(_ data: Data) throws -> StoredImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ClipImageStorageError.unreadableImage }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + ".png"
        let url = url(for: fileName)

        if CGImageSourceGetType(source) as String? == UTType.png.identifier {
            try data.write(to: url, options: .atomic)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw ClipImageStorageError.encodingFailed }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ClipImageStorageError.encodingFailed }
        }
        return StoredImage(fileName: fileName, pixelWidth: image.width, pixelHeight: image.height)
    }

    func data(for fileName: String) throws -> Data {
        try Data(contentsOf: url(for: fileName))
    }

    func delete(_ fileName: String) {
        do {
            try FileManager.default.removeItem(at: url(for: fileName))
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            Logger.clipboard.error("Couldn't delete image \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes image files no history item refers to, e.g. left behind by a crash.
    func deleteFiles(notIn keep: Set<String>) {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            Logger.clipboard.error("Couldn't list images: \(error.localizedDescription, privacy: .public)")
            return
        }
        for url in contents where !keep.contains(url.lastPathComponent) {
            delete(url.lastPathComponent)
        }
    }
}
