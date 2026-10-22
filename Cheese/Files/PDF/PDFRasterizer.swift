import CoreGraphics
import Foundation
import PDFKit

/// Renders PDF pages to bitmaps, upright and on white.
enum PDFRasterizer {
    /// The page's crop box at `dpi`, with the page's rotation applied.
    static func render(_ page: CGPDFPage, dpi: CGFloat, opaque: Bool = true) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle / 90) % 4 + 4) % 4
        let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let width = max(Int((size.width * scale).rounded(.up)), 1)
        let height = max(Int((size.height * scale).rounded(.up)), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // At unit scale the drawing transform only rotates and moves the box into place.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// One region of a page (in page space, unrotated) at `dpi`, for cropping out images.
    static func render(_ page: CGPDFPage, region: CGRect, dpi: CGFloat) -> CGImage? {
        let scale = dpi / 72
        let width = max(Int((region.width * scale).rounded(.up)), 1)
        let height = max(Int((region.height * scale).rounded(.up)), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
