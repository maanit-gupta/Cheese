import AppKit
import KeyboardShortcuts

/// The menu bar menu, drawn from `MenuLayout`. Items that have a global hotkey show its current
/// binding, and update when it's rebound. Rebuilt each time it opens, so actions of disabled
/// modules are left out.
@MainActor
final class StatusMenu: NSObject {
    let menu = NSMenu()
    private let registry: ActionRegistry
    /// Items for work in progress, like running Files jobs, shown at the top of the menu.
    private let progressItems: () -> [NSMenuItem]

    init(registry: ActionRegistry, progressItems: @escaping () -> [NSMenuItem] = { [] }) {
        self.registry = registry
        self.progressItems = progressItems
        super.init()
        rebuild()
    }

    func rebuild() {
        menu.removeAllItems()
        let progress = progressItems()
        for item in progress {
            menu.addItem(item)
        }
        let nodes = MenuLayout.visible(MenuLayout.standard) { registry.isAvailable($0) }
        if !progress.isEmpty, !nodes.isEmpty {
            menu.addItem(.separator())
        }
        add(nodes, to: menu, inSubmenu: false)
    }

    private func add(_ nodes: [MenuLayout.Node], to menu: NSMenu, inSubmenu: Bool) {
        for node in nodes {
            switch node {
            case let .action(id, keyEquivalent, fullTitle):
                if let item = actionItem(id, keyEquivalent: keyEquivalent, inSubmenu: inSubmenu && !fullTitle) {
                    menu.addItem(item)
                }
            case let .alternate(id):
                // Shown instead of the item above while Option is held.
                guard let item = actionItem(id, inSubmenu: inSubmenu) else { continue }
                let primary = menu.items.last
                item.keyEquivalent = primary?.keyEquivalent ?? ""
                item.keyEquivalentModifierMask = (primary?.keyEquivalentModifierMask ?? []).union(.option)
                item.isAlternate = true
                menu.addItem(item)
            case let .submenu(title, symbol, children):
                let submenu = NSMenu()
                add(children, to: submenu, inSubmenu: true)
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                parent.submenu = submenu
                menu.addItem(parent)
            case let .header(title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            }
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
        if let isChecked = action.isChecked {
            item.state = isChecked() ? .on : .off
        }
        return item
    }

    @objc private func itemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        registry.perform(ActionID(rawValue: rawValue))
    }
}
