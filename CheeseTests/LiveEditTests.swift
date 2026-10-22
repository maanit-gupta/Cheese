import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Cheese

@MainActor
final class ClipStoreUpdateTextTests {
    private let store: ClipStore

    init() throws {
        store = ClipStore(
            container: try ClipStore.makeContainer(storeURL: nil),
            images: ClipImageStorage(directory: makeTemporaryDirectory()),
            historyLimit: { 200 }
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + seconds)
    }

    private func addText(_ text: String, at seconds: TimeInterval, rich: Bool = false) async {
        let items = rich ? [PasteboardItemContent(representations: [
            .init(type: PasteboardTypeID.plainText, data: Data(text.utf8)),
            .init(type: PasteboardTypeID.rtf, data: Data("{\\rtf1 \(text)}".utf8)),
        ])] : []
        await store.add(.text(plain: text, items: items, isRich: rich), at: date(seconds))
    }

    private func item(titled title: String) throws -> ClipItem {
        try #require(store.items.first { $0.title == title })
    }

    @Test func editReplacesTextAndMovesToTop() async throws {
        await addText("first", at: 1)
        await addText("second", at: 2)
        let first = try item(titled: "first")

        #expect(store.updateText(for: first.id, newText: "first, edited", at: date(3)))
        #expect(store.items.map(\.title) == ["first, edited", "second"])
        #expect(first.contentHash == ClipHasher.hash(text: "first, edited"))
        #expect(first.searchText == "first, edited")
    }

    @Test func editDropsStaleRichText() async throws {
        await addText("bold", at: 1, rich: true)
        let rich = try item(titled: "bold")
        #expect(rich.kind == .richText)

        #expect(store.updateText(for: rich.id, newText: "plain now", at: date(2)))
        #expect(rich.kind == .text)
        #expect(rich.pasteboardItems.isEmpty)
    }

    @Test func editMatchingAnotherItemMergesInsteadOfDuplicating() async throws {
        await addText("keep me", at: 1)
        await addText("draft", at: 2)
        let other = try item(titled: "keep me")
        store.togglePin(other.id, at: date(3))
        let draft = try item(titled: "draft")

        #expect(store.updateText(for: draft.id, newText: "keep me", at: date(4)))
        #expect(store.items.count == 1)
        #expect(store.items.first?.id == draft.id)
        // The merged-away copy was pinned, so the survivor is.
        #expect(store.items.first?.isPinned == true)

        // A re-copy of the same text still finds the one item rather than adding a second.
        await addText("keep me", at: 5)
        #expect(store.items.count == 1)
    }

    @Test func noChangeForEmptySameOrNonText() async throws {
        await addText("same", at: 1)
        await store.add(.files([URL(filePath: "/tmp/a.txt")]), at: date(2))
        let text = try item(titled: "same")
        let files = try item(titled: "a.txt")

        #expect(!store.updateText(for: text.id, newText: "same"))
        #expect(!store.updateText(for: text.id, newText: "  \n "))
        #expect(!store.updateText(for: files.id, newText: "nope"))
        #expect(!store.updateText(for: UUID(), newText: "nope"))
        #expect(text.plainText == "same")
    }
}

struct ClipDragProviderTests {
    private let imageURL = URL(filePath: "/Users/me/Library/Application Support/Cheese/Images/abc.png")

