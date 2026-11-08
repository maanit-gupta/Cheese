import AppKit
import KeyboardShortcuts

/// Hush's own menu bar icon: a bell, crossed out while notifications are hushed, with the time
/// left on a timed Hush beside it. Clicking it opens the Hush menu. Shown while the module runs.
@MainActor
final class HushStatusItem: NSObject, NSMenuDelegate {
    private let controller: HushController
    private let makeMenu: @MainActor () -> StatusMenu?
    private var statusItem: NSStatusItem?
    private var statusMenu: StatusMenu?

    init(controller: HushController, makeMenu: @escaping @MainActor () -> StatusMenu?) {
        self.controller = controller
        self.makeMenu = makeMenu
        super.init()
    }

    func show() {
        guard statusItem == nil, let menu = makeMenu() else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.menu.delegate = self
        item.menu = menu.menu
        item.button?.toolTip = "Hush"
        statusItem = item
        statusMenu = menu
        update()
    }

    func hide() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        statusMenu = nil
    }

    func update() {
        guard let button = statusItem?.button else { return }
        let hushed = controller.isEngaged
        let image = NSImage(
            systemSymbolName: hushed ? "bell.slash.fill" : "bell",
            accessibilityDescription: hushed ? "Notifications hushed" : "Hush"
        )
        image?.isTemplate = true
        button.image = image
        if let text = controller.indicatorText, hushed {
            statusItem?.length = NSStatusItem.variableLength
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
            button.title = text
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem?.length = NSStatusItem.squareLength
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusMenu?.rebuild()
    }

    // Like the Cheese menu: global hotkeys pause while it's open, so they aren't replayed on close.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = false
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = true
    }
}
