import AppKit
import Foundation
import Testing
@testable import Cheese

/// A line at `top` (y grows downward) with one run.
private func line(_ text: String, top: CGFloat, size: CGFloat = 11, x: CGFloat = 72, bold: Bool = false, italic: Bool = false) -> LayoutLine {
    LayoutLine(
        runs: [LayoutRun(text: text, fontSize: size, isBold: bold, isItalic: italic)],
        frame: CGRect(x: x, y: top, width: CGFloat(text.count) * size * 0.5, height: size * 1.2)
    )
}

struct TextLayoutAnalyzerTests {
    @Test func groupsLinesIntoParagraphsByVerticalGaps() {
        let lines = [
            line("First paragraph line one", top: 100),
            line("continues here.", top: 114),
            line("Second paragraph after a gap.", top: 150),
        ]
        let blocks = TextLayoutAnalyzer.blocks(lines: lines)
        #expect(blocks.count == 2)
        #expect(blocks.first?.text == "First paragraph line one continues here.")
        #expect(blocks.last?.text == "Second paragraph after a gap.")
    }

    @Test func detectsHeadingsRelativeToTheBodySize() {
        let lines = [
            line("Quarterly Report", top: 60, size: 24, bold: true),
            line("Body text that is long enough to be the median size of this page.", top: 100),
            line("More body text, also at the body size for the page median.", top: 114),
            line("Highlights", top: 150, size: 16, bold: true),
            line("Small Caption", top: 190, size: 11, bold: true),
        ]
        let blocks = TextLayoutAnalyzer.blocks(lines: lines)
        #expect(blocks.map(\.kind) == [.heading(level: 1), .paragraph, .heading(level: 2), .paragraph])
    }

    @Test func detectsBulletedAndNumberedLists() {
        let lines = [
            line("Shopping:", top: 100),
            line("•  Apples", top: 130),
            line("•  Pears", top: 145),
            line("- Plums", top: 160),
            line("1. First step", top: 190),
            line("2) Second step", top: 205),
        ]
        let blocks = TextLayoutAnalyzer.blocks(lines: lines)
        #expect(blocks.map(\.kind) == [.paragraph, .listItem(ordered: false), .listItem(ordered: false), .listItem(ordered: false), .listItem(ordered: true), .listItem(ordered: true)])
        #expect(blocks[1].text == "Apples")
        #expect(blocks[5].text == "Second step")
    }

    @Test func keepsBoldAndItalicRunsAndJoinsHyphenatedWords() {
        var mixed = line("Bold claim:", top: 100, bold: true)
        mixed.runs.append(LayoutRun(text: " an italic aside", fontSize: 11, isBold: false, isItalic: true))
        let blocks = TextLayoutAnalyzer.blocks(lines: [mixed, line("and a hyphen-", top: 114), line("ated word.", top: 128)])
        let runs = blocks.first?.runs ?? []
        #expect(runs.first?.isBold == true)
        #expect(runs.contains { $0.isItalic })
        #expect(blocks.first?.text == "Bold claim: an italic aside and a hyphenated word.")
    }

    @Test func placesImagesInReadingOrder() {
        let lines = [line("Above the photo.", top: 100), line("Below the photo.", top: 400)]
        let images = [LayoutImage(id: 7, frame: CGRect(x: 72, y: 150, width: 300, height: 200))]
        let blocks = TextLayoutAnalyzer.blocks(lines: lines, images: images)
        #expect(blocks.map(\.kind) == [.paragraph, .image(7), .paragraph])
    }

    @Test func bodySizeIsTheMedianByCharacters() {
        let lines = [line("H", top: 0, size: 30), line("lots of body characters here", top: 40, size: 10)]
        #expect(TextLayoutAnalyzer.bodySize(of: lines) == 10)
        #expect(TextLayoutAnalyzer.bodySize(of: []) == 0)
    }
}

private func word(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat? = nil) -> PositionedWord {
    PositionedWord(text: text, frame: CGRect(x: x, y: top, width: width ?? CGFloat(text.count) * 5.5, height: 12))
}

struct TableDetectorTests {
    /// Region / Units / Revenue with right-aligned numbers, like tables.pdf.
    private var salesWords: [PositionedWord] {
        [
            word("Region", x: 72, top: 100), word("Units", x: 200, top: 100), word("Revenue", x: 300, top: 100),
            word("North", x: 72, top: 116), word("120", x: 208, top: 116), word("4,500.50", x: 300, top: 116),
            word("South", x: 72, top: 132), word("98", x: 213, top: 132), word("3,120.00", x: 300, top: 132),
            // A row with only its first cell filled still belongs to the table.
            word("East", x: 72, top: 148),
        ]
    }

    @Test func rowsAndColumnsFromAlignment() {
        let tables = TableDetector.tables(in: salesWords)
        #expect(tables.count == 1)
        let rows = tables.first?.rows ?? []
        #expect(rows.first == ["Region", "Units", "Revenue"])
        #expect(rows[1] == ["North", "120", "4,500.50"])
        #expect(rows.last == ["East", "", ""])
    }

