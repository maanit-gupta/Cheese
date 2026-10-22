import AppKit
import Foundation
import Observation

/// State behind the history panel: the search query, the selection, live text editing and the
/// keyboard commands.
@MainActor
@Observable
final class HistoryViewModel {
    var query = "" {
        didSet {
            if query != oldValue { selectedID = nil }
        }
    }
    var selectedID: UUID? {
        didSet {
            // Moving on from the item being edited saves the edit.
            if let editingID, selectedID != editingID { endEditing() }
        }
    }
    /// Bumped each time the panel opens so the view re-focuses the search field.
    private(set) var focusRequest = 0
    /// The text item being live-edited in the preview pane, if any.
    private(set) var editingID: UUID?
    /// The editor's text as the user types. Saved on Done, ⌘Return, Esc, a drag, or moving on.
    @ObservationIgnored var draftText = ""

    @ObservationIgnored let store: ClipStore
    @ObservationIgnored var onPaste: (ClipItem, _ plainText: Bool) -> Void = { _, _ in }
    @ObservationIgnored var onClose: () -> Void = {}
    /// A live edit was saved: put the new text on the clipboard.
    @ObservationIgnored var onEditSaved: (ClipItem) -> Void = { _ in }
    /// A drag out of the panel started, or ended (`dropped` when it landed somewhere).
    @ObservationIgnored var onDragBegan: () -> Void = {}
    @ObservationIgnored var onDragEnded: (_ dropped: Bool) -> Void = { _ in }

    init(store: ClipStore) {
        self.store = store
    }

    var visibleItems: [ClipItem] {
        FuzzyMatcher.rank(store.items, query: query, text: \.searchText)
    }

    var isEditingText: Bool { editingID != nil }

    /// The selected item, falling back to the first visible one.
    func selection(in items: [ClipItem]) -> ClipItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFileName.map(store.images.url(for:))
    }

    func prepareForDisplay() {
        query = ""
        selectedID = nil
        focusRequest += 1
    }

    /// The panel closed: an edit in progress is kept, not thrown away.
    func panelClosed() {
        endEditing()
    }

    func perform(_ command: HistoryCommand) {
        let items = visibleItems
        let selected = selection(in: items)
        let selectedIndex = selected.flatMap { item in items.firstIndex { $0.id == item.id } }

        switch command {
        case .moveUp:
            guard let selectedIndex else { return }
            selectedID = items[max(selectedIndex - 1, 0)].id
        case .moveDown:
            guard let selectedIndex else { return }
            selectedID = items[min(selectedIndex + 1, items.count - 1)].id
        case let .paste(plainText):
            if let selected { onPaste(selected, plainText) }
        case let .pasteItem(number):
            guard items.indices.contains(number - 1) else { return }
            onPaste(items[number - 1], false)
        case .togglePin:
            guard let selected else { return }
            selectedID = selected.id
            store.togglePin(selected.id)
        case .delete:
            guard let selected, let selectedIndex else { return }
            // Keep the selection in place: the next item, or the previous one at the end of the list.
            let neighbor = items.indices.contains(selectedIndex + 1)
                ? items[selectedIndex + 1]
                : (selectedIndex > 0 ? items[selectedIndex - 1] : nil)
            selectedID = neighbor?.id
            store.delete(selected.id)
        case .close:
            onClose()
        case .toggleEdit:
            if isEditingText {
                endEditing()
            } else if let selected {
                startEditing(selected)
            }
        case .saveEditAndPaste:
            guard let editingID else { return }
            // Pasting writes the clipboard itself, so the save doesn't need to.
            saveEdit(syncsClipboard: false)
            stopEditing()
            if let item = store.item(withID: editingID) { onPaste(item, false) }
        case .endEdit:
            endEditing()
        }
    }

    // MARK: Live edit

    /// Opens the selected text item for editing in place. Images and files can't be edited.
    func startEditing(_ item: ClipItem) {
        guard item.kind == .text || item.kind == .richText else { return }
        // Select it first: selecting another item ends any edit in progress.
        selectedID = item.id
        draftText = item.plainText ?? ""
        editingID = item.id
    }

    /// Saves the edit and hands the keyboard back to the list.
    func endEditing() {
        guard isEditingText else { return }
        saveEdit(syncsClipboard: true)
        stopEditing()
    }

    private func stopEditing() {
        editingID = nil
        focusRequest += 1
    }

    /// Saves the draft without leaving edit mode. Unchanged or empty drafts save nothing.
    private func saveEdit(syncsClipboard: Bool) {
        guard let editingID, store.updateText(for: editingID, newText: draftText) else { return }
        if syncsClipboard, let item = store.item(withID: editingID) {
            onEditSaved(item)
        }
    }

    // MARK: Dragging out

    /// What dragging an item carries. An edit of that item is saved first, so the edited text is
    /// what's dropped.
    func dragContents(for id: UUID) -> (items: [ClipDragItem], icon: NSImage?)? {
        if editingID == id {
            saveEdit(syncsClipboard: true)
        }
        guard let item = store.item(withID: id) else { return nil }
        let imageURL = imageURL(for: item)
        let items = ClipDragProvider.items(for: ClipDragInput(item: item, imageURL: imageURL))
        guard !items.isEmpty else { return nil }
        return (items, ClipDragImage.icon(for: item, imageURL: imageURL))
    }

    func dragBegan() {
        onDragBegan()
    }

    func dragEnded(dropped: Bool) {
        onDragEnded(dropped)
    }
}
