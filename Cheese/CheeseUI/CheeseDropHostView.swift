import AppKit

/// A panel's content view that takes drops anywhere on it: an AppKit drop target around the SwiftUI
/// content (the shelf, the Share panel). AppKit hands a drag to the registered view nearest the
/// pointer among the views under it, so registering here, above every card, catches drops anywhere
/// in the panel. SwiftUI's `onDrop` in a non-activating panel, and drag handlers on the window's
/// delegate, don't reliably get them.
final class CheeseDropHostView: NSView {
    /// A drag came over the panel: the operation to show, or `[]` to refuse it.
    var onEntered: (any NSDraggingInfo) -> NSDragOperation = { _ in [] }
    /// The drag moved, for panels whose parts take drops of their own (the Share panel's devices).
    var onUpdated: (any NSDraggingInfo) -> Void = { _ in }
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

    // The panel sizes itself to this, the SwiftUI content's size.
    override var fittingSize: NSSize { content.fittingSize }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation = onEntered(sender)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !operation.isEmpty {
            onUpdated(sender)
        }
        return operation
    }

    /// A drag's location in SwiftUI's terms: top-left origin, in this view's (and the content's) space.
    func contentPoint(of sender: any NSDraggingInfo) -> CGPoint {
        let point = convert(sender.draggingLocation, from: nil)
        return isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
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
