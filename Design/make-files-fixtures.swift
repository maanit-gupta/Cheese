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
// Added for the 2.5 conversion audit:
//
//   no-unicode.pdf    page 1: readable text plus one line in a Type 3 font with no /ToUnicode map and
//                     codes in the control range (extracts as garbage); page 2: only such lines
//   rotated.pdf       page 1 upright; page 2 has /Rotate 90 with its text drawn to read upright
//   encrypted.pdf     password-protected (user password "cheese")
//   empty.pdf         a PDF with no pages;  corrupt.pdf  not a PDF at all
//   big.pdf           220 pages of text, for speed and cancelling
//   rich.docx         styles, a numbered and a bulleted list, a table, an image, a header and a footer
//   notes.md          front matter, a table, a code block and a local image (notes-image.png)
//   page.html         headings, a list, a table and a local image
//   scripts.txt       Hindi, Chinese, Japanese and Arabic (right to left)
//   alpha.png         RGBA with a transparent background;  rotated.jpg  EXIF orientation 6
//   photo.tiff, photo.webp (needs `cwebp`, `brew install webp`), animated.gif (3 frames)
//   huge.png          12000×12000;  tiny.png  1×1
//
// latex-article.pdf is built from latex-article.tex with `tectonic` (see that file).
// make-files-fixtures.mjs makes the PowerPoint and Excel fixtures.
import AppKit
import CoreText
import PDFKit
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

// MARK: - 2.5 conversion audit fixtures

/// A hand-written PDF: page 1 has a normal Helvetica line and one line in a Type 3 font whose
/// glyphs are Helvetica outlines but whose codes are control characters with no /ToUnicode map, so
/// text extraction gives garbage while the page looks normal. Page 2 is all such lines.
func type3PDF(pages: [(readable: [String], garbled: [String])]) -> Data {
    let glyphFont = CTFontCreateWithName("Helvetica" as CFString, 1000, nil)
    var characters: [Character] = []
    for page in pages {
        for line in page.garbled {
            for character in line where !characters.contains(character) {
                characters.append(character)
            }
        }
    }
    func code(_ character: Character) -> Int { (characters.firstIndex(of: character) ?? 0) + 1 }

    func glyphProcedure(_ character: Character) -> (String, Int) {
        var unichars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        CTFontGetGlyphsForCharacters(glyphFont, &unichars, &glyphs, unichars.count)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(glyphFont, .horizontal, &glyphs, &advance, 1)
        let width = Int(advance.width.rounded())
        var ops = "\(width) 0 0 -250 \(width) 800 d1\n"
        if let path = CTFontCreatePathForGlyph(glyphFont, glyphs[0], nil) {
            var current = CGPoint.zero
            path.applyWithBlock { element in
                let points = element.pointee.points
                func p(_ point: CGPoint) -> String { String(format: "%.1f %.1f", point.x, point.y) }
                switch element.pointee.type {
                case .moveToPoint:
                    ops += "\(p(points[0])) m\n"
                    current = points[0]
                case .addLineToPoint:
                    ops += "\(p(points[0])) l\n"
                    current = points[0]
                case .addQuadCurveToPoint:
                    let c1 = CGPoint(x: current.x + 2 / 3 * (points[0].x - current.x), y: current.y + 2 / 3 * (points[0].y - current.y))
                    let c2 = CGPoint(x: points[1].x + 2 / 3 * (points[0].x - points[1].x), y: points[1].y + 2 / 3 * (points[0].y - points[1].y))
                    ops += "\(p(c1)) \(p(c2)) \(p(points[1])) c\n"
                    current = points[1]
                case .addCurveToPoint:
                    ops += "\(p(points[0])) \(p(points[1])) \(p(points[2])) c\n"
                    current = points[2]
                case .closeSubpath:
                    ops += "h\n"
                @unknown default:
                    break
                }
            }
            ops += "f\n"
        }
        return (ops, width)
    }

    var objects: [String] = []
    // 1 catalog, 2 pages, 3 Helvetica, 4 Type 3 font, 5 char procs, 6 encoding, then glyphs, then pages.
    let glyphStart = 7
    let pageStart = glyphStart + characters.count
    let procedures = characters.map(glyphProcedure)
    objects.append("<< /Type /Catalog /Pages 2 0 R >>")
    let kids = (0..<pages.count).map { "\(pageStart + $0 * 2) 0 R" }.joined(separator: " ")
    objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    let widths = procedures.map { String($0.1) }.joined(separator: " ")
    objects.append("<< /Type /Font /Subtype /Type3 /FontBBox [0 -250 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs 5 0 R /Encoding 6 0 R /FirstChar 1 /LastChar \(characters.count) /Widths [\(widths)] /Resources << >> >>")
    let procs = characters.indices.map { "/g\($0 + 1) \(glyphStart + $0) 0 R" }.joined(separator: " ")
    objects.append("<< \(procs) >>")
    let names = characters.indices.map { "/g\($0 + 1)" }.joined(separator: " ")
    objects.append("<< /Type /Encoding /Differences [1 \(names)] >>")
    for (ops, _) in procedures {
        objects.append("<< /Length \(ops.utf8.count) >>\nstream\n\(ops)endstream")
    }
    for (index, page) in pages.enumerated() {
        var content = ""
        var y = 700
        for line in page.readable {
            let escaped = line.replacing("\\", with: "\\\\").replacing("(", with: "\\(").replacing(")", with: "\\)")
            content += "BT /F1 14 Tf 72 \(y) Td (\(escaped)) Tj ET\n"
            y -= 28
        }
        for line in page.garbled {
            let hex = line.map { String(format: "%02X", code($0)) }.joined()
            content += "BT /F2 14 Tf 72 \(y) Td <\(hex)> Tj ET\n"
            y -= 28
        }
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents \(pageStart + index * 2 + 1) 0 R >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
    }
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets {
        pdf += String(format: "%010d 00000 n \n", offset)
    }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
}

