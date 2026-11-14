import AppKit
import Foundation
import PDFKit
import Testing
@testable import Cheese

struct MergeFilesNamingTests {
    @Test func theOldMergePDFsValueStillDecodes() throws {
        #expect(try JSONDecoder().decode(ToolID.self, from: Data(#""mergePDFs""#.utf8)) == .mergeFiles)
        #expect(ToolID.mergeFiles.rawValue == "mergePDFs")
        let handoff = #"{"tool":"mergePDFs","fileURLs":["file:///tmp/a.pdf","file:///tmp/b.docx"]}"#
        #expect(try JSONDecoder().decode(FilesHandoff.Job.self, from: Data(handoff.utf8)).tool == .mergeFiles)
        #expect(PreferenceKey.fileToolOptions(.mergeFiles) == "fileToolOptions_mergePDFs")
    }

    @Test func titleVerbsAndApplicability() {
        #expect(ToolID.mergeFiles.title == "Merge Files")
        #expect(JobTitles.inProgress(.mergeFiles, inputs: ["a.docx", "b.jpg", "c.jpg", "d.pdf"].map { URL(filePath: "/tmp/\($0)") }) == "Merging 4 files…")
        #expect(JobTitles.done(.mergeFiles, inputs: ["a.pdf", "b.pdf"].map { URL(filePath: "/tmp/\($0)") }) == "Merged 2 PDFs")
        let mixed = ["a.docx", "b.jpg", "c.pdf", "d.md", "e.xlsx", "f.pptx", "g.html", "h.txt"].map { URL(filePath: "/tmp/\($0)") }
        #expect(ToolApplicability.tools(for: mixed) == [.mergeFiles])
        #expect(!ToolApplicability.tools(for: [URL(filePath: "/tmp/a.docx")]).contains(.mergeFiles))
        #expect(!ToolApplicability.tools(for: [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/b.zip")]).contains(.mergeFiles))
        #expect(OutputNamer.mergedName(fileCount: 4, extension: "pdf") == "Merged (4 files).pdf")
    }

    @Test func failuresNameTheFileAndTheReason() {
        let locked = MergeFailure.wrap(FileToolError.message("Budget.pdf is password-protected."), file: URL(filePath: "/tmp/Budget.pdf"))
        #expect((locked as? LocalizedError)?.errorDescription == "Couldn't read Budget.pdf: the file is password-protected.")
        let other = MergeFailure.wrap(FileToolError.emptyDocument, file: URL(filePath: "/tmp/Deck.pptx"))
        #expect((other as? LocalizedError)?.errorDescription == "Couldn't read Deck.pptx: the document has no pages.")
        #expect(MergeFailure.wrap(CancellationError(), file: URL(filePath: "/tmp/a.pdf")) is CancellationError)
    }
}

struct MergePageLayoutTests {
    private let a4 = CGSize(width: 595, height: 842)

    @Test func smallImagesKeepTheirSizeCentered() {
        let (page, rect) = MergePageLayout.placement(image: CGSize(width: 200, height: 300), previousPage: a4)
        #expect(page == a4)
        #expect(rect == CGRect(x: 197.5, y: 271, width: 200, height: 300))
    }

    @Test func bigImagesFitInsideTheHalfInchMargin() {
        let (_, rect) = MergePageLayout.placement(image: CGSize(width: 4000, height: 6000), previousPage: a4)
        #expect(abs(rect.height - (842 - 72)) < 0.001)
        #expect(rect.minY == 36)
        #expect(abs(rect.width - (842 - 72) * 4000 / 6000) < 0.01)
    }

    @Test func wideImagesTurnThePageLandscape() {
        let (page, rect) = MergePageLayout.placement(image: CGSize(width: 3000, height: 2000), previousPage: a4)
        #expect(page == CGSize(width: 842, height: 595))
        #expect(rect.width <= 842 - 72 && rect.height <= 595 - 72)
        // A landscape page before a portrait image gives a portrait page of the same paper.
        #expect(MergePageLayout.placement(image: CGSize(width: 10, height: 20), previousPage: CGSize(width: 792, height: 612)).page == CGSize(width: 612, height: 792))
    }
}

