import AppKit
import SwiftUI

/// What the HUD's buttons do, supplied by `DrawModeController`.
struct HUDActions {
    var chooseTool: (DrawTool) -> Void
    var cycleBoard: () -> Void
    var toggleDisappearingInk: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var clearAll: () -> Void
    /// Shift held opens the annotation editor instead of copying.
    var snapshot: (_ shiftHeld: Bool) -> Void
    var exit: () -> Void
}

/// Draw mode's tool rail. It never takes keyboard focus (the canvas keeps it), yet every button
/// works on the first click, acts on mouse-down, and stays put: the rail doesn't collapse, slide or
/// resize, and moves only when the user drags its grip. Options live in two popovers, Style and
/// More, which open only from their own buttons, never because a tool was picked.
@MainActor
final class DrawHUD {
    /// Remembered position, under `panelOrigin_drawHUD`.
    static let positionKey = "drawHUD"
    /// Room between the rail and the screen edge, and between the rail and a popover.
    static let margin = DesignTokens.Spacing.large

    /// The tools on the rail itself, in groups; the rest are under More.
    nonisolated static let railGroups: [[DrawTool]] = [
        [.select, .passThrough],
        [.pen, .highlighter, .eraser],
        [.line, .arrow, .rectangle, .ellipse],
        [.text],
    ]
    nonisolated static let moreTools: [DrawTool] = [.sticky, .stamp, .laser, .spotlight, .zoom]

    private let settings: DrawSettings
    private let actions: HUDActions
    private let rail = DrawHUDWindow()
    private let popover = DrawHUDWindow()
    private let railHost: FirstMouseHostingView<HUDRailView>
    private let popoverHost: FirstMouseHostingView<HUDPopoverView>
    private var moveObserver: NSObjectProtocol?
    /// Bumped on every show and hide, so a fade-out that finishes late doesn't hide a fresh rail.
    private var transition = 0

    init(settings: DrawSettings, actions: HUDActions) {
        self.settings = settings
        self.actions = actions
        railHost = FirstMouseHostingView(rootView: HUDRailView(settings: settings, actions: actions, togglePopover: { _ in }))
        popoverHost = FirstMouseHostingView(rootView: HUDPopoverView(kind: .style, settings: settings, actions: actions))
        railHost.rootView = HUDRailView(settings: settings, actions: actions) { [weak self] kind in
            self?.togglePopover(kind)
        }
        rail.contentView = railHost
        popover.contentView = popoverHost
    }

    /// Whether `window` (by identity) is the rail or its popover.
    func owns(_ window: ObjectIdentifier) -> Bool {
        window == ObjectIdentifier(rail) || window == ObjectIdentifier(popover)
    }

    /// Screen rects where clicks belong to the HUD: the canvas never draws there.
    var interactiveFrames: [NSRect] {
        [rail, popover].filter { $0.isVisible && $0.alphaValue > 0 }.map(\.frame)
    }

