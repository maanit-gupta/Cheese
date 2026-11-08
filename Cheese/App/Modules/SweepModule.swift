/// Sweep: locks the keyboard and trackpad for a moment so the screen and keyboard can be wiped.
/// Reached from Tools ▸ Mode ▸ Sweep and the palette, never from a hotkey.
@MainActor
final class SweepModule: CheeseModule {
    let id = ModuleID.sweep
    private let controller: SweepController

    init(controller: SweepController) {
        self.controller = controller
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .sweep, title: "Sweep", symbol: "bubbles.and.sparkles", module: id,
                paletteTitle: "Control: Sweep (Clean Screen)",
                requiredPermissions: [.accessibility],
                precondition: { [controller] in !controller.isActive }
            ) { [controller] _ in
                controller.start(duration: Preferences().sweepDuration.seconds)
            },
        ]
    }

    // Nothing runs until the user starts a Sweep.
    func start() {}

    func stop() {
        controller.stop()
    }
}
