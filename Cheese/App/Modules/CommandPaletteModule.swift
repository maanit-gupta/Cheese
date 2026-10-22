import KeyboardShortcuts

/// A Spotlight-style search over every available Cheese action.
@MainActor
final class CommandPaletteModule: CheeseModule {
    let id = ModuleID.commandPalette
    private let availableActions: () -> [CheeseAction]
    private let perform: (ActionID, ActionContext) -> Void
    /// Where the palette was opened from: the app pastes and snaps should target.
    private var context = ActionContext()
    private lazy var panel = PalettePanel { [weak self] id in
        guard let self else { return }
        perform(id, context)
    }

    /// - Parameters:
    ///   - availableActions: the registry's actions that can run right now.
    ///   - perform: runs an action through the registry with the given context.
    init(availableActions: @escaping () -> [CheeseAction], perform: @escaping (ActionID, ActionContext) -> Void) {
        self.availableActions = availableActions
        self.perform = perform
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(id: .commandPalette, title: "Command Palette", symbol: "command", module: id, shortcut: .commandPalette) { [weak self] context in
                self?.toggle(context: context)
            },
        ]
    }

    func start() {}

    func stop() {
        panel.close()
    }

    private func toggle(context: ActionContext) {
        if panel.isShown {
            panel.close()
            return
        }
        self.context = context
        panel.show(entries: Self.entries(from: availableActions()))
    }

    /// Every action but the palette itself, with its module name and current hotkey.
    static func entries(from actions: [CheeseAction]) -> [PaletteEntry] {
        actions.filter { $0.id != .commandPalette }.map { action in
            PaletteEntry(
                id: action.id,
                title: action.title,
                symbol: action.symbol,
                moduleName: action.module?.title ?? "Cheese",
                shortcut: action.shortcut.flatMap { KeyboardShortcuts.getShortcut(for: $0) }?.description
            )
        }
    }
}
