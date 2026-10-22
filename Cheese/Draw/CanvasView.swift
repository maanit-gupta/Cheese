import AppKit
import QuartzCore

/// What one canvas shows, supplied by `DrawModeController`.
struct CanvasRenderState {
    /// Committed items, in z-order. They're painted once into a cached bitmap.
    var items: [CanvasItem] = []
    /// Drawn live above the bitmap: a shape being dragged out, items being moved or resized,
    /// the paper of a note being edited.
    var floating: [CanvasItem] = []
    var selectedBounds: [CGRect] = []
    /// Resize handles show only for a single selection.
    var showsHandles = false
    var board = BoardMode.off
}

/// The stroke being drawn, rebuilt once per display frame.
struct LiveInk {
    var points: [CGPoint]
    var pressures: [CGFloat]
    var options: StrokeBuilder.Options
    var color: CanvasColor
    var isNeon: Bool
}

/// One display's drawings, in layers from the bottom:
/// board and vignette · bitmap of committed items · floating items and selection ·
/// live ink, snap preview and fading ink · text editor · laser, spotlight, zoom and radial menu.
/// Committed items are never redrawn per frame; the stroke being drawn is a single shape layer
/// updated from the display link.
final class CanvasView: NSView, NSTextViewDelegate {
    static let handleSize: CGFloat = 9
    /// Disappearing ink stays this long, then fades.
    static let disappearDelay: Duration = .seconds(3)
    static let disappearFade: CFTimeInterval = 0.6

    let page: CanvasPageID
    weak var controller: DrawModeController?

    private let backgroundHost = LayerHostView()
    private let vignette = CAGradientLayer()
    private let bakedHost = LayerHostView()
    private let bakedLayer = CALayer()
    private let floatingView = FloatingItemsView()
    private let liveHost = LayerHostView()
    private let liveInkLayer = CAShapeLayer()
    private let snapPreview = CALayer()
    private let presenterHost = LayerHostView()
    let presenter = PresenterLayers()
    let radialMenu = RadialMenuLayer()
    private var textEditor: NSTextView?
    private(set) var editingSticky = false

    /// What the bitmap currently shows, in draw order.
    private var baked: [CanvasItem] = []
    private var bakedContext: CGContext?
    private var bakedPixelSize = CGSize.zero
    private let outlines = InkOutlineCache()
    private var frameLink: CADisplayLink?
    private var liveInk: LiveInk?
    private var isLiveInkDirty = false
    private var isLaserAnimating = false
    private var fadingLayers: [CALayer] = []