try type3PDF(pages: [
    (readable: ["Readable heading on a normal font", "This line extracts cleanly with real spaces."],
     garbled: ["Hidden invoice number 4471"]),
    (readable: [], garbled: ["Every line on this page", "uses the font without a map", "so it must be read with OCR"]),
]).write(to: folder.appending(path: "no-unicode.pdf"))
print("wrote no-unicode.pdf")

// Rotated: page 2 carries /Rotate 90, with its text drawn turned so it reads upright when shown.
do {
    let url = folder.appending(path: "rotated.pdf")
    pdf("rotated.pdf", pages: [
        { context in line("Upright first page", x: 72, y: 700, size: 20, bold: true, in: context) },
        { context in
            context.saveGState()
            context.translateBy(x: 120, y: 72)
            context.rotate(by: .pi / 2)
            line("Landscape page shown turned", x: 0, y: 0, size: 20, bold: true, in: context)
            context.restoreGState()
        },
    ])
    if let document = PDFDocument(url: url), let page = document.page(at: 1) {
        page.rotation = 90
        document.write(to: url)
    }
}

// Encrypted
do {
    var box = CGRect(origin: .zero, size: pageSize)
    let url = folder.appending(path: "encrypted.pdf")
    let info: [CFString: Any] = [kCGPDFContextUserPassword: "cheese", kCGPDFContextOwnerPassword: "cheese-owner"]
    if let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) {
        context.beginPDFPage(nil)
        line("Secret page", x: 72, y: 700, size: 20, in: context)
        context.endPDFPage()
        context.closePDF()
        print("wrote encrypted.pdf")
    }
}

