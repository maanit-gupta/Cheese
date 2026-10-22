import AppKit
import CoreText
import Foundation
import PDFKit

/// Small PDFs written on the fly for the Files tests.
enum TestPDFs {
    /// Writes a PDF whose page `n` (1-based) says "Page n" in 24 pt Helvetica.
    @discardableResult
    static func write(pages: Int, to url: URL, size: CGSize = CGSize(width: 612, height: 792), label: String = "Page") -> URL {
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return url }
        for page in 1...max(pages, 1) {
            context.beginPDFPage(nil)
            draw("\(label) \(page)", at: CGPoint(x: 72, y: size.height - 100), size: 24, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static func draw(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false, in context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// The text of every page, in order.
    static func pageTexts(_ url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }
}
