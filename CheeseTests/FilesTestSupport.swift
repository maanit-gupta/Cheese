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

extension TestPDFs {
    /// Random RGB noise, which compresses badly: a stand-in for a photo.
    static func noiseImage(width: Int, height: Int) -> CGImage? {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<(width * height * 4)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Page 1: a full-page noisy image ("scanned"). Page 2: text only.
    @discardableResult
    static func writeMixed(to url: URL, imagePixels: Int = 1200) -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil),
              let image = noiseImage(width: imagePixels, height: imagePixels)
        else { return url }
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 0, y: 90, width: 612, height: 612))
        context.endPDFPage()
        context.beginPDFPage(nil)
        draw("Plain text page", at: CGPoint(x: 72, y: 700), size: 18, in: context)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}

/// The self-made fixtures in Fixtures/Files, copied to a temp folder so outputs land beside them.
enum FilesFixture {
    private final class BundleToken {}

    static func copy(_ name: String) throws -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard let source = Bundle(for: BundleToken.self).url(forResource: base, withExtension: ext, subdirectory: "Fixtures/Files") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = makeTemporaryDirectory().appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
