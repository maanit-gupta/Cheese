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
    static let hint = "Layout is approximate: multi-column pages may need cleanup, complex or merged-cell tables won't be perfect, and text inside images isn't converted unless the whole page is scanned."
}

enum PDFToDocx {
    /// Images smaller than this (in points, either side) are decoration, not content.
    static let minimumImageSide: CGFloat = 24

    static func convert(_ input: URL) throws -> Data {
        let document = try PDFFiles.open(input)
        var builder = DocxBuilder()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let scanned = !PDFTextExtractor.hasText(page)
            let lines = scanned ? try ScannedPageReader.lines(on: page) : PDFTextExtractor.lines(on: page)
            let images = scanned ? [] : self.images(on: page, builder: &builder)
            builder.append(TextLayoutAnalyzer.blocks(lines: lines, images: images), bodySize: TextLayoutAnalyzer.bodySize(of: lines))
            if index < document.pageCount - 1 {
                builder.pageBreak()
            }
        }
        return try builder.docx()
    }

    /// Crops each image on the page out by rendering its region, in reading position.
    private static func images(on page: PDFPage, builder: inout DocxBuilder) -> [LayoutImage] {
        guard let cgPage = page.pageRef else { return [] }
        let box = page.bounds(for: .cropBox)
        return PDFImageInspector.imageRects(on: cgPage).compactMap { rect in
            let visible = rect.intersection(box)
            guard !visible.isNull, visible.width >= minimumImageSide, visible.height >= minimumImageSide,
                  let image = PDFRasterizer.render(cgPage, region: visible, dpi: 150),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { return nil }
            let id = builder.addImage(png: png, size: visible.size)
            return LayoutImage(id: id, frame: PDFTextExtractor.topLeft(visible, in: box))
        }
    }
}

/// Builds the Word document: an attributed string written by Cocoa, then images embedded.
struct DocxBuilder {
    /// Images wider than the text column are scaled down to it (Letter minus 1-inch margins).
    static let maxImageWidth: CGFloat = 468
    private static let fontName = "Helvetica"

    private let text = NSMutableAttributedString()
    private var images: [Int: DocxImage] = [:]
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
            }
        }
    }

    mutating func pageBreak() {
        listNumber = 0
        text.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font(size: 11, bold: false, italic: false)]))
    }

    func docx() throws -> Data {
        let written = try DocxWriter.docx(from: text)
        guard !images.isEmpty else { return written }
        var parts = try ZipArchive.read(written)
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
            text.append(NSAttributedString(string: run.text, attributes: [
                .font: font(size: size, bold: forceBold || run.isBold, italic: run.isItalic),
                .paragraphStyle: style,
            ]))
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
