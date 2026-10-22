import Foundation

/// When a canvas's cached bitmap of committed items has to be redrawn. Committing a stroke only
/// draws that stroke on top; undo, redo, erase, move and clear redraw everything. Pure.
enum CanvasRaster {
    enum Update: Equatable, Sendable {
        case none
        /// Draw just these on top of what's there.
        case append([CanvasItem])
        /// Clear and draw everything again.
        case full
    }

    /// The order items are painted in: highlighters beneath everything else, each group in z-order.
    static func drawOrder(_ items: [CanvasItem]) -> [CanvasItem] {
        items.filter(\.isHighlighter) + items.filter { !$0.isHighlighter }
    }

    /// What to redraw to go from the bitmap showing `baked` to showing `target`, both in draw order.
    /// Anything other than new items painted on top (which covers new highlighters slotting in
    /// beneath existing ink) needs a full redraw.
    static func update(from baked: [CanvasItem], to target: [CanvasItem]) -> Update {
        guard target.count >= baked.count, target.prefix(baked.count).elementsEqual(baked) else { return .full }
        let added = Array(target.dropFirst(baked.count))
        return added.isEmpty ? .none : .append(added)
    }
}
