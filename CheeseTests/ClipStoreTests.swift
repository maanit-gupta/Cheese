import Foundation
import Testing
@testable import Cheese

@MainActor
final class ClipStoreTests {
    private let imageDirectory = makeTemporaryDirectory()
    private var limit = 200
    private lazy var store: ClipStore = {
        do {
            return ClipStore(
                container: try ClipStore.makeContainer(storeURL: nil),
                images: ClipImageStorage(directory: imageDirectory),
                historyLimit: { [unowned self] in self.limit }
            )
        } catch {
            fatalError("Couldn't create in-memory store: \(error)")
        }
    }()

    deinit {
        try? FileManager.default.removeItem(at: imageDirectory)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + seconds)
    }

    private func addText(_ text: String, at seconds: TimeInterval) async {
        await store.add(.text(plain: text, items: [], isRich: false), at: date(seconds))
    }

    private var titles: [String] { store.items.map(\.title) }

    private func imageFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: imageDirectory.path(percentEncoded: false))) ?? []
    }

    @Test func newestFirst() async {
        await addText("one", at: 1)
        await addText("two", at: 2)
        await addText("three", at: 3)
        #expect(titles == ["three", "two", "one"])
    }

    @Test func recopyMovesToTopInsteadOfDuplicating() async {
        await addText("one", at: 1)
        await addText("two", at: 2)
        await addText("one", at: 3)
        #expect(titles == ["one", "two"])
        // Consecutive duplicates collapse too.
        await addText("one", at: 4)
        #expect(titles == ["one", "two"])
    }

    @Test func recopyKeepsNewestFormatting() async throws {
        let rtf = PasteboardItemContent(representations: [.init(type: PasteboardTypeID.rtf, data: Data("x".utf8))])
        await addText("same", at: 1)
        await store.add(.text(plain: "same", items: [rtf], isRich: true), at: date(2))
        let item = try #require(store.items.first)
        #expect(store.items.count == 1)
        #expect(item.kind == .richText)
        #expect(item.pasteboardItems == [rtf])
    }

    @Test func retentionDropsOldestUnpinned() async throws {
        limit = 2
        await addText("one", at: 1)
        let first = try #require(store.items.first)
        store.togglePin(first.id, at: date(1.5))
        await addText("two", at: 2)
        await addText("three", at: 3)
        await addText("four", at: 4)
        #expect(titles == ["one", "four", "three"])
    }

    @Test func pinnedComeFirstInPinOrder() async throws {
        await addText("a", at: 1)
        await addText("b", at: 2)
        await addText("c", at: 3)
        let a = try #require(store.items.first { $0.title == "a" })
        let b = try #require(store.items.first { $0.title == "b" })
        store.togglePin(b.id, at: date(4))
        store.togglePin(a.id, at: date(5))
        #expect(titles == ["b", "a", "c"])

        store.togglePin(b.id, at: date(6))
        #expect(titles == ["a", "b", "c"])
        #expect(store.items.first { $0.title == "b" }?.isPinned == false)
    }

    @Test func clearHistoryKeepsPinned() async throws {
        await addText("keep", at: 1)
        await addText("drop", at: 2)
        let keep = try #require(store.items.first { $0.title == "keep" })
        store.togglePin(keep.id)
        store.clearHistory()
        #expect(titles == ["keep"])
        store.clearAll()
        #expect(store.items.isEmpty)
    }

    @Test func imagesAreStoredAsPNGAndDeduplicated() async throws {
        let tiff = TestImages.encoded(width: 6, height: 2, type: .tiff)
        var indexed: [UUID] = []
        store.onImageItemAdded = { id, _ in indexed.append(id) }

        await store.add(.image(data: tiff), at: date(1))
        await store.add(.image(data: tiff), at: date(2))

        let item = try #require(store.items.first)
        #expect(store.items.count == 1)
        #expect(item.kind == .image)
        #expect(item.imagePixelWidth == 6)
        #expect(item.imagePixelHeight == 2)
        #expect(item.title == "Image 6 × 2")
        #expect(indexed == [item.id])
        #expect(imageFiles().count == 1)
        #expect(imageFiles().first?.hasSuffix(".png") == true)
    }

    @Test func deletingAnImageItemDeletesItsFile() async throws {
        await store.add(.image(data: TestImages.encoded()), at: date(1))
        let item = try #require(store.items.first)
        #expect(imageFiles().count == 1)

        store.delete(item.id)
        #expect(store.items.isEmpty)
        // File deletion is asynchronous on the storage actor; wait for it.
        for _ in 0..<50 where !imageFiles().isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(imageFiles().isEmpty)
    }

    @Test func orphanedImagesAreRemoved() async throws {
        await store.add(.image(data: TestImages.encoded()), at: date(1))
        let orphan = imageDirectory.appending(path: "orphan.png")
        try Data([1]).write(to: orphan)
        #expect(imageFiles().count == 2)

        await store.removeOrphanedImages()
        #expect(imageFiles() == [try #require(store.items.first?.imageFileName)])
    }

    @Test func recognizedTextIsSearchable() async throws {
        await store.add(.image(data: TestImages.encoded()), at: date(1))
        let item = try #require(store.items.first)
        #expect(store.imageItemsAwaitingRecognition.map(\.id) == [item.id])

        store.setRecognizedText("Invoice 4521", for: item.id)
        #expect(item.searchText.contains("Invoice 4521"))
        #expect(store.imageItemsAwaitingRecognition.isEmpty)
    }

    @Test func filesAreStoredAsURLs() async throws {
        let urls = [URL(filePath: "/tmp/report.pdf"), URL(filePath: "/tmp/notes.txt")]
        await store.add(.files(urls), at: date(1))
        await store.add(.files([urls[0]]), at: date(2))
        #expect(titles == ["report.pdf", "2 files"])
        #expect(store.items.last?.fileURLs == urls)
    }
}
