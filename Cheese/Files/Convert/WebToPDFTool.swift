import Foundation
import SwiftUI

/// HTML, Markdown and plain text → PDF on A4 or Letter. HTML may use images and styles from its
/// own folder; nothing remote is loaded.
struct WebToPDFTool: FileTool {
    struct Options: Codable, Sendable, Equatable {
        var pageSize = PDFPageSize.localeDefault
    }

    let id = ToolID.webToPDF
    var defaultOptions: Options { Options() }
    var hint: String? { "Remote images and styles aren't loaded; files next to the document are." }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Page size", selection: options.pageSize) {
            Text(PDFPageSize.a4.title).tag(PDFPageSize.a4)
            Text(PDFPageSize.letter.title).tag(PDFPageSize.letter)
        }
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        let pageSize = options.pageSize == .fitToImage ? PDFPageSize.localeDefault : options.pageSize
        return .perFile(tool: id, inputs: inputs) { input, context in
            let output = context.outputURL(for: input, suffix: nil, extension: "pdf")
            let kind = FileKind(url: input)
            try await TimeLimit.run(seconds: 60) {
                try await WebRenderer.renderPDF(input, kind: kind, pageSize: pageSize, to: output)
            }
        }
    }
}
