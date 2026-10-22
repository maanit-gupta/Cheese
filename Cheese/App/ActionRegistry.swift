import KeyboardShortcuts
import os

/// The one list of everything Cheese can do. The menu bar menu, global hotkeys and the command
/// palette all read from here, so an action's title, symbol, shortcut and permissions live in one place.
@MainActor
final class ActionRegistry {
    let moduleManager: ModuleManager
    /// Every action in definition order: app-level actions first, then each module's.
    let actions: [CheeseAction]
    private let permissions: any PermissionChecking
    private let onMissingPermission: (Permission, _ feature: String) -> Void
    private var hotkeyTasks: [KeyboardShortcuts.Name: Task<Void, Never>] = [:]
    /// Called just before an action runs, from the menu, a hotkey or the palette, so whatever
    /// Cheese UI is open can make way for it.
    var willPerform: (CheeseAction) -> Void = { _ in }

    init(
        appActions: [CheeseAction],
        moduleManager: ModuleManager,
        permissions: any PermissionChecking,
        onMissingPermission: @escaping (Permission, _ feature: String) -> Void
    ) {
        self.moduleManager = moduleManager
        self.permissions = permissions
        self.onMissingPermission = onMissingPermission
        actions = appActions + moduleManager.modules.flatMap(\.actions)
    }

    func action(_ id: ActionID) -> CheeseAction? {
        actions.first { $0.id == id }
    }

    /// False when the action's module is off or its precondition fails.
    func isAvailable(_ action: CheeseAction) -> Bool {
        isModuleRunning(for: action) && action.precondition()
    }

    func isAvailable(_ id: ActionID) -> Bool {
        action(id).map(isAvailable) ?? false
    }

    var availableActions: [CheeseAction] {
        actions.filter(isAvailable)
    }

    /// Runs the action, or explains which permission it's missing. Unavailable actions do nothing.
    func perform(_ id: ActionID, context: ActionContext = .current()) {
        guard let action = action(id), isAvailable(action) else {
            Logger.app.info("Ignored unavailable action \(id.rawValue, privacy: .public)")
            return
        }
        if let missing = permissions.missing(from: action.requiredPermissions).first {
            onMissingPermission(missing, action.alertName)
            return
        }
        willPerform(action)
        action.perform(context)
    }

    /// Every shortcut that should be live, hidden variants included: those of app-level
    /// actions and of running modules. A disabled module registers none.
    var hotkeyBindings: [KeyboardShortcuts.Name: ActionID] {
        var bindings: [KeyboardShortcuts.Name: ActionID] = [:]
        for action in actions where isModuleRunning(for: action) {
            for name in [action.shortcut].compactMap(\.self) + action.hiddenShortcuts {
                bindings[name] = action.id
            }
        }
        return bindings
    }

    /// Every shortcut name an action owns, whether or not its module is running.
    var shortcutNames: [KeyboardShortcuts.Name] {
        actions.flatMap { [$0.shortcut].compactMap(\.self) + $0.hiddenShortcuts }
    }

    /// Starts and stops modules to match Settings, then registers exactly the hotkeys they own.
    /// Returns whether any module started or stopped.
    @discardableResult
    func refresh() -> Bool {
        let changed = moduleManager.sync()
        syncHotkeys()
        return changed
    }

    func stopAll() {
        for task in hotkeyTasks.values {
            task.cancel()
        }
        hotkeyTasks.removeAll()
        moduleManager.stopAll()
    }

    private func isModuleRunning(for action: CheeseAction) -> Bool {
        action.module.map(moduleManager.isRunning) ?? true
    }

    /// Ending a listener's stream unregisters its hotkey, so cancelling the task is enough.
    private func syncHotkeys() {
        let bindings = hotkeyBindings
        for (name, task) in hotkeyTasks where bindings[name] == nil {
            task.cancel()
            hotkeyTasks[name] = nil
        }
        for (name, id) in bindings where hotkeyTasks[name] == nil {
            hotkeyTasks[name] = Task { [weak self] in
                for await event in KeyboardShortcuts.events(for: name) {
                    self?.handleHotkey(event, for: id)
                }
            }
        }
    }

    /// Presses run the action; releases only matter to actions that handle the hotkey themselves.
    func handleHotkey(_ event: KeyboardShortcuts.EventType, for id: ActionID) {
        guard let action = action(id) else { return }
        guard let handler = action.hotkeyHandler else {
            if event == .keyDown {
                perform(id)
            }
            return
        }
        guard isAvailable(action) else { return }
        if event == .keyDown, let missing = permissions.missing(from: action.requiredPermissions).first {
            onMissingPermission(missing, action.alertName)
            return
        }
        if event == .keyDown {
            willPerform(action)
        }
        handler(event)
    }
}
