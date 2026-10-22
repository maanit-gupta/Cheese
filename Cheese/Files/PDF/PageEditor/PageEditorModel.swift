import AppKit
import PDFKit

/// One open page-editor window's state: the page list with undo, the selection and thumbnails.
@MainActor
@Observable
final class PageEditorModel {
    let url: URL
    private(set) var history: UndoHistory<[EditorPage]>
    var selection: Set<Int> = []
    private(set) var thumbnails: [Int: NSImage] = [:]
    /// Edits since the last save.
    private(set) var isDirty = false
    @ObservationIgnored private var anchor: Int?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?

    init(url: URL, pageCount: Int) {
        self.url = url
        history = UndoHistory(PageEditing.initial(pageCount: pageCount))
    }

    var pages: [EditorPage] { history.current }

    // MARK: Selection

    /// Click selects one page, Cmd-click toggles, Shift-click selects the range from the last click.
    func click(_ id: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor {
            selection = PageEditing.range(from: anchor, to: id, in: pages)
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else {
            selection = [id]
        }
        anchor = id
    }

    func selectAll() {
        selection = Set(pages.map(\.id))
    }

    // MARK: Edits

    func rotateSelected(by degrees: Int) {
        apply(PageEditing.rotate(pages, ids: selection, by: degrees))
    }

    /// Keeps at least one page; a PDF can't be empty.
    var canDelete: Bool {
        !selection.isEmpty && selection.count < pages.count
    }

    func deleteSelected() {
        guard canDelete else { return }
        apply(PageEditing.delete(pages, ids: selection))
        selection.removeAll()
    }

    /// Drops a dragged page before `target`. Dragging a selected page moves the whole selection.
    func drop(_ dragged: Int, before target: Int?) {
        let ids = selection.contains(dragged) ? selection : [dragged]
        apply(PageEditing.move(pages, ids: ids, before: target))
    }

    func undo() {
        history.undo()
        isDirty = true
        dropStaleSelection()
    }

    func redo() {
        history.redo()
        isDirty = true
        dropStaleSelection()
    }

    private func apply(_ newPages: [EditorPage]) {
        let before = pages
        history.apply(newPages)
        if pages != before {
            isDirty = true
        }
    }

    private func dropStaleSelection() {
        selection.formIntersection(pages.map(\.id))
    }

    // MARK: Output

    /// Writes the edited document as `Report (edited).pdf`.
    func saveWork() -> JobWork {
        isDirty = false
        return Self.work(url: url, pages: pages, suffix: "edited")
    }

    /// Writes the selected pages, in their current order, as a new PDF.
    func extractWork() -> JobWork? {
        let chosen = pages.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        return Self.work(url: url, pages: chosen, suffix: PageRangeFormatter.label(chosen.map { $0.source + 1 }))
    }

    private static func work(url: URL, pages: [EditorPage], suffix: String) -> JobWork {
        let layout = pages.map { (index: $0.source, rotation: $0.rotation) }
        return JobWork(tool: .editPages, inputs: [url]) { context in
            let document = try PDFFiles.open(url)
            let output = context.outputURL(for: url, suffix: suffix, extension: "pdf")
            try PDFFiles.write(PDFFiles.assemble(document, pages: layout), to: output)
            context.fileFinished()
        }
    }

    // MARK: Thumbnails

    /// Renders page thumbnails in the background, a few at a time.
    func loadThumbnails(size: CGSize = CGSize(width: 220, height: 280)) {
        guard thumbnailTask == nil else { return }
        let url = url
        thumbnailTask = Task { [weak self] in
            let stream = AsyncStream<(Int, CGImage)> { continuation in
                let worker = Task.detached(priority: .utility) {
                    guard let document = PDFDocument(url: url) else {
                        continuation.finish()
                        return
                    }
                    for index in 0..<document.pageCount {
                        guard !Task.isCancelled else { break }
                        let image = document.page(at: index)?.thumbnail(of: size, for: .cropBox)
                        if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            continuation.yield((index, cgImage))
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in worker.cancel() }
            }
            for await (index, image) in stream {
                self?.thumbnails[index] = NSImage(cgImage: image, size: .zero)
            }
        }
    }

    func stop() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }
}
