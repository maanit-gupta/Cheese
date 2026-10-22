import Foundation

/// One undoable change to the canvas.
enum CanvasCommand: Equatable, Sendable {
    case addItem(CanvasItem, page: CanvasPageID)
    /// Items in the order they were removed, each with its index at the moment of removal.
    case removeItems([IndexedItem], page: CanvasPageID)
    /// Moves and resizes: the same items before and after.
    case transformItems(before: [CanvasItem], after: [CanvasItem], page: CanvasPageID)
    case editText(before: CanvasItem, after: CanvasItem, page: CanvasPageID)
    case clearAll(previous: CanvasDocument)

    func apply(to document: inout CanvasDocument) {
        switch self {
        case let .addItem(item, page):
            document.insert(item, on: page)
        case let .removeItems(removed, page):
            document.remove(Set(removed.map(\.item.id)), on: page)
        case let .transformItems(_, after, page):
            document.replace(after, on: page)
        case let .editText(_, after, page):
            document.replace([after], on: page)
        case .clearAll:
            document.removeAll()
        }
    }

    func revert(in document: inout CanvasDocument) {
        switch self {
        case let .addItem(item, page):
            document.remove([item.id], on: page)
        case let .removeItems(removed, page):
            for entry in removed.reversed() {
                document.insert(entry.item, on: page, at: entry.index)
            }
        case let .transformItems(before, _, page):
            document.replace(before, on: page)
        case let .editText(before, _, page):
            document.replace([before], on: page)
        case let .clearAll(previous):
            document = previous
        }
    }
}

/// The undo and redo stacks for the canvas.
struct CanvasHistory: Equatable, Sendable {
    private(set) var undoStack: [CanvasCommand] = []
    private(set) var redoStack: [CanvasCommand] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Applies the command and makes it the next thing to undo. Clears redo.
    mutating func perform(_ command: CanvasCommand, on document: inout CanvasDocument) {
        command.apply(to: &document)
        record(command)
    }

    /// Records a command whose effect is already in the document (live drags and erasing).
    mutating func record(_ command: CanvasCommand) {
        undoStack.append(command)
        redoStack.removeAll()
    }

    /// Returns the command undone, if any.
    @discardableResult
    mutating func undo(_ document: inout CanvasDocument) -> CanvasCommand? {
        guard let command = undoStack.popLast() else { return nil }
        command.revert(in: &document)
        redoStack.append(command)
        return command
    }

    @discardableResult
    mutating func redo(_ document: inout CanvasDocument) -> CanvasCommand? {
        guard let command = redoStack.popLast() else { return nil }
        command.apply(to: &document)
        undoStack.append(command)
        return command
    }
}
