import AppKit
import SwiftUI

/// The first-launch welcome window. Closing it, finished or not, counts as seen;
/// it can be reopened from Settings → General.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let permissions: any PermissionChecking
    private let openPermissionSettings: @MainActor (Permission) -> Void
    private let defaults: UserDefaults
    private var window: NSWindow?

    init(
        permissions: any PermissionChecking,
        openPermissionSettings: @escaping @MainActor (Permission) -> Void,
        defaults: UserDefaults = .standard
    ) {
        self.permissions = permissions
        self.openPermissionSettings = openPermissionSettings
        self.defaults = defaults
    }

    func showIfFirstLaunch() {
        guard !Preferences(defaults: defaults).hasSeenWelcome else { return }
        show()
    }

    func show() {
        // Closing drops the window, so reopening later starts again from the first page.
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(
            permissions: permissions,
            openSystemSettings: openPermissionSettings,
            finish: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Cheese"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        defaults.set(true, forKey: PreferenceKey.hasSeenWelcome)
        window = nil
    }
}
