import AppKit
import SwiftUI

/// What the toolbar's buttons do, supplied by `DrawModeController`.
struct ToolbarActions {
    var chooseTool: (DrawTool) -> Void
    var cycleBoard: () -> Void
    var toggleDisappearingInk: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var clearAll: () -> Void
    /// Shift held opens the annotation editor instead of copying.
    var snapshot: (_ shiftHeld: Bool) -> Void
    var exit: () -> Void
    /// After a toolbar control changes a style, give keyboard focus back to the canvas.
    var returnFocus: () -> Void
}

/// The vertical tool rail: non-activating, above the overlays, draggable anywhere. Secondary to
/// the radial menu and modifiers, so it shrinks to a pill a few seconds into drawing and grows
/// back on hover.
@MainActor
final class ToolbarPanel {
    /// How long into drawing the rail waits before shrinking to a pill.
    static let collapseDelay: Duration = .seconds(3)

    private let panel: ToolbarWindow
    private let settings: DrawSettings
    private var collapseTask: Task<Void, Never>?
    private var isHovering = false
    /// Bumped on every show and hide, so a slide-out that finishes late doesn't hide a fresh rail.
    private var transition = 0

    init(settings: DrawSettings, actions: ToolbarActions) {
        self.settings = settings
        panel = ToolbarWindow()
        let hosting = NSHostingController(rootView: ToolbarView(settings: settings, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        hosting.rootView.onHover = { [weak self] hovering in self?.hoverChanged(hovering) }
    }

    var windowNumber: Int { panel.windowNumber }

    /// Where the rail is on screen while it's showing. Nothing is drawn there.
    var visibleFrame: NSRect? {
        panel.isVisible && panel.alphaValue > 0 ? panel.frame : nil
    }

    /// Slides the rail in at the left edge of `screen`, vertically centered.
    func show(on screen: NSScreen, animated: Bool) {
        transition += 1
        collapseTask?.cancel()
        collapseTask = nil
        if let fitting = panel.contentViewController?.view.fittingSize, fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let target = NSPoint(x: visible.minX + 12, y: visible.midY - size.height / 2)
        panel.setFrameOrigin(animated ? NSPoint(x: target.x - size.width * 0.6, y: target.y) : target)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.28 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if animated {
                panel.animator().setFrameOrigin(target)
            }
        }
    }

    func hide(animated: Bool) {
        transition += 1
        let generation = transition
        collapseTask?.cancel()
        collapseTask = nil
        isHovering = false
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.2 : 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if animated {
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX - panel.frame.width * 0.6, y: panel.frame.minY))
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    /// The user started a stroke: shrink to a pill after a few seconds, unless the pointer is on the rail.
    func noteDrawing() {
        guard !settings.isToolbarCollapsed, collapseTask == nil, !isHovering else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            guard !self.isHovering else { return }
            self.setCollapsed(true)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            setCollapsed(false)
        }
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard settings.isToolbarCollapsed != collapsed else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) {
            settings.isToolbarCollapsed = collapsed
            if collapsed {
                settings.isFlyoutOpen = false
            }
        }
    }
}

private final class ToolbarWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: DrawOverlayWindow.overlayLevel.rawValue + 1)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // The canvas keeps keyboard focus; the rail only takes clicks.
    override var canBecomeKey: Bool { false }

    // Growing or shrinking (the pill, a flyout) keeps the top edge where it is, so the rail
    // doesn't jump under the pointer.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.size != frame.size, rect.origin == frame.origin {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }
}

private struct ToolbarView: View {
    @Bindable var settings: DrawSettings
    let actions: ToolbarActions
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if settings.isToolbarCollapsed {
                pill
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topLeading)))
            } else {
                rail
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                if settings.showsFlyout {
                    ToolFlyout(settings: settings, returnFocus: actions.returnFocus)
                }
            }
        }
        .padding(6)
        // Fully transparent pixels let clicks fall through to the canvas below; this keeps the
        // whole rail, margins included, a place for picking tools and never for drawing.
        .background(Color.black.opacity(0.012))
        .onHover { onHover($0) }
    }

    /// The collapsed rail: the current tool, color and size. Hover to expand.
    private var pill: some View {
        VStack(spacing: 6) {
            Image(systemName: settings.tool.symbol)
                .font(.system(size: 14))
            BrushDot(color: settings.color, width: settings.width)
        }
        .padding(.vertical, DesignTokens.Spacing.small)
        .padding(.horizontal, DesignTokens.Spacing.xSmall)
        .cheeseSurface(in: Capsule())
        .help("\(settings.tool.title) · \(Int(settings.width)) pt")
    }

    private var rail: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                WindowDragHandle()
                    .frame(width: 22, height: 18)
                    .overlay {
                        Image(systemName: "line.3.horizontal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                    .help("Drag to move")
                Button(action: actions.exit) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Exit Draw Mode (Esc)")
            }
            BrushDot(color: settings.color, width: settings.width)
                .frame(height: 24)
                .help("\(Int(settings.width)) pt. Scroll to resize, ⇧-scroll to change color, or hold the right button for the radial menu")
            section([.select, .passThrough])
            section([.pen, .highlighter, .eraser])
            section([.rectangle, .ellipse, .line, .arrow])
            section([.text, .sticky, .stamp])
            section([.laser, .spotlight, .zoom])
            Divider().frame(width: 28)
            RailButton(
                symbol: settings.board == .blackboard ? "square.fill" : settings.board == .whiteboard ? "square.lefthalf.filled" : "square.dashed",
                help: settings.board.title,
                isActive: settings.board != .off,
                action: actions.cycleBoard
            )
            RailButton(
                symbol: settings.isDisappearingInk ? "timer" : "timer.circle",
                help: settings.isDisappearingInk ? "Disappearing Ink: On" : "Disappearing Ink: Off",
                isActive: settings.isDisappearingInk,
                action: actions.toggleDisappearingInk
            )
            Divider().frame(width: 28)
            RailButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: actions.undo)
                .disabled(!settings.canUndo)
            RailButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: actions.redo)
                .disabled(!settings.canRedo)
            RailButton(symbol: "trash", help: "Clear All", action: actions.clearAll)
            RailButton(symbol: "camera", help: "Snapshot (⇧⌘S) — Shift-click to annotate") {
                actions.snapshot(NSEvent.modifierFlags.contains(.shift))
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xSmall)
        .padding(.horizontal, DesignTokens.Spacing.xxSmall)
        .cheeseSurface(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
    }

    @ViewBuilder
    private func section(_ tools: [DrawTool]) -> some View {
        Divider().frame(width: 28)
        ForEach(tools, id: \.self) { tool in
            RailButton(symbol: tool.symbol, help: tool.title, isActive: settings.tool == tool) {
                actions.chooseTool(tool)
            }
        }
    }
}

