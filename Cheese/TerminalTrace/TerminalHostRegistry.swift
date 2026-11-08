/// Whether a terminal is its own app or a panel inside an editor.
enum TerminalHostKind: Sendable {
    /// The app is the terminal: whatever has focus in it is terminal text.
    case standalone
    /// An editor with a terminal panel (VS Code, Cursor, Windsurf, Zed): only part of the window is a
    /// terminal, and Electron ones build their accessibility tree only when asked (`AXManualAccessibility`).
    case integrated
}

/// Every app Cheese treats as a terminal host, by bundle ID. Pure; shared by Terminal Trace and the clipboard.
enum TerminalHostRegistry {
    static let standalone: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    static let integrated: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
    ]

    static func kind(of bundleID: String?) -> TerminalHostKind? {
        guard let bundleID else { return nil }
        if standalone.contains(bundleID) { return .standalone }
        if integrated.contains(bundleID) { return .integrated }
        return nil
    }

    static func isTerminalHost(_ bundleID: String?) -> Bool {
        kind(of: bundleID) != nil
    }
}
