import AppKit

/// The slice of `NSPasteboard` the monitor reads, so tests can substitute a fake.
@MainActor
protocol PasteboardReading {
    var changeCount: Int { get }
    /// The types of each pasteboard item, in order.
    var itemTypes: [[String]] { get }
    func data(forType type: String, itemAt index: Int) -> Data?
}

@MainActor
struct SystemPasteboard: PasteboardReading {
    var pasteboard: NSPasteboard = .general

    var changeCount: Int { pasteboard.changeCount }

    var itemTypes: [[String]] {
        (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
    }

    func data(forType type: String, itemAt index: Int) -> Data? {
        guard let items = pasteboard.pasteboardItems, items.indices.contains(index) else { return nil }
        return items[index].data(forType: NSPasteboard.PasteboardType(type))
    }
}

/// Turns the current pasteboard contents into a `CapturedClip`, reading only the data the clip needs.
@MainActor
enum ClipReader {
    /// Text items keep every representation up to this total; larger extras (often pictures of the text) are dropped.
    static let maxTextPayloadBytes = 32 * 1024 * 1024

    static func read(from pasteboard: some PasteboardReading) -> CapturedClip? {
        let itemTypes = pasteboard.itemTypes
        switch ClipClassifier.classify(itemTypes) {
        case nil:
            return nil
        case .files:
            return readFiles(itemTypes, from: pasteboard)
        case .image:
            return readImage(itemTypes, from: pasteboard)
        case .text:
            return readText(itemTypes, from: pasteboard, isRich: false)
        case .richText:
            return readText(itemTypes, from: pasteboard, isRich: true)
        }
    }

    private static func readFiles(_ itemTypes: [[String]], from pasteboard: some PasteboardReading) -> CapturedClip? {
        let urls = itemTypes.indices.compactMap { index -> URL? in
            guard let data = pasteboard.data(forType: PasteboardTypeID.fileURL, itemAt: index),
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.isFileURL
            else { return nil }
            return url
        }
        return urls.isEmpty ? nil : .files(urls)
    }

    private static func readImage(_ itemTypes: [[String]], from pasteboard: some PasteboardReading) -> CapturedClip? {
        for type in PasteboardTypeID.imageTypes {
            for (index, types) in itemTypes.enumerated() where types.contains(type) {
                if let data = pasteboard.data(forType: type, itemAt: index), !data.isEmpty {
                    return .image(data: data)
                }
            }
        }
        return nil
    }

    private static func readText(
        _ itemTypes: [[String]],
        from pasteboard: some PasteboardReading,
        isRich: Bool
    ) -> CapturedClip? {
        var budget = maxTextPayloadBytes
        var items: [PasteboardItemContent] = []
        for (index, types) in itemTypes.enumerated() {
            var representations: [PasteboardRepresentation] = []
            for type in types {
                guard let data = pasteboard.data(forType: type, itemAt: index) else { continue }
                // Plain text is always kept; it's what the item is.
                guard type == PasteboardTypeID.plainText || data.count <= budget else { continue }
                budget -= min(data.count, budget)
                representations.append(PasteboardRepresentation(type: type, data: data))
            }
            if !representations.isEmpty {
                items.append(PasteboardItemContent(representations: representations))
            }
        }

        guard let plain = plainText(of: items),
              plain.contains(where: { !$0.isWhitespace })
        else { return nil }
        return .text(plain: plain, items: items, isRich: isRich)
    }

    /// The items' plain text, or text extracted from their RTF/RTFD/HTML when no plain text was offered.
    static func plainText(of items: [PasteboardItemContent]) -> String? {
        let strings = items.compactMap { item in
            item.data(forType: PasteboardTypeID.plainText).flatMap { String(data: $0, encoding: .utf8) }
        }
        if !strings.isEmpty { return strings.joined(separator: "\n") }
        return items.lazy.compactMap { RichText.attributedString(from: $0)?.string }.first
    }
}

/// Builds attributed strings from stored rich-text representations.
@MainActor
enum RichText {
    static func attributedString(from item: PasteboardItemContent) -> NSAttributedString? {
        let candidates: [(String, NSAttributedString.DocumentType)] = [
            (PasteboardTypeID.rtfd, .rtfd),
            (PasteboardTypeID.rtf, .rtf),
            (PasteboardTypeID.html, .html),
        ]
        for (type, documentType) in candidates {
            guard let data = item.data(forType: type) else { continue }
            if let string = try? NSAttributedString(
                data: data,
                options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            ) {
                return string
            }
        }
        return nil
    }
}
