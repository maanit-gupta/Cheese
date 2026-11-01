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
              let app = running.first(where: { $0.bundleIdentifier == terminal.bundleID }) else {
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
            buffer = await readAccessibility(pid: app.processIdentifier, electron: terminal.isElectron)
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

    // MARK: - Accessibility

    /// How many elements to visit looking for the terminal's text, so a huge window can't stall Cheese.
    private static let maxVisitedElements = 4000

    private func readAccessibility(pid: pid_t, electron: Bool) async -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        if electron {
            // The tree is built on request and takes a moment the first time.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if let text = accessibilityText(of: app) { return text }
        guard electron else { return nil }
        try? await Task.sleep(for: .milliseconds(400))
        return accessibilityText(of: app)
    }

    /// The selection if there is one, else the focused element's text, else the longest text area
    /// in the focused window.
    private func accessibilityText(of app: AXUIElement) -> String? {
        if let focused = element(kAXFocusedUIElementAttribute, of: app) {
            if let selected = string(kAXSelectedTextAttribute, of: focused), !selected.isBlank { return selected }
            if let value = string(kAXValueAttribute, of: focused), !value.isBlank { return value }
            // xterm.js (VS Code, Cursor) keeps each row in its own static text.
            if let rows = staticText(under: focused), !rows.isBlank { return rows }
        }
        guard let window = element(kAXFocusedWindowAttribute, of: app) else { return nil }
        var longest: String?
        visit(window) { element in
            guard string(kAXRoleAttribute, of: element) == kAXTextAreaRole,
                  let value = string(kAXValueAttribute, of: element), !value.isBlank else { return }
            if value.count > (longest?.count ?? 0) { longest = value }
        }
        return longest
    }

    private func staticText(under root: AXUIElement) -> String? {
        var rows: [String] = []
        visit(root) { element in
            guard string(kAXRoleAttribute, of: element) == kAXStaticTextRole,
                  let value = string(kAXValueAttribute, of: element) else { return }
            rows.append(value)
        }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    /// Breadth-first over `root` and its descendants, up to `maxVisitedElements`.
    private func visit(_ root: AXUIElement, _ body: (AXUIElement) -> Void) {
        var queue = [root]
        var index = 0
        while index < queue.count, index < Self.maxVisitedElements {
            let element = queue[index]
            index += 1
            body(element)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
               let children = value as? [AXUIElement] {
                queue += children
            }
        }
    }

    private func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

private extension String {
    var isBlank: Bool {
        allSatisfy(\.isWhitespace)
    }
}
