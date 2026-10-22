import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cheese

/// An in-memory disk. Bookmarks are the file's path, re-pointed by `move`, like a real bookmark
/// following a rename.
private final class FakeShelfFileSystem: ShelfFileSystem, @unchecked Sendable {
    var files: [String: Data] = [:]
    /// Bookmark → where that file is now.
    var locations: [Data: String] = [:]

    func addFile(_ path: String) -> URL {
        files[path] = Data()
        return URL(filePath: path)
    }

    func move(_ from: String, to: String) {
        files[to] = files.removeValue(forKey: from)
        for (bookmark, path) in locations where path == from {
            locations[bookmark] = to
        }
    }

    func bookmark(for url: URL) -> Data? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard files[path] != nil else { return nil }
        let bookmark = Data(UUID().uuidString.utf8)
        locations[bookmark] = path
        return bookmark
    }

    func resolve(_ bookmark: Data) -> URL? {
        guard let path = locations[bookmark], files[path] != nil else { return nil }
        return URL(filePath: path)
    }

    func fileExists(at url: URL) -> Bool { files[url.standardizedFileURL.path(percentEncoded: false)] != nil }
    func write(_ data: Data, to url: URL) throws { files[url.standardizedFileURL.path(percentEncoded: false)] = data }
    func read(_ url: URL) -> Data? { files[url.standardizedFileURL.path(percentEncoded: false)] }
    func remove(_ url: URL) {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    func files(under folder: URL) -> [URL] {
        var path = folder.standardizedFileURL.path(percentEncoded: false)
        if path.hasSuffix("/") { path.removeLast() }
        let prefix = path + "/"
        return files.keys.filter { $0.hasPrefix(prefix) }.sorted().map { URL(filePath: $0) }
    }
}

@MainActor
struct ShelfStoreTests {
    private let disk = FakeShelfFileSystem()
    private let folder = URL(filePath: "/Shelf", directoryHint: .isDirectory)

    private func makeStore() -> ShelfStore {
        ShelfStore(folder: folder, fileSystem: disk)
    }

    @Test func addsFilesTextLinksAndImages() {
        let store = makeStore()
        let report = disk.addFile("/Users/me/Report.pdf")
        let added = store.add([
            .file(report),
            .text("hello"),
            .link(URL(string: "https://example.com/page")!),
            .imageData(Data([1, 2, 3]), suggestedName: "Screenshot.tiff"),
        ])
        #expect(added.count == 4)
        #expect(store.items.count == 4)
        #expect(store.name(of: store.items[0]) == "Report.pdf")
        #expect(store.name(of: store.items[1]) == "hello")
        #expect(store.name(of: store.items[2]) == "example.com")
        #expect(store.name(of: store.items[3]) == "Screenshot.png")
        #expect(store.texts == ["hello", "https://example.com/page"])
        #expect(store.originalFileURLs == [report])
        #expect(store.fileURLs.count == 2)
    }

    @Test func skipsWhatsAlreadyOnTheShelf() {
        let store = makeStore()
        let report = disk.addFile("/Users/me/Report.pdf")
        store.add([.file(report), .text("hi"), .imageData(Data([9]), suggestedName: nil)])
        let again = store.add([.file(report), .text("hi"), .imageData(Data([9]), suggestedName: nil), .text("   ")])
        #expect(again.isEmpty)
        #expect(store.items.count == 3)
    }

    @Test func filesAreFoundAfterTheyMove() {
        let store = makeStore()
        store.add([.file(disk.addFile("/Users/me/Draft.txt"))])
        disk.move("/Users/me/Draft.txt", to: "/Users/me/Archive/Final.txt")
        let item = store.items[0]
        #expect(store.url(for: item) == URL(filePath: "/Users/me/Archive/Final.txt"))
        #expect(store.name(of: item) == "Final.txt")
        #expect(!store.isMissing(item))
        // Adding the file at its new place is still a duplicate.
        #expect(store.add([.file(URL(filePath: "/Users/me/Archive/Final.txt"))]).isEmpty)
    }

    @Test func deletedOriginalsShowAsMissingWithTheirLastName() {
        let store = makeStore()
        store.add([.file(disk.addFile("/Users/me/Gone.key"))])
        disk.remove(URL(filePath: "/Users/me/Gone.key"))
        let item = store.items[0]
        #expect(store.isMissing(item))
        #expect(store.name(of: item) == "Gone.key")
        #expect(store.fileURLs.isEmpty)
    }

    @Test func persistsAcrossRestarts() {
        let store = makeStore()
        store.add([.file(disk.addFile("/a.txt")), .text("note")])
        let reloaded = makeStore()
        #expect(reloaded.items == store.items)
        reloaded.clear()
        #expect(makeStore().isEmpty)
    }

