import Foundation

/// One thing parked on the shelf. Files and folders are kept as bookmarks, so they're found again
/// after being renamed or moved; dragged-in image data and text live in the shelf's own folder.
struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        /// A file or folder somewhere on disk. `lastPath` names it when the bookmark no longer resolves.
        case file(bookmark: Data, lastPath: String)
        /// Image data dropped on the shelf, stored as a PNG at this path inside the shelf folder.
        case image(relativePath: String)
        case text(String)
        case link(URL)
    }

    var id = UUID()
    var content: Content
    var addedAt = Date()

    var isFile: Bool {
        if case .file = content { return true }
        return false
    }

    /// Text and links show as chips rather than cards.
    var isChip: Bool {
        switch content {
        case .text, .link: true
        case .file, .image: false
        }
    }
}

/// What a dropped or pasted thing turns into before it's added.
enum ShelfInput: Equatable, Sendable {
    case file(URL)
    case imageData(Data, suggestedName: String?)
    case text(String)
    case link(URL)
}

/// Disk access the shelf needs, behind a protocol so `ShelfStore` is tested without the real disk.
protocol ShelfFileSystem: Sendable {
    func bookmark(for url: URL) -> Data?
    /// The bookmark's current location, or nil when the original is gone.
    func resolve(_ bookmark: Data) -> URL?
    func fileExists(at url: URL) -> Bool
    func write(_ data: Data, to url: URL) throws
    func read(_ url: URL) -> Data?
    func remove(_ url: URL)
    /// Every regular file under `folder`, recursively.
    func files(under folder: URL) -> [URL]
}

struct SystemShelfFileSystem: ShelfFileSystem {
    func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return nil }
        return url
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func files(under folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
