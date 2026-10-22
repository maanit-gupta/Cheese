import Foundation
import KeyboardShortcuts

/// User-assigned `Ctrl+Opt+Cmd+<key>` hotkeys that open apps. These aren't actions (the palette
/// doesn't launch apps), so the module registers its own hotkeys, one per bound app.
@MainActor
final class AppHotkeysModule: CheeseModule {
    let id = ModuleID.appHotkeys
    let store: AppHotkeyStore
    let index: InstalledAppIndex
    private var listeners: [String: Task<Void, Never>] = [:]
    private var defaultsObserver: Task<Void, Never>?

    init(store: AppHotkeyStore, index: InstalledAppIndex) {
        self.store = store
        self.index = index
    }

    var actions: [CheeseAction] { [] }

    func start() {
        syncListeners()
        // Bindings and their keys are edited in Settings; pick changes up right away.
        defaultsObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.syncListeners()
            }
        }
        // Warm the app list so the Settings search opens instantly.
        Task { [index] in _ = await index.apps() }
    }

    func stop() {
        defaultsObserver?.cancel()
        defaultsObserver = nil
        for task in listeners.values {
            task.cancel()
        }
        listeners.removeAll()
    }

    /// One listener per bound app with a key. Ending a listener's stream unregisters its hotkey.
    private func syncListeners() {
        store.reload()
        let active = Dictionary(uniqueKeysWithValues: store.activeBindings.map { ($0.bundleID, $0) })
        for (bundleID, task) in listeners where active[bundleID] == nil {
            task.cancel()
            listeners[bundleID] = nil
        }
        for (bundleID, binding) in active where listeners[bundleID] == nil {
            listeners[bundleID] = Task {
                for await _ in KeyboardShortcuts.events(.keyDown, for: binding.shortcutName) {
                    AppLauncher.launchOrActivate(binding)
                }
            }
        }
    }
}
