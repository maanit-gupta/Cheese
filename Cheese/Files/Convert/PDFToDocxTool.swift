import AppKit
import PDFKit
import SwiftUI

/// PDF → Word: paragraphs, headings, bold and italic, simple lists and images, with a page break
/// after each PDF page. Scanned pages go through Vision OCR.
struct PDFToDocxTool: FileTool {
    let id = ToolID.pdfToWord
    var defaultOptions: NoOptions { NoOptions() }
    var hint: String? { PDFConversionLimits.hint }

    func optionsView(options: Binding<NoOptions>, inputs: [URL]) -> some View {
        EmptyView()
    }

    func work(inputs: [URL], options: NoOptions) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let data = try PDFToDocx.convert(input)
            let output = context.outputURL(for: input, suffix: nil, extension: "docx")
            try data.write(to: output, options: .withoutOverwriting)
        }
    }
}

enum PDFConversionLimits {
    static let hint = "Layout is approximate: display equations and line drawings come across as pictures (not editable), pages with more than two columns may need cleanup, complex or merged-cell tables won't be perfect, and text inside images isn't converted unless the whole page is scanned."
}

enum PDFToDocx {
    /// Images smaller than this (in points, either side) are decoration, not content.
    static let minimumImageSide: CGFloat = 24
    /// Equations are cropped sharp enough to print: at least 300 dpi.
    static let equationDPI: CGFloat = 300
    static let imageDPI: CGFloat = 200

