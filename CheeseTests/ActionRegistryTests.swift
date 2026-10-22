import AppKit
import KeyboardShortcuts
import Testing
@testable import Cheese

private struct FakePermissions: PermissionChecking {
    var granted: Set<Permission> = Set(Permission.allCases)

    func isGranted(_ permission: Permission) -> Bool {
        granted.contains(permission)
    }
}

/// Records what the manager and registry do to it. Offers one action, bound to `shortcut`.
@MainActor
private final class FakeModule: CheeseModule {
    let id: ModuleID
    var shortcut: KeyboardShortcuts.Name?
    var requiredPermissions: [Permission] = []
    var precondition = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var performed: [ActionContext] = []

    init(_ id: ModuleID, shortcut: KeyboardShortcuts.Name? = nil) {
        self.id = id
        self.shortcut = shortcut
    }

    static func actionID(for module: ModuleID) -> ActionID {
        ActionID(rawValue: "fake-\(module.rawValue)")
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: Self.actionID(for: id), title: id.title, symbol: "star", module: id,
                shortcut: shortcut, requiredPermissions: requiredPermissions,
                precondition: { [weak self] in self?.precondition ?? false }
            ) { [weak self] context in
                self?.performed.append(context)
            },
        ]
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

// MARK: - The v1 actions

@MainActor
struct ActionCatalogueTests {
    private let modules: [any CheeseModule]

    init() {
        let capture = CaptureController(capturer: CaptureService())
        let editor = AnnotationEditor()
        modules = [
            ClipboardModule(permissions: FakePermissions(), permissionPrompter: PermissionPrompter()) { nil },
            ScreenshotsModule(capture: capture, editor: editor),
            OCRModule(capture: capture),
            ScrollCaptureModule(capture: capture, previewActions: ScrollPreviewWindow.Actions(annotate: { _ in }, recognizeText: { _ in })),
            WindowSnappingModule(snapper: WindowSnapper(controller: WindowManager())),
        ]
    }

    private var actions: [CheeseAction] { modules.flatMap(\.actions) }

    private func action(_ id: ActionID) -> CheeseAction? {
        actions.first { $0.id == id }
    }

    @Test func everyModuleExistsOnce() {
        #expect(modules.map(\.id) == ModuleID.allCases)
    }

    @Test func idsAreUnique() {
        let ids = actions.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func actionsBelongToTheirModule() {
        for module in modules {
            #expect(module.actions.allSatisfy { $0.module == module.id }, "\(module.id)")
        }
    }

    @Test func everyHotkeyRunsExactlyOneAction() {
        let shortcuts = actions.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(Set(shortcuts) == Set(Hotkey.allCases.map(\.name)))
    }

    @Test func shiftFullScreenVariantRunsFullScreenCapture() {
        #expect(action(.captureFullScreen)?.hiddenShortcuts == [.captureFullScreenEditor])
        let others = actions.filter { $0.id != .captureFullScreen }
        #expect(others.allSatisfy { $0.hiddenShortcuts.isEmpty })
    }

    @Test(arguments: [ActionID.captureRegion, .captureFullScreen, .captureWindow, .ocrRegion])
    func captureNeedsScreenRecording(_ id: ActionID) {
        #expect(action(id)?.requiredPermissions == [.screenRecording])
    }

    @Test(arguments: [ActionID.snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow])
    func snappingNeedsAccessibilityAndAlertsNameTheFeature(_ id: ActionID) {
        #expect(action(id)?.requiredPermissions == [.accessibility])
        #expect(action(id)?.alertName == "Window snapping")
    }

    @Test func ocrAlertNamesTheFeature() {
        #expect(action(.ocrRegion)?.alertName == "Copying text from the screen")
    }

    @Test func scrollingCaptureNeedsBoth() {
        #expect(action(.scrollingCapture)?.requiredPermissions == [.screenRecording, .accessibility])
    }

    @Test(arguments: [ActionID.openHistory, .clearHistory, .clearAll])
    func clipboardActionsNeedNothing(_ id: ActionID) {
        // Without Accessibility, history still opens and pasting falls back to copy-only.
        #expect(action(id)?.requiredPermissions == [])
    }

    @Test func clearingHasNoHotkey() {
        #expect(action(.clearHistory)?.shortcut == nil)
        #expect(action(.clearAll)?.shortcut == nil)
    }

    @Test func everyModuleActionIsInTheMenu() {
        var inMenu: Set<ActionID> = []
        for entry in StatusMenu.layout.flatMap(\.entries) {
            switch entry {
            case let .action(id, _): inMenu.insert(id)
            case let .submenu(_, _, actions): inMenu.formUnion(actions)
            }
        }
        #expect(Set(actions.map(\.id)).isSubset(of: inMenu))
    }
}

// MARK: - Registry

@MainActor
struct ActionRegistryTests {
    private func makeRegistry(
        _ modules: [FakeModule],
        enabled: Set<ModuleID>,
        permissions: FakePermissions = FakePermissions(),
        appActions: [CheeseAction] = [],
        onMissing: @escaping (Permission, String) -> Void = { _, _ in }
    ) -> ActionRegistry {
        let manager = ModuleManager(modules: modules) { enabled.contains($0) }
        let registry = ActionRegistry(appActions: appActions, moduleManager: manager, permissions: permissions, onMissingPermission: onMissing)
        manager.sync()
        return registry
    }

