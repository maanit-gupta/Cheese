import Foundation

/// The last command in a terminal and what it printed, trimmed for pasting into a chat or an issue.
struct TerminalTrace: Equatable, Sendable {
    /// The prompt line the command was typed on, when one was found.
    var command: String?
    /// What it printed, at most the parser's line limit (the newest lines are kept).
    var output: [String]
    /// Output lines dropped from the top to stay under the limit.
    var omittedLineCount: Int
    /// Lines that look like errors, from all of the command's output, not just what was kept.
    var errorLines: [String]

    /// Lines in the copied trace: the command plus the output that was kept.
    var lineCount: Int { (command == nil ? 0 : 1) + output.count }
}

/// How much of the terminal Terminal Trace copies.
enum TerminalTraceScope: String, CaseIterable, Sendable {
    /// The last command and what it printed.
    case lastResponse
    /// Everything the terminal has: the whole scrollback where the app exposes it.
    case everything

    var title: String {
        switch self {
        case .lastResponse: "Last Response"
        case .everything: "Everything"
        }
    }

    var symbol: String {
        switch self {
        case .lastResponse: "text.line.last.and.arrowtriangle.forward"
        case .everything: "text.justify.left"
        }
    }
}

/// Finds the last command in a terminal buffer, its output and its errors, and formats them as
/// Markdown. Pure, so prompt detection and slicing are unit-tested without a terminal.
enum TerminalTraceParser {
    static let defaultMaxLines = 120
    static let maxErrorLines = 40
    /// Below this many output lines the errors are easy to spot, so they aren't repeated.
    static let errorSectionThreshold = 30

    /// The trace for `scope`, or nil when the buffer has no text.
    static func extract(from buffer: String, scope: TerminalTraceScope) -> TerminalTrace? {
        switch scope {
        case .lastResponse: extract(from: buffer)
        case .everything: extractAll(from: buffer)
        }
    }

    /// Every line in the buffer, uncut, minus the empty prompt waiting at the bottom. Errors aren't
    /// pulled out: the whole thing is the point.
    static func extractAll(from buffer: String) -> TerminalTrace? {
        var lines = cleanLines(buffer)
        guard !lines.isEmpty else { return nil }
        if lines.count > 1, let last = lines.last, isPrompt(last), isBarePrompt(last) { lines.removeLast() }
        return TerminalTrace(command: nil, output: lines, omittedLineCount: 0, errorLines: [])
    }

    /// The last command and its output, or nil when the buffer has no text.
    static func extract(from buffer: String, maxLines: Int = defaultMaxLines) -> TerminalTrace? {
        let lines = cleanLines(buffer)
        guard !lines.isEmpty else { return nil }

        // The last line is usually the prompt waiting for the next command: not part of the trace.
        var end = lines.count
        if end > 1, isPrompt(lines[end - 1]) { end -= 1 }

        let prompts = lines[..<end].indices.filter { isPrompt(lines[$0]) }
        var start = prompts.last
        // A command with no output (just `clear`, say) tells nothing; show the one before it too.
        if let last = start, last == end - 1, prompts.count > 1 {
            start = prompts[prompts.count - 2]
        }

        let command: String?
        var output: [String]
        if let start {
            command = lines[start]
            output = Array(lines[(start + 1)..<end])
        } else {
            command = nil
            output = Array(lines[..<end])
        }

        let errors = output.filter(isErrorLine).prefix(maxErrorLines)
        let room = max(1, maxLines - (command == nil ? 0 : 1))
        let omitted = max(0, output.count - room)
        output.removeFirst(omitted)
        // Blank lines at the top of what's left only push the content down.
        var trimmedTop = 0
        while output.count > 1, output.first?.isEmpty == true {
            output.removeFirst()
            trimmedTop += 1
        }
        return TerminalTrace(
            command: command, output: output,
            omittedLineCount: omitted == 0 ? 0 : omitted + trimmedTop,
            errorLines: Array(errors)
        )
    }

