/// A feature area that can be switched on and off while Cheese runs.
/// `stop()` must leave nothing running: no monitors, timers, listeners or open panels.
/// Action hotkeys are registered by `ActionRegistry`; a module registers only hotkeys that aren't
/// actions, like the user's app hotkeys.
@MainActor
protocol CheeseModule: AnyObject {
    var id: ModuleID { get }
    /// Every action the module offers. Listed whether or not the module is running.
    var actions: [CheeseAction] { get }
    func start()
    func stop()
}