    @Test func wordsCloseTogetherFormOneCell() {
        let words = [
            word("Item", x: 72, top: 100), word("On", x: 240, top: 100), word("hand", x: 254, top: 100),
            word("Blue", x: 72, top: 116), word("widgets", x: 97, top: 116), word("1,204", x: 240, top: 116),
        ]
        #expect(TableDetector.tables(in: words).first?.rows == [["Item", "On hand"], ["Blue widgets", "1,204"]])
    }

    @Test func aParagraphBetweenTablesSplitsThem() {
        var words = salesWords
        words.append(word("Inventory is counted at the end of the quarter, every quarter.", x: 72, top: 190, width: 330))
        words += [word("Item", x: 72, top: 230), word("Reorder", x: 240, top: 230), word("Gears", x: 72, top: 246), word("150", x: 240, top: 246)]
        let tables = TableDetector.tables(in: words)
        #expect(tables.count == 2)
        #expect(tables.last?.rows == [["Item", "Reorder"], ["Gears", "150"]])
    }

    @Test func pagesWithoutTablesKeepTheirLines() {
        let words = [word("Just", x: 72, top: 100), word("text.", x: 99, top: 100), word("More", x: 72, top: 116)]
        #expect(TableDetector.tables(in: words).isEmpty)
        #expect(TableDetector.rows(in: words) == [["Just text."], ["More"]])
    }

    @Test func sheetsArePerPageOrPerTable() {
        let one = TableDetector.sheets(forPage: 1, words: salesWords)
        #expect(one.map(\.name) == ["Page 1"])
        var words = salesWords
        words.append(word("A paragraph that separates the two tables on this page.", x: 72, top: 190, width: 330))
        words += [word("Item", x: 72, top: 230), word("Reorder", x: 240, top: 230), word("Gears", x: 72, top: 246), word("150", x: 240, top: 246)]
        #expect(TableDetector.sheets(forPage: 2, words: words).map(\.name) == ["Page 2 Table 1", "Page 2 Table 2"])
        #expect(TableDetector.sheets(forPage: 3, words: []).isEmpty)
    }
}

struct CellValueParserTests {
    private let us = Locale(identifier: "en_US")
    private let germany = Locale(identifier: "de_DE")

    @Test func numbersFollowTheLocale() {
        #expect(CellValueParser.parse("4,500.50", locale: us) == .number(4500.5))
        #expect(CellValueParser.parse("4.500,50", locale: germany) == .number(4500.5))
        #expect(CellValueParser.parse("-12", locale: us) == .number(-12))
        #expect(CellValueParser.parse("12%", locale: us) == .number(0.12))
        #expect(CellValueParser.parse("$1,200", locale: us) == .number(1200))
    }

    @Test func datesBecomeDates() throws {
        guard case let .date(date) = CellValueParser.parse("2026-01-15", locale: us) else {
            Issue.record("Expected a date")
            return
        }
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .gmt, from: date)
        #expect(parts.year == 2026 && parts.month == 1 && parts.day == 15)
        guard case .date = CellValueParser.parse("1/31/2026", locale: us) else {
            Issue.record("Expected a US short date")
            return
        }
    }

    @Test func everythingElseStaysText() {
        #expect(CellValueParser.parse("North", locale: us) == .text("North"))
        #expect(CellValueParser.parse("12 apples", locale: us) == .text("12 apples"))
        #expect(CellValueParser.parse("", locale: us) == .empty)
        #expect(CellValueParser.parse("1,2,3", locale: us) == .text("1,2,3"))
    }
}

struct DocxImageEmbedderTests {
    private let document = """
    <w:document xmlns:r="r" xmlns:wp="wp"><w:body><w:p><w:r><w:rPr/><w:t xml:space="preserve">CHEESEIMAGE0001X</w:t></w:r></w:p></w:body></w:document>
    """
    private let relationships = """
    <Relationships xmlns="x"><Relationship Id="rId1" Type="t" Target="theme/theme1.xml"/></Relationships>
    """
    private let contentTypes = """
    <Types xmlns="x"><Default Extension="xml" ContentType="application/xml"/></Types>
    """

