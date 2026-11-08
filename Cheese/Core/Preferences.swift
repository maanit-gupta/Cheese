import Foundation

/// UserDefaults keys. Views bind to these with `@AppStorage`, using the defaults in `Preferences`.
/// No dots in keys: `@AppStorage` observes them with KVO.
enum PreferenceKey {
    static let screenshotSaveFolder = "screenshotSaveFolder"
    static let captureDestination = "captureDestination"
    static let historySize = "historySize"
    /// Whether a copied link has its tracking parameters stripped on the clipboard right away (off unless set).
    static let copyCleanLinkAutomatically = "copyCleanLinkAutomatically"
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
    static let terminalTraceScope = "terminalTraceScope"
    static let stageManagerStripInset = "stageManagerStripInset"
    /// Whether dragging another app's window to a screen edge or corner snaps it there (on unless set false).
    static let dragToEdgeSnappingEnabled = "dragToEdgeSnappingEnabled"
    static let caffeinateLidClosed = "caffeinateLidClosed"
    static let caffeinateBatteryFloor = "caffeinateBatteryFloor"
    /// How many seconds Sweep locks the keyboard and trackpad (30 unless set).
    static let sweepDuration = "sweepDuration"
    /// Whether Hush holds notifications back whenever the screen is shared (on unless set false).
    static let hushAutomatically = "hushAutomatically"
    /// Hush turned Focus on and hasn't turned it off yet, so a crash is undone at the next launch.
    static let hushEngagedByCheese = "hushEngagedByCheese"
    /// Whether Cheese checks GitHub for a newer release at launch and every 12 hours (on unless set false).
    static let updaterAutoCheck = "updaterAutoCheck"
    /// A version the user chose "Skip This Version" for; automatic checks stay quiet about it.
    static let updaterSkippedVersion = "updaterSkippedVersion"
    /// When the last check got an answer from GitHub, as seconds since 1970.
    static let updaterLastCheck = "updaterLastCheck"
    /// The version that ran last, to tell the first launch after an upgrade.
    static let updaterLastLaunchedVersion = "updaterLastLaunchedVersion"
    /// The version handed to the swap script, so the next launch can say whether it went in.
    static let updaterPendingVersion = "updaterPendingVersion"

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

    static let defaultCopyCleanLinkAutomatically = false

    /// Whether copied links are cleaned of tracking parameters as soon as they land on the clipboard.
    var copyCleanLinkAutomatically: Bool {
        defaults.object(forKey: PreferenceKey.copyCleanLinkAutomatically) as? Bool ?? Self.defaultCopyCleanLinkAutomatically
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

    static let defaultCaptureDestination = CaptureDestination.clipboard

    /// Where finished captures go: the clipboard unless the user chose the save folder (or both).
    var captureDestination: CaptureDestination {
        defaults.string(forKey: PreferenceKey.captureDestination).flatMap(CaptureDestination.init(rawValue:))
            ?? Self.defaultCaptureDestination
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

    /// Single-letter tool keys in draw mode (P, H, E…). On unless the user turns them off.
    var usesDrawLetterKeys: Bool {
        defaults.object(forKey: PreferenceKey.drawLetterKeys) as? Bool ?? true
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

    /// Edge to edge by default: windows that overlap Stage Manager's strip just tuck it away, and
    /// reserving room for it left a gutter beside every filled window.
    static let defaultWindowFillMode = WindowFillMode.fullVisibleFrame
    static let defaultTerminalTraceScope = TerminalTraceScope.lastResponse

    /// What Terminal Trace copies: the last command's output, or the whole terminal.
    var terminalTraceScope: TerminalTraceScope {
        defaults.string(forKey: PreferenceKey.terminalTraceScope).flatMap(TerminalTraceScope.init(rawValue:))
            ?? Self.defaultTerminalTraceScope
    }

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

    static let defaultDragToEdgeSnapping = true

    /// Whether dragging a window to a screen edge or corner snaps it there.
    var dragToEdgeSnappingEnabled: Bool {
        defaults.object(forKey: PreferenceKey.dragToEdgeSnappingEnabled) as? Bool ?? Self.defaultDragToEdgeSnapping
    }

    static let defaultCaffeinateLidClosed = true
    static let defaultCaffeinateBatteryFloor = 10
    /// The battery floors Settings offers; 0 means never stop for the battery.
    static let caffeinateBatteryFloors = [0, 5, 10, 15, 20, 25, 30]

    /// Whether Caffeinate sessions keep the Mac awake with the lid closed too.
    var caffeinateLidClosed: Bool {
        defaults.object(forKey: PreferenceKey.caffeinateLidClosed) as? Bool ?? Self.defaultCaffeinateLidClosed
    }

    /// On battery, Caffeinate ends once the charge is at or below this percentage (0: never).
    var caffeinateBatteryFloor: Int {
        let stored = defaults.object(forKey: PreferenceKey.caffeinateBatteryFloor) as? Int ?? Self.defaultCaffeinateBatteryFloor
        return min(max(stored, 0), 50)
    }

    /// How long Sweep keeps the keyboard and trackpad locked.
    var sweepDuration: SweepDuration {
        SweepDuration.stored(defaults.object(forKey: PreferenceKey.sweepDuration) as? Int)
    }

    static let defaultHushAutomatically = true

    /// Whether Hush holds notifications back whenever the screen is shared.
    var hushAutomatically: Bool {
        defaults.object(forKey: PreferenceKey.hushAutomatically) as? Bool ?? Self.defaultHushAutomatically
    }

    func isModuleEnabled(_ module: ModuleID) -> Bool {
        defaults.object(forKey: PreferenceKey.moduleEnabled(module)) as? Bool
            ?? Self.defaultModuleEnabled
    }
}
