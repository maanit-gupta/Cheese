import AppKit
import Foundation
import PDFKit
import Testing
@testable import Cheese

/// Slower tests that drive WebKit or the Office renderers. Run with `make test-integration`.
enum Integration {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FILES_INTEGRATION"] == "1"
    }
}

struct MarkdownConverterTests {
    @Test func convertsGitHubFlavoredMarkdown() throws {
        let html = try MarkdownConverter.html(fromMarkdown: "# Title\n\n- one\n- **two**\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>two</strong>"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<pre><code>code"))
    }

    @Test func plainTextIsEscapedInsideAPre() {
        #expect(WebDocument.plainText("a < b & \"c\"") == "<pre class=\"plain-text\">a &lt; b &amp; &quot;c&quot;</pre>")
        #expect(WebDocument.page(body: "<p>x</p>", css: "p{}", title: "<T>").contains("<title>&lt;T&gt;</title>"))
    }

    @Test func sanitizerDropsRemoteResourcesButKeepsLinksAndLocalImages() {
        let html = """
        <p><a href="https://example.com">link</a></p>
        <img src="https://example.com/a.png"><img src="//cdn.example.com/b.png"><img src="local.png">
        <link rel="stylesheet" href="http://example.com/s.css"><script>alert(1)</script>
        <style>@import url("https://x/y.css"); body { background: url(https://x/bg.png) }</style>
        """
        let clean = HTMLSanitizer.removingRemoteResources(html)
        #expect(clean.contains("href=\"https://example.com\""))
        #expect(clean.contains("local.png"))
        #expect(!clean.contains("a.png"))
        #expect(!clean.contains("b.png"))
        #expect(!clean.contains("s.css"))
        #expect(!clean.contains("alert"))
        #expect(!clean.contains("y.css"))
        #expect(!clean.contains("bg.png"))
    }

    @Test func contentRulesBlockEverythingButLocalSchemes() throws {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(LocalWebView.contentRules.utf8)) as? [[String: [String: String]]])
        #expect(rules.first?["trigger"]?["url-filter"] == ".*")
        #expect(rules.first?["action"]?["type"] == "block")
        let exceptions = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] }
        #expect(exceptions == ["^file:", "^data:", "^blob:", "^about:"])
        #expect(rules.dropFirst().allSatisfy { $0["action"]?["type"] == "ignore-previous-rules" })
        #expect(!LocalWebView.allowedSchemes.contains("http"))
        #expect(!LocalWebView.allowedSchemes.contains("https"))
    }
}

@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct WebRenderingIntegrationTests {
    @Test func markdownBecomesAPaginatedPDF() async throws {
        let folder = makeTemporaryDirectory()
        let input = folder.appending(path: "Notes.md")
        let paragraphs = (1...80).map { "Paragraph \($0) with enough words to wrap across the line a couple of times." }
        try ("# Meeting Notes\n\n" + paragraphs.joined(separator: "\n\n")).write(to: input, atomically: true, encoding: .utf8)
        let report = try await runJob(WebToPDFTool().work(inputs: [input], options: .init(pageSize: .a4)))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Notes.pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount > 1)
        #expect(document.page(at: 0)?.string?.contains("Meeting Notes") == true)
        let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(abs(size.width - 595.28) < 1)
    }

    @Test func plainTextAndHTMLRender() async throws {
        let folder = makeTemporaryDirectory()
        let text = folder.appending(path: "readme.txt")
        try "Plain <text> file".write(to: text, atomically: true, encoding: .utf8)
        let html = folder.appending(path: "page.html")
        try "<html><body><h1>Hello page</h1><img src=\"https://example.com/x.png\"></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let report = try await runJob(WebToPDFTool().work(inputs: [text, html], options: .init(pageSize: .letter)))
        #expect(report.failures.isEmpty)
        #expect(report.outputs.count == 2)
        #expect(TestPDFs.pageTexts(report.outputs[0]).first?.contains("Plain <text> file") == true)
        #expect(TestPDFs.pageTexts(report.outputs[1]).first?.contains("Hello page") == true)
    }

    @Test func markdownBecomesWordWithHeadingsListsAndCode() async throws {
        let input = makeTemporaryDirectory().appending(path: "Spec.md")
        try "# Big Heading\n\nSome **bold** text.\n\n- first\n- second\n\n```\nlet x = 1\n```\n".write(to: input, atomically: true, encoding: .utf8)
        let report = try await runJob(MarkdownToDocxTool().work(inputs: [input], options: NoOptions()))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Spec.docx")
        let attributed = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(attributed.string.contains("Big Heading"))
        #expect(attributed.string.contains("let x = 1"))
        let headingFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((headingFont?.pointSize ?? 0) > 16)
    }
}
