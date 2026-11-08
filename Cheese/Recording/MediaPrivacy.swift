import AVFoundation
import AppKit

/// Camera and microphone access, which recordings ask for only when they're turned on.
@MainActor
enum MediaPrivacy {
    /// True once access is granted; asks the first time.
    static func requestAccess(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    static func openSettings(for type: AVMediaType) {
        let pane = type == .video ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explains a refusal, with a button to the privacy pane.
    static func explainDenied(_ type: AVMediaType) {
        let alert = NSAlert()
        let name = type == .video ? "Camera" : "Microphone"
        alert.messageText = "Cheese can't use the \(name.lowercased())"
        alert.informativeText = "Allow Cheese in System Settings → Privacy & Security → \(name), then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings(for: type)
        }
    }
}
