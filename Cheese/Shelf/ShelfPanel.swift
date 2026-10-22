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
final class ShelfPanelController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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
        model.onAddFiles = { [weak self] in self?.chooseFiles() }
        model.onPaste = { [weak self] in self?.paste() }
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
        model.add(inputs)
        if !store.isEmpty {
            show()
        }
    }

    /// Asks for files and folders to put on the shelf.
    func chooseFiles() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.prompt = "Add to Shelf"
        openPanel.message = "Choose files and folders to put on the shelf."
        // Above the floating shelf, so it isn't hidden behind it.
        openPanel.level = .modalPanel
        NSApp.activate()
        guard openPanel.runModal() == .OK, !openPanel.urls.isEmpty else { return }
        add(openPanel.urls.map(ShelfInput.file))
    }

    /// Adds what's on the clipboard: files, an image, a link or text.
    func paste() {
        let inputs = ShelfDropReader.inputs(from: .general)
        guard !inputs.isEmpty else {
            CheeseToast.show("Nothing on the clipboard to add", systemImage: "doc.on.clipboard")
            return
        }
        add(inputs)
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
        let panel = CheesePanel(rootView: ShelfView(model: model), behavior: behavior) { [weak self] content in
            let host = CheeseDropHostView(content: content, types: ShelfDropReader.acceptedTypes)
            host.onEntered = { self?.dragEntered($0) ?? [] }
            host.onExited = { self?.model.isDropTargeted = false }
            host.onDrop = { self?.drop($0) ?? false }
            return host
        }
        panel.onCancel = { [weak self] in self?.hide() }
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
            let key = ShelfKey(
                keyCode: Int(event.keyCode),
                modifiers: event.modifierFlags,
                characters: event.charactersIgnoringModifiers
            )
            let window = event.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let key else { return false }
                switch key {
                case .quickLook:
                    guard window === self.panel || window === QLPreviewPanel.shared() else { return false }
                    self.toggleQuickLook()
                case .addFiles:
                    guard window === self.panel else { return false }
                    self.chooseFiles()
                case .paste:
                    guard window === self.panel else { return false }
                    self.paste()
                }
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

    // MARK: Dropping onto the shelf (through `CheeseDropHostView`)

    private func dragEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !ShelfDropReader.isFromShelf(sender) else { return [] }
        model.isDropTargeted = true
        panel?.orderFrontRegardless()
        return .copy
    }

    private func drop(_ sender: any NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
        guard !ShelfDropReader.isFromShelf(sender) else { return false }
        let pasteboard = sender.draggingPasteboard
        let inputs = ShelfDropReader.inputs(from: pasteboard)
        if !inputs.isEmpty {
            model.add(inputs)
            return true
        }
        // Photos and some browsers promise files instead of handing them over.
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        receive(promises)
        return !promises.isEmpty
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
                    self?.model.add([.file(url)])
                }
            }
        }
    }
}

/// Reads what was dropped or pasted on the shelf, most specific first: files, then images, then
/// links, then text (plain, or the text of rich text and HTML).
@MainActor
enum ShelfDropReader {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = {
        let promised: [NSPasteboard.PasteboardType] = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        let direct: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string, .rtfd, .rtf, .html]
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
        let links = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter { !$0.isFileURL }
        if let png = imageData(from: pasteboard) {
            // A browser's image drag also carries the image's address, which gives it a name.
            let name = links.first.map(\.lastPathComponent).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
            return [.imageData(png, suggestedName: name)]
        }
        if !links.isEmpty {
            return links.map(ShelfInput.link)
        }
        if let text = text(from: pasteboard) {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme, ["http", "https"].contains(scheme) {
                return [.link(url)]
            }
            return [.text(text)]
        }
        return []
    }

    /// A stored image for dragging out: its file, for Finder and apps that take files, plus its PNG
    /// data for apps that only take images.
    static func pasteboardItem(forImageAt url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let png = try? Data(contentsOf: url) {
            item.setData(png, forType: .png)
        }
        return item
    }

    /// PNG data for an image on the pasteboard: PNG as it is, anything else converted.
    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        guard pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) else { return nil }
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func text(from pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string) {
            return text
        }
        for (type, documentType) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd), (.rtf, .rtf), (.html, .html)] {
            guard let data = pasteboard.data(forType: type),
                  let text = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil).string
            else { continue }
            return text
        }
        return nil
    }
}

