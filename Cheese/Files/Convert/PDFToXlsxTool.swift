import Foundation
import PDFKit
import SwiftUI

/// PDF → Excel: tables found from word positions, numbers and dates as real cells. One sheet per
/// page, or per table when a page has several. Scanned pages go through Vision OCR.
struct PDFToXlsxTool: FileTool {
    let id = ToolID.pdfToExcel
    var defaultOptions: NoOptions { NoOptions() }
    var hint: String? { PDFConversionLimits.hint }

    func optionsView(options: Binding<NoOptions>, inputs: [URL]) -> some View {
        EmptyView()
    }

    func work(inputs: [URL], options: NoOptions) -> JobWork {
        .perFile(tool: id, inputs: inputs) { input, context in
            let data = try PDFToXlsx.convert(input, locale: .current)
            let output = context.outputURL(for: input, suffix: nil, extension: "xlsx")
            try data.write(to: output, options: .withoutOverwriting)
        }
    }
}

enum PDFToXlsx {
    static func convert(_ input: URL, locale: Locale) throws -> Data {
        let document = try PDFFiles.open(input)
        var sheets: [SheetJSWriter.Sheet] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let words = PDFTextExtractor.hasText(page) ? PDFTextExtractor.words(on: page) : try ScannedPageReader.words(on: page)
            for plan in TableDetector.sheets(forPage: index + 1, words: words) {
                sheets.append(SheetJSWriter.Sheet(name: plan.name, rows: plan.rows.map { $0.map { CellValueParser.parse($0, locale: locale) } }))
            }
        }
        guard !sheets.isEmpty else {
            throw FileToolError.message("\(input.lastPathComponent) has no text to put in a spreadsheet.")
        }
        return try SheetJSWriter.workbook(sheets)
    }
}
