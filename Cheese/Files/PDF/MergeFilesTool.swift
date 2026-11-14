import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// Merge Files: any mix of PDFs, images, Office documents and HTML, Markdown or text files, in the
/// order set in the panel, into one PDF or one Word document. Replaces Merge PDFs.
struct MergeFilesTool: FileTool {
    enum Format: String, Codable, Sendable, CaseIterable, Identifiable {
        case pdf
        case word

        var id: Self { self }
        var title: String {
            switch self {
            case .pdf: "PDF"
            case .word: "Word (.docx)"
            }
        }

        var fileExtension: String {
            switch self {
            case .pdf: "pdf"
            case .word: "docx"
            }
        }
    }

    struct Options: Codable, Sendable, Equatable {
        var format = Format.pdf
        /// PDF only: an outline entry named after each source file.
        var bookmarks = true
        var pageNumbers = false
        /// PDF: a title page with the file's name before each file. Word: a page break and a Heading 1.
        var dividers = false
    }

    let id = ToolID.mergeFiles
    let ordersInputs = true
    let editsInputList = true
    var defaultOptions: Options { Options() }

    var hint: String? {
        "Office and web files are converted with Cheese's built-in renderers first, with the same limits as their own tools. In Word, PDFs become editable text (equations as pictures), spreadsheets become tables and slides become pictures."
    }

