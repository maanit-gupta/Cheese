import AppKit
import SwiftUI

/// A borderless, non-activating panel centered on the display under the pointer. It takes keyboard
/// focus without activating Cheese, so the app the user was in stays frontmost. `Esc` and clicks
/// outside it call `onCancel`.
@MainActor
final class FloatingPanel: NSPanel {
    var onCancel: () -> Void = {}
    private var clickMonitors: [Any] = []

    init(rootView: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    /// Centers the panel a little above the middle of the display under the pointer and focuses it.
    func present() {
        if let screen = Screens.underMouse {
            let visible = screen.visibleFrame
            let size = frame.size
            setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height / 10))
        }
        makeKeyAndOrderFront(nil)
        installClickMonitors()
    }

    func dismiss() {
        removeClickMonitors()
        orderOut(nil)
    }

    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel() }
        }) {
            clickMonitors.append(global)
        }
        // Clicks in Cheese's other windows.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                if let self, window !== self { self.onCancel() }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }
}
