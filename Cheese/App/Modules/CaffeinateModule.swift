import Foundation

/// Caffeinate: keep the Mac awake for a set time, until a chosen time or indefinitely, with the
/// lid open or (through a one-time root helper) closed, with a countdown in the menu bar.
@MainActor
final class CaffeinateModule: CheeseModule {
    let id = ModuleID.keepAwake
    let controller: CaffeinateController
    private let picker = TimePickerWindow()

    init(controller: CaffeinateController) {
        self.controller = controller
    }

    var actions: [CheeseAction] {
        CaffeinatePreset.allCases.map { preset in
            CheeseAction(
                id: .caffeinate(preset), title: "Caffeinate: \(preset.title)", symbol: "timer", module: id,
                menuTitle: preset.title,
                isChecked: { [weak self] in self?.controller.session?.duration == .preset(preset) }
            ) { [weak self] _ in
                self?.controller.start(.preset(preset))
            }
        } + [
            CheeseAction(
                id: .caffeinateUntil, title: "Caffeinate: Until…", symbol: "clock", module: id,
                menuTitle: "Until…",
                isChecked: { [weak self] in
                    if case .until = self?.controller.session?.duration { return true }
                    return false
                }
            ) { [weak self] _ in
                self?.picker.show { hour, minute in
                    self?.controller.start(.until(CaffeinateSchedule.targetDate(hour: hour, minute: minute, after: .now)))
                }
            },
            CheeseAction(
                id: .caffeinateIndefinitely, title: "Caffeinate: Indefinitely", symbol: "cup.and.saucer", module: id,
                menuTitle: "Indefinitely",
                isChecked: { [weak self] in self?.controller.session?.duration == .indefinitely }
            ) { [weak self] _ in
                self?.controller.start(.indefinitely)
            },
            CheeseAction(
                id: .caffeinateLidClosed, title: "Caffeinate: Keep Awake With Lid Closed", symbol: "laptopcomputer",
                module: id, menuTitle: "Keep Awake With Lid Closed",
                isChecked: { [weak self] in self?.controller.wantsLid ?? false }
            ) { [weak self] _ in
                guard let self else { return }
                controller.setCoversLid(!controller.wantsLid)
            },
            CheeseAction(
                id: .caffeinateOff, title: "Caffeinate: Turn Off", symbol: "moon.zzz", module: id,
                menuTitle: "Turn Off",
                precondition: { [weak self] in self?.controller.isActive ?? false }
            ) { [weak self] _ in
                self?.controller.turnOff()
            },
        ]
    }

    // Nothing runs until the user asks, apart from undoing what an older Cheese left behind.
    func start() {
        controller.refreshHelperStatus()
        LegacyLidAwake.recoverIfNeeded()
    }

    /// Also runs on quit; the helper puts lid-close sleep back once the request is gone.
    func stop() {
        picker.close()
        controller.stop()
    }
}
