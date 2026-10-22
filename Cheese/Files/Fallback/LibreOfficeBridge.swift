import Foundation

/// Office → PDF with LibreOffice's headless converter.
enum LibreOfficeBridge {
    static let timeout = Duration.seconds(120)

    /// `soffice --headless --convert-to pdf --outdir <tmp> <file>`, with a throwaway profile so it
    /// works even while LibreOffice is open (a running instance would otherwise swallow the request).
    static func arguments(input: URL, outputFolder: URL, profile: URL) -> [String] {
        [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--norestore",
            "--convert-to", "pdf",
            "--outdir", outputFolder.path(percentEncoded: false),
            input.path(percentEncoded: false),
        ]
    }

    static func convert(_ input: URL, soffice: URL, to output: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "CheeseLibreOffice-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outputFolder = work.appending(path: "out", directoryHint: .isDirectory)
        let profile = work.appending(path: "profile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let status = try await ProcessRunner.run(
            soffice, arguments: arguments(input: input, outputFolder: outputFolder, profile: profile),
            timeout: timeout, name: "LibreOffice"
        )
        let converted = outputFolder.appending(path: input.deletingPathExtension().lastPathComponent + ".pdf")
        guard status == 0, FileManager.default.fileExists(atPath: converted.path(percentEncoded: false)) else {
            throw FileToolError.message("LibreOffice couldn't convert \(input.lastPathComponent).")
        }
        try FileManager.default.moveItem(at: converted, to: output)
    }
}