    @Test func disabledModuleActionsAreUnavailableAndDoNothing() {
        let clipboard = FakeModule(.clipboard)
        let ocr = FakeModule(.ocr)
        let registry = makeRegistry([clipboard, ocr], enabled: [.ocr])

        #expect(!registry.isAvailable(FakeModule.actionID(for: .clipboard)))
        #expect(registry.isAvailable(FakeModule.actionID(for: .ocr)))
        #expect(registry.availableActions.map(\.id) == [FakeModule.actionID(for: .ocr)])

        registry.perform(FakeModule.actionID(for: .clipboard), context: ActionContext())
        #expect(clipboard.performed.isEmpty)
    }

    @Test func appActionsAreAlwaysAvailable() {
        var ran = false
        let quit = CheeseAction(id: .quit, title: "Quit", symbol: "power", module: nil) { _ in ran = true }
        let registry = makeRegistry([FakeModule(.clipboard)], enabled: [], appActions: [quit])

        #expect(registry.availableActions.map(\.id) == [.quit])
        registry.perform(.quit, context: ActionContext())
        #expect(ran)
    }

    @Test func failedPreconditionMakesActionUnavailable() {
        let module = FakeModule(.screenshots)
        module.precondition = false
        let registry = makeRegistry([module], enabled: [.screenshots])

        #expect(!registry.isAvailable(FakeModule.actionID(for: .screenshots)))
        registry.perform(FakeModule.actionID(for: .screenshots), context: ActionContext())
        #expect(module.performed.isEmpty)
    }

    @Test func missingPermissionIsExplainedInsteadOfRunning() {
        let module = FakeModule(.windowSnapping)
        module.requiredPermissions = [.screenRecording, .accessibility]
        var explained: [(Permission, String)] = []
        let registry = makeRegistry(
            [module], enabled: [.windowSnapping],
            permissions: FakePermissions(granted: [.screenRecording])
        ) { explained.append(($0, $1)) }

        registry.perform(FakeModule.actionID(for: .windowSnapping), context: ActionContext())
        #expect(module.performed.isEmpty)
        #expect(explained.count == 1)
        #expect(explained.first?.0 == .accessibility)
        #expect(explained.first?.1 == ModuleID.windowSnapping.title)
    }

