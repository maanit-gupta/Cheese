import os

/// Starts and stops modules to match their Settings toggles. Changes apply immediately, no relaunch.
@MainActor
final class ModuleManager {
    let modules: [any CheeseModule]
    private let isEnabled: (ModuleID) -> Bool
    private(set) var running: Set<ModuleID> = []

    init(modules: [any CheeseModule], isEnabled: @escaping (ModuleID) -> Bool) {
        self.modules = modules
        self.isEnabled = isEnabled
    }

    func isRunning(_ module: ModuleID) -> Bool {
        running.contains(module)
    }

    /// Starts enabled modules that aren't running and stops disabled ones that are.
    /// Returns whether anything changed.
    @discardableResult
    func sync() -> Bool {
        var changed = false
        for module in modules {
            let shouldRun = isEnabled(module.id)
            guard shouldRun != running.contains(module.id) else { continue }
            if shouldRun {
                module.start()
                running.insert(module.id)
                Logger.app.info("Started module \(module.id.rawValue, privacy: .public)")
            } else {
                module.stop()
                running.remove(module.id)
                Logger.app.info("Stopped module \(module.id.rawValue, privacy: .public)")
            }
            changed = true
        }
        return changed
    }

    func stopAll() {
        for module in modules where running.contains(module.id) {
            module.stop()
        }
        running.removeAll()
    }
}
