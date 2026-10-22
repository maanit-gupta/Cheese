import AppKit
import KeyboardShortcuts
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
    private var files: FilesModule?
    private let appHotkeyStore = AppHotkeyStore()
    private let installedApps = InstalledAppIndex()
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
                showWelcome: { [weak welcomeWindow] in welcomeWindow?.show() },
                appHotkeys: AppHotkeysSettingsModel(store: appHotkeyStore, index: installedApps) { [weak self] in
                    self?.takenAppHotkeyCharacters() ?? []
                },
                files: FilesSettingsModel()
            )
        )

        let registry = makeRegistry()
        self.registry = registry
        menuBar = MenuBarController(
            statusMenu: StatusMenu(registry: registry) { [weak self] in self?.files?.progressMenuItems ?? [] },
            dropMenu: { [weak self] urls in self?.files?.dropMenu(for: urls) }
        )
        EditorShortcutVariant.sync()
        registry.refresh()
        FilesHandoff.setEnabled(Preferences().isModuleEnabled(.files))
        observeDefaults()
        welcomeWindow.showIfFirstLaunch()
        Logger.app.info("Cheese launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry?.stopAll()
    }

    /// `cheese://job/<uuid>` from the Finder extension: open that tool on the handed-over files.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            files?.openHandoff(url)
        }
    }

    private func makeRegistry() -> ActionRegistry {
        let captureService = CaptureService()
        let capture = CaptureController(capturer: captureService)
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
        let files = FilesModule { [weak self] text in self?.menuBar?.setIndicator(text, for: .files) }
        self.files = files
        let modules: [any CheeseModule] = [
            clipboard,
            ScreenshotsModule(capture: capture, editor: editor),
            ocr,
            scrollCapture,
            WindowSnappingModule(snapper: WindowSnapper(controller: WindowManager())),
            DrawModule(services: DrawModeController.Services(
                captureDisplay: { displayID, overlay in
                    try await captureService.captureDisplay(displayID, includingCheeseWindows: [overlay])
                },
                openEditor: { image in editor.open(image) },
                isScreenRecordingGranted: { [permissions] in permissions.isGranted(.screenRecording) },
                explainMissingScreenRecording: { [permissionPrompter] feature in
                    permissionPrompter.presentAlert(for: .screenRecording, feature: feature)
                }
            )),
            QRModule(),
            KeepAwakeModule { [weak self] text in self?.menuBar?.setIndicator(text, for: .keepAwake) },
            AppHotkeysModule(store: appHotkeyStore, index: installedApps),
            CommandPaletteModule(
                availableActions: { [weak self] in self?.registry?.availableActions ?? [] },
                perform: { [weak self] id, context in self?.registry?.perform(id, context: context) }
            ),
            files,
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

    /// Letters and digits already used with Ctrl+Opt+Cmd: by Cheese's actions, other app hotkeys,
    /// macOS's own shortcuts, and the bundled list of popular utilities.
    private func takenAppHotkeyCharacters() -> Set<Character> {
        let names = (registry?.shortcutNames ?? []) + appHotkeyStore.bindings.map(\.shortcutName)
        let cheese = names.compactMap { KeyboardShortcuts.getShortcut(for: $0) }
        return AppHotkeyKeys.takenCharacters(in: cheese + SystemShortcutReader.enabledShortcuts())
            .union(ReservedShortcuts.takenCharacters(in: ReservedShortcuts.bundled()))
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
        ] + settingsTabActions()
    }

    /// "Settings: General" and friends, so the palette can open Settings on any tab.
    private func settingsTabActions() -> [CheeseAction] {
        let tabs: [(ActionID, String, String, SettingsTab)] = [
            (.settingsGeneral, "General", "gearshape", .general),
            (.settingsShortcuts, "Shortcuts", "keyboard", .shortcuts),
            (.settingsClipboard, "Clipboard", "doc.on.clipboard", .clipboard),
            (.settingsOCR, "OCR", "text.viewfinder", .ocr),
            (.settingsAppHotkeys, "App Hotkeys", "app.badge", .appHotkeys),
            (.settingsFiles, "Files", "doc.on.doc", .files),
            (.settingsPermissions, "Permissions", "lock.shield", .permissions),
            (.settingsAbout, "About", "info.circle", .about),
        ]
        return tabs.map { id, title, symbol, tab in
            CheeseAction(id: id, title: "Settings: \(title)", symbol: symbol, module: nil) { [weak self] _ in
                self?.settingsWindow?.show(tab: tab)
            }
        }
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
                // The Finder extension shows "Cheese Files is turned off" when the module is off.
                FilesHandoff.setEnabled(Preferences().isModuleEnabled(.files))
            }
        }
    }
}
