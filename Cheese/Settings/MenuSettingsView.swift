import AppKit
import SwiftUI

/// Settings → Menu: reorder and hide what the menu bar menu shows. Changes apply at once.
struct MenuSettingsView: View {
    @State private var model: MenuEditorModel
    @State private var confirmsReset = false

    init(context: MenuEditorContext, defaults: UserDefaults = .standard) {
        _model = State(initialValue: MenuEditorModel(context: context, defaults: defaults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            HStack(spacing: DesignTokens.Spacing.large) {
                Picker("Preset", selection: Binding(get: { model.customization.preset }, set: { model.setPreset($0) })) {
                    ForEach(MenuCustomization.Preset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button("Show Menu") { model.context.showMenu() }
                    .help("Open the menu bar menu to see the result")
                Button("Reset to Default…") { confirmsReset = true }
            }

            MenuOutline(model: model)
                .frame(minHeight: 230)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).strokeBorder(.separator))

            HStack(spacing: DesignTokens.Spacing.small) {
                Button {
                    announce(model.moveSelection(by: -1))
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(!model.canMoveSelection(by: -1))
                Button {
                    announce(model.moveSelection(by: 1))
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(!model.canMoveSelection(by: 1))
                Text("Drag to reorder within a menu, or press ⌥⌘↑ and ⌥⌘↓.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            FooterRows(model: model)

            Text("Hidden items keep their keyboard shortcuts and stay in the command palette. To turn a feature off completely, use General → Modules.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .onAppear { model.opened() }
        .confirmationDialog("Reset the menu to Cheese's default?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) { model.reset() }
        } message: {
            Text("Every item comes back, in its original order.")
        }
    }

    private func announce(_ message: String?) {
        guard let message, let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// "Always at the bottom": the footer's hideable items, and the locked ones.
private struct FooterRows: View {
    let model: MenuEditorModel

    private struct Row: Identifiable {
        var id: String
        var title: String
        var detail: String?
        var hideable: Bool
    }

    private var rows: [Row] {
        [
            Row(id: ActionID.clearHistory.rawValue, title: "Clear History", detail: "with ⌥ Clear All…", hideable: true),
            Row(id: "version", title: Brand.versionTitle, detail: "version", hideable: false),
            Row(id: ActionID.checkForUpdates.rawValue, title: "Check for Updates…", detail: "or Install Update", hideable: true),
            Row(id: ActionID.editMenu.rawValue, title: "Edit Menu…", detail: nil, hideable: true),
            Row(id: ActionID.openSettings.rawValue, title: "Settings…", detail: nil, hideable: false),
            Row(id: ActionID.quit.rawValue, title: "Quit Cheese", detail: nil, hideable: false),
        ]
    }

    var body: some View {
        GroupBox("Always at the bottom") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                ForEach(rows) { row in
                    HStack(spacing: DesignTokens.Spacing.small) {
                        if row.hideable {
                            Toggle(isOn: Binding(
                                get: { !model.isHidden(row.id) },
                                set: { _ in
                                    model.toggle(row.id)
                                    // Check for Updates and Install Update are one slot.
                                    if row.id == ActionID.checkForUpdates.rawValue {
                                        model.toggle(ActionID.installUpdate.rawValue)
                                    }
                                }
                            )) {
                                label(row)
                            }
                            .accessibilityLabel("\(row.title), \(model.isHidden(row.id) ? "hidden" : "shown")")
                        } else {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: DesignTokens.Size.rowIcon)
                                .accessibilityHidden(true)
                            label(row)
                                .accessibilityLabel("\(row.title), always shown")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.xSmall)
        }
    }

    private func label(_ row: Row) -> some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            Text(row.title)
            if let detail = row.detail {
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Outline

/// The menu's tree in an `NSOutlineView`: SwiftUI's nested lists don't drag-reorder reliably on
/// macOS 15. Rows drag only within their own parent.
private struct MenuOutline: NSViewRepresentable {
    let model: MenuEditorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = MenuOutlineView()
        outline.headerView = nil
        outline.rowSizeStyle = .medium
        outline.style = .inset
        outline.allowsMultipleSelection = false
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 28
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([Coordinator.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Menu items")
        outline.onMove = { [weak coordinator = context.coordinator] offset in coordinator?.moveSelection(by: offset) }
        outline.onToggle = { [weak coordinator = context.coordinator] in coordinator?.toggleSelection() }
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.reload(rows: model.rows)
    }

    /// Reference boxes, kept per ID, so the outline keeps rows expanded across reloads.
    final class Box {
        var row: MenuEditorRow
        var children: [Box] = []

        init(row: MenuEditorRow) {
            self.row = row
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.maanitgupta.cheese.menu-row")
        let model: MenuEditorModel
        weak var outline: MenuOutlineView?
        private var roots: [Box] = []
        private var boxes: [String: Box] = [:]
        private var lastRows: [MenuEditorRow] = []

        init(model: MenuEditorModel) {
            self.model = model
        }

        func reload(rows: [MenuEditorRow]) {
            guard rows != lastRows || roots.isEmpty else { return }
            lastRows = rows
            func boxes(for rows: [MenuEditorRow]) -> [Box] {
                rows.map { row in
                    let box = self.boxes[row.id] ?? Box(row: row)
                    box.row = row
                    box.children = boxes(for: row.children ?? [])
                    self.boxes[row.id] = box
                    return box
                }
            }
            roots = boxes(for: rows)
            guard let outline else { return }
            let selected = model.selection
            outline.reloadData()
            if let selected, let box = self.boxes[selected] {
                let row = outline.row(forItem: box)
                if row >= 0 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            }
        }

        // Data

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Box)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Box)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Box)?.row.children != nil
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let box = item as? Box else { return nil }
            let cell = outlineView.makeView(withIdentifier: MenuRowCell.identifier, owner: nil) as? MenuRowCell ?? MenuRowCell()
            cell.configure(box.row, toggle: { [weak self] in self?.model.toggle(box.row.id) }, openModules: { [weak self] in self?.model.context.openModules() })
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            model.selection = (outline.item(atRow: outline.selectedRow) as? Box)?.row.id
        }

        // Dragging: only within the same parent.

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let box = item as? Box else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(box.row.id, forType: Self.dragType)
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let dragged = draggedRow(info), index != NSOutlineViewDropOnItemIndex else { return [] }
            let parent = (item as? Box)?.row.id ?? MenuCustomization.root
            return parent == dragged.parent ? .move : []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let dragged = draggedRow(info) else { return false }
            let parent = (item as? Box)?.row.id ?? MenuCustomization.root
            guard parent == dragged.parent else { return false }
            let siblings = MenuEditorTree.childIDs(of: parent, customization: model.customization)
            guard let from = siblings.firstIndex(of: dragged.id) else { return false }
            model.selection = dragged.id
            model.move(dragged.id, in: parent, to: from < index ? index - 1 : index)
            return true
        }

        private func draggedRow(_ info: any NSDraggingInfo) -> MenuEditorRow? {
            guard let id = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType) else { return nil }
            return model.row(id)
        }

        // Keyboard

        func moveSelection(by offset: Int) {
            guard let message = model.moveSelection(by: offset), let outline else { return }
            NSAccessibility.post(element: outline, notification: .announcementRequested, userInfo: [
                .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }

        func toggleSelection() {
            if let id = model.selection {
                model.toggle(id)
            }
        }
    }
}

/// ⌥⌘↑ / ⌥⌘↓ move the selected row; Space shows or hides it.
final class MenuOutlineView: NSOutlineView {
    var onMove: ((Int) -> Void)?
    var onToggle: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains([.option, .command]), event.keyCode == 126 {
            onMove?(-1)
        } else if modifiers.contains([.option, .command]), event.keyCode == 125 {
            onMove?(1)
        } else if modifiers.isEmpty, event.charactersIgnoringModifiers == " " {
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A row: visibility checkbox, symbol, title, "New", "Module off", and the shortcut.
private final class MenuRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MenuRowCell")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "New")
    private let moduleOff = NSButton(title: "Module off", target: nil, action: nil)
    private let shortcut = NSTextField(labelWithString: "")
    private var onToggle: () -> Void = {}
    private var onOpenModules: () -> Void = {}

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.setAccessibilityElement(false)
        symbol.symbolConfiguration = .init(scale: .medium)
        title.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.textColor = .controlAccentColor
        moduleOff.bezelStyle = .inline
        moduleOff.controlSize = .small
        moduleOff.target = self
        moduleOff.action = #selector(openModules)
        moduleOff.toolTip = "Turned off in General → Modules"
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [checkbox, symbol, title, badge, moduleOff, spacer, shortcut])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
        imageView = symbol
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ row: MenuEditorRow, toggle: @escaping () -> Void, openModules: @escaping () -> Void) {
        onToggle = toggle
        onOpenModules = openModules
        checkbox.state = row.isHidden ? .off : .on
        symbol.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        title.stringValue = row.title
        let dimmed = row.isHidden || row.moduleOff
        title.textColor = dimmed ? .secondaryLabelColor : .labelColor
        symbol.contentTintColor = dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        badge.isHidden = !row.isNew
        moduleOff.isHidden = !row.moduleOff
        shortcut.stringValue = row.shortcut ?? ""
        var label = "\(row.title), \(row.isHidden ? "hidden" : "shown")"
        if row.children != nil { label += ", menu" }
        if row.isNew { label += ", new" }
        if row.moduleOff { label += ", module off" }
        setAccessibilityLabel(label)
    }

    @objc private func toggled() {
        onToggle()
    }

    @objc private func openModules() {
        onOpenModules()
    }

    // VoiceOver: Press toggles visibility.
    override func accessibilityPerformPress() -> Bool {
        onToggle()
        return true
    }
}