    @Test func removingLeavesTheOriginalsAlone() {
        let store = makeStore()
        let file = disk.addFile("/Users/me/Keep.txt")
        store.add([.file(file), .text("x")])
        store.remove([store.items[0].id])
        #expect(store.items.count == 1)
        #expect(disk.fileExists(at: file))
    }

    @Test func purgeDeletesOnlyUnreferencedImageData() {
        let store = makeStore()
        store.add([.imageData(Data([1]), suggestedName: "One"), .imageData(Data([2]), suggestedName: "Two")])
        let kept = store.url(for: store.items[1])
        let dropped = store.url(for: store.items[0])
        store.remove([store.items[0].id])
        // Not deleted until purged, so an app reading the dragged file can finish.
        #expect(dropped.map(disk.fileExists) == true)
        store.purgeOrphans()
        #expect(dropped.map(disk.fileExists) == false)
        #expect(kept.map(disk.fileExists) == true)
        #expect(disk.fileExists(at: folder.appending(path: "shelf.json")))
    }

    @Test func imageNamesAreSafe() {
        #expect(ShelfStore.imageFileName(nil) == "Image.png")
        #expect(ShelfStore.imageFileName("photo.heic") == "photo.png")
        #expect(ShelfStore.imageFileName("../../etc/passwd") == "-..-etc-passwd.png")
        #expect(ShelfStore.imageFileName("...") == "Image.png")
    }
}

struct ShelfDragTests {
    private let file = ShelfItem(content: .file(bookmark: Data(), lastPath: "/a"))
    private let text = ShelfItem(content: .text("t"))

    @Test func filesFollowFindersRules() {
        let offered = ShelfDrag.offered(for: [file, text])
        #expect(offered.contains(.move))
        #expect(offered.contains(.copy))
        #expect(offered.contains(.delete))
    }

    @Test func textAndImagesAreCopied() {
        let image = ShelfItem(content: .image(relativePath: "Images/x/Image.png"))
        let offered = ShelfDrag.offered(for: [text, image])
        #expect(offered.contains(.copy))
        #expect(!offered.contains(.move))
    }

    @Test func itemsLeaveOnlyWhenTheDropLanded() {
        #expect(!ShelfDrag.leavesShelf(after: []))
        #expect(ShelfDrag.leavesShelf(after: .copy))
        #expect(ShelfDrag.leavesShelf(after: .move))
        #expect(ShelfDrag.leavesShelf(after: .delete))
    }

    @Test func operationsMatchAppKit() {
        #expect(ShelfDrag.Operations.copy.rawValue == 1)
        #expect(ShelfDrag.Operations.link.rawValue == 2)
        #expect(ShelfDrag.Operations.generic.rawValue == 4)
        #expect(ShelfDrag.Operations.move.rawValue == 16)
        #expect(ShelfDrag.Operations.delete.rawValue == 32)
    }
}

struct ShelfActionTests {
    @Test func pathsAreNewlineSeparated() {
        let urls = [URL(filePath: "/Users/me/A file.txt"), URL(filePath: "/tmp/b")]
        #expect(ShelfActions.pathsText(urls) == "/Users/me/A file.txt\n/tmp/b")
    }

    @Test func zipNames() {
        #expect(ShelfActions.zipName(for: [URL(filePath: "/x/Report.pdf")]) == "Report.zip")
        #expect(ShelfActions.zipName(for: [URL(filePath: "/x/Photos", directoryHint: .isDirectory)]) == "Photos.zip")
        #expect(ShelfActions.zipName(for: [URL(filePath: "/a"), URL(filePath: "/b")]) == "Archive.zip")
    }
}

@MainActor
struct ShelfItemMenuTests {
    @Test func rightClickOffersOpenRevealAndRemove() {
        let store = ShelfStore(folder: FileManager.default.temporaryDirectory.appending(path: "ShelfMenu-\(UUID().uuidString)"))
        store.add([.text("note")])
        let model = ShelfViewModel(store: store, services: ShelfServices())
        let menu = ShelfItemMenu.make(for: store.items[0], model: model)
        #expect(menu.items.map(\.title) == ["Open", "", "Remove from Shelf"])
        // Running "Remove from Shelf" takes the item off.
        let remove = menu.items[2]
        if let action = remove.action {
            NSApp.sendAction(action, to: remove.target, from: remove)
        }
        #expect(store.isEmpty)
    }
}

// MARK: - Adding by drop, paste and the file picker

@MainActor
struct ShelfIntakeTests {
    private let disk = FakeShelfFileSystem()
    private let folder = URL(filePath: "/Shelf", directoryHint: .isDirectory)

