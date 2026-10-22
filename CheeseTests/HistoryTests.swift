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

    @Test func typingIsLeftToTheSearchField() {
        #expect(command(kVK_ANSI_A, [], "a") == nil)
        #expect(command(kVK_Delete) == nil)
        #expect(command(kVK_ANSI_1, [], "1") == nil)
        #expect(command(kVK_ANSI_A, .command, "a") == nil)
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
