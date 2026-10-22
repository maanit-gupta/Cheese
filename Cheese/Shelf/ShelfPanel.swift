import AppKit
import QuickLookThumbnailing
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import os

/// What the shelf can hand to other modules, wired by `App/`.
struct ShelfServices {
    /// Files tools that apply to these files; empty when the Files module is off.
    var fileTools: @MainActor ([URL]) -> [ToolID] = { _ in [] }
    var openFileTool: @MainActor (ToolID, [URL]) -> Void = { _, _ in }
    /// Whether Share is on, so the shelf offers Send….
    var isSendAvailable: @MainActor () -> Bool = { false }
    /// Opens the Share panel with these ready to send.
    var send: @MainActor (_ files: [URL], _ texts: [String]) -> Void = { _, _ in }
}

/// The floating shelf: a `CheesePanel` the user can drag anywhere, that remembers where they put it.
/// Things dropped on it are added; things dragged off it and dropped somewhere leave it; it hides
/// once it's empty.
@MainActor
final class ShelfPanelController: NSObject, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let store: ShelfStore
    private let model: ShelfViewModel
    private var panel: CheesePanel?
    private var keyMonitor: Any?
    private var purgeTask: Task<Void, Never>?

    init(store: ShelfStore, services: ShelfServices) {
        self.store = store
        model = ShelfViewModel(store: store, services: services)
        super.init()
        model.onItemsLeft = { [weak self] in self?.itemsLeft() }
        model.onClose = { [weak self] in self?.hide() }
        model.onQuickLook = { [weak self] in self?.toggleQuickLook() }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.present(at: .remembered(key: "shelf", fallback: .nearPointer))
        installKeyMonitor()
    }

    func hide() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        removeKeyMonitor()
        panel?.dismiss()
    }

    func add(_ inputs: [ShelfInput]) {
        store.add(inputs)
        if !store.isEmpty {
            show()
        }
    }

    func clear() {
        store.clear()
        itemsLeft()
    }

    private func makePanel() -> CheesePanel {
        var behavior = CheesePanel.Behavior()
        behavior.dismissesOnOutsideClick = false
        behavior.isMovable = true
        behavior.level = .floating
        let panel = CheesePanel(rootView: ShelfView(model: model), behavior: behavior)
        panel.onCancel = { [weak self] in self?.hide() }
        panel.delegate = self
        panel.registerForDraggedTypes(ShelfDropReader.acceptedTypes)
        return panel
    }

    /// Items were dragged off or cleared: hide when empty, and drop stored copies once nothing can still be reading them.
    private func itemsLeft() {
        if store.isEmpty {
            hide()
        }
        purgeTask?.cancel()
        purgeTask = Task { [store] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            store.purgeOrphans()
        }
    }

    // MARK: Keys: Space for Quick Look

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isSpace = event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, isSpace, event.window === self.panel || event.window === QLPreviewPanel.shared() else { return false }
                self.toggleQuickLook()
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: Quick Look

    private var previewURLs: [URL] {
        let selected = model.selection.isEmpty ? store.items : store.items.filter { model.selection.contains($0.id) }
        return selected.compactMap(store.url(for:))
    }

    private func toggleQuickLook() {
        let preview = QLPreviewPanel.shared()
        guard let preview else { return }
        if preview.isVisible {
            preview.orderOut(nil)
            return
        }
        guard !previewURLs.isEmpty else { return }
        preview.dataSource = self
        preview.delegate = self
        preview.reloadData()
        preview.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        let urls = previewURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    // MARK: Dropping onto the shelf (the panel forwards drags to its delegate)

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !ShelfDropReader.isFromShelf(sender) else { return [] }
        model.isDropTargeted = true
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        model.isDropTargeted ? .copy : []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        model.isDropTargeted = false
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
        guard !ShelfDropReader.isFromShelf(sender) else { return false }
        let pasteboard = sender.draggingPasteboard
        let inputs = ShelfDropReader.inputs(from: pasteboard)
        if !inputs.isEmpty {
            store.add(inputs)
        }
        // Photos and some browsers promise files instead of handing them over.
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if inputs.isEmpty, !promises.isEmpty {
            receive(promises)
        }
        return !inputs.isEmpty || !promises.isEmpty
    }

    private func receive(_ promises: [NSFilePromiseReceiver]) {
        let folder = store.folder.appending(path: "Received/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { [weak self] url, error in
                MainActor.assumeIsolated {
                    if let error {
                        Logger.shelf.error("A promised file didn't arrive: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    self?.store.add([.file(url)])
                }
            }
        }
    }
}

