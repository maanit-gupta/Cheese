import AppKit
import Foundation
import ImageIO
import SwiftUI

/// Stamps text or an image on PDF pages: centered, tiled, or in a corner. The pages stay vector
/// and their text stays selectable.
struct WatermarkTool: FileTool {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case text
        case image

        var id: Self { self }
        var title: String { self == .text ? "Text" : "Image" }
    }

    enum Position: String, Codable, Sendable, CaseIterable, Identifiable {
        case center, tiled, topLeft, topRight, bottomLeft, bottomRight

        var id: Self { self }

        var title: String {
            switch self {
            case .center: "Center"
            case .tiled: "Tiled"
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }

        var anchor: OverlayLayout.Anchor? {
            switch self {
            case .center: .center
            case .tiled: nil
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
        }
    }

    struct Options: Codable, Sendable, Equatable {
        var kind = Kind.text
        var text = "CONFIDENTIAL"
        var fontName = "Helvetica-Bold"
        var fontSize = 60.0
        var color = RGBAColor.gray
        var opacity = 0.3
        var rotation = 45.0
        var imagePath = ""
        /// Image width as a fraction of the page width.
        var imageScale = 0.4
        var position = Position.center
        var pages = PageSelection.all
        var ranges = "1"
    }

    static let fonts = ["Helvetica", "Helvetica-Bold", "Times-Roman", "Times-Bold", "Courier", "Courier-Bold", "Georgia", "AvenirNext-Bold"]

    let id = ToolID.watermarkPDF
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        WatermarkOptionsView(options: options)
    }

    func problem(with options: Options, inputs: [URL]) -> String? {
        switch options.kind {
        case .text where options.text.trimmingCharacters(in: .whitespaces).isEmpty:
            return "Enter the watermark text."
        case .image where options.imagePath.isEmpty:
            return "Choose a watermark image."
        default:
            break
        }
        if options.pages == .range {
            for input in inputs {
                guard let count = PDFPageCounts.count(input) else { return "\(input.lastPathComponent) can't be opened." }
                do {
                    _ = try PageRangeParser.parse(options.ranges, pageCount: count)
                } catch {
                    return error.localizedDescription
                }
            }
        }
        return nil
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let image = try options.kind == .image ? Self.loadImage(options.imagePath) : nil
            let output = context.outputURL(for: input, suffix: "watermarked", extension: "pdf")
            var included: Set<Int>?
            try PDFOverlayRenderer.render(input, to: output) { pdf, page in
                if page.index == 0 {
                    included = try PageSelection.indexes(options.pages, ranges: options.ranges, pageCount: page.count)
                }
                guard included?.contains(page.index) ?? true else { return }
                pdf.setAlpha(options.opacity)
                if let image {
                    Self.draw(image, options: options, on: page, in: pdf)
                } else {
                    Self.drawText(options: options, on: page, in: pdf)
                }
            }
        }
    }

    private nonisolated static func loadImage(_ path: String) throws -> CGImage {
        let url = URL(filePath: path)
        let source = try ImageFiles.source(at: url)
        return try ImageFiles.uprightImage(from: source, name: url.lastPathComponent)
    }

    private nonisolated static func drawText(options: Options, on page: OverlayPage, in pdf: CGContext) {
        let line = OverlayText.line(options.text, fontName: options.fontName, size: options.fontSize, color: options.color.cgColor)
        let size = OverlayText.size(of: line)
        for center in centers(for: size, options: options, page: page) {
            OverlayText.draw(line, centeredAt: center, rotation: options.rotation, in: pdf)
        }
    }

    private nonisolated static func draw(_ image: CGImage, options: Options, on page: OverlayPage, in pdf: CGContext) {
        let width = page.size.width * options.imageScale
        let size = CGSize(width: width, height: width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
        pdf.interpolationQuality = .high
        for center in centers(for: size, options: options, page: page) {
            pdf.draw(image, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    private nonisolated static func centers(for size: CGSize, options: Options, page: OverlayPage) -> [CGPoint] {
        guard let anchor = options.position.anchor else {
            return OverlayLayout.tileCenters(itemSize: size, page: page.size, gap: max(size.height, 40) * 1.5)
        }
        let rect = OverlayLayout.rect(for: size, at: anchor, in: page.size, margin: 36)
        return [CGPoint(x: rect.midX, y: rect.midY)]
    }
}

private struct WatermarkOptionsView: View {
    @Binding var options: WatermarkTool.Options

    var body: some View {
        Picker("Watermark", selection: $options.kind) {
            ForEach(WatermarkTool.Kind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        switch options.kind {
        case .text:
            TextField("Text", text: $options.text)
            Picker("Font", selection: $options.fontName) {
                ForEach(WatermarkTool.fonts, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Size") {
                Slider(value: $options.fontSize, in: 8...200, step: 1)
                Text("\(Int(options.fontSize)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            ColorPicker("Color", selection: RGBAColor.binding($options.color), supportsOpacity: false)
            LabeledContent("Rotation") {
                Slider(value: $options.rotation, in: -90...90, step: 5)
                Text("\(Int(options.rotation))°").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
        case .image:
            LabeledContent("Image") {
                Text(options.imagePath.isEmpty ? "None" : (options.imagePath as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: chooseImage)
            }
            LabeledContent("Scale") {
                Slider(value: $options.imageScale, in: 0.05...1)
                Text(options.imageScale, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 50, alignment: .trailing)
            }
        }
        LabeledContent("Opacity") {
            Slider(value: $options.opacity, in: 0.05...1)
            Text(options.opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
        Picker("Position", selection: $options.position) {
            ForEach(WatermarkTool.Position.allCases) { Text($0.title).tag($0) }
        }
        Picker("Pages", selection: $options.pages) {
            ForEach(PageSelection.allCases) { Text($0.title).tag($0) }
        }
        if options.pages == .range {
            TextField("Range", text: $options.ranges, prompt: Text("1-3, 5"))
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileKind.imageTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            options.imagePath = url.path(percentEncoded: false)
        }
    }
}
