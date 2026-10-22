import Foundation

/// What's on the clipboard, as far as the QR feature cares.
enum QRSource: Equatable, Sendable {
    case empty
    case text(String)
    /// Formatted text; shared as its plain text, since a phone can't do much with RTF.
    case richText(String)
    case image(png: Data)
    case files([URL])
}

/// Something served over a local Wi-Fi share link.
enum ShareContent: Equatable, Sendable {
    case text(String)
    case image(png: Data)
    /// One file, sent as a download.
    case file(URL)
    /// Several files or a folder, zipped before sharing.
    case archive([URL])
}

enum QRPlan: Equatable, Sendable {
    case empty
    /// Short enough to put in the QR code itself.
    case direct(String)
    /// Too big or not text: the QR code holds a local share link instead.
    case share(ShareContent)
}

/// Decides between encoding the clipboard directly and sharing it over Wi-Fi.
enum QRPayloadPlanner {
    /// Byte-mode capacity of the largest QR code (version 40) at error correction level M.
    static let maxDirectBytes = 2_331

    /// - Parameter isDirectory: whether a file URL is a folder; folders are always zipped.
    static func plan(for source: QRSource, isDirectory: (URL) -> Bool) -> QRPlan {
        switch source {
        case .empty:
            return .empty
        case let .text(text):
            guard text.contains(where: { !$0.isWhitespace }) else { return .empty }
            return text.utf8.count <= maxDirectBytes ? .direct(text) : .share(.text(text))
        case let .richText(text):
            guard text.contains(where: { !$0.isWhitespace }) else { return .empty }
            return .share(.text(text))
        case let .image(png):
            return .share(.image(png: png))
        case let .files(urls):
            guard let first = urls.first else { return .empty }
            if urls.count == 1, !isDirectory(first) {
                return .share(.file(first))
            }
            return .share(.archive(urls))
        }
    }
}
