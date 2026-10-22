import AppKit
import KeyboardShortcuts

/// The menu bar menu: every feature, so nothing needs a hotkey. Items that have a global
/// hotkey show its current binding, and update when it's rebound.
@MainActor
final class StatusMenu: NSObject {
    let menu = NSMenu()
    private let perform: (AppAction) -> Void
    private var actions: [AppAction] = []

    init(perform: @escaping (AppAction) -> Void) {
        self.perform = perform
        super.init()

        menu.addItem(item(.openHistory))
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Capture"))
        for action: AppAction in [.captureRegion, .captureWindow, .captureFullScreen, .scrollingCapture] {
            menu.addItem(item(action))
        }
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Text"))
        menu.addItem(item(.ocrRegion))
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Windows"))
        menu.addItem(windowSubmenu())
        menu.addItem(.separator())

        menu.addItem(item(.clearHistory))
        menu.addItem(item(.clearAll))
        menu.addItem(.separator())

        menu.addItem(item(.editShortcuts))
        menu.addItem(item(.openSettings, keyEquivalent: ","))
        menu.addItem(item(.showWelcome))
        menu.addItem(.separator())
        menu.addItem(item(.quit, keyEquivalent: "q"))
    }

    /// Snapping acts on the frontmost app's window. Opening this menu doesn't activate Cheese,
    /// so that's still the window the user was working in.
    private func windowSubmenu() -> NSMenuItem {
        let submenu = NSMenu()
        for action: AppAction in [.snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow] {
            submenu.addItem(item(action))
        }
        let parent = NSMenuItem(title: "Arrange Window", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        parent.submenu = submenu
        return parent
    }

    private func item(_ action: AppAction, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(itemSelected(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.tag = actions.count
        actions.append(action)
        if let symbol = Self.symbol(for: action) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let hotkey = action.hotkey {
            item.setShortcut(for: hotkey.name)
        }
        return item
    }

    private static func symbol(for action: AppAction) -> String? {
        switch action {
        case .openHistory: "doc.on.clipboard"
        case .captureRegion: "crop"
        case .captureWindow: "macwindow"
        case .captureFullScreen: "display"
        case .scrollingCapture: "rectangle.expand.vertical"
        case .ocrRegion: "text.viewfinder"
        case .snapLeft: "rectangle.lefthalf.filled"
        case .snapRight: "rectangle.righthalf.filled"
        case .maximize: "rectangle.fill"
        case .snapBottom: "rectangle.bottomhalf.filled"
        case .restoreWindow: "arrow.uturn.backward"
        case .clearHistory: "clear"
        case .clearAll: "trash"
        case .editShortcuts: "keyboard"
        case .openSettings: "gearshape"
        case .showWelcome: "hand.wave"
        case .quit: "power"
        }
    }

    @objc private func itemSelected(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        perform(actions[sender.tag])
    }
}
