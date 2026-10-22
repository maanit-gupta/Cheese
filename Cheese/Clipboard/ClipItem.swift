import Foundation
import SwiftData
import os

/// One clipboard history entry. Image pixels live on disk (see `ClipImageStorage`); files are kept as URLs.
@Model
final class ClipItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool
    var pinnedAt: Date?
    /// Fingerprint from `ClipHasher`, used to move re-copied content to the top instead of duplicating it.
    var contentHash: String
    /// The text for text items; nil for images and files.
    var plainText: String?
    /// Encoded `[PasteboardItemContent]` for text items: every representation, for pasting back with formatting.
    @Attribute(.externalStorage) var pasteboardData: Data?
    var imageFileName: String?
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var filePaths: [String]
    /// Text Live Text found in an image item, so search can match it.
    var recognizedText: String?

    init(
        kind: ClipKind,
        contentHash: String,
        plainText: String? = nil,
        pasteboardItems: [PasteboardItemContent] = [],
        image: StoredImage? = nil,
        files: [URL] = [],
        date: Date = .now
    ) {
        id = UUID()
        kindRaw = kind.rawValue
        createdAt = date
        lastCopiedAt = date
        isPinned = false
        self.contentHash = contentHash
        self.plainText = plainText
        pasteboardData = Self.encode(pasteboardItems)
        imageFileName = image?.fileName
        imagePixelWidth = image?.pixelWidth
        imagePixelHeight = image?.pixelHeight
        filePaths = files.map { $0.path(percentEncoded: false) }
    }

    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

    var fileURLs: [URL] { filePaths.map { URL(filePath: $0) } }

    var pasteboardItems: [PasteboardItemContent] {
        get {
            guard let pasteboardData else { return [] }
            do {
                return try PropertyListDecoder().decode([PasteboardItemContent].self, from: pasteboardData)
            } catch {
                Logger.clipboard.error("Couldn't decode stored pasteboard data: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
        set { pasteboardData = Self.encode(newValue) }
    }

    /// One-line summary for the history list.
    var title: String {
        switch kind {
        case .text, .richText:
            let line = plainText?
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return String((line ?? "").prefix(200))
        case .image:
            if let imagePixelWidth, let imagePixelHeight {
                return "Image \(imagePixelWidth) × \(imagePixelHeight)"
            }
            return "Image"
        case .files:
            if filePaths.count == 1, let path = filePaths.first {
                return URL(filePath: path).lastPathComponent
            }
            return "\(filePaths.count) files"
        }
    }

    /// Everything the search field matches against.
    var searchText: String {
        switch kind {
        case .text, .richText: plainText ?? ""
        case .image: [title, recognizedText ?? ""].joined(separator: "\n")
        case .files: filePaths.joined(separator: "\n")
        }
    }

    var retentionCandidate: RetentionCandidate {
        RetentionCandidate(id: id, isPinned: isPinned, lastCopiedAt: lastCopiedAt)
    }

    private static func encode(_ items: [PasteboardItemContent]) -> Data? {
        guard !items.isEmpty else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(items)
        } catch {
            Logger.clipboard.error("Couldn't encode pasteboard data: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
