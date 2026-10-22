/// Draw on screen: annotate over everything, then snapshot it.
@MainActor
final class DrawModule: CheeseModule {
    let id = ModuleID.drawOnScreen
    private let controller: DrawModeController

    init(services: DrawModeController.Services) {
        controller = DrawModeController(services: services)
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .drawOnScreen, title: "Draw on Screen", symbol: "pencil.and.scribble", module: id, shortcut: .drawOnScreen
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
