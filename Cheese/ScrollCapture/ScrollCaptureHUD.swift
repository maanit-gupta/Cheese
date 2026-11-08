import AppKit
import Observation
import SwiftUI

/// While a scrolling capture runs: a border around the region and a bar with what's been captured
/// so far, the Auto-scroll switch, Cancel and Done. Return finishes, Esc cancels. Both windows sit
/// outside the region and are excluded from capture anyway.
@MainActor
final class ScrollCaptureHUD {
    @Observable
    @MainActor
    final class Model {
        var height = 0
        var thumbnail: CGImage?
        /// A word of help, like "Lost the page — scroll back up a little".
        var hint: String?
        var autoScroll: Bool

        init(autoScroll: Bool) {
            self.autoScroll = autoScroll
        }
    }

    struct Actions {
        var done: @MainActor () -> Void
        var cancel: @MainActor () -> Void
        var autoScrollChanged: @MainActor (Bool) -> Void
    }

    private let region: CGRect
    private let actions: Actions
    private let model: Model
    private let border: RegionBorderWindow
    private var panel: NSPanel?
    private var keyMonitor: Any?

    init(region: CGRect, autoScroll: Bool, actions: Actions) {
        self.region = region
        self.actions = actions
        model = Model(autoScroll: autoScroll)
        border = RegionBorderWindow(region: region)
    }

    func show() {
        border.show()

        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let actions = actions
        let hosting = NSHostingView(rootView: HUDView(model: model, actions: actions))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.setFrameOrigin(panelOrigin(for: hosting.fittingSize))
        self.panel = panel

        // Cheese takes keyboard focus so Esc and Return reach it; the window under the region still scrolls.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            switch keyCode {
            // Return and keypad Enter finish.
            case 36, 76:
                MainActor.assumeIsolated { actions.done() }
                return nil
            // Esc cancels.
            case 53:
                MainActor.assumeIsolated { actions.cancel() }
                return nil
            default:
                return event
            }
        }
    }

    func update(height: Int, thumbnail: CGImage?) {
        model.height = height
        if let thumbnail {
            model.thumbnail = thumbnail
        }
    }

    func setHint(_ hint: String?) {
        model.hint = hint
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        border.close()
        panel?.close()
        panel = nil
    }

    /// Below the region if it fits on screen, else above it, else inside its bottom edge.
    private func panelOrigin(for size: CGSize) -> CGPoint {
        let visible = (NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main)?.visibleFrame ?? region
        let gap = DesignTokens.Spacing.xLarge
        let x = min(max(region.midX - size.width / 2, visible.minX + DesignTokens.Spacing.small), visible.maxX - size.width - DesignTokens.Spacing.small)
        if region.minY - size.height - gap >= visible.minY {
            return CGPoint(x: x, y: region.minY - size.height - gap)
        }
        if region.maxY + size.height + gap <= visible.maxY {
            return CGPoint(x: x, y: region.maxY + gap)
        }
        return CGPoint(x: x, y: region.minY + gap)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct HUDView: View {
    @Bindable var model: ScrollCaptureHUD.Model
    let actions: ScrollCaptureHUD.Actions

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.large) {
            thumbnail
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text(model.autoScroll ? "Scrolling for you" : "Scroll to capture")
                    .font(DesignTokens.Typography.heading)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.hint == nil ? .secondary : Color.orange)
            }
            .frame(minWidth: 220, alignment: .leading)
            Toggle("Auto-scroll", isOn: $model.autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: model.autoScroll) { _, isOn in actions.autoScrollChanged(isOn) }
            Button("Cancel", action: actions.cancel)
            Button("Done", action: actions.done)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DesignTokens.Spacing.xLarge)
        .padding(.vertical, DesignTokens.Spacing.medium)
        .cheeseSurface(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .fixedSize()
    }

    private var detail: String {
        if let hint = model.hint { return hint }
        let size = model.height > 0 ? "\(model.height.formatted()) px · " : ""
        return size + "Return to finish, Esc to cancel"
    }

    /// The growing image, squeezed into a narrow strip.
    @ViewBuilder
    private var thumbnail: some View {
        let box = CGSize(width: 36, height: DesignTokens.Size.thumbnailRow)
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(.quaternary)
            if let image = model.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            } else {
                Image(systemName: "rectangle.expand.vertical")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: box.width, height: box.height)
    }
}
