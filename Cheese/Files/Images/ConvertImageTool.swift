import Foundation
import SwiftUI

/// Converts images between formats with ImageIO, keeping color profile, orientation and metadata.
struct ConvertImageTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        var format = ImageFormat.jpeg
        var quality = 0.85
    }

    let id = ToolID.convertImage
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Format", selection: options.format) {
            ForEach(ImageFormat.writable) { format in
                Text(format.title).tag(format)
            }
        }
        if options.wrappedValue.format.isLossy {
            QualitySlider(quality: options.quality)
        }
    }

    func problem(with options: Options, inputs: [URL]) -> String? {
        ImageFormat.writable.contains(options.format) ? nil : "\(options.format.title) can't be written on this Mac."
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let source = try ImageFiles.source(at: input)
            let output = context.outputURL(for: input, suffix: nil, extension: options.format.fileExtension)
            try ImageFiles.write(
                source: source, name: input.lastPathComponent, to: output,
                format: options.format, quality: options.quality, stripMetadata: false
            )
        }
    }
}

/// JPEG/HEIC quality, 10–100%.
struct QualitySlider: View {
    @Binding var quality: Double

    var body: some View {
        LabeledContent("Quality") {
            HStack {
                Slider(value: $quality, in: 0.1...1, step: 0.05)
                Text(quality, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
