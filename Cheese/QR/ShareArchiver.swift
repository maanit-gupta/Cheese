import Foundation

enum ShareArchiveError: LocalizedError {
    case zipFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .zipFailed(status): "Zipping the files failed (ditto exited with \(status))."
        }
    }
}

/// Zips several files, or a folder, into a temp file for sharing.
enum ShareArchiver {
    struct Archive: Sendable {
        var zip: URL
        /// The temp folder holding the zip; delete it when the share ends.
        var temporaryFolder: URL
    }

    /// A folder keeps its name (`Photos.zip`); several items go into `Files.zip`.
    @concurrent
    static func archive(_ urls: [URL]) async throws -> Archive {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: "CheeseShare-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let source: URL
            if urls.count == 1, let only = urls.first {
                source = only
            } else {
                // Copies are APFS clones, so this is cheap even for big files.
                source = folder.appending(path: "Files", directoryHint: .isDirectory)
                try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
                for url in urls {
                    try fileManager.copyItem(at: url, to: source.appending(path: url.lastPathComponent))
                }
            }
            let zip = folder.appending(path: source.lastPathComponent + ".zip", directoryHint: .notDirectory)
            try await runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", source.path(percentEncoded: false), zip.path(percentEncoded: false)])
            return Archive(zip: zip, temporaryFolder: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private static func runDitto(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw ShareArchiveError.zipFailed(status: status) }
    }
}
