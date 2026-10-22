import AppKit
import KeyboardShortcuts

/// Every global hotkey Cheese registers. Users can rebind each one in Settings → Shortcuts.
enum Hotkey: CaseIterable, Sendable {
    case openHistory
    case captureRegion
    case captureFullScreen
    case captureWindow
    case ocrRegion
    case scrollingCapture
    case snapLeft
    case snapRight
    case maximize
    case snapBottom
    case restoreWindow

    var name: KeyboardShortcuts.Name {
        switch self {
        case .openHistory: .openHistory
        case .captureRegion: .captureRegion
        case .captureFullScreen: .captureFullScreen
        case .captureWindow: .captureWindow
        case .ocrRegion: .ocrRegion
        case .scrollingCapture: .scrollingCapture
        case .snapLeft: .snapLeft
        case .snapRight: .snapRight
        case .maximize: .maximize
        case .snapBottom: .snapBottom
        case .restoreWindow: .restoreWindow
        }
    }

    var title: String {
        switch self {
        case .openHistory: "Open clipboard history"
        case .captureRegion: "Capture region"
        case .captureFullScreen: "Capture full screen"
        case .captureWindow: "Capture window"
        case .ocrRegion: "Copy text from region (OCR)"
        case .scrollingCapture: "Scrolling capture"
        case .snapLeft: "Snap to left half"
        case .snapRight: "Snap to right half"
        case .maximize: "Maximize"
        case .snapBottom: "Snap to bottom half"
        case .restoreWindow: "Restore window"
        }
    }
}

extension KeyboardShortcuts.Name {
    private static let modifiers: NSEvent.ModifierFlags = [.control, .option]

    static let openHistory = Self("openHistory", initial: .init(.v, modifiers: modifiers))
    static let captureRegion = Self("captureRegion", initial: .init(.four, modifiers: modifiers))
    static let captureFullScreen = Self("captureFullScreen", initial: .init(.three, modifiers: modifiers))
    static let captureWindow = Self("captureWindow", initial: .init(.five, modifiers: modifiers))
    static let ocrRegion = Self("ocrRegion", initial: .init(.t, modifiers: modifiers))
    static let scrollingCapture = Self("scrollingCapture", initial: .init(.s, modifiers: modifiers))
    static let snapLeft = Self("snapLeft", initial: .init(.leftArrow, modifiers: modifiers))
    static let snapRight = Self("snapRight", initial: .init(.rightArrow, modifiers: modifiers))
    static let maximize = Self("maximize", initial: .init(.upArrow, modifiers: modifiers))
    static let snapBottom = Self("snapBottom", initial: .init(.downArrow, modifiers: modifiers))
    static let restoreWindow = Self("restoreWindow", initial: .init(.delete, modifiers: modifiers))
}

extension KeyboardShortcuts.Name {
    /// Not listed in Settings: always the full-screen shortcut plus Shift, which opens the editor.
    /// A separate registration is needed because a hotkey only fires for its exact modifiers.
    static let captureFullScreenEditor = Self("captureFullScreenEditor")
}

@MainActor
enum EditorShortcutVariant {
    /// Keeps `captureFullScreenEditor` in step with the user's full-screen shortcut.
    static func sync() {
        let target = shiftVariant(of: KeyboardShortcuts.getShortcut(for: .captureFullScreen))
        // Only write on a real change: writing posts a defaults notification that calls this again.
        if KeyboardShortcuts.getShortcut(for: .captureFullScreenEditor) != target {
            KeyboardShortcuts.setShortcut(target, for: .captureFullScreenEditor)
        }
    }

    /// The shortcut plus Shift, or nil when there's no shortcut or it already uses Shift.
    nonisolated static func shiftVariant(of shortcut: KeyboardShortcuts.Shortcut?) -> KeyboardShortcuts.Shortcut? {
        guard let shortcut, let key = shortcut.key, !shortcut.modifiers.contains(.shift) else { return nil }
        return KeyboardShortcuts.Shortcut(key, modifiers: shortcut.modifiers.union(.shift))
    }
}
