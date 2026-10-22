import KeyboardShortcuts

/// Windows-style snapping of the frontmost app's focused window, and Fill to Screen for one window
/// or all of them, leaving room for Stage Manager.
@MainActor
final class WindowSnappingModule: CheeseModule {
    let id = ModuleID.windowSnapping
    private let snap: (WindowCommand) -> Void
    private let fillAll: () -> (windows: Int, apps: Int)
    private let restoreAll: () -> Int

    init<Controller: WindowControlling>(snapper: WindowSnapper<Controller>) {
        snap = snapper.perform
        fillAll = {
            let result = snapper.fillAll()
            return (result.windows, result.apps)
        }
        restoreAll = snapper.restoreAll
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
        let snapping = entries.map { entry in
            CheeseAction(
                id: entry.id, title: entry.title, symbol: entry.symbol, module: id,
                shortcut: entry.shortcut, requiredPermissions: [.accessibility], featureName: "Window snapping"
            ) { [weak self] _ in
                self?.snap(entry.command)
            }
        }
        return fillActions + snapping
    }

    private var fillActions: [CheeseAction] {
        [
            CheeseAction(
                id: .fillAllWindows, title: "Fill All Windows to Screen", symbol: "rectangle.inset.filled", module: id,
                menuTitle: "Fill All to Screen (Stage Manager)", shortcut: .fillAllWindows,
                requiredPermissions: [.accessibility], featureName: "Fill to Screen"
            ) { [weak self] _ in
                guard let self else { return }
                let result = fillAll()
                CheeseToast.show(
                    StageManagerLayout.summary(windows: result.windows, apps: result.apps),
                    systemImage: result.windows > 0 ? "rectangle.inset.filled" : "info.circle"
                )
            },
            CheeseAction(
                id: .fillCurrentWindow, title: "Fill Current Window to Screen", symbol: "macwindow", module: id,
                menuTitle: "Fill Current Window", shortcut: .fillCurrentWindow,
                requiredPermissions: [.accessibility], featureName: "Fill to Screen"
            ) { [weak self] _ in
                self?.snap(.fillCurrent)
            },
            CheeseAction(
                id: .restoreAllWindows, title: "Restore All Windows", symbol: "arrow.uturn.backward.square", module: id,
                requiredPermissions: [.accessibility], featureName: "Fill to Screen"
            ) { [weak self] _ in
                guard let self else { return }
                let restored = restoreAll()
                if restored == 0 {
                    CheeseToast.show("No filled windows to restore", systemImage: "info.circle")
                } else {
                    CheeseToast.show(restored == 1 ? "Restored 1 window" : "Restored \(restored) windows", systemImage: "arrow.uturn.backward.square")
                }
            },
        ]
    }

    // Snapping only runs on demand, so there's nothing to start or stop.
    func start() {}
    func stop() {}
}
