/// The terminals Terminal Trace knows how to read, in the order it looks for them when none is frontmost.
enum TerminalApp: String, CaseIterable, Sendable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case warp = "dev.warp.Warp-Stable"
    case alacritty = "org.alacritty"
    case kitty = "net.kovidgoyal.kitty"
    case wezTerm = "com.github.wez.wezterm"
    case vsCode = "com.microsoft.VSCode"
    case cursor = "com.todesktop.230313mzl4w4u92"

    var bundleID: String { rawValue }

    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .alacritty: "Alacritty"
        case .kitty: "kitty"
        case .wezTerm: "WezTerm"
        case .vsCode: "VS Code"
        case .cursor: "Cursor"
        }
    }

    /// AppleScript that returns the front tab's text, for terminals that have a scripting dictionary.
    var scriptSource: String? {
        switch self {
        case .terminal:
            // `history` is the whole scrollback; `contents` is what's on screen.
            """
            tell application id "com.apple.Terminal"
                try
                    return history of selected tab of front window
                on error
                    return contents of selected tab of front window
                end try
            end tell
            """
        case .iTerm:
            """
            tell application id "com.googlecode.iterm2"
                tell current session of current window to return contents
            end tell
            """
        default:
            nil
        }
    }

    /// Electron apps only build their accessibility tree when asked to.
    var isElectron: Bool {
        self == .vsCode || self == .cursor
    }

    /// The terminal to read: the app the user was just in if it's a terminal, otherwise the first
    /// running one in `allCases` order.
    static func choose(frontmost: String?, running: [String]) -> TerminalApp? {
        if let frontmost, let app = TerminalApp(rawValue: frontmost) { return app }
        let runningSet = Set(running)
        return allCases.first { runningSet.contains($0.bundleID) }
    }
}
