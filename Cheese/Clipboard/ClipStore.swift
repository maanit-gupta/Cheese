import Foundation
import Observation
import SwiftData
import os

/// Clipboard history: persistence, de-duplication and retention.
@MainActor
@Observable
final class ClipStore {
    /// Pinned items first (in the order they were pinned), then everything else, most recent first.
    private(set) var items: [ClipItem] = []

    /// Called after a new image item is stored, with its id and PNG file, so Live Text can index it.
    @ObservationIgnored var onImageItemAdded: ((UUID, URL) -> Void)?

    @ObservationIgnored let images: ClipImageStorage
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let historyLimit: () -> Int

    init(container: ModelContainer, images: ClipImageStorage, historyLimit: @escaping () -> Int) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.images = images
        self.historyLimit = historyLimit
        reload()
    }

    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Cheese/History.store", directoryHint: .notDirectory)
    }

    static func makeContainer(storeURL: URL? = defaultStoreURL) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let storeURL {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(url: storeURL)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        }
        return try ModelContainer(for: ClipItem.self, configurations: configuration)
    }

    func item(withID id: UUID) -> ClipItem? {
        items.first { $0.id == id }
    }

    // MARK: Adding

    func add(_ clip: CapturedClip, at date: Date = .now) async {
        switch clip {
        case let .text(plain, pasteboardItems, isRich):
            let hash = ClipHasher.hash(text: plain)
            if let existing = item(withHash: hash) {
                // Same text again, possibly with different formatting: keep the newest representations.
                existing.kindRaw = (isRich ? ClipKind.richText : .text).rawValue
                existing.pasteboardItems = pasteboardItems
                bump(existing, to: date)
            } else {
                insert(ClipItem(
                    kind: isRich ? .richText : .text,
                    contentHash: hash,
                    plainText: plain,
                    pasteboardItems: pasteboardItems,
                    date: date
                ))
            }

        case let .files(urls):
            let hash = ClipHasher.hash(files: urls)
            if let existing = item(withHash: hash) {
                bump(existing, to: date)
            } else {
                insert(ClipItem(kind: .files, contentHash: hash, files: urls, date: date))
            }

        case let .image(data):
            let hash = await images.hash(data)
            if let existing = item(withHash: hash) {
                bump(existing, to: date)
                break
            }
            let stored: StoredImage
            do {
                stored = try await images.save(data)
            } catch {
                Logger.clipboard.error("Couldn't store copied image: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Another copy of the same image may have landed while this one was being written.
            if let existing = item(withHash: hash) {
                await images.delete(stored.fileName)
                bump(existing, to: date)
                break
            }
            let item = ClipItem(kind: .image, contentHash: hash, image: stored, date: date)
            insert(item)
            onImageItemAdded?(item.id, images.url(for: stored.fileName))
        }
        enforceRetention()
    }

    private func item(withHash hash: String) -> ClipItem? {
        items.first { $0.contentHash == hash }
    }

    private func insert(_ item: ClipItem) {
        context.insert(item)
        save()
    }

    private func bump(_ item: ClipItem, to date: Date) {
        item.lastCopiedAt = date
        save()
    }

    // MARK: Editing

    /// Moves an item to the top, e.g. after pasting it.
    func touch(_ id: UUID, at date: Date = .now) {
        guard let item = item(withID: id) else { return }
        bump(item, to: date)
    }

    func togglePin(_ id: UUID, at date: Date = .now) {
        guard let item = item(withID: id) else { return }
        item.isPinned.toggle()
        item.pinnedAt = item.isPinned ? date : nil
        if !item.isPinned {
            // An unpinned item rejoins the limited history at the top.
            item.lastCopiedAt = date
        }
        save()
        enforceRetention()
    }

    /// Replaces a text item's text with the user's live edit and moves it to the top, since the edit
    /// goes onto the clipboard. The edit becomes the item's only representation: stale RTF or HTML
    /// would paste the old text back. Another item already holding the same text merges into this
    /// one (keeping its pin), so the text never shows up twice.
    /// - Returns: false when nothing changed: no such text item, an empty edit, or the same text.
    @discardableResult
    func updateText(for id: UUID, newText: String, at date: Date = .now) -> Bool {
        guard let item = item(withID: id), item.kind == .text || item.kind == .richText,
              !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newText != item.plainText
        else { return false }

        let hash = ClipHasher.hash(text: newText)
        let duplicates = items.filter { $0.id != id && $0.contentHash == hash }
        if !item.isPinned, let pinned = duplicates.first(where: \.isPinned) {
            item.isPinned = true
            item.pinnedAt = pinned.pinnedAt ?? date
        }
        item.plainText = newText
        item.contentHash = hash
        item.kindRaw = ClipKind.text.rawValue
        item.pasteboardItems = []
        item.lastCopiedAt = date
        // Text items keep nothing on disk, so there are no files to clean up.
        for duplicate in duplicates {
            context.delete(duplicate)
        }
        save()
        return true
    }

    func delete(_ id: UUID) {
        guard let item = item(withID: id) else { return }
        remove([item])
    }

    /// Removes every unpinned item.
    func clearHistory() {
        remove(items.filter { !$0.isPinned })
    }

    /// Removes everything, pinned items included.
    func clearAll() {
        remove(items)
    }

    func setRecognizedText(_ text: String, for id: UUID) {
        guard let item = item(withID: id), item.kind == .image else { return }
        item.recognizedText = text
        save()
    }

    /// Image items that haven't been through Live Text yet.
    var imageItemsAwaitingRecognition: [(id: UUID, url: URL)] {
        items.compactMap { item in
            guard item.kind == .image, item.recognizedText == nil, let fileName = item.imageFileName else { return nil }
            return (item.id, images.url(for: fileName))
        }
    }

    func enforceRetention() {
        let ids = Set(RetentionPolicy.itemsToRemove(from: items.map(\.retentionCandidate), limit: historyLimit()))
        guard !ids.isEmpty else { return }
        remove(items.filter { ids.contains($0.id) })
    }

    /// Deletes image files that no item refers to.
    func removeOrphanedImages() async {
        await images.deleteFiles(notIn: Set(items.compactMap(\.imageFileName)))
    }

    private func remove(_ doomed: [ClipItem]) {
        guard !doomed.isEmpty else { return }
        let fileNames = doomed.compactMap(\.imageFileName)
        for item in doomed {
            context.delete(item)
        }
        save()
        if !fileNames.isEmpty {
            Task { [images] in
                for fileName in fileNames {
                    await images.delete(fileName)
                }
            }
        }
    }

    // MARK: Persistence

    private func save() {
        do {
            try context.save()
        } catch {
            Logger.clipboard.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }

    private func reload() {
        let all: [ClipItem]
        do {
            all = try context.fetch(FetchDescriptor<ClipItem>())
        } catch {
            Logger.clipboard.error("Couldn't load history: \(error.localizedDescription, privacy: .public)")
            return
        }
        items = all.sorted(by: Self.displayOrder)
    }

    private static func displayOrder(_ lhs: ClipItem, _ rhs: ClipItem) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.isPinned, let left = lhs.pinnedAt, let right = rhs.pinnedAt, left != right {
            return left < right
        }
        return lhs.lastCopiedAt > rhs.lastCopiedAt
    }
}
