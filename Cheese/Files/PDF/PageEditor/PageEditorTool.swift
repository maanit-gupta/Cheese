import AppKit
import SwiftUI

/// The page editor: a window per PDF with a thumbnail grid to reorder, rotate, delete and
/// extract pages. Saving writes a `(edited)` copy; the original is never touched.
@MainActor
final class PageEditorTool: NSObject, WindowFileTool, NSWindowDelegate {
    let id = ToolID.editPages
    private var windows: [URL: (window: NSWindow, model: PageEditorModel)] = [:]

    func open(_ files: [URL], run: @escaping @MainActor (JobWork) -> Void) {
        guard let url = files.first else { return }
        NSApp.activate()
        if let existing = windows[url] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let count = PDFPageCounts.count(url), count > 0 else {
            Toast.show("\(url.lastPathComponent) can't be opened", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let model = PageEditorModel(url: url, pageCount: count)
        let view = PageEditorView(model: model, run: run)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = url.lastPathComponent
        window.representedURL = url
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[url] = (window, model)
        model.loadThumbnails()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        for entry in windows.values {
            entry.model.stop()
            entry.window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = windows.values.first(where: { $0.window === sender }), entry.model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close without saving?"
        alert.informativeText = "Your page edits to \(entry.model.url.lastPathComponent) haven't been saved."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let url = windows.first(where: { $0.value.window === window })?.key
        else { return }
        windows[url]?.model.stop()
        windows[url] = nil
    }
}

private struct PageEditorView: View {
    @Bindable var model: PageEditorModel
    let run: @MainActor (JobWork) -> Void
    private static let dragPrefix = "cheese-page:"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { position, page in
                        PageCell(
                            page: page,
                            position: position + 1,
                            thumbnail: model.thumbnails[page.source],
                            isSelected: model.selection.contains(page.id)
                        )
                        .onTapGesture {
                            model.click(page.id, modifiers: NSEvent.modifierFlags)
                        }
                        .draggable(Self.dragPrefix + String(page.id))
                        .dropDestination(for: String.self) { items, _ in
                            return drop(items, before: page.id)
                        }
                    }
                }
                .padding(20)
            }
            .dropDestination(for: String.self) { items, _ in
                return drop(items, before: nil)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button("Rotate Left", systemImage: "rotate.left") { model.rotateSelected(by: -90) }
                .disabled(model.selection.isEmpty)
                .keyboardShortcut("[", modifiers: .command)
            Button("Rotate Right", systemImage: "rotate.right") { model.rotateSelected(by: 90) }
                .disabled(model.selection.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
            Button("Delete", systemImage: "trash") { model.deleteSelected() }
                .disabled(!model.canDelete)
                .keyboardShortcut(.delete, modifiers: [])
            Divider().frame(height: 18)
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .disabled(!model.history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Select All", systemImage: "checkmark.circle") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Spacer()
            Text("\(model.pages.count) pages")
                .foregroundStyle(.secondary)
            Button("Extract Selected", systemImage: "square.and.arrow.up.on.square") {
                if let work = model.extractWork() { run(work) }
            }
            .disabled(model.selection.isEmpty)
            Button("Save", systemImage: "square.and.arrow.down") { run(model.saveWork()) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .labelStyle(.titleAndIcon)
        .padding(10)
    }

    private func drop(_ items: [String], before target: Int?) -> Bool {
        guard let item = items.first, item.hasPrefix(Self.dragPrefix),
              let dragged = Int(item.dropFirst(Self.dragPrefix.count))
        else { return false }
        model.drop(dragged, before: target)
        return true
    }
}

private struct PageCell: View {
    let page: EditorPage
    let position: Int
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 130, height: 160)
            .rotationEffect(.degrees(Double(page.rotation)))
            .shadow(radius: 1.5)
            .padding(6)
            .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            Text("\(position)")
                .font(.caption)
                .foregroundStyle(page.source + 1 == position ? .secondary : .primary)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Page \(position), originally page \(page.source + 1)")
    }
}
