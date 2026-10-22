import Foundation
import PDFKit
import SwiftUI

/// Merges PDFs in the order set in the panel. Each source becomes a top-level bookmark, with its
/// own bookmarks kept underneath.
struct MergeTool: FileTool {
    let id = ToolID.mergePDFs
    let ordersInputs = true
    var defaultOptions: NoOptions { NoOptions() }

    func optionsView(options: Binding<NoOptions>, inputs: [URL]) -> some View {
        EmptyView()
    }

    func work(inputs: [URL], options: NoOptions) -> JobWork {
        JobWork(tool: id, inputs: inputs) { context in
            let merged = try PDFMerger.merge(inputs) { context.fileFinished() }
            guard let first = inputs.first else { return }
            let output = context.outputURL(for: first, suffix: "merged", extension: "pdf")
            try PDFFiles.write(merged, to: output)
        }
    }
}

enum PDFMerger {
    /// Appends every page of each PDF, in order, calling `didAppend` after each file.
    static func merge(_ inputs: [URL], didAppend: () -> Void = {}) throws -> PDFDocument {
        let output = PDFDocument()
        let root = PDFOutline()
        for input in inputs {
            try Task.checkCancellation()
            let source = try PDFFiles.open(input)
            let start = output.pageCount
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
                output.insert(page, at: output.pageCount)
            }
            let entry = PDFOutline()
            entry.label = OutputNamer.baseName(of: input)
            if let firstPage = output.page(at: start) {
                let bounds = firstPage.bounds(for: .cropBox)
                entry.destination = PDFDestination(page: firstPage, at: CGPoint(x: bounds.minX, y: bounds.maxY))
            }
            if let outline = source.outlineRoot {
                copyChildren(of: outline, into: entry, source: source, output: output, offset: start)
            }
            root.insertChild(entry, at: root.numberOfChildren)
            didAppend()
        }
        output.outlineRoot = root
        return output
    }

    /// Copies bookmarks, pointing each at the same page in the merged document.
    private static func copyChildren(of outline: PDFOutline, into parent: PDFOutline, source: PDFDocument, output: PDFDocument, offset: Int) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            if let destination = child.destination, let page = destination.page {
                let pageIndex = source.index(for: page)
                if let target = output.page(at: offset + pageIndex) {
                    copy.destination = PDFDestination(page: target, at: destination.point)
                }
            }
            copyChildren(of: child, into: copy, source: source, output: output, offset: offset)
            parent.insertChild(copy, at: parent.numberOfChildren)
        }
    }
}