// Empty and corrupt
do {
    // Core Graphics adds a blank page to a document without any, so this one is written by hand.
    let body = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
    let xref = body.utf8.count
    let empty = body + "xref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \ntrailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    try Data(empty.utf8).write(to: folder.appending(path: "empty.pdf"))
    print("wrote empty.pdf")
    try Data("%PDF-1.7\nThis is not really a PDF. It was cut off here".utf8).write(to: folder.appending(path: "corrupt.pdf"))
    print("wrote corrupt.pdf")
}

// Big
pdf("big.pdf", pages: (1...220).map { number in
    { context in
        line("Chapter \(number)", x: 72, y: 700, size: 18, bold: true, in: context)
        _ = paragraph((1...20).map { "Line \($0) of page \(number): plain text for speed and cancelling tests." }, x: 72, top: 670, in: context)
    }
})

// MARK: Word, by hand: styles, lists, a table, an image, a header and a footer

func zipFolder(_ source: URL, to destination: URL) throws {
    try? FileManager.default.removeItem(at: destination)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    // [Content_Types].xml first, uncompressed folders after.
    process.arguments = ["-X", "-q", "-r", destination.path(percentEncoded: false), "[Content_Types].xml", "_rels", "docProps", "word"]
    try process.run()
    process.waitUntilExit()
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    if let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return data as Data
}

