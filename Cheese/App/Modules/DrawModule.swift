import Foundation

/// Draw on screen: annotate over everything, then snapshot it.
@MainActor
final class DrawModule: CheeseModule {
    let id = ModuleID.drawOnScreen
    private let controller: DrawModeController

    init(services: DrawModeController.Services) {
        controller = DrawModeController(services: services)
    }

    /// Whether draw mode is on right now.
    var isDrawing: Bool { controller.isActive }

    var actions: [CheeseAction] {
        [
            // Tap the hotkey to toggle; hold it to ink until it's released. The menu item toggles.
            CheeseAction(
                id: .drawOnScreen, title: "Draw on Screen", symbol: "pencil.and.scribble", module: id, shortcut: .drawOnScreen,
                showsInPalette: false,
                hotkeyHandler: { [weak self] event in
                    let now = ProcessInfo.processInfo.systemUptime
                    switch event {
                    case .keyDown: self?.controller.hotkeyPressed(at: now)
                    case .keyUp: self?.controller.hotkeyReleased(at: now)
                    }
                }
            ) { [weak self] _ in
                self?.controller.toggle()
            },
        ]
    }

    // Nothing runs until draw mode is turned on.
    func start() {}

    /// Leaves draw mode and drops the drawings.
    func stop() {
        controller.reset()
    }
}
