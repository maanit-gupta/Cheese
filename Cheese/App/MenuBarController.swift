import AppKit
import KeyboardShortcuts

/// Owns the status item. Any click on the icon opens the feature menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem

    /// The view popovers anchor to, so they appear under the menu bar icon.
    var anchorView: NSView? { statusItem.button }

    init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            // Template image from the asset catalog, so it tints for light/dark menu bars.
            let icon = NSImage(resource: .menuBarIcon)
            icon.accessibilityDescription = "Cheese"
            button.image = icon
            button.toolTip = "Cheese"
        }
    }

    // MARK: NSMenuDelegate

    // NSMenu's tracking loop buffers global hotkeys and replays them on close, so pause them while open.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = false
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = true
    }
}
