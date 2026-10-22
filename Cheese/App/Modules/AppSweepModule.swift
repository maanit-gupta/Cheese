/// Auto-Kill: quit every open app at once from a panel, a hotkey or the palette, with a safe list.
@MainActor
final class AppSweepModule: CheeseModule {
    let id = ModuleID.appSweep
    private let controller = AppSweepController()

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .autoKillPanel, title: "Auto-Kill Apps…", symbol: "xmark.app", module: id,
                paletteTitle: "Control: Auto-Kill Open Apps…", shortcut: .autoKill
            ) { [weak self] context in
                self?.controller.showPanel(activeApp: context.previousApp)
            },
            CheeseAction(
                id: .killAllApps, title: "Kill All Open Apps Now", symbol: "xmark.circle", module: id,
                paletteTitle: "Control: Kill All Open Apps Now", shortcut: .killAllApps
            ) { [weak self] context in
                self?.controller.sweepNow(scope: .all, force: false, activeApp: context.previousApp)
            },
            CheeseAction(
                id: .killBackgroundApps, title: "Kill Background Apps (Keep Frontmost)", symbol: "rectangle.stack.badge.minus", module: id,
                paletteTitle: "Control: Kill Background Apps (Keep Frontmost)"
            ) { [weak self] context in
                self?.controller.sweepNow(scope: .keepFrontmost, force: false, activeApp: context.previousApp)
            },
            CheeseAction(
                id: .forceKillAllApps, title: "Force Kill All Open Apps", symbol: "bolt.circle", module: id,
                paletteTitle: "Control: Force Kill All Open Apps"
            ) { [weak self] context in
                self?.controller.sweepNow(scope: .all, force: true, activeApp: context.previousApp)
            },
        ]
    }

    // Nothing runs until the user sweeps.
    func start() {}

    func stop() {
        controller.closePanel()
    }
}
