import AppKit
import ApplicationServices
import CoreGraphics
import os

enum Permission: CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording:
            "Used to take screenshots, copy text from the screen and make scrolling captures."
        case .accessibility:
            "Used to paste from clipboard history, snap windows and scroll during scrolling captures."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

protocol PermissionChecking: Sendable {
    func isGranted(_ permission: Permission) -> Bool
}

extension PermissionChecking {
    func missing(from required: [Permission]) -> [Permission] {
        required.filter { !isGranted($0) }
    }
}

struct SystemPermissions: PermissionChecking {
    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }
}

/// Explains a missing permission and sends the user to the right System Settings pane.
@MainActor
final class PermissionPrompter {
    private var requestedThisLaunch: Set<Permission> = []

    func presentAlert(for permission: Permission, feature: String) {
        let alert = NSAlert()
        alert.messageText = "\(feature) needs \(permission.title) access"
        var details = permission.purpose
            + "\n\nTurn on Cheese in System Settings → Privacy & Security → \(permission.title)."
        if permission == .screenRecording {
            details += " macOS may ask you to quit and reopen Cheese afterwards."
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings(for: permission)
        }
    }

    func openSystemSettings(for permission: Permission) {
        registerWithSystemIfNeeded(permission)
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Calls the request API once per launch so Cheese appears in the System Settings list.
    /// The user has to have asked for it, and it never runs in a loop.
    private func registerWithSystemIfNeeded(_ permission: Permission) {
        guard requestedThisLaunch.insert(permission).inserted else { return }
        Logger.core.info("Requesting \(permission.title, privacy: .public) access")
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            // String literal: the imported kAXTrustedCheckOptionPrompt global isn't concurrency-safe.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }
}
