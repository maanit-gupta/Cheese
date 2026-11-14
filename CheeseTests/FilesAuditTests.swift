import AppKit
import Foundation
import PDFKit
import Testing
@testable import Cheese

/// Dumps what the PDF extractor sees, for tuning by eye:
/// `TEST_RUNNER_FILES_AUDIT_DIR=$(mktemp -d) … -only-testing:CheeseTests/FilesAuditDumpTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FILES_AUDIT_DIR"] != nil))
struct FilesAuditDumpTests {
    private var folder: URL {
        URL(filePath: ProcessInfo.processInfo.environment["FILES_AUDIT_DIR"] ?? NSTemporaryDirectory(), directoryHint: .isDirectory)
    }

    @Test(arguments: ["latex-article.pdf", "no-unicode.pdf", "rotated.pdf"])
    func dumpExtraction(_ name: String) throws {
        let input = try FilesFixture.copy(name)
        let document = try #require(PDFDocument(url: input))
        var out = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            out += "=== PAGE \(index + 1) string ===\n\(page.string ?? "")\n"
            out += "=== PAGE \(index + 1) lines ===\n"
            let box = page.bounds(for: .cropBox)
            for line in page.selection(for: box)?.selectionsByLine() ?? [] {
                let bounds = line.bounds(for: page)
                var fonts: [String] = []
                if let attributed = line.attributedString {
                    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                        let font = value as? NSFont
                        fonts.append("[\(font?.fontName ?? "?") \(font?.pointSize ?? 0)] \((attributed.string as NSString).substring(with: range))")
                    }
                }
                out += String(format: "%.1f,%.1f %.1fx%.1f | ", bounds.minX, bounds.minY, bounds.width, bounds.height) + fonts.joined(separator: " ") + "\n"
            }
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let planned = PageLayoutPlanner.plan(PDFTextExtractor.pageInput(on: page))
            out += "=== PAGE \(index + 1) planned (needsOCR \(planned.needsOCR)) ===\n"
            for item in planned.items {
                switch item {
                case let .line(line):
                    let runs = line.runs.map { run in
                        run.script == .none ? run.text : (run.script == .superscript ? "^{\(run.text)}" : "_{\(run.text)}")
                    }.joined()
                    out += String(format: "LINE %.0f,%.0f %.0fx%.0f%@ | ", line.frame.minX, line.frame.minY, line.frame.width, line.frame.height, line.isTabular ? " TAB" : "") + runs + "\n"
                default:
                    out += "\(item)\n"
                }
            }
        }
        try out.write(to: folder.appending(path: name + ".txt"), atomically: true, encoding: .utf8)
        let docx = try PDFToDocx.convert(input)
        try docx.write(to: folder.appending(path: name + ".docx"))
    }
}

/// Writes one output per tool into `TEST_RUNNER_FILES_AUDIT_DIR`, for rendering to PNG and checking
/// by eye (`qlmanage -t -s 1200 -o out <file>`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FILES_AUDIT_DIR"] != nil))
struct FilesAuditOutputTests {
    private var folder: URL {
        URL(filePath: ProcessInfo.processInfo.environment["FILES_AUDIT_DIR"] ?? NSTemporaryDirectory(), directoryHint: .isDirectory)
    }

    private func keep(_ report: JobReport, as name: String) throws {
        for (index, output) in report.outputs.enumerated() {
            let destination = folder.appending(path: index == 0 ? name : "\(index)-\(name)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: output, to: destination)
        }
    }

    @Test func everyToolOnce() async throws {
        let inputs = try FilesFixture.copy([
            "latex-article.pdf", "rotated.pdf", "text.pdf", "mixed.pdf", "tables.pdf", "rich.docx", "merged.xlsx", "media.pptx",
            "notes.md", "page.html", "scripts.txt", "notes-image.png", "alpha.png", "rotated.jpg", "photo.webp", "animated.gif", "photo.heic",
        ])
        func file(_ name: String) -> URL { inputs.first { $0.lastPathComponent == name } ?? inputs[0] }
        try keep(try await runJob(MergeFilesTool().work(inputs: [file("latex-article.pdf"), file("rotated.pdf"), file("text.pdf")], options: MergeFilesTool.Options())), as: "merge.pdf")
        try keep(try await runJob(CompressTool().work(inputs: [file("mixed.pdf")], options: CompressTool.Options(targetMB: 0.2))), as: "compress.pdf")
        try keep(try await runJob(WatermarkTool().work(inputs: [file("latex-article.pdf")], options: WatermarkTool.Options())), as: "watermark.pdf")
        try keep(try await runJob(PageNumbersTool().work(inputs: [file("rotated.pdf")], options: PageNumbersTool.Options(format: .pageOf))), as: "numbers.pdf")
        try keep(try await runJob(ImagesToPDFTool().work(
            inputs: [file("alpha.png"), file("rotated.jpg"), file("photo.webp"), file("animated.gif"), file("photo.heic")],
            options: ImagesToPDFTool.Options(pageSize: .a4, margin: .normal)
        )), as: "images.pdf")
        try keep(try await runJob(OfficeToPDFTool(kind: .word).work(inputs: [file("rich.docx")], options: NoOptions())), as: "word.pdf")
        try keep(try await runJob(OfficeToPDFTool(kind: .excel).work(inputs: [file("merged.xlsx")], options: NoOptions())), as: "excel.pdf")
        try keep(try await runJob(OfficeToPDFTool(kind: .powerPoint).work(inputs: [file("media.pptx")], options: NoOptions())), as: "powerpoint.pdf")
        try keep(try await runJob(WebToPDFTool().work(inputs: [file("notes.md")], options: WebToPDFTool.Options())), as: "markdown.pdf")
        try keep(try await runJob(WebToPDFTool().work(inputs: [file("scripts.txt")], options: WebToPDFTool.Options())), as: "scripts.pdf")
        try keep(try await runJob(PDFToDocxTool().work(inputs: [file("text.pdf")], options: NoOptions())), as: "text.docx")
        try keep(try await runJob(PDFToDocxTool().work(inputs: [file("mixed.pdf")], options: NoOptions())), as: "mixed.docx")
        try keep(try await runJob(PDFToXlsxTool().work(inputs: [file("tables.pdf")], options: NoOptions())), as: "tables.xlsx")
        try keep(try await runJob(MarkdownToDocxTool().work(inputs: [file("notes.md")], options: NoOptions())), as: "markdown.docx")
        try keep(try await runJob(MarkdownToDocxTool().work(inputs: [file("page.html")], options: NoOptions())), as: "html.docx")
        let mixed = ["rich.docx", "rotated.jpg", "photo.webp", "latex-article.pdf", "notes.md", "merged.xlsx", "media.pptx"].map(file)
        var options = MergeFilesTool.Options()
        options.dividers = true
        options.pageNumbers = true
        try keep(try await runJob(MergeFilesTool().work(inputs: mixed, options: options)), as: "merged-mixed.pdf")
        options.format = .word
        try keep(try await runJob(MergeFilesTool().work(inputs: mixed, options: options)), as: "merged-mixed.docx")
    }
}
