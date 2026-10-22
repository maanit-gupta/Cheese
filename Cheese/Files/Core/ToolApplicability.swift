import Foundation
import UniformTypeIdentifiers

/// What a file is, as far as the Files tools care. Decided from its type alone, so the sandboxed
/// Finder extension can classify a selection without reading the files.
enum FileKind: String, CaseIterable, Sendable {
    case pdf
    case image
    case word
    case excel
    case powerPoint
    case html
    case markdown
    case plainText
    case other

    /// Image formats ImageIO reads that the image tools accept.
    static let imageTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .gif, .bmp, .webP]
    static let wordTypes: [UTType] = [UTType("org.openxmlformats.wordprocessingml.document")].compactMap(\.self)
    static let excelTypes: [UTType] = [
        UTType("org.openxmlformats.spreadsheetml.sheet"),
        UTType("com.microsoft.excel.xls"),
        .commaSeparatedText,
    ].compactMap(\.self)
    static let powerPointTypes: [UTType] = [UTType("org.openxmlformats.presentationml.presentation")].compactMap(\.self)
    static let markdownTypes: [UTType] = [UTType("net.daringfireball.markdown")].compactMap(\.self)

    init(type: UTType?) {
        guard let type else {
            self = .other
            return
        }
        func matches(_ types: [UTType]) -> Bool {
            types.contains { type.conforms(to: $0) }
        }
        // Order matters: Markdown and CSV also conform to plain text.
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if matches(Self.imageTypes) {
            self = .image
        } else if matches(Self.wordTypes) {
            self = .word
        } else if matches(Self.excelTypes) {
            self = .excel
        } else if matches(Self.powerPointTypes) {
            self = .powerPoint
        } else if matches(Self.markdownTypes) {
            self = .markdown
        } else if type.conforms(to: .html) {
            self = .html
        } else if type == .plainText || type == .utf8PlainText {
            self = .plainText
        } else {
            self = .other
        }
    }

    /// Classifies by file name extension, the same way in the app and in the Finder extension.
    init(url: URL) {
        if url.hasDirectoryPath {
            self = .other
            return
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        // Plain-text and Markdown extensions aren't always declared as such on every Mac.
        case "md", "markdown", "mdown", "mkd": self = .markdown
        case "txt", "text": self = .plainText
        default: self.init(type: UTType(filenameExtension: ext))
        }
    }

    /// The types an open panel should allow for this kind.
    var contentTypes: [UTType] {
        switch self {
        case .pdf: [.pdf]
        case .image: Self.imageTypes
        case .word: Self.wordTypes
        case .excel: Self.excelTypes
        case .powerPoint: Self.powerPointTypes
        case .html: [.html]
        case .markdown: Self.markdownTypes
        case .plainText: [.plainText]
        case .other: []
        }
    }
}

/// Which tools apply to a selection. Shared by the Finder extension, the menu bar drop and the palette.
enum ToolApplicability {
    static func tools(for kinds: [FileKind]) -> [ToolID] {
        guard !kinds.isEmpty else { return [] }
        let present = Set(kinds)
        return ToolID.allCases.filter { tool in
            tool.fileCount.contains(kinds.count) && present.isSubset(of: tool.acceptedKinds)
        }
    }

    static func tools(for urls: [URL]) -> [ToolID] {
        tools(for: urls.map(FileKind.init(url:)))
    }

    static func applies(_ tool: ToolID, to urls: [URL]) -> Bool {
        tools(for: urls).contains(tool)
    }

    /// Tools in display order, grouped under their headers, leaving out empty groups.
    static func grouped(_ tools: [ToolID]) -> [(group: ToolGroup, tools: [ToolID])] {
        ToolGroup.allCases.compactMap { group in
            let members = tools.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }
}
