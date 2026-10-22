import Foundation

/// Keep the Mac awake, indefinitely or until a chosen time, with a countdown in the menu bar.
@MainActor
final class KeepAwakeModule: CheeseModule {
    let id = ModuleID.keepAwake
    private let controller = KeepAwakeController()
    private let picker = TimePickerWindow()

    /// Shows or clears the menu bar countdown.
    init(setIndicator: @escaping (String?) -> Void) {
        controller.onIndicatorChange = setIndicator
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .keepAwakeIndefinitely, title: "Keep Awake: Indefinitely", symbol: "cup.and.saucer", module: id,
                menuTitle: "Indefinitely"
            ) { [weak self] _ in
                self?.controller.keepAwakeIndefinitely()
            },
            CheeseAction(
                id: .keepAwakeUntil, title: "Keep Awake: Until…", symbol: "clock", module: id,
                menuTitle: "Until…"
            ) { [weak self] _ in
                self?.picker.show { hour, minute in
                    self?.controller.keepAwake(until: KeepAwakeSchedule.targetDate(hour: hour, minute: minute, after: .now))
                }
            },
            CheeseAction(
                id: .keepAwakeOff, title: "Keep Awake: Turn Off", symbol: "moon.zzz", module: id,
                menuTitle: "Turn Off",
                precondition: { [weak self] in self?.controller.isActive ?? false }
            ) { [weak self] _ in
                self?.controller.turnOff()
            },
        ]
    }

    // Nothing runs until the user asks for it.
    func start() {}

    func stop() {
        picker.close()
        controller.turnOff()
    }
}
