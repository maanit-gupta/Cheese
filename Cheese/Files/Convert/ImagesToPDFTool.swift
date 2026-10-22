import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One image per page, in panel order, upright per EXIF. JPEGs are embedded as they are;
/// other opaque images are stored as JPEG so the PDF stays small.
struct ImagesToPDFTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        var pageSize = PDFPageSize.fitToImage
        var margin = PDFMargin.none
    }

    let id = ToolID.imagesToPDF
    let ordersInputs = true
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Page size", selection: options.pageSize) {
            ForEach(PDFPageSize.allCases) { Text($0.title).tag($0) }
        }
        Picker("Margins", selection: options.margin) {
            ForEach(PDFMargin.allCases) { Text($0.title).tag($0) }
        }
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        JobWork(tool: id, inputs: inputs) { context in
            guard let first = inputs.first else { return }
            let output = context.outputURL(for: first, suffix: nil, extension: "pdf")
            guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else {
                throw FileToolError.writeFailed(output.lastPathComponent)
            }
            for input in inputs {
                try Task.checkCancellation()
                let source = try ImageFiles.source(at: input)
                let image = try PDFImages.embeddable(source, url: input)
                let layout = ImagePageLayout.layout(
                    imageSize: PDFImages.pointSize(source: source, image: image),
                    pageSize: options.pageSize, margin: options.margin
                )
                var mediaBox = CGRect(origin: .zero, size: layout.page)
                let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
                pdf.beginPDFPage(pageInfo)
                pdf.interpolationQuality = .high
                pdf.draw(image, in: layout.imageRect)
                pdf.endPDFPage()
                context.fileFinished()
            }
            pdf.closePDF()
        }
    }
}

enum PDFImages {
    /// The image to place on a PDF page, upright. JPEGs without rotation pass through untouched;
    /// other opaque images are re-encoded as high-quality JPEG; images with transparency stay lossless.
    static func embeddable(_ source: CGImageSource, url: URL) throws -> CGImage {
        let properties = ImageFiles.properties(of: source)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        if isJPEG, orientation == 1, let provider = CGDataProvider(url: url as CFURL),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return jpeg
        }
        let upright = try ImageFiles.uprightImage(from: source, name: url.lastPathComponent)
        guard !ImageFiles.hasAlpha(upright) else { return upright }
        return jpegBacked(upright) ?? upright
    }

    /// The image as JPEG data, so a PDF stores it with DCT compression.
    static func jpegBacked(_ image: CGImage, quality: Double = 0.9) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The image's size in points, from its DPI (72 when unknown).
    static func pointSize(source: CGImageSource, image: CGImage) -> CGSize {
        let properties = ImageFiles.properties(of: source)
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
    }
}
