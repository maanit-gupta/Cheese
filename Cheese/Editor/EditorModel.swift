import AppKit
import Observation
import os

enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case arrow
    case rectangle
    case text
    case highlighter
    case pixelate
    case crop

    var id: Self { self }

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .text: "Text"
        case .highlighter: "Highlighter"
        case .pixelate: "Pixelate"
        case .crop: "Crop"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        case .highlighter: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }
}

/// Editor state: the document with undo history, the current tool, and a rendered preview.
@MainActor
@Observable
final class EditorModel {
    let base: CapturedImage
    private(set) var history = EditHistory()
    /// The base with every committed annotation, uncropped. Refreshed off the main actor after each change.
    private(set) var rendered: CGImage
    var tool: EditorTool = .arrow
    var color: RGBAColor = .red
    /// A text annotation being typed, at a top-left image point.
    var pendingText: (point: CGPoint, string: String)?

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private let saveFolder: () -> URL

    init(image: CapturedImage, saveFolder: @escaping () -> URL = { Preferences().screenshotSaveFolder }) {
        base = image
        rendered = image.image
        self.saveFolder = saveFolder
    }

    var document: EditorDocument { history.current }
    var pixelSize: CGSize { base.pixelSize }

    // Sizes scale with the display the image came from, so marks look the same on Retina and non-Retina.
    var lineWidth: CGFloat { 4 * base.scale }
    var highlighterWidth: CGFloat { 18 * base.scale }
    var fontSize: CGFloat { 20 * base.scale }
    var pixelateBlockSize: CGFloat { 10 * base.scale }

    /// The annotation a drag from `start` to `end` makes with the current tool, for previewing and committing.
    func annotation(from start: CGPoint, to end: CGPoint, path: [CGPoint]) -> Annotation? {
        switch tool {
        case .arrow:
            return .arrow(from: start, to: end, color: color, lineWidth: lineWidth)
        case .rectangle:
            return .rectangle(CanvasGeometry.rect(from: start, to: end, imagePixelSize: pixelSize), color: color, lineWidth: lineWidth)
        case .highlighter:
            return .highlight(points: path, color: color.withAlpha(0.4), lineWidth: highlighterWidth)
        case .pixelate:
            return .pixelate(CanvasGeometry.rect(from: start, to: end, imagePixelSize: pixelSize), blockSize: pixelateBlockSize)
        case .text, .crop:
            return nil
        }
    }

    /// Finishes a drag. Tiny drags (stray clicks) are ignored.
    func finishDrag(from start: CGPoint, to end: CGPoint, path: [CGPoint]) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        switch tool {
        case .text:
            commitPendingText()
            pendingText = (start, "")
        case .crop:
            let rect = CanvasGeometry.rect(from: start, to: end, imagePixelSize: pixelSize)
            guard rect.width >= 8, rect.height >= 8 else { return }
            apply { $0.crop = rect.integral }
        case .highlighter:
            guard let annotation = annotation(from: start, to: end, path: path) else { return }
            apply { $0.annotations.append(annotation) }
        case .arrow, .rectangle, .pixelate:
            guard distance >= 4 * base.scale, let annotation = annotation(from: start, to: end, path: path) else { return }
            apply { $0.annotations.append(annotation) }
        }
    }

    func commitPendingText() {
        guard let pending = pendingText else { return }
        pendingText = nil
        let string = pending.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return }
        apply { $0.annotations.append(.text(string, at: pending.point, color: color, fontSize: fontSize)) }
    }

    func resetCrop() {
        apply { $0.crop = nil }
    }

    func undo() {
        pendingText = nil
        history.undo()
        rerender()
    }

    func redo() {
        history.redo()
        rerender()
    }

    private func apply(_ change: (inout EditorDocument) -> Void) {
        history.apply(change)
        rerender()
    }

    private func rerender() {
        let base = base.image
        let document = document.annotations.isEmpty ? nil : EditorDocument(annotations: document.annotations)
        renderTask?.cancel()
        guard let document else {
            rendered = base
            return
        }
        renderTask = Task {
            let image = await Self.render(base, document: document, applyCrop: false)
            guard !Task.isCancelled, let image else { return }
            rendered = image
        }
    }

    @concurrent
    private static func render(_ base: CGImage, document: EditorDocument, applyCrop: Bool) async -> CGImage? {
        AnnotationRenderer.render(base, document: document, applyCrop: applyCrop)
    }

    /// The finished image: annotations drawn, crop applied.
    func export() async -> CapturedImage? {
        commitPendingText()
        guard let image = await Self.render(base.image, document: document, applyCrop: true) else {
            Logger.editor.error("Rendering the edited image failed")
            return nil
        }
        return CapturedImage(image: image, scale: base.scale)
    }

    func copy() async {
        guard let image = await export() else { return }
        if await ImageExport.copy(image) {
            Toast.show("Copied")
        }
    }

    func save() async {
        guard let image = await export() else { return }
        do {
            let url = try await ImageExport.save(image, in: saveFolder())
            Toast.show("Saved \(url.lastPathComponent)", systemImage: "square.and.arrow.down.fill", action: Toast.Action(title: "Show") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        } catch {
            Logger.editor.error("Saving failed: \(error.localizedDescription, privacy: .public)")
            Toast.show("Couldn't save: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
        }
    }
}
