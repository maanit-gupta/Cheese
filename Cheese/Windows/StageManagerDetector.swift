import Foundation

/// Reads whether Stage Manager is on, whether its strip hides, and where the Dock is, from the
/// system's own preferences (`com.apple.WindowManager`, `com.apple.dock`).
enum StageManagerDetector {
    static let windowManagerDomain = "com.apple.WindowManager"
    static let dockDomain = "com.apple.dock"

    /// Reads fresh each time, so a change in System Settings applies to the next fill.
    static func current() -> StageManagerState {
        state(windowManager: UserDefaults(suiteName: windowManagerDomain), dock: UserDefaults(suiteName: dockDomain))
    }

    static func state(windowManager: UserDefaults?, dock: UserDefaults?) -> StageManagerState {
        StageManagerState(
            isEnabled: windowManager?.object(forKey: "GloballyEnabled") as? Bool ?? false,
            stripAutoHides: windowManager?.object(forKey: "AutoHide") as? Bool ?? false,
            dockOrientation: dock?.string(forKey: "orientation").flatMap(DockOrientation.init(rawValue:)) ?? .bottom
        )
    }
}

extension FillLayout {
    /// The layout for the next fill, from Settings → Windows and the current Stage Manager state.
    static func current(preferences: Preferences = Preferences()) -> FillLayout {
        StageManagerLayout.layout(
            mode: preferences.windowFillMode,
            stageManager: StageManagerDetector.current(),
            configuredInset: preferences.stageManagerStripInset
        )
    }
}