/// The shelf's own keys, while it's focused: Space, ⌘O and ⌘V.
enum ShelfKey: Equatable {
    case quickLook
    case addFiles
    case paste

    init?(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        switch (modifiers, characters?.lowercased()) {
        case ([], _) where keyCode == 49: self = .quickLook
        case (.command, "o"): self = .addFiles
        case (.command, "v"): self = .paste
        default: return nil
        }
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
    @ObservationIgnored var onAddFiles: () -> Void = {}
    @ObservationIgnored var onPaste: () -> Void = {}

    init(store: ShelfStore, services: ShelfServices) {
        self.store = store
        self.services = services
    }

    var fileTools: [ToolID] {
        let files = store.fileURLs
        return files.isEmpty ? [] : services.fileTools(files)
    }

    /// Adds new items, animating their cards in.
    @discardableResult
    func add(_ inputs: [ShelfInput]) -> [ShelfItem] {
        withAnimation(DesignTokens.animation(DesignTokens.Duration.gentle, reduceMotion: DesignTokens.reducesMotion)) {
            store.add(inputs)
        }
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
            CheeseDivider()
            Group {
                if model.store.isEmpty {
                    emptyDropZone
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                            ForEach(model.store.items) { item in
                                ShelfItemView(model: model, item: item)
                                    .onAppear { model.loadThumbnail(for: item, scale: displayScale) }
                                    .transition(.scale(scale: 0.85).combined(with: .opacity))
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

    /// Where things land while the shelf is empty: a dashed drop zone with buttons for those who'd
    /// rather not drag.
    private var emptyDropZone: some View {
        HStack(spacing: DesignTokens.Spacing.large) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: DesignTokens.Size.largeSymbol))
                .foregroundStyle(model.isDropTargeted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                Text("Drop files, images, or text here")
                    .font(DesignTokens.Typography.heading)
                Text("They wait here until you drag them somewhere.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignTokens.Spacing.small) {
                    Button("Upload Files…", systemImage: "plus") { model.onAddFiles() }
                        .buttonStyle(.borderedProminent)
                    Button("Paste", systemImage: "doc.on.clipboard") { model.onPaste() }
                        .help("Add what's on the clipboard (⌘V)")
                }
                .controlSize(.small)
                .padding(.top, DesignTokens.Spacing.xxSmall)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .fill(Color.accentColor.opacity(model.isDropTargeted ? DesignTokens.Opacity.hoverTint : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(
                    model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: model.isDropTargeted ? 2 : 1.5, dash: [6, 4])
                )
        )
        .padding(DesignTokens.Spacing.medium)
    }

    private var toolbar: some View {
        CheeseToolbar {
            DragAllHandle(model: model)
            Text(model.store.items.count == 1 ? "1 item" : "\(model.store.items.count) items")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        } trailing: {
            CheeseIconButton(symbol: "plus.circle.fill", help: "Add Files… (⌘O)") { model.onAddFiles() }
            CheeseIconButton(symbol: "doc.on.clipboard", help: "Paste from Clipboard (⌘V)") { model.onPaste() }
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
                            .font(.system(size: DesignTokens.Size.largeSymbol))
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
        case .file:
            guard let url = store.url(for: item) else { return nil }
            writer = url as NSURL
            icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        case .image:
            guard let url = store.url(for: item) else { return nil }
            writer = ShelfDropReader.pasteboardItem(forImageAt: url)
            icon = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
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
