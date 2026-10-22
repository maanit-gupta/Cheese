import AppKit
import SwiftUI

/// The welcome screens, in order: what Cheese is, which tools to keep, and the permissions those need.
enum WelcomeStep: Int, CaseIterable, Sendable {
    case intro
    case tools
    case permissions

    var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
    var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }
    var isFirst: Bool { previous == nil }
    var isLast: Bool { next == nil }
}

/// Shows the welcome flow on first launch, and again from Settings → General. Closing it,
/// finished or not, counts as seen. Tool choices go straight to the module toggles, so
/// `ModuleManager` starts and stops modules as the user flips them.
@MainActor
final class WelcomeFlow {
    private let permissions: any PermissionChecking
    private let openPermissionSettings: @MainActor (Permission) -> Void
    private let defaults: UserDefaults
    private var panel: CheesePanel?

    init(
        permissions: any PermissionChecking,
        openPermissionSettings: @escaping @MainActor (Permission) -> Void,
        defaults: UserDefaults = .standard
    ) {
        self.permissions = permissions
        self.openPermissionSettings = openPermissionSettings
        self.defaults = defaults
    }

    func showIfFirstLaunch() {
        guard !Preferences(defaults: defaults).hasSeenWelcome else { return }
        show()
    }

    func show() {
        if let panel {
            panel.present(at: .centered)
            return
        }
        let view = WelcomeView(
            permissions: permissions,
            openSystemSettings: openPermissionSettings,
            finish: { [weak self] in self?.close() }
        )
        var behavior = CheesePanel.Behavior()
        behavior.dismissesOnOutsideClick = false
        behavior.isMovable = true
        behavior.level = .floating
        let panel = CheesePanel(rootView: view, behavior: behavior)
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        panel.present(at: .centered)
    }

    func close() {
        defaults.set(true, forKey: PreferenceKey.hasSeenWelcome)
        panel?.dismiss()
        // Dropped, so showing it again starts from the first screen.
        panel = nil
    }
}
