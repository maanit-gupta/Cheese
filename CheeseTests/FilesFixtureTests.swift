import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import Cheese

/// End-to-end runs of every Files tool on the self-made fixtures in Fixtures/Files, asserting what
/// can be checked mechanically: the output opens, holds the expected text and pages, and has no
/// replacement or private-use characters. The slow ones (WebKit, OCR) are in the integration suite.

extension FilesFixture {
    /// Copies several fixtures into one temporary folder (so relative references like a Markdown
    /// file's image still resolve) and returns them in order.
    static func copy(_ names: [String]) throws -> [URL] {
        let folder = makeTemporaryDirectory()
        return try names.map { name in
            let source = try copy(name)
            let destination = folder.appending(path: name)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }
}

enum DocxFixtureReader {
    static func parts(_ url: URL) throws -> [String: Data] {
        try ZipArchive.read(Data(contentsOf: url))
    }

    static func documentXML(_ url: URL) throws -> String {
        String(decoding: try parts(url)[DocxImageEmbedder.documentPath] ?? Data(), as: UTF8.self)
    }

    /// The text of every paragraph (runs joined, paragraphs on their own lines): what Word shows, tables and all.
    static func text(_ url: URL) throws -> String {
        let xml = try documentXML(url)
        return xml.components(separatedBy: "</w:p>").map { paragraph in
            paragraph.matches(of: /<w:t(?:\s[^>]*)?>([^<]*)<\/w:t>/).map { String($0.1) }.joined()
        }.joined(separator: "\n")
            .replacing("&amp;", with: "&").replacing("&lt;", with: "<").replacing("&gt;", with: ">")
    }

    static func hasBadCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0xFFFD || (0xE000...0xF8FF).contains($0.value) }
    }
}

private func pageCount(_ url: URL) -> Int {
    PDFDocument(url: url)?.pageCount ?? 0
}