struct InputListInfoTests {
    @Test func badgesCountsAndSorting() {
        #expect(InputListInfo.badge(for: URL(filePath: "/a/Report.docx")) == "DOCX")
        #expect(InputListInfo.badge(for: URL(filePath: "/a/notes.markdown")) == "MD")
        #expect(InputListInfo.countText(1, unit: "page") == "1 page")
        #expect(InputListInfo.countText(3, unit: "slide") == "3 slides")
        #expect(InputListInfo.slideCount(partNames: ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/_rels/slide1.xml.rels", "ppt/slideLayouts/slideLayout1.xml"]) == 2)
        #expect(InputListInfo.sheetCount(workbook: #"<workbook><sheets><sheet name="A" sheetId="1"/><sheet name="B" sheetId="2"/></sheets></workbook>"#) == 2)
        #expect(InputListInfo.wordPages(appProperties: "<Properties><Pages>12</Pages></Properties>") == 12)
        let urls = ["b.pdf", "A.docx", "c 10.jpg", "c 9.jpg"].map { URL(filePath: "/tmp/\($0)") }
        #expect(InputListInfo.sorted(urls, by: .name) { _ in nil }.map(\.lastPathComponent) == ["A.docx", "b.pdf", "c 9.jpg", "c 10.jpg"])
        let dates = Dictionary(uniqueKeysWithValues: urls.enumerated().map { ($1, Date(timeIntervalSince1970: Double(10 - $0))) })
        #expect(InputListInfo.sorted(urls, by: .dateModified) { dates[$0] }.map(\.lastPathComponent) == ["c 9.jpg", "c 10.jpg", "A.docx", "b.pdf"])
    }

    @Test func addingKeepsOrderAndSkipsDuplicatesAndUnsupportedFiles() {
        let start = [URL(filePath: "/tmp/a.pdf")]
        let added = InputListInfo.adding(
            ["a.pdf", "b.png", "c.zip", "b.png", "d.md"].map { URL(filePath: "/tmp/\($0)") }, to: start, accepted: ToolID.mergeFiles.acceptedKinds
        )
        #expect(added.map(\.lastPathComponent) == ["a.pdf", "b.png", "d.md"])
    }
}