    @Test func grantedActionRunsWithContext() {
        let module = FakeModule(.windowSnapping)
        module.requiredPermissions = [.accessibility]
        let registry = makeRegistry([module], enabled: [.windowSnapping])
        let app = NSRunningApplication.current

        registry.perform(FakeModule.actionID(for: .windowSnapping), context: ActionContext(previousApp: app))
        #expect(module.performed.count == 1)
        #expect(module.performed.first?.previousApp == app)
    }

    @Test func disabledModulesBindNoHotkeys() {
        let clipboard = FakeModule(.clipboard, shortcut: .openHistory)
        let snapping = FakeModule(.windowSnapping, shortcut: .snapLeft)
        let registry = makeRegistry([clipboard, snapping], enabled: [.windowSnapping])

        #expect(registry.hotkeyBindings == [.snapLeft: FakeModule.actionID(for: .windowSnapping)])
    }
}

// MARK: - Module manager

@MainActor
struct ModuleManagerTests {
    @Test func syncStartsEnabledAndStopsDisabledModules() {
        var enabled: Set<ModuleID> = [.clipboard]
        let clipboard = FakeModule(.clipboard)
        let ocr = FakeModule(.ocr)
        let manager = ModuleManager(modules: [clipboard, ocr]) { enabled.contains($0) }

        #expect(manager.sync())
        #expect(manager.running == [.clipboard])
        #expect(clipboard.startCount == 1 && ocr.startCount == 0)

        // Nothing changed: no restarts.
        #expect(!manager.sync())
        #expect(clipboard.startCount == 1)

        enabled = [.ocr]
        #expect(manager.sync())
        #expect(manager.running == [.ocr])
        #expect(clipboard.stopCount == 1 && ocr.startCount == 1)

        enabled = [.ocr, .clipboard]
        manager.sync()
        #expect(clipboard.startCount == 2)
    }

    @Test func stopAllStopsOnlyRunningModules() {
        let clipboard = FakeModule(.clipboard)
        let ocr = FakeModule(.ocr)
        let manager = ModuleManager(modules: [clipboard, ocr]) { $0 == .clipboard }
        manager.sync()

        manager.stopAll()
        #expect(manager.running.isEmpty)
        #expect(clipboard.stopCount == 1 && ocr.stopCount == 0)
    }
}

// MARK: - Menu

@MainActor
struct StatusMenuLayoutTests {
    private func ids(in sections: [StatusMenu.Section]) -> [ActionID] {
        sections.flatMap(\.entries).flatMap { entry -> [ActionID] in
            switch entry {
            case let .action(id, _): [id]
            case let .submenu(_, _, actions): actions
            }
        }
    }

    @Test func everythingAvailableShowsTheWholeLayout() {
        #expect(StatusMenu.visibleSections(of: StatusMenu.layout) { _ in true } == StatusMenu.layout)
    }

    @Test func emptySectionsLoseTheirHeaders() {
        let hidden: Set<ActionID> = [.captureRegion, .captureWindow, .captureFullScreen, .scrollingCapture]
        let sections = StatusMenu.visibleSections(of: StatusMenu.layout) { !hidden.contains($0) }
        #expect(!sections.contains { $0.header == "Capture" })
        #expect(sections.contains { $0.header == "Text" })
        #expect(sections.count == StatusMenu.layout.count - 1)
    }

    @Test func submenusKeepOnlyAvailableActionsAndVanishWhenEmpty() {
        let partial = StatusMenu.visibleSections(of: StatusMenu.layout) { $0 != .maximize }
        #expect(ids(in: partial).contains(.snapLeft))
        #expect(!ids(in: partial).contains(.maximize))

        let snapping: Set<ActionID> = [.snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow]
        let none = StatusMenu.visibleSections(of: StatusMenu.layout) { !snapping.contains($0) }
        #expect(!none.contains { $0.header == "Windows" })
    }

    @Test func nothingAvailableShowsNothing() {
        #expect(StatusMenu.visibleSections(of: StatusMenu.layout) { _ in false }.isEmpty)
    }
}
