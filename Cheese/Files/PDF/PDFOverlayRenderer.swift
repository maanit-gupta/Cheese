import AppKit
import CoreText
import Foundation
import SwiftUI

/// One page as the overlay sees it: upright, origin at the bottom left.
struct OverlayPage: Sendable {
    var index: Int
    var count: Int
    var size: CGSize
}

/// Redraws every page of a PDF into a new one and draws an overlay on top. Pages are drawn with
/// `drawPDFPage`, so text stays selectable and vector content stays vector: nothing is rasterized.
enum PDFOverlayRenderer {
    static func render(
        _ source: URL,
        to output: URL,
        overlay: (CGContext, OverlayPage) throws -> Void
    ) throws {
        guard let document = CGPDFDocument(source as CFURL) else { throw FileToolError.unreadable(source.lastPathComponent) }
        guard !document.isEncrypted || document.isUnlocked else {
            throw FileToolError.message("\(source.lastPathComponent) is password-protected.")
        }
        let count = document.numberOfPages
        guard count > 0 else { throw FileToolError.emptyDocument }
        guard let context = CGContext(output as CFURL, mediaBox: nil, documentInfo(of: document)) else {
            throw FileToolError.writeFailed(output.lastPathComponent)
        }
        for number in 1...count {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            let quarterTurns = ((page.rotationAngle / 90) % 4 + 4) % 4
            let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
            var mediaBox = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.saveGState()
            // Bakes the page's rotation and crop into the new page so it looks the same.
            context.concatenate(page.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
            context.clip(to: box)
            context.drawPDFPage(page)
            context.restoreGState()
            context.saveGState()
            try overlay(context, OverlayPage(index: number - 1, count: count, size: size))
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Title, author and the like, carried over to the new file.
    private static func documentInfo(of document: CGPDFDocument) -> CFDictionary? {
        guard let info = document.info else { return nil }
        var result: [CFString: Any] = [:]
        let keys: [(String, CFString)] = [
            ("Title", kCGPDFContextTitle), ("Author", kCGPDFContextAuthor),
            ("Subject", kCGPDFContextSubject), ("Creator", kCGPDFContextCreator),
        ]
        for (name, key) in keys {
            var value: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, name, &value), let value, let string = CGPDFStringCopyTextString(value) {
                result[key] = string as String
            }
        }
        return result.isEmpty ? nil : result as CFDictionary
    }
}

/// Where overlays go on a page. Pure, so placement is tested.
enum OverlayLayout {
    enum Anchor: String, Codable, Sendable, CaseIterable, Identifiable {
        case topLeft, topCenter, topRight
        case center
        case bottomLeft, bottomCenter, bottomRight

        var id: Self { self }

        var title: String {
            switch self {
            case .topLeft: "Top left"
            case .topCenter: "Top center"
            case .topRight: "Top right"
            case .center: "Center"
            case .bottomLeft: "Bottom left"
            case .bottomCenter: "Bottom center"
            case .bottomRight: "Bottom right"
            }
        }
    }

    /// The rect an item of `size` occupies at `anchor`, `margin` points in from the edges.
    static func rect(for size: CGSize, at anchor: Anchor, in page: CGSize, margin: CGFloat) -> CGRect {
        let x: CGFloat = switch anchor {
        case .topLeft, .bottomLeft: margin
        case .topCenter, .center, .bottomCenter: (page.width - size.width) / 2
        case .topRight, .bottomRight: page.width - margin - size.width
        }
        let y: CGFloat = switch anchor {
        case .bottomLeft, .bottomCenter, .bottomRight: margin
        case .center: (page.height - size.height) / 2
        case .topLeft, .topCenter, .topRight: page.height - margin - size.height
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Centers of a grid of tiles that covers the page even when each tile is rotated.
    static func tileCenters(itemSize: CGSize, page: CGSize, gap: CGFloat) -> [CGPoint] {
        let step = CGSize(width: max(itemSize.width + gap, 1), height: max(itemSize.height + gap, 1))
        // Start half a tile outside the page so rotated tiles still reach the corners.
        var centers: [CGPoint] = []
        var row = 0
        var y = -step.height / 2
        while y < page.height + step.height {
            // Every other row is shifted by half a tile, like bricks.
            var x = (row.isMultiple(of: 2) ? 0 : step.width / 2) - step.width / 2
            while x < page.width + step.width {
                centers.append(CGPoint(x: x, y: y))
                x += step.width
            }
            y += step.height
            row += 1
        }
        return centers
    }
}

/// Draws a line of text centered on a point, optionally rotated.
enum OverlayText {
    static func line(_ text: String, fontName: String, size: CGFloat, color: CGColor) -> CTLine {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Typographic width and height (ascent + descent) of a line.
    static func size(of line: CTLine) -> CGSize {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return CGSize(width: width, height: ascent + descent)
    }

    static func draw(_ line: CTLine, centeredAt center: CGPoint, rotation degrees: CGFloat, in context: CGContext) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: degrees * .pi / 180)
        context.textPosition = CGPoint(x: -width / 2, y: -(ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension RGBAColor {
    static let gray = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)

    /// A binding for SwiftUI's `ColorPicker`.
    static func binding(_ color: Binding<RGBAColor>) -> Binding<Color> {
        Binding {
            Color(.sRGB, red: color.wrappedValue.red, green: color.wrappedValue.green, blue: color.wrappedValue.blue, opacity: color.wrappedValue.alpha)
        } set: { newValue in
            guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            color.wrappedValue = RGBAColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
        }
    }
}

/// Which pages an overlay goes on.
enum PageSelection: String, Codable, Sendable, CaseIterable, Identifiable {
    case all
    case range

    var id: Self { self }
    var title: String { self == .all ? "All pages" : "Page range" }

    /// 0-based page indexes to include, or nil for all.
    static func indexes(_ selection: PageSelection, ranges: String, pageCount: Int) throws -> Set<Int>? {
        guard selection == .range else { return nil }
        return Set(try PageRangeParser.parse(ranges, pageCount: pageCount).flatMap { $0.map { $0 - 1 } })
    }
}
