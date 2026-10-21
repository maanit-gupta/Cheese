import AppKit
import SwiftUI

/// What Settings needs from other modules, injected by `AppDelegate`.
struct SettingsDependencies {
    var permissions: any PermissionChecking
    var openPermissionSettings: @MainActor (Permission) -> Void
    var supportedOCRLanguages: @MainActor () -> Set<OCRLanguage>
}

/// Hosts `SettingsView` in a plain window. A SwiftUI `Settings` scene is awkward to open
/// from an `LSUIElement` app's status menu, so Cheese manages the window itself.
@MainActor
final class SettingsWindowController {
    private let dependencies: SettingsDependencies
    private var window: NSWindow?

    init(dependencies: SettingsDependencies) {
        self.dependencies = dependencies
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(dependencies: dependencies)))
        window.title = "Cheese Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
