import Foundation
import os

/// The files selected in Finder, read over AppleScript. The first use asks for Automation
/// permission for Finder; if it's refused there's no selection.
@MainActor
enum FinderSelection {
    nonisolated static let finderBundleID = "com.apple.finder"

    private static let source = """
    tell application id "com.apple.finder"
        set out to ""
        repeat with anItem in (get selection as alias list)
            set out to out & POSIX path of anItem & linefeed
        end repeat
        return out
    end tell
    """

    /// Selected files and folders, or nil when Finder couldn't be asked.
    static func selectedFiles() -> [URL]? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Logger.files.info("Finder selection unavailable: \(String(describing: error[NSAppleScript.errorNumber]), privacy: .public)")
            return nil
        }
        return paths(from: result.stringValue ?? "")
    }

    /// One POSIX path per line → file URLs (folders keep their trailing slash).
    nonisolated static func paths(from text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline).map { line in
            let path = String(line)
            return URL(filePath: path, directoryHint: path.hasSuffix("/") ? .isDirectory : .notDirectory)
        }
    }

    /// The files in a selection that a tool takes, when they're enough for it to run.
    nonisolated static func usable(_ files: [URL], for tool: ToolID) -> [URL]? {
        let accepted = files.filter { tool.acceptedKinds.contains(FileKind(url: $0)) }
        return ToolApplicability.applies(tool, to: accepted) ? accepted : nil
    }
}
