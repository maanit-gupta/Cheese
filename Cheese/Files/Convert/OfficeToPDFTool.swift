import Foundation
import SwiftUI

/// Word, Excel or PowerPoint → PDF with the embedded renderers, or with Microsoft Office or
/// LibreOffice when the user turned that on and one is installed. If the native app fails, the
/// file is retried with the embedded renderer and the notification says so.
struct OfficeToPDFTool: FileTool {
    let kind: OfficeRenderer.Kind
    /// Overrides the Settings choice of native app, for tests.
    var nativeOverride: NativeConverter?
    var defaultOptions: NoOptions { NoOptions() }

    var id: ToolID {
        switch kind {
        case .word: .wordToPDF
        case .excel: .excelToPDF
        case .powerPoint: .powerPointToPDF
        }
    }

    /// The embedded engine's known limits, one line each.
    var hint: String? {
        switch kind {
        case .word: "Page breaks are approximate, and complex layouts, SmartArt and charts may be simplified."
        case .excel: "Values only: cell colors, fonts and charts aren't kept. Each sheet starts a new page."
        case .powerPoint: "The roughest of the three: animations, some shapes, SmartArt and media aren't rendered."
        }
    }

    func optionsView(options: Binding<NoOptions>, inputs: [URL]) -> some View {
        EmptyView()
    }

    func work(inputs: [URL], options: NoOptions) -> JobWork {
        let kind = kind
        let paper = PDFPageSize.localeDefault.portraitSize ?? CGSize(width: 595.28, height: 841.89)
        let native = nativeOverride ?? (Preferences().usesNativeOfficeApps ? NativeAppDetector.converter(for: kind) : nil)
        return JobWork(tool: id, inputs: inputs) { context in
            let renderer = await OfficeRenderer()
            for input in inputs {
                try Task.checkCancellation()
                do {
                    let output = context.outputURL(for: input, suffix: nil, extension: "pdf")
                    if let native {
                        do {
                            try await native.convert(input, kind: kind, to: output)
                            context.fileFinished()
                            continue
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try? FileManager.default.removeItem(at: output)
                            context.note("\(native.app.name) couldn't convert \(input.lastPathComponent), so Cheese's built-in renderer was used.")
                        }
                    }
                    try await TimeLimit.run(seconds: 60) {
                        try await renderer.render(input, kind: kind, paper: paper, to: output)
                    }
                } catch is CancellationError {
                    await renderer.close()
                    throw CancellationError()
                } catch {
                    context.fail(input, error)
                }
                context.fileFinished()
            }
            await renderer.close()
        }
    }
}
