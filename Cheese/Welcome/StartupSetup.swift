import AppKit
import os

/// What the launch prompt offers to turn on.
enum StartupSetupItem: CaseIterable, Sendable {
    case accessibility
    case launchAtLogin

    var title: String {
        switch self {
        case .accessibility: "Allow Accessibility access"
        case .launchAtLogin: "Open Cheese automatically when you log in"
        }
    }

    /// What still needs turning on, in prompt order. Empty when everything is on or the user
    /// asked not to be asked again.
    static func pending(accessibilityGranted: Bool, launchAtLoginEnabled: Bool, skipped: Bool) -> [StartupSetupItem] {
        guard !skipped else { return [] }
        return allCases.filter { item in
            switch item {
            case .accessibility: !accessibilityGranted
            case .launchAtLogin: !launchAtLoginEnabled
            }
        }
    }
}

/// Asks at launch for Accessibility access and launch at login, whichever is still off, until
/// both are on or the user ticks "Don't ask again".
@MainActor
struct StartupSetupPrompt {
    let permissions: any PermissionChecking
    let permissionPrompter: PermissionPrompter
    var defaults: UserDefaults = .standard

    func showIfNeeded() {
        let pending = StartupSetupItem.pending(
            accessibilityGranted: permissions.isGranted(.accessibility),
            launchAtLoginEnabled: LaunchAtLogin.isEnabled,
            skipped: Preferences(defaults: defaults).skipsStartupSetup
        )
        guard !pending.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Finish setting up Cheese"
        alert.informativeText = pending.contains(.accessibility)
            ? Permission.accessibility.purpose + " Turn on Cheese in the list System Settings opens."
            : "Cheese lives in your menu bar, so it's most useful when it's always running."
        let checkboxes = pending.map { item in
            let checkbox = NSButton(checkboxWithTitle: item.title, target: nil, action: nil)
            checkbox.state = .on
            return checkbox
        }
        let stack = NSStackView(views: checkboxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: PreferenceKey.skipsStartupSetup)
        }
        guard response == .alertFirstButtonReturn else { return }
        let chosen = zip(pending, checkboxes).filter { $0.1.state == .on }.map(\.0)
        // Login items first: Accessibility hands focus to System Settings.
        if chosen.contains(.launchAtLogin) {
            enableLaunchAtLogin()
        }
        if chosen.contains(.accessibility) {
            permissionPrompter.openSystemSettings(for: .accessibility)
        }
    }

    private func enableLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(true)
        } catch {
            Logger.welcome.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        if LaunchAtLogin.requiresApproval {
            LaunchAtLogin.openApprovalSettings()
        }
    }
}
