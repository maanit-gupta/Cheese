import AppKit

/// A rectangle the user dragged over a frozen display.
struct RegionSelection {
    var snapshot: DisplaySnapshot
    /// AppKit global points.
    var rect: CGRect
    /// Shift was held when the drag ended.
    var shiftHeld: Bool
    /// Close with `end(restoreFocus:)` once the selection has been handled.
    var session: OverlaySession

    var image: CapturedImage? { snapshot.crop(to: rect) }
}

/// Drag-to-select a region over frozen images of every display.
@MainActor
enum SelectionOverlay {
    /// Smallest drag, in points, that counts as a selection; anything less is treated as a stray click.
    static let minimumSize: CGFloat = 4

    /// Returns nil if the user pressed Esc. The overlay stays up (frozen) until the caller ends the session,
    /// so follow-up work such as OCR doesn't flash the live screen.
    static func selectRegion(on snapshots: [DisplaySnapshot]) async -> RegionSelection? {
        let session = OverlaySession()
        let selection: (DisplaySnapshot, CGRect, Bool)? = await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ result: (DisplaySnapshot, CGRect, Bool)?) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            session.show { screen in
                guard let snapshot = snapshots.first(where: { $0.displayID == screen.displayID }) else { return nil }
                return RegionSelectionView(
                    snapshot: snapshot,
                    onSelect: { rect, shift in
                        let global = rect.offsetBy(dx: snapshot.frame.minX, dy: snapshot.frame.minY)
                        finish((snapshot, global, shift))
                    },
                    onCancel: { finish(nil) }
                )
            }
            if session.windows.isEmpty { finish(nil) }
        }
        guard let (snapshot, rect, shiftHeld) = selection else {
            session.end(restoreFocus: true)
            return nil
        }
        // Drop the dimming so the frozen image shows plainly while the caller works.
        for view in session.windows.compactMap({ $0.contentView as? RegionSelectionView }) {
            view.isFinished = true
        }
        return RegionSelection(snapshot: snapshot, rect: rect, shiftHeld: shiftHeld, session: session)
    }
}

/// Draws a frozen display image, dims it, and lets the user drag out a rectangle.
final class RegionSelectionView: NSView {
    private let snapshot: DisplaySnapshot
    private let onSelect: (CGRect, Bool) -> Void
    private let onCancel: () -> Void
    private var dragStart: CGPoint?
    private var selection: CGRect?
    var isFinished = false {
        didSet { needsDisplay = true }
    }

    init(snapshot: DisplaySnapshot, onSelect: @escaping (CGRect, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(snapshot.captured.image, in: bounds)
        guard !isFinished else { return }

        let dim = NSColor.black.withAlphaComponent(0.35)
        guard let selection, selection.width > 0, selection.height > 0 else {
            dim.setFill()
            bounds.fill()
            return
        }
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: selection).reversed)
        dim.setFill()
        outside.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let pixels = DisplayGeometry.pixelRect(
            forViewRect: selection,
            viewSize: bounds.size,
            imagePixelSize: snapshot.captured.pixelSize
        )
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var origin = CGPoint(x: selection.minX, y: selection.minY - size.height - 8)
        if origin.y < bounds.minY + 2 { origin.y = selection.minY + 4 }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - size.width - 10)
        let background = CGRect(origin: origin, size: CGSize(width: size.width + 8, height: size.height + 4))
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: origin.x + 4, y: origin.y + 2), withAttributes: attributes)
    }

    private func clampedPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFinished else { return }
        window?.makeKey()
        dragStart = clampedPoint(for: event)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFinished, let dragStart else { return }
        let point = clampedPoint(for: event)
        selection = CGRect(
            x: min(dragStart.x, point.x),
            y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x),
            height: abs(point.y - dragStart.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isFinished else { return }
        defer { dragStart = nil }
        guard let selection, selection.width >= SelectionOverlay.minimumSize,
              selection.height >= SelectionOverlay.minimumSize
        else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onSelect(selection, event.modifierFlags.contains(.shift))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}
