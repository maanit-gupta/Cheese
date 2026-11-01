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
    /// The cursor plus any Shift/Cmd multi-selection.
    private(set) var selectionState = HistorySelection() {
        didSet {
            // Moving on from the item being edited, or selecting several, saves the edit.
            if let editingID, selectionState.cursor != editingID || selectionState.batch.count > 1 { endEditing() }
        }
    }
    /// The cursor: the previewed item. Setting it selects just that item.
    var selectedID: UUID? {
        get { selectionState.cursor }
        set { selectionState.select(newValue) }
    }
    /// Bumped each time the panel opens so the view re-focuses the search field.
    private(set) var focusRequest = 0
    /// The text item being live-edited in the preview pane, if any.
    private(set) var editingID: UUID?
    /// The editor's text as the user types. Saved on Done, ⌘Return, Esc, a drag, or moving on.
    @ObservationIgnored var draftText = ""

    @ObservationIgnored let store: ClipStore
    @ObservationIgnored var onPaste: (ClipItem, _ plainText: Bool) -> Void = { _, _ in }
    /// Several items chosen at once: paste them together (`.together`), one Cmd+V each
    /// (`.oneByOne`), or just copy them (`.copyOnly`). In selection order.
    @ObservationIgnored var onBatch: ([ClipItem], ClipBatchMode) -> Void = { _, _ in }
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

    /// Every chosen item that's still visible, in selection order.
    func selectedItems(in items: [ClipItem]) -> [ClipItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selectionState.items(in: items.map(\.id)).compactMap { byID[$0] }
    }

    /// The IDs to highlight in the list.
    func highlightedIDs(in items: [ClipItem]) -> Set<UUID> {
        Set(selectionState.items(in: items.map(\.id)))
    }

    /// Whether several visible items are selected.
    var isBatchSelected: Bool {
        selectionState.isBatch(in: visibleItems.map(\.id))
    }

    /// A click on a row: Cmd adds or removes it, Shift extends to it, otherwise it alone is selected.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let order = visibleItems.map(\.id)
        if modifiers.contains(.command) {
            selectionState.toggle(id, in: order)
        } else if modifiers.contains(.shift) {
            selectionState.extend(to: id, in: order)
        } else {
            selectionState.select(id)
        }
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
        let chosen = selectedItems(in: items)
        let isBatch = chosen.count > 1

        switch command {
        case .moveUp:
            guard let selectedIndex else { return }
            selectedID = items[max(selectedIndex - 1, 0)].id
        case .moveDown:
            guard let selectedIndex else { return }
            selectedID = items[min(selectedIndex + 1, items.count - 1)].id
        case .extendUp:
            selectionState.extend(by: -1, in: items.map(\.id))
        case .extendDown:
            selectionState.extend(by: 1, in: items.map(\.id))
        case .selectAll:
            selectionState.selectAll(items.map(\.id))
        case .copySelection:
            if isBatch { onBatch(chosen, .copyOnly) }
        case let .paste(plainText):
            if isBatch {
                onBatch(chosen, plainText ? .oneByOne : .together)
            } else if let selected {
                onPaste(selected, plainText)
            }
        case let .pasteItem(number):
            guard items.indices.contains(number - 1) else { return }
            onPaste(items[number - 1], false)
        case .togglePin:
            if isBatch {
                // Pin them all, or unpin them all when they're all pinned already.
                let pin = chosen.contains { !$0.isPinned }
                for item in chosen where item.isPinned != pin {
                    store.togglePin(item.id)
                }
                return
            }
            guard let selected else { return }
            selectedID = selected.id
            store.togglePin(selected.id)
        case .delete:
            if isBatch {
                deleteBatch(chosen, from: items)
                return
            }
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

    /// Deletes every chosen item and selects the nearest survivor: the first one below the
    /// deleted items, or else the last one above them.
    private func deleteBatch(_ doomed: [ClipItem], from items: [ClipItem]) {
        let doomedIDs = Set(doomed.map(\.id))
        let indices = items.indices.filter { doomedIDs.contains(items[$0].id) }
        let below = indices.max().flatMap { last in items[(last + 1)...].first { !doomedIDs.contains($0.id) } }
        let above = indices.min().flatMap { first in items[..<first].last { !doomedIDs.contains($0.id) } }
        selectedID = (below ?? above)?.id
        for id in doomedIDs {
            store.delete(id)
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
