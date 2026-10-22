import KeyboardShortcuts

/// Windows-style snapping of the frontmost app's focused window.
@MainActor
final class WindowSnappingModule: CheeseModule {
    let id = ModuleID.windowSnapping
    private let snap: (WindowCommand) -> Void

    init<Controller: WindowControlling>(snapper: WindowSnapper<Controller>) {
        snap = snapper.perform
    }

    var actions: [CheeseAction] {
        typealias Entry = (id: ActionID, title: String, symbol: String, shortcut: KeyboardShortcuts.Name, command: WindowCommand)
        let entries: [Entry] = [
            (.snapLeft, "Left Half", "rectangle.lefthalf.filled", .snapLeft, .snap(.leftHalf)),
            (.snapRight, "Right Half", "rectangle.righthalf.filled", .snapRight, .snap(.rightHalf)),
            (.maximize, "Maximize", "rectangle.fill", .maximize, .snap(.maximize)),
            (.snapBottom, "Bottom Half", "rectangle.bottomhalf.filled", .snapBottom, .snap(.bottomHalf)),
            (.restoreWindow, "Restore Previous Size", "arrow.uturn.backward", .restoreWindow, .restore),
        ]
        return entries.map { entry in
            CheeseAction(
                id: entry.id, title: entry.title, symbol: entry.symbol, module: id,
                shortcut: entry.shortcut, requiredPermissions: [.accessibility], featureName: "Window snapping"
            ) { [weak self] _ in
                self?.snap(entry.command)
            }
        }
    }

    // Snapping only runs on demand, so there's nothing to start or stop.
    func start() {}
    func stop() {}
}