    static func convert(_ input: URL) throws -> Data {
        let document = try PDFFiles.open(input)
        var pages: [PlannedPage] = []
        var heights: [CGFloat] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                pages.append(PlannedPage(items: []))
                heights.append(0)
                continue
            }
            let geometry = PDFPageGeometry(page)
            heights.append(geometry.size.height)
            if PDFTextExtractor.hasText(page) {
                pages.append(PageLayoutPlanner.plan(PDFTextExtractor.pageInput(on: page)))
            } else {
                pages.append(PlannedPage(items: [], needsOCR: true))
            }
        }
        pages = PageLayoutPlanner.removingRunningLines(pages, pageHeights: heights)
        let vocabulary = TextLayoutAnalyzer.vocabulary(of: pages.flatMap { page in
            page.items.compactMap { item -> LayoutLine? in
                if case let .line(line) = item { line } else { nil }
            }
        })

        var builder = DocxBuilder()
        for (index, planned) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let items: [LayoutItem]
            if planned.needsOCR {
                let lines = try ScannedPageReader.lines(on: page)
                items = lines.map { .line($0) }
            } else {
                items = try layoutItems(planned.items, on: page, builder: &builder)
            }
            let lines = items.compactMap { item -> LayoutLine? in
                if case let .line(line) = item { line } else { nil }
            }
            builder.append(TextLayoutAnalyzer.blocks(items: items, vocabulary: vocabulary), bodySize: TextLayoutAnalyzer.bodySize(of: lines))
            if index < document.pageCount - 1 {
                builder.pageBreak()
            }
        }
        return try builder.docx()
    }

    /// Crops pictures (images, drawings, equations) and reads unreadable lines with OCR.
    private static func layoutItems(_ items: [PageItem], on page: PDFPage, builder: inout DocxBuilder) throws -> [LayoutItem] {
        guard let cgPage = page.pageRef else { return [] }
        let size = PDFPageGeometry(page).size
        let pageBox = CGRect(origin: .zero, size: size)
        return try items.compactMap { item -> LayoutItem? in
            switch item {
            case let .line(line):
                return .line(line)
            case let .image(rect), let .figure(rect):
                let visible = rect.intersection(pageBox)
                guard !visible.isNull, visible.width >= minimumImageSide, visible.height >= minimumImageSide,
                      let png = png(cgPage, region: visible, dpi: imageDPI)
                else { return nil }
                return .image(LayoutImage(id: builder.addImage(png: png, size: visible.size), frame: visible))
            case let .equation(rect, number):
                let visible = rect.intersection(pageBox)
                guard !visible.isNull, let png = png(cgPage, region: visible, dpi: equationDPI) else { return nil }
                return .equation(LayoutImage(id: builder.addImage(png: png, size: visible.size), frame: visible), number: number)
            case let .unreadable(rect, fontSize):
                let text = try ScannedPageReader.text(in: rect, on: page)
                guard !text.isEmpty else { return nil }
                return .line(LayoutLine(runs: [LayoutRun(text: text, fontSize: fontSize)], frame: rect))
            }
        }
    }

    private static func png(_ page: CGPDFPage, region: CGRect, dpi: CGFloat) -> Data? {
        guard let image = PDFRasterizer.render(page, uprightRegion: region, dpi: dpi) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Builds the Word document: an attributed string written by Cocoa, then images embedded.
struct DocxBuilder {
    /// Images wider than the text column are scaled down to it (Letter minus 1-inch margins).
    static let maxImageWidth: CGFloat = 468
    private static let fontName = "Helvetica"

    private let text = NSMutableAttributedString()
    private var images: [Int: DocxImage] = [:]
    private var tables: [DocxTable] = []
    private var listNumber = 0

    /// Registers an image and returns its ID for a `LayoutImage`.
    mutating func addImage(png: Data, size: CGSize) -> Int {
        let id = images.count + 1
        let scale = min(1, Self.maxImageWidth / max(size.width, 1))
        images[id] = DocxImage(token: DocxImage.token(id), png: png, size: CGSize(width: size.width * scale, height: size.height * scale))
        return id
    }

    mutating func append(_ blocks: [LayoutBlock], bodySize: CGFloat) {
        for block in blocks {
            switch block.kind {
            case let .heading(level):
                listNumber = 0
                let size: CGFloat = level == 1 ? 20 : level == 2 ? 16 : 13
                appendParagraph(block.runs, size: size, forceBold: true, spacingBefore: 12, spacingAfter: 6)
            case .paragraph:
                listNumber = 0
                appendParagraph(block.runs, size: 11, forceBold: false, spacingBefore: 0, spacingAfter: 8)
            case let .listItem(ordered):
                listNumber += 1
                let marker = ordered ? "\(listNumber)." : "•"
                appendParagraph(
                    [LayoutRun(text: "\t\(marker)\t", fontSize: 11)] + block.runs,
                    size: 11, forceBold: false, spacingBefore: 0, spacingAfter: 3, indent: 24
                )
            case let .image(id):
                listNumber = 0
                guard let image = images[id] else { continue }
                appendParagraph([LayoutRun(text: image.token, fontSize: 11)], size: 11, forceBold: false, spacingBefore: 0, spacingAfter: 8)
            case let .equation(id, number):
                listNumber = 0
                guard let image = images[id] else { continue }
                appendEquation(token: image.token, number: number)
            case let .table(rows):
                listNumber = 0
                appendTable(rows)
            }
        }
    }

    mutating func pageBreak() {
        listNumber = 0
        text.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font(size: 11, bold: false, italic: false)]))
    }

    /// Adds a table where a token paragraph stands (Cocoa's writer drops text tables).
    mutating func appendTable(_ rows: [[String]]) {
        let table = DocxTable(token: DocxTable.token(tables.count + 1), rows: rows)
        tables.append(table)
        appendParagraph([LayoutRun(text: table.token, fontSize: 11)], size: 11, forceBold: false, spacingBefore: 0, spacingAfter: 8)
    }

    /// A display equation: the picture centered, and its number (if any) at the right margin, laid
    /// out as a borderless two-cell table (tab stops after an inline picture aren't honored everywhere).
    private mutating func appendEquation(token: String, number: String?) {
        guard let number else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 4
            style.paragraphSpacing = 8
            text.append(NSAttributedString(string: "\(token)\n", attributes: [.font: font(size: 11, bold: false, italic: false), .paragraphStyle: style]))
            return
        }
        let table = DocxTable(
            token: DocxTable.token(tables.count + 1), rows: [[token, number]], hasHeader: false, hasBorders: false,
            columnWidths: [DocxTableEmbedder.textWidth - 1200, 1200], alignments: ["center", "right"]
        )
        tables.append(table)
        appendParagraph([LayoutRun(text: table.token, fontSize: 11)], size: 11, forceBold: false, spacingBefore: 0, spacingAfter: 8)
    }

    func docx() throws -> Data {
        let written = try DocxWriter.docx(from: text)
        guard !images.isEmpty || !tables.isEmpty else { return written }
        var parts = try ZipArchive.read(written)
        // Tables first: an equation's table cell holds its picture's token.
        try DocxTableEmbedder.embed(tables, into: &parts)
        try DocxImageEmbedder.embed(images.keys.sorted().compactMap { images[$0] }, into: &parts)
        return try ZipArchive.write(parts)
    }

    private func appendParagraph(_ runs: [LayoutRun], size: CGFloat, forceBold: Bool, spacingBefore: CGFloat, spacingAfter: CGFloat, indent: CGFloat = 0) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        if indent > 0 {
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent / 2), NSTextTab(textAlignment: .left, location: indent)]
        }
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, bold: forceBold || run.isBold, italic: run.isItalic),
                .paragraphStyle: style,
            ]
            switch run.script {
            case .superscript: attributes[.superscript] = 1
            case .subscript: attributes[.superscript] = -1
            case .none: break
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        text.append(NSAttributedString(string: "\n", attributes: [.font: font(size: size, bold: false, italic: false), .paragraphStyle: style]))
    }

    private func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let base = NSFont(name: Self.fontName, size: size) ?? .systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }
}