/// The brush as a dot: its color, at its width.
private struct BrushDot: View {
    let color: CanvasColor
    let width: CGFloat

    var body: some View {
        Circle()
            .fill(Color(CanvasRenderer.nsColor(color)))
            .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
            .frame(width: min(max(width, 4), 22), height: min(max(width, 4), 22))
            .frame(width: 24, height: 24)
    }
}

private struct RailButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 27)
                // Touch-sized for a drawing tool, so a little larger than CheeseIconButton.
                .background(isActive ? Color.accentColor.opacity(DesignTokens.Opacity.activeTint) : .clear, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .help(help)
    }
}

/// The options for the current tool, beside the rail.
private struct ToolFlyout: View {
    @Bindable var settings: DrawSettings
    let returnFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.tool.title)
                .font(.headline)
            if settings.tool == .sticky {
                Swatches(colors: CanvasColor.stickyColors, selection: $settings.stickyColor, returnFocus: returnFocus)
            } else {
                Swatches(colors: CanvasColor.presets, selection: $settings.color, returnFocus: returnFocus)
                ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                    .font(.caption)
            }
            if settings.tool == .stamp {
                stampPicker
            }
            if settings.tool.usesWidth {
                widthControls
            }
            if settings.tool == .pen {
                Toggle("Neon", isOn: $settings.isNeon)
                    .onChange(of: settings.isNeon) { _, _ in returnFocus() }
            }
            if settings.tool == .rectangle || settings.tool == .ellipse {
                Toggle("Fill", isOn: $settings.isFilled)
                    .onChange(of: settings.isFilled) { _, _ in returnFocus() }
            }
            if settings.tool == .text {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Font size: \(Int(settings.fontSize)) pt")
                        .font(.caption)
                    Slider(value: $settings.fontSize, in: DrawSettings.fontSizeRange, step: 1) { editing in
                        if !editing { returnFocus() }
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(width: 180, alignment: .leading)
        .cheeseSurface(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
    }

    private var stampPicker: some View {
        HStack(spacing: 6) {
            ForEach(StampKind.allCases, id: \.self) { kind in
                Button {
                    settings.stampKind = kind
                    returnFocus()
                } label: {
                    Image(systemName: kind.symbol)
                        .frame(width: 26, height: 26)
                        .background(settings.stampKind == kind ? Color.accentColor.opacity(DesignTokens.Opacity.activeTint) : .clear, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.title)
            }
        }
    }

    private var widthControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.tool == .stamp ? "Size: \(Int(settings.width)) (scroll)" : "Width: \(Int(settings.width)) pt (scroll)")
                .font(.caption)
            HStack(spacing: 10) {
                ForEach(DrawSettings.widthPresets, id: \.self) { width in
                    Button {
                        settings.width = width
                        returnFocus()
                    } label: {
                        Circle()
                            .frame(width: width + 4, height: width + 4)
                            .frame(width: 28, height: 28)
                            .background(settings.width == width ? Color.accentColor.opacity(DesignTokens.Opacity.activeTint) : .clear, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Slider(value: $settings.width, in: DrawSettings.widthRange, step: 1) { editing in
                if !editing { returnFocus() }
            }
        }
    }

    private var customColor: Binding<Color> {
        Binding {
            Color(CanvasRenderer.nsColor(settings.color))
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            settings.color = CanvasColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
    }
}

private struct Swatches: View {
    let colors: [CanvasColor]
    @Binding var selection: CanvasColor
    let returnFocus: () -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 5), alignment: .leading, spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button {
                    selection = color
                    returnFocus()
                } label: {
                    Circle()
                        .fill(Color(CanvasRenderer.nsColor(color)))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selection == color ? 3 : 0).padding(-3))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Dragging here moves the toolbar window.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ view: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
