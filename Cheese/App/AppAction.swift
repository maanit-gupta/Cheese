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
    case editShortcuts
    case openSettings
    case showWelcome
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
        case .clearHistory, .clearAll, .editShortcuts, .openSettings, .showWelcome, .quit: nil
        }
    }

    var title: String {
        switch self {
        case .openHistory: "Clipboard History"
        case .captureRegion: "Capture Region"
        case .captureFullScreen: "Capture Full Screen"
        case .captureWindow: "Capture Window"
        case .ocrRegion: "Copy Text from Screen"
        case .scrollingCapture: "Scrolling Capture"
        case .snapLeft: "Left Half"
        case .snapRight: "Right Half"
        case .maximize: "Maximize"
        case .snapBottom: "Bottom Half"
        case .restoreWindow: "Restore Previous Size"
        case .clearHistory: "Clear History"
        case .clearAll: "Clear All…"
        case .editShortcuts: "Keyboard Shortcuts…"
        case .openSettings: "Settings…"
        case .showWelcome: "Welcome Guide…"
        case .quit: "Quit Cheese"
        }
    }

    /// How permission alerts name the feature: "Window snapping needs Accessibility access".
    var featureName: String {
        switch self {
        case .snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow: "Window snapping"
        case .ocrRegion: "Copying text from the screen"
        default: title
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
        case .openHistory, .clearHistory, .clearAll, .editShortcuts, .openSettings, .showWelcome, .quit:
            []
        }
    }
}
