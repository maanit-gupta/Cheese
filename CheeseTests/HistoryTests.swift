import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Cheese

struct HistoryCommandTests {
    private func command(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil) -> HistoryCommand? {
        HistoryCommand(keyCode: keyCode, modifiers: modifiers, charactersIgnoringModifiers: characters)
    }

    @Test func navigation() {
        // Arrow keys carry the function and numeric-pad flags; those must not matter.
        #expect(command(kVK_UpArrow, [.function, .numericPad]) == .moveUp)
        #expect(command(kVK_DownArrow, [.function, .numericPad]) == .moveDown)
        #expect(command(kVK_Escape) == .close)
    }

    @Test func pasting() {
        #expect(command(kVK_Return) == .paste(plainText: false))
        #expect(command(kVK_ANSI_KeypadEnter, .numericPad) == .paste(plainText: false))
        #expect(command(kVK_Return, .option) == .paste(plainText: true))
        #expect(command(kVK_ANSI_1, .command, "1") == .pasteItem(number: 1))
        #expect(command(kVK_ANSI_9, .command, "9") == .pasteItem(number: 9))
        // AZERTY: the digit keys type symbols, but the key codes still match.
        #expect(command(kVK_ANSI_2, .command, "é") == .pasteItem(number: 2))
    }

    @Test func editing() {
        #expect(command(kVK_ANSI_P, .command, "p") == .togglePin)
        #expect(command(kVK_Delete, .command) == .delete)
    }

    @Test func multiSelection() {
        #expect(command(kVK_UpArrow, [.shift, .function, .numericPad]) == .extendUp)
        #expect(command(kVK_DownArrow, .shift) == .extendDown)
        #expect(command(kVK_ANSI_A, .command, "a") == .selectAll)
        // Cmd+C copies the batch only while several items are selected.
        #expect(HistoryCommand(keyCode: kVK_ANSI_C, modifiers: .command, charactersIgnoringModifiers: "c", isBatch: true) == .copySelection)
        #expect(command(kVK_ANSI_C, .command, "c") == nil)
    }

    @Test func typingIsLeftToTheSearchField() {
        #expect(command(kVK_ANSI_A, [], "a") == nil)
        #expect(command(kVK_Delete) == nil)
        #expect(command(kVK_ANSI_1, [], "1") == nil)
        #expect(command(kVK_ANSI_C, .command, "c") == nil)
        #expect(command(kVK_Return, [.command, .option]) == nil)
    }
}

@MainActor
final class HistoryViewModelTests {
    private let store: ClipStore
    private let model: HistoryViewModel
    private var pasted: [(String, Bool)] = []

    init() throws {
        store = ClipStore(
            container: try ClipStore.makeContainer(storeURL: nil),
            images: ClipImageStorage(directory: makeTemporaryDirectory()),
            historyLimit: { 200 }
        )
        model = HistoryViewModel(store: store)
        model.onPaste = { [unowned self] item, plain in self.pasted.append((item.title, plain)) }
    }

