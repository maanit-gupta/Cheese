import AppKit
import KeyboardShortcuts

/// Owns the status item. Right-click (or Control-click) always opens the menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    /// Runs on left-click. While nil, left-click opens the menu too.
    var primaryClickAction: (() -> Void)?

    /// The view popovers anchor to, so they appear under the menu bar icon.
    var anchorView: NSView? { statusItem.button }

    init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.menu = menu
        super.init()

        menu.delegate = self
        if let button = statusItem.button {
            // Template image from the asset catalog, so it tints for light/dark menu bars.
            let icon = NSImage(resource: .menuBarIcon)
            icon.accessibilityDescription = "Cheese"
            button.image = icon
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func showMenu() {
        // Attaching the menu only for this click keeps left-click free for `primaryClickAction`.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !wantsMenu, let primaryClickAction {
            primaryClickAction()
        } else {
            showMenu()
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