/// Two small hand-written packages, the way Word writes them.
private enum TestDocx {
    static func package(body: String, relationships: String = "", styles: String? = nil, numbering: String? = nil, media: [String: Data] = [:]) -> [String: Data] {
        var parts: [String: Data] = [
            "[Content_Types].xml": Data(#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>"#.utf8),
            "_rels/.rels": Data(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#.utf8),
            "word/document.xml": Data(("<w:document xmlns:w=\"\(DocxMerger.wordNamespace)\" xmlns:r=\"\(DocxMerger.relationshipNamespace)\"><w:body>" + body + "</w:body></w:document>").utf8),
            "word/_rels/document.xml.rels": Data((#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + relationships + "</Relationships>").utf8),
        ]
        if let styles {
            parts["word/styles.xml"] = Data(("<w:styles xmlns:w=\"\(DocxMerger.wordNamespace)\">" + styles + "</w:styles>").utf8)
        }
        if let numbering {
            parts["word/numbering.xml"] = Data(("<w:numbering xmlns:w=\"\(DocxMerger.wordNamespace)\">" + numbering + "</w:numbering>").utf8)
        }
        for (path, data) in media {
            parts[path] = data
        }
        return parts
    }

    static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    static func drawing(_ id: String) -> String {
        #"<w:p><w:r><w:drawing><wp:inline><wp:docPr id="1" name="p"/><a:graphic><a:graphicData><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="p"/></pic:nvPicPr><pic:blipFill><a:blip r:embed=""# + id + #""/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#
    }
}

struct DocxMergerTests {
    private func xml(_ parts: [String: Data], _ path: String) -> String {
        String(decoding: parts[path] ?? Data(), as: UTF8.self)
    }

    private var first: DocxMerger.Document {
        DocxMerger.Document(parts: TestDocx.package(
            body: #"<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>First</w:t></w:r></w:p>"# + TestDocx.drawing("rId5")
                + #"<w:sectPr><w:headerReference w:type="default" r:id="rId9"/><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>"#,
            relationships: #"<Relationship Id="rId5" Type="\#(TestDocx.imageType)" Target="media/image1.png"/><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>"#,
            styles: #"<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style><w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>"#,
            media: ["word/media/image1.png": Data([1])]
        ), title: "First.docx")
    }

    private var second: DocxMerger.Document {
        DocxMerger.Document(parts: TestDocx.package(
            body: #"<w:p><w:pPr><w:pStyle w:val="Fancy"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Second</w:t><w:footnoteReference w:id="2"/></w:r></w:p>"#
                + TestDocx.drawing("rId5") + #"<w:p><w:hyperlink r:id="rId7"><w:r><w:t>link</w:t></w:r></w:hyperlink></w:p>"#
                + #"<w:p><w:r><w:drawing><c:chart r:id="rId8"/></w:drawing></w:r></w:p>"#
                + #"<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>"#,
            relationships: #"<Relationship Id="rId5" Type="\#(TestDocx.imageType)" Target="media/image1.png"/><Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/?a=1&amp;b=2" TargetMode="External"/><Relationship Id="rId8" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="charts/chart1.xml"/>"#,
            styles: #"<w:style w:type="paragraph" w:styleId="Fancy"><w:name w:val="Fancy"/><w:basedOn w:val="Base2"/></w:style><w:style w:type="paragraph" w:styleId="Base2"><w:name w:val="Base2"/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Other title"/></w:style>"#,
            numbering: #"<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>"#,
            media: ["word/media/image1.png": Data([2])]
        ), title: "Second.docx")
    }

    @Test func appendsBodiesAndRelinksPictures() throws {
        let merged = try DocxMerger.merge([first, second], dividers: false, pageNumbers: false)
        let document = xml(merged, "word/document.xml")
        #expect(document.range(of: "First")!.lowerBound < document.range(of: "Second")!.lowerBound)
        // The first document's section (page size, header) is the one kept; the second's is gone.
        #expect(document.contains(#"<w:pgSz w:w="11906""#) && !document.contains(#"w:w="12240""#))
        #expect(document.hasSuffix("</w:sectPr></w:body></w:document>"))
        #expect(document.contains(DocxMerger.pageBreak))
        // Both pictures, under distinct names and IDs.
        #expect(merged["word/media/image1.png"] == Data([1]))
        #expect(merged["word/media/merged1-image1.png"] == Data([2]))
        let relationships = xml(merged, "word/_rels/document.xml.rels")
        #expect(relationships.contains(#"Id="rIdM1xrId5" Type="\#(TestDocx.imageType)" Target="media/merged1-image1.png""#))
        #expect(document.contains(#"r:embed="rId5""#) && document.contains(#"r:embed="rIdM1xrId5""#))
        #expect(xml(merged, "[Content_Types].xml").contains(#"Extension="png""#))
        // Links keep working, external mode and all.
        #expect(document.contains(#"<w:hyperlink r:id="rIdM1xrId7">"#))
        #expect(relationships.contains(#"Target="https://example.com/?a=1&amp;b=2" TargetMode="External""#))
        // A chart that wasn't carried over is left out rather than left broken; so are footnote references.
        #expect(!document.contains("c:chart") && !document.contains("footnoteReference"))
        // Drawing IDs are unique.
        let ids = document.matches(of: /<wp:docPr id="(\d+)"/).map { String($0.1) }
        #expect(Set(ids).count == ids.count && ids.count == 2)
    }

    @Test func copiesMissingStylesAndRenumbersLists() throws {
        let merged = try DocxMerger.merge([first, second], dividers: false, pageNumbers: false)
        let styles = xml(merged, "word/styles.xml")
        #expect(styles.contains(#"w:styleId="Fancy""#) && styles.contains(#"w:styleId="Base2""#))
        // A style both have keeps the first document's definition.
        #expect(styles.components(separatedBy: #"w:styleId="Title""#).count == 2 && !styles.contains("Other title"))
        let numbering = xml(merged, "word/numbering.xml")
        #expect(numbering.contains(#"<w:abstractNum w:abstractNumId="1000">"#) && numbering.contains(#"<w:num w:numId="1001"><w:abstractNumId w:val="1000"/>"#))
        #expect(xml(merged, "word/document.xml").contains(#"<w:numId w:val="1001"/>"#))
        #expect(xml(merged, "word/_rels/document.xml.rels").contains("/numbering\""))
        #expect(xml(merged, "[Content_Types].xml").contains("PartName=\"/word/numbering.xml\""))
    }

    @Test func dividersAndPageNumbers() throws {
        let merged = try DocxMerger.merge([first, second], dividers: true, pageNumbers: true)
        let document = xml(merged, "word/document.xml")
        #expect(document.contains(#"<w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t xml:space="preserve">First.docx</w:t>"#))
        #expect(document.contains(#"<w:pStyle w:val="Heading1"/><w:pageBreakBefore/></w:pPr><w:r><w:t xml:space="preserve">Second.docx</w:t>"#))
        #expect(xml(merged, "word/styles.xml").contains(#"w:styleId="Heading1""#))
        // The header stays; the footer is a PAGE field.
        #expect(document.contains(#"<w:headerReference w:type="default" r:id="rId9"/><w:footerReference w:type="default" r:id="rIdCheeseFooter"/>"#))
        #expect(xml(merged, "word/footerCheesePageNumber.xml").contains(" PAGE "))
        #expect(xml(merged, "word/_rels/document.xml.rels").contains(#"Target="footerCheesePageNumber.xml""#))
    }

    @Test func aSectionlessDocumentGetsOneForItsFooter() {
        #expect(DocxMerger.withFooter("rIdF", in: "").contains(#"<w:sectPr><w:footerReference w:type="default" r:id="rIdF"/><w:pgSz"#))
        #expect(DocxMerger.withFooter("rIdF", in: #"<w:sectPr w:rsidR="1"/>"#) == #"<w:sectPr w:rsidR="1"><w:footerReference w:type="default" r:id="rIdF"/></w:sectPr>"#)
    }
}

@MainActor
struct MergeFilesPDFTests {
    @Test func pdfsAndImagesWithBookmarksDividersAndPageNumbers() async throws {
        let inputs = try FilesFixture.copy(["latex-article.pdf", "rotated.jpg", "alpha.png", "text.pdf"])
        var options = MergeFilesTool.Options()
        options.dividers = true
        options.pageNumbers = true
        let report = try await runJob(MergeFilesTool().work(inputs: inputs, options: options))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Merged (4 files).pdf")
        #expect(output.deletingLastPathComponent() == inputs[0].deletingLastPathComponent())
        let document = try #require(PDFDocument(url: output))
        // 4 dividers + 2 + 1 + 1 + 2 pages.
        #expect(document.pageCount == 10)
        let texts = TestPDFs.pageTexts(output)
        #expect(texts[0].contains("latex-article.pdf") && texts[3].contains("rotated.jpg") && texts[5].contains("alpha.png"))
        #expect(texts.last?.hasSuffix("10") == true)
        // The rotated JPEG (shown 400×600) gets a portrait Letter page like the one before; the wide PNG a landscape one.
        let letter = CGSize(width: 612, height: 792)
        #expect(document.page(at: 4)?.bounds(for: .mediaBox).size == letter)
        #expect(document.page(at: 6)?.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))
        // Bookmarks named after each file, pointing at its divider.
        let root = try #require(document.outlineRoot)
        #expect((0..<root.numberOfChildren).compactMap { root.child(at: $0)?.label } == ["latex-article", "rotated", "alpha", "text"])
        let third = try #require(root.child(at: 2)?.destination?.page)
        #expect(document.index(for: third) == 5)
    }

    @Test func withoutExtrasPagesFollowEachOtherAndNoOutline() async throws {
        let inputs = try FilesFixture.copy(["text.pdf", "tiny.png"])
        var options = MergeFilesTool.Options()
        options.bookmarks = false
        let report = try await runJob(MergeFilesTool().work(inputs: inputs, options: options))
        let output = try #require(report.outputs.first)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(document.outlineRoot == nil)
    }

    @Test func aLockedInputStopsTheMergeAndNamesIt() async throws {
        let inputs = try FilesFixture.copy(["text.pdf", "encrypted.pdf"])
        await #expect(throws: FileToolError.message("Couldn't read encrypted.pdf: the file is password-protected.")) {
            try await runJob(MergeFilesTool().work(inputs: inputs, options: MergeFilesTool.Options()))
        }
        let folder = try FileManager.default.contentsOfDirectory(atPath: inputs[0].deletingLastPathComponent().path(percentEncoded: false))
        #expect(folder.sorted() == ["encrypted.pdf", "text.pdf"])
    }

    @Test func cancellingLeavesNoOutputOrTemporaryFiles() async throws {
        let inputs = try FilesFixture.copy(["big.pdf", "latex-article.pdf"])
        var options = MergeFilesTool.Options()
        options.format = .word
        let work = MergeFilesTool().work(inputs: inputs, options: options)
        let context = JobContext(tool: work.tool)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("CheeseMerge-") })
        let task = Task { try await work.run(context) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        context.discardOutputs()
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("CheeseMerge-") })
        #expect(after.subtracting(before).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inputs[0].deletingLastPathComponent().path(percentEncoded: false)).sorted() == ["big.pdf", "latex-article.pdf"])
    }

