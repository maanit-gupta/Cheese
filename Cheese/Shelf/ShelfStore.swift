import CryptoKit
import Foundation
import os

/// The one shelf: its items, in the order they were added, persisted across restarts.
/// Adding skips anything already on it; removing never deletes the user's files, only the shelf's
/// own copies of dropped image data (and those only through `purgeOrphans`, once nothing can still be
/// reading them).
@MainActor
@Observable
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    /// `~/Library/Application Support/Cheese/Shelf/`: the item list and dropped image data.
    let folder: URL
    @ObservationIgnored private let fileSystem: any ShelfFileSystem

    static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Cheese/Shelf", directoryHint: .isDirectory)
    }

    private var listURL: URL { folder.appending(path: "shelf.json", directoryHint: .notDirectory) }

    init(folder: URL = ShelfStore.defaultFolder, fileSystem: any ShelfFileSystem = SystemShelfFileSystem()) {
        self.folder = folder
        self.fileSystem = fileSystem
        load()
    }

    var isEmpty: Bool { items.isEmpty }

    // MARK: Adding

    /// Adds what isn't on the shelf yet and returns the new items.
    @discardableResult
    func add(_ inputs: [ShelfInput]) -> [ShelfItem] {
        var added: [ShelfItem] = []
        for input in inputs {
            guard let item = makeItem(input), !contains(item) else { continue }
            items.append(item)
            added.append(item)
        }
        if !added.isEmpty {
            save()
        }
        return added
    }

    private func makeItem(_ input: ShelfInput) -> ShelfItem? {
        switch input {
        case let .file(url):
            guard let bookmark = fileSystem.bookmark(for: url) else { return nil }
            return ShelfItem(content: .file(bookmark: bookmark, lastPath: url.standardizedFileURL.path(percentEncoded: false)))
        case let .imageData(data, suggestedName):
            let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            let name = Self.imageFileName(suggestedName)
            let relativePath = "Images/\(digest)/\(name)"
            let url = folder.appending(path: relativePath, directoryHint: .notDirectory)
            if !fileSystem.fileExists(at: url) {
                do {
                    try fileSystem.write(data, to: url)
                } catch {
                    Logger.shelf.error("Couldn't store a dropped image: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            return ShelfItem(content: .image(relativePath: relativePath))
        case let .text(text):
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
            return ShelfItem(content: .text(text))
        case let .link(url):
            return ShelfItem(content: .link(url))
        }
    }

    /// A safe PNG name: the suggested one's base, or "Image".
    static func imageFileName(_ suggested: String?) -> String {
        let base = (suggested.map { ($0 as NSString).deletingPathExtension } ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (base.isEmpty ? "Image" : base) + ".png"
    }

    /// Already on the shelf: the same file (wherever it is now), the same image data, text or link.
    private func contains(_ candidate: ShelfItem) -> Bool {
        items.contains { existing in
            switch (existing.content, candidate.content) {
            case let (.file(existingBookmark, existingPath), .file(_, path)):
                let current = fileSystem.resolve(existingBookmark)?.standardizedFileURL.path(percentEncoded: false) ?? existingPath
                return current == path
            default:
                return existing.content == candidate.content
            }
        }
    }

    // MARK: Removing

    func remove(_ ids: some Collection<ShelfItem.ID>) {
        let ids = Set(ids)
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        if items.count != before {
            save()
        }
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        save()
    }

    /// Deletes stored image data no item refers to any more. Call it a while after items leave, so
    /// an app that was handed a stored file by drag-and-drop has finished reading it.
    func purgeOrphans() {
        let referenced = Set(items.compactMap { item -> String? in
            if case let .image(relativePath) = item.content {
                return folder.appending(path: relativePath).standardizedFileURL.path(percentEncoded: false)
            }
            return nil
        })
        let images = folder.appending(path: "Images", directoryHint: .isDirectory)
        for file in fileSystem.files(under: images) where !referenced.contains(file.standardizedFileURL.path(percentEncoded: false)) {
            fileSystem.remove(file)
            // Its digest folder too, now that it's empty.
            fileSystem.remove(file.deletingLastPathComponent())
        }
    }

    // MARK: Reading items

    /// Where the item's file is now: the resolved bookmark, or the stored image. Nil when it's gone,
    /// and for text and links.
    func url(for item: ShelfItem) -> URL? {
        switch item.content {
        case let .file(bookmark, _):
            return fileSystem.resolve(bookmark)
        case let .image(relativePath):
            let url = folder.appending(path: relativePath, directoryHint: .notDirectory)
            return fileSystem.fileExists(at: url) ? url : nil
        case .text, .link:
            return nil
        }
    }

    /// The original was deleted or its volume is gone.
    func isMissing(_ item: ShelfItem) -> Bool {
        switch item.content {
        case .file, .image: url(for: item) == nil
        case .text, .link: false
        }
    }

    func name(of item: ShelfItem) -> String {
        switch item.content {
        case let .file(_, lastPath):
            return (url(for: item)?.lastPathComponent) ?? (lastPath as NSString).lastPathComponent
        case let .image(relativePath):
            return (relativePath as NSString).lastPathComponent
        case let .text(text):
            let line = text.split(whereSeparator: \.isNewline).first { $0.contains { !$0.isWhitespace } } ?? ""
            return line.trimmingCharacters(in: .whitespaces)
        case let .link(url):
            return url.host() ?? url.absoluteString
        }
    }

    /// Files and folders that are still there, plus stored images, in shelf order.
    var fileURLs: [URL] {
        items.compactMap(url(for:))
    }

    /// The user's own files and folders only (not stored images), for Copy Paths and Zip.
    var originalFileURLs: [URL] {
        items.filter(\.isFile).compactMap(url(for:))
    }

    var texts: [String] {
        items.compactMap { item in
            switch item.content {
            case let .text(text): text
            case let .link(url): url.absoluteString
            case .file, .image: nil
            }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = fileSystem.read(listURL) else { return }
        do {
            items = try JSONDecoder().decode([ShelfItem].self, from: data)
        } catch {
            Logger.shelf.error("Couldn't read the shelf: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try fileSystem.write(try JSONEncoder().encode(items), to: listURL)
        } catch {
            Logger.shelf.error("Couldn't save the shelf: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Drag-out bookkeeping: what the shelf offers a drop target, and whether a finished drag took the
/// items. Mirrors `NSDragOperation` without AppKit, so it's unit-tested.
enum ShelfDrag {
    struct Operations: OptionSet, Sendable {
        let rawValue: UInt
        static let copy = Operations(rawValue: 1 << 0)
        static let link = Operations(rawValue: 1 << 1)
        static let generic = Operations(rawValue: 1 << 2)
        static let move = Operations(rawValue: 1 << 4)
        static let delete = Operations(rawValue: 1 << 5)
    }

    /// Files offer copy and move, and Finder picks by its own rules: same volume moves, another volume
    /// copies, Option forces a copy, the Trash deletes. The shelf only holds references, so whatever
    /// Finder does is what the user meant. Text, links and stored image data are copied.
    static func offered(for items: [ShelfItem]) -> Operations {
        items.contains(where: \.isFile) ? [.copy, .move, .generic, .delete] : [.copy, .generic]
    }

    /// Whether the dragged items leave the shelf: they do whenever the drop landed somewhere.
    static func leavesShelf(after operation: Operations) -> Bool {
        !operation.isEmpty
    }
}
