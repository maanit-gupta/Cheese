import AppKit
import KeyboardShortcuts
import SwiftData
import os

/// Composition root: owns every feature controller and routes `AppAction`s to them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissions: any PermissionChecking = SystemPermissions()
    private let permissionPrompter = PermissionPrompter()
    private var statusMenu: StatusMenu?
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var clipboard: ClipboardController?
    private var liveText: LiveTextIndexer?
    private let capture = CaptureController(capturer: CaptureService())
    private let snapper = WindowSnapper(controller: WindowManager())
    private let editor = AnnotationEditor()
    private var scrollSession: ScrollCaptureSession?
    private lazy var scrollPreview = ScrollPreviewWindow(actions: ScrollPreviewWindow.Actions(
        annotate: { [weak self] image in self?.editor.open(image) },
        recognizeText: { [weak self] image in await self?.copyText(fromTallImage: image) }
    ))
    private var hotkeyTasks: [Task<Void, Never>] = []
    private var defaultsObserver: Task<Void, Never>?

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted in the app; don't add a status item or grab hotkeys there.
        guard !Self.isRunningUnitTests else { return }

        MainMenu.install()
        let statusMenu = StatusMenu { [weak self] action in self?.perform(action) }
        self.statusMenu = statusMenu
        let menuBar = MenuBarController(menu: statusMenu.menu)
        self.menuBar = menuBar
        menuBar.primaryClickAction = { [weak self] in self?.perform(.openHistory) }
        startClipboard()
        capture.onCapture = { [weak self] image, wantsEditor in self?.handleScreenshot(image, wantsEditor: wantsEditor) }
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
        registerHotkeys()
        welcomeWindow.showIfFirstLaunch()
        Logger.app.info("Cheese launched")
    }

    private func startClipboard() {
        let preferences = Preferences()
        let container: ModelContainer
        do {
            container = try ClipStore.makeContainer()
        } catch {
            // Keep the app usable; history just won't survive this launch.
            Logger.app.error("Couldn't open the history store, using memory only: \(error.localizedDescription, privacy: .public)")
            do {
                container = try ClipStore.makeContainer(storeURL: nil)
            } catch {
                Logger.app.fault("Couldn't create an in-memory history store: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let store = ClipStore(container: container, images: ClipImageStorage()) { preferences.historySize }
        let clipboard = ClipboardController(
            store: store,
            canPostEvents: { [permissions] in permissions.isGranted(.accessibility) },
            onMissingAccessibility: { [permissionPrompter] in
                permissionPrompter.presentAlert(for: .accessibility, feature: "Pasting from history")
            }
        )
        self.clipboard = clipboard

        // Live Text: OCR history images in the background so search finds the text in them.
        let liveText = LiveTextIndexer(ocr: .live) { [weak store] id, text in
            store?.setRecognizedText(text, for: id)
        }
        self.liveText = liveText
        store.onImageItemAdded = { [weak liveText] id, url in liveText?.enqueue(id, imageURL: url) }
        for item in store.imageItemsAwaitingRecognition {
            liveText.enqueue(item.id, imageURL: item.url)
        }

        clipboard.start()

    }

    private func registerHotkeys() {
        EditorShortcutVariant.sync()
        hotkeyTasks = Hotkey.allCases.map { hotkey in
            Task { [weak self] in
                for await _ in KeyboardShortcuts.events(.keyDown, for: hotkey.name) {
                    self?.perform(AppAction(hotkey))
                }
            }
        }
        // Shift + the full-screen shortcut; `perform` sees Shift held and opens the editor.
        hotkeyTasks.append(Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .captureFullScreenEditor) {
                self?.perform(.captureFullScreen)
            }
        })

        // Settings changes: a smaller history size applies right away, and a rebound
        // full-screen shortcut takes its Shift variant along.
        defaultsObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                EditorShortcutVariant.sync()
                self?.clipboard?.store.enforceRetention()
            }
        }
    }

    func perform(_ action: AppAction) {
        if let missing = permissions.missing(from: action.requiredPermissions).first {
            permissionPrompter.presentAlert(for: missing, feature: action.title)
            return
        }

        switch action {
        case .openSettings:
            settingsWindow?.show()
        case .editShortcuts:
            settingsWindow?.show(tab: .shortcuts)
        case .quit:
            NSApp.terminate(nil)
        case .openHistory:
            clipboard?.toggleHistory(anchoredTo: menuBar?.anchorView)
        case .clearHistory:
            clipboard?.store.clearHistory()
        case .clearAll:
            confirmClearAll()
        case .captureRegion:
            Task { await capture.captureRegion() }
        case .captureWindow:
            Task { await capture.captureWindow() }
        case .captureFullScreen:
            let wantsEditor = NSEvent.modifierFlags.contains(.shift)
            Task { await capture.captureFullScreen(wantsEditor: wantsEditor) }
        case .ocrRegion:
            Task { await copyTextFromRegion() }
        case .snapLeft:
            snapper.perform(.snap(.leftHalf))
        case .snapRight:
            snapper.perform(.snap(.rightHalf))
        case .maximize:
            snapper.perform(.snap(.maximize))
        case .snapBottom:
            snapper.perform(.snap(.bottomHalf))
        case .restoreWindow:
            snapper.perform(.restore)
        case .scrollingCapture:
            // The hotkey again stops a capture that's running.
            if let scrollSession {
                scrollSession.stop()
            } else {
                Task { await scrollingCapture() }
            }
        }
    }

    private func handleScreenshot(_ image: CapturedImage, wantsEditor: Bool) {
        if wantsEditor {
            editor.open(image)
            return
        }
        Task {
            if await ImageExport.copy(image) {
                Toast.show("Screenshot copied")
            }
        }
    }

    /// OCR: select a region, read codes or text from it, and copy the result.
    private func copyTextFromRegion() async {
        guard let selection = await capture.selectRegion() else { return }
        let image = selection.image
        selection.session.end(restoreFocus: true)
        guard let image else { return }

        let result = await OCRService.live.read(image.image)
        guard let text = result.copyText else {
            Toast.show(result.summary, systemImage: "text.viewfinder")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if case let .codes(payloads) = result, let url = BarcodeReader.openableURL(from: payloads) {
            Toast.show(result.summary, systemImage: "qrcode", action: Toast.Action(title: "Open") {
                NSWorkspace.shared.open(url)
            })
        } else {
            Toast.show(result.summary, systemImage: result == .nothing ? "text.viewfinder" : "text.quote")
        }
    }

    /// Scrolling capture: select a region, auto-scroll and stitch it, then show the preview.
    private func scrollingCapture() async {
        guard let selection = await capture.selectRegion() else { return }
        selection.session.end(restoreFocus: true)
        let capturer: any RegionCapturing
        do {
            capturer = try await capture.regionCapturer(for: selection)
        } catch {
            Logger.app.error("Scrolling capture setup failed: \(error.localizedDescription, privacy: .public)")
            Toast.show("Capture failed: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let session = ScrollCaptureSession(region: selection.rect, capturer: capturer)
        scrollSession = session
        let result = await session.run()
        scrollSession = nil
        if let result {
            scrollPreview.show(result)
        }
    }

    /// OCR for stitched pages, which are read in strips so small text survives.
    private func copyText(fromTallImage image: CapturedImage) async {
        let service = OCRService.live
        var parts: [String] = []
        for tile in await ImageTiling.tiles(of: image.image) {
            do {
                let text = try await TextRecognizer.recognizeText(in: tile, languages: service.languages(), mode: service.lineBreakMode())
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            } catch {
                Logger.app.error("OCR of a strip failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let result: OCRResult = parts.isEmpty ? .nothing : .text(parts.joined(separator: "\n"))
        if let text = result.copyText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Toast.show(result.summary, systemImage: result == .nothing ? "text.viewfinder" : "text.quote")
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes every item, including pinned ones. It can't be undone."
        alert.addButton(withTitle: "Clear All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clipboard?.store.clearAll()
    }
}