    @Test func wordMergeOfPDFsAndImages() async throws {
        let inputs = try FilesFixture.copy(["text.pdf", "rotated.jpg", "alpha.png", "latex-article.pdf"])
        var options = MergeFilesTool.Options()
        options.format = .word
        options.dividers = true
        let report = try await runJob(MergeFilesTool().work(inputs: inputs, options: options))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Merged (4 files).docx")
        let text = try DocxFixtureReader.text(output)
        for expected in ["Quarterly Report", "Next Steps", "rotated.jpg", "alpha.png", "efficient", "Discussion"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        let media = try DocxFixtureReader.parts(output).keys.filter { $0.hasPrefix("word/media/") }
        // Two images plus the article's six pictures.
        #expect(media.count == 8, "\(media.sorted())")
        // Cocoa reads the merged package back.
        let attributed = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(attributed.string.contains("Quarterly Report") && attributed.string.contains("efficient"))
    }
}

/// Merges through WebKit and the Office renderers: `make test-integration`.
@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct MergeFilesIntegrationTests {
    private let mixed = ["rich.docx", "rotated.jpg", "photo.webp", "latex-article.pdf", "notes.md", "merged.xlsx", "media.pptx", "notes-image.png"]

    @Test func everyKindToPDF() async throws {
        let inputs = Array(try FilesFixture.copy(mixed).dropLast())
        let report = try await runJob(MergeFilesTool().work(inputs: inputs, options: MergeFilesTool.Options()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        let text = TestPDFs.pageTexts(output).joined(separator: "\n")
        for expected in ["Field Guide", "Introduction", "Trip Notes", "Quarterly Summary", "Route overview"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        let root = try #require(PDFDocument(url: output)?.outlineRoot)
        #expect(root.numberOfChildren == 7)
    }

    @Test func everyKindToWord() async throws {
        let inputs = Array(try FilesFixture.copy(mixed).dropLast())
        var options = MergeFilesTool.Options()
        options.format = .word
        options.pageNumbers = true
        let report = try await runJob(MergeFilesTool().work(inputs: inputs, options: options))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        let text = try DocxFixtureReader.text(output)
        // Word content for real (its list, table and image), the PDF as text, Markdown, and Excel as a table.
        for expected in ["Field Guide", "Pack the tent", "Lantern", "efficient", "Trip Notes", "Ridge", "Summary", "Quarterly Summary", "250", "Column 12"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        let xml = try DocxFixtureReader.documentXML(output)
        #expect(xml.components(separatedBy: "<w:tbl>").count >= 5)
        let media = try DocxFixtureReader.parts(output).keys.filter { $0.hasPrefix("word/media/") }
        // rich.docx's chart, two photos, six article pictures, the Markdown picture and two slides.
        #expect(media.count >= 12, "\(media.sorted())")
        // The first file's header and footer are kept, and the page number replaces the footer.
        #expect(xml.contains("headerReference") && xml.contains("rIdCheeseFooter"))
        let attributed = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(attributed.string.contains("Pack the tent"))
        // LibreOffice opens it too, when it's installed.
        if let libreOffice = InstalledOfficeApps.libreOffice {
            let pdf = output.deletingLastPathComponent().appending(path: "check.pdf")
            try await NativeConverter(app: .libreOffice, location: libreOffice).convert(output, kind: .word, to: pdf)
            let rendered = TestPDFs.pageTexts(pdf).joined(separator: "\n")
            #expect(rendered.contains("Field Guide") && rendered.contains("Quarterly Summary") && rendered.contains("Trip Notes"))
        }
    }
}
