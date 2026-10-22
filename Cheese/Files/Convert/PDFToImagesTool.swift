import Foundation
import ImageIO
import SwiftUI

/// Renders PDF pages to PNG or JPEG at 72, 150 or 300 DPI into a `Report (images)` folder.
struct PDFToImagesTool: FileTool {
    enum Format: String, Codable, Sendable, CaseIterable, Identifiable {
        case png
        case jpeg

        var id: Self { self }
        var imageFormat: ImageFormat { self == .png ? .png : .jpeg }
    }

    struct Options: Codable, Sendable, Equatable {
        var format = Format.png
        var dpi = 150
        /// Empty means every page.
        var pages = ""
    }

    static let dpiChoices = [72, 150, 300]

    let id = ToolID.pdfToImages
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Format", selection: options.format) {
            ForEach(Format.allCases) { Text($0.imageFormat.title).tag($0) }
        }
        Picker("Resolution", selection: options.dpi) {
            ForEach(Self.dpiChoices, id: \.self) { Text("\($0) DPI").tag($0) }
        }
        TextField("Pages", text: options.pages, prompt: Text("All pages"))
    }

    func problem(with options: Options, inputs: [URL]) -> String? {
        guard !options.pages.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        for input in inputs {
            guard let count = PDFPageCounts.count(input) else { return "\(input.lastPathComponent) can't be opened." }
            do {
                _ = try PageRangeParser.parse(options.pages, pageCount: count)
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    /// 1-based pages to render, in order and without repeats.
    nonisolated static func pageNumbers(_ text: String, pageCount: Int) throws -> [Int] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(1...max(pageCount, 1)) }
        var seen: Set<Int> = []
        return try PageRangeParser.parse(text, pageCount: pageCount).flatMap(Array.init).filter { seen.insert($0).inserted }
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let document = try PDFFiles.open(input)
            let pages = try Self.pageNumbers(options.pages, pageCount: document.pageCount)
            let folder = try context.outputFolder(for: input, suffix: "images")
            let base = OutputNamer.baseName(of: input)
            let format = options.format.imageFormat
            let dpi = CGFloat(options.dpi)
            for number in pages {
                try Task.checkCancellation()
                guard let page = document.page(at: number - 1)?.pageRef,
                      let image = PDFRasterizer.render(page, dpi: dpi)
                else { throw FileToolError.message("Page \(number) couldn't be rendered.") }
                var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
                if format == .jpeg {
                    properties[kCGImageDestinationLossyCompressionQuality] = 0.9
                }
                let name = OutputNamer.numberedFile(base: base, index: number, total: document.pageCount, extension: format.fileExtension)
                try ImageFiles.write(image, properties: properties, to: folder.appending(path: name), format: format)
            }
        }
    }
}