    @Test func replacesTheTokenAndAddsPartsAndRelationships() throws {
        var parts = [
            "word/document.xml": Data(document.utf8),
            "word/_rels/document.xml.rels": Data(relationships.utf8),
            "[Content_Types].xml": Data(contentTypes.utf8),
        ]
        let image = DocxImage(token: DocxImage.token(1), png: Data([1, 2, 3]), size: CGSize(width: 72, height: 36))
        try DocxImageEmbedder.embed([image], into: &parts)

        let xml = String(decoding: parts["word/document.xml"] ?? Data(), as: UTF8.self)
        #expect(!xml.contains("CHEESEIMAGE0001X"))
        #expect(xml.contains("<w:drawing>"))
        #expect(xml.contains("r:embed=\"rIdCheeseImage1\""))
        #expect(xml.contains("cx=\"914400\" cy=\"457200\""))
        #expect(parts["word/media/cheese-image-1.png"] == Data([1, 2, 3]))
        let rels = String(decoding: parts["word/_rels/document.xml.rels"] ?? Data(), as: UTF8.self)
        #expect(rels.contains("Id=\"rIdCheeseImage1\""))
        #expect(rels.contains("Target=\"media/cheese-image-1.png\""))
        let types = String(decoding: parts["[Content_Types].xml"] ?? Data(), as: UTF8.self)
        #expect(types.contains("Extension=\"png\""))
    }

    @Test func missingTokensAreAnError() {
        var parts = ["word/document.xml": Data("<w:document/>".utf8)]
        let image = DocxImage(token: DocxImage.token(2), png: Data(), size: .zero)
        #expect(throws: (any Error).self) { try DocxImageEmbedder.embed([image], into: &parts) }
    }
}

struct OfficePackageTests {
    @Test func zipRoundTripsParts() throws {
        let parts = ["[Content_Types].xml": Data("<Types/>".utf8), "word/document.xml": Data("<w:document/>".utf8), "word/media/a.png": Data([0, 1, 2, 255])]
        let zip = try ZipArchive.write(parts)
        #expect(zip.starts(with: [0x50, 0x4B]))
        #expect(try ZipArchive.read(zip) == parts)
    }

    @Test func workbookKeepsNumbersDatesAndSheetNames() throws {
        let date = try #require(CellValueParser.date("2026-01-15", locale: Locale(identifier: "en_US")))
        let data = try SheetJSWriter.workbook([
            SheetJSWriter.Sheet(name: "Page 1", rows: [[.text("Region"), .text("Revenue"), .text("Due")], [.text("North"), .number(4500.5), .date(date)]]),
            SheetJSWriter.Sheet(name: "Page 1", rows: [[.empty, .text("x")]]),
        ])
        let sheets = try SheetJSWriter.readRows(data)
        #expect(Set(sheets.keys) == ["Page 1", "Page 1 2"])
        #expect(sheets["Page 1"]?.last == ["North", "4500.5", "2026-01-15"])
        #expect(SheetJSWriter.serial(date) == 46_037)
    }
}

@MainActor
@Suite(.enabled(if: Integration.isEnabled))
struct PDFToOfficeIntegrationTests {
    private func docxText(_ url: URL) throws -> NSAttributedString {
        try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
    }

    @Test func textPDFRoundTripsToWordWithHeadingsAndPageBreaks() async throws {
        let input = try FilesFixture.copy("text.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "text.docx")
        let text = try docxText(output)
        #expect(text.string.contains("Quarterly Report"))
        #expect(text.string.contains("Next Steps"))
        let heading = (text.string as NSString).range(of: "Quarterly Report")
        let headingFont = text.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont
        let body = (text.string as NSString).range(of: "This report summarizes")
        let bodyFont = text.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
        #expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0))
        let document = try ZipArchive.read(Data(contentsOf: output))[DocxImageEmbedder.documentPath].map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(document.contains("w:type=\"page\""))
        #expect(text.string.contains("New customers in three regions"))
    }

    @Test func imagesCarryOverIntoWord() async throws {
        let input = try FilesFixture.copy("mixed.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let parts = try ZipArchive.read(Data(contentsOf: try #require(report.outputs.first)))
        #expect(parts.keys.contains { $0.hasPrefix("word/media/") })
        let document = String(decoding: parts[DocxImageEmbedder.documentPath] ?? Data(), as: UTF8.self)
        #expect(document.contains("<w:drawing>"))
        #expect(document.contains("Field Trip"))
    }

    @Test func scannedPagesAreReadWithOCR() async throws {
        let input = try FilesFixture.copy("scanned.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let text = try docxText(try #require(report.outputs.first))
        #expect(text.string.contains("SCANNED INVOICE"))
    }

    @Test func tablesBecomeSheetsWithNumbers() async throws {
        let input = try FilesFixture.copy("tables.pdf")
        let report = try await runJob(PDFToXlsxTool().work(inputs: [input], options: NoOptions()))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "tables.xlsx")
        let sheets = try SheetJSWriter.readRows(Data(contentsOf: output))
        #expect(Set(sheets.keys) == ["Page 1 Table 1", "Page 1 Table 2"])
        let sales = try #require(sheets["Page 1 Table 1"])
        #expect(sales.first == ["Region", "Units", "Revenue", "Date"])
        #expect(sales.contains(["North", "120", "4500.5", "2026-01-15"]))
        let inventory = try #require(sheets["Page 1 Table 2"])
        #expect(inventory.contains(["Gears", "88", "150"]))
    }
}
