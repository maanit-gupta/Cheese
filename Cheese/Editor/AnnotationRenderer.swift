import CoreGraphics
import CoreText

/// Draws an `EditorDocument` onto its base image with Core Graphics. Pure, so it runs on any thread.
enum AnnotationRenderer {
    /// Renders every annotation in order. With `applyCrop`, the result is cut to the document's crop.
    static func render(_ base: CGImage, document: EditorDocument, applyCrop: Bool) -> CGImage? {
        let width = base.width
        let height = base.height
        let colorSpace = outputColorSpace(for: base)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: bounds)
        // Annotations use a top-left origin, like the editor's view.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        for annotation in document.annotations {
            draw(annotation, in: context, imageHeight: CGFloat(height))
        }

        guard let rendered = context.makeImage() else { return nil }
        guard applyCrop, let crop = document.crop else { return rendered }
        let pixels = crop.integral.intersection(bounds)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return rendered }
        return rendered.cropping(to: pixels)
    }

    private static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, imageHeight: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }

        switch annotation {
        case let .arrow(from, to, color, lineWidth):
            drawArrow(from: from, to: to, color: color, lineWidth: lineWidth, in: context)

        case let .rectangle(rect, color, lineWidth):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineJoin(.round)
            context.stroke(rect.standardized)

        case let .text(string, origin, color, fontSize):
            drawText(string, at: origin, color: color, fontSize: fontSize, in: context)

        case let .highlight(points, color, lineWidth):
            guard !points.isEmpty else { return }
            context.setFillColor(color.cgColor)
            context.setBlendMode(.multiply)
            context.addPath(inkPath(points: points, options: .highlighter(width: lineWidth)))
            context.fillPath()

        case let .ink(points, color, lineWidth):
            guard !points.isEmpty else { return }
            context.setFillColor(color.cgColor)
            context.addPath(inkPath(points: points, options: .pen(width: lineWidth)))
            context.fillPath()

        case let .pixelate(rect, blockSize):
            pixelate(rect, blockSize: blockSize, in: context, imageHeight: imageHeight)
        }
    }

    /// The pen and highlighter share draw on screen's ink engine, so both feel the same.
    static func inkPath(points: [CGPoint], options: StrokeBuilder.Options) -> CGPath {
        StrokeBuilder.path(points: points, options: options)
    }

    static func arrowHeadLength(for lineWidth: CGFloat) -> CGFloat {
        max(lineWidth * 4, 12)
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: RGBAColor, lineWidth: CGFloat, in context: CGContext) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return }
        let angle = atan2(dy, dx)
        let headLength = min(arrowHeadLength(for: lineWidth), length)
        let spread = CGFloat.pi / 7
        // Stop the shaft inside the head so its square end doesn't poke through the tip.
        let shaftEnd = CGPoint(x: to.x - cos(angle) * headLength * 0.8, y: to.y - sin(angle) * headLength * 0.8)

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.strokeLineSegments(between: [from, shaftEnd])

        context.beginPath()
        context.move(to: to)
        context.addLine(to: CGPoint(x: to.x - cos(angle - spread) * headLength, y: to.y - sin(angle - spread) * headLength))
        context.addLine(to: CGPoint(x: to.x - cos(angle + spread) * headLength, y: to.y - sin(angle + spread) * headLength))
        context.closePath()
        context.fillPath()
    }

    static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// `origin` is the top-left of the first line.
    private static func drawText(_ string: String, at origin: CGPoint, color: RGBAColor, fontSize: CGFloat, in context: CGContext) {
        let font = font(size: fontSize)
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ] as CFDictionary

        // The context is flipped; flip glyphs back so text isn't upside down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in string.components(separatedBy: "\n").enumerated() {
            guard let attributed = CFAttributedStringCreate(nil, line as CFString, attributes) else { continue }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent + CGFloat(index) * lineHeight)
            CTLineDraw(ctLine, context)
        }
    }

    /// Replaces a region with large blocks of its average color, so text under it can't be read back.
    private static func pixelate(_ rect: CGRect, blockSize: CGFloat, in context: CGContext, imageHeight: CGFloat) {
        let rect = rect.standardized.integral
        guard rect.width >= 1, rect.height >= 1, let snapshot = context.makeImage(),
              let region = snapshot.cropping(to: rect)
        else { return }

        let block = max(blockSize, 2)
        let smallWidth = max(Int((rect.width / block).rounded(.up)), 1)
        let smallHeight = max(Int((rect.height / block).rounded(.up)), 1)
        guard let small = CGContext(
            data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .medium
        small.draw(region, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let blocks = small.makeImage() else { return }

        // Draw in unflipped space; `rect` is top-left based.
        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -imageHeight)
        context.interpolationQuality = .none
        context.draw(blocks, in: CGRect(x: rect.minX, y: imageHeight - rect.maxY, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}
