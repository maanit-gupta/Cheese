import AppKit
import Observation
import SwiftUI

/// While a scrolling capture runs: a border around the region and a small panel with progress and Stop.
/// Esc or Return also stops. Both windows sit outside the region and are excluded from capture anyway.
@MainActor
final class ScrollCaptureHUD {
    @Observable
    @MainActor
    final class Progress {
        var height = 0
    }

    private let region: CGRect
    private let onStop: () -> Void
    private let progress = Progress()
    private var border: NSWindow?
    private var panel: NSPanel?
    private var keyMonitor: Any?

    init(region: CGRect, onStop: @escaping () -> Void) {
        self.region = region
        self.onStop = onStop
    }

    func show() {
        let border = NSWindow(contentRect: region.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        border.backgroundColor = .clear
        border.isOpaque = false
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.isReleasedWhenClosed = false
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        border.contentView = RegionBorderView()
        border.orderFrontRegardless()
        self.border = border

        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: HUDView(progress: progress, stop: { [weak self] in self?.onStop() }))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.setFrameOrigin(panelOrigin(for: hosting.fittingSize))
        self.panel = panel

        // Cheese takes keyboard focus so Esc and Return reach it; the window under the region still scrolls.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            // Esc, Return, keypad Enter.
            guard keyCode == 53 || keyCode == 36 || keyCode == 76 else { return event }
            MainActor.assumeIsolated { self?.onStop() }
            return nil
        }
    }

    func update(height: Int) {
        progress.height = height
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        border?.close()
        panel?.close()
        border = nil
        panel = nil
    }

    /// Below the region if it fits on screen, else above it, else inside its bottom edge.
    private func panelOrigin(for size: CGSize) -> CGPoint {
        let visible = (NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main)?.visibleFrame ?? region
        let x = min(max(region.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        if region.minY - size.height - 16 >= visible.minY {
            return CGPoint(x: x, y: region.minY - size.height - 16)
        }
        if region.maxY + size.height + 16 <= visible.maxY {
            return CGPoint(x: x, y: region.maxY + 16)
        }
        return CGPoint(x: x, y: region.minY + 16)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.setLineDash([8, 4], count: 2, phase: 0)
        path.stroke()
    }
}

private struct HUDView: View {
    let progress: ScrollCaptureHUD.Progress
    let stop: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.large) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text("Scrolling capture")
                    .font(DesignTokens.Typography.heading)
                Text(progress.height > 0 ? "\(progress.height) px · Esc or Return to stop" : "Esc or Return to stop")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Stop", action: stop)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DesignTokens.Spacing.xLarge)
        .padding(.vertical, DesignTokens.Spacing.medium)
        .cheeseSurface(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .fixedSize()
    }
}
