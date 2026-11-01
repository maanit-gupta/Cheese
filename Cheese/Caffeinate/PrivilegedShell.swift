import Foundation

/// Running shell commands, with or without one administrator prompt, and the quoting that needs.
/// The quoting and output parsing are pure and unit-tested.
enum PrivilegedShell {
    struct Result: Sendable, Equatable {
        let status: Int32
        let output: String
    }

    static let pmset = "/usr/bin/pmset"

    /// `text` as one single-quoted shell word.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `text` as an AppleScript string literal.
    static func appleScriptQuoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// `do shell script … with administrator privileges`, for `osascript -e`.
    static func appleScript(running script: String, prompt: String) -> String {
        "do shell script \(appleScriptQuoted(script)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
    }

    /// Whether `pmset -g` says lid-close sleep is disabled (`SleepDisabled 1`).
    static func isSleepDisabled(pmsetOutput: String) -> Bool {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "SleepDisabled" {
                return fields.last == "1"
            }
        }
        return false
    }

    /// Whether osascript failed because the user dismissed the password prompt (error -128).
    static func isUserCancelled(osascriptError: String) -> Bool {
        osascriptError.contains("(-128)")
    }

    /// Whether lid-close sleep is disabled right now.
    static func isSleepDisabled() async -> Bool {
        let result = await run(pmset, ["-g"])
        return result.status == 0 && isSleepDisabled(pmsetOutput: result.output)
    }

    /// Runs `script` as root behind one administrator prompt showing `prompt`.
    static func runPrivileged(_ script: String, prompt: String) async -> Result {
        await run("/usr/bin/osascript", ["-e", appleScript(running: script, prompt: prompt)])
    }

    /// Runs a command without blocking, collecting its output in a temporary file rather than a
    /// pipe, which a process it leaves behind could hold open for ever.
    nonisolated static func run(_ executable: String, _ arguments: [String]) async -> Result {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cheese-shell-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL)
        else {
            return Result(status: -1, output: "Couldn't create a temporary file")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                try? output.close()
                let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(returning: Result(status: finished.terminationStatus, output: text))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? output.close()
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
            }
        }
    }
}