    @Test func imagesOfferTheirFileAndPNGBytes() {
        let items = ClipDragProvider.items(for: ClipDragInput(kind: .image, plainText: nil, imageURL: imageURL))
        #expect(items.count == 1)
        #expect(items.first?.representations == [
            .init(type: PasteboardTypeID.fileURL, value: .string(imageURL.absoluteString)),
            .init(type: PasteboardTypeID.png, value: .contentsOf(imageURL)),
        ])
    }

    @Test func plainTextIsUTF8Only() {
        let items = ClipDragProvider.items(for: ClipDragInput(kind: .text, plainText: "héllo"))
        #expect(items == [ClipDragItem(representations: [.init(type: PasteboardTypeID.plainText, value: .string("héllo"))])])
    }

    @Test func unEditedRichTextKeepsItsFormatting() {
        let rtf = Data("{\\rtf1 hi}".utf8)
        let html = Data("<b>hi</b>".utf8)
        let stored = PasteboardItemContent(representations: [
            .init(type: PasteboardTypeID.plainText, data: Data("hi".utf8)),
            .init(type: PasteboardTypeID.rtf, data: rtf),
            .init(type: "com.example.private", data: Data()),
            .init(type: PasteboardTypeID.html, data: html),
        ])
        let items = ClipDragProvider.items(for: ClipDragInput(kind: .richText, plainText: "hi", pasteboardItems: [stored]))
        #expect(items.first?.representations == [
            .init(type: PasteboardTypeID.plainText, value: .string("hi")),
            .init(type: PasteboardTypeID.rtf, value: .data(rtf)),
            .init(type: PasteboardTypeID.html, value: .data(html)),
        ])
    }

    @MainActor
    @Test func editedTextDragsAsPlainText() async throws {
        let store = ClipStore(
            container: try ClipStore.makeContainer(storeURL: nil),
            images: ClipImageStorage(directory: makeTemporaryDirectory()),
            historyLimit: { 200 }
        )
        let stored = PasteboardItemContent(representations: [.init(type: PasteboardTypeID.rtf, data: Data("{\\rtf1 old}".utf8))])
        await store.add(.text(plain: "old", items: [stored], isRich: true))
        let item = try #require(store.items.first)
        store.updateText(for: item.id, newText: "new")

        let items = ClipDragProvider.items(for: ClipDragInput(item: item, imageURL: nil))
        #expect(items.first?.types == [PasteboardTypeID.plainText])
        #expect(items.first?.representations.first?.value == .string("new"))
    }

    @Test func filesAreOneItemPerURL() {
        let urls = [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/folder", directoryHint: .isDirectory)]
        let items = ClipDragProvider.items(for: ClipDragInput(kind: .files, plainText: nil, fileURLs: urls))
        #expect(items.map(\.types) == [[PasteboardTypeID.fileURL], [PasteboardTypeID.fileURL]])
        #expect(items.last?.representations.first?.value == .string("file:///tmp/folder/"))
    }

    @Test func nothingToDragGivesNoItems() {
        #expect(ClipDragProvider.items(for: ClipDragInput(kind: .text, plainText: "")).isEmpty)
        #expect(ClipDragProvider.items(for: ClipDragInput(kind: .image, plainText: nil)).isEmpty)
        #expect(ClipDragProvider.items(for: ClipDragInput(kind: .files, plainText: nil)).isEmpty)
    }

    @Test func popoverFadesOnlyOutsideItsFrame() {
        let frame = CGRect(x: 100, y: 500, width: 680, height: 460)
        #expect(!ClipDragProvider.fadesPopover(pointer: CGPoint(x: 400, y: 700), popoverFrame: frame))
        #expect(ClipDragProvider.fadesPopover(pointer: CGPoint(x: 90, y: 700), popoverFrame: frame))
        #expect(ClipDragProvider.fadesPopover(pointer: CGPoint(x: 400, y: 200), popoverFrame: frame))
    }
}

struct LiveEditCommandTests {
    private func command(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil, editing: Bool) -> HistoryCommand? {
        HistoryCommand(keyCode: keyCode, modifiers: modifiers, charactersIgnoringModifiers: characters, isEditing: editing)
    }

    @Test func commandEStartsAndEndsEditing() {
        #expect(command(kVK_ANSI_E, .command, "e", editing: false) == .toggleEdit)
        #expect(command(kVK_ANSI_E, .command, "e", editing: true) == .toggleEdit)
    }

    @Test func whileEditingOnlyReturnEscAndEAreCommands() {
        #expect(command(kVK_Return, .command, editing: true) == .saveEditAndPaste)
        #expect(command(kVK_Escape, editing: true) == .endEdit)
        // Everything else is typing: arrows move the caret, Return is a new line.
        #expect(command(kVK_UpArrow, editing: true) == nil)
        #expect(command(kVK_DownArrow, editing: true) == nil)
        #expect(command(kVK_Return, editing: true) == nil)
        #expect(command(kVK_Return, .option, editing: true) == nil)
        #expect(command(kVK_ANSI_P, .command, "p", editing: true) == nil)
        #expect(command(kVK_Delete, .command, editing: true) == nil)
        #expect(command(kVK_ANSI_1, .command, "1", editing: true) == nil)
    }