    private func add(_ texts: String...) async {
        for (index, text) in texts.enumerated() {
            await store.add(.text(plain: text, items: [], isRich: false), at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
    }

    private var selectedTitle: String? { model.selection(in: model.visibleItems)?.title }

    @Test func selectionMovesAndClamps() async {
        await add("c", "b", "a")
        #expect(selectedTitle == "a")
        model.perform(.moveUp)
        #expect(selectedTitle == "a")
        model.perform(.moveDown)
        model.perform(.moveDown)
        model.perform(.moveDown)
        #expect(selectedTitle == "c")
    }

    @Test func filteringResetsSelectionToBestMatch() async {
        await add("apple pie", "banana", "cherry")
        model.perform(.moveDown)
        model.query = "ban"
        #expect(model.visibleItems.map(\.title) == ["banana"])
        #expect(selectedTitle == "banana")
    }

    @Test func pasteSelectedAndNumbered() async {
        await add("c", "b", "a")
        model.perform(.moveDown)
        model.perform(.paste(plainText: true))
        model.perform(.pasteItem(number: 3))
        model.perform(.pasteItem(number: 4))
        #expect(pasted.map(\.0) == ["b", "c"])
        #expect(pasted.map(\.1) == [true, false])
    }

    @Test func deleteKeepsSelectionInPlace() async {
        await add("c", "b", "a")
        model.perform(.moveDown)
        model.perform(.delete)
        #expect(model.visibleItems.map(\.title) == ["a", "c"])
        #expect(selectedTitle == "c")
        model.perform(.delete)
        #expect(selectedTitle == "a")
    }

    @Test func pinKeepsSelectionOnItem() async {
        await add("c", "b", "a")
        model.perform(.moveDown)
        model.perform(.moveDown)
        model.perform(.togglePin)
        #expect(model.visibleItems.map(\.title) == ["c", "a", "b"])
        #expect(selectedTitle == "c")
    }

    // MARK: Multi-selection

    private var batched: [([String], ClipBatchMode)] = []

    private func recordBatches() {
        model.onBatch = { [unowned self] items, mode in self.batched.append((items.map(\.title), mode)) }
    }

    @Test func shiftArrowsBatchPasteInSelectionOrder() async {
        await add("c", "b", "a")
        recordBatches()
        model.perform(.extendDown)
        model.perform(.extendDown)
        #expect(model.isBatchSelected)
        model.perform(.paste(plainText: false))
        model.perform(.paste(plainText: true))
        model.perform(.copySelection)
        #expect(batched.map(\.0) == [["a", "b", "c"], ["a", "b", "c"], ["a", "b", "c"]])
        #expect(batched.map(\.1) == [.together, .oneByOne, .copyOnly])
        #expect(pasted.isEmpty)
    }

    @Test func plainArrowEndsBatch() async {
        await add("c", "b", "a")
        recordBatches()
        model.perform(.extendDown)
        model.perform(.moveDown)
        #expect(!model.isBatchSelected)
        model.perform(.paste(plainText: false))
        #expect(pasted.map(\.0) == ["c"])
        #expect(batched.isEmpty)
    }

    @Test func clicksBuildBatch() async {
        await add("c", "b", "a")
        let ids = model.visibleItems.map(\.id)
        model.click(ids[2], modifiers: [])
        model.click(ids[0], modifiers: .command)
        #expect(model.selectedItems(in: model.visibleItems).map(\.title) == ["c", "a"])
        model.click(ids[1], modifiers: .shift)
        #expect(model.selectedItems(in: model.visibleItems).map(\.title) == ["a", "b"])
    }

    @Test func batchDeleteAndPin() async {
        await add("d", "c", "b", "a")
        model.perform(.moveDown)
        model.perform(.extendDown)
        model.perform(.togglePin)
        #expect(model.store.items.filter(\.isPinned).count == 2)
        model.perform(.togglePin)
        #expect(model.store.items.filter(\.isPinned).isEmpty)
    }

    @Test func batchDeleteSelectsNextSurvivor() async {
        await add("d", "c", "b", "a")
        model.perform(.moveDown)
        model.perform(.extendDown)
        model.perform(.delete)
        #expect(model.visibleItems.map(\.title) == ["a", "d"])
        #expect(selectedTitle == "d")
        #expect(!model.isBatchSelected)
    }

    @Test func selectAllCoversFilter() async {
        await add("apple", "avocado", "cherry")
        model.query = "a"
        model.perform(.selectAll)
        let titles = model.selectedItems(in: model.visibleItems).map(\.title)
        #expect(Set(titles) == Set(model.visibleItems.map(\.title)))
        model.query = ""
        #expect(!model.isBatchSelected)
    }
}

struct HistorySelectionTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test func extendGrowsAndShrinksFromAnchor() {
        var selection = HistorySelection()
        selection.select(ids[2])
        selection.extend(by: 1, in: ids)
        selection.extend(by: 1, in: ids)
        #expect(selection.items(in: ids) == [ids[2], ids[3], ids[4]])
        selection.extend(by: 1, in: ids)
        #expect(selection.items(in: ids) == [ids[2], ids[3], ids[4]])
        selection.extend(by: -1, in: ids)
        #expect(selection.items(in: ids) == [ids[2], ids[3]])
        selection.extend(by: -1, in: ids)
        selection.extend(by: -1, in: ids)
        // Past the anchor the batch walks upward, in that order.
        #expect(selection.items(in: ids) == [ids[2], ids[1]])
        #expect(selection.cursor == ids[1])
    }

    @Test func extendWithoutCursorStartsAtFirstItem() {
        var selection = HistorySelection()
        selection.extend(by: 1, in: ids)
        #expect(selection.items(in: ids) == [ids[0], ids[1]])
    }

    @Test func toggleAddsAndRemovesButKeepsOne() {
        var selection = HistorySelection()
        selection.select(ids[0])
        selection.toggle(ids[3], in: ids)
        selection.toggle(ids[1], in: ids)
        #expect(selection.items(in: ids) == [ids[0], ids[3], ids[1]])
        selection.toggle(ids[3], in: ids)
        selection.toggle(ids[0], in: ids)
        #expect(selection.items(in: ids) == [ids[1]])
        #expect(!selection.isBatch(in: ids))
        selection.toggle(ids[1], in: ids)
        #expect(selection.items(in: ids) == [ids[1]])
    }

    @Test func hiddenItemsDropOut() {
        var selection = HistorySelection()
        selection.selectAll(ids)
        #expect(selection.items(in: ids) == ids)
        let filtered = [ids[1], ids[4]]
        #expect(selection.items(in: filtered) == filtered)
        #expect(selection.items(in: [ids[4]]) == [ids[4]])
        #expect(selection.items(in: []).isEmpty)
    }

    @Test func selectResetsBatch() {
        var selection = HistorySelection()
        selection.selectAll(ids)
        selection.select(ids[2])
        #expect(selection.items(in: ids) == [ids[2]])
    }
}

struct ClipBatchTests {
    @Test func textJoinsWithBlankLines() {
        let items = ClipBatch.pasteboardItems(for: [
            ClipDragInput(kind: .text, plainText: "one"),
            ClipDragInput(kind: .richText, plainText: "two"),
        ])
        #expect(items == [ClipDragItem(representations: [.init(type: PasteboardTypeID.plainText, value: .string("one\n\ntwo"))])])
    }