    init(frame: CGRect, page: CanvasPageID, controller: DrawModeController) {
        self.page = page
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true

        vignette.type = .radial
        vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.16).cgColor]
        vignette.locations = [0.6, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)
        vignette.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        backgroundHost.hostedLayer.addSublayer(vignette)
        backgroundHost.hostedLayer.actions = ["backgroundColor": NSNull()]

        bakedLayer.contentsGravity = .resize
        bakedLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        bakedHost.hostedLayer.addSublayer(bakedLayer)

        liveInkLayer.fillRule = .nonZero
        liveInkLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "shadowColor": NSNull(), "shadowOpacity": NSNull(), "opacity": NSNull()]
        liveHost.hostedLayer.addSublayer(liveInkLayer)
        snapPreview.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        snapPreview.isHidden = true
        liveHost.hostedLayer.addSublayer(snapPreview)

        presenterHost.hostedLayer.addSublayer(presenter.container)
        presenterHost.hostedLayer.addSublayer(radialMenu.container)

        floatingView.canvas = self
        for subview in [backgroundHost, bakedHost, floatingView, liveHost, presenterHost] {
            subview.frame = bounds
            subview.autoresizingMask = [.width, .height]
            addSubview(subview)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presenter.container.frame = presenterHost.bounds
        liveInkLayer.frame = liveHost.bounds
        vignette.frame = backgroundHost.bounds
        bakedLayer.frame = bakedHost.bounds
        CATransaction.commit()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: Rendering

    /// Brings every layer up to date with the controller's state. Only what changed is redrawn:
    /// a newly committed item is painted on top of the bitmap; anything else repaints it.
    func refresh() {
        guard let state = controller?.renderState(for: page) else { return }
        backgroundHost.hostedLayer.backgroundColor = switch state.board {
        case .off: nil
        case .whiteboard: NSColor(white: 0.98, alpha: 1).cgColor
        case .blackboard: NSColor(red: 0.11, green: 0.14, blue: 0.13, alpha: 1).cgColor
        }
        bake(CanvasRaster.drawOrder(state.items))
        floatingView.needsDisplay = true
    }

    private func bake(_ target: [CanvasItem]) {
        let scale = backingScale
        let pixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        var update = CanvasRaster.update(from: baked, to: target)
        if bakedContext == nil || pixelSize != bakedPixelSize {
            update = .full
        }
        let toDraw: [CanvasItem]
        switch update {
        case .none:
            return
        case let .append(items):
            toDraw = items
        case .full:
            outlines.keep(only: Set(target.map(\.id)))
            if bakedContext == nil || pixelSize != bakedPixelSize {
                bakedContext = Self.makeContext(pixelSize: pixelSize, scale: scale)
                bakedPixelSize = pixelSize
            }
            bakedContext?.clear(CGRect(origin: .zero, size: bounds.size))
            toDraw = target
        }
        guard let context = bakedContext else { return }
        CanvasRenderer.withGraphicsContext(context) {
            for item in toDraw {
                CanvasRenderer.draw(item, in: context, outlines: outlines)
            }
        }
        baked = target
        bakedLayer.contentsScale = scale
        bakedLayer.contents = target.isEmpty ? nil : context.makeImage()
    }

    /// A bitmap context drawn in view points with y down.
    private static func makeContext(pixelSize: CGSize, scale: CGFloat) -> CGContext? {
        guard let context = CGContext(
            data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        return context
    }

    /// Floating items and the selection, drawn by `FloatingItemsView`.
    fileprivate func drawFloating(in context: CGContext) {
        guard let state = controller?.renderState(for: page) else { return }
        for item in CanvasRaster.drawOrder(state.floating) {
            CanvasRenderer.draw(item, in: context, outlines: outlines)
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

    // MARK: Live ink

    /// Shows the stroke being drawn; it's rebuilt on the next display frame. Nil clears it at once.
    func setLiveInk(_ ink: LiveInk?) {
        liveInk = ink
        guard let ink else {
            isLiveInkDirty = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveInkLayer.path = nil
            liveInkLayer.opacity = 1
            CATransaction.commit()
            updateFrameLink()
            return
        }
        let color = CanvasRenderer.nsColor(ink.color)
        liveInkLayer.fillColor = (ink.isNeon ? CanvasRenderer.neonCore(of: color) : color).cgColor
        liveInkLayer.shadowColor = color.cgColor
        liveInkLayer.shadowOpacity = ink.isNeon ? 1 : 0
        liveInkLayer.shadowRadius = CanvasRenderer.neonBlur(width: ink.options.size) / 2
        liveInkLayer.shadowOffset = .zero
        isLiveInkDirty = true
        updateFrameLink()
    }

    private func updateFrameLink() {
        let needed = liveInk != nil || isLaserAnimating
        if needed, frameLink == nil {
            let link = displayLink(target: self, selector: #selector(frameTick))
            link.add(to: .main, forMode: .common)
            frameLink = link
        } else if !needed {
            frameLink?.invalidate()
            frameLink = nil
        }
    }

    @objc private func frameTick() {
        if isLiveInkDirty, let ink = liveInk {
            isLiveInkDirty = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveInkLayer.path = StrokeBuilder.path(points: ink.points, pressures: ink.pressures, options: ink.options)
            CATransaction.commit()
        }
        if isLaserAnimating {
            presenter.updateLaser(at: CACurrentMediaTime())
        }
    }

    /// The magic pen's clean shape, morphing in over the rough stroke. Nil puts the stroke back.
    func setSnapPreview(_ item: CanvasItem?) {
        guard let item, let (image, frame) = CanvasRenderer.image(of: item, scale: backingScale, outlines: outlines) else {
            snapPreview.isHidden = true
            snapPreview.contents = nil
            liveInkLayer.opacity = 1
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapPreview.contents = image
        snapPreview.contentsScale = backingScale
        snapPreview.frame = frame
        snapPreview.isHidden = false
        liveInkLayer.opacity = 0
        CATransaction.commit()

        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.18
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = duration
        snapPreview.add(fadeIn, forKey: "morph")
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = duration
        liveInkLayer.add(fadeOut, forKey: "morph")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let settle = CASpringAnimation(keyPath: "transform.scale")
            settle.fromValue = 0.92
            settle.toValue = 1
            settle.damping = 12
            settle.initialVelocity = 4
            settle.duration = settle.settlingDuration
            snapPreview.add(settle, forKey: "settle")
        }
    }

    /// Disappearing ink: shows `item` for a few seconds, then fades it out. Never part of the document.
    func showDisappearing(_ item: CanvasItem) {
        guard let (image, frame) = CanvasRenderer.image(of: item, scale: backingScale, outlines: outlines) else { return }
        let layer = CALayer()
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.contents = image
        layer.contentsScale = backingScale
        layer.frame = frame
        liveHost.hostedLayer.insertSublayer(layer, below: liveInkLayer)
        fadingLayers.append(layer)
        Task { @MainActor [weak self, weak layer] in
            try? await Task.sleep(for: Self.disappearDelay)
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.disappearFade)
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    layer.removeFromSuperlayer()
                    self?.fadingLayers.removeAll { $0 === layer }
                }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            layer.opacity = 0
            layer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    /// Removes every transient layer: live ink, snap preview, fading ink, presenters and the radial menu.
    func clearTransients() {
        setLiveInk(nil)
        setSnapPreview(nil)
        for layer in fadingLayers {
            layer.removeFromSuperlayer()
        }
        fadingLayers.removeAll()
        presenter.hideAll()
        radialMenu.hide()
        setLaserAnimating(false)
    }

    // MARK: Vignette

    var showsVignette: Bool {
        get { !vignette.isHidden }
        set { vignette.isHidden = !newValue }
    }

    // MARK: Laser animation

    func setLaserAnimating(_ animating: Bool) {
        isLaserAnimating = animating
        updateFrameLink()
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

    // Right-click (or a two-finger click) held down opens the radial menu.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        controller?.radialBegan(on: page, at: location(of: event), time: event.timestamp)
    }

    override func rightMouseDragged(with event: NSEvent) {
        controller?.radialMoved(on: page, to: location(of: event))
    }

    override func rightMouseUp(with event: NSEvent) {
        controller?.radialEnded(on: page, at: location(of: event), time: event.timestamp)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(on: page, to: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerExited(page)
    }

    override func scrollWheel(with event: NSEvent) {
        // With Shift held, a mouse wheel scrolls sideways.
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        controller?.scrolled(on: page, at: location(of: event), delta: delta, precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags)
    }

    override func magnify(with event: NSEvent) {
        controller?.pinched(on: page, at: location(of: event), magnification: event.magnification, phase: event.phase)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.modifiersChanged(event.modifierFlags)
        super.flagsChanged(with: event)
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

/// Draws a canvas's floating items and selection above its bitmap. Never takes clicks.
private final class FloatingItemsView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawFloating(in: context)
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

/// Stroke outlines are the costly part of painting ink; each is built once per item and reused
/// until the item changes.
@MainActor
final class InkOutlineCache {
    private var paths: [UUID: (item: CanvasItem, path: CGPath)] = [:]

    func path(for item: CanvasItem, build: () -> CGPath) -> CGPath {
        if let cached = paths[item.id], cached.item == item {
            return cached.path
        }
        let path = build()
        paths[item.id] = (item, path)
        return path
    }

    func keep(only ids: Set<UUID>) {
        paths = paths.filter { ids.contains($0.key) }
    }
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

    /// Neon ink: a bright core inside a glow of the ink's color.
    static func neonCore(of color: NSColor) -> NSColor {
        color.blended(withFraction: 0.45, of: .white) ?? color
    }

    static func neonBlur(width: CGFloat) -> CGFloat {
        max(10, width * 2.5)
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

    /// Runs `body` with `context` as AppKit's current context, so text can be drawn into it.
    static func withGraphicsContext(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The ink outline of a stroke item.
    static func strokeOutline(_ item: CanvasItem) -> CGPath {
        guard case let .stroke(points, pressures, isHighlighter) = item.kind else { return CGMutablePath() }
        let options: StrokeBuilder.Options = isHighlighter
            ? .highlighter(width: item.renderedWidth)
            : .pen(width: item.style.width, simulatesPressure: !StrokeBuilder.hasAnalogPressure(pressures))
        return StrokeBuilder.path(points: points, pressures: pressures, options: options)
    }

    /// `item` alone as an image, with the frame (in view points) it covers.
    static func image(of item: CanvasItem, scale: CGFloat, outlines: InkOutlineCache) -> (CGImage, CGRect)? {
        let pad = item.style.isNeon ? neonBlur(width: item.style.width) * 1.5 : 4
        let frame = item.bounds.insetBy(dx: -pad, dy: -pad).integral
        let width = Int((frame.width * scale).rounded(.up))
        let height = Int((frame.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        withGraphicsContext(context) {
            draw(item, in: context, outlines: outlines)
        }
        guard let image = context.makeImage() else { return nil }
        return (image, frame)
    }

    static func draw(_ item: CanvasItem, in context: CGContext, outlines: InkOutlineCache? = nil) {
        let color = item.isHighlighter ? item.style.color.withAlpha(CanvasItem.highlighterAlpha) : item.style.color
        let base = nsColor(color)
        context.saveGState()
        defer { context.restoreGState() }
        let ink = item.style.isNeon ? neonCore(of: base) : base
        if item.style.isNeon {
            context.setShadow(offset: .zero, blur: neonBlur(width: item.style.width), color: base.cgColor)
        }
        context.setStrokeColor(ink.cgColor)
        context.setFillColor(ink.cgColor)
        context.setLineWidth(item.renderedWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch item.kind {
        case .stroke:
            let path = outlines?.path(for: item) { strokeOutline(item) } ?? strokeOutline(item)
            context.addPath(path)
            context.fillPath()
        case let .shape(kind, rect):
            let rect = rect.standardized
            let path = kind == .rectangle ? CGPath(rect: rect, transform: nil) : CGPath(ellipseIn: rect, transform: nil)
            context.addPath(path)
            context.drawPath(using: item.style.isFilled ? .fillStroke : .stroke)
        case let .polygon(points):
            guard points.count > 1 else { return }
            context.addLines(between: points)
            context.closePath()
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
        case let .stamp(stamp, center, size):
            drawStamp(stamp, center: center, size: size, color: item.style.color, context: context)
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

    private static func drawStamp(_ stamp: Stamp, center: CGPoint, size: CGFloat, color: CanvasColor, context: CGContext) {
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * size, y: rect.minY + y * size)
        }
        switch stamp {
        case .check:
            context.setLineWidth(size * 0.15)
            context.addLines(between: [point(0.16, 0.54), point(0.4, 0.78), point(0.86, 0.24)])
            context.strokePath()
        case .cross:
            context.setLineWidth(size * 0.14)
            context.addLines(between: [point(0.2, 0.2), point(0.8, 0.8)])
            context.addLines(between: [point(0.8, 0.2), point(0.2, 0.8)])
            context.strokePath()
        case .star:
            let outer = size / 2
            let inner = outer * 0.42
            let corners = (0..<10).map { index -> CGPoint in
                let radius = index.isMultiple(of: 2) ? outer : inner
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 1.02)
            }
            context.addLines(between: corners)
            context.closePath()
            context.setLineWidth(size * 0.04)
            context.drawPath(using: .fillStroke)
        case .question:
            drawBadge("?", in: rect, color: color, context: context)
        case let .number(number):
            drawBadge("\(number)", in: rect, color: color, context: context)
        }
    }

    /// A filled circle with a label in its middle, dark on light colors and light on dark ones.
    private static func drawBadge(_ label: String, in rect: CGRect, color: CanvasColor, context: CGContext) {
        context.addEllipse(in: rect)
        context.fillPath()
        let luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        let textColor: NSColor = luminance > 0.7 ? NSColor(white: 0.1, alpha: 1) : .white
        let fontSize = rect.height * (label.count > 1 ? 0.48 : 0.6)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold).withRoundedDesign
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = (label as NSString).size(withAttributes: attributes)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        (label as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

private extension NSFont {
    var withRoundedDesign: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
