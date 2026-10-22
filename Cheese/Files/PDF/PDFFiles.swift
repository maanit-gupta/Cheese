import Foundation
import PDFKit

/// Opening and saving PDFs for the Files tools.
enum PDFFiles {
    /// Opens a PDF, refusing locked (password-protected) ones with a clear message.
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw FileToolError.unreadable(url.lastPathComponent)
        }
        guard !document.isLocked else {
            throw FileToolError.message("\(url.lastPathComponent) is password-protected.")
        }
        guard document.pageCount > 0 else { throw FileToolError.emptyDocument }
        return document
    }

    static func write(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else {
            throw FileToolError.writeFailed(url.lastPathComponent)
        }
    }

    /// A new document holding copies of `pages` (0-based) of `source`, each turned by the extra rotation.
    static func assemble(_ source: PDFDocument, pages: [(index: Int, rotation: Int)]) -> PDFDocument {
        let output = PDFDocument()
        for (index, rotation) in pages {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + rotation) % 360 + 360) % 360
            output.insert(page, at: output.pageCount)
        }
        return output
    }
}

/// Page counts for the options panel's checks, cached so typing a range doesn't reopen the file.
@MainActor
enum PDFPageCounts {
    private static var cache: [URL: (modified: Date?, count: Int)] = [:]

    static func count(_ url: URL) -> Int? {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = cache[url], cached.modified == modified {
            return cached.count
        }
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        cache[url] = (modified, document.pageCount)
        return document.pageCount
    }
}
