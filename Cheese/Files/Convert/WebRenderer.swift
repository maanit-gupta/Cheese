import AppKit
import Foundation
import JavaScriptCore

/// The vendored renderer files bundled under `Renderers/`.
enum Renderers {
    static var folder: URL? {
        Bundle.main.url(forResource: "Renderers", withExtension: nil)
    }

    static func url(_ name: String) throws -> URL {
        guard let url = folder?.appending(path: name), FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw FileToolError.message("Cheese's \(name) renderer is missing. Reinstall Cheese.")
        }
        return url
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }
}

/// Runs vendored JavaScript in a bare `JSContext`: no WebView, no network, no DOM.
enum JavaScriptRunner {
    /// A context with the given renderer scripts loaded, reporting the first script error.
    static func context(loading scripts: [String]) throws -> JSContext {
        guard let context = JSContext() else { throw FileToolError.message("JavaScript isn't available.") }
        for script in scripts {
            context.evaluateScript(try Renderers.source(script))
            try check(context)
        }
        return context
    }

    static func check(_ context: JSContext) throws {
        if let exception = context.exception {
            context.exception = nil
            throw FileToolError.message("A renderer script failed: \(exception.toString() ?? "unknown error")")
        }
    }
}

/// Markdown → HTML with the vendored `marked` (GitHub-flavored: tables, task lists, fenced code).
enum MarkdownConverter {
    static func html(fromMarkdown markdown: String) throws -> String {
        let context = try JavaScriptRunner.context(loading: ["marked.umd.js"])
        let result = context.objectForKeyedSubscript("marked")?.invokeMethod("parse", withArguments: [markdown])
        try JavaScriptRunner.check(context)
        guard let result, result.isString, let html = result.toString() else {
            throw FileToolError.message("The Markdown couldn't be converted.")
        }
        return html
    }
}

/// Wraps content in a printable page. Pure, so escaping and structure are tested.
enum WebDocument {
    static func page(body: String, css: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title><style>\(css)</style></head>
        <body>\(body)</body></html>
        """
    }

    static func plainText(_ text: String) -> String {
        "<pre class=\"plain-text\">\(escape(text))</pre>"
    }

    static func escape(_ text: String) -> String {
        text
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }

    /// Reads a text file as UTF-8, falling back to whatever encoding Foundation detects.
    static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }
}

/// HTML, Markdown and plain text → PDF, paginated by WebKit's print system with `print.css`.
/// JavaScript is off and nothing but local files can load.
@MainActor
enum WebRenderer {
    static let margin: CGFloat = 54

    static func renderPDF(_ input: URL, kind: FileKind, pageSize: PDFPageSize, to output: URL) async throws {
        let paper = pageSize.portraitSize ?? PDFPageSize.localeDefault.portraitSize ?? CGSize(width: 595.28, height: 841.89)
        let view = try await LocalWebView.make(width: paper.width - margin * 2, allowsJavaScript: false)
        defer { view.close() }
        let folder = input.deletingLastPathComponent()
        switch kind {
        case .html:
            try await view.loadFile(input, readAccess: folder)
        case .markdown:
            let body = try MarkdownConverter.html(fromMarkdown: try WebDocument.readText(input))
            try await view.loadHTML(WebDocument.page(body: body, css: try Renderers.source("print.css"), title: input.lastPathComponent), baseURL: folder)
        default:
            let body = WebDocument.plainText(try WebDocument.readText(input))
            try await view.loadHTML(WebDocument.page(body: body, css: try Renderers.source("print.css"), title: input.lastPathComponent), baseURL: folder)
        }
        try await view.printPDF(to: output, paperSize: paper, margin: margin, landscape: false)
    }
}
