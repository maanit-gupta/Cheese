import AppKit
import PDFKit
import Vision

/// Text with fonts and positions from a PDF page's text layer (PDFKit), or from Vision OCR when
/// the page has none (a scan). Frames use a top-left origin in page points.
enum PDFTextExtractor {
    static func hasText(_ page: PDFPage) -> Bool {
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the text layer can be trusted for words: there is one, it isn't mostly garbage, and no
    /// text is drawn in a font without a Unicode map (PDFKit drops that text). Otherwise use OCR.
    static func isReadable(_ page: PDFPage) -> Bool {
        guard hasText(page), !PageLayoutPlanner.isUnreadable(page.string ?? "") else { return false }
        guard let cgPage = page.pageRef else { return true }
        return PDFContentScanner.scan(cgPage).glyphs.filter { !$0.hasUnicodeMap }.count < 3
    }

    /// Words with boxes. Each word's box comes from a selection over its range of `page.string`;
    /// `characterBounds(at:)` can't be used because its indexes skip the line breaks PDFKit adds.
    static func words(on page: PDFPage) -> [PositionedWord] {
        let box = page.bounds(for: .cropBox)
        let text = page.string ?? ""
        let nsText = text as NSString
        return text.matches(of: /\S+/).compactMap { match in
            let range = NSRange(match.range, in: text)
            guard let selection = page.selection(for: range) else { return nil }
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return PositionedWord(text: PageLayoutPlanner.normalizedText(nsText.substring(with: range)), frame: topLeft(bounds, in: box))
        }
    }

    /// Everything the layout planner needs from a page: PDFKit's lines as characters with their
    /// boxes (one selection per character: `characterBounds(at:)` drifts from the string's indexes),
    /// fonts from the content stream, painted paths, picture-font glyphs and images.
    static func pageInput(on page: PDFPage) -> PageInput {
        let geometry = PDFPageGeometry(page)
        guard let cgPage = page.pageRef else { return PageInput(lines: [], size: geometry.size) }
        let scanned = PDFContentScanner.scan(cgPage)
        let glyphs = GlyphIndex(scanned.glyphs)
        let string = (page.string ?? "") as NSString
        var lines: [[PageChar]] = []
        for line in page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [] {
            var chars: [PageChar] = []
            var strays = 0
            for rangeIndex in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: rangeIndex, on: page)
                guard range.location != NSNotFound, NSMaxRange(range) <= string.length else { continue }
                var index = range.location
                while index < NSMaxRange(range) {
                    let composed = string.rangeOfComposedCharacterSequence(at: index)
                    index = NSMaxRange(composed)
                    let text = string.substring(with: composed)
                    guard text != "\n", text != "\r", text != "\r\n", let selection = page.selection(for: composed) else { continue }
                    let bounds = selection.bounds(for: page)
                    guard !bounds.isEmpty || text.allSatisfy(\.isWhitespace) else { continue }
                    let font = selection.attributedString.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
                    let glyphIndex = glyphs.index(for: bounds)
                    let glyph = glyphIndex.map { scanned.glyphs[$0] }
                    let fontName = glyph?.fontName ?? ""
                    let pointSize = font?.pointSize ?? glyph?.size ?? 11
                    if !PDFFontClass.isMath(fontName), bounds.height > max(pointSize * 4, 30),
                       !text.contains(where: { $0.isLetter || $0.isNumber }) {
                        strays += 1
                    }
                    var frame = geometry.upright(bounds)
                    var baseline: CGFloat?
                    if let glyph {
                        baseline = geometry.upright(CGRect(origin: glyph.origin, size: .zero)).minY
                        // Text glyphs get their own height; math glyphs (tall ∑, ∫, brackets) keep the
                        // generous box, which the planner clips to the lines around an equation.
                        if !PDFFontClass.isMath(fontName) {
                            let box = geometry.upright(glyph.box)
                            frame = CGRect(x: frame.minX, y: box.minY, width: frame.width, height: box.height)
                        }
                    }
                    chars.append(PageChar(
                        text: text, frame: frame, fontSize: pointSize, fontName: fontName,
                        isBold: isBold(font) || PDFFontClass.isBold(fontName), isItalic: isItalic(font) || PDFFontClass.isItalic(fontName),
                        baseline: baseline
                    ))
                }
            }
            // A line of nothing but symbols with boxes many lines tall is picture glyphs PDFKit read
            // as text (LaTeX's line segments come out as "." and "@").
            let visible = chars.filter { !$0.isSpace }.count
            if visible > 0, strays < visible {
                lines.append(chars)
            }
        }
        let graphic = scanned.glyphs.filter { PDFFontClass.isGraphic($0.fontName) }.map { geometry.upright($0.box) }
        // Fonts without a Unicode map: PDFKit drops their text or returns garbage, so it's read with OCR.
        let orphans = scanned.glyphs.filter { !$0.hasUnicodeMap && !PDFFontClass.isGraphic($0.fontName) && $0.size > 0 }
            .map { geometry.upright($0.box) }
        let images = PDFImageInspector.imageRects(on: cgPage).map(geometry.upright)
        return PageInput(
            lines: lines, paths: scanned.paths.map(geometry.upright), graphicGlyphs: graphic, unextractedGlyphs: orphans,
            images: images, size: geometry.size
        )
    }

    static func topLeft(_ rect: CGRect, in box: CGRect) -> CGRect {
        CGRect(x: rect.minX - box.minX, y: box.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName.lowercased()
        return ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
    }

    private static func isItalic(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { return true }
        let name = font.fontName.lowercased()
        return name.contains("italic") || name.contains("oblique")
    }
}

