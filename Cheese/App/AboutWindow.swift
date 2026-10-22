import AppKit
import SwiftUI

/// "About Cheese": the same content as Settings → About, in its own small window.
@MainActor
final class AboutWindow {
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Opened from the status menu, activation can lose to the app the user was in; stay visible anyway.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let view = AboutView().frame(width: 460, height: 520)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "About Cheese"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
