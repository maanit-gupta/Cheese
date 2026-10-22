import AppKit
import QuartzCore

/// What one canvas draws, supplied by `DrawModeController`.
struct CanvasRenderState {
    var items: [CanvasItem] = []
    /// A shape, line or note being made, not yet in the document.
    var draft: CanvasItem?
    var selectedBounds: [CGRect] = []
    /// Resize handles show only for a single selection.
    var showsHandles = false
    /// The item whose text is being edited; its text editor draws it instead.
    var hiddenItemID: UUID?
    var board = BoardMode.off
}

/// One display's drawings. Committed items are drawn with Core Graphics; the stroke being drawn
/// lives in a `CAShapeLayer` so freehand input stays low-latency at 120 Hz.
final class CanvasView: NSView, NSTextViewDelegate {
    static let handleSize: CGFloat = 9

    let page: CanvasPageID
    weak var controller: DrawModeController?

    private let liveStrokeHost = LayerHostView()
    private let liveStroke = CAShapeLayer()
    private let presenterHost = LayerHostView()
    let presenter = PresenterLayers()
    private var textEditor: NSTextView?
    private(set) var editingSticky = false
    private var displayLink: CADisplayLink?

    init(frame: CGRect, page: CanvasPageID, controller: DrawModeController) {
        self.page = page
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        liveStroke.fillColor = nil
        liveStroke.lineCap = .round
        liveStroke.lineJoin = .round
        liveStroke.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        liveStrokeHost.hostedLayer.addSublayer(liveStroke)
        presenterHost.hostedLayer.addSublayer(presenter.container)
        for host in [liveStrokeHost, presenterHost] {
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        presenter.container.frame = presenterHost.bounds
        liveStroke.frame = liveStrokeHost.bounds
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let state = controller?.renderState(for: page) else { return }
        switch state.board {
        case .off:
            break
        case .whiteboard:
            context.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
            context.fill(bounds)
        case .blackboard:
            context.setFillColor(NSColor(red: 0.11, green: 0.14, blue: 0.13, alpha: 1).cgColor)
            context.fill(bounds)
        }

        // Highlighters sit beneath everything else; the draft goes on top.
        let all = state.items + [state.draft].compactMap(\.self)
        for item in all.filter(\.isHighlighter) + all.filter({ !$0.isHighlighter }) where item.bounds.intersects(dirtyRect) {
            if item.id == state.hiddenItemID {
                // The text editor shows the text; a note still needs its paper behind it.
                if case .sticky = item.kind {
                    CanvasRenderer.draw(item.withText(""), in: context)
                }
                continue
            }
            CanvasRenderer.draw(item, in: context)
        }
        drawSelection(state, in: context)
    }

    private func drawSelection(_ state: CanvasRenderState, in context: CGContext) {
        guard !state.selectedBounds.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 3])
        for rect in state.selectedBounds {
            context.stroke(rect.insetBy(dx: -4, dy: -4))
        }
        context.restoreGState()
        guard state.showsHandles, let rect = state.selectedBounds.first else { return }
        for handle in CanvasHitTester.Handle.allCases {
            let center = CanvasHitTester.point(of: handle, in: rect.insetBy(dx: -4, dy: -4))
            let box = CGRect(x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.stroke(box)
        }
    }

    /// Shows the stroke being drawn. Nil clears it.
    func setLiveStroke(_ points: [CGPoint]?, style: CanvasStyle, isHighlighter: Bool) {
        guard let points, !points.isEmpty else {
            liveStroke.path = nil
            return
        }
        let color = isHighlighter ? style.color.withAlpha(CanvasItem.highlighterAlpha) : style.color
        liveStroke.strokeColor = CanvasRenderer.nsColor(color).cgColor
        liveStroke.lineWidth = isHighlighter ? style.width * CanvasItem.highlighterWidthFactor : style.width
        liveStroke.path = StrokeSmoother.path(through: points)
    }

    // MARK: Laser animation