/// Maps a page's default user space to upright page points with a top-left origin, the way the page
/// is shown (its crop box, rotated by its `/Rotate`). Uses the same transform the rasterizer draws with.
struct PDFPageGeometry {
    let size: CGSize
    private let toUprightBottomLeft: CGAffineTransform

    init(_ page: PDFPage) {
        if let cgPage = page.pageRef {
            self.init(cgPage)
        } else {
            let box = page.bounds(for: .cropBox)
            self.init(size: box.size, transform: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        }
    }

    private init(size: CGSize, transform: CGAffineTransform) {
        self.size = size
        toUprightBottomLeft = transform
    }

    init(_ page: CGPDFPage) {
        let size = PDFPageDrawing.uprightSize(of: page)
        self.init(size: size, transform: page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
    }

    func upright(_ rect: CGRect) -> CGRect {
        let mapped = rect.applying(toUprightBottomLeft)
        return CGRect(x: mapped.minX, y: size.height - mapped.maxY, width: mapped.width, height: mapped.height)
    }
}

/// Scanned glyphs bucketed by baseline, to find the one under a character's box.
struct GlyphIndex {
    private static let bucket: CGFloat = 4
    private let glyphs: [ScannedGlyph]
    private var buckets: [Int: [Int]] = [:]

    init(_ glyphs: [ScannedGlyph]) {
        self.glyphs = glyphs
        // PDFKit returns no text for fonts without a Unicode map, so its characters never belong to them.
        for (index, glyph) in glyphs.enumerated() where glyph.hasUnicodeMap {
            buckets[Int((glyph.origin.y / Self.bucket).rounded(.down)), default: []].append(index)
        }
    }

    func glyph(for box: CGRect) -> ScannedGlyph? {
        index(for: box).map { glyphs[$0] }
    }

    /// The glyph whose origin sits at the left of `box` (default user space) and within its height.
    func index(for box: CGRect) -> Int? {
        guard !box.isNull, box.width > 0 || box.height > 0 else { return nil }
        let low = Int(((box.minY - 2) / Self.bucket).rounded(.down))
        let high = Int(((box.maxY + 2) / Self.bucket).rounded(.down))
        var best: Int?
        var bestDistance = CGFloat.infinity
        for key in low...max(low, high) {
            for index in buckets[key] ?? [] {
                let glyph = glyphs[index]
                guard glyph.origin.y >= box.minY - 2, glyph.origin.y <= box.maxY + 2,
                      glyph.origin.x >= box.minX - 1.5, glyph.origin.x <= box.maxX
                else { continue }
                let distance = abs(glyph.origin.x - box.minX)
                if distance < bestDistance {
                    best = index
                    bestDistance = distance
                }
            }
        }
        return best
    }
}

/// Text from scanned pages with Vision, as lines and as words.
enum ScannedPageReader {
    private static let dpi: CGFloat = 200

    static func lines(on page: PDFPage) throws -> [LayoutLine] {
        try recognize(page).map { observation, text, frame in
            // A text box is about 1.3 times the font size.
            LayoutLine(runs: [LayoutRun(text: text, fontSize: (frame.height / 1.3).rounded())], frame: frame)
        }
    }

    static func words(on page: PDFPage) throws -> [PositionedWord] {
        let box = page.bounds(for: .cropBox)
        return try recognize(page).flatMap { observation, text, _ -> [PositionedWord] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            return text.split(separator: " ").compactMap { word -> PositionedWord? in
                guard let range = Range(NSRange(word.startIndex..<word.endIndex, in: text), in: candidate.string),
                      let rect = try? candidate.boundingBox(for: range)?.boundingBox
                else { return nil }
                return PositionedWord(text: String(word), frame: pageRect(rect, size: box.size))
            }
        }
    }

    /// The text in one region (upright page points, top-left origin), read with OCR: for lines whose
    /// font has no usable Unicode map.
    static func text(in region: CGRect, on page: PDFPage) throws -> String {
        guard let cgPage = page.pageRef, let image = PDFRasterizer.render(cgPage, uprightRegion: region.insetBy(dx: -2, dy: -2), dpi: 300) else {
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Each recognized line with its text and frame in page points (top-left origin).
    private static func recognize(_ page: PDFPage) throws -> [(VNRecognizedTextObservation, String, CGRect)] {
        guard let cgPage = page.pageRef, let image = PDFRasterizer.render(cgPage, dpi: dpi) else {
            throw FileToolError.message("A scanned page couldn't be read.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = PDFPageDrawing.uprightSize(of: cgPage)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (observation, text, pageRect(observation.boundingBox, size: size))
        }
    }

    /// Vision's normalized, bottom-left box → page points, top-left origin.
    private static func pageRect(_ normalized: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
            width: normalized.width * size.width, height: normalized.height * size.height
        )
    }
}
