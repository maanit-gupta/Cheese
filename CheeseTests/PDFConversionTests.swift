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

    @Test func multiColumnPagesKeepBothColumnsText() async throws {
        let input = try FilesFixture.copy("multicolumn.pdf")
        let report = try await runJob(PDFToDocxTool().work(inputs: [input], options: NoOptions()))
        let text = try docxText(try #require(report.outputs.first)).string
        #expect(text.contains("Two Column Newsletter"))
        #expect(text.contains("Left column line 18"))
        #expect(text.contains("Right column line 18"))
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

// MARK: - 2.5 PDF → Word rebuild

/// Characters set at `x`, one em apart unless `gaps` says otherwise, on a baseline at `baseline`.
private func chars(
    _ text: String, x: CGFloat = 72, baseline: CGFloat = 100, size: CGFloat = 10, font: String = "CMR10",
    advance: CGFloat? = nil
) -> [PageChar] {
    var position = x
    return text.map { character in
        let width = advance ?? size * 0.5
        defer { position += width }
        return PageChar(
            text: String(character), frame: CGRect(x: position, y: baseline - size * 0.75, width: width, height: size),
            fontSize: size, fontName: font, baseline: baseline
        )
    }
}

struct PageLayoutPlannerTests {
    @Test func ligaturesBecomeLettersSharingTheGlyphBox() {
        let ffi = PageChar(text: "\u{FB03}", frame: CGRect(x: 10, y: 0, width: 9, height: 10), fontSize: 10)
        let pieces = PageLayoutPlanner.normalized(ffi)
        #expect(pieces.map(\.text) == ["f", "f", "i"])
        #expect(pieces.map(\.frame.minX) == [10, 13, 16])
        #expect(PageLayoutPlanner.normalizedText("E\u{FB00}icient \u{FB02}ow") == "Efficient flow")
        #expect(PageLayoutPlanner.normalized(PageChar(text: "α", frame: .zero, fontSize: 10)).map(\.text) == ["α"])
    }

    @Test func unreadableTextIsPrivateUseReplacementOrControlCharacters() {
        #expect(PageLayoutPlanner.isUnreadable("\u{E001}\u{E002}\u{E003} x"))
        #expect(PageLayoutPlanner.isUnreadable("\u{01}\u{02}\u{03}\u{04}"))
        #expect(PageLayoutPlanner.isUnreadable("\u{FFFD}\u{FFFD}a"))
        #expect(!PageLayoutPlanner.isUnreadable("Plain text, α ≤ β"))
        #expect(!PageLayoutPlanner.isUnreadable("\u{E001}"))
    }

    @Test func gapsBecomeSpacesAndWideGapsBecomeCells() throws {
        // "word" then a 3 pt gap (0.3 em: a space), "kern" then 0.5 pt (kerning: no space), then 15 pt (a cell).
        let line = chars("word", x: 0) + chars("next", x: 23) + chars("ab", x: 43.5) + chars("cell", x: 68.5)
        let layout = try #require(PageLayoutPlanner.layoutLine(line))
        #expect(layout.text == "word nextab\tcell")
        #expect(layout.isTabular)
    }

    @Test func raisedAndLoweredSmallCharactersAreScripts() throws {
        var line = chars("x", x: 0)
        line += chars("2", x: 5, baseline: 96, size: 7)
        line += chars(" + a", x: 9)
        line += chars("i", x: 29, baseline: 101.5, size: 7)
        let layout = try #require(PageLayoutPlanner.layoutLine(line))
        #expect(layout.runs.map(\.script) == [.none, .superscript, .none, .subscript])
        #expect(layout.text == "x2 + ai")
        // A small character on the baseline (a footnote-size word) is not a script.
        let flat = try #require(PageLayoutPlanner.layoutLine(chars("ab", x: 0) + chars("c", x: 10, size: 7)))
        #expect(flat.runs.allSatisfy { $0.script == .none })
    }

    @Test func linesAreProseMathOrFragments() {
        #expect(PageLayoutPlanner.role(of: chars("The first finding is that", font: "CMR10")) == .prose)
        var equation = chars("u", font: "CMMI10") + chars("+", font: "CMR10") + chars("v", font: "CMMI10") + chars("=10,", font: "CMR10")
        #expect(PageLayoutPlanner.role(of: equation) == .math)
        equation = chars("cos", font: "CMR10") + chars("θ", font: "CMMI10") + chars("−", font: "CMSY10") + chars("sin", font: "CMR10") + chars("θ", font: "CMMI10")
        #expect(PageLayoutPlanner.role(of: equation) == .math)
        #expect(PageLayoutPlanner.role(of: chars("(4)")) == .fragment)
        #expect(PageLayoutPlanner.role(of: chars("lim")) == .fragment)
        // Inline math inside a sentence stays prose.
        let inline = chars("the error ", font: "CMR10") + chars("ϵ", font: "CMMI10") + chars(" for every one", font: "CMR10")
        #expect(PageLayoutPlanner.role(of: inline) == .prose)
    }

    @Test func displayEquationsBecomeRegionsWithTheirNumberAsText() throws {
        let before = chars("We define the transfer as an integral:", baseline: 100)
        let equation = chars("F", x: 120, baseline: 130, font: "CMMI10") + chars("=", x: 126, baseline: 130) + chars("x", x: 132, baseline: 130, font: "CMMI10")
            + chars("(1)", x: 290, baseline: 130)
        let limit = chars("0", x: 140, baseline: 138, size: 7, font: "CMR7")
        let after = chars("Equation one is evaluated numerically here.", baseline: 160)
        let columns = ColumnLayout(isTwoColumn: false, middle: 300)
        let (items, rest) = PageLayoutPlanner.equationRegions(lines: [before, equation, limit, after], paths: [], columns: columns)
        #expect(rest.count == 2)
        guard case let .equation(frame, number) = try #require(items.first) else {
            Issue.record("not an equation")
            return
        }
        #expect(number == "(1)")
        #expect(frame.minX < 121 && frame.maxX < 200)
        // Clipped to stay clear of the lines above and below.
        #expect(frame.minY >= 100 && frame.maxY <= 160)
    }

    @Test func twoAlignedNumbersStayInThePicture() {
        let rows = [chars("u=1", x: 120, baseline: 130, font: "CMMI10") + chars("(4)", x: 290, baseline: 130),
                    chars("v=2", x: 120, baseline: 142, font: "CMMI10") + chars("(5)", x: 290, baseline: 142)]
        #expect(PageLayoutPlanner.equationNumber(in: rows) == nil)
    }

    @Test func boxesOfLinesFormAFigureButRulesDoNot() {
        let frame = [CGRect(x: 100, y: 100, width: 180, height: 0.4), CGRect(x: 100, y: 190, width: 180, height: 0.4),
                     CGRect(x: 100, y: 100, width: 0.4, height: 90), CGRect(x: 280, y: 100, width: 0.4, height: 90),
                     CGRect(x: 120, y: 120, width: 40, height: 60)]
        let rule = [CGRect(x: 72, y: 400, width: 400, height: 0.5)]
        let figures = PageLayoutPlanner.figureRegions(paths: frame + rule, chars: [], pageSize: CGSize(width: 612, height: 792))
        #expect(figures.count == 1)
        #expect(figures.first?.contains(CGRect(x: 100, y: 100, width: 180, height: 90)) == true)
        // A ruled table full of text isn't a picture.
        let text = (0..<6).flatMap { row in chars("Cell text here", x: 110, baseline: 110 + CGFloat(row) * 12) }
        #expect(PageLayoutPlanner.figureRegions(paths: frame, chars: text, pageSize: CGSize(width: 612, height: 792)).isEmpty)
    }

    @Test func twoColumnPagesReadDownTheLeftThenTheRight() {
        let left = (0..<5).map { chars("left column words here \($0)", x: 60, baseline: 200 + CGFloat($0) * 12) }
        let right = (0..<5).map { chars("right column words now \($0)", x: 320, baseline: 200 + CGFloat($0) * 12, advance: 4) }
        let title = chars("A title across both columns of the page", x: 150, baseline: 100, advance: 8)
        let columns = ColumnLayout(lines: left + right + [title])
        #expect(columns.isTwoColumn)
        let items = (right + left + [title]).compactMap(PageLayoutPlanner.layoutLine).map(PageItem.line)
        let order = columns.ordered(items).compactMap { item -> String? in
            if case let .line(line) = item { line.text } else { nil }
        }
        #expect(order.first?.hasPrefix("A title") == true)
        #expect(order[1].hasPrefix("left column") && order[5].hasPrefix("left column"))
        #expect(order[6].hasPrefix("right column"))
    }

    @Test func runningHeadersAndPageNumbersRepeatedOnMostPagesAreDropped() {
        func page(_ number: Int) -> PlannedPage {
            PlannedPage(items: [
                .line(LayoutLine(runs: [LayoutRun(text: "Journal of Cheese", fontSize: 9)], frame: CGRect(x: 72, y: 20, width: 100, height: 9))),
                .line(LayoutLine(runs: [LayoutRun(text: "Body on page \(number)", fontSize: 10)], frame: CGRect(x: 72, y: 300, width: 100, height: 10))),
                .line(LayoutLine(runs: [LayoutRun(text: "Page \(number)", fontSize: 9)], frame: CGRect(x: 290, y: 760, width: 40, height: 9))),
            ])
        }
        let cleaned = PageLayoutPlanner.removingRunningLines([page(1), page(2), page(3)], pageHeights: [792, 792, 792])
        #expect(cleaned.allSatisfy { $0.items.count == 1 })
        // A single page keeps everything.
        #expect(PageLayoutPlanner.removingRunningLines([page(1)], pageHeights: [792])[0].items.count == 3)
    }

    @Test func unreadableGlyphRowsBecomeOCRRegionsOutsidePictures() {
        let row = (0..<8).map { CGRect(x: 72 + CGFloat($0) * 8, y: 140, width: 8, height: 14) }
        let inEquation = (0..<4).map { CGRect(x: 300 + CGFloat($0) * 8, y: 140, width: 8, height: 14) }
        let regions = PageLayoutPlanner.missingTextRegions(row + inEquation, pictures: [CGRect(x: 290, y: 130, width: 60, height: 30)])
        #expect(regions.count == 1)
        #expect(regions.first?.minX == 72)
    }
}

struct TextLayoutAnalyzerHyphenationTests {
    private func lines(_ texts: [String]) -> [LayoutItem] {
        texts.enumerated().map { index, text in
            .line(LayoutLine(runs: [LayoutRun(text: text, fontSize: 10)], frame: CGRect(x: 72, y: 100 + CGFloat(index) * 12, width: 200, height: 10)))
        }
    }

    @Test func compoundsKeepTheirHyphenAndBrokenWordsJoin() {
        let blocks = TextLayoutAnalyzer.blocks(items: lines(["a well-known state-", "of-the-art pa-", "rameter and self-", "aware text"]))
        #expect(blocks.first?.text == "a well-known state-of-the-art parameter and self-aware text")
    }

    @Test func theDocumentsOwnSpellingDecides() {
        let joined = TextLayoutAnalyzer.blocks(items: lines(["some co-", "operation"]), vocabulary: ["cooperation"])
        #expect(joined.first?.text == "some cooperation")
        let kept = TextLayoutAnalyzer.blocks(items: lines(["an e-", "mail"]), vocabulary: ["e-mail"])
        #expect(kept.first?.text == "an e-mail")
        let vocabulary = TextLayoutAnalyzer.vocabulary(of: [LayoutLine(runs: [LayoutRun(text: "A non-linear model, linear-", fontSize: 10)], frame: .zero)])
        #expect(vocabulary == ["a", "non-linear", "model"])
    }

    @Test func tabularRowsBecomeATableAndALoneRowIsAHeading() {
        func row(_ text: String, _ y: CGFloat, size: CGFloat = 10) -> LayoutItem {
            .line(LayoutLine(runs: [LayoutRun(text: text, fontSize: size)], frame: CGRect(x: 72, y: y, width: 200, height: size), isTabular: true))
        }
        let body = (0..<3).map { index in
            LayoutItem.line(LayoutLine(runs: [LayoutRun(text: "Body text at the usual size for the page.", fontSize: 10)], frame: CGRect(x: 72, y: 300 + CGFloat(index) * 12, width: 200, height: 10)))
        }
        let blocks = TextLayoutAnalyzer.blocks(items: [row("1\tIntroduction", 60, size: 14)] + body + [row("Name\tCount", 400), row("Lantern\t2", 412)])
        #expect(blocks.first?.kind == .heading(level: 2))
        #expect(blocks.first?.text == "1 Introduction")
        #expect(blocks.last?.kind == .table([["Name", "Count"], ["Lantern", "2"]]))
    }

    @Test func equationsAreTheirOwnBlocks() {
        let items: [LayoutItem] = lines(["Text before"]) + [.equation(LayoutImage(id: 3, frame: .zero), number: "(2)")] + lines(["Text after"])
        let blocks = TextLayoutAnalyzer.blocks(items: items)
        #expect(blocks.map(\.kind) == [.paragraph, .equation(3, number: "(2)"), .paragraph])
    }
}

struct DocxTableEmbedderTests {
    @Test func replacesTheTokenParagraphWithATableAndKeepsABodyParagraphLast() throws {
        let table = DocxTable(token: DocxTable.token(1), rows: [["Item", "Count"], ["A & B", "<2>"]])
        let document = #"<w:document><w:body><w:p><w:pPr/><w:r><w:t>Before</w:t></w:r></w:p><w:p w:rsidR="1"><w:r><w:t>CHEESETABLE0001X</w:t></w:r></w:p><w:sectPr/></w:body></w:document>"#
        var parts = [DocxImageEmbedder.documentPath: Data(document.utf8)]
        try DocxTableEmbedder.embed([table], into: &parts)
        let xml = String(decoding: try #require(parts[DocxImageEmbedder.documentPath]), as: UTF8.self)
        #expect(!xml.contains("CHEESETABLE"))
        #expect(xml.contains("<w:t>Before</w:t>"))
        #expect(xml.contains("<w:tbl>") && xml.contains("</w:tbl><w:p/><w:sectPr/>"))
        #expect(xml.contains("A &amp; B") && xml.contains("&lt;2&gt;"))
        #expect(xml.components(separatedBy: "<w:b/>").count == 3)
    }

    @Test func aMissingTokenIsAnError() {
        var parts = [DocxImageEmbedder.documentPath: Data("<w:body/>".utf8)]
        #expect(throws: (any Error).self) { try DocxTableEmbedder.embed([DocxTable(token: DocxTable.token(1), rows: [["a"]])], into: &parts) }
    }
}

struct MarkdownAndHTMLPreparationTests {
    @Test func frontMatterIsDropped() {
        #expect(MarkdownConverter.strippingFrontMatter("---\ntitle: X\ntags: [a]\n---\n# Heading") == "# Heading")
        #expect(MarkdownConverter.strippingFrontMatter("---\ntitle: X\n...\nBody") == "Body")
        // A horizontal rule later in the file, or an unclosed block, stays.
        #expect(MarkdownConverter.strippingFrontMatter("Intro\n---\nMore") == "Intro\n---\nMore")
        #expect(MarkdownConverter.strippingFrontMatter("---\nno end") == "---\nno end")
    }

    @Test func tablesAndLocalImagesBecomeTokens() throws {
        let folder = makeTemporaryDirectory()
        let image = try #require(FileFixtures.halfTransparentImage())
        #expect(FileFixtures.write(image, to: folder.appending(path: "pic.png"), type: .png))
        let html = """
        <p>Intro</p><table><thead><tr><th>Name</th><th>Qty</th></tr></thead><tr><td><b>Lamp</b></td><td>2 &amp; 3</td></tr></table>
        <img src="pic.png"><img src="../secret.png"><img src="https://example.com/x.png"><img src="/etc/x.png">
        """
        let prepared = HTMLForDocx.prepare(html, folder: folder)
        #expect(prepared.tables.first?.rows == [["Name", "Qty"], ["Lamp", "2 & 3"]])
        #expect(prepared.tables.first?.hasHeader == true)
        #expect(prepared.images.count == 1)
        #expect(prepared.html.contains(DocxTable.token(1)) && prepared.html.contains(DocxImage.token(1)))
        #expect(prepared.html.contains("../secret.png") && prepared.html.contains("https://example.com/x.png"))
    }

    @Test func onlyImagesInsideTheFolderResolve() throws {
        let folder = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.appending(path: "img"), withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appending(path: "img/a.png"))
        try Data([0]).write(to: folder.appending(path: "notes.txt"))
        #expect(LocalImages.resolve("img/a.png", in: folder) != nil)
        #expect(LocalImages.resolve("img/../img/a.png", in: folder) != nil)
        #expect(LocalImages.resolve("../a.png", in: folder) == nil)
        #expect(LocalImages.resolve("notes.txt", in: folder) == nil)
        #expect(LocalImages.resolve("file:///etc/a.png", in: folder) == nil)
        #expect(LocalImages.resolve("/img/a.png", in: folder) == nil)
        #expect(LocalImages.inliningImages(in: #"<img alt="x" src="img/a.png">"#, folder: folder).contains("data:image/png;base64,AA=="))
    }
}

struct PDFContentScannerTests {
    @Test func findsFontsGlyphPositionsAndPaths() throws {
        let url = makeTemporaryDirectory().appending(path: "scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        TestPDFs.draw("Hi", at: CGPoint(x: 72, y: 700), size: 20, bold: true, in: context)
        context.stroke(CGRect(x: 100, y: 100, width: 50, height: 40))
        context.endPDFPage()
        context.closePDF()
        let page = try #require(CGPDFDocument(url as CFURL)?.page(at: 1))
        let scanned = PDFContentScanner.scan(page)
        #expect(scanned.glyphs.count == 2)
        let first = try #require(scanned.glyphs.first)
        #expect(first.fontName.contains("Helvetica-Bold"))
        #expect(abs(first.origin.x - 72) < 0.5 && abs(first.origin.y - 700) < 0.5)
        #expect(abs(first.size - 20) < 0.5)
        #expect(scanned.glyphs[1].origin.x > first.origin.x + 5)
        #expect(scanned.paths.contains { abs($0.minX - 100) < 1 && abs($0.width - 50) < 1 && abs($0.height - 40) < 1 })
    }
}
