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
}
