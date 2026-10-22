import AppKit
import os

/// Draw on screen: transparent overlays on every display plus the toolbar. Drawings are kept in
/// memory while draw mode is off and come back when it's turned on again.
@MainActor
final class DrawModeController {
    /// What draw mode needs from the rest of Cheese, wired up in `App/`.
    struct Services {
        /// Captures a display, including the given Cheese window (the overlay) but no other Cheese window.
        var captureDisplay: (CGDirectDisplayID, CGWindowID) async throws -> CapturedImage
        var openEditor: (CapturedImage) -> Void
        var isScreenRecordingGranted: () -> Bool
        var explainMissingScreenRecording: (_ feature: String) -> Void
    }

    /// Clearing more objects than this asks first.
    static let clearAllConfirmationThreshold = 20
    static let selectTolerance: CGFloat = 6
    static let eraserRadius: CGFloat = 10
    /// Freehand points closer together than this are merged.
    static let strokeMinimumDistance: CGFloat = 0.75
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    private enum Interaction {
        case idle
        case drawing(page: CanvasPageID, points: [CGPoint])
        case shaping(page: CanvasPageID, start: CGPoint, end: CGPoint, constrained: Bool)
        case erasing(page: CanvasPageID, last: CGPoint, removed: [IndexedItem])
        case moving(page: CanvasPageID, start: CGPoint, originals: [CanvasItem], moved: Bool)
        case resizing(page: CanvasPageID, handle: CanvasHitTester.Handle, original: CanvasItem)
    }

    private struct Selection {
        var page: CanvasPageID
        var ids: Set<UUID>
    }

    private struct TextEditing {
        var page: CanvasPageID
        var item: CanvasItem
        /// Not in the document yet; added when editing ends.
        var isNew: Bool
    }

    let settings = DrawSettings()
    private(set) var isActive = false
    private(set) var document = CanvasDocument()
    private var history = CanvasHistory()
    private let services: Services
    private var overlays: [CanvasPageID: (window: DrawOverlayWindow, view: CanvasView)] = [:]
    private lazy var toolbar = ToolbarPanel(settings: settings, actions: makeToolbarActions())
    private var interaction = Interaction.idle
    private var selection: Selection?
    private var editing: TextEditing?
    private var toolBeforePassThrough = DrawTool.pen
    private var pointer: (page: CanvasPageID, point: CGPoint)?
    /// With a shape tool, whether the pointer is over an item it would grab.
    private var isOverGrabbableItem = false
    private var screenObserver: Task<Void, Never>?
    private let zoomStream = ZoomStream()
    /// The draft shape's ID stays the same while it's dragged out.
    private var draftID = UUID()

    init(services: Services) {
        self.services = services
        zoomStream.onFrame = { [weak self] in self?.updateLens() }
    }

    // MARK: Entering and exiting

    func toggle() {
        isActive ? exit() : enter()
    }

    func enter() {
        guard !isActive else { return }
        isActive = true
        rebuildOverlays()
        for overlay in overlays.values {
            overlay.window.orderFrontRegardless()
        }
        if let screen = Screens.underMouse {
            toolbar.show(on: screen)
        }
        applyTool()
        refreshAll()
        syncHistoryState()
        focusCanvasUnderPointer()
        observeScreens()
        Logger.draw.info("Draw mode on")
    }

    /// Hides everything but keeps the drawings for next time.
    func exit() {
        guard isActive else { return }
        endTextEditing()
        finishInteraction(constrained: false)
        selection = nil
        isActive = false
        screenObserver?.cancel()
        screenObserver = nil
        Task { await zoomStream.stop() }
        for overlay in overlays.values {
            overlay.view.presenter.hideAll()
            overlay.view.setLaserAnimating(false)
            overlay.window.orderOut(nil)
        }
        toolbar.hide()
        NSCursor.arrow.set()
        Logger.draw.info("Draw mode off")
    }

    /// Exits and forgets every drawing: the module was switched off.
    func reset() {
        exit()
        document.removeAll()
        history = CanvasHistory()
        syncHistoryState()
        for overlay in overlays.values {
            overlay.window.close()
        }
        overlays.removeAll()
    }