    /// Fades the rail in where the user last left it, or at the left edge of the display under the pointer.
    func show(animated: Bool) {
        transition += 1
        setPopover(nil)
        let size = railHost.fittingSize
        if size.width > 0, size.height > 0 {
            rail.setContentSize(size)
        }
        rail.setFrameOrigin(startingOrigin())
        rail.alphaValue = 0
        rail.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? DesignTokens.Duration.gentle : DesignTokens.Duration.quick
            rail.animator().alphaValue = 1
        }
        observeMoves()
    }

    func hide(animated: Bool) {
        transition += 1
        let generation = transition
        setPopover(nil)
        let rail = rail
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? DesignTokens.Duration.standard : DesignTokens.Duration.quick
            rail.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == generation else { return }
                rail.orderOut(nil)
            }
        }
    }

    /// Displays changed: bring the rail back onto one if it's now off screen.
    func keepOnScreen() {
        guard rail.isVisible, !Self.fits(rail.frame) else { return }
        rail.setFrameOrigin(defaultOrigin(size: rail.frame.size))
        setPopover(nil)
    }

    // MARK: Popovers

    func togglePopover(_ kind: HUDPopover) {
        setPopover(settings.openPopover == kind ? nil : kind)
    }

    /// Opens `kind` beside the rail, or closes the popover with nil.
    func setPopover(_ kind: HUDPopover?) {
        settings.openPopover = kind
        guard let kind, rail.isVisible else {
            if popover.parent != nil {
                rail.removeChildWindow(popover)
            }
            popover.orderOut(nil)
            return
        }
        popoverHost.rootView = HUDPopoverView(kind: kind, settings: settings, actions: actions)
        let size = popoverHost.fittingSize
        if size.width > 0, size.height > 0 {
            popover.setContentSize(size)
        }
        popover.setFrameOrigin(popoverOrigin(size: popover.frame.size))
        if popover.parent == nil {
            // A child window moves with the rail when it's dragged.
            rail.addChildWindow(popover, ordered: .above)
        }
        popover.orderFrontRegardless()
    }

    // MARK: Placement

    private func startingOrigin() -> NSPoint {
        let size = rail.frame.size
        if let saved = PanelPositions.origin(forKey: Self.positionKey), Self.fits(NSRect(origin: saved, size: size)) {
            return saved
        }
        return defaultOrigin(size: size)
    }

    private func defaultOrigin(size: NSSize) -> NSPoint {
        guard let visible = (Screens.underMouse ?? NSScreen.main)?.visibleFrame else { return .zero }
        return NSPoint(x: visible.minX + Self.margin, y: visible.midY - size.height / 2)
    }

    /// Whether `rect` lies wholly on one display.
    private static func fits(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.contains(rect) }
    }

    /// Beside the rail, top edges level; on the left when there's no room on the right.
    private func popoverOrigin(size: NSSize) -> NSPoint {
        let anchor = rail.frame
        let visible = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? anchor
        var x = anchor.maxX + Self.margin
        if x + size.width > visible.maxX {
            x = anchor.minX - Self.margin - size.width
        }
        let y = min(max(anchor.maxY - size.height, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    /// Saves the position whenever the user drags the rail.
    private func observeMoves() {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: rail, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.rail.isVisible else { return }
                PanelPositions.save(self.rail.frame.origin, forKey: Self.positionKey)
            }
        }
    }
}

/// The rail's and popovers' window: above the canvas, never key, never main.
private final class DrawHUDWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Before `level`: turning on isFloatingPanel resets the level to `.floating`.
        isFloatingPanel = true
        level = DrawLevels.hud
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Set explicitly, so the transparent rounded corners take clicks too instead of passing
        // them to the canvas underneath.
        ignoresMouseEvents = false
    }

    // The canvas keeps keyboard focus; the HUD only takes clicks, on the first one.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The rail

private struct HUDRailView: View {
    @Bindable var settings: DrawSettings
    let actions: HUDActions
    let togglePopover: (HUDPopover) -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.hairline) {
            WindowDragHandle()
                .frame(width: DesignTokens.HUD.button.width, height: DesignTokens.Spacing.xLarge)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                .help("Drag to move")
            ForEach(Array(DrawHUD.railGroups.enumerated()), id: \.offset) { _, tools in
                RailDivider()
                ForEach(tools, id: \.self) { tool in
                    HUDButton(symbol: tool.symbol, help: tool.helpText, hint: tool.key, emphasis: emphasis(for: tool)) {
                        actions.chooseTool(tool)
                    }
                }
            }
            RailDivider()
            HUDPressable(help: "Color and Stroke: \(Int(settings.width)) pt", emphasis: settings.openPopover == .style ? .active : .normal) {
                togglePopover(.style)
            } label: {
                BrushDot(color: settings.color, width: settings.width)
            }
            RailDivider()
            HUDButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", isEnabled: settings.canUndo, action: actions.undo)
            HUDButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", isEnabled: settings.canRedo, action: actions.redo)
            HUDButton(symbol: "trash", help: "Clear All", action: actions.clearAll)
            RailDivider()
            HUDButton(symbol: moreSymbol, help: "More Tools", emphasis: moreEmphasis) {
                togglePopover(.more)
            }
            RailDivider()
            HUDButton(symbol: "checkmark", help: "Done (Esc)", action: actions.exit)
        }
        .padding(.vertical, DesignTokens.Spacing.xSmall)
        .padding(.horizontal, DesignTokens.Spacing.xxSmall)
        .cheeseSurface(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                .strokeBorder(Color.primary.opacity(DesignTokens.Opacity.panelBorder), lineWidth: 1)
        )
    }

    private func emphasis(for tool: DrawTool) -> HUDEmphasis {
        guard settings.tool == tool else { return .normal }
        return tool == .passThrough ? .passThrough : .active
    }

    /// A tool picked from More shows on its button, so the active tool is always visible on the rail.
    private var moreSymbol: String {
        DrawHUD.moreTools.contains(settings.tool) ? settings.tool.symbol : "ellipsis"
    }

    private var moreEmphasis: HUDEmphasis {
        settings.openPopover == .more || DrawHUD.moreTools.contains(settings.tool) ? .active : .normal
    }
}