    private func makeModel() -> ShelfViewModel {
        ShelfViewModel(store: ShelfStore(folder: folder, fileSystem: disk), services: ShelfServices())
    }

    /// A private pasteboard, so tests never touch the user's clipboard.
    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CheeseShelfTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        fill(pasteboard)
        return pasteboard
    }

    @Test func filePickerURLsAddFilesAndFolders() {
        let model = makeModel()
        let file = disk.addFile("/Users/me/Report.pdf")
        let folderURL = disk.addFile("/Users/me/Photos")
        let added = model.add([file, folderURL].map(ShelfInput.file))
        #expect(added.count == 2)
        #expect(model.store.originalFileURLs == [file, folderURL])
        // Choosing the same files again doesn't duplicate them.
        #expect(model.add([.file(file)]).isEmpty)
    }

    @Test func readsFileURLs() {
        let urls = [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b.png")]
        let board = pasteboard { $0.writeObjects(urls.map { $0 as NSURL }) }
        #expect(ShelfDropReader.inputs(from: board) == urls.map(ShelfInput.file))
    }

    @Test func readsImageDataAsPNGNamedAfterItsAddress() throws {
        let png = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.representation(using: .png, properties: [:]))
        let board = pasteboard { board in
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setString("https://example.com/cat.jpg", forType: .URL)
            board.writeObjects([item])
        }
        #expect(ShelfDropReader.inputs(from: board) == [.imageData(png, suggestedName: "cat.jpg")])
    }

    @Test func readsPlainTextAndLinks() {
        let text = pasteboard { $0.setString("  a note\nwith lines ", forType: .string) }
        #expect(ShelfDropReader.inputs(from: text) == [.text("  a note\nwith lines ")])
        let link = pasteboard { $0.setString(" https://example.com/page ", forType: .string) }
        #expect(ShelfDropReader.inputs(from: link) == [.link(URL(string: "https://example.com/page")!)])
    }

    @Test func readsTheTextOfHTMLOnlyDrags() {
        let board = pasteboard { $0.setData(Data("<p>Hello <b>shelf</b></p>".utf8), forType: .html) }
        guard case let .text(text) = ShelfDropReader.inputs(from: board).first else {
            Issue.record("HTML wasn't read as text")
            return
        }
        #expect(text.contains("Hello shelf"))
    }

    @Test func emptyPasteboardAddsNothing() {
        #expect(ShelfDropReader.inputs(from: pasteboard { _ in }).isEmpty)
    }

    @Test func dragOutRemovesOnlyWhenTheDropLanded() {
        let model = makeModel()
        var leftCount = 0
        model.onItemsLeft = { leftCount += 1 }
        model.add([.text("one"), .text("two")])
        let ids = model.store.items.map(\.id)

        model.dragEnded([ids[0]], operation: [])
        #expect(model.store.items.count == 2)
        #expect(leftCount == 0)

        model.dragEnded([ids[0]], operation: .copy)
        #expect(model.store.items.map(\.id) == [ids[1]])
        #expect(leftCount == 1)
    }

    @Test func draggedOutImagesCarryTheirFileAndPNG() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ShelfDrag-\(UUID().uuidString).png")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ShelfDropReader.pasteboardItem(forImageAt: url)
        #expect(item.string(forType: .fileURL) == url.absoluteString)
        #expect(item.data(forType: .png) == png)
    }

    @Test func shelfKeys() {
        #expect(ShelfKey(keyCode: 49, modifiers: [], characters: " ") == .quickLook)
        #expect(ShelfKey(keyCode: 31, modifiers: .command, characters: "o") == .addFiles)
        #expect(ShelfKey(keyCode: 9, modifiers: .command, characters: "v") == .paste)
        #expect(ShelfKey(keyCode: 9, modifiers: [.command, .shift], characters: "v") == nil)
        #expect(ShelfKey(keyCode: 9, modifiers: [], characters: "v") == nil)
    }

    /// The drop target sits above every card and takes every kind the shelf reads.
    @Test func dropHostTakesEveryAcceptedType() {
        let content = NSHostingView(rootView: Color.clear.frame(width: 520, height: 170))
        let host = CheeseDropHostView(content: content, types: ShelfDropReader.acceptedTypes)
        let registered = Set(host.registeredDraggedTypes)
        for type in [NSPasteboard.PasteboardType.fileURL, .URL, .png, .tiff, .string, .rtfd, .html] {
            #expect(registered.contains(type))
        }
        #expect(content.superview === host)
        // Sized like its SwiftUI content, which is what the panel sizes itself to.
        #expect(host.fittingSize == CGSize(width: 520, height: 170))
        #expect(host.frame.size == CGSize(width: 520, height: 170))
    }
}
