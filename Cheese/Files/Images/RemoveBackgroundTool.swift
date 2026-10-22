import CoreImage
import Foundation
import ImageIO
import SwiftUI
import Vision

/// Cuts the subject out of a photo with Vision's on-device foreground mask and saves a
/// transparent PNG. Writes nothing when Vision finds no subject.
struct RemoveBackgroundTool: FileTool {
    let id = ToolID.removeBackground
    var defaultOptions: NoOptions { NoOptions() }
    var hint: String? { "Works best on photos with a clear subject: people, pets or objects." }

    func optionsView(options: Binding<NoOptions>, inputs: [URL]) -> some View {
        EmptyView()
    }

    func work(inputs: [URL], options: NoOptions) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let source = try ImageFiles.source(at: input)
            let image = try ImageFiles.uprightImage(from: source, name: input.lastPathComponent)
            let cutout = try BackgroundRemover.cutout(image)
            var properties: [CFString: Any] = [:]
            let sourceProperties = ImageFiles.properties(of: source)
            properties[kCGImagePropertyDPIWidth] = sourceProperties[kCGImagePropertyDPIWidth]
            properties[kCGImagePropertyDPIHeight] = sourceProperties[kCGImagePropertyDPIHeight]
            let output = context.outputURL(for: input, suffix: "no background", extension: "png")
            try ImageFiles.write(cutout, properties: properties, to: output, format: .png)
        }
    }
}

enum BackgroundRemover {
    /// The image with everything but its foreground subjects made transparent.
    static func cutout(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw FileToolError.noSubjectFound
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let output = CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: space) else {
            throw FileToolError.message("The cut-out couldn't be made.")
        }
        return output
    }
}
