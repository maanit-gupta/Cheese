import CryptoKit
import Foundation

enum ReceiveError: LocalizedError, Equatable {
    case tooLarge
    case incomplete
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The file is bigger than announced or allowed."
        case .incomplete: "The file didn't arrive whole."
        case .checksumMismatch: "The file's checksum didn't match."
        }
    }
}

/// Streams an incoming request body to disk: into a hidden partial file in the destination folder,
/// then, once it's whole (and its checksum matches, if one was given), to a safe, unused name there.
/// Never writes outside the destination, and never overwrites.
enum ReceivedFileWriter {
    /// A hidden temp file in `folder`, on the same volume so finishing is a rename.
    static func partialURL(in folder: URL) -> URL {
        folder.appending(path: ".cheese-\(UUID().uuidString).partial", directoryHint: .notDirectory)
    }

    /// Writes the body to `partial`. `expectedSize` (when known) must match exactly; `maxSize` is a
    /// hard cap. `touch` runs every few MB so stalled-transfer timers see progress.
    @concurrent
    static func write(
        _ body: HTTPRequestBody,
        to partial: URL,
        expectedSize: Int64?,
        maxSize: Int64,
        sha256: String?,
        touch: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var hasher = SHA256()
        var written: Int64 = 0
        var lastTouch: Int64 = 0
        let limit = min(expectedSize ?? maxSize, maxSize)
        if let declared = body.declaredLength, declared > limit {
            throw ReceiveError.tooLarge
        }
        while let piece = try await body.next() {
            written += Int64(piece.count)
            guard written <= limit else { throw ReceiveError.tooLarge }
            try handle.write(contentsOf: piece)
            if sha256 != nil {
                hasher.update(data: piece)
            }
            if written - lastTouch >= 8 << 20 {
                lastTouch = written
                await touch(written)
            }
        }
        if let expectedSize, written != expectedSize {
            throw ReceiveError.incomplete
        }
        if let sha256, !sha256.isEmpty {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(sha256) == .orderedSame else { throw ReceiveError.checksumMismatch }
        }
    }

    /// Moves a finished partial file to its final, sanitized, unused name in `folder`.
    static func finish(_ partial: URL, named name: String, in folder: URL) throws -> URL {
        let destination = FilenameSanitizer.destination(for: name, in: folder) {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }
}
