/// The feature areas the user can switch off in Settings → General → Modules.
/// A disabled module registers no hotkeys, runs nothing in the background, and its actions disappear.
enum ModuleID: String, CaseIterable, Identifiable, Sendable {
    case clipboard
    case screenshots
    case ocr
    case scrollingCapture
    case windowSnapping
    case drawOnScreen
    case qr
    case keepAwake
    case appHotkeys
    case commandPalette
    case files

    var id: Self { self }

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .ocr: "OCR"
        case .scrollingCapture: "Scrolling Capture"
        case .windowSnapping: "Window Snapping"
        case .drawOnScreen: "Draw on Screen"
        case .qr: "QR"
        case .keepAwake: "Keep Awake"
        case .appHotkeys: "App Hotkeys"
        case .commandPalette: "Command Palette"
        case .files: "Files"
        }
    }
}
