import Foundation
import PDFKit
import Testing
@testable import Cheese

struct OverlayLayoutTests {
    private let page = CGSize(width: 600, height: 800)
    private let item = CGSize(width: 100, height: 20)

    @Test func anchorsSitInsideTheMargin() {
        #expect(OverlayLayout.rect(for: item, at: .bottomCenter, in: page, margin: 30) == CGRect(x: 250, y: 30, width: 100, height: 20))
        #expect(OverlayLayout.rect(for: item, at: .topRight, in: page, margin: 30) == CGRect(x: 470, y: 750, width: 100, height: 20))
        #expect(OverlayLayout.rect(for: item, at: .center, in: page, margin: 30) == CGRect(x: 250, y: 390, width: 100, height: 20))
        #expect(OverlayLayout.rect(for: item, at: .topLeft, in: page, margin: 30).origin == CGPoint(x: 30, y: 750))
    }

    @Test func tilesCoverEveryCorner() {
        let centers = OverlayLayout.tileCenters(itemSize: item, page: page, gap: 40)
        #expect(centers.contains { $0.x <= 0 && $0.y <= 0 })
        #expect(centers.contains { $0.x >= page.width && $0.y >= page.height })
        #expect(centers.count > 20)
    }
}

struct PageNumberingTests {
    @Test func formats() {
        #expect(PageNumberFormat.plain.text(number: 3, total: 9) == "3")
        #expect(PageNumberFormat.page.text(number: 3, total: 9) == "Page 3")
        #expect(PageNumberFormat.slash.text(number: 3, total: 9) == "3 / 9")
        #expect(PageNumberFormat.pageOf.text(number: 3, total: 9) == "Page 3 of 9")
    }

    @Test func skippingTheFirstPageStartsCountingOnTheSecond() {
        #expect(PageNumbering.number(forPage: 0, start: 1, skipFirst: true) == nil)
        #expect(PageNumbering.number(forPage: 1, start: 1, skipFirst: true) == 1)
        #expect(PageNumbering.total(pageCount: 10, start: 1, skipFirst: true) == 9)
        #expect(PageNumbering.number(forPage: 4, start: 10, skipFirst: false) == 14)
        #expect(PageNumbering.total(pageCount: 5, start: 10, skipFirst: false) == 14)
    }

    @Test func pageSelectionLimitsToARange() throws {
        #expect(try PageSelection.indexes(.all, ranges: "x", pageCount: 3) == nil)
        #expect(try PageSelection.indexes(.range, ranges: "1, 3", pageCount: 3) == [0, 2])
    }
}

@MainActor
struct OverlayToolTests {
    @Test func watermarkKeepsTheOriginalTextSelectableAndAddsItsOwn() async throws {
        let input = TestPDFs.write(pages: 2, to: makeTemporaryDirectory().appending(path: "Report.pdf"))
        let options = WatermarkTool.Options(text: "DRAFT", position: .center)
        let report = try await runJob(WatermarkTool().work(inputs: [input], options: options))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Report (watermarked).pdf")
        let texts = TestPDFs.pageTexts(output)
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.contains("DRAFT") })
        #expect(texts[1].contains("Page 2"))
    }

    @Test func watermarkOnlyOnChosenPages() async throws {
        let input = TestPDFs.write(pages: 3, to: makeTemporaryDirectory().appending(path: "Report.pdf"))
        let options = WatermarkTool.Options(text: "DRAFT", position: .tiled, pages: .range, ranges: "2")
        let report = try await runJob(WatermarkTool().work(inputs: [input], options: options))
        let texts = TestPDFs.pageTexts(try #require(report.outputs.first))
        #expect(texts.map { $0.contains("DRAFT") } == [false, true, false])
    }

    @Test func watermarkNeedsTextOrAnImage() {
        #expect(WatermarkTool().problem(with: .init(text: "  "), inputs: []) == "Enter the watermark text.")
        #expect(WatermarkTool().problem(with: .init(kind: .image), inputs: []) == "Choose a watermark image.")
    }

    @Test func pageNumbersFollowTheFormatAndSkipTheCover() async throws {
        let input = TestPDFs.write(pages: 3, to: makeTemporaryDirectory().appending(path: "Report.pdf"))
        let options = PageNumbersTool.Options(format: .pageOf, skipFirst: true)
        let report = try await runJob(PageNumbersTool().work(inputs: [input], options: options))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Report (numbered).pdf")
        let texts = TestPDFs.pageTexts(output)
        #expect(!texts[0].contains("of 2"))
        #expect(texts[1].contains("Page 1 of 2"))
        #expect(texts[2].contains("Page 2 of 2"))
    }

    @Test func rotatedPagesStayUpright() async throws {
        let folder = makeTemporaryDirectory()
        let source = TestPDFs.write(pages: 1, to: folder.appending(path: "Source.pdf"))
        let document = try #require(PDFDocument(url: source))
        document.page(at: 0)?.rotation = 90
        let rotated = folder.appending(path: "Rotated.pdf")
        #expect(document.write(to: rotated))

        let report = try await runJob(PageNumbersTool().work(inputs: [rotated], options: .init()))
        let url = try #require(report.outputs.first)
        let output = try #require(PDFDocument(url: url))
        let page = try #require(output.page(at: 0))
        #expect(page.rotation == 0)
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))
        #expect(page.string?.contains("Page 1") == true)
    }
}
