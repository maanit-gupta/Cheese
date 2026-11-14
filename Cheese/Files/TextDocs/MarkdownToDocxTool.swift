import AppKit
import Foundation
import SwiftUI

/// Markdown or HTML → Word. Markdown goes through `marked`, then Cocoa's HTML importer and
/// its Office Open XML writer. Headings, lists, emphasis, links, code and simple tables survive.
struct MarkdownToDocxTool: FileTool {
    let id = ToolID.markdownToWord
    var defaultOptions: NoOptions { NoOptions() }
    var hint: String? { "Remote images aren't downloaded; images next to the file are included." }

    func optionsView(options: Binding<NoOptions>, inputs: [URL]) -> some View {
        EmptyView()
    }

    func work(inputs: [URL], options: NoOptions) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let text = try WebDocument.readText(input)
            let body = FileKind(url: input) == .markdown ? try MarkdownConverter.html(fromMarkdown: text) : text
            let html = HTMLSanitizer.removingRemoteResources(DocxWriter.page(body: body))
            let folder = input.deletingLastPathComponent()
            let data = try await MainActor.run { try DocxWriter.docx(fromHTML: html, baseURL: folder) }
            let output = context.outputURL(for: input, suffix: nil, extension: "docx")
            try data.write(to: output, options: .withoutOverwriting)
        }
    }
}

/// HTML → `.docx` through `NSAttributedString`.
enum DocxWriter {
    /// Styles the HTML importer understands, so headings and code look right in Word.
    static func page(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: 'Helvetica Neue', Helvetica, Arial; font-size: 11pt; }
        h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
        code, pre { font-family: Menlo, Courier; font-size: 10pt; }
        table { border-collapse: collapse; } th, td { border: 1px solid #999; padding: 3pt 6pt; }
        blockquote { color: #555; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// Imports HTML (WebKit, so main thread only) and writes it as Office Open XML. Cocoa's writer
    /// drops tables and pictures, so those are swapped for tokens first and put back as a real
    /// `w:tbl` and inline pictures afterwards.
    @MainActor
    static func docx(fromHTML html: String, baseURL: URL?) throws -> Data {
        let prepared = HTMLForDocx.prepare(html, folder: baseURL)
        let attributed = try attributedString(fromHTML: prepared.html, baseURL: baseURL)
        let written = try docx(from: attributed)
        guard !prepared.images.isEmpty || !prepared.tables.isEmpty else { return written }
        var parts = try ZipArchive.read(written)
        try DocxTableEmbedder.embed(prepared.tables, into: &parts)
        try DocxImageEmbedder.embed(prepared.images, into: &parts)
        return try ZipArchive.write(parts)
    }

    @MainActor
    static func attributedString(fromHTML html: String, baseURL: URL?) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL {
            options[.baseURL] = baseURL
        }
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }

    static func docx(from attributed: NSAttributedString) throws -> Data {
        try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
    }
}

/// Strips anything in HTML that would make the importer fetch from the network: remote images,
/// stylesheets, scripts, frames and CSS `url()`/`@import` pointing at http(s). Links stay.
enum HTMLSanitizer {
    private static let patterns = [
        #"<script\b[^>]*>[\s\S]*?</script\s*>"#,
        #"<(iframe|frame|object|embed)\b[^>]*>([\s\S]*?</\1\s*>)?"#,
        #"<(img|source|video|audio|input)\b[^>]*\b(src|srcset|poster)\s*=\s*["']?\s*(https?:)?//[^>]*>"#,
        #"<link\b[^>]*\bhref\s*=\s*["']?\s*(https?:)?//[^>]*>"#,
        #"@import\s+(url\()?\s*["']?\s*(https?:)?//[^;]*;?"#,
    ]
    private static let cssURL = #"url\(\s*["']?\s*(https?:)?//[^)]*\)"#

    static func removingRemoteResources(_ html: String) -> String {
        var result = html
        for pattern in patterns {
            if let regex = try? Regex(pattern).ignoresCase() {
                result = result.replacing(regex, with: "")
            }
        }
        if let regex = try? Regex(cssURL).ignoresCase() {
            result = result.replacing(regex, with: "none")
        }
        return result
    }
}

/// Gets HTML ready for Cocoa's importer and Office Open XML writer, which drop tables and pictures:
/// each `<table>` becomes a token paragraph plus its rows, and each local `<img>` a token plus
/// its PNG. Pure apart from reading the images, which must sit in (or under) `folder`.
enum HTMLForDocx {
    struct Prepared {
        var html: String
        var images: [DocxImage] = []
        var tables: [DocxTable] = []
    }

    /// Pictures wider than the text column are scaled down to it.
    static let maxImageWidth: CGFloat = 468

    static func prepare(_ html: String, folder: URL?, firstImage: Int = 1, firstTable: Int = 1) -> Prepared {
        var prepared = Prepared(html: html)
        prepared.html = html.replacing(/(?is)<table\b.*?<\/table\s*>/) { match in
            let rows = tableRows(String(match.0))
            guard !rows.isEmpty else { return "" }
            let token = DocxTable.token(firstTable + prepared.tables.count)
            let header = String(match.0).range(of: "<th", options: .caseInsensitive) != nil
            prepared.tables.append(DocxTable(token: token, rows: rows, hasHeader: header))
            return "<p>\(token)</p>"
        }
        guard let folder else { return prepared }
        prepared.html = prepared.html.replacing(/(?i)<img\b[^>]*>/) { match in
            guard let source = attribute("src", in: String(match.0)),
                  let file = LocalImages.resolve(source, in: folder),
                  let picture = LocalImages.png(at: file)
            else { return String(match.0) }
            let token = DocxImage.token(firstImage + prepared.images.count)
            let scale = min(1, maxImageWidth / max(picture.size.width, 1))
            prepared.images.append(DocxImage(token: token, png: picture.png, size: CGSize(width: picture.size.width * scale, height: picture.size.height * scale)))
            // A color of its own keeps the token in a run by itself.
            return "<span style=\"color:#010101\">\(token)</span>"
        }
        return prepared
    }

    /// The text of each cell, row by row. Nested markup is dropped; entities are decoded.
    static func tableRows(_ table: String) -> [[String]] {
        table.matches(of: /(?is)<tr\b[^>]*>(.*?)<\/tr\s*>/).map { row in
            String(row.1).matches(of: /(?is)<t[hd]\b[^>]*>(.*?)<\/t[hd]\s*>/).map { cell in
                decodeEntities(String(cell.1).replacing(/(?s)<[^>]*>/, with: ""))
                    .replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
            }
        }.filter { !$0.isEmpty }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex("(?i)\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"),
              let match = tag.firstMatch(of: regex)
        else { return nil }
        for index in 2...4 {
            if let value = match.output[index].substring {
                return decodeEntities(String(value))
            }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacing("&nbsp;", with: " ").replacing("&lt;", with: "<").replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"").replacing("&#39;", with: "'").replacing("&amp;", with: "&")
    }
}
