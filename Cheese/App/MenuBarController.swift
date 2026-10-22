import AppKit
import KeyboardShortcuts

/// Owns the status item. Any click on the icon opens the feature menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let statusMenu: StatusMenu

    /// The view popovers anchor to, so they appear under the menu bar icon.
    var anchorView: NSView? { statusItem.button }

    init(statusMenu: StatusMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusMenu = statusMenu
        super.init()

        statusMenu.menu.delegate = self
        statusItem.menu = statusMenu.menu
        if let button = statusItem.button {
            // Template image from the asset catalog, so it tints for light/dark menu bars.
            let icon = NSImage(resource: .menuBarIcon)
            icon.accessibilityDescription = "Cheese"
            button.image = icon
            button.toolTip = "Cheese"
        }
    }

    /// Short status text beside the icon, like the keep-awake countdown. Nil shows the icon alone.
    func setIndicator(_ text: String?) {
        guard let button = statusItem.button else { return }
        if let text {
            statusItem.length = NSStatusItem.variableLength
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
            button.title = text
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    // MARK: NSMenuDelegate

    // Modules may have been switched on or off since the menu last opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusMenu.rebuild()
    }

    // NSMenu's tracking loop buffers global hotkeys and replays them on close, so pause them while open.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = false
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = true
    }
}
