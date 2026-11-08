/// Hush: holds notifications back while the screen is shared, and on demand for a while, from
/// its own menu bar icon.
@MainActor
final class HushModule: CheeseModule {
    let id = ModuleID.hush
    let controller: HushController
    private let statusItem: HushStatusItem?
    private let openSettings: @MainActor () -> Void
    private let picker = TimePickerWindow(heading: "Hush notifications until", title: "Hush")

    init(controller: HushController, statusItem: HushStatusItem?, openSettings: @escaping @MainActor () -> Void = {}) {
        self.controller = controller
        self.statusItem = statusItem
        self.openSettings = openSettings
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .hushStatus, title: "Hush", symbol: "bell", module: id,
                liveTitle: { [controller] in controller.statusText },
                showsInPalette: false
            ) { [openSettings] _ in
                openSettings()
            },
            CheeseAction(
                id: .hushAutomatically, title: "Hush: Automatically While Sharing", symbol: "rectangle.on.rectangle", module: id,
                menuTitle: "Hush Automatically While Sharing",
                isChecked: { [controller] in controller.automatic }
            ) { [controller] _ in
                controller.setAutomatic(!controller.automatic)
            },
        ] + CaffeinatePreset.allCases.map { preset in
            CheeseAction(
                id: .hush(preset), title: "Hush: \(preset.title)", symbol: "timer", module: id,
                menuTitle: preset.title,
                isChecked: { [controller] in controller.manual?.duration == .preset(preset) }
            ) { [controller] _ in
                controller.hush(.preset(preset))
            }
        } + [
            CheeseAction(
                id: .hushUntil, title: "Hush: Until…", symbol: "clock", module: id,
                menuTitle: "Until…",
                isChecked: { [controller] in
                    if case .until = controller.manual?.duration { return true }
                    return false
                }
            ) { [controller, picker] _ in
                picker.show { hour, minute in
                    controller.hush(.until(CaffeinateSchedule.targetDate(hour: hour, minute: minute, after: .now)))
                }
            },
            CheeseAction(
                id: .hushIndefinitely, title: "Hush: Indefinitely", symbol: "bell.slash", module: id,
                menuTitle: "Indefinitely", shortcut: .hush,
                isChecked: { [controller] in controller.manual?.duration == .indefinitely }
            ) { [controller] _ in
                // The hotkey toggles: a second press brings notifications back.
                if controller.manual?.duration == .indefinitely {
                    controller.turnOff()
                } else {
                    controller.hush(.indefinitely)
                }
            },
            CheeseAction(
                id: .hushOff, title: "Hush: Turn Off", symbol: "bell", module: id,
                menuTitle: "Turn Off",
                precondition: { [controller] in controller.reason != nil || controller.isEngaged }
            ) { [controller] _ in
                controller.turnOff()
            },
            CheeseAction(
                id: .hushSettings, title: "Hush Settings…", symbol: "gearshape", module: id,
                showsInPalette: false
            ) { [openSettings] _ in
                openSettings()
            },
        ]
    }

    func start() {
        controller.start()
        statusItem?.show()
    }

    func stop() {
        picker.close()
        controller.stop()
        statusItem?.hide()
    }
}
