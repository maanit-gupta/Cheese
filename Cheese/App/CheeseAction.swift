import AppKit
import KeyboardShortcuts

/// Stable identity of an action, used by the menu layout and (later) palette recency.
struct ActionID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ActionID {
    static let openHistory = Self(rawValue: "openHistory")
    static let clearHistory = Self(rawValue: "clearHistory")
    static let clearAll = Self(rawValue: "clearAll")
    static let captureRegion = Self(rawValue: "captureRegion")
    static let captureWindow = Self(rawValue: "captureWindow")
    static let captureFullScreen = Self(rawValue: "captureFullScreen")
    static let ocrRegion = Self(rawValue: "ocrRegion")
    static let scrollingCapture = Self(rawValue: "scrollingCapture")
    static let snapLeft = Self(rawValue: "snapLeft")
    static let snapRight = Self(rawValue: "snapRight")
    static let maximize = Self(rawValue: "maximize")
    static let snapBottom = Self(rawValue: "snapBottom")
    static let restoreWindow = Self(rawValue: "restoreWindow")
    static let editShortcuts = Self(rawValue: "editShortcuts")
    static let openSettings = Self(rawValue: "openSettings")
    static let showWelcome = Self(rawValue: "showWelcome")
    static let about = Self(rawValue: "about")
    static let quit = Self(rawValue: "quit")
    static let keepAwakeIndefinitely = Self(rawValue: "keepAwakeIndefinitely")
    static let keepAwakeUntil = Self(rawValue: "keepAwakeUntil")
    static let keepAwakeOff = Self(rawValue: "keepAwakeOff")
    static let showClipboardQR = Self(rawValue: "showClipboardQR")
    static let commandPalette = Self(rawValue: "commandPalette")
    static let drawOnScreen = Self(rawValue: "drawOnScreen")
    static let settingsGeneral = Self(rawValue: "settingsGeneral")
    static let settingsShortcuts = Self(rawValue: "settingsShortcuts")
    static let settingsClipboard = Self(rawValue: "settingsClipboard")
    static let settingsOCR = Self(rawValue: "settingsOCR")
    static let settingsAppHotkeys = Self(rawValue: "settingsAppHotkeys")
    static let settingsPermissions = Self(rawValue: "settingsPermissions")
    static let settingsFiles = Self(rawValue: "settingsFiles")
    static let settingsAbout = Self(rawValue: "settingsAbout")
    static let settingsShare = Self(rawValue: "settingsShare")
    static let toggleShelf = Self(rawValue: "toggleShelf")
    static let clearShelf = Self(rawValue: "clearShelf")
    static let showShare = Self(rawValue: "showShare")
    static let sendClipboard = Self(rawValue: "sendClipboard")
    static let autoKillPanel = Self(rawValue: "autoKillPanel")
    static let killAllApps = Self(rawValue: "killAllApps")
    static let killBackgroundApps = Self(rawValue: "killBackgroundApps")
    static let forceKillAllApps = Self(rawValue: "forceKillAllApps")
    static let settingsAutoKill = Self(rawValue: "settingsAutoKill")
    static let fillAllWindows = Self(rawValue: "fillAllWindows")
    static let fillCurrentWindow = Self(rawValue: "fillCurrentWindow")
    static let restoreAllWindows = Self(rawValue: "restoreAllWindows")
    static let settingsWindows = Self(rawValue: "settingsWindows")

    /// "After Capture: Copy to Clipboard" and the other capture destinations.
    static func captureDestination(_ destination: CaptureDestination) -> Self {
        Self(rawValue: "captureDestination.\(destination.rawValue)")
    }

    /// "Files: Merge PDFs…" and the other Files tools.
    static func files(_ tool: ToolID) -> Self {
        Self(rawValue: "files.\(tool.rawValue)")
    }
}

/// Where an action was launched from.
struct ActionContext {
    /// The app the user was in before any Cheese UI opened: where pastes and snaps go.
    /// Nil when that was Cheese itself.
    var previousApp: NSRunningApplication?

    /// The context right now. Cheese's menu and hotkeys don't activate Cheese, so the
    /// frontmost app is still the one the user was working in.
    @MainActor
    static func current() -> ActionContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isCheese = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        return ActionContext(previousApp: isCheese ? nil : frontmost)
    }
}

/// One thing the user can trigger. The menu bar menu, global hotkeys and the command palette
/// all read these from `ActionRegistry`; each is defined once, by the module that owns it.
@MainActor
struct CheeseAction: Identifiable {
    let id: ActionID
    let title: String
    /// SF Symbol name.
    let symbol: String
    /// Nil for app-level actions (Settings, Quit) that can't be switched off.
    let module: ModuleID?
    /// How the command palette lists it, when that differs from the menu ("Show Shelf" for "Shelf").
    var paletteTitle: String?
    /// A shorter title for inside a submenu, where the parent names the feature ("Until…" under Keep Awake).
    var menuTitle: String?
    var shortcut: KeyboardShortcuts.Name?
    /// Extra bindings that also run the action but aren't shown, like Shift + the full-screen shortcut.
    var hiddenShortcuts: [KeyboardShortcuts.Name] = []
    /// Permissions the action can't run without; the registry explains what's missing instead of running it.
    var requiredPermissions: [Permission] = []
    /// How permission alerts name the feature ("Window snapping needs Accessibility access"); defaults to the title.
    var featureName: String?
    /// Beyond its module being on, whether the action can run right now.
    var precondition: @MainActor () -> Bool = { true }
    /// For a choice among options: whether this one is current, shown as a checkmark in the menu.
    var isChecked: (@MainActor () -> Bool)?
    /// Listed in the command palette. Draw mode isn't: it's entered from its hotkey or the menu bar.
    var showsInPalette = true
    /// Gets the hotkey's presses and releases instead of `perform` running on each press,
    /// for actions that tell a tap from a hold.
    var hotkeyHandler: (@MainActor (KeyboardShortcuts.EventType) -> Void)?
    let perform: @MainActor (ActionContext) -> Void

    var alertName: String { featureName ?? title }
}