private func pixelSize(_ url: URL) -> CGSize {
    let properties = FileFixtures.properties(of: url)
    return CGSize(width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

@MainActor
struct PDFToWordFixtureTests {
    /// The LaTeX article: ligatures, kerned words, hyphenation, two columns, inline and display math.
    @Test func latexArticleKeepsWordsAndTurnsEquationsIntoPictures() async throws {
        let input = try FilesFixture.copy("latex-article.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        let text = try DocxFixtureReader.text(output)
        let xml = try DocxFixtureReader.documentXML(output)

        // Ligatures (fi, fl, ff, ffi, ffl) come back as letters.
        for word in ["efficient", "fluent", "office", "officers", "difficult", "baffled", "affine", "shuffle", "Affluent", "fluffy"] {
            #expect(text.contains(word), "missing \(word)")
        }
        #expect(!text.unicodeScalars.contains { PageLayoutPlanner.isPresentationForm($0) })
        #expect(!DocxFixtureReader.hasBadCharacters(text))
        // Words hyphenated at line ends are joined; real compounds keep their hyphens.
        for word in ["parameter", "configuration", "interval", "spacing", "vocabulary", "notation", "state-of-the-art", "well-known"] {
            #expect(text.contains(word), "missing \(word)")
        }
        #expect(!text.contains("stateof"))
        // Inline math: real superscripts and subscripts, Greek letters as Unicode.
        #expect(xml.contains(#"<w:vertAlign w:val="superscript"/>"#))
        #expect(xml.contains(#"<w:vertAlign w:val="subscript"/>"#))
        for symbol in ["α", "β", "γ", "∞", "Ω"] {
            #expect(text.contains(symbol))
        }
        // Display equations are pictures (five: (4) and (5) are aligned in one), plus the figure; numbered ones keep their number as text.
        let media = try DocxFixtureReader.parts(output).keys.filter { $0.hasPrefix("word/media/") }
        #expect(media.count == 6, "\(media.sorted())")
        for number in ["(1)", "(2)", "(3)", "(6)"] {
            #expect(text.contains(number))
        }
        #expect(!text.contains("∫"))
        // The table is a Word table.
        #expect(xml.contains("<w:tbl>"))
        #expect(text.contains("Configuration") && text.contains("Seconds") && text.contains("11.5"))
        // Two columns read in order; running header and footer dropped; no picture-font garbage.
        let method = try #require(text.range(of: "Method"))
        let results = try #require(text.range(of: "Results"))
        let discussion = try #require(text.range(of: "Discussion"))
        #expect(method.lowerBound < results.lowerBound && results.lowerBound < discussion.lowerBound)
        #expect(!text.contains("Cheese Fixture Journal"))
        #expect(!text.contains("Page 1") && !text.contains("Page 2"))
        #expect(!text.contains("@"))
    }

    @Test func rotatedPagesKeepTheirText() async throws {
        let input = try FilesFixture.copy("rotated.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let output = try #require(report.outputs.first)
        let text = try DocxFixtureReader.text(output)
        #expect(text.contains("Upright first page"))
        #expect(text.contains("Landscape page shown turned"))
    }

    @Test(arguments: [
        ("encrypted.pdf", "password-protected"),
        ("corrupt.pdf", "couldn't be opened"),
        // Neither PDFKit nor Core Graphics opens a PDF without pages.
        ("empty.pdf", "couldn't be opened"),
    ])
    func brokenPDFsFailWithAReason(_ name: String, _ reason: String) async throws {
        let input = try FilesFixture.copy(name)
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        #expect(report.outputs.isEmpty)
        let failure = try #require(report.failures.first)
        #expect(failure.reason.localizedCaseInsensitiveContains(reason), "\(failure.reason)")
    }

    @Test func cancellingABigConversionLeavesNothingBehind() async throws {
        let input = try FilesFixture.copy("big.pdf")
        let work = PDFToDocxTool().work(inputs: [input], options: NoOptions())
        let context = JobContext(tool: work.tool)
        let task = Task { try await work.run(context) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        context.discardOutputs()
        let leftovers = try FileManager.default.contentsOfDirectory(at: input.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(leftovers.map(\.lastPathComponent) == ["big.pdf"])
    }
}

@MainActor
struct PDFToolsFixtureTests {
    @Test func mergeKeepsRotationAndRefusesLockedFiles() async throws {
        let inputs = try FilesFixture.copy(["latex-article.pdf", "rotated.pdf", "text.pdf"])
        let report = try await runJob(MergeFilesTool().work(inputs: inputs, options: MergeFilesTool.Options()))
        let output = try #require(report.outputs.first)
        #expect(pageCount(output) == 6)
        #expect(PDFDocument(url: output)?.page(at: 3)?.rotation == 90)

        let locked = try FilesFixture.copy(["text.pdf", "encrypted.pdf"])
        await #expect(throws: (any Error).self) { try await runJob(MergeFilesTool().work(inputs: locked, options: MergeFilesTool.Options())) }
    }

    @Test func splitABigPDFEveryHundredPages() async throws {
        let input = try FilesFixture.copy("big.pdf")
        let report = try await runJob(SplitTool().work(inputs: [input], options: SplitTool.Options(mode: .everyN, everyN: 100)))
        let folder = try #require(report.outputs.first)
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(parts.map(pageCount) == [100, 100, 20])
    }

    @Test func editPagesDropsAPageOfTheArticle() async throws {
        let input = try FilesFixture.copy("latex-article.pdf")
        let model = PageEditorModel(url: input, pageCount: 2)
        model.click(1, modifiers: [])
        model.deleteSelected()
        let report = try await runJob(model.saveWork())
        let output = try #require(report.outputs.first)
        #expect(pageCount(output) == 1)
        #expect(TestPDFs.pageTexts(output).first?.contains("Introduction") == true)
    }

    @Test func compressShrinksAPhotoHeavyPDF() async throws {
        let input = try FilesFixture.copy("mixed.pdf")
        let original = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let report = try await runJob(CompressTool().work(inputs: [input], options: CompressTool.Options(targetMB: Double(original) / 2 / 1_000_000)))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
        #expect(size < original)
        #expect(pageCount(output) == 2)
    }

    @Test func watermarkAndNumbersOnTheArticleKeepItsText() async throws {
        let input = try FilesFixture.copy("latex-article.pdf")
        let watermarked = try await runJob(WatermarkTool().work(inputs: [input], options: WatermarkTool.Options()))
        let marked = try #require(watermarked.outputs.first)
        let texts = TestPDFs.pageTexts(marked)
        #expect(texts.count == 2)
        #expect(texts[0].contains("CONFIDENTIAL") && texts[0].contains("Introduction"))

        let numbered = try await runJob(PageNumbersTool().work(inputs: [input], options: PageNumbersTool.Options(format: .pageOf)))
        let numberedOutput = try #require(numbered.outputs.first)
        #expect(TestPDFs.pageTexts(numberedOutput).last?.contains("Page 2 of 2") == true)
    }

    @Test func pageNumbersStayUprightOnARotatedPage() async throws {
        let input = try FilesFixture.copy("rotated.pdf")
        let report = try await runJob(PageNumbersTool().work(inputs: [input], options: PageNumbersTool.Options(format: .slash)))
        let output = try #require(report.outputs.first)
        #expect(TestPDFs.pageTexts(output).last?.contains("2 / 2") == true)
    }

    @Test func pdfToImagesTurnsTheRotatedPage() async throws {
        let input = try FilesFixture.copy("rotated.pdf")
        let report = try await runJob(PDFToImagesTool().work(inputs: [input], options: PDFToImagesTool.Options(format: .png, dpi: 72)))
        let folder = try #require(report.outputs.first)
        let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(images.count == 2)
        #expect(pixelSize(images[0]) == CGSize(width: 612, height: 792))
        #expect(pixelSize(images[1]) == CGSize(width: 792, height: 612))
    }

    @Test func pdfToExcelUnfoldsLigatures() async throws {
        let input = try FilesFixture.copy("latex-article.pdf")
        let report = try await runJob(PDFToXlsxTool().work(inputs: [input], options: NoOptions()))
        let output = try #require(report.outputs.first)
        let sheets = try SheetJSWriter.readRows(Data(contentsOf: output))
        let cells = sheets.values.flatMap { $0.flatMap { $0 } }.joined(separator: " ")
        #expect(cells.contains("Efficient"))
        #expect(!cells.unicodeScalars.contains { PageLayoutPlanner.isPresentationForm($0) })
        #expect(!DocxFixtureReader.hasBadCharacters(cells))
    }
}

@MainActor
struct ImageToolsFixtureTests {
    private static let everyImage = ["alpha.png", "rotated.jpg", "photo.tiff", "photo.webp", "animated.gif", "tiny.png", "photo.heic"]

    @Test func imagesToPDFMakesAnUprightPageForEveryFormat() async throws {
        let inputs = try FilesFixture.copy(Self.everyImage)
        let report = try await runJob(ImagesToPDFTool().work(inputs: inputs, options: ImagesToPDFTool.Options()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == Self.everyImage.count)
        // rotated.jpg is 600×400 stored with orientation 6: it shows 400×600.
        let rotated = try #require(document.page(at: 1)?.bounds(for: .mediaBox))
        #expect(rotated.height > rotated.width)
    }

    @Test func convertEveryFormatToPNG() async throws {
        let inputs = try FilesFixture.copy(Self.everyImage.filter { $0 != "alpha.png" && $0 != "tiny.png" } + ["huge.png"])
        let report = try await runJob(ConvertImageTool().work(inputs: inputs, options: ConvertImageTool.Options(format: .png)))
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.outputs.count == inputs.count)
        let huge = try #require(report.outputs.first { $0.lastPathComponent.hasPrefix("huge") })
        #expect(pixelSize(huge) == CGSize(width: 12000, height: 12000))
    }

    @Test func alphaFlattensToJPEGAndTheTinyImageSurvives() async throws {
        let inputs = try FilesFixture.copy(["alpha.png", "tiny.png"])
        let report = try await runJob(ConvertImageTool().work(inputs: inputs, options: ConvertImageTool.Options(format: .jpeg)))
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.outputs.map(pixelSize) == [CGSize(width: 300, height: 200), CGSize(width: 1, height: 1)])
    }

    @Test func resizeTheHugeAndTheTinyImage() async throws {
        let inputs = try FilesFixture.copy(["huge.png", "tiny.png"])
        let report = try await runJob(ResizeImageTool().work(inputs: inputs, options: ResizeImageTool.Options(mode: .percentage, percent: 10)))
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.outputs.map(pixelSize) == [CGSize(width: 1200, height: 1200), CGSize(width: 1, height: 1)])
    }

    @Test func compressKeepsOrientationAndDropsNothingElse() async throws {
        let inputs = try FilesFixture.copy(["rotated.jpg", "photo.webp", "photo.tiff"])
        let report = try await runJob(CompressImageTool().work(inputs: inputs, options: CompressImageTool.Options(quality: 0.5)))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let jpeg = try #require(report.outputs.first { $0.pathExtension == "jpg" })
        #expect(FileFixtures.properties(of: jpeg)[kCGImagePropertyOrientation] as? Int == 6)
        if !ImageFormat.writable.contains(.webp) {
            #expect(report.outputs.contains { $0.lastPathComponent == "photo (compressed).heic" })
            #expect(report.notes.contains { $0.contains("compressed to HEIC") })
        }
    }

    @Test func removeBackgroundCutsOutTheSubject() async throws {
        let input = try FilesFixture.copy("alpha.png")
        let report = try await runJob(RemoveBackgroundTool().work(inputs: [input], options: NoOptions()))
        // A flat orange disc may or may not read as a subject; either way the result is honest.
        if let output = report.outputs.first {
            #expect(output.pathExtension == "png")
            #expect(FileFixtures.properties(of: output)[kCGImagePropertyHasAlpha] as? Bool == true)
        } else {
            #expect(report.failures.first?.reason.isEmpty == false)
        }
    }
}

/// Every fixture is offered the tools that take it, through the Finder menu, the drop hub and the menu.
struct FixtureApplicabilityTests {
    @Test func everyFixtureKindHasTools() {
        let expectations: [(String, ToolID)] = [
            ("latex-article.pdf", .pdfToWord), ("rich.docx", .wordToPDF), ("merged.xlsx", .excelToPDF), ("media.pptx", .powerPointToPDF),
            ("notes.md", .webToPDF), ("notes.md", .markdownToWord), ("page.html", .markdownToWord), ("scripts.txt", .webToPDF),
            ("photo.webp", .convertImage), ("animated.gif", .imagesToPDF), ("photo.tiff", .resizeImage), ("huge.png", .removeBackground),
        ]
        for (name, tool) in expectations {
            let url = URL(filePath: "/tmp/\(name)")
            #expect(ToolApplicability.tools(for: [url]).contains(tool), "\(name) → \(tool)")
        }
    }
}

/// The tools that render through WebKit, OCR, or take a while: `make test-integration`.
@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct FilesFixtureIntegrationTests {
    private func pdfText(_ url: URL) -> String {
        TestPDFs.pageTexts(url).joined(separator: "\n")
    }

    @Test func wordWithStylesListsTableImageAndHeaderBecomesPDF() async throws {
        let input = try FilesFixture.copy("rich.docx")
        let report = try await runJob(OfficeToPDFTool(kind: .word).work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        let text = pdfText(output)
        for expected in ["Field Guide", "bold", "Pack the tent", "Bring a map", "Lantern", "Compass", "Leave no trace", "The chart above"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        let page = try #require(PDFDocument(url: output)?.page(at: 0)?.pageRef)
        #expect(!PDFImageInspector.imageRects(on: page).isEmpty)
    }

    @Test func excelWithMergedCellsFormulasAndThreeSheets() async throws {
        let input = try FilesFixture.copy("merged.xlsx")
        let report = try await runJob(OfficeToPDFTool(kind: .excel).work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        #expect(pageCount(output) >= 3)
        let text = pdfText(output)
        for expected in ["Quarterly Summary", "North", "210", "250", "unaudited", "Column 12"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
    }

    @Test func powerPointWithAPictureAndTextBoxes() async throws {
        let input = try FilesFixture.copy("media.pptx")
        let report = try await runJob(OfficeToPDFTool(kind: .powerPoint).work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let output = try #require(report.outputs.first)
        #expect(pageCount(output) == 2)
        let text = pdfText(output)
        for expected in ["Route overview", "Two days", "Left box text", "Right box text"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        let page = try #require(PDFDocument(url: output)?.page(at: 0)?.pageRef)
        #expect(!PDFImageInspector.imageRects(on: page).isEmpty)
    }

    @Test func markdownHTMLAndNonLatinTextBecomePDF() async throws {
        let inputs = try FilesFixture.copy(["notes.md", "page.html", "scripts.txt", "notes-image.png"]).dropLast()
        let report = try await runJob(WebToPDFTool().work(inputs: Array(inputs), options: WebToPDFTool.Options()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.outputs.count == 3)
        let notes = pdfText(try #require(report.outputs.first { $0.lastPathComponent == "notes.pdf" }))
        for expected in ["Trip Notes", "Ridge", "greeting", "Water"] {
            #expect(notes.contains(expected), "missing \(expected)")
        }
        // Front matter is metadata, not body text.
        #expect(!notes.contains("tags:"))
        let notesOutput = try #require(report.outputs.first { $0.lastPathComponent == "notes.pdf" })
        let markdownPage = try #require(PDFDocument(url: notesOutput)?.page(at: 0)?.pageRef)
        // The local picture (240×120), not a broken-image icon.
        #expect(PDFImageInspector.imageRects(on: markdownPage).contains { $0.width > 100 })
        let htmlOutput = try #require(report.outputs.first { $0.lastPathComponent == "page.pdf" })
        let html = pdfText(htmlOutput)
        #expect(html.contains("Station Report") && html.contains("Humidity"))
        let htmlPage = try #require(PDFDocument(url: htmlOutput)?.page(at: 0)?.pageRef)
        #expect(PDFImageInspector.imageRects(on: htmlPage).contains { $0.width > 100 })
        let scriptsOutput = try #require(report.outputs.first { $0.lastPathComponent == "scripts.pdf" })
        let scripts = PageLayoutPlanner.normalizedText(pdfText(scriptsOutput))
        for expected in ["नमस्ते", "你好", "こんにちは", "مرحبا"] {
            #expect(scripts.contains(expected), "missing \(expected) in \(scripts)")
        }
    }

    @Test func markdownAndHTMLBecomeWord() async throws {
        let inputs = try FilesFixture.copy(["notes.md", "page.html", "notes-image.png"]).dropLast()
        let report = try await runJob(MarkdownToDocxTool().work(inputs: Array(inputs), options: NoOptions()))
        #expect(report.failures.isEmpty, "\(report.failures)")
        let notes = try DocxFixtureReader.text(try #require(report.outputs.first { $0.lastPathComponent == "notes.docx" }))
        for expected in ["Trip Notes", "Ridge", "greeting", "Water"] {
            #expect(notes.contains(expected), "missing \(expected)")
        }
        #expect(!notes.contains("tags:"))
        let station = try DocxFixtureReader.text(try #require(report.outputs.first { $0.lastPathComponent == "page.docx" }))
        #expect(station.contains("Station Report") && station.contains("Humidity"))
        // Tables are Word tables and local pictures come along.
        for name in ["notes.docx", "page.docx"] {
            let output = try #require(report.outputs.first { $0.lastPathComponent == name })
            #expect(try DocxFixtureReader.documentXML(output).contains("<w:tbl>"), "\(name)")
            #expect(try DocxFixtureReader.parts(output).keys.contains { $0.hasPrefix("word/media/") }, "\(name)")
        }
    }

    @Test func textWithoutAUnicodeMapIsReadWithOCR() async throws {
        let input = try FilesFixture.copy("no-unicode.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let output = try #require(report.outputs.first)
        let text = try DocxFixtureReader.text(output)
        for expected in ["Readable heading", "extracts cleanly", "Hidden invoice number 4471", "Every line on this page", "read with OCR"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        #expect(!DocxFixtureReader.hasBadCharacters(text))

        let sheet = try await runJob(PDFToXlsxTool().work(inputs: [input], options: NoOptions()))
        let sheetOutput = try #require(sheet.outputs.first)
        let cells = try SheetJSWriter.readRows(Data(contentsOf: sheetOutput)).values.flatMap { $0.flatMap { $0 } }.joined(separator: " ")
        #expect(cells.contains("4471"))
    }

    @Test func aBigPDFConvertsToWordInReasonableTime() async throws {
        let input = try FilesFixture.copy("big.pdf")
        let clock = ContinuousClock()
        let start = clock.now
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let elapsed = clock.now - start
        #expect(report.failures.isEmpty)
        let text = try DocxFixtureReader.text(try #require(report.outputs.first))
        #expect(text.contains("Chapter 1") && text.contains("Chapter 220"))
        #expect(elapsed < .seconds(60), "took \(elapsed)")
    }
}

/// The Microsoft Office and LibreOffice bridges, run for real when the app is installed. Microsoft
/// Office needs an Automation grant for the test host and opens visibly, so it also needs
/// `TEST_RUNNER_FILES_NATIVE_OFFICE=1`.
enum InstalledOfficeApps {
    static var libreOffice: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: NativeOfficeApp.libreOffice.rawValue) }
    static var word: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: NativeOfficeApp.word.rawValue) }
    static var runsMicrosoft: Bool { ProcessInfo.processInfo.environment["FILES_NATIVE_OFFICE"] == "1" }
}

@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct NativeOfficeBridgeTests {
    @Test(.enabled(if: InstalledOfficeApps.libreOffice != nil, "LibreOffice isn't installed"))
    func libreOfficeConvertsWordToPDF() async throws {
        let input = try FilesFixture.copy("rich.docx")
        var tool = OfficeToPDFTool(kind: .word)
        tool.nativeOverride = NativeConverter(app: .libreOffice, location: try #require(InstalledOfficeApps.libreOffice))
        let report = try await runJob(tool.work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty && report.notes.isEmpty, "\(report.failures) \(report.notes)")
        #expect(TestPDFs.pageTexts(try #require(report.outputs.first)).joined().contains("Field Guide"))
    }

    @Test(.enabled(if: InstalledOfficeApps.word != nil, "Microsoft Word isn't installed"),
          .enabled(if: InstalledOfficeApps.runsMicrosoft, "needs TEST_RUNNER_FILES_NATIVE_OFFICE=1 (Automation prompt, Word opens visibly)"))
    func microsoftWordConvertsWordToPDF() async throws {
        let input = try FilesFixture.copy("rich.docx")
        var tool = OfficeToPDFTool(kind: .word)
        tool.nativeOverride = NativeConverter(app: .word, location: try #require(InstalledOfficeApps.word))
        let report = try await runJob(tool.work(inputs: [input], options: NoOptions()))
        #expect(report.failures.isEmpty && report.notes.isEmpty, "\(report.failures) \(report.notes)")
        #expect(TestPDFs.pageTexts(try #require(report.outputs.first)).joined().contains("Field Guide"))
    }
}
