import Foundation

/// Something dragged onto the menu bar icon.
enum DropPayload: Equatable, Sendable {
    case files([URL])
    /// Image data with no file behind it, like a picture dragged out of a browser, as PNG.
    case image(png: Data)
    case link(URL)
    case text(String)

    /// What a drag carries, read in order of preference: files, then an image, then a web link,
    /// then text (text that's nothing but a web link counts as a link). Nil when it's none of these.
    static func resolve(fileURLs: [URL], imagePNG: Data?, webURL: URL?, string: String?) -> DropPayload? {
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty { return .files(files) }
        if let imagePNG, !imagePNG.isEmpty { return .image(png: imagePNG) }
        if let webURL, Self.isWebLink(webURL) { return .link(webURL) }
        guard let string, string.contains(where: { !$0.isWhitespace }) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), Self.isWebLink(url) {
            return .link(url)
        }
        return .text(string)
    }

    private static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host() != nil
    }

    var fileURLs: [URL] {
        if case let .files(urls) = self { return urls }
        return []
    }
}

/// One choice in the drop hub.
enum DropHubAction: Equatable, Hashable, Sendable {
    /// Stage it in Cheese Share and show the link and QR code.
    case shareLink
    case addToShelf
    case tool(ToolID)
}

/// What the drop hub offers for a payload: a summary pill, the two primary actions when their
/// features are on, and the Files tools that apply, grouped under PDF / Convert / Images.
struct DropHubPlan: Equatable, Sendable {
    struct ToolSection: Equatable, Sendable {
        var group: ToolGroup
        var tools: [ToolID]
    }

    var summary: String
    var symbol: String
    var primary: [DropHubAction]
    var sections: [ToolSection]

    /// Nothing to offer, so the icon refuses the drag.
    var isEmpty: Bool { primary.isEmpty && sections.isEmpty }

    /// - Parameters:
    ///   - canShare: Cheese Share (or Show Clipboard as QR) is on.
    ///   - canShelve: the Shelf is on.
    ///   - tools: the Files tools that apply to the payload's files and are switched on.
    ///   - size: a file's size in bytes, nil for a folder.
    static func make(for payload: DropPayload, canShare: Bool, canShelve: Bool, tools: [ToolID], size: (URL) -> Int64?) -> DropHubPlan {
        var primary: [DropHubAction] = []
        if canShare { primary.append(.shareLink) }
        if canShelve { primary.append(.addToShelf) }
        let fileTools = payload.fileURLs.isEmpty ? [] : tools
        return DropHubPlan(
            summary: summary(of: payload, size: size),
            symbol: symbol(for: payload),
            primary: primary,
            sections: ToolApplicability.grouped(fileTools).map { ToolSection(group: $0.group, tools: $0.tools) }
        )
    }

    /// `Report.pdf · 1.8 MB`, `Photos · Folder`, `4 items dropped`, `Image · 340 KB`, a link's host,
    /// or the first line of text.
    static func summary(of payload: DropPayload, size: (URL) -> Int64?) -> String {
        switch payload {
        case let .files(urls):
            guard urls.count == 1, let url = urls.first else { return "\(urls.count) items dropped" }
            let detail = size(url).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Folder"
            return "\(url.lastPathComponent) · \(detail)"
        case let .image(png):
            return "Image · " + ByteCountFormatter.string(fromByteCount: Int64(png.count), countStyle: .file)
        case let .link(url):
            return url.host() ?? url.absoluteString
        case let .text(text):
            let line = text.split(whereSeparator: \.isNewline).first { $0.contains { !$0.isWhitespace } } ?? ""
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    static func symbol(for payload: DropPayload) -> String {
        switch payload {
        case let .files(urls): urls.count == 1 ? "doc" : "doc.on.doc"
        case .image: "photo"
        case .link: "link"
        case .text: "text.quote"
        }
    }
}
