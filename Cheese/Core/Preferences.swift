import Foundation

/// UserDefaults keys. Views bind to these with `@AppStorage`, using the defaults in `Preferences`.
/// No dots in keys: `@AppStorage` observes them with KVO.
enum PreferenceKey {
    static let screenshotSaveFolder = "screenshotSaveFolder"
    static let historySize = "historySize"
    static let ocrLineBreakMode = "ocrLineBreakMode"
    static let hasSeenWelcome = "hasSeenWelcome"
    static let skipsStartupSetup = "skipsStartupSetup"

    static func ocrLanguageEnabled(_ language: OCRLanguage) -> String {
        "ocrLanguageEnabled_\(language.rawValue)"
    }

    static func moduleEnabled(_ module: ModuleID) -> String {
        "moduleEnabled_\(module.rawValue)"
    }

    static let filesNativeFallback = "filesNativeFallback"
    static let drawLetterKeys = "drawLetterKeys"
    static let shareDeviceName = "shareDeviceName"
    static let shareDestination = "shareDestination"
    static let shareMaxGigabytes = "shareMaxGigabytes"
    static let autoKillForcesStragglers = "autoKillForcesStragglers"
    static let windowFillMode = "windowFillMode"
    static let stageManagerStripInset = "stageManagerStripInset"

    /// Last-used options of a Files tool, as JSON.
    static func fileToolOptions(_ tool: ToolID) -> String {
        "fileToolOptions_\(tool.rawValue)"
    }
}

enum OCRLineBreakMode: String, CaseIterable, Sendable {
    case keepLineBreaks
    case joinParagraphs
}

enum OCRLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case hindi = "hi"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .english: "English"
        case .hindi: "Hindi"
        }
    }

    var languageCode: Locale.LanguageCode {
        switch self {
        case .english: .english
        case .hindi: .hindi
        }
    }
}

/// Typed, read-only access to user preferences, falling back to defaults for unset or invalid values.
struct Preferences {
    static let defaultHistorySize = 200
    static let historySizeRange = 50...1000
    static let defaultLineBreakMode = OCRLineBreakMode.keepLineBreaks
    static let defaultOCRLanguageEnabled = true
    static let defaultModuleEnabled = true
    static var defaultSaveFolder: URL { .desktopDirectory }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var historySize: Int {
        let stored = defaults.object(forKey: PreferenceKey.historySize) as? Int ?? Self.defaultHistorySize
        return min(max(stored, Self.historySizeRange.lowerBound), Self.historySizeRange.upperBound)
    }

    var screenshotSaveFolder: URL {
        guard let path = defaults.string(forKey: PreferenceKey.screenshotSaveFolder), !path.isEmpty else {
            return Self.defaultSaveFolder
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    var ocrLineBreakMode: OCRLineBreakMode {
        defaults.string(forKey: PreferenceKey.ocrLineBreakMode).flatMap(OCRLineBreakMode.init(rawValue:))
            ?? Self.defaultLineBreakMode
    }

    /// False until the welcome window has been finished or closed once.
    var hasSeenWelcome: Bool {
        defaults.bool(forKey: PreferenceKey.hasSeenWelcome)
    }

    /// True once the user ticked "Don't ask again" on the launch prompt.
    var skipsStartupSetup: Bool {
        defaults.bool(forKey: PreferenceKey.skipsStartupSetup)
    }

    func isOCRLanguageEnabled(_ language: OCRLanguage) -> Bool {
        defaults.object(forKey: PreferenceKey.ocrLanguageEnabled(language)) as? Bool
            ?? Self.defaultOCRLanguageEnabled
    }

    /// Use Microsoft Office or LibreOffice for Office → PDF when installed. Off unless the user opts in.
    var usesNativeOfficeApps: Bool {
        defaults.bool(forKey: PreferenceKey.filesNativeFallback)
    }

    /// Single-letter tool keys in draw mode (P, H, E…). Off unless the user turns them on.
    var usesDrawLetterKeys: Bool {
        defaults.bool(forKey: PreferenceKey.drawLetterKeys)
    }

    static let defaultShareMaxGigabytes = 10
    static var defaultShareDestination: URL { .downloadsDirectory }

    /// What Cheese Share calls this Mac: the computer name unless the user renamed it.
    var shareDeviceName: String {
        let stored = defaults.string(forKey: PreferenceKey.shareDeviceName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? (Host.current().localizedName ?? "Mac") : stored
    }

    /// Where received files go (Downloads unless changed).
    var shareDestination: URL {
        guard let path = defaults.string(forKey: PreferenceKey.shareDestination), !path.isEmpty else {
            return Self.defaultShareDestination
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The largest transfer Cheese Share accepts, in bytes.
    var shareMaxBytes: Int64 {
        let stored = defaults.object(forKey: PreferenceKey.shareMaxGigabytes) as? Int ?? Self.defaultShareMaxGigabytes
        return Int64(min(max(stored, 1), 1000)) * 1_000_000_000
    }

    /// Auto-Kill force-quits apps still open 3 s after being asked to quit. Off unless the user opts in,
    /// since that includes apps waiting on "Save changes?".
    var autoKillForcesStragglers: Bool {
        defaults.bool(forKey: PreferenceKey.autoKillForcesStragglers)
    }

    static let defaultWindowFillMode = WindowFillMode.stageManagerSafe

    /// How Fill to Screen sizes windows.
    var windowFillMode: WindowFillMode {
        defaults.string(forKey: PreferenceKey.windowFillMode).flatMap(WindowFillMode.init(rawValue:)) ?? Self.defaultWindowFillMode
    }

    /// The room Fill to Screen leaves for the Stage Manager strip, in points, within the allowed range.
    var stageManagerStripInset: CGFloat {
        let stored = defaults.object(forKey: PreferenceKey.stageManagerStripInset) as? Double ?? Double(StageManagerLayout.defaultStripInset)
        let range = StageManagerLayout.stripInsetRange
        return min(max(CGFloat(stored), range.lowerBound), range.upperBound)
    }

    func isModuleEnabled(_ module: ModuleID) -> Bool {
        defaults.object(forKey: PreferenceKey.moduleEnabled(module)) as? Bool
            ?? Self.defaultModuleEnabled
    }
}
