// Regenerates the self-made Files fixtures in CheeseTests/Fixtures/Files.
//
//   swift Design/make-files-fixtures.swift CheeseTests/Fixtures/Files
//
// Everything is drawn here, so no third-party or copyrighted document ends up in the repo:
//
//   text.pdf          2 pages: a heading, body paragraphs, a bulleted list, bold and italic runs
//   scanned.pdf       1 page that is only an image of text (no text layer), like a scan
//   mixed.pdf         page 1 text with a small photo; page 2 a full-page photo
//   multicolumn.pdf   a heading over two columns of text
//   tables.pdf        two tables (header row, text, numbers, dates) separated by a paragraph
//   report.docx       a short Word document: headings, paragraphs, a list (written by Cocoa)
//   photo.heic        a 600×400 photo with EXIF, GPS and orientation 6 (rotated 90°)
//
// make-files-fixtures.mjs makes the PowerPoint and Excel fixtures.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: make-files-fixtures <output folder>")
    exit(1)
}
let folder = URL(filePath: arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let pageSize = CGSize(width: 612, height: 792)
let black = CGColor(gray: 0, alpha: 1)

func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
    let name = switch (bold, italic) {
    case (true, true): "Helvetica-BoldOblique"
    case (true, false): "Helvetica-Bold"
    case (false, true): "Helvetica-Oblique"
    case (false, false): "Helvetica"
    }
    return CTFontCreateWithName(name as CFString, size, nil)
}

/// Draws one line at a baseline; returns its width.
@discardableResult
func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, italic: Bool = false, in context: CGContext) -> CGFloat {
    let attributed = NSAttributedString(string: text, attributes: [.font: font(size, bold: bold, italic: italic), .foregroundColor: black])
    let ctLine = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(ctLine, context)
    return CTLineGetTypographicBounds(ctLine, nil, nil, nil)
}

/// Draws lines top-down from `top`, returning the next baseline.
func paragraph(_ lines: [String], x: CGFloat, top: CGFloat, size: CGFloat = 11, leading: CGFloat = 15, in context: CGContext) -> CGFloat {
    var y = top
    for text in lines {
        line(text, x: x, y: y, size: size, in: context)
        y -= leading
    }
    return y
}

func pdf(_ name: String, pages: [(CGContext) -> Void]) {
    var box = CGRect(origin: .zero, size: pageSize)
    let url = folder.appending(path: name)
    guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: name] as CFDictionary) else { return }
    for draw in pages {
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
    }
    context.closePDF()
    print("wrote \(name)")
}

/// A deterministic "photo": smooth color bands with a sun, so JPEG compression behaves like a real picture.
func photo(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    let colors = [CGColor(srgbRed: 0.35, green: 0.6, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.98, green: 0.8, blue: 0.5, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
    }
    context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
    context.fillEllipse(in: CGRect(x: width * 2 / 3, y: height * 2 / 3, width: height / 5, height: height / 5))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.25, alpha: 1))
    for index in 0..<12 {
        let x = CGFloat(index * width / 12)
        context.fill(CGRect(x: x, y: 0, width: CGFloat(width / 14), height: CGFloat(height / 4 + (index % 3) * height / 20)))
    }
    return context.makeImage()
}

/// Text rendered into pixels, for the "scanned" page.
func scannedText(_ lines: [String], width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
    _ = paragraph(lines, x: 72, top: 700, size: 14, leading: 22, in: context)
    return context.makeImage()
}

// MARK: PDFs

pdf("text.pdf", pages: [
    { context in
        line("Quarterly Report", x: 72, y: 700, size: 24, bold: true, in: context)
        var y = paragraph([
            "This report summarizes the quarter. Revenue grew in every region and",
            "the team shipped two major releases on schedule.",
        ], x: 72, top: 660, in: context)
        y -= 14
        line("Highlights", x: 72, y: y, size: 16, bold: true, in: context)
        y -= 24
        for item in ["New customers in three regions", "Support response time halved", "Two releases shipped"] {
            line("•  " + item, x: 84, y: y, size: 11, in: context)
            y -= 15
        }
        y -= 14
        let width = line("Bold claim:", x: 72, y: y, size: 11, bold: true, in: context)
        line(" an italic aside follows.", x: 72 + width, y: y, size: 11, italic: true, in: context)
    },
    { context in
        line("Next Steps", x: 72, y: 700, size: 18, bold: true, in: context)
        _ = paragraph([
            "Hire two engineers and open the Berlin office in the spring.",
            "Review the budget again at the end of the next quarter.",
        ], x: 72, top: 670, in: context)
    },
])