    @Test func commandReturnIsNothingOutsideEditing() {
        #expect(command(kVK_Return, .command, editing: false) == nil)
    }
}

@MainActor
final class LiveEditFlowTests {
    private let store: ClipStore
    private let model: HistoryViewModel
    private var pasted: [(text: String?, plain: Bool)] = []
    private var synced: [String?] = []

    init() throws {
        store = ClipStore(
            container: try ClipStore.makeContainer(storeURL: nil),
            images: ClipImageStorage(directory: makeTemporaryDirectory()),
            historyLimit: { 200 }
        )
        model = HistoryViewModel(store: store)
        model.onPaste = { [unowned self] item, plain in self.pasted.append((item.plainText, plain)) }
        model.onEditSaved = { [unowned self] item in self.synced.append(item.plainText) }
    }

    private func add(_ texts: String...) async {
        for (index, text) in texts.enumerated() {
            await store.add(.text(plain: text, items: [], isRich: false), at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
    }

    @Test func escSavesEditAndKeepsPanelOpen() async {
        await add("hello")
        var closed = false
        model.onClose = { closed = true }
        model.perform(.toggleEdit)
        #expect(model.isEditingText)
        model.draftText = "hello world"
        model.perform(.endEdit)

        #expect(!model.isEditingText)
        #expect(!closed)
        #expect(store.items.map(\.plainText) == ["hello world"])
        #expect(synced == ["hello world"])
    }

    @Test func unchangedEditSyncsNothing() async {
        await add("hello")
        model.perform(.toggleEdit)
        model.perform(.toggleEdit)
        #expect(!model.isEditingText)
        #expect(synced.isEmpty)
    }

    @Test func commandReturnSavesAndPastesTheEdit() async {
        await add("draft")
        model.perform(.toggleEdit)
        model.draftText = "final"
        model.perform(.saveEditAndPaste)

        #expect(!model.isEditingText)
        #expect(pasted.map(\.text) == ["final"])
        #expect(pasted.map(\.plain) == [false])
        // Pasting puts it on the clipboard, so the save doesn't write it a second time.
        #expect(synced.isEmpty)
    }

    @Test func selectingAnotherItemSavesTheEdit() async throws {
        await add("b", "a")
        model.perform(.toggleEdit)
        model.draftText = "a2"
        model.perform(.moveDown)

        #expect(!model.isEditingText)
        #expect(Set(store.items.compactMap(\.plainText)) == ["a2", "b"])
    }

    @Test func closingThePanelKeepsTheEdit() async {
        await add("note")
        model.perform(.toggleEdit)
        model.draftText = "note, kept"
        model.panelClosed()
        #expect(store.items.first?.plainText == "note, kept")
    }

    @Test func draggingTheEditSavesItFirstAndStaysInEditMode() async throws {
        await add("chat message")
        model.perform(.toggleEdit)
        model.draftText = "chat message, edited"
        let id = try #require(model.editingID)

        let drag = try #require(model.dragContents(for: id))
        #expect(drag.items.first?.representations.first?.value == .string("chat message, edited"))
        #expect(store.items.first?.plainText == "chat message, edited")
        #expect(model.isEditingText)
    }

    @Test func onlyTextItemsCanBeEdited() async {
        await store.add(.files([URL(filePath: "/tmp/a.txt")]))
        model.perform(.toggleEdit)
        #expect(!model.isEditingText)
    }

    @Test func savedEditOnThePasteboardIsNotRecordedAgain() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CheeseTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let paster = Paster(pasteboard: pasteboard, images: store.images)
        var captured: [CapturedClip] = []
        let monitor = PasteboardMonitor(pasteboard: SystemPasteboard(pasteboard: pasteboard)) { captured.append($0) }

        let rich = PasteboardItemContent(representations: [.init(type: PasteboardTypeID.rtf, data: Data("{\\rtf1 old}".utf8))])
        await store.add(.text(plain: "old", items: [rich], isRich: true))
        let item = try #require(store.items.first)
        store.updateText(for: item.id, newText: "new")

        let changeCount = try #require(await paster.write(item, plainTextOnly: true))
        monitor.ignoreChange(changeCount)
        monitor.poll()

        #expect(captured.isEmpty)
        #expect(store.items.count == 1)
        #expect(pasteboard.string(forType: .string) == "new")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }
}
