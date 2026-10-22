import Foundation
import PDFKit
import SwiftUI

/// Splits a PDF by page ranges (each range next to the original as `Report (pages 1-3).pdf`),
/// every N pages, or into single pages (both into a `Report (split)` folder).
struct SplitTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        var mode = SplitMode.ranges
        var ranges = "1-3, 4-"
        var everyN = 1
    }

    let id = ToolID.splitPDF
    var defaultOptions: Options { Options() }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Split by", selection: options.mode) {
            ForEach(SplitMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        switch options.wrappedValue.mode {
        case .ranges:
            TextField("Pages", text: options.ranges, prompt: Text("1-3, 5, 8-"))
        case .everyN:
            Stepper(value: options.everyN, in: 1...999) {
                LabeledContent("Pages per file", value: "\(options.wrappedValue.everyN)")
            }
        case .eachPage:
            EmptyView()
        }
    }

    func problem(with options: Options, inputs: [URL]) -> String? {
        for input in inputs {
            guard let count = PDFPageCounts.count(input) else {
                return "\(input.lastPathComponent) can't be opened."
            }
            do {
                _ = try SplitPlanner.parts(mode: options.mode, ranges: options.ranges, everyN: options.everyN, pageCount: count)
            } catch {
                return inputs.count > 1 ? "\(input.lastPathComponent): \(error.localizedDescription)" : error.localizedDescription
            }
        }
        return nil
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let document = try PDFFiles.open(input)
            let parts = try SplitPlanner.parts(mode: options.mode, ranges: options.ranges, everyN: options.everyN, pageCount: document.pageCount)
            if options.mode == .ranges {
                for part in parts {
                    try Task.checkCancellation()
                    let output = context.outputURL(for: input, suffix: part.label, extension: "pdf")
                    try PDFFiles.write(PDFFiles.assemble(document, pages: part.pages.map { ($0 - 1, 0) }), to: output)
                }
            } else {
                let folder = try context.outputFolder(for: input, suffix: "split")
                let base = OutputNamer.baseName(of: input)
                for (index, part) in parts.enumerated() {
                    try Task.checkCancellation()
                    let name = OutputNamer.numberedFile(base: base, index: index + 1, total: parts.count, extension: "pdf")
                    try PDFFiles.write(PDFFiles.assemble(document, pages: part.pages.map { ($0 - 1, 0) }), to: folder.appending(path: name))
                }
            }
        }
    }
}
