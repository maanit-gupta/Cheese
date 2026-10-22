import Foundation
import PDFKit
import Testing
@testable import Cheese

struct RendererBudgetTests {
    private var folder: URL? { Renderers.folder }

    @Test func renderersStayUnderThreeMegabytes() throws {
        let folder = try #require(folder)
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]))
        var total = 0
        for case let url as URL in files {
            total += (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        #expect(total > 0)
        #expect(total < 3_000_000, "Renderers/ is \(total) bytes")
    }

    @Test func everyVendoredFileIsRecordedWithALicense() throws {
        let folder = try #require(folder)
        let notes = try String(contentsOf: folder.appending(path: "VENDORED.md"), encoding: .utf8)
        for (file, license) in [
            ("marked.umd.js", "marked.txt"), ("jszip.min.js", "jszip.txt"), ("docx-preview.min.js", "docx-preview.txt"),
            ("xlsx.full.min.js", "sheetjs.txt"), ("pptx-to-html.js", "pptx-to-html.txt"),
        ] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path(percentEncoded: false)), "\(file)")
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "licenses/\(license)").path(percentEncoded: false)), "\(license)")
            #expect(notes.contains("`\(file)`"), "\(file) isn't in VENDORED.md")
        }
        #expect(Acknowledgements.load().count == 5)
    }

    @Test func powerPointModuleBecomesAClassicScript() throws {
        let script = try OfficeRenderer.powerPointScript()
        #expect(script.contains("const JSZip = window.JSZip;"))
        #expect(script.contains("window.pptxToHtml = pptxToHtml;"))
        #expect(!script.contains("import JSZip"))
    }
}

@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct OfficeRenderingIntegrationTests {
    private func convert(_ fixture: String, with kind: OfficeRenderer.Kind) async throws -> PDFDocument {
        let input = try FilesFixture.copy(fixture)
        let report = try await runJob(OfficeToPDFTool(kind: kind).work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        #expect(output.pathExtension == "pdf")
        return try #require(PDFDocument(url: output))
    }

    private func text(_ document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    @Test func wordRendersWithSelectableText() async throws {
        let document = try await convert("report.docx", with: .word)
        #expect(document.pageCount > 0)
        #expect(text(document).contains("Project Plan"))
        #expect(text(document).contains("Timeline"))
        let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
        // A Letter or A4 page, not CSS pixels.
        #expect(size.width < 620 && size.width > 590, "\(size)")
    }

    @Test func excelRendersEverySheet() async throws {
        let document = try await convert("budget.xlsx", with: .excel)
        #expect(document.pageCount >= 2)
        let all = text(document)
        #expect(all.contains("Hardware"))
        #expect(all.contains("Engineering"))
        let page = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(page.width > page.height)
    }

    @Test func csvRendersAsATable() async throws {
        let document = try await convert("data.csv", with: .excel)
        #expect(document.pageCount > 0)
        #expect(text(document).contains("Mumbai"))
    }

    @Test func powerPointRendersOneSlidePerPage() async throws {
        let document = try await convert("deck.pptx", with: .powerPoint)
        #expect(document.pageCount == 3)
        let all = text(document)
        #expect(all.contains("Launch Review"))
        #expect(all.contains("What shipped"))
        let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.05)
    }

    @Test func aBrokenFileFailsAloneAndTheRestStillConvert() async throws {
        let good = try FilesFixture.copy("report.docx")
        let broken = good.deletingLastPathComponent().appending(path: "broken.docx")
        try Data("not a zip".utf8).write(to: broken)
        let report = try await runJob(OfficeToPDFTool(kind: .word).work(inputs: [broken, good], options: NoOptions()))
        #expect(report.failures.map(\.file) == ["broken.docx"])
        #expect(report.outputs.map(\.lastPathComponent) == ["report.pdf"])
    }
}
