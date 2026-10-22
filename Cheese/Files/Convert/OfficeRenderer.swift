import AppKit
import PDFKit
import WebKit

/// Word, Excel and PowerPoint → PDF with the vendored renderers in a hidden, network-blocked web
/// view. One renderer serves a whole job, with a fresh page load per file.
@MainActor
final class OfficeRenderer {
    enum Kind: String, Sendable {
        case word
        case excel
        case powerPoint
    }

    /// Word and PowerPoint lay out in CSS pixels (96 per inch); PDF pages are in points (72 per inch).
    private static let zoom: CGFloat = 0.75
    private var view: LocalWebView?
    private let messages = RenderMessages()

    /// Renders `input` into a PDF at `output`. Excel prints on `paper`, landscape and fitted to width;
    /// Word uses it for documents that don't set their own page size.
    func render(_ input: URL, kind: Kind, paper: CGSize, to output: URL) async throws {
        let data = try Data(contentsOf: input)
        let view = try await prepareView()
        guard let folder = Renderers.folder else { throw FileToolError.message("Cheese's Office renderer is missing. Reinstall Cheese.") }
        view.webView.pageZoom = kind == .excel ? 1 : Self.zoom
        try await view.loadFile(try Renderers.url("office.html"), readAccess: folder)
        if kind == .powerPoint {
            // End on a plain value: evaluateJavaScript fails on results it can't bridge.
            _ = try await view.webView.evaluateJavaScript(try Self.powerPointScript() + "\ntrue;")
        }

        let pages = try await messages.result {
            _ = try await view.webView.callAsyncJavaScript(
                "Cheese.render(kind, data, paper); return true;",
                arguments: [
                    "kind": kind.rawValue,
                    "data": data.base64EncodedString(),
                    "paper": ["width": paper.width, "height": paper.height],
                ],
                contentWorld: .page
            )
        }
        guard !pages.isEmpty else { throw FileToolError.emptyDocument }

        switch kind {
        case .excel:
            try await view.printPDF(to: output, paperSize: paper, margin: 28, landscape: true)
        case .word, .powerPoint:
            let document = PDFDocument()
            for index in pages.indices {
                try Task.checkCancellation()
                for page in try await capture(page: index, in: view) {
                    document.insert(page, at: document.pageCount)
                }
            }
            try PDFFiles.write(document, to: output)
        }
    }

    func close() {
        view?.close()
        view = nil
    }

    private func prepareView() async throws -> LocalWebView {
        if let view {
            return view
        }
        let messages = messages
        let view = try await LocalWebView.make(width: 1200, allowsJavaScript: true) { configuration in
            configuration.userContentController.add(messages, contentWorld: .page, name: "cheese")
        }
        self.view = view
        return view
    }

    /// PDF pages for one rendered page. A Word section longer than its page size (docx-preview
    /// doesn't paginate flowing text) is sliced into page-sized pieces.
    private func capture(page index: Int, in view: LocalWebView) async throws -> [PDFPage] {
        let result = try await view.webView.callAsyncJavaScript("return Cheese.showOnly(index);", arguments: ["index": index], contentWorld: .page)
        guard let rect = result as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
              let width = (rect["width"] as? NSNumber)?.doubleValue, let height = (rect["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { throw FileToolError.message("Page \(index + 1) couldn't be laid out.") }
        let nominal = (rect["pageHeight"] as? NSNumber)?.doubleValue ?? 0
        let sliceHeight = nominal > 0 && height > nominal * 1.02 ? nominal : height

        // The view must contain the whole page for it to be captured.
        let zoom = Self.zoom
        view.webView.setFrameSize(NSSize(width: max(1200, (x + width) * zoom + 20), height: (y + height) * zoom + 20))
        var pages: [PDFPage] = []
        var offset = 0.0
        while offset < height - 1 {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: x * zoom, y: (y + offset) * zoom, width: width * zoom, height: sliceHeight * zoom)
            let data = try await view.webView.pdf(configuration: configuration)
            if let page = PDFDocument(data: data)?.page(at: 0) {
                pages.append(page)
            }
            offset += sliceHeight
        }
        return pages
    }

    /// The vendored pptx-to-html is an ES module importing `jszip`. Run it as a classic script that
    /// uses the already-loaded JSZip global and publishes `pptxToHtml` on `window`.
    nonisolated static func powerPointScript() throws -> String {
        let source = try Renderers.source("pptx-to-html.js")
        let importLine = "import JSZip from \"jszip\";"
        let exportLine = "export { pptxToHtml };"
        guard source.contains(importLine), source.contains(exportLine) else {
            throw FileToolError.message("The PowerPoint renderer isn't the expected version.")
        }
        return source
            .replacing(importLine, with: "const JSZip = window.JSZip;")
            .replacing(exportLine, with: "window.pptxToHtml = pptxToHtml;")
    }
}

/// Receives `{ ok, pages, error }` from office.js and hands it to whoever is waiting.
@MainActor
private final class RenderMessages: NSObject, WKScriptMessageHandler {
    private var continuation: CheckedContinuation<[CGSize], any Error>?

    /// Runs `start` and waits for the page to post its result.
    func result(after start: @escaping @MainActor () async throws -> Void) async throws -> [CGSize] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CGSize], any Error>) in
                self.continuation = continuation
                Task { @MainActor in
                    do {
                        try await start()
                    } catch {
                        self.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<[CGSize], any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        guard body["ok"] as? Bool == true else {
            let reason = body["error"] as? String ?? "unknown error"
            finish(.failure(FileToolError.message("The document couldn't be rendered: \(reason)")))
            return
        }
        let pages = (body["pages"] as? [[String: Any]] ?? []).map { page in
            CGSize(width: (page["width"] as? NSNumber)?.doubleValue ?? 0, height: (page["height"] as? NSNumber)?.doubleValue ?? 0)
        }
        finish(.success(pages))
    }
}
