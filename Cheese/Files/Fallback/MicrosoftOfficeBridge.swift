import Foundation

/// Office → PDF by asking Word, Excel or PowerPoint to save as PDF over AppleScript. macOS asks
/// once per app for Automation permission, and the app may open visibly while it works.
enum MicrosoftOfficeBridge {
    static let timeout = Duration.seconds(120)

    /// Office is sandboxed, so it saves into its own container, where Cheese can pick the file up.
    static func exportFolder(for app: NativeOfficeApp) -> URL {
        URL.homeDirectory.appending(path: "Library/Containers/\(app.rawValue)/Data/tmp/CheeseExport", directoryHint: .isDirectory)
    }

    static func convert(_ input: URL, kind: OfficeRenderer.Kind, to output: URL) async throws {
        let app = NativeOfficeApp.microsoft(for: kind)
        let folder = exportFolder(for: app)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exported = folder.appending(path: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: exported) }

        let status = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/osascript"), arguments: ["-e", script(for: kind, input: input, output: exported)],
            timeout: timeout, name: app.name
        )
        guard status == 0, FileManager.default.fileExists(atPath: exported.path(percentEncoded: false)) else {
            throw FileToolError.message("\(app.name) couldn't save \(input.lastPathComponent) as PDF.")
        }
        try FileManager.default.moveItem(at: exported, to: output)
    }

    /// The AppleScript that opens the document, saves it as PDF and closes it without saving.
    static func script(for kind: OfficeRenderer.Kind, input: URL, output: URL) -> String {
        let source = quoted(input.path(percentEncoded: false))
        let destination = quoted(output.path(percentEncoded: false))
        switch kind {
        case .word:
            return """
            tell application id "com.microsoft.Word"
                open (POSIX file \(source))
                set theDocument to active document
                save as theDocument file name (POSIX file \(destination) as text) file format format PDF
                close theDocument saving no
            end tell
            """
        case .excel:
            return """
            tell application id "com.microsoft.Excel"
                open (POSIX file \(source))
                set theWorkbook to active workbook
                save workbook as theWorkbook filename (POSIX file \(destination) as text) file format PDF file format
                close theWorkbook saving no
            end tell
            """
        case .powerPoint:
            return """
            tell application id "com.microsoft.Powerpoint"
                open (POSIX file \(source))
                set thePresentation to active presentation
                save thePresentation in (POSIX file \(destination)) as save as PDF
                close thePresentation saving no
            end tell
            """
        }
    }

    /// An AppleScript string literal: backslashes and quotes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
}