/// Reads what was dropped on the shelf, most specific first: files, then images, then links, then text.
@MainActor
enum ShelfDropReader {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = {
        let promised: [NSPasteboard.PasteboardType] = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        let direct: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]
        return direct + promised
    }()

    static func isFromShelf(_ info: any NSDraggingInfo) -> Bool {
        info.draggingSource is ShelfDragSourceView
    }

    static func inputs(from pasteboard: NSPasteboard) -> [ShelfInput] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            return files.map(ShelfInput.file)
        }
        if let image = NSImage(pasteboard: pasteboard), pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.imageData(png, suggestedName: nil)]
        }
        let links = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter { !$0.isFileURL }
        if !links.isEmpty {
            return links.map(ShelfInput.link)
        }
        if let text = pasteboard.string(forType: .string) {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme, ["http", "https"].contains(scheme) {
                return [.link(url)]
            }
            return [.text(text)]
        }
        return []
    }
}

// MARK: - Model

@MainActor
@Observable
final class ShelfViewModel {
    let store: ShelfStore
    let services: ShelfServices
    var selection: Set<ShelfItem.ID> = []
    var isDropTargeted = false
    var isZipping = false
    var thumbnails: [ShelfItem.ID: NSImage] = [:]
    @ObservationIgnored var onItemsLeft: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onQuickLook: () -> Void = {}

    init(store: ShelfStore, services: ShelfServices) {
        self.store = store
        self.services = services
    }

    var fileTools: [ToolID] {
        let files = store.fileURLs
        return files.isEmpty ? [] : services.fileTools(files)
    }

    func dragEnded(_ ids: [ShelfItem.ID], operation: NSDragOperation) {
        guard ShelfDrag.leavesShelf(after: ShelfDrag.Operations(rawValue: operation.rawValue)) else { return }
        store.remove(ids)
        selection.subtract(ids)
        onItemsLeft()
    }