let scanLines = ["SCANNED INVOICE 2047", "Amount due: 1,250.00", "Thank you for your business."]
pdf("scanned.pdf", pages: [
    { context in
        if let image = scannedText(scanLines, width: 1275, height: 1650) {
            context.draw(image, in: CGRect(origin: .zero, size: pageSize))
        }
    },
])

pdf("mixed.pdf", pages: [
    { context in
        line("Field Trip", x: 72, y: 700, size: 22, bold: true, in: context)
        _ = paragraph(["We walked along the river and stopped for a photo."], x: 72, top: 670, in: context)
        if let image = photo(width: 600, height: 400) {
            context.draw(image, in: CGRect(x: 72, y: 380, width: 300, height: 200))
        }
        _ = paragraph(["The light was perfect in the late afternoon."], x: 72, top: 350, in: context)
    },
    { context in
        if let image = photo(width: 1600, height: 2000) {
            context.draw(image, in: CGRect(origin: .zero, size: pageSize))
        }
    },
])

pdf("multicolumn.pdf", pages: [
    { context in
        line("Two Column Newsletter", x: 72, y: 720, size: 20, bold: true, in: context)
        let left = (1...18).map { "Left column line \($0) of text." }
        let right = (1...18).map { "Right column line \($0) here." }
        _ = paragraph(left, x: 72, top: 680, in: context)
        _ = paragraph(right, x: 324, top: 680, in: context)
    },
])

func table(_ rows: [[String]], top: CGFloat, columns: [CGFloat], in context: CGContext) -> CGFloat {
    var y = top
    for (index, row) in rows.enumerated() {
        for (cell, x) in zip(row, columns) {
            line(cell, x: x, y: y, size: 10, bold: index == 0, in: context)
        }
        y -= 16
    }
    return y
}

pdf("tables.pdf", pages: [
    { context in
        line("Sales by Region", x: 72, y: 720, size: 16, bold: true, in: context)
        var y = table([
            ["Region", "Units", "Revenue", "Date"],
            ["North", "120", "4,500.50", "2026-01-15"],
            ["South", "98", "3,120.00", "2026-02-03"],
            ["East", "143", "5,010.75", "2026-03-21"],
            ["West", "77", "2,480.25", "2026-03-30"],
        ], top: 690, columns: [72, 200, 300, 420], in: context)
        y -= 30
        _ = paragraph(["Inventory below is counted at the end of the quarter."], x: 72, top: y, in: context)
        y -= 40
        _ = table([
            ["Item", "On hand", "Reorder"],
            ["Widgets", "1,204", "300"],
            ["Gears", "88", "150"],
            ["Springs", "560", "200"],
        ], top: y, columns: [72, 240, 380], in: context)
    },
])

// MARK: Word

let report = NSMutableAttributedString()
func append(_ text: String, size: CGFloat, bold: Bool = false) {
    let font = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size) ?? .systemFont(ofSize: size)
    report.append(NSAttributedString(string: text + "\n", attributes: [.font: font]))
}
append("Project Plan", size: 24, bold: true)
append("This document describes the plan for the next release.", size: 11)
append("Goals", size: 16, bold: true)
append("• Ship the Files module", size: 11)
append("• Keep everything offline", size: 11)
append("Timeline", size: 16, bold: true)
append("Design in January, build in February, release in March.", size: 11)
let docx = try report.data(
    from: NSRange(location: 0, length: report.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
)
try docx.write(to: folder.appending(path: "report.docx"))
print("wrote report.docx")

// MARK: HEIC

if let image = photo(width: 600, height: 400),
   let destination = CGImageDestinationCreateWithURL(folder.appending(path: "photo.heic") as CFURL, UTType.heic.identifier as CFString, 1, nil) {
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImageDestinationLossyCompressionQuality: 0.8,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:05:01 17:30:00",
            kCGImagePropertyExifLensModel: "Fixture Lens 26mm",
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 28.6139, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 77.2090, kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    if CGImageDestinationFinalize(destination) {
        print("wrote photo.heic")
    }
}
