import AppKit
import PDFKit
import Vision

/// Text with fonts and positions from a PDF page's text layer (PDFKit), or from Vision OCR when
/// the page has none (a scan). Frames use a top-left origin in page points.
enum PDFTextExtractor {
    static func hasText(_ page: PDFPage) -> Bool {
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lines in PDFKit's reading order, each split into runs by font.
    static func lines(on page: PDFPage) -> [LayoutLine] {
        let box = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: box) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let attributed = line.attributedString, attributed.length > 0 else { return nil }
            var runs: [LayoutRun] = []
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                let text = (attributed.string as NSString).substring(with: range).replacing("\n", with: "")
                guard !text.isEmpty else { return }
                let font = value as? NSFont
                runs.append(LayoutRun(text: text, fontSize: font?.pointSize ?? 11, isBold: isBold(font), isItalic: isItalic(font)))
            }
            guard !runs.isEmpty else { return nil }
            return LayoutLine(runs: runs, frame: topLeft(line.bounds(for: page), in: box))
        }
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
            return PositionedWord(text: nsText.substring(with: range), frame: topLeft(bounds, in: box))
        }
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
