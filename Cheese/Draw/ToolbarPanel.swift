import AppKit
import SwiftUI

/// What the toolbar's buttons do, supplied by `DrawModeController`.
struct ToolbarActions {
    var chooseTool: (DrawTool) -> Void
    var cycleBoard: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var clearAll: () -> Void
    /// Shift held opens the annotation editor instead of copying.
    var snapshot: (_ shiftHeld: Bool) -> Void
    var exit: () -> Void
    /// After a toolbar control changes a style, give keyboard focus back to the canvas.
    var returnFocus: () -> Void
}

/// The Miro-style vertical tool rail: non-activating, above the overlays, draggable anywhere.
@MainActor
final class ToolbarPanel {
    private let panel: ToolbarWindow

    init(settings: DrawSettings, actions: ToolbarActions) {
        panel = ToolbarWindow()
        let hosting = NSHostingController(rootView: ToolbarView(settings: settings, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
    }

    var windowNumber: Int { panel.windowNumber }

    /// Shows the rail at the left edge of `screen`, vertically centered.
    func show(on screen: NSScreen) {
        if let fitting = panel.contentViewController?.view.fittingSize, fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.minX + 12, y: visible.midY - size.height / 2))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
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
}

private struct ToolbarView: View {
    @Bindable var settings: DrawSettings
    let actions: ToolbarActions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            rail
            if settings.showsFlyout {
                ToolFlyout(settings: settings, returnFocus: actions.returnFocus)
            }
        }
        .padding(6)
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
            section([.select, .passThrough])
            section([.pen, .highlighter, .eraser])
            section([.rectangle, .ellipse, .line, .arrow])
            section([.text, .sticky])
            section([.laser, .spotlight, .zoom])
            Divider().frame(width: 28)
            RailButton(
                symbol: settings.board == .blackboard ? "square.fill" : settings.board == .whiteboard ? "square.lefthalf.filled" : "square.dashed",
                help: "\(settings.board.title) (B)",
                isActive: settings.board != .off,
                action: actions.cycleBoard
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
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func section(_ tools: [DrawTool]) -> some View {
        Divider().frame(width: 28)
        ForEach(tools, id: \.self) { tool in
            RailButton(symbol: tool.symbol, help: "\(tool.title) (\(tool.key))", isActive: settings.tool == tool) {
                actions.chooseTool(tool)
            }
        }
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
                .background(isActive ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 7))
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
            if settings.tool.usesWidth {
                widthControls
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
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var widthControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Width: \(Int(settings.width)) pt  ([ and ])")
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
                            .background(settings.width == width ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
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
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
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
                .help(colors == CanvasColor.presets ? "Color \(index + 1)" : "")
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
