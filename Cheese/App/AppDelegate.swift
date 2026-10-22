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
    private var welcome: WelcomeFlow?
    private let aboutWindow = AboutWindow()
    private var clipboard: ClipboardModule?
    private var files: FilesModule?
    private var shelf: ShelfModule?
    private var share: ShareModule?
    private var qr: QRModule?
    private let appHotkeyStore = AppHotkeyStore()
    private let installedApps = InstalledAppIndex()
    private var defaultsObserver: Task<Void, Never>?

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted in the app; don't add a status item or grab hotkeys there.
        guard !Self.isRunningUnitTests else { return }

        MainMenu.install { [aboutWindow] in aboutWindow.show() }
        let openPermissionSettings: @MainActor (Permission) -> Void = { [permissionPrompter] permission in
            permissionPrompter.openSystemSettings(for: permission)
        }
        let welcome = WelcomeFlow(permissions: permissions, openPermissionSettings: openPermissionSettings)
        self.welcome = welcome
        settingsWindow = SettingsWindowController(
            dependencies: SettingsDependencies(
                permissions: permissions,
                openPermissionSettings: openPermissionSettings,
                supportedOCRLanguages: OCRLanguageSupport.supportedLanguages,
                showWelcome: { [weak welcome] in welcome?.show() },
                appHotkeys: AppHotkeysSettingsModel(store: appHotkeyStore, index: installedApps) { [weak self] in
                    self?.takenAppHotkeyCharacters() ?? []
                },
                files: FilesSettingsModel()
            )
        )

        let registry = makeRegistry()
        self.registry = registry
        // Starting any other feature leaves Share, so its floating panel never strands the user.
        registry.willPerform = { [weak self] action in
            if action.module != .share {
                self?.share?.closePanel()
            }
        }
        menuBar = MenuBarController(
            statusMenu: StatusMenu(registry: registry) { [weak self] in self?.files?.progressMenuItems ?? [] },
            dropHub: makeDropHub(),
            openShare: { [weak self] in self?.share?.open() },
            isShareShown: { [weak self] in self?.share?.isPanelShown ?? false }
        )
        EditorShortcutVariant.sync()
        registry.refresh()
        FilesHandoff.setEnabled(Preferences().isModuleEnabled(.files))
        ShareHandoff.setEnabled(Preferences().isModuleEnabled(.share))
        observeDefaults()
        Logger.app.info("Cheese launched")
        // After launch finishes, so the menu bar icon is already showing behind the prompt.
        Task { [permissions, permissionPrompter] in
            StartupSetupPrompt(permissions: permissions, permissionPrompter: permissionPrompter).showIfNeeded()
            welcome.showIfFirstLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry?.stopAll()
    }

    /// `cheese://job/<uuid>` from the Finder extension opens that tool on the handed-over files;
    /// `cheese://share/<uuid>` from the Share menu opens Cheese Share with the shared items;
    /// `cheese://share` opens it empty; `cheese://settings/share` opens Settings on the Share tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if ShareHandoff.jobID(from: url) != nil {
                share?.openHandoff(url)
            } else if url.host() == ShareHandoff.host {
                // `cheese://share` on its own opens the Share panel, for Shortcuts and scripts.
                share?.open()
            } else if url.host() == "settings" {
                settingsWindow?.show(tab: url.lastPathComponent == "share" ? .share : .general)
            } else {
                files?.openHandoff(url)
            }
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
        let share = ShareModule(
            setIndicator: { [weak self] listening in self?.menuBar?.setIndicator(listening ? "Share" : nil, for: .share) },
            openMenu: { [weak self] in self?.menuBar?.openMenu() }
        )
        self.share = share
        let shelf = ShelfModule(services: ShelfServices(
            fileTools: { [weak files] urls in files?.applicableTools(for: urls) ?? [] },
            openFileTool: { [weak files] tool, urls in files?.open(tool, files: urls) },
            isSendAvailable: { [weak share] in share?.isRunning ?? false },
            send: { [weak share] files, texts in share?.open(files: files, texts: texts) }
        ))
        self.shelf = shelf
        let draw = DrawModule(services: DrawModeController.Services(
            captureDisplay: { displayID, overlay in
                try await captureService.captureDisplay(displayID, includingCheeseWindows: [overlay])
            },
            openEditor: { image in editor.open(image) },
            isScreenRecordingGranted: { [permissions] in permissions.isGranted(.screenRecording) },
            explainMissingScreenRecording: { [permissionPrompter] feature in
                permissionPrompter.presentAlert(for: .screenRecording, feature: feature)
            }
        ))
        let qr = QRModule()
        self.qr = qr
        let modules: [any CheeseModule] = [
            clipboard,
            ScreenshotsModule(capture: capture, editor: editor),
            ocr,
            scrollCapture,
            WindowSnappingModule(snapper: WindowSnapper(controller: WindowManager()) { FillLayout.current() }),
            draw,
            qr,
            KeepAwakeModule { [weak self] text in self?.menuBar?.setIndicator(text, for: .keepAwake) },
            AppHotkeysModule(store: appHotkeyStore, index: installedApps),
            // Draw mode never routes through the palette, and the palette stays shut while drawing.
            CommandPaletteModule(
                availableActions: { [weak self] in self?.registry?.availableActions ?? [] },
                perform: { [weak self] id, context in self?.registry?.perform(id, context: context) },
                isSuppressed: { [draw] in draw.isDrawing }
            ),
            files,
            shelf,
            share,
            AppSweepModule(),
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

    /// The hub that opens when something is dropped on the menu bar icon: Share Link / QR, Add to
    /// Shelf, and the Files tools that apply.
    private func makeDropHub() -> StatusItemDropPanelController {
        StatusItemDropPanelController(services: DropHubServices(
            canShare: { [weak self] in (self?.share?.isRunning ?? false) || (self?.qr?.isRunning ?? false) },
            canShelve: { [weak self] in self?.shelf?.isRunning ?? false },
            tools: { [weak self] urls in self?.files?.applicableTools(for: urls) ?? [] },
            share: { [weak self] payload in self?.share(payload) },
            addToShelf: { [weak self] payload in
                self?.shelf?.add(Self.shelfInputs(for: payload))
                CheeseToast.show("Added to Shelf", systemImage: "tray.and.arrow.down.fill")
            },
            openTool: { [weak self] tool, urls in self?.files?.open(tool, files: urls) }
        ))
    }

    /// Stages a drop in Cheese Share and shows its link, or, with Share off, shows it as a QR share.
    private func share(_ payload: DropPayload) {
        if let share, share.isRunning {
            share.open(ready: Self.outgoingItems(for: payload))
            return
        }
        switch payload {
        case let .files(urls): qr?.show(.files(urls))
        case let .image(png): qr?.show(.image(png: png))
        case let .link(url): qr?.show(.text(url.absoluteString))
        case let .text(text): qr?.show(.text(text))
        }
    }

    private static func outgoingItems(for payload: DropPayload) -> [OutgoingItem] {
        switch payload {
        case let .files(urls): urls.filter { !$0.hasDirectoryPath }.map(OutgoingItem.file)
        case let .image(png): ShareModule.imageItem(png, named: "Image.png").map { [$0] } ?? []
        case let .link(url): [.text(url.absoluteString)]
        case let .text(text): [.text(text)]
        }
    }

    private static func shelfInputs(for payload: DropPayload) -> [ShelfInput] {
        switch payload {
        case let .files(urls): urls.map(ShelfInput.file)
        case let .image(png): [.imageData(png, suggestedName: nil)]
        case let .link(url): [.link(url)]
        case let .text(text): [.text(text)]
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
            CheeseAction(id: .showWelcome, title: "Show Welcome…", symbol: "hand.wave", module: nil) { [weak self] _ in
                self?.welcome?.show()
            },
            CheeseAction(id: .about, title: "About Cheese", symbol: "info.circle", module: nil) { [weak self] _ in
                self?.aboutWindow.show()
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
            (.settingsWindows, "Windows", "macwindow.on.rectangle", .windows),
            (.settingsAppHotkeys, "App Hotkeys", "app.badge", .appHotkeys),
            (.settingsFiles, "Files", "doc.on.doc", .files),
            (.settingsShare, "Share", "dot.radiowaves.left.and.right", .share),
            (.settingsAutoKill, "Auto-Kill", "xmark.app", .autoKill),
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
                ShareHandoff.setEnabled(Preferences().isModuleEnabled(.share))
            }
        }
    }
}
