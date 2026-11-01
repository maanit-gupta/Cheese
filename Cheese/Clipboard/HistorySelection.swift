import Foundation

/// The history panel's selection: a cursor (the previewed item, moved by the arrows), an anchor that
/// Shift-extends grow from, and a batch of items chosen with Shift or Cmd, in the order they were
/// chosen. That order is the order a batch pastes in.
struct HistorySelection: Equatable, Sendable {
    /// The previewed item. Nil falls back to the first visible item.
    private(set) var cursor: UUID?
    /// Where Shift+arrow and Shift+click extend from.
    private(set) var anchor: UUID?
    /// Items chosen together. Fewer than two means a single selection: just the cursor.
    private(set) var batch: [UUID] = []

    /// Selects one item and drops any batch.
    mutating func select(_ id: UUID?) {
        cursor = id
        anchor = id
        batch = []
    }

    /// Shift+click: the batch becomes every item from the anchor to `id`, in the order walked.
    mutating func extend(to id: UUID, in order: [UUID]) {
        guard let end = order.firstIndex(of: id) else { return }
        let start = anchor.flatMap(order.firstIndex(of:)) ?? cursor.flatMap(order.firstIndex(of:)) ?? 0
        anchor = order[start]
        cursor = id
        let step = end >= start ? 1 : -1
        batch = stride(from: start, through: end, by: step).map { order[$0] }
    }

    /// Shift+arrow: moves the cursor `offset` rows (-1 up, +1 down), clamped to the list, and extends
    /// the batch from the anchor to it. Moving back toward the anchor shrinks the batch.
    mutating func extend(by offset: Int, in order: [UUID]) {
        guard !order.isEmpty else { return }
        let current = cursor.flatMap(order.firstIndex(of:)) ?? 0
        if anchor.flatMap(order.firstIndex(of:)) == nil {
            anchor = order[current]
        }
        let next = min(max(current + offset, 0), order.count - 1)
        extend(to: order[next], in: order)
    }

    /// Cmd+click: adds the item to the batch, or takes it out. The last item can't be taken out.
    mutating func toggle(_ id: UUID, in order: [UUID]) {
        guard order.contains(id) else { return }
        var chosen = items(in: order)
        if let index = chosen.firstIndex(of: id) {
            guard chosen.count > 1 else { return }
            chosen.remove(at: index)
            if cursor == id { cursor = chosen.last }
        } else {
            chosen.append(id)
            cursor = id
        }
        anchor = cursor
        batch = chosen.count > 1 ? chosen : []
    }

    /// Cmd+A: every visible item, top to bottom.
    mutating func selectAll(_ order: [UUID]) {
        guard !order.isEmpty else { return }
        batch = order.count > 1 ? order : []
        anchor = order.first
        if cursor.flatMap(order.firstIndex(of:)) == nil { cursor = order.first }
    }

    /// The chosen items that are still visible, in selection order: the batch, or else just the
    /// cursor (or the first visible item when there's no cursor).
    func items(in order: [UUID]) -> [UUID] {
        let visible = Set(order)
        let chosen = batch.filter(visible.contains)
        if chosen.count > 1 { return chosen }
        if let cursor, visible.contains(cursor) { return [cursor] }
        return Array(order.prefix(1))
    }

    /// Whether more than one visible item is chosen.
    func isBatch(in order: [UUID]) -> Bool {
        items(in: order).count > 1
    }
}

/// How a multi-selection goes out.
enum ClipBatchMode: Equatable, Sendable {
    /// One pasteboard write and one Cmd+V (Return).
    case together
    /// Each item written and pasted in turn, for apps that take one image per paste (Opt+Return).
    case oneByOne
    /// Written to the clipboard only (Cmd+C).
    case copyOnly
}

/// What a batch paste puts on the pasteboard. All-text batches become one text, joined with blank
/// lines. Anything else (screenshots, files, a mix) goes on as one pasteboard item per piece, so a
/// single Cmd+V drops them all into Finder, Slack, Notes or a browser chat.
enum ClipBatch {
    static let textSeparator = "\n\n"

    static func pasteboardItems(for inputs: [ClipDragInput]) -> [ClipDragItem] {
        let allText = !inputs.isEmpty && inputs.allSatisfy { $0.kind == .text || $0.kind == .richText }
        if allText {
            let text = inputs.compactMap(\.plainText).filter { !$0.isEmpty }.joined(separator: textSeparator)
            guard !text.isEmpty else { return [] }
            return [ClipDragItem(representations: [.init(type: PasteboardTypeID.plainText, value: .string(text))])]
        }
        return inputs.flatMap(ClipDragProvider.items(for:))
    }
}
