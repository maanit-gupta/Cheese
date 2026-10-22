import Foundation

/// A page in the page editor: which page of the original it shows and how far it's turned.
struct EditorPage: Hashable, Sendable, Identifiable {
    let id: Int
    /// 0-based page index in the original PDF.
    let source: Int
    /// Extra clockwise rotation in degrees: 0, 90, 180 or 270.
    var rotation = 0
}

/// The page editor's edits, as pure functions over the page list.
enum PageEditing {
    static func initial(pageCount: Int) -> [EditorPage] {
        (0..<pageCount).map { EditorPage(id: $0, source: $0) }
    }

    static func rotate(_ pages: [EditorPage], ids: Set<Int>, by degrees: Int) -> [EditorPage] {
        pages.map { page in
            guard ids.contains(page.id) else { return page }
            var turned = page
            turned.rotation = ((page.rotation + degrees) % 360 + 360) % 360
            return turned
        }
    }

    static func delete(_ pages: [EditorPage], ids: Set<Int>) -> [EditorPage] {
        pages.filter { !ids.contains($0.id) }
    }

    /// Moves the pages in `ids` (keeping their relative order) to just before `target`,
    /// or to the end when `target` is nil. A target inside the moved set leaves the list as is.
    static func move(_ pages: [EditorPage], ids: Set<Int>, before target: Int?) -> [EditorPage] {
        if let target, ids.contains(target) {
            return pages
        }
        let moving = pages.filter { ids.contains($0.id) }
        var rest = pages.filter { !ids.contains($0.id) }
        let index = target.flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.endIndex
        rest.insert(contentsOf: moving, at: index)
        return rest
    }

    /// Shift-click: every page between the anchor and the clicked page, inclusive.
    static func range(from anchor: Int, to id: Int, in pages: [EditorPage]) -> Set<Int> {
        guard let start = pages.firstIndex(where: { $0.id == anchor }),
              let end = pages.firstIndex(where: { $0.id == id })
        else { return [id] }
        return Set(pages[min(start, end)...max(start, end)].map(\.id))
    }
}

/// Undo and redo over snapshots of an editor's state.
struct UndoHistory<State: Equatable> {
    private(set) var current: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    init(_ initial: State) {
        current = initial
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records a new state. No-op edits don't create an undo step.
    mutating func apply(_ state: State) {
        guard state != current else { return }
        undoStack.append(current)
        redoStack.removeAll()
        current = state
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }
}