    /// The trace as an LLM-ready Markdown block, with a separate Errors block when the output is
    /// long enough that they'd be hard to find.
    static func markdown(for trace: TerminalTrace, appName: String, timestamp: String) -> String {
        var body: [String] = []
        if let command = trace.command { body.append(command) }
        if trace.omittedLineCount > 0 {
            body.append("… \(trace.omittedLineCount) earlier line\(trace.omittedLineCount == 1 ? "" : "s") omitted …")
        }
        body += trace.output

        var text = "### Terminal Trace (\(appName) — \(timestamp))\n"
        text += fenced(body)
        let showErrors = !trace.errorLines.isEmpty
            && (trace.omittedLineCount > 0 || trace.output.count > errorSectionThreshold)
        if showErrors {
            text += "\n#### Errors\n" + fenced(trace.errorLines)
        }
        return text
    }

    /// The buffer's lines without color codes, trailing spaces, or blank lines at either end.
    private static func cleanLines(_ buffer: String) -> [String] {
        var lines = stripANSI(buffer)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0).trimmingTrailingWhitespace() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines
    }

    /// A prompt with nothing typed after its marker: `user@mac ~ %`, `❯`.
    private static func isBarePrompt(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return last == "$" || last == "%" || symbolMarkers.contains(last)
    }

    // MARK: - Prompts

    /// Whether a line looks like a shell prompt: `user@mac ~ % make`, `bash-3.2$ ls`, `❯ swift build`,
    /// `➜  Cheese git:(main) npm test`, or a bare prompt waiting for input.
    static func isPrompt(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        guard !trimmed.isEmpty else { return false }

        // Symbol prompts from zsh themes and starship sit at the start of the line.
        if let first = trimmed.first, symbolMarkers.contains(first) {
            let rest = trimmed.dropFirst()
            return rest.isEmpty || rest.first?.isWhitespace == true
        }

        // `$` and `%` end a prefix like `user@host dir`; the first one decides.
        let window = trimmed.prefix(maxPromptPrefix)
        guard let index = window.firstIndex(where: { $0 == "$" || $0 == "%" }) else { return false }
        let marker = window[index]
        let after = window.index(after: index)
        // The marker has to end the prefix: followed by a space or the end of the line.
        if after < trimmed.endIndex, !trimmed[after].isWhitespace { return false }
        // `45 %` and `100%` are progress, not prompts.
        if marker == "%", trimmed[..<index].trimmingCharacters(in: .whitespaces).last?.isNumber == true {
            return false
        }
        return true
    }

    private static let symbolMarkers: Set<Character> = ["❯", "➜", "λ"]
    /// How far into a line a `$` or `%` prompt marker may sit.
    private static let maxPromptPrefix = 80

    // MARK: - Errors

    /// Whether a line looks like part of an error: compiler diagnostics, tracebacks, npm, git, Go, Rust.
    static func isErrorLine(_ line: String) -> Bool {
        if caseSensitiveErrorMarkers.contains(where: line.contains) { return true }
        let lowered = line.lowercased()
        return errorMarkers.contains(where: lowered.contains)
    }

    private static let caseSensitiveErrorMarkers = ["FAILED", "FAIL ", "ERROR", "Traceback", "Exception"]
    private static let errorMarkers = [
        "error:", "error[", "npm err!", "fatal:", "panic:", "exit code", "exit status",
        "segmentation fault", "command not found", "no such file or directory",
        "permission denied", "failed with", "undefined reference", "cannot find",
    ]

    // MARK: - Formatting

    /// A ```text block whose fence is longer than any run of backticks inside it, so output that
    /// itself contains Markdown can't close it early.
    private static func fenced(_ lines: [String]) -> String {
        let body = lines.joined(separator: "\n")
        var longest = 0
        var run = 0
        for character in body {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)text\n\(body)\n\(fence)\n"
    }

    /// Removes terminal color and cursor escape sequences (`ESC [ … letter`).
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}" else {
                result.append(character)
                continue
            }
            // CSI: ESC [ parameters final-byte. Anything else: drop ESC and the next character.
            guard let next = iterator.next(), next == "[" else { continue }
            while let code = iterator.next() {
                if let ascii = code.asciiValue, (0x40...0x7E).contains(ascii) { break }
            }
        }
        return result
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self
        while copy.last?.isWhitespace == true { copy.removeLast() }
        return copy
    }
}