do {
    let root = FileManager.default.temporaryDirectory.appending(path: "rich-docx-\(UUID().uuidString)")
    let files: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """,
        "_rels/.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """,
        "docProps/core.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Field Guide</dc:title><dc:creator>Cheese fixtures</dc:creator></cp:coreProperties>
        """,
        "word/_rels/document.xml.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/chart.png"/></Relationships>
        """,
        "word/styles.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="120"/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="1F3A5F"/><w:sz w:val="36"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style><w:style w:type="table" w:styleId="Grid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:left w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:right w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="000000"/></w:tblBorders></w:tblPr></w:style></w:styles>
        """,
        "word/numbering.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>
        """,
        "word/header1.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>Field Guide header</w:t></w:r></w:p></w:hdr>
        """,
        "word/footer1.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>Field Guide footer</w:t></w:r></w:p></w:ftr>
        """,
        "word/document.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Field Guide</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">This guide has </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:t xml:space="preserve">, </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>italic</w:t></w:r><w:r><w:t xml:space="preserve"> and </w:t></w:r><w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>underlined</w:t></w:r><w:r><w:t xml:space="preserve"> words.</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Steps</w:t></w:r></w:p>\
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Pack the tent</w:t></w:r></w:p>\
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Check the weather</w:t></w:r></w:p>\
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Bring water</w:t></w:r></w:p>\
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Bring a map</w:t></w:r></w:p>\
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Supplies</w:t></w:r></w:p>\
        <w:tbl><w:tblPr><w:tblStyle w:val="Grid"/><w:tblW w:w="6000" w:type="dxa"/></w:tblPr><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>\
        <w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Count</w:t></w:r></w:p></w:tc></w:tr>\
        <w:tr><w:tc><w:p><w:r><w:t>Lantern</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr>\
        <w:tr><w:tc><w:p><w:r><w:t>Compass</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
        <w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>Leave no trace.</w:t></w:r></w:p>\
        <w:p><w:r><w:drawing><wp:inline><wp:extent cx="2540000" cy="1270000"/><wp:docPr id="1" name="Chart"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="chart.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId5"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2540000" cy="1270000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>\
        <w:p><w:r><w:t>The chart above shows the route.</w:t></w:r></w:p>\
        <w:sectPr><w:headerReference w:type="default" r:id="rId3"/><w:footerReference w:type="default" r:id="rId4"/><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """,
    ]
    for (path, text) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    if let chart = photo(width: 400, height: 200) {
        try FileManager.default.createDirectory(at: root.appending(path: "word/media"), withIntermediateDirectories: true)
        try pngData(chart).write(to: root.appending(path: "word/media/chart.png"))
    }
    try zipFolder(root, to: folder.appending(path: "rich.docx"))
    try? FileManager.default.removeItem(at: root)
    print("wrote rich.docx")
}

// MARK: Text documents

if let image = photo(width: 240, height: 120) {
    try pngData(image).write(to: folder.appending(path: "notes-image.png"))
}
try """
---
title: Trip Notes
tags: [travel, fixtures]
---

# Trip Notes

Some **bold**, some *italic*, and a [link](https://example.com).

| Day | Place | Miles |
|-----|-------|------:|
| 1 | Lake | 12 |
| 2 | Ridge | 8 |

```swift
let greeting = "Hello, trail"
print(greeting)
```

![Route](notes-image.png)

- Water
- Map
""".write(to: folder.appending(path: "notes.md"), atomically: true, encoding: .utf8)
try """
<!doctype html>
<html><head><meta charset="utf-8"><title>Station Report</title></head>
<body>
<h1>Station Report</h1>
<p>Readings from the <em>north</em> station, with <strong>two</strong> sensors.</p>
<ul><li>Temperature</li><li>Humidity</li></ul>
<table border="1"><tr><th>Sensor</th><th>Value</th></tr><tr><td>Temperature</td><td>21.5</td></tr><tr><td>Humidity</td><td>48%</td></tr></table>
<p><img src="notes-image.png" alt="Station"></p>
</body></html>
""".write(to: folder.appending(path: "page.html"), atomically: true, encoding: .utf8)
try """
Languages
Hindi: नमस्ते दुनिया, यह एक परीक्षण है।
Chinese: 你好，世界。这是一个测试。
Japanese: こんにちは世界
Arabic: مرحبا بالعالم، هذا اختبار.
""".write(to: folder.appending(path: "scripts.txt"), atomically: true, encoding: .utf8)
print("wrote notes.md, page.html, scripts.txt")

// MARK: Images

func writeImage(_ image: CGImage, _ name: String, type: UTType, properties: [CFString: Any] = [:]) {
    guard let destination = CGImageDestinationCreateWithURL(folder.appending(path: name) as CFURL, type.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    if CGImageDestinationFinalize(destination) {
        print("wrote \(name)")
    }
}

func alphaImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(srgbRed: 0.95, green: 0.62, blue: 0.12, alpha: 1))
    context.fillEllipse(in: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
    return context.makeImage()
}

func flatImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(srgbRed: 0.98, green: 0.85, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return context.makeImage()
}

if let image = alphaImage(width: 300, height: 200) {
    writeImage(image, "alpha.png", type: .png)
}
if let image = photo(width: 600, height: 400) {
    writeImage(image, "rotated.jpg", type: .jpeg, properties: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.85])
    writeImage(image, "photo.tiff", type: .tiff)
    // ImageIO can't write WebP, so make a PNG and convert it with cwebp.
    let png = FileManager.default.temporaryDirectory.appending(path: "webp-source.png")
    try pngData(image).write(to: png)
    let process = Process()
    process.executableURL = URL(filePath: "/opt/homebrew/bin/cwebp")
    process.arguments = ["-quiet", "-q", "80", png.path(percentEncoded: false), "-o", folder.appending(path: "photo.webp").path(percentEncoded: false)]
    if (try? process.run()) != nil {
        process.waitUntilExit()
        print(process.terminationStatus == 0 ? "wrote photo.webp" : "cwebp failed: photo.webp not written")
    } else {
        print("cwebp not found (brew install webp): photo.webp not written")
    }
}
if let destination = CGImageDestinationCreateWithURL(folder.appending(path: "animated.gif") as CFURL, UTType.gif.identifier as CFString, 3, nil) {
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for size in [80, 120, 160] {
        if let frame = alphaImage(width: size * 2, height: 200) {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
    }
    if CGImageDestinationFinalize(destination) {
        print("wrote animated.gif")
    }
}
if let image = flatImage(width: 12000, height: 12000) {
    writeImage(image, "huge.png", type: .png)
}
if let image = flatImage(width: 1, height: 1) {
    writeImage(image, "tiny.png", type: .png)
}