    private func rebuildOverlays() {
        var seen: Set<CanvasPageID> = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            seen.insert(displayID)
            if let existing = overlays[displayID] {
                existing.window.setFrame(screen.frame, display: true)
                continue
            }
            let window = DrawOverlayWindow(screen: screen, displayID: displayID)
            let view = CanvasView(frame: CGRect(origin: .zero, size: screen.frame.size), page: displayID, controller: self)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            overlays[displayID] = (window, view)
        }
        for (page, overlay) in overlays where !seen.contains(page) {
            overlay.window.close()
            overlays[page] = nil
        }
    }

    private func observeScreens() {
        screenObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                guard let self, self.isActive else { continue }
                self.rebuildOverlays()
                for overlay in self.overlays.values {
                    overlay.window.orderFrontRegardless()
                }
                self.applyTool()
                self.refreshAll()
            }
        }
    }

    private func focusCanvasUnderPointer() {
        guard isActive, settings.tool != .passThrough else { return }
        let mouse = NSEvent.mouseLocation
        let overlay = overlays.values.first { $0.window.frame.contains(mouse) } ?? overlays.values.first
        overlay?.window.makeKey()
        if let overlay, overlay.window.firstResponder !== overlay.view, !overlay.view.isEditingText {
            overlay.window.makeFirstResponder(overlay.view)
        }
    }

    // MARK: Tools

    var cursor: NSCursor {
        if settings.tool.grabsItems, isOverGrabbableItem {
            return .openHand
        }
        return switch settings.tool {
        case .select, .passThrough, .spotlight: .arrow
        case .text: .iBeam
        case .laser, .zoom: Self.hiddenCursor
        default: .crosshair
        }
    }

    /// Picks a tool. From the toolbar, picking the current tool again toggles its options flyout.
    func chooseTool(_ tool: DrawTool, fromToolbar: Bool = false) {
        endTextEditing()
        finishInteraction(constrained: false)
        if tool == .zoom, !services.isScreenRecordingGranted() {
            services.explainMissingScreenRecording("The Zoom tool")
            return
        }
        if fromToolbar {
            settings.isFlyoutOpen = settings.tool == tool ? !settings.isFlyoutOpen : tool.hasOptions
        } else {
            settings.isFlyoutOpen = false
        }
        if tool == .passThrough, settings.tool != .passThrough {
            toolBeforePassThrough = settings.tool
        }
        if tool != .select {
            selection = nil
        }
        isOverGrabbableItem = false
        settings.tool = tool
        applyTool()
        refreshAll()
        focusCanvasUnderPointer()
    }

    private func togglePassThrough() {
        chooseTool(settings.tool == .passThrough ? toolBeforePassThrough : .passThrough)
    }

    private func applyTool() {
        let passThrough = settings.tool == .passThrough
        for overlay in overlays.values {
            overlay.window.ignoresMouseEvents = passThrough
            overlay.view.setLaserAnimating(isActive && settings.tool == .laser)
            if settings.tool != .laser {
                overlay.view.presenter.clearLaser()
            }
        }
        updatePresenters()
        cursor.set()
    }

    // MARK: Rendering

    func renderState(for page: CanvasPageID) -> CanvasRenderState {
        var state = CanvasRenderState(items: document.items(on: page), board: settings.board)
        if case let .shaping(shapePage, start, end, constrained) = interaction, shapePage == page {
            state.draft = shapeItem(from: start, to: end, constrained: constrained)
        }
        if let editing, editing.page == page {
            state.hiddenItemID = editing.item.id
            if editing.isNew {
                state.draft = editing.item
            }
        }
        if let selection, selection.page == page {
            let selected = state.items.filter { selection.ids.contains($0.id) }
            state.selectedBounds = selected.map(\.bounds)
            state.showsHandles = selected.count == 1 && (settings.tool == .select || settings.tool.grabsItems)
        }
        return state
    }

    private func view(_ page: CanvasPageID) -> CanvasView? {
        overlays[page]?.view
    }

    private func refresh(_ page: CanvasPageID) {
        view(page)?.needsDisplay = true
    }

    private func refreshAll() {
        for overlay in overlays.values {
            overlay.view.needsDisplay = true
        }
    }

    private func syncHistoryState() {
        settings.canUndo = history.canUndo
        settings.canRedo = history.canRedo
    }

    // MARK: Mouse

    func mouseDown(on page: CanvasPageID, at point: CGPoint, event: NSEvent) {
        if editing != nil {
            endTextEditing()
            // Clicking away from a text box or note only commits it.
            if settings.tool == .text || settings.tool == .sticky || settings.tool == .select {
                return
            }
        }
        let items = document.items(on: page)
        switch settings.tool {
        case .select:
            selectMouseDown(on: page, at: point, items: items, event: event)
        case .pen, .highlighter:
            interaction = .drawing(page: page, points: [point])
            view(page)?.setLiveStroke([point], style: settings.style, isHighlighter: settings.tool == .highlighter)
        case .eraser:
            interaction = .erasing(page: page, last: point, removed: [])
            erase(on: page, to: point)
        case .rectangle, .ellipse, .line, .arrow:
            if grabbableItem(at: point, on: page, items: items) {
                selectMouseDown(on: page, at: point, items: items, event: event, purpose: .grab)
                return
            }
            if selection != nil {
                selection = nil
                refreshAll()
            }
            draftID = UUID()
            interaction = .shaping(page: page, start: point, end: point, constrained: event.modifierFlags.contains(.shift))
        case .text:
            if let hit = CanvasHitTester.topItem(at: point, in: items, tolerance: Self.selectTolerance), case .text = hit.kind {
                beginEditing(hit, on: page, isNew: false)
            } else {
                let size = CanvasRenderer.textSize("", fontSize: settings.fontSize)
                let rect = CGRect(x: point.x, y: point.y - size.height / 2, width: size.width, height: size.height)
                beginEditing(CanvasItem(kind: .text("", rect: rect), style: settings.style), on: page, isNew: true)
            }
        case .sticky:
            if let hit = CanvasHitTester.topItem(at: point, in: items, tolerance: Self.selectTolerance), case .sticky = hit.kind {
                beginEditing(hit, on: page, isNew: false)
            } else {
                let size = CanvasItem.stickySize
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                beginEditing(CanvasItem(kind: .sticky("", rect: rect, color: settings.stickyColor), style: settings.style), on: page, isNew: true)
            }
        case .laser:
            view(page)?.presenter.addLaserPoint(point, at: CACurrentMediaTime())
        case .passThrough, .spotlight, .zoom:
            break
        }
    }

    /// The resize handle under `point` when exactly one item is selected on `page`.
    private func selectedHandle(at point: CGPoint, on page: CanvasPageID) -> (handle: CanvasHitTester.Handle, item: CanvasItem)? {
        guard let selection, selection.page == page, selection.ids.count == 1, let id = selection.ids.first,
              let item = document.item(id, on: page),
              let handle = CanvasHitTester.handle(at: point, of: item.bounds.insetBy(dx: -4, dy: -4), radius: CanvasView.handleSize)
        else { return nil }
        return (handle, item)
    }

    /// Whether a shape tool pressed at `point` grabs an item (or the selected item's handle) rather than drawing.
    private func grabbableItem(at point: CGPoint, on page: CanvasPageID, items: [CanvasItem]) -> Bool {
        selectedHandle(at: point, on: page) != nil
            || CanvasHitTester.topItem(at: point, in: items, tolerance: Self.selectTolerance, purpose: .grab) != nil
    }

    private func selectMouseDown(on page: CanvasPageID, at point: CGPoint, items: [CanvasItem], event: NSEvent, purpose: CanvasHitTester.Purpose = .select) {
        let shift = event.modifierFlags.contains(.shift)
        if let grabbed = selectedHandle(at: point, on: page) {
            interaction = .resizing(page: page, handle: grabbed.handle, original: grabbed.item)
            return
        }
        guard let hit = CanvasHitTester.topItem(at: point, in: items, tolerance: Self.selectTolerance, purpose: purpose) else {
            if !shift {
                selection = nil
            }
            refreshAll()
            return
        }
        if event.clickCount >= 2, hit.text != nil {
            selection = nil
            beginEditing(hit, on: page, isNew: false)
            return
        }
        var ids = selection?.page == page ? selection?.ids ?? [] : []
        if shift {
            if ids.contains(hit.id) {
                ids.remove(hit.id)
            } else {
                ids.insert(hit.id)
            }
            selection = ids.isEmpty ? nil : Selection(page: page, ids: ids)
            refreshAll()
            return
        }
        if !ids.contains(hit.id) {
            ids = [hit.id]
        }
        selection = Selection(page: page, ids: ids)
        interaction = .moving(page: page, start: point, originals: items.filter { ids.contains($0.id) }, moved: false)
        refreshAll()
    }

    func mouseDragged(on page: CanvasPageID, at point: CGPoint, event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch interaction {
        case .idle:
            pointerMoved(on: page, to: point)
        case .drawing(let page, var points):
            points.append(point)
            interaction = .drawing(page: page, points: points)
            view(page)?.setLiveStroke(points, style: settings.style, isHighlighter: settings.tool == .highlighter)
        case let .shaping(page, start, _, _):
            interaction = .shaping(page: page, start: start, end: point, constrained: shift)
            refresh(page)
        case .erasing(let page, _, _):
            erase(on: page, to: point)
        case let .moving(page, start, originals, _):
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            document.replace(originals.map { $0.translated(by: offset) }, on: page)
            interaction = .moving(page: page, start: start, originals: originals, moved: true)
            refresh(page)
        case let .resizing(page, handle, original):
            // Text keeps its proportions, since its font scales with height.
            let isText = if case .text = original.kind { true } else { false }
            let keepAspect = shift || isText
            let target = CanvasHitTester.resized(original.bounds, dragging: handle, to: point, keepAspect: keepAspect)
            document.replace([original.resized(from: original.bounds, to: target)], on: page)
            refresh(page)
        }
    }

    func mouseUp(on page: CanvasPageID, at point: CGPoint, event: NSEvent) {
        finishInteraction(constrained: event.modifierFlags.contains(.shift))
    }

    /// Commits whatever the pointer was doing as one undoable step.
    private func finishInteraction(constrained: Bool) {
        let finished = interaction
        interaction = .idle
        switch finished {
        case .idle:
            return
        case let .drawing(page, points):
            view(page)?.setLiveStroke(nil, style: settings.style, isHighlighter: false)
            let filtered = StrokeSmoother.filtered(points, minimumDistance: Self.strokeMinimumDistance)
            guard !filtered.isEmpty else { break }
            let item = CanvasItem(kind: .stroke(points: filtered, isHighlighter: settings.tool == .highlighter), style: settings.style)
            history.perform(.addItem(item, page: page), on: &document)
            refresh(page)
        case let .shaping(page, start, end, wasConstrained):
            guard hypot(end.x - start.x, end.y - start.y) >= 3,
                  let item = shapeItem(from: start, to: end, constrained: constrained || wasConstrained)
            else {
                refresh(page)
                break
            }
            history.perform(.addItem(CanvasItem(kind: item.kind, style: item.style), page: page), on: &document)
            refresh(page)
        case let .erasing(page, _, removed):
            if !removed.isEmpty {
                history.record(.removeItems(removed, page: page))
            }
        case let .moving(page, _, originals, moved):
            guard moved else { break }
            let after = originals.compactMap { document.item($0.id, on: page) }
            history.record(.transformItems(before: originals, after: after, page: page))
        case let .resizing(page, _, original):
            if let after = document.item(original.id, on: page), after != original {
                history.record(.transformItems(before: [original], after: [after], page: page))
            }
        }
        syncHistoryState()
    }

    private func shapeItem(from start: CGPoint, to end: CGPoint, constrained: Bool) -> CanvasItem? {
        let kind: CanvasItem.Kind
        switch settings.tool {
        case .rectangle:
            kind = .shape(.rectangle, rect: CanvasHitTester.shapeRect(from: start, to: end, constrained: constrained))
        case .ellipse:
            kind = .shape(.ellipse, rect: CanvasHitTester.shapeRect(from: start, to: end, constrained: constrained))
        case .line:
            kind = .line(from: start, to: constrained ? CanvasHitTester.snappedEnd(from: start, to: end) : end)
        case .arrow:
            kind = .arrow(from: start, to: constrained ? CanvasHitTester.snappedEnd(from: start, to: end) : end)
        default:
            return nil
        }
        return CanvasItem(id: draftID, kind: kind, style: settings.style)
    }

    private func erase(on page: CanvasPageID, to point: CGPoint) {
        guard case .erasing(_, let last, var removed) = interaction else { return }
        let touched = CanvasHitTester.itemsErased(from: last, to: point, radius: Self.eraserRadius, in: document.items(on: page))
        if !touched.isEmpty {
            removed += document.remove(touched, on: page)
            refresh(page)
        }
        interaction = .erasing(page: page, last: point, removed: removed)
    }

    // MARK: Text and sticky notes

    private func beginEditing(_ item: CanvasItem, on page: CanvasPageID, isNew: Bool) {
        guard let view = view(page) else { return }
        editing = TextEditing(page: page, item: item, isNew: isNew)
        switch item.kind {
        case let .text(text, rect):
            view.beginTextEditing(text: text, frame: rect, fontSize: item.style.fontSize, color: item.style.color, isSticky: false)
        case let .sticky(text, rect, _):
            view.beginTextEditing(text: text, frame: rect, fontSize: item.style.fontSize, color: item.style.color, isSticky: true)
        default:
            editing = nil
            return
        }
        refresh(page)
    }

    /// Commits the text being edited. Empty text boxes are dropped; notes stay even when empty.
    func endTextEditing() {
        guard let editing else { return }
        self.editing = nil
        let text = view(editing.page)?.endTextEditingView() ?? editing.item.text ?? ""
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let updated: CanvasItem
        switch editing.item.kind {
        case let .text(_, rect):
            let size = CanvasRenderer.textSize(text, fontSize: editing.item.style.fontSize)
            updated = editing.item.withText(text, rect: CGRect(origin: rect.origin, size: size))
        case .sticky:
            updated = editing.item.withText(text)
        default:
            return
        }
        let isText = if case .text = updated.kind { true } else { false }

        if editing.isNew {
            if !(isText && isBlank) {
                history.perform(.addItem(updated, page: editing.page), on: &document)
            }
        } else if isText && isBlank {
            let removed = document.indexedItems(withIDs: [updated.id], on: editing.page)
            history.perform(.removeItems(removed, page: editing.page), on: &document)
        } else if updated != editing.item {
            history.perform(.editText(before: editing.item, after: updated, page: editing.page), on: &document)
        }
        syncHistoryState()
        refresh(editing.page)
        focusCanvasUnderPointer()
    }

    // MARK: Keyboard

    /// Single-letter tool keys and the rest. Returns whether the key was used.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers ?? ""

        if event.keyCode == 53 {
            if editing != nil {
                endTextEditing()
            } else {
                exit()
            }
            return true
        }
        if flags.contains(.command) {
            switch characters.lowercased() {
            case "z":
                flags.contains(.shift) ? redo() : undo()
                return true
            case "s" where flags.contains(.shift):
                snapshot(shiftHeld: false)
                return true
            default:
                return false
            }
        }
        guard editing == nil, flags.isDisjoint(with: [.control, .option, .command]),
              characters.count == 1, let character = characters.first
        else { return false }

        // In pass-through only M (back to drawing) works.
        if settings.tool == .passThrough {
            guard DrawTool.forKey(character) == .passThrough else { return false }
            togglePassThrough()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return true
        }
        if let tool = DrawTool.forKey(character) {
            tool == .passThrough ? togglePassThrough() : chooseTool(tool)
            return true
        }
        switch character {
        case "b", "B":
            cycleBoard()
        case "[":
            settings.adjustWidth(thicker: false)
        case "]":
            settings.adjustWidth(thicker: true)
        case "1"..."9":
            if let digit = character.wholeNumberValue {
                settings.color = CanvasColor.presets[digit - 1]
            }
        default:
            return false
        }
        return true
    }

    private func deleteSelection() {
        guard let selection else { return }
        self.selection = nil
        let removed = document.indexedItems(withIDs: selection.ids, on: selection.page)
        guard !removed.isEmpty else { return }
        history.perform(.removeItems(removed, page: selection.page), on: &document)
        syncHistoryState()
        refresh(selection.page)
    }

    // MARK: Toolbar commands

    func undo() {
        endTextEditing()
        finishInteraction(constrained: false)
        guard history.undo(&document) != nil else { return }
        selection = nil
        syncHistoryState()
        refreshAll()
    }

    func redo() {
        endTextEditing()
        finishInteraction(constrained: false)
        guard history.redo(&document) != nil else { return }
        selection = nil
        syncHistoryState()
        refreshAll()
    }

    func clearAll() {
        endTextEditing()
        finishInteraction(constrained: false)
        guard !document.isEmpty else { return }
        if document.itemCount > Self.clearAllConfirmationThreshold, !confirmClearAll() {
            focusCanvasUnderPointer()
            return
        }
        history.perform(.clearAll(previous: document), on: &document)
        selection = nil
        syncHistoryState()
        refreshAll()
        focusCanvasUnderPointer()
    }

    private func confirmClearAll() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Clear all \(document.itemCount) drawings?"
        alert.informativeText = "You can undo this with ⌘Z."
        alert.addButton(withTitle: "Clear All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func cycleBoard() {
        settings.board = settings.board.next
        refreshAll()
    }

    /// Copies the display under the pointer, drawings included, or opens it in the editor with Shift.
    func snapshot(shiftHeld: Bool) {
        endTextEditing()
        finishInteraction(constrained: false)
        selection = nil
        refreshAll()
        guard let screen = Screens.underMouse, let displayID = screen.displayID, let overlay = overlays[displayID] else { return }
        guard services.isScreenRecordingGranted() else {
            services.explainMissingScreenRecording("Snapshots of drawings")
            return
        }
        overlay.view.displayIfNeeded()
        let windowID = CGWindowID(overlay.window.windowNumber)
        Task {
            do {
                let image = try await services.captureDisplay(displayID, windowID)
                if shiftHeld {
                    exit()
                    services.openEditor(image)
                } else if await ImageExport.copy(image) {
                    Toast.show("Snapshot copied", systemImage: "camera.fill")
                }
            } catch {
                Logger.draw.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                Toast.show("Snapshot failed: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    private func makeToolbarActions() -> ToolbarActions {
        ToolbarActions(
            chooseTool: { [weak self] tool in self?.chooseTool(tool, fromToolbar: true) },
            cycleBoard: { [weak self] in self?.cycleBoard() },
            undo: { [weak self] in self?.undo() },
            redo: { [weak self] in self?.redo() },
            clearAll: { [weak self] in self?.clearAll() },
            snapshot: { [weak self] shiftHeld in self?.snapshot(shiftHeld: shiftHeld) },
            exit: { [weak self] in self?.exit() },
            returnFocus: { [weak self] in self?.focusCanvasUnderPointer() }
        )
    }

    // MARK: Laser, spotlight and zoom

    func pointerMoved(on page: CanvasPageID, to point: CGPoint) {
        pointer = (page, point)
        if settings.tool.grabsItems {
            let overItem = grabbableItem(at: point, on: page, items: document.items(on: page))
            if overItem != isOverGrabbableItem {
                isOverGrabbableItem = overItem
                cursor.set()
            }
        }
        if settings.tool == .laser {
            view(page)?.presenter.addLaserPoint(point, at: CACurrentMediaTime())
        }
        if settings.tool == .spotlight || settings.tool == .zoom {
            updatePresenters()
        }
    }

    func pointerExited(_ page: CanvasPageID) {
        if pointer?.page == page, settings.tool == .zoom {
            view(page)?.presenter.hideLens()
        }
    }

    func scrolled(on page: CanvasPageID, at point: CGPoint, deltaY: CGFloat, precise: Bool) {
        let step = precise ? deltaY : deltaY * 8
        switch settings.tool {
        case .spotlight:
            let range = DrawSettings.spotlightRadiusRange
            settings.spotlightRadius = min(max(settings.spotlightRadius + step, range.lowerBound), range.upperBound)
        case .zoom:
            let range = DrawSettings.zoomRange
            settings.zoomFactor = min(max(settings.zoomFactor * (1 + step * 0.01), range.lowerBound), range.upperBound)
        default:
            return
        }
        pointer = (page, point)
        updatePresenters()
    }

    /// Where the pointer is right now, in the coordinates of the canvas under it.
    private func currentPointer() -> (page: CanvasPageID, point: CGPoint)? {
        let mouse = NSEvent.mouseLocation
        guard let (page, overlay) = overlays.first(where: { $0.value.window.frame.contains(mouse) }) else { return nil }
        let point = overlay.view.convert(overlay.window.convertPoint(fromScreen: mouse), from: nil)
        return (page, point)
    }

    private func updatePresenters() {
        if pointer == nil, isActive, settings.tool.isPresenter {
            pointer = currentPointer()
        }
        for (page, overlay) in overlays {
            let presenter = overlay.view.presenter
            let here = pointer?.page == page ? pointer?.point : nil
            if isActive, settings.tool == .spotlight {
                presenter.showSpotlight(center: here, radius: settings.spotlightRadius, bounds: overlay.view.bounds)
            } else {
                presenter.hideSpotlight()
            }
        }
        updateLens()
        guard isActive, settings.tool == .zoom else {
            if zoomStream.displayID != nil {
                Task { await zoomStream.stop() }
            }
            return
        }
        let page = pointer?.page ?? Screens.underMouse?.displayID
        if let page, zoomStream.displayID != page {
            Task { await zoomStream.start(displayID: page) }
        }
    }

    private func updateLens() {
        for (page, overlay) in overlays {
            let presenter = overlay.view.presenter
            guard isActive, settings.tool == .zoom, let pointer, pointer.page == page else {
                presenter.hideLens()
                continue
            }
            let surface = zoomStream.displayID == page ? zoomStream.surface : nil
            presenter.showLens(center: pointer.point, viewSize: overlay.view.bounds.size, factor: settings.zoomFactor, surface: surface)
        }
    }
}
