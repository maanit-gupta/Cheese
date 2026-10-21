import AppKit
import KeyboardShortcuts

/// The menu bar menu. Items that have a global hotkey show its current binding.
@MainActor
final class StatusMenu: NSObject {
    let menu = NSMenu()
    private let perform: (AppAction) -> Void
    private var actions: [AppAction] = []

    init(perform: @escaping (AppAction) -> Void) {
        self.perform = perform
        super.init()

        addItems([.openHistory, .captureRegion, .captureWindow, .captureFullScreen, .ocrRegion, .scrollingCapture])
        menu.addItem(.separator())
        addItems([.clearHistory, .clearAll])
        menu.addItem(.separator())
        addItem(.openSettings, keyEquivalent: ",")
        addItem(.quit, keyEquivalent: "q")
    }

    private func addItems(_ actions: [AppAction]) {
        for action in actions {
            addItem(action)
        }
    }

    private func addItem(_ action: AppAction, keyEquivalent: String = "") {
        let item = NSMenuItem(title: action.title, action: #selector(itemSelected(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.tag = actions.count
        actions.append(action)
        if let hotkey = action.hotkey {
            item.setShortcut(for: hotkey.name)
        }
        menu.addItem(item)
    }

    @objc private func itemSelected(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        perform(actions[sender.tag])
    }
}
