import AppKit
import SwiftUI

/// The translucent outline of where a dragged window will land, shown while the pointer is in a
/// snap zone. Never key, never takes clicks, on every Space and over full-screen apps.
@MainActor
final class SnapPreviewWindowController {
    private var panel: NSPanel?
    private var shownFrame: CGRect?

    /// Shows the preview over `quartzFrame`, sliding there from the zone shown before.
    func show(_ quartzFrame: CGRect) {
        let frame = Screens.appKitRect(fromQuartz: quartzFrame)
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if shownFrame == nil {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.duration(DesignTokens.Duration.standard)
                panel.animator().alphaValue = 1
            }
        } else if shownFrame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.duration(DesignTokens.Duration.standard)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        }
        shownFrame = frame
    }

    /// Hides the preview at once (the pointer left every zone, or the drag ended).
    func hide() {
        guard shownFrame != nil else { return }
        shownFrame = nil
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // After isFloatingPanel, which would reset the level to .floating.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: SnapPreviewView())
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// A rounded, see-through rectangle with an accent edge, inset from the target frame.
private struct SnapPreviewView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color.accentColor.opacity(DesignTokens.Opacity.activeTint))
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.accentColor.opacity(DesignTokens.Opacity.selectedRowTint)))
            }
        }
        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: DesignTokens.Size.selectionBar))
        .padding(DesignTokens.Spacing.xSmall)
    }
}

/// Drag-to-edge snapping: the drag monitor, the preview, and placing the window on release.
@MainActor
final class DragSnapController {
    private let monitor: WindowDragMonitor
    private let preview = SnapPreviewWindowController()

    /// - Parameter place: moves the dropped window into the zone's frame.
    init(monitor: WindowDragMonitor, place: @escaping (SnapZoneHit, AXWindow) -> Void) {
        self.monitor = monitor
        monitor.onZoneChange = { [preview] hit in
            if let hit {
                preview.show(hit.frame)
            } else {
                preview.hide()
            }
        }
        monitor.onDrop = { [preview] hit, window in
            preview.hide()
            // Next turn, so the window server has finished the drag's own last move.
            DispatchQueue.main.async {
                place(hit, window)
            }
        }
    }

    var isRunning: Bool { monitor.isRunning }

    func start() {
        monitor.start()
    }

    func stop() {
        monitor.stop()
        preview.hide()
    }
}
