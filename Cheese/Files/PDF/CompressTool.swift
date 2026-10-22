import Foundation
import SwiftUI

/// Compresses PDFs toward a target size (prefilled with half the original). Saves the smallest
/// result it can get, and keeps the original when nothing smaller is possible.
struct CompressTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        /// Target per file, in megabytes. Prefilled from the inputs each time the panel opens.
        var targetMB = 0.0
    }

    let id = ToolID.compressPDF
    var defaultOptions: Options { Options() }
    var hint: String? { "Image-heavy pages are re-rendered as JPEG to get under the target; text and vector pages stay sharp." }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        CompressOptionsView(options: options, inputs: inputs)
    }

    func problem(with options: Options, inputs: [URL]) -> String? {
        options.targetMB > 0 ? nil : "Enter a target size."
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        let target = Int(options.targetMB * 1_000_000)
        return .perFile(tool: id, inputs: inputs) { input, context in
            let workFolder = FileManager.default.temporaryDirectory.appending(path: "CheeseCompress-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workFolder) }

            let (result, outcome) = try await PDFCompressor.compress(input, target: target, workFolder: workFolder)
            let name = input.lastPathComponent
            let before = ImageFiles.fileSize(input)
            let after = ImageFiles.fileSize(result)
            guard after < before else {
                context.note("\(name) can't be made smaller; kept the original.")
                return
            }
            let output = context.outputURL(for: input, suffix: "compressed", extension: "pdf")
            try FileManager.default.moveItem(at: result, to: output)
            switch outcome {
            case .reached:
                context.note("\(name): \(FileSizeText.format(before)) → \(FileSizeText.format(after))")
            case .floor:
                context.note("\(name): " + CompressionPlanner.unreachableMessage(target: target, smallest: Int(after)))
            }
        }
    }
}

private struct CompressOptionsView: View {
    @Binding var options: CompressTool.Options
    let inputs: [URL]

    private var largest: Int64 {
        inputs.map(ImageFiles.fileSize).max() ?? 0
    }

    var body: some View {
        LabeledContent(inputs.count == 1 ? "Original" : "Largest file", value: CompressionPlanner.megabytes(Int(largest)))
        LabeledContent("Target size") {
            TextField("MB", value: $options.targetMB, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 70)
            Text(inputs.count == 1 ? "MB" : "MB per file")
        }
        .onAppear {
            // Half the original, never remembered from another file.
            options.targetMB = max((Double(largest) / 2 / 100_000).rounded() / 10, 0.1)
        }
    }
}
