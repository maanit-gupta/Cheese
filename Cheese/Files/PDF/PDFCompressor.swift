import CoreGraphics
import Foundation
import PDFKit

/// Shrinks a PDF toward a target size. First PDFKit's own image options; if that isn't enough,
/// image-dominant pages are re-rendered as JPEG at decreasing DPI and quality while text-only
/// and vector pages are copied as they are.
enum PDFCompressor {
    /// Writes candidates into `workFolder` and returns the chosen one with how it went.
    static func compress(_ input: URL, target: Int, workFolder: URL) async throws -> (url: URL, outcome: CompressionOutcome) {
        let document = try PDFFiles.open(input)
        let stageOne = workFolder.appending(path: "stage-one.pdf")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: stageOne, withOptions: options) else {
            throw FileToolError.writeFailed(input.lastPathComponent)
        }
        guard let original = CGPDFDocument(input as CFURL), let vectors = CGPDFDocument(stageOne as CFURL) else {
            throw FileToolError.unreadable(input.lastPathComponent)
        }
        let imagePages = Set((1...max(original.numberOfPages, 1)).filter { number in
            original.page(at: number).map(PDFImageInspector.isImageDominant) ?? false
        })

        var candidates: [CompressionParameters: URL] = [:]
        let outcome = try await CompressionPlanner.plan(target: target, stageOneSize: Int(ImageFiles.fileSize(stageOne))) { parameters in
            // With no image-heavy pages there's nothing more to squeeze.
            guard !imagePages.isEmpty else { return Int(ImageFiles.fileSize(stageOne)) }
            let url = workFolder.appending(path: "dpi\(parameters.dpi)-q\(Int(parameters.quality * 100)).pdf")
            try render(original: original, vectors: vectors, imagePages: imagePages, parameters: parameters, to: url)
            candidates[parameters] = url
            return Int(ImageFiles.fileSize(url))
        }
        switch outcome {
        case let .reached(_, parameters?), let .floor(_, parameters?):
            return (candidates[parameters] ?? stageOne, outcome)
        case .reached(_, nil), .floor(_, nil):
            return (stageOne, outcome)
        }
    }

    /// Builds a PDF where `imagePages` (1-based) are JPEG renders and every other page is copied
    /// from the stage-one vectors.
    private static func render(
        original: CGPDFDocument,
        vectors: CGPDFDocument,
        imagePages: Set<Int>,
        parameters: CompressionParameters,
        to url: URL
    ) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, PDFOverlayRenderer.documentInfo(of: original)) else {
            throw FileToolError.writeFailed(url.lastPathComponent)
        }
        for number in 1...original.numberOfPages {
            try Task.checkCancellation()
            if imagePages.contains(number), let page = original.page(at: number),
               let rendered = PDFRasterizer.render(page, dpi: CGFloat(parameters.dpi)),
               let jpeg = PDFImages.jpegBacked(rendered, quality: parameters.quality) {
                let size = PDFPageDrawing.uprightSize(of: page)
                PDFPageDrawing.beginPage(size: size, in: context)
                context.interpolationQuality = .high
                context.draw(jpeg, in: CGRect(origin: .zero, size: size))
                context.endPDFPage()
            } else if let page = vectors.page(at: number) {
                let size = PDFPageDrawing.uprightSize(of: page)
                PDFPageDrawing.beginPage(size: size, in: context)
                PDFPageDrawing.drawUpright(page, size: size, in: context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}
