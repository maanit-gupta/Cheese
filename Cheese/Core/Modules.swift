/// The feature areas the user can switch off in Settings → General → Modules.
/// A disabled module registers no hotkeys, runs nothing in the background, and its actions disappear.
enum ModuleID: String, CaseIterable, Identifiable, Sendable {
    case clipboard
    case screenshots
    case ocr
    case scrollingCapture
    case windowSnapping
    case keepAwake

    var id: Self { self }

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .ocr: "OCR"
        case .scrollingCapture: "Scrolling Capture"
        case .windowSnapping: "Window Snapping"
        case .keepAwake: "Keep Awake"
        }
    }
}
