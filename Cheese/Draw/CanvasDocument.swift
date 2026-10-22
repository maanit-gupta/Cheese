import CoreGraphics
import Foundation

/// Which display a page of drawings belongs to (its `CGDirectDisplayID`).
typealias CanvasPageID = UInt32

/// An item together with where it sat in its page's z-order.
struct IndexedItem: Equatable, Sendable {
    var index: Int
    var item: CanvasItem
}

/// Every drawing, as vector items, one z-ordered array per display. Kept in memory only.
struct CanvasDocument: Equatable, Sendable {
    private(set) var pages: [CanvasPageID: [CanvasItem]] = [:]

    func items(on page: CanvasPageID) -> [CanvasItem] {
        pages[page] ?? []
    }

    var itemCount: Int {
        pages.values.reduce(0) { $0 + $1.count }
    }

    var isEmpty: Bool { itemCount == 0 }

    func item(_ id: UUID, on page: CanvasPageID) -> CanvasItem? {
        items(on: page).first { $0.id == id }
    }

    /// Adds on top, or at `index` (clamped).
    mutating func insert(_ item: CanvasItem, on page: CanvasPageID, at index: Int? = nil) {
        var items = pages[page] ?? []
        let position = min(max(index ?? items.count, 0), items.count)
        items.insert(item, at: position)
        pages[page] = items
    }

    @discardableResult
    mutating func remove(_ ids: Set<UUID>, on page: CanvasPageID) -> [IndexedItem] {
        let removed = indexedItems(withIDs: ids, on: page)
        pages[page]?.removeAll { ids.contains($0.id) }
        return removed
    }

    /// Replaces items with the same IDs in place, keeping their z-order.
    mutating func replace(_ replacements: [CanvasItem], on page: CanvasPageID) {
        guard var items = pages[page] else { return }
        let byID = Dictionary(replacements.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for index in items.indices {
            if let replacement = byID[items[index].id] {
                items[index] = replacement
            }
        }
        pages[page] = items
    }

    mutating func removeAll() {
        pages.removeAll()
    }

    /// The items with these IDs, highest index first, so removing them one by one in this order
    /// leaves each recorded index valid, and re-inserting in reverse restores the page exactly.
    func indexedItems(withIDs ids: Set<UUID>, on page: CanvasPageID) -> [IndexedItem] {
        items(on: page).enumerated()
            .filter { ids.contains($0.element.id) }
            .map { IndexedItem(index: $0.offset, item: $0.element) }
            .reversed()
    }
}
