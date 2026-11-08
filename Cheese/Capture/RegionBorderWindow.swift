import AppKit

/// A dashed outline just outside a screen region, showing what's being captured or recorded. It
/// takes no clicks, and like every Cheese window it stays out of captures.
@MainActor
final class RegionBorderWindow {
    private let region: CGRect
    private let color: NSColor
    private var window: NSWindow?

    /// `region` in AppKit global points.
    init(region: CGRect, color: NSColor = .systemRed) {
        self.region = region
        self.color = color
    }

    func show() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: region.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = RegionBorderView(color: color)
        window.orderFrontRegardless()
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

private final class RegionBorderView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.setLineDash([8, 4], count: 2, phase: 0)
        path.stroke()
    }
}
