import Foundation
import SwiftUI

/// Re-encodes images at a lower quality (JPEG, HEIC, WebP) and strips EXIF and GPS by default.
/// Keeps the original when the result wouldn't be smaller.
struct CompressImageTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        var quality = 0.7
        var stripMetadata = true
    }

    let id = ToolID.compressImage
    var defaultOptions: Options { Options() }
    var hint: String? { "Quality applies to JPEG, HEIC and WebP. Other formats are only re-saved, without metadata if stripped." }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        QualitySlider(quality: options.quality)
        Toggle("Strip metadata (EXIF, GPS)", isOn: options.stripMetadata)
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            guard let format = ImageFormat(url: input), ImageFormat.writable.contains(format) else {
                throw FileToolError.message("\(input.lastPathComponent) is in a format Cheese can't write.")
            }
            let source = try ImageFiles.source(at: input)
            let output = context.outputURL(for: input, suffix: "compressed", extension: format.fileExtension)
            try ImageFiles.write(
                source: source, name: input.lastPathComponent, to: output,
                format: format, quality: options.quality, stripMetadata: options.stripMetadata
            )
            let before = ImageFiles.fileSize(input)
            let after = ImageFiles.fileSize(output)
            if after >= before {
                context.discard(output)
                context.note("\(input.lastPathComponent) is already as small as it gets; kept the original.")
            } else {
                context.note("\(input.lastPathComponent): \(FileSizeText.format(before)) → \(FileSizeText.format(after))")
            }
        }
    }
}
