import AppKit

/// The shelf panel's content view: an AppKit drop target around the SwiftUI shelf. AppKit hands a
/// drag to the registered view nearest the pointer among the views under it, so registering here,
/// above every card, catches drops anywhere on the shelf. SwiftUI's `onDrop` in a non-activating
/// panel, and drag handlers on the window's delegate, don't reliably get them.
final class ShelfDropHostView: NSView {
    /// A drag came over the shelf: the operation to show, or `[]` to refuse it.
    var onEntered: (any NSDraggingInfo) -> NSDragOperation = { _ in [] }
    var onExited: () -> Void = {}
    /// The drop landed: whether anything was taken.
    var onDrop: (any NSDraggingInfo) -> Bool = { _ in false }

    private let content: NSView
    private var operation: NSDragOperation = []

    init(content: NSView, types: [NSPasteboard.PasteboardType]) {
        self.content = content
        super.init(frame: CGRect(origin: .zero, size: content.fittingSize))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // The panel sizes itself to this; the shelf's size is the SwiftUI content's.
    override var fittingSize: NSSize { content.fittingSize }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation = onEntered(sender)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        operation = []
        onExited()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !operation.isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { operation = [] }
        return onDrop(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        if !operation.isEmpty {
            operation = []
            onExited()
        }
    }
}
