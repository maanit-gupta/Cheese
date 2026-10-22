import Foundation

/// UserDefaults keys. Views bind to these with `@AppStorage`, using the defaults in `Preferences`.
/// No dots in keys: `@AppStorage` observes them with KVO.
enum PreferenceKey {
    static let screenshotSaveFolder = "screenshotSaveFolder"
    static let historySize = "historySize"
    static let ocrLineBreakMode = "ocrLineBreakMode"
    static let hasSeenWelcome = "hasSeenWelcome"

    static func ocrLanguageEnabled(_ language: OCRLanguage) -> String {
        "ocrLanguageEnabled_\(language.rawValue)"
    }

    static func moduleEnabled(_ module: ModuleID) -> String {
        "moduleEnabled_\(module.rawValue)"
    }

    static let filesNativeFallback = "filesNativeFallback"

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

    func isOCRLanguageEnabled(_ language: OCRLanguage) -> Bool {
        defaults.object(forKey: PreferenceKey.ocrLanguageEnabled(language)) as? Bool
            ?? Self.defaultOCRLanguageEnabled
    }

    /// Use Microsoft Office or LibreOffice for Office → PDF when installed. Off unless the user opts in.
    var usesNativeOfficeApps: Bool {
        defaults.bool(forKey: PreferenceKey.filesNativeFallback)
    }

    func isModuleEnabled(_ module: ModuleID) -> Bool {
        defaults.object(forKey: PreferenceKey.moduleEnabled(module)) as? Bool
            ?? Self.defaultModuleEnabled
    }
}