    func select(_ id: ShelfItem.ID, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func open(_ item: ShelfItem) {
        if let url = store.url(for: item) {
            NSWorkspace.shared.open(url)
        } else if case let .link(url) = item.content {
            NSWorkspace.shared.open(url)
        }
    }

    func remove(_ item: ShelfItem) {
        store.remove([item.id])
        selection.remove(item.id)
        onItemsLeft()
    }

    func clear() {
        store.clear()
        selection.removeAll()
        onItemsLeft()
    }

    func send() {
        services.send(store.fileURLs, store.texts)
    }

    func copyPaths() {
        let urls = store.originalFileURLs
        guard !urls.isEmpty else { return }
        ShelfActions.copyPaths(urls)
        CheeseToast.show(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied", systemImage: "doc.on.doc.fill")
    }

    func zip() {
        let urls = store.fileURLs
        guard !urls.isEmpty, !isZipping else { return }
        isZipping = true
        Task {
            defer { isZipping = false }
            do {
                let zip = try await ShelfActions.zip(urls)
                store.add([.file(zip)])
                CheeseToast.show("Zipped to \(zip.lastPathComponent) in Downloads", systemImage: "doc.zipper")
            } catch {
                Logger.shelf.error("Zipping failed: \(error.localizedDescription, privacy: .public)")
                CheeseToast.show("Couldn't zip: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    func loadThumbnail(for item: ShelfItem, scale: CGFloat) {
        guard thumbnails[item.id] == nil, let url = store.url(for: item) else { return }
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 56, height: 56), scale: scale, representationTypes: .thumbnail
        )
        Task {
            guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
            thumbnails[item.id] = thumbnail.nsImage
        }
    }

    func size(of item: ShelfItem) -> String? {
        guard let url = store.url(for: item),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        else { return nil }
        if values.isDirectory == true { return "Folder" }
        return values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

// MARK: - Views

private struct ShelfView: View {
    @Bindable var model: ShelfViewModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if model.store.isEmpty {
                    CheeseEmptyState(symbol: "tray.and.arrow.down", title: "Drop things here", detail: "Files, images, text and links wait here until you drag them somewhere.")
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                            ForEach(model.store.items) { item in
                                ShelfItemView(model: model, item: item)
                                    .onAppear { model.loadThumbnail(for: item, scale: displayScale) }
                            }
                        }
                        .padding(DesignTokens.Spacing.medium)
                    }
                }
            }
            .frame(height: 132)
        }
        .frame(width: 520)
        .cheesePanelBackground()
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(Color.accentColor, lineWidth: model.isDropTargeted ? 3 : 0)
        )
    }

    private var toolbar: some View {
        CheeseToolbar {
            DragAllHandle(model: model)
            Text(model.store.items.count == 1 ? "1 item" : "\(model.store.items.count) items")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        } trailing: {
            if model.services.isSendAvailable() {
                CheeseIconButton(symbol: "square.and.arrow.up", help: "Send…") { model.send() }
                    .disabled(model.store.isEmpty)
            }
            let tools = model.fileTools
            if !tools.isEmpty {
                Menu {
                    ForEach(ToolApplicability.grouped(tools), id: \.group) { group in
                        Section(group.group.title) {
                            ForEach(group.tools, id: \.self) { tool in
                                Button("\(tool.title)…", systemImage: tool.symbol) {
                                    model.services.openFileTool(tool, model.store.fileURLs)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Files tools")
            }
            CheeseIconButton(symbol: model.isZipping ? "hourglass" : "doc.zipper", help: "Zip to Downloads") { model.zip() }
                .disabled(model.store.fileURLs.isEmpty || model.isZipping)
            CheeseIconButton(symbol: "link", help: "Copy Paths") { model.copyPaths() }
                .disabled(model.store.originalFileURLs.isEmpty)
            CheeseIconButton(symbol: "eye", help: "Quick Look (Space)") { model.onQuickLook() }
                .disabled(model.store.fileURLs.isEmpty)
            CheeseIconButton(symbol: "trash", help: "Clear Shelf", role: .destructive) { model.clear() }
                .disabled(model.store.isEmpty)
            CheeseIconButton(symbol: "xmark", help: "Hide Shelf") { model.onClose() }
        }
    }
}

/// The stack handle: dragging it drags every item at once.
private struct DragAllHandle: View {
    let model: ShelfViewModel

    var body: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 14))
            .frame(width: DesignTokens.Size.iconButton.width, height: DesignTokens.Size.iconButton.height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .overlay {
                ShelfDragSource(model: model, ids: { model.store.items.map(\.id) })
            }
            .help("Drag everything")
            .opacity(model.store.isEmpty ? 0.4 : 1)
    }
}

private struct ShelfItemView: View {
    let model: ShelfViewModel
    let item: ShelfItem

    var body: some View {
        let isSelected = model.selection.contains(item.id)
        let isMissing = model.store.isMissing(item)
        Group {
            if item.isChip {
                chip(isSelected: isSelected)
            } else {
                card(isSelected: isSelected, isMissing: isMissing)
            }
        }
        .overlay {
            ShelfDragSource(model: model, ids: {
                // Dragging a selected item drags the whole selection.
                model.selection.contains(item.id) ? model.store.items.filter { model.selection.contains($0.id) }.map(\.id) : [item.id]
            }, item: item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func card(isSelected: Bool, isMissing: Bool) -> some View {
        CheeseCard(isHighlighted: isSelected, padding: DesignTokens.Spacing.small) {
            VStack(spacing: DesignTokens.Spacing.xxSmall) {
                Group {
                    if let thumbnail = model.thumbnails[item.id] {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Image(systemName: isMissing ? "questionmark.folder" : "doc")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                Text(model.store.name(of: item))
                    .font(DesignTokens.Typography.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                Text(isMissing ? "Missing" : model.size(of: item) ?? " ")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 80)
        }
        .opacity(isMissing ? 0.45 : 1)
    }

    private func chip(isSelected: Bool) -> some View {
        let isLink: Bool = if case .link = item.content { true } else { false }
        return Label(model.store.name(of: item), systemImage: isLink ? "link" : "text.quote")
            .font(DesignTokens.Typography.secondary)
            .lineLimit(2)
            .frame(maxWidth: 160, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.vertical, DesignTokens.Spacing.xSmall)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(DesignTokens.Opacity.activeTint)) : AnyShapeStyle(.quaternary), in: Capsule())
    }
}

// MARK: - Dragging items off the shelf

/// An AppKit view over each card that starts the drag, so the shelf learns when a drop landed.
/// SwiftUI's `onDrag` doesn't report how a drag ended.
private struct ShelfDragSource: NSViewRepresentable {
    let model: ShelfViewModel
    let ids: @MainActor () -> [ShelfItem.ID]
    var item: ShelfItem?

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: ShelfDragSourceView) {
        view.model = model
        view.ids = ids
        view.item = item
    }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    fileprivate var model: ShelfViewModel?
    fileprivate var ids: @MainActor () -> [ShelfItem.ID] = { [] }
    fileprivate var item: ShelfItem?
    private var mouseDownEvent: NSEvent?
    private var draggedIDs: [ShelfItem.ID] = []

    override var mouseDownCanMoveWindow: Bool { false }

    /// The item's right-click menu. Built here because this view sits on top of the card and gets
    /// the click; a SwiftUI context menu underneath never would.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let item else { return nil }
        model.selection = [item.id]
        return ShelfItemMenu.make(for: item, model: model)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard let model, let item else { return }
        if event.clickCount == 2 {
            model.open(item)
        } else {
            model.select(item.id, extending: event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let model else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil
        let ids = ids()
        let items = model.store.items.filter { ids.contains($0.id) }
        let draggingItems = items.compactMap { draggingItem(for: $0, store: model.store) }
        guard !draggingItems.isEmpty else { return }
        draggedIDs = items.map(\.id)
        let session = beginDraggingSession(with: draggingItems, event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    private func draggingItem(for item: ShelfItem, store: ShelfStore) -> NSDraggingItem? {
        let writer: any NSPasteboardWriting
        var icon: NSImage?
        switch item.content {
        case .file, .image:
            guard let url = store.url(for: item) else { return nil }
            writer = url as NSURL
            icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        case let .text(text):
            writer = text as NSString
            icon = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        case let .link(url):
            writer = url as NSURL
            icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        }
        let dragging = NSDraggingItem(pasteboardWriter: writer)
        let frame = NSRect(x: bounds.midX - 24, y: bounds.midY - 24, width: 48, height: 48)
        dragging.setDraggingFrame(frame, contents: icon)
        return dragging
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication, let model else { return context == .withinApplication ? [] : .copy }
        let items = model.store.items.filter { draggedIDs.contains($0.id) }
        return NSDragOperation(rawValue: ShelfDrag.offered(for: items).rawValue)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = draggedIDs
        draggedIDs = []
        model?.dragEnded(ids, operation: operation)
    }
}

/// Open · Show in Finder · Remove from Shelf, for one item.
@MainActor
enum ShelfItemMenu {
    static func make(for item: ShelfItem, model: ShelfViewModel) -> NSMenu {
        let menu = NSMenu()
        let open = ClosureMenuItem(title: "Open") { model.open(item) }
        open.isEnabled = !model.store.isMissing(item)
        menu.autoenablesItems = false
        menu.addItem(open)
        if let url = model.store.url(for: item) {
            menu.addItem(ClosureMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove from Shelf") { model.remove(item) })
        return menu
    }
}
