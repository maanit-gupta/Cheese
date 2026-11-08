import AppKit
import ApplicationServices
import os

/// Terminal Trace: reads the active terminal's text, keeps the last command and its output (or all
/// of it), and copies it as Markdown. Terminal and iTerm2 are read over AppleScript (Automation permission);
/// everything else, and those two when AppleScript fails, through Accessibility.
@MainActor
final class TerminalTraceService {
    /// Shows the Accessibility alert, for terminals that can only be read through it.
    private let askForAccessibility: @MainActor () -> Void
    private var isRunning = false

    init(askForAccessibility: @escaping @MainActor () -> Void) {
        self.askForAccessibility = askForAccessibility
    }

    func copyTrace(previousApp: NSRunningApplication?, scope: TerminalTraceScope) {
        guard !isRunning else { return }
        let running = NSWorkspace.shared.runningApplications
        let choice = TerminalApp.choose(
            frontmost: previousApp?.bundleIdentifier,
            running: running.compactMap(\.bundleIdentifier)
        )
        guard let terminal = choice,
              let app = running.first(where: { $0.bundleIdentifier.flatMap(TerminalApp.init(bundleID:)) == terminal }) else {
            CheeseToast.show("No terminal app is open", systemImage: "terminal")
            return
        }
        isRunning = true
        Task {
            defer { isRunning = false }
            await readAndCopy(from: terminal, app: app, scope: scope)
        }
    }

    private func readAndCopy(from terminal: TerminalApp, app: NSRunningApplication, scope: TerminalTraceScope) async {
        var automationDenied = false
        var buffer: String?
        if let source = terminal.scriptSource {
            switch runScript(source) {
            case let .success(text): buffer = text
            case let .failure(code): automationDenied = code == Self.automationDeniedCode
            }
        }
        if buffer?.isBlank ?? true {
            guard AXIsProcessTrusted() else {
                if automationDenied {
                    showAutomationHint(for: terminal)
                } else {
                    askForAccessibility()
                }
                return
            }
            let inspector = TerminalTreeInspector(pid: app.processIdentifier, kind: terminal.kind)
            buffer = await inspector.snapshotAllowingTreeBuild().text
        }

        guard let buffer, let trace = TerminalTraceParser.extract(from: buffer, scope: scope) else {
            if automationDenied {
                showAutomationHint(for: terminal)
            } else {
                CheeseToast.show("Couldn't read any text from \(terminal.name)", systemImage: "exclamationmark.triangle.fill")
            }
            return
        }

        let timestamp = Date.now.formatted(date: .abbreviated, time: .standard)
        let markdown = TerminalTraceParser.markdown(for: trace, appName: terminal.name, timestamp: timestamp)
        // The clipboard poller records this in history like any other copy.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        let lines = trace.lineCount
        Logger.terminalTrace.info("Copied \(lines) lines from \(terminal.name, privacy: .public)")
        CheeseToast.show(
            "Copied \(scope == .everything ? "everything" : "last response") from \(terminal.name) (\(lines) line\(lines == 1 ? "" : "s"))",
            systemImage: "terminal"
        )
    }

    // MARK: - AppleScript

    /// errAEEventNotPermitted: the user said no to Automation for this app.
    private static let automationDeniedCode = -1743

    private enum ScriptResult {
        case success(String)
        case failure(Int)
    }

    private func runScript(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else { return .failure(0) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            Logger.terminalTrace.info("AppleScript failed: \(code)")
            return .failure(code)
        }
        return .success(result.stringValue ?? "")
    }

    private func showAutomationHint(for terminal: TerminalApp) {
        CheeseToast.show(
            "Allow Cheese to control \(terminal.name) in Automation settings",
            systemImage: "exclamationmark.triangle.fill",
            action: .init(title: "Open") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }
}

private extension String {
    var isBlank: Bool {
        allSatisfy(\.isWhitespace)
    }
}
