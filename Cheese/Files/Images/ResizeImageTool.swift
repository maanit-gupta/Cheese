import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import SwiftUI

/// Resizes images by percentage, to fit within a box, or to an exact size, with Lanczos scaling.
/// Keeps the format and color profile; the result is upright, so its orientation tag is reset.
struct ResizeImageTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        var mode = ResizeMode.percentage
        var percent = 50.0
        var maxWidth = 1920
        var maxHeight = 1920
        var width = 1280
        var height = 720
        var lockAspect = true
    }

    let id = ToolID.resizeImage
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        ResizeOptionsView(options: options, original: inputs.first.flatMap(ImageFiles.uprightSize(of:)))
    }

    func problem(with options: Options, inputs: [URL]) -> String? {
        switch options.mode {
        case .percentage: options.percent > 0 ? nil : "Enter a percentage above 0."
        case .maxSize: options.maxWidth > 0 || options.maxHeight > 0 ? nil : "Enter a maximum width or height."
        case .exact: options.width > 0 && (options.lockAspect || options.height > 0) ? nil : "Enter a width and height."
        }
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let source = try ImageFiles.source(at: input)
            let upright = try ImageFiles.uprightImage(from: source, name: input.lastPathComponent)
            let target = ResizeMath.target(
                for: PixelSize(width: upright.width, height: upright.height), mode: options.mode,
                percent: options.percent, maxWidth: options.maxWidth, maxHeight: options.maxHeight,
                width: options.width, height: options.height, lockAspect: options.lockAspect
            )
            let resized = try ImageScaler.scale(upright, to: target)
            let format = ImageFormat(url: input).flatMap { ImageFormat.writable.contains($0) ? $0 : nil } ?? .png
            var properties = ImageFiles.properties(of: source)
            ImageFiles.markUpright(&properties)
            if format.isLossy {
                properties[kCGImageDestinationLossyCompressionQuality] = 0.9
            }
            let output = context.outputURL(for: input, suffix: "resized", extension: format.fileExtension)
            try ImageFiles.write(resized, properties: properties, to: output, format: format)
        }
    }
}

private struct ResizeOptionsView: View {
    @Binding var options: ResizeImageTool.Options
    let original: PixelSize?

    var body: some View {
        Picker("Resize", selection: $options.mode) {
            ForEach(ResizeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        switch options.mode {
        case .percentage:
            LabeledContent("Scale") {
                TextField("Percent", value: $options.percent, format: .number)
                    .frame(width: 70)
                Text("%")
            }
        case .maxSize:
            LabeledContent("Max size") {
                TextField("Width", value: $options.maxWidth, format: .number).frame(width: 70)
                Text("×")
                TextField("Height", value: $options.maxHeight, format: .number).frame(width: 70)
                Text("px")
            }
        case .exact:
            LabeledContent("Size") {
                TextField("Width", value: $options.width, format: .number).frame(width: 70)
                Text("×")
                if options.lockAspect, let original {
                    Text("\(ResizeMath.lockedHeight(forWidth: options.width, original: original))")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .leading)
                } else {
                    TextField("Height", value: $options.height, format: .number).frame(width: 70)
                }
                Text("px")
            }
            Toggle("Keep aspect ratio", isOn: $options.lockAspect)
        }
        if let original {
            LabeledContent("Original", value: "\(original.width) × \(original.height) px")
                .foregroundStyle(.secondary)
        }
    }
}

/// High-quality downscaling and upscaling with Core Image's Lanczos filter.
enum ImageScaler {
    static func scale(_ image: CGImage, to size: PixelSize) throws -> CGImage {
        guard size.width != image.width || size.height != image.height else { return image }
        let scaleY = Double(size.height) / Double(image.height)
        let aspect = (Double(size.width) / Double(image.width)) / scaleY
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(aspect)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let output = filter.outputImage,
              let scaled = context.createCGImage(output, from: rect, format: .RGBA8, colorSpace: space)
        else { throw FileToolError.message("The image couldn't be resized.") }
        return scaled
    }
}

extension ImageFiles {
    /// Upright pixel size, without decoding the image.
    static func uprightSize(of url: URL) -> PixelSize? {
        guard let source = try? source(at: url) else { return nil }
        let props = properties(of: source)
        guard let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }

    /// Marks properties as belonging to already-upright pixels.
    static func markUpright(_ properties: inout [CFString: Any]) {
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
    }
}
