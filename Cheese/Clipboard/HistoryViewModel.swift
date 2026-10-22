import Foundation
import Observation

/// State behind the history panel: the search query, the selection and the keyboard commands.
@MainActor
@Observable
final class HistoryViewModel {
    var query = "" {
        didSet {
            if query != oldValue { selectedID = nil }
        }
    }
    var selectedID: UUID?
    /// Bumped each time the panel opens so the view re-focuses the search field.
    private(set) var focusRequest = 0

    @ObservationIgnored let store: ClipStore
    @ObservationIgnored var onPaste: (ClipItem, _ plainText: Bool) -> Void = { _, _ in }
    @ObservationIgnored var onClose: () -> Void = {}

    init(store: ClipStore) {
        self.store = store
    }

    var visibleItems: [ClipItem] {
        FuzzyMatcher.rank(store.items, query: query, text: \.searchText)
    }

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
        }
    }
}
