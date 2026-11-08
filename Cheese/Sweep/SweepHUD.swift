import AppKit
import SwiftUI

/// The Sweep capsule: the countdown, then the time left and how to stop early. One per display,
/// near the top, above everything, and never in the way: it takes no clicks (none arrive anyway).
@MainActor
final class SweepHUD: SweepHUDPresenting {
    @Observable
    final class Model {
        var content = SweepHUDContent.countdown(SweepSession.countdownSeconds)
    }

    private let model = Model()
    private var panels: [NSPanel] = []

    func show(_ content: SweepHUDContent) {
        model.content = content
        if panels.isEmpty {
            present()
        } else {
            panels.forEach(resize)
        }
    }

    func close() {
        let panels = panels
        self.panels = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.duration(DesignTokens.Duration.gentle)
            panels.forEach { $0.animator().alphaValue = 0 }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            panels.forEach { $0.orderOut(nil) }
        }
    }

    private func present() {
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            // Before `level`: setting it afterwards would put the level back to `.floating`.
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let hosting = NSHostingView(rootView: SweepHUDView(model: model))
            panel.contentView = hosting
            panel.identifier = NSUserInterfaceItemIdentifier("\(screen.displayID ?? 0)")
            panels.append(panel)
            resize(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.duration(DesignTokens.Duration.standard)
            panels.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// Sized to its text, centered near the top of its display.
    private func resize(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { "\($0.displayID ?? 0)" == panel.identifier?.rawValue } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - DesignTokens.Spacing.xxxLarge, width: size.width, height: size.height),
            display: true
        )
    }
}

private struct SweepHUDView: View {
    let model: SweepHUD.Model

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.large) {
            Image(systemName: model.content.symbol)
                .font(DesignTokens.Typography.panelTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text(model.content.title)
                    .font(DesignTokens.Typography.heading.monospacedDigit())
                Text(model.content.detail)
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xxLarge)
        .padding(.vertical, DesignTokens.Spacing.large)
        .cheeseSurface(in: Capsule())
        .fixedSize()
    }
}
