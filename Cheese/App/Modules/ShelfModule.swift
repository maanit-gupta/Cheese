import AppKit

/// The floating drop shelf: park files, images, text and links, then drag them out together.
@MainActor
final class ShelfModule: CheeseModule {
    let id = ModuleID.shelf
    private let services: ShelfServices
    /// Loaded when the module starts, so a disabled shelf never touches the disk.
    private var controller: ShelfPanelController?
    private(set) var isRunning = false

    init(services: ShelfServices) {
        self.services = services
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .toggleShelf, title: "Shelf", symbol: "tray", module: id,
                paletteTitle: "Show Shelf", shortcut: .toggleShelf
            ) { [weak self] _ in
                self?.controller?.toggle()
            },
            CheeseAction(
                id: .clearShelf, title: "Clear Shelf", symbol: "tray.full", module: id,
                precondition: { [weak self] in !(self?.controller?.store.isEmpty ?? true) }
            ) { [weak self] _ in
                self?.controller?.clear()
            },
        ]
    }

    func start() {
        controller = controller ?? ShelfPanelController(store: ShelfStore(), services: services)
        isRunning = true
    }

    func stop() {
        isRunning = false
        controller?.hide()
    }

    /// "Add to Shelf" from the menu bar drop menu.
    func add(files: [URL]) {
        guard isRunning else { return }
        controller?.add(files.map(ShelfInput.file))
    }
}
