import AppKit
import SwiftUI

/// What Settings needs from other modules, injected by `AppDelegate`.
struct SettingsDependencies {
    var permissions: any PermissionChecking
    var openPermissionSettings: @MainActor (Permission) -> Void
    var supportedOCRLanguages: @MainActor () -> Set<OCRLanguage>
    var showWelcome: @MainActor () -> Void
}

/// Hosts `SettingsView` in a plain window. A SwiftUI `Settings` scene is awkward to open
/// from an `LSUIElement` app's status menu, so Cheese manages the window itself.
@MainActor
final class SettingsWindowController {
    private let dependencies: SettingsDependencies
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(dependencies: SettingsDependencies) {
        self.dependencies = dependencies
    }

    /// Shows Settings, switching to `tab` when given and otherwise keeping the last tab.
    func show(tab: SettingsTab? = nil) {
        if let tab {
            navigation.tab = tab
        }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(dependencies: dependencies, navigation: navigation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Cheese Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
