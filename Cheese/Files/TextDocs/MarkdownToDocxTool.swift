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

    /// Imports HTML (WebKit, so main thread only) and writes it as Office Open XML.
    @MainActor
    static func docx(fromHTML html: String, baseURL: URL?) throws -> Data {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL {
            options[.baseURL] = baseURL
        }
        let attributed = try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
        return try docx(from: attributed)
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
