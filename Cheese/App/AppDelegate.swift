import AppKit
import os

/// Composition root: builds the modules, the action registry over them, and the windows they share.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissions: any PermissionChecking = SystemPermissions()
    private let permissionPrompter = PermissionPrompter()
    private var registry: ActionRegistry?
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var clipboard: ClipboardModule?
    private var defaultsObserver: Task<Void, Never>?

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted in the app; don't add a status item or grab hotkeys there.
        guard !Self.isRunningUnitTests else { return }

        MainMenu.install()
        let openPermissionSettings: @MainActor (Permission) -> Void = { [permissionPrompter] permission in
            permissionPrompter.openSystemSettings(for: permission)
        }
        let welcomeWindow = WelcomeWindowController(permissions: permissions, openPermissionSettings: openPermissionSettings)
        self.welcomeWindow = welcomeWindow
        settingsWindow = SettingsWindowController(
            dependencies: SettingsDependencies(
                permissions: permissions,
                openPermissionSettings: openPermissionSettings,
                supportedOCRLanguages: OCRLanguageSupport.supportedLanguages,
                showWelcome: { [weak welcomeWindow] in welcomeWindow?.show() }
            )
        )

        let registry = makeRegistry()
        self.registry = registry
        menuBar = MenuBarController(statusMenu: StatusMenu(registry: registry))
        EditorShortcutVariant.sync()
        registry.refresh()
        observeDefaults()
        welcomeWindow.showIfFirstLaunch()
        Logger.app.info("Cheese launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry?.stopAll()
    }

    private func makeRegistry() -> ActionRegistry {
        let capture = CaptureController(capturer: CaptureService())
        let editor = AnnotationEditor()
        let clipboard = ClipboardModule(permissions: permissions, permissionPrompter: permissionPrompter) { [weak self] in
            self?.menuBar?.anchorView
        }
        self.clipboard = clipboard
        let ocr = OCRModule(capture: capture)
        let scrollCapture = ScrollCaptureModule(capture: capture, previewActions: ScrollPreviewWindow.Actions(
            annotate: { image in editor.open(image) },
            recognizeText: { image in await ocr.copyText(fromTallImage: image) }
        ))
        let modules: [any CheeseModule] = [
            clipboard,
            ScreenshotsModule(capture: capture, editor: editor),
            ocr,
            scrollCapture,
            WindowSnappingModule(snapper: WindowSnapper(controller: WindowManager())),
            KeepAwakeModule { [weak self] text in self?.menuBar?.setIndicator(text) },
        ]
        let preferences = Preferences()
        return ActionRegistry(
            appActions: appActions(),
            moduleManager: ModuleManager(modules: modules) { preferences.isModuleEnabled($0) },
            permissions: permissions
        ) { [permissionPrompter] permission, feature in
            permissionPrompter.presentAlert(for: permission, feature: feature)
        }
    }

    /// Actions that belong to Cheese itself rather than a module, so they can't be switched off.
    private func appActions() -> [CheeseAction] {
        [
            CheeseAction(id: .editShortcuts, title: "Keyboard Shortcuts…", symbol: "keyboard", module: nil) { [weak self] _ in
                self?.settingsWindow?.show(tab: .shortcuts)
            },
            CheeseAction(id: .openSettings, title: "Settings…", symbol: "gearshape", module: nil) { [weak self] _ in
                self?.settingsWindow?.show()
            },
            CheeseAction(id: .showWelcome, title: "Welcome Guide…", symbol: "hand.wave", module: nil) { [weak self] _ in
                self?.welcomeWindow?.show()
            },
            CheeseAction(id: .quit, title: "Quit Cheese", symbol: "power", module: nil) { _ in
                NSApp.terminate(nil)
            },
        ]
    }

    /// Settings changes take effect right away: module toggles start or stop modules (and their
    /// hotkeys), a smaller history size trims history, and a rebound full-screen shortcut takes
    /// its Shift variant along.
    private func observeDefaults() {
        defaultsObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                EditorShortcutVariant.sync()
                self?.registry?.refresh()
                self?.clipboard?.enforceRetention()
            }
        }
    }
}
