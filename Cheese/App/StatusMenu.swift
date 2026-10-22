import AppKit
import KeyboardShortcuts

/// The menu bar menu: every available action, so nothing needs a hotkey. Items that have a global
/// hotkey show its current binding, and update when it's rebound. Rebuilt each time it opens, so
/// actions of disabled modules are left out.
@MainActor
final class StatusMenu: NSObject {
    struct Section: Equatable {
        var header: String?
        var entries: [Entry]
    }

    enum Entry: Equatable {
        case action(ActionID, keyEquivalent: String = "")
        case submenu(title: String, symbol: String, actions: [ActionID])
    }

    static let layout: [Section] = [
        Section(entries: [.action(.openHistory)]),
        Section(header: "Capture", entries: [.action(.captureRegion), .action(.captureWindow), .action(.captureFullScreen), .action(.scrollingCapture)]),
        Section(header: "Text", entries: [.action(.ocrRegion)]),
        // Snapping acts on the frontmost app's window. Opening this menu doesn't activate Cheese,
        // so that's still the window the user was working in.
        Section(header: "Windows", entries: [
            .submenu(title: "Arrange Window", symbol: "macwindow.on.rectangle", actions: [.snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow]),
        ]),
        Section(header: "Utilities", entries: [
            .action(.showClipboardQR),
            .submenu(title: "Keep Awake", symbol: "cup.and.saucer", actions: [.keepAwakeIndefinitely, .keepAwakeUntil, .keepAwakeOff]),
        ]),
        Section(entries: [.action(.clearHistory), .action(.clearAll)]),
        Section(entries: [.action(.commandPalette), .action(.editShortcuts), .action(.openSettings, keyEquivalent: ","), .action(.showWelcome)]),
        Section(entries: [.action(.quit, keyEquivalent: "q")]),
    ]

    /// The layout without unavailable actions, and without the submenus and sections they leave empty.
    static func visibleSections(of layout: [Section], isAvailable: (ActionID) -> Bool) -> [Section] {
        layout.compactMap { section in
            let entries = section.entries.compactMap { entry -> Entry? in
                switch entry {
                case let .action(id, _):
                    return isAvailable(id) ? entry : nil
                case let .submenu(title, symbol, actions):
                    let visible = actions.filter(isAvailable)
                    return visible.isEmpty ? nil : .submenu(title: title, symbol: symbol, actions: visible)
                }
            }
            return entries.isEmpty ? nil : Section(header: section.header, entries: entries)
        }
    }

    let menu = NSMenu()
    private let registry: ActionRegistry

    init(registry: ActionRegistry) {
        self.registry = registry
        super.init()
        rebuild()
    }

    func rebuild() {
        menu.removeAllItems()
        let sections = Self.visibleSections(of: Self.layout) { registry.isAvailable($0) }
        for (index, section) in sections.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            if let header = section.header {
                menu.addItem(.sectionHeader(title: header))
            }
            for entry in section.entries {
                if let item = item(for: entry) {
                    menu.addItem(item)
                }
            }
        }
    }

    private func item(for entry: Entry) -> NSMenuItem? {
        switch entry {
        case let .action(id, keyEquivalent):
            return actionItem(id, keyEquivalent: keyEquivalent)
        case let .submenu(title, symbol, actions):
            let submenu = NSMenu()
            for item in actions.compactMap({ actionItem($0, inSubmenu: true) }) {
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            parent.submenu = submenu
            return parent
        }
    }

    private func actionItem(_ id: ActionID, keyEquivalent: String = "", inSubmenu: Bool = false) -> NSMenuItem? {
        guard let action = registry.action(id) else { return nil }
        let title = inSubmenu ? action.menuTitle ?? action.title : action.title
        let item = NSMenuItem(title: title, action: #selector(itemSelected(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = id.rawValue
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        if let shortcut = action.shortcut {
            item.setShortcut(for: shortcut)
        }
        return item
    }

    @objc private func itemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        registry.perform(ActionID(rawValue: rawValue))
    }
}
