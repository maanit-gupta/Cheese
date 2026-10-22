import AppKit
import SwiftUI

/// A brief, non-activating message near the top of the screen under the pointer, optionally with one action.
@MainActor
final class Toast {
    struct Action {
        var title: String
        var perform: @MainActor () -> Void
    }

    private static var current: Toast?

    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?

    static func show(_ message: String, systemImage: String = "checkmark.circle.fill", action: Action? = nil) {
        current?.dismiss(animated: false)
        let toast = Toast(message: message, systemImage: systemImage, action: action)
        current = toast
        toast.present(for: action == nil ? .seconds(1.6) : .seconds(4))
    }

    private init(message: String, systemImage: String, action: Action?) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = action == nil

        var dismiss: @MainActor () -> Void = {}
        let view = ToastView(message: message, systemImage: systemImage, actionTitle: action?.title) {
            action?.perform()
            dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        dismiss = { [weak self] in self?.dismiss(animated: true) }
    }

    private func present(for duration: Duration) {
        guard let screen = Screens.underMouse else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    private func dismiss(animated: Bool) {
        dismissTask?.cancel()
        let panel = panel
        if Self.current === self { Self.current = nil }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(message)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