private struct RailDivider: View {
    var body: some View {
        CheeseDivider()
            .frame(width: DesignTokens.HUD.button.width - DesignTokens.Spacing.xxSmall)
            .padding(.vertical, DesignTokens.Spacing.hairline)
    }
}

/// A HUD control that acts the moment the mouse goes down, rather than on release.
private enum HUDEmphasis {
    case normal
    case active
    /// Pass-through looks different from a drawing tool, so it's obvious clicks go through.
    case passThrough
}

private struct HUDPressable<Label: View>: View {
    let help: String
    var hint: Character?
    var emphasis = HUDEmphasis.normal
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
        label()
            .foregroundStyle(foreground)
            .frame(width: DesignTokens.HUD.button.width, height: DesignTokens.HUD.button.height)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(tint, lineWidth: emphasis == .normal ? 0 : DesignTokens.HUD.activeRing))
            .overlay(alignment: .bottomTrailing) {
                if let hint {
                    Text(String(hint))
                        .font(DesignTokens.Typography.keyHint)
                        .foregroundStyle(.secondary)
                        .padding(DesignTokens.Spacing.hairline)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        action()
                    }
                    .onEnded { _ in isPressed = false }
            )
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if isEnabled { action() }
            }
    }

    private var tint: Color {
        emphasis == .passThrough ? .green : .accentColor
    }

    private var foreground: Color {
        emphasis == .normal ? .primary : tint
    }

    private var fill: Color {
        switch emphasis {
        case .normal: isHovering && isEnabled ? Color.primary.opacity(DesignTokens.Opacity.hoverTint) : .clear
        case .active, .passThrough: tint.opacity(DesignTokens.Opacity.activeTint)
        }
    }
}

private struct HUDButton: View {
    let symbol: String
    let help: String
    var hint: Character?
    var emphasis = HUDEmphasis.normal
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        HUDPressable(help: help, hint: hint, emphasis: emphasis, isEnabled: isEnabled, action: action) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.hudSymbol)
        }
    }
}

/// The brush as a dot: its color, at its width.
private struct BrushDot: View {
    let color: CanvasColor
    let width: CGFloat

    var body: some View {
        let diameter = min(max(width, DesignTokens.Spacing.xxSmall), DesignTokens.HUD.swatch)
        Circle()
            .fill(Color(CanvasRenderer.nsColor(color)))
            .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Popovers

private struct HUDPopoverView: View {
    let kind: HUDPopover
    @Bindable var settings: DrawSettings
    let actions: HUDActions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            switch kind {
            case .style: StylePopover(settings: settings)
            case .more: MorePopover(settings: settings, actions: actions)
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(width: DesignTokens.HUD.popoverWidth, alignment: .leading)
        .cheeseSurface(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                .strokeBorder(Color.primary.opacity(DesignTokens.Opacity.panelBorder), lineWidth: 1)
        )
    }
}

/// Color, width and the current tool's own options.
private struct StylePopover: View {
    @Bindable var settings: DrawSettings

    var body: some View {
        Text("Color and Stroke")
            .font(DesignTokens.Typography.heading)
        if settings.tool == .sticky {
            Swatches(colors: CanvasColor.stickyColors, selection: $settings.stickyColor)
        } else {
            Swatches(colors: CanvasColor.presets, selection: $settings.color)
            ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                .font(DesignTokens.Typography.caption)
        }
        if settings.tool == .stamp {
            stampPicker
        }
        if settings.tool != .text, settings.tool != .sticky {
            widthControls
        }
        if settings.tool == .pen {
            Toggle("Neon", isOn: $settings.isNeon)
        }
        if settings.tool == .rectangle || settings.tool == .ellipse {
            Toggle("Fill", isOn: $settings.isFilled)
        }
        if settings.tool == .text {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
                Text("Font size: \(Int(settings.fontSize)) pt")
                    .font(DesignTokens.Typography.caption)
                Slider(value: $settings.fontSize, in: DrawSettings.fontSizeRange, step: 1)
            }
        }
    }

    private var stampPicker: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            ForEach(StampKind.allCases, id: \.self) { kind in
                Button {
                    settings.stampKind = kind
                } label: {
                    Image(systemName: kind.symbol)
                        .frame(width: DesignTokens.HUD.widthPresetSlot, height: DesignTokens.HUD.widthPresetSlot)
                        .background(
                            settings.stampKind == kind ? Color.accentColor.opacity(DesignTokens.Opacity.activeTint) : .clear,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.title)
            }
        }
    }