    @Test func imagesGoAsOneItemEach() {
        let first = URL(fileURLWithPath: "/tmp/a.png")
        let second = URL(fileURLWithPath: "/tmp/b.png")
        let items = ClipBatch.pasteboardItems(for: [
            ClipDragInput(kind: .image, imageURL: first),
            ClipDragInput(kind: .text, plainText: "caption"),
            ClipDragInput(kind: .image, imageURL: second),
        ])
        #expect(items.count == 3)
        #expect(items[0].types == [PasteboardTypeID.fileURL, PasteboardTypeID.png])
        #expect(items[1].types == [PasteboardTypeID.plainText])
        #expect(items[2].representations.first?.value == .string(second.absoluteString))
    }

    @Test func emptyBatchWritesNothing() {
        #expect(ClipBatch.pasteboardItems(for: []).isEmpty)
        #expect(ClipBatch.pasteboardItems(for: [ClipDragInput(kind: .text, plainText: "")]).isEmpty)
    }
}

@MainActor
struct PasteboardMonitorTests {
    @Test func reportsOnlyNewChangesAndSkipsOwnWrites() {
        let pasteboard = FakePasteboard()
        pasteboard.setString("before launch")
        var captured: [CapturedClip] = []
        let monitor = PasteboardMonitor(pasteboard: pasteboard) { captured.append($0) }

        monitor.poll()
        #expect(captured.isEmpty)

        pasteboard.setString("copied")
        monitor.poll()
        monitor.poll()
        #expect(captured == [.text(plain: "copied", items: [.init(representations: [.init(type: PasteboardTypeID.plainText, data: Data("copied".utf8))])], isRich: false)])

        pasteboard.setString("pasted from history")
        monitor.ignoreChange(pasteboard.changeCount)
        monitor.poll()
        #expect(captured.count == 1)
    }
}
