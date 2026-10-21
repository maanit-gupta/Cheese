import AppKit
import KeyboardShortcuts
import os

/// Composition root: owns every feature controller and routes `AppAction`s to them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissions: any PermissionChecking = SystemPermissions()
    private let permissionPrompter = PermissionPrompter()
    private var statusMenu: StatusMenu?
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var hotkeyTasks: [Task<Void, Never>] = []

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted in the app; don't add a status item or grab hotkeys there.
        guard !Self.isRunningUnitTests else { return }

        let statusMenu = StatusMenu { [weak self] action in self?.perform(action) }
        self.statusMenu = statusMenu
        menuBar = MenuBarController(menu: statusMenu.menu)
        settingsWindow = SettingsWindowController(
            dependencies: SettingsDependencies(
                permissions: permissions,
                openPermissionSettings: { [permissionPrompter] permission in
                    permissionPrompter.openSystemSettings(for: permission)
                },
                supportedOCRLanguages: OCRLanguageSupport.supportedLanguages
            )
        )
        registerHotkeys()
        Logger.app.info("Cheese launched")
    }

    private func registerHotkeys() {
        hotkeyTasks = Hotkey.allCases.map { hotkey in
            Task { [weak self] in
                for await _ in KeyboardShortcuts.events(.keyDown, for: hotkey.name) {
                    self?.perform(AppAction(hotkey))
                }
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
        case .quit:
            NSApp.terminate(nil)
        case .clearAll:
            confirmClearAll()
        case .openHistory, .captureRegion, .captureFullScreen, .captureWindow, .ocrRegion,
             .scrollingCapture, .snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow,
             .clearHistory:
            notImplemented(action)
        }
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes every item, including pinned ones. It can't be undone."
        alert.addButton(withTitle: "Clear All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notImplemented(.clearAll)
    }

    // Placeholder until each feature lands (build order steps 2–8). The beep confirms the trigger fired.
    private func notImplemented(_ action: AppAction) {
        Logger.app.notice("\(action.title, privacy: .public) isn't implemented yet")
        NSSound.beep()
    }
}