    func optionsView(options: Binding<Options>, inputs: [URL]) -> some View {
        Picker("Save as", selection: options.format) {
            ForEach(Format.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if options.wrappedValue.format == .pdf {
            Toggle("Bookmark each file", isOn: options.bookmarks)
        }
        Toggle("Page numbers", isOn: options.pageNumbers)
        Toggle(options.wrappedValue.format == .pdf ? "Divider page before each file" : "Start each file with its name as a heading", isOn: options.dividers)
    }

    func work(inputs: [URL], options: Options) -> JobWork {
        let natives = Dictionary(uniqueKeysWithValues: [OfficeRenderer.Kind.word, .excel, .powerPoint].map { ($0, OfficeToPDFTool.nativeConverter(for: $0)) })
        return JobWork(tool: id, inputs: inputs) { context in
            guard let first = inputs.first else { return }
            let output = context.outputURL(named: OutputNamer.mergedName(fileCount: inputs.count, extension: options.format.fileExtension), nextTo: first)
            let scratch = FileManager.default.temporaryDirectory.appending(path: "CheeseMerge-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            // Temporary files go whatever happens: done, failed or cancelled.
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                switch options.format {
                case .pdf:
                    try await MergeFilesPDF.merge(inputs, options: options, natives: natives, scratch: scratch, to: output, context: context)
                case .word:
                    try await MergeFilesWord.merge(inputs, options: options, natives: natives, scratch: scratch, to: output, context: context)
                }
            } catch {
                context.discard(output)
                throw error
            }
        }
    }
}

/// Where an image goes in a merged PDF. Pure.
enum MergePageLayout {
    /// Half an inch.
    static let margin: CGFloat = 36

    /// An image sits on a page the size of the one before it (portrait or landscape to match the
    /// image), inside the margin, centered, never enlarged past its own size.
    static func placement(image: CGSize, previousPage: CGSize) -> (page: CGSize, rect: CGRect) {
        let short = min(previousPage.width, previousPage.height)
        let long = max(previousPage.width, previousPage.height)
        let page = image.width > image.height ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        let room = CGSize(width: max(page.width - margin * 2, 1), height: max(page.height - margin * 2, 1))
        let scale = min(1, room.width / max(image.width, 1), room.height / max(image.height, 1))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return (page, CGRect(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2, width: size.width, height: size.height))
    }

    /// The page an image takes when it comes first: A4 or US Letter by locale.
    static var firstPage: CGSize {
        PDFPageSize.localeDefault.portraitSize ?? CGSize(width: 595.28, height: 841.89)
    }
}

/// A source file that couldn't be read: "Couldn't read Budget.xlsx: the file is password-protected."
enum MergeFailure {
    static func wrap(_ error: any Error, file: URL) -> any Error {
        if error is CancellationError { return error }
        let name = file.lastPathComponent
        var reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // "Budget.pdf is password-protected." → "the file is password-protected."
        if reason.hasPrefix(name) {
            reason = "the file" + reason.dropFirst(name.count)
        }
        if let first = reason.first, first.isUppercase, !reason.hasPrefix("PDF"), !reason.hasPrefix("Word"), !reason.hasPrefix("Cheese") {
            reason = first.lowercased() + reason.dropFirst()
        }
        return FileToolError.message("Couldn't read \(name): \(reason)")
    }
}

// MARK: - PDF

enum MergeFilesPDF {
    private struct Bookmark {
        var label: String
        var page: Int
        var point: CGPoint?
        var children: [Bookmark] = []
    }

    static func merge(
        _ inputs: [URL], options: MergeFilesTool.Options, natives: [OfficeRenderer.Kind: NativeConverter?], scratch: URL, to output: URL,
        context: JobContext
    ) async throws {
        let merged = PDFDocument()
        var bookmarks: [Bookmark] = []
        var previousPage = MergePageLayout.firstPage
        let renderer = await OfficeRenderer()
        defer { Task { @MainActor in renderer.close() } }

        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let source: PDFDocument
            do {
                let url = try await pdf(for: input, index: index, previousPage: previousPage, natives: natives, renderer: renderer, scratch: scratch, context: context)
                source = try PDFFiles.open(url)
            } catch {
                throw MergeFailure.wrap(error, file: input)
            }
            let start = merged.pageCount
            if options.dividers, let firstPage = source.page(at: 0) {
                let size = firstPage.bounds(for: .cropBox).size
                if let divider = dividerPage(title: input.lastPathComponent, size: size) {
                    merged.insert(divider, at: merged.pageCount)
                }
            }
            let contentStart = merged.pageCount
            for pageIndex in 0..<source.pageCount {
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
            if let last = merged.page(at: merged.pageCount - 1) {
                let bounds = last.bounds(for: .cropBox)
                previousPage = last.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
            }
            var entry = Bookmark(label: OutputNamer.baseName(of: input), page: start)
            if let outline = source.outlineRoot {
                entry.children = children(of: outline, in: source, offset: contentStart)
            }
            bookmarks.append(entry)
            context.fileFinished()
        }

        try Task.checkCancellation()
        var result = merged
        if options.pageNumbers {
            let plain = scratch.appending(path: "merged.pdf")
            let numbered = scratch.appending(path: "numbered.pdf")
            try PDFFiles.write(merged, to: plain)
            try PageNumbersTool.stamp(plain, to: numbered, options: PageNumbersTool.Options())
            guard let reopened = PDFDocument(url: numbered) else { throw FileToolError.writeFailed(output.lastPathComponent) }
            // PDFKit doesn't save an outline added to a document it opened from this file, so the
            // numbered pages move into a fresh document.
            result = PDFDocument()
            for index in 0..<reopened.pageCount {
                if let page = reopened.page(at: index)?.copy() as? PDFPage {
                    result.insert(page, at: result.pageCount)
                }
            }
        }
        if options.bookmarks {
            let root = PDFOutline()
            for bookmark in bookmarks {
                root.insertChild(outline(bookmark, in: result), at: root.numberOfChildren)
            }
            result.outlineRoot = root
        }
        try PDFFiles.write(result, to: output)
    }

    /// The input as a PDF file: itself, or converted into `scratch` with the renderer its kind needs.
    @MainActor
    private static func pdf(
        for input: URL, index: Int, previousPage: CGSize, natives: [OfficeRenderer.Kind: NativeConverter?], renderer: OfficeRenderer,
        scratch: URL, context: JobContext
    ) async throws -> URL {
        let converted = scratch.appending(path: "\(index).pdf")
        let paper = PDFPageSize.localeDefault.portraitSize ?? MergePageLayout.firstPage
        switch FileKind(url: input) {
        case .pdf:
            return input
        case .image:
            try imagePage(input, previousPage: previousPage, to: converted)
        case .word, .excel, .powerPoint:
            let kind: OfficeRenderer.Kind = switch FileKind(url: input) {
            case .word: .word
            case .excel: .excel
            default: .powerPoint
            }
            try await OfficeToPDFTool.convert(input, kind: kind, paper: paper, native: natives[kind] ?? nil, renderer: renderer, to: converted) { context.note($0) }
        case .html, .markdown, .plainText:
            try await TimeLimit.run(seconds: 60) {
                try await WebRenderer.renderPDF(input, kind: FileKind(url: input), pageSize: .localeDefault, to: converted)
            }
        case .other:
            throw FileToolError.message("Cheese can't merge this kind of file.")
        }
        return converted
    }

    /// One page holding the image, placed by `MergePageLayout`, upright by its EXIF orientation,
    /// and never stored at more than 300 dpi of its placed size.
    static func imagePage(_ input: URL, previousPage: CGSize, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw FileToolError.unreadable(input.lastPathComponent) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let pixels = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let points = CGSize(width: pixels.width * 72 / max(dpi, 1), height: pixels.height * 72 / max(dpi, 1))
        let (page, rect) = MergePageLayout.placement(image: points, previousPage: previousPage)
        let maxPixels = max(rect.width, rect.height) * 300 / 72
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(min(max(pixels.width, pixels.height), max(maxPixels, 1)).rounded(.up)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else {
            throw FileToolError.unreadable(input.lastPathComponent)
        }
        var box = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(output as CFURL, mediaBox: &box, nil) else { throw FileToolError.writeFailed(output.lastPathComponent) }
        pdf.beginPDFPage(nil)
        pdf.interpolationQuality = .high
        pdf.draw(image, in: rect)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    /// A page with just the file's name, centered.
    static func dividerPage(title: String, size: CGSize) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        pdf.beginPDFPage(nil)
        let line = OverlayText.line(title, fontName: "Helvetica-Bold", size: min(28, size.width / 14), color: RGBAColor.black.cgColor)
        OverlayText.draw(line, centeredAt: CGPoint(x: size.width / 2, y: size.height / 2), rotation: 0, in: pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    private static func children(of outline: PDFOutline, in source: PDFDocument, offset: Int) -> [Bookmark] {
        (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let page = child.destination?.page.map { source.index(for: $0) }
            return Bookmark(
                label: child.label ?? "", page: offset + (page ?? 0), point: child.destination?.point,
                children: children(of: child, in: source, offset: offset)
            )
        }
    }

    private static func outline(_ bookmark: Bookmark, in document: PDFDocument) -> PDFOutline {
        let item = PDFOutline()
        item.label = bookmark.label
        if let page = document.page(at: bookmark.page) {
            let bounds = page.bounds(for: .cropBox)
            item.destination = PDFDestination(page: page, at: bookmark.point ?? CGPoint(x: bounds.minX, y: bounds.maxY))
        }
        for child in bookmark.children {
            item.insertChild(outline(child, in: document), at: item.numberOfChildren)
        }
        return item
    }
}

// MARK: - Word

enum MergeFilesWord {
    static func merge(
        _ inputs: [URL], options: MergeFilesTool.Options, natives: [OfficeRenderer.Kind: NativeConverter?], scratch: URL, to output: URL,
        context: JobContext
    ) async throws {
        var documents: [DocxMerger.Document] = []
        let renderer = await OfficeRenderer()
        defer { Task { @MainActor in renderer.close() } }
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            do {
                let data = try await docx(for: input, index: index, natives: natives, renderer: renderer, scratch: scratch, context: context)
                documents.append(DocxMerger.Document(parts: try ZipArchive.read(data), title: input.lastPathComponent))
            } catch {
                throw MergeFailure.wrap(error, file: input)
            }
            context.fileFinished()
        }
        try Task.checkCancellation()
        let parts = try DocxMerger.merge(documents, dividers: options.dividers, pageNumbers: options.pageNumbers)
        try ZipArchive.write(parts).write(to: output, options: .withoutOverwriting)
    }

    /// The input as a Word document.
    @MainActor
    private static func docx(
        for input: URL, index: Int, natives: [OfficeRenderer.Kind: NativeConverter?], renderer: OfficeRenderer, scratch: URL, context: JobContext
    ) async throws -> Data {
        switch FileKind(url: input) {
        case .word:
            let data = try Data(contentsOf: input)
            // A .docx is a ZIP; anything else (an encrypted document is an OLE file) can't be merged.
            guard data.starts(with: [0x50, 0x4B]) else {
                throw FileToolError.message("the file is password-protected or isn't a Word document Cheese can read.")
            }
            return data
        case .pdf:
            // Off the main actor, with cancelling passed on (a detached task doesn't inherit it).
            let conversion = Task.detached { try PDFToDocx.convert(input) }
            return try await withTaskCancellationHandler { try await conversion.value } onCancel: { conversion.cancel() }
        case .image:
            guard let picture = LocalImages.png(at: input) else { throw FileToolError.unreadable(input.lastPathComponent) }
            var builder = DocxBuilder()
            let id = builder.addImage(png: picture.png, size: picture.size)
            builder.append([LayoutBlock(kind: .image(id))], bodySize: 11)
            return try builder.docx()
        case .excel:
            var builder = DocxBuilder()
            for sheet in try SheetJSWriter.readSheets(Data(contentsOf: input)) where !sheet.rows.isEmpty {
                builder.append([LayoutBlock(kind: .heading(level: 1), runs: [LayoutRun(text: sheet.name, fontSize: 20)])], bodySize: 11)
                builder.appendTable(sheet.rows)
            }
            return try builder.docx()
        case .powerPoint:
            let pdf = scratch.appending(path: "\(index).pdf")
            let paper = PDFPageSize.localeDefault.portraitSize ?? MergePageLayout.firstPage
            try await OfficeToPDFTool.convert(input, kind: .powerPoint, paper: paper, native: natives[.powerPoint] ?? nil, renderer: renderer, to: pdf) { context.note($0) }
            return try slidesAsPictures(pdf)
        case .markdown, .html:
            let text = try WebDocument.readText(input)
            let body = FileKind(url: input) == .markdown ? try MarkdownConverter.html(fromMarkdown: text) : text
            return try DocxWriter.docx(fromHTML: HTMLSanitizer.removingRemoteResources(DocxWriter.page(body: body)), baseURL: input.deletingLastPathComponent())
        case .plainText:
            var builder = DocxBuilder()
            let lines = try WebDocument.readText(input).components(separatedBy: .newlines)
            builder.append(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
                LayoutBlock(kind: .paragraph, runs: [LayoutRun(text: line, fontSize: 11)])
            }, bodySize: 11)
            return try builder.docx()
        case .other:
            throw FileToolError.message("Cheese can't merge this kind of file.")
        }
    }

    /// One picture per slide, fitted to the page width, each on its own page.
    private static func slidesAsPictures(_ pdf: URL) throws -> Data {
        guard let document = CGPDFDocument(pdf as CFURL), document.numberOfPages > 0 else { throw FileToolError.emptyDocument }
        var builder = DocxBuilder()
        for number in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: number), let image = PDFRasterizer.render(page, dpi: 150),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            let id = builder.addImage(png: png, size: PDFPageDrawing.uprightSize(of: page))
            builder.append([LayoutBlock(kind: .image(id))], bodySize: 11)
            if number < document.numberOfPages {
                builder.pageBreak()
            }
        }
        return try builder.docx()
    }
}