    func setLaserAnimating(_ animating: Bool) {
        if animating, displayLink == nil {
            let link = displayLink(target: self, selector: #selector(laserTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !animating {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func laserTick() {
        presenter.updateLaser(at: CACurrentMediaTime())
    }

    // MARK: Text editing

    var isEditingText: Bool { textEditor != nil }

    /// Places an editor over `frame`. Plain text grows to fit; a sticky note's text wraps inside it.
    func beginTextEditing(text: String, frame: CGRect, fontSize: CGFloat, color: CanvasColor, isSticky: Bool) {
        endTextEditingView()
        let editor = NSTextView(frame: isSticky ? frame.insetBy(dx: CanvasRenderer.stickyPadding, dy: CanvasRenderer.stickyPadding) : frame)
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.font = isSticky ? CanvasRenderer.stickyFont : CanvasRenderer.textFont(size: fontSize)
        editor.textColor = isSticky ? CanvasRenderer.stickyTextColor : CanvasRenderer.nsColor(color)
        editor.insertionPointColor = editor.textColor ?? .labelColor
        if isSticky {
            editor.isVerticallyResizable = false
            editor.isHorizontallyResizable = false
            editor.alignment = .center
        } else {
            editor.isHorizontallyResizable = true
            editor.isVerticallyResizable = true
            editor.textContainer?.widthTracksTextView = false
            editor.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            editor.minSize = CGSize(width: max(fontSize, 8), height: CanvasRenderer.textSize("", fontSize: fontSize).height)
            editor.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        editor.string = text
        editor.delegate = self
        if !isSticky {
            editor.sizeToFit()
        }
        addSubview(editor, positioned: .below, relativeTo: presenterHost)
        textEditor = editor
        editingSticky = isSticky
        window?.makeKey()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Removes the editor and returns what was typed.
    @discardableResult
    func endTextEditingView() -> String? {
        guard let editor = textEditor else { return nil }
        let text = editor.string
        editor.delegate = nil
        editor.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        return text
    }

    func textDidChange(_ notification: Notification) {
        if !editingSticky {
            textEditor?.sizeToFit()
        }
    }

    // Esc ends editing rather than leaving draw mode.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        controller?.endTextEditing()
        return true
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        controller?.mouseDown(on: page, at: location(of: event), event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(on: page, at: location(of: event), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(on: page, at: location(of: event), event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(on: page, to: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerExited(page)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scrolled(on: page, at: location(of: event), deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    }

    override func cursorUpdate(with event: NSEvent) {
        controller?.cursor.set()
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) != true {
            super.keyDown(with: event)
        }
    }

    // Command shortcuts arrive here before the main menu sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isEditingText, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        return controller?.handleKeyDown(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// A transparent layer-hosting view that never takes clicks, for layers drawn above the canvas.
final class LayerHostView: NSView {
    let hostedLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostedLayer.isGeometryFlipped = true
        hostedLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer = hostedLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Core Graphics drawing for canvas items, in flipped (y-down) view coordinates.
@MainActor
enum CanvasRenderer {
    static let stickyPadding: CGFloat = 14
    static let stickyFont = NSFont.systemFont(ofSize: 18, weight: .medium)
    static let stickyTextColor = NSColor(white: 0.12, alpha: 1)

    static func nsColor(_ color: CanvasColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }

    /// The size text takes when drawn, used to size a committed text item.
    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let measured = (text.isEmpty ? " " : text) as NSString
        let rect = measured.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont(size: fontSize)]
        )
        return CGSize(width: rect.width.rounded(.up), height: rect.height.rounded(.up))
    }

    static func draw(_ item: CanvasItem, in context: CGContext) {
        let color = item.isHighlighter ? item.style.color.withAlpha(CanvasItem.highlighterAlpha) : item.style.color
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(nsColor(color).cgColor)
        context.setFillColor(nsColor(color).cgColor)
        context.setLineWidth(item.renderedWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch item.kind {
        case let .stroke(points, _):
            context.addPath(StrokeSmoother.path(through: points))
            context.strokePath()
        case let .shape(kind, rect):
            let rect = rect.standardized
            let path = kind == .rectangle ? CGPath(rect: rect, transform: nil) : CGPath(ellipseIn: rect, transform: nil)
            context.addPath(path)
            context.drawPath(using: item.style.isFilled ? .fillStroke : .stroke)
        case let .line(from, to):
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        case let .arrow(from, to):
            drawArrow(from: from, to: to, width: item.style.width, in: context)
        case let .text(text, rect):
            let attributes: [NSAttributedString.Key: Any] = [.font: textFont(size: item.style.fontSize), .foregroundColor: nsColor(item.style.color)]
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        case let .sticky(text, rect, noteColor):
            drawSticky(text, in: rect.standardized, color: noteColor, context: context)
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, in context: CGContext) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return }
        let headLength = min(max(14, width * 4), length)
        let headHalfWidth = headLength * 0.5
        let ux = (to.x - from.x) / length
        let uy = (to.y - from.y) / length
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)

        context.move(to: from)
        context.addLine(to: CGPoint(x: base.x + ux * 1, y: base.y + uy * 1))
        context.strokePath()

        context.move(to: to)
        context.addLine(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        context.addLine(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        context.closePath()
        context.fillPath()
    }

    private static func drawSticky(_ text: String, in rect: CGRect, color: CanvasColor, context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.setFillColor(nsColor(color).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        context.restoreGState()

        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: stickyFont, .foregroundColor: stickyTextColor, .paragraphStyle: paragraph]
        (text as NSString).draw(
            with: rect.insetBy(dx: stickyPadding, dy: stickyPadding),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }
}
