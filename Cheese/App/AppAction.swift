/// Everything the user can trigger from the menu bar menu or a global hotkey.
enum AppAction: Equatable, Sendable {
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
    case clearHistory
    case clearAll
    case openSettings
    case quit

    init(_ hotkey: Hotkey) {
        self = switch hotkey {
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

    var hotkey: Hotkey? {
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
        case .clearHistory, .clearAll, .openSettings, .quit: nil
        }
    }

    var title: String {
        switch self {
        case .openHistory: "Open History"
        case .captureRegion: "Capture Region"
        case .captureFullScreen: "Capture Screen"
        case .captureWindow: "Capture Window"
        case .ocrRegion: "OCR"
        case .scrollingCapture: "Scrolling Capture"
        case .snapLeft: "Snap Left"
        case .snapRight: "Snap Right"
        case .maximize: "Maximize"
        case .snapBottom: "Snap Bottom"
        case .restoreWindow: "Restore Window"
        case .clearHistory: "Clear History"
        case .clearAll: "Clear All"
        case .openSettings: "Settings…"
        case .quit: "Quit"
        }
    }

    /// Permissions the action can't run without. Opening history needs none: without
    /// Accessibility, pasting from it falls back to copying only.
    var requiredPermissions: [Permission] {
        switch self {
        case .captureRegion, .captureFullScreen, .captureWindow, .ocrRegion:
            [.screenRecording]
        case .scrollingCapture:
            [.screenRecording, .accessibility]
        case .snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow:
            [.accessibility]
        case .openHistory, .clearHistory, .clearAll, .openSettings, .quit:
            []
        }
    }
}
