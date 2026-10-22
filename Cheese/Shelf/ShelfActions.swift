import AppKit
import Foundation

/// The shelf toolbar's file actions: zip and copy paths. Quick Look, Send and Files tools are wired in
/// `ShelfPanel` and `App/`.
enum ShelfActions {
    /// Newline-separated POSIX paths, in shelf order.
    static func pathsText(_ urls: [URL]) -> String {
        urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
    }

    @MainActor
    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathsText(urls), forType: .string)
    }

    /// One item keeps its name (`Report.zip`); several make `Archive.zip`, like Finder's Compress.
    static func zipName(for urls: [URL]) -> String {
        guard urls.count == 1, let only = urls.first else { return "Archive.zip" }
        return OutputNamer.fileName(base: OutputNamer.baseName(of: only), suffix: nil, extension: "zip")
    }

    /// Zips `urls` into `folder` (Downloads), never overwriting, and returns the zip.
    @concurrent
    static func zip(_ urls: [URL], into folder: URL = .downloadsDirectory) async throws -> URL {
        let archive = try await ShareArchiver.archive(urls)
        defer { try? FileManager.default.removeItem(at: archive.temporaryFolder) }
        let destination = OutputNamer.uniqueFile(named: zipName(for: urls), in: folder) {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        try FileManager.default.moveItem(at: archive.zip, to: destination)
        return destination
    }
}