    private var widthControls: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text(settings.tool == .stamp ? "Size: \(Int(settings.width))" : "Width: \(Int(settings.width)) pt")
                .font(DesignTokens.Typography.caption)
            HStack(spacing: DesignTokens.Spacing.medium) {
                ForEach(DrawSettings.widthPresets, id: \.self) { width in
                    Button {
                        settings.width = width
                    } label: {
                        Circle()
                            .frame(width: width + DesignTokens.Spacing.xxSmall, height: width + DesignTokens.Spacing.xxSmall)
                            .frame(width: DesignTokens.HUD.widthPresetSlot, height: DesignTokens.HUD.widthPresetSlot)
                            .background(
                                settings.width == width ? Color.accentColor.opacity(DesignTokens.Opacity.activeTint) : .clear,
                                in: Circle()
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("\(Int(width)) pt")
                }
            }
            Slider(value: $settings.width, in: DrawSettings.widthRange, step: 1)
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

    var body: some View {
        let slot = DesignTokens.HUD.swatch + DesignTokens.Spacing.xxSmall
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(slot), spacing: DesignTokens.Spacing.small), count: 5),
            alignment: .leading,
            spacing: DesignTokens.Spacing.small
        ) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(Color(CanvasRenderer.nsColor(color)))
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                        .overlay(
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: selection == color ? DesignTokens.HUD.swatchRing : 0)
                                .padding(-DesignTokens.HUD.swatchRing)
                        )
                        .frame(width: DesignTokens.HUD.swatch, height: DesignTokens.HUD.swatch)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The tools and switches that don't fit on the rail.
private struct MorePopover: View {
    @Bindable var settings: DrawSettings
    let actions: HUDActions

    var body: some View {
        Text("More Tools")
            .font(DesignTokens.Typography.heading)
        VStack(spacing: DesignTokens.Spacing.hairline) {
            ForEach(DrawHUD.moreTools, id: \.self) { tool in
                HUDRow(symbol: tool.symbol, title: tool.title, hint: tool.key.map(String.init), isActive: settings.tool == tool) {
                    actions.chooseTool(tool)
                }
            }
            CheeseDivider()
                .padding(.vertical, DesignTokens.Spacing.xxSmall)
            HUDRow(symbol: boardSymbol, title: settings.board.title, hint: "B", isActive: settings.board != .off, action: actions.cycleBoard)
            HUDRow(symbol: "timer", title: "Disappearing Ink", hint: nil, isActive: settings.isDisappearingInk, action: actions.toggleDisappearingInk)
            HUDRow(symbol: "camera", title: "Snapshot", hint: "⇧⌘S", isActive: false) {
                actions.snapshot(NSEvent.modifierFlags.contains(.shift))
            }
        }
    }

    private var boardSymbol: String {
        switch settings.board {
        case .off: "square.dashed"
        case .whiteboard: "square.lefthalf.filled"
        case .blackboard: "square.fill"
        }
    }
}

/// A row in the More popover, acting on mouse-down like the rail's buttons.
private struct HUDRow: View {
    let symbol: String
    let title: String
    let hint: String?
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.body)
                .frame(width: DesignTokens.Size.rowIcon)
            Text(title)
                .font(DesignTokens.Typography.body)
            Spacer(minLength: DesignTokens.Spacing.xxSmall)
            if let hint {
                Text(hint)
                    .font(DesignTokens.Typography.keycap)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .padding(.horizontal, DesignTokens.Spacing.xSmall)
        .padding(.vertical, DesignTokens.Spacing.xxSmall)
        .background(background, in: shape)
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    action()
                }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private var background: Color {
        if isActive { return Color.accentColor.opacity(DesignTokens.Opacity.activeTint) }
        return isHovering ? Color.primary.opacity(DesignTokens.Opacity.hoverTint) : .clear
    }
}

/// Dragging here moves the rail.
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

extension DrawTool {
    /// The tooltip: the tool's name and, if it has one, its key.
    var helpText: String {
        key.map { "\(title) (\($0))" } ?? title
    }
}
