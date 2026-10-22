import AppKit
import SwiftUI
import os

/// An AppKit view laid over a history row, a preview card or the live-edit badge that drags the
/// item out of the popover. SwiftUI's `onDrag` can't report how a drag ended, which the popover
/// needs to close after a drop, and can't fade the popover while the drag is outside it.
struct ClipDragHandle: NSViewRepresentable {
    let model: HistoryViewModel
    let itemID: UUID
    /// A click that didn't turn into a drag, with its click count.
    var onClick: (@MainActor (_ clickCount: Int) -> Void)?
    /// The right-click menu.
    var menu: (@MainActor () -> NSMenu)?
    var toolTip: String?
    /// The pointer over the handle, like an open hand on a grip.
    var cursor: NSCursor?

    func makeNSView(context: Context) -> ClipDragSourceView {
        let view = ClipDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: ClipDragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: ClipDragSourceView) {
        view.model = model
        view.itemID = itemID
        view.onClick = onClick
        view.contextMenu = menu
        view.toolTip = toolTip
        if view.cursor != cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

final class ClipDragSourceView: NSView, NSDraggingSource {
    fileprivate var model: HistoryViewModel?
    fileprivate var itemID: UUID?
    fileprivate var onClick: (@MainActor (Int) -> Void)?
    fileprivate var contextMenu: (@MainActor () -> NSMenu)?
    fileprivate var cursor: NSCursor?
    private var mouseDownEvent: NSEvent?
    /// The popover's window, faded while the drag is outside it.
    private weak var sourceWindow: NSWindow?
    private var isFaded = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        if let cursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?(event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let model, let itemID else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil
        // Saves a live edit first, so the edited text is what's dragged.
        guard let drag = model.dragContents(for: itemID) else { return }
        // The drag image starts centered under the pointer.
        let pointer = convert(start.locationInWindow, from: nil)
        let side: CGFloat = 48
        let frame = NSRect(x: pointer.x - side / 2, y: pointer.y - side / 2, width: side, height: side)
        let draggingItems = drag.items.map { item in
            let dragging = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: item))
            dragging.setDraggingFrame(frame, contents: drag.icon)
            return dragging
        }
        guard !draggingItems.isEmpty else { return }
        sourceWindow = window
        model.dragBegan()
        let session = beginDraggingSession(with: draggingItems, event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    // Copy only: a Finder drop must never move the stored PNG out of Cheese's history.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let sourceWindow else { return }
        setFaded(ClipDragProvider.fadesPopover(pointer: screenPoint, popoverFrame: sourceWindow.frame))
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let sourceWindow {
            sourceWindow.alphaValue = 1
            sourceWindow.ignoresMouseEvents = false
        }
        isFaded = false
        sourceWindow = nil
        model?.dragEnded(dropped: operation != [])
    }

    /// Fades the popover so the target shows through, and lets the drop pass through it to the
    /// window underneath.
    private func setFaded(_ faded: Bool) {
        guard faded != isFaded, let sourceWindow else { return }
        isFaded = faded
        sourceWindow.ignoresMouseEvents = faded
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.duration(DesignTokens.Duration.standard)
            sourceWindow.animator().alphaValue = faded ? ClipDragProvider.fadedAlpha : 1
        }
    }

    private static func pasteboardItem(for item: ClipDragItem) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        for representation in item.representations {
            let type = NSPasteboard.PasteboardType(representation.type)
            switch representation.value {
            case let .string(string):
                pasteboardItem.setString(string, forType: type)
            case let .data(data):
                pasteboardItem.setData(data, forType: type)
            case let .contentsOf(url):
                do {
                    pasteboardItem.setData(try Data(contentsOf: url), forType: type)
                } catch {
                    // The file URL still goes along, which is enough for most drop targets.
                    Logger.clipboard.error("Couldn't read the dragged image: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return pasteboardItem
    }
}

/// The picture under the pointer while dragging a history item.
@MainActor
enum ClipDragImage {
    static func icon(for item: ClipItem, imageURL: URL?) -> NSImage? {
        switch item.kind {
        case .text, .richText:
            return NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        case .image:
            return imageURL.flatMap(NSImage.init(contentsOf:))
        case .files:
            return item.filePaths.first.map { NSWorkspace.shared.icon(forFile: $0) }
        }
    }
}
