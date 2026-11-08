import AppKit
import os

/// Draw on screen: transparent overlays on every display plus the HUD. Drawings are kept in
/// memory while draw mode is off and come back when it's turned on again.
///
/// Whenever another Cheese window takes the keyboard (the command palette, Share, an alert) draw
/// mode yields: drawings stay on screen, but the canvas stops drawing and taking focus until that
/// window goes, then hands the keyboard straight back to the canvas.
///
/// Everyday drawing needs only the mouse and at most one held modifier: the magic pen snaps rough
/// shapes, ⇧ draws straight, ⌘ erases, ⌥ highlights, scrolling sizes the brush, and holding the
/// right button opens a radial menu of tools and colors.
@MainActor
final class DrawModeController {
    /// What draw mode needs from the rest of Cheese, wired up in `App/`.
    struct Services {
        /// Captures a display, including the given Cheese window (the overlay) but no other Cheese window.
        var captureDisplay: (CGDirectDisplayID, CGWindowID) async throws -> CapturedImage
        var openEditor: (CapturedImage) -> Void
        var isScreenRecordingGranted: () -> Bool
        var explainMissingScreenRecording: (_ feature: String) -> Void
        /// Settings → General → "Single-letter tool keys" (on by default).
        var usesLetterKeys: () -> Bool = { Preferences().usesDrawLetterKeys }
    }

    /// Clearing more objects than this asks first.
    static let clearAllConfirmationThreshold = 20
    static let selectTolerance: CGFloat = 6
    static let eraserRadius: CGFloat = 10
    /// Freehand samples closer together than this are merged.
    static let strokeMinimumDistance: CGFloat = 0.75
    /// Holding the pen still this long at the end of a stroke snaps it into a clean shape.
    static let magicPause: Duration = .milliseconds(400)
    /// Pointer movement smaller than this doesn't count as moving during that pause.
    static let pauseTolerance: CGFloat = 3
    /// The radial menu draws after the right button has been held this long; flicks don't wait for it.
    static let radialMenuDelay: Duration = .milliseconds(140)
    /// ⇧ snaps straight lines to multiples of this angle.
    static let straightLineStep = CGFloat.pi / 12
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// The stroke being drawn with the pen or highlighter.
    private struct ActiveInk {
        var page: CanvasPageID
        /// Filtered samples; the raw pointer position is added at the end when drawing.
        var samples: [InkSample]
        var latest: InkSample
        var filter = OneEuroFilter()
        var isHighlighter: Bool
        var style: CanvasStyle
        /// With ⇧ held: where the straight line ends.
        var straightEnd: CGPoint?
        /// The clean shape the magic pen snapped to, if the pen paused.
        var snapped: CanvasItem?
        var pauseAnchor: CGPoint

        var start: CGPoint { samples.first?.point ?? latest.point }

        /// Every sample with the pointer's latest position last, so ink always reaches the cursor.
        var allSamples: [InkSample] {
            guard let last = samples.last, last.point != latest.point else { return samples }
            return samples + [latest]
        }
    }

    private enum Interaction {
        case idle
        case inking(ActiveInk)
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

    /// A right-button press: a flick or, once held, the radial menu.
    private struct RadialGesture {
        var page: CanvasPageID
        var start: CGPoint
        var startTime: TimeInterval
        /// Where the menu is drawn, once it's shown.
        var menuCenter: CGPoint?
    }

    let settings = DrawSettings()
    private(set) var isActive = false
    private(set) var document = CanvasDocument()
    private var history = CanvasHistory()
    private let services: Services
    private var overlays: [CanvasPageID: (window: DrawOverlayWindow, view: CanvasView)] = [:]
    private lazy var hud = DrawHUD(settings: settings, actions: makeHUDActions())
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
    private var modifiers: NSEvent.ModifierFlags = []
    private var pauseTask: Task<Void, Never>?
    private var radial: RadialGesture?
    private var radialTask: Task<Void, Never>?
    private var hotkeyGesture = DrawHotkeyGesture()
    /// While the draw hotkey is held its own modifiers (⌃⌥) are down; they mustn't turn the pen into a highlighter.
    private var isHotkeyHeld = false
    private var widthScroll: CGFloat = 0
    private var colorScroll: CGFloat = 0
    private var isPinchZooming = false
    /// The dot a single click just left, removed again if that click turns out to be a double-click.
    private var lastDot: (id: UUID, page: CanvasPageID)?
    /// Bumped on every enter and exit, so a fade-out that finishes late doesn't hide a fresh session.
    private var transition = 0
    /// Another Cheese window (the palette, Share, an alert) has the keyboard; the canvas waits.
    private(set) var isYielded = false
    /// The window draw mode yielded to.
    private weak var yieldingWindow: NSWindow?
    private var keyWindowObservers: [NSObjectProtocol] = []
    /// Windows raised above the canvas while drawing, with the level each goes back to on exit.
    private var liftedWindows: [LiftedWindow] = []

    private struct LiftedWindow {
        weak var window: NSWindow?
        let level: NSWindow.Level
    }

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
        transition += 1
        // Draw mode always opens ready to draw, even if it was left in pass-through.
        if settings.tool == .passThrough {
            settings.tool = toolBeforePassThrough
        }
        isYielded = false
        yieldingWindow = nil
        rebuildOverlays()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for overlay in overlays.values {
            overlay.view.showsVignette = true
            overlay.window.alphaValue = 0
            overlay.window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.25
            for overlay in overlays.values {
                overlay.window.animator().alphaValue = 1
            }
        }
        hud.show(animated: !reduceMotion)
        applyTool()
        refreshAll()
        syncHistoryState()
        focusCanvasUnderPointer()
        observeScreens()
        observeKeyWindows()
        Logger.draw.info("Draw mode on")
    }

    /// Hides everything but keeps the drawings for next time.
    func exit() {
        guard isActive else { return }
        endTextEditing()
        finishInteraction(constrained: false)
        cancelRadial()
        hotkeyGesture.cancel()
        isHotkeyHeld = false
        selection = nil
        isActive = false
        isPinchZooming = false
        isYielded = false
        yieldingWindow = nil
        stopObservingKeyWindows()
        restoreLiftedWindows()
        transition += 1
        let generation = transition
        screenObserver?.cancel()
        screenObserver = nil
        Task { await zoomStream.stop() }
        for overlay in overlays.values {
            overlay.view.clearTransients()
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let windows = overlays.values.map(\.window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.2
            for window in windows {
                window.animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == generation else { return }
                for window in windows {
                    window.orderOut(nil)
                }
            }
        }
        hud.hide(animated: !reduceMotion)
        NSCursor.arrow.set()
        refreshAll()
        Logger.draw.info("Draw mode off")
    }

    /// The canvas windows, made now if they don't exist yet, so a screen recording can include
    /// drawings made after it starts.
    func canvasWindowsForRecording() -> [NSWindow] {
        rebuildOverlays()
        return overlays.values.map(\.window)
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
                    overlay.window.alphaValue = 1
                    overlay.window.orderFrontRegardless()
                }
                self.hud.keepOnScreen()
                self.applyTool()
                self.refreshAll()
            }
        }
    }

    private func focusCanvasUnderPointer() {
        guard isActive, !isYielded, settings.tool != .passThrough else { return }
        let mouse = NSEvent.mouseLocation
        let overlay = overlays.values.first { $0.window.frame.contains(mouse) } ?? overlays.values.first
        overlay?.window.makeKey()
        if let overlay, overlay.window.firstResponder !== overlay.view, !overlay.view.isEditingText {
            overlay.window.makeFirstResponder(overlay.view)
        }
    }

    // MARK: Sharing the keyboard with other Cheese windows

    /// Follows which Cheese window has the keyboard, so draw mode steps aside for the palette and
    /// other panels and takes the keyboard back as soon as they go.
    private func observeKeyWindows() {
        guard keyWindowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let became = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = (note.object as? NSObject).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        }
        let resigned = center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = (note.object as? NSObject).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated { self?.windowLostKey(window) }
        }
        let closed = center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = (note.object as? NSObject).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated { self?.windowLostKey(window) }
        }
        keyWindowObservers = [became, resigned, closed]
    }

    private func stopObservingKeyWindows() {
        for observer in keyWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyWindowObservers.removeAll()
    }

    /// The canvases and the HUD.
    private func isDrawWindow(_ id: ObjectIdentifier) -> Bool {
        overlays.values.contains { ObjectIdentifier($0.window) == id } || hud.owns(id)
    }

    private func windowBecameKey(_ id: ObjectIdentifier?) {
        guard isActive, let id, !isDrawWindow(id), let window = NSApp.windows.first(where: { ObjectIdentifier($0) == id }) else { return }
        lift(window)
        yieldingWindow = window
        guard !isYielded else { return }
        isYielded = true
        endTextEditing()
        finishInteraction(constrained: false)
        cancelRadial()
        NSCursor.arrow.set()
    }

    /// A window that sits below the canvas (Settings, the shelf, the color panel) would open hidden
    /// under the drawing; it's raised above it until draw mode ends.
    private func lift(_ window: NSWindow) {
        guard window.level.rawValue < DrawLevels.hud.rawValue else { return }
        liftedWindows.append(LiftedWindow(window: window, level: window.level))
        window.level = DrawLevels.panels
    }

    private func restoreLiftedWindows() {
        for lifted in liftedWindows {
            lifted.window?.level = lifted.level
        }
        liftedWindows.removeAll()
    }

    private func windowLostKey(_ id: ObjectIdentifier?) {
        guard isYielded, let id, let yieldingWindow, ObjectIdentifier(yieldingWindow) == id else { return }
        // Wait until the event that closed it has been handled: a click on the canvas that
        // dismissed the palette mustn't also draw (see `shouldDrawOnCanvasClick`).
        Task { @MainActor [weak self] in
            self?.resumeAfterYield()
        }
    }

    private func resumeAfterYield() {
        guard isYielded else { return }
        // Another Cheese window took over, like an action the palette ran.
        if let key = NSApp.keyWindow, !isDrawWindow(ObjectIdentifier(key)) {
            yieldingWindow = key
            return
        }
        isYielded = false
        yieldingWindow = nil
        guard isActive else { return }
        focusCanvasUnderPointer()
        cursor.set()
    }

    /// The canvas was clicked. Returns whether the click should draw: a click that dismissed the
    /// palette only gives the canvas the keyboard back, while a panel that stays up (the shelf)
    /// just loses focus and the click draws as usual.
    func shouldDrawOnCanvasClick() -> Bool {
        guard isYielded else { return true }
        let panelStillShowing = yieldingWindow?.isVisible == true
        isYielded = false
        yieldingWindow = nil
        if !panelStillShowing {
            focusCanvasUnderPointer()
            cursor.set()
        }
        return panelStillShowing
    }

    // MARK: The draw hotkey: tap to toggle, hold for quick ink

    /// The hotkey went down. `time` is in the same clock as event timestamps (system uptime).
    func hotkeyPressed(at time: TimeInterval) {
        switch hotkeyGesture.press(at: time, isActive: isActive, isPassThrough: settings.tool == .passThrough) {
        case .enter:
            enter()
        case .resumeDrawing:
            chooseTool(toolBeforePassThrough)
        case .none:
            break
        }
        isHotkeyHeld = hotkeyGesture.isHeld
    }

    func hotkeyReleased(at time: TimeInterval) {
        isHotkeyHeld = false
        switch hotkeyGesture.release(at: time) {
        case .exit:
            exit()
        case .passThrough:
            guard isActive else { return }
            chooseTool(.passThrough)
        case .stay, .none:
            break
        }
    }

    // MARK: Tools

    /// The modifiers that mean something while drawing; the hotkey's own are ignored while it's held.
    private func effectiveModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var flags = flags.intersection(.deviceIndependentFlagsMask)
        if isHotkeyHeld {
            flags.subtract([.control, .option])
        }
        return flags
    }

    var cursor: NSCursor {
        // Over the palette or another panel, the pointer is a plain arrow, never a brush or hidden.
        if isYielded {
            return .arrow
        }
        if settings.tool.grabsItems, isOverGrabbableItem {
            return .openHand
        }
        let flags = effectiveModifiers(modifiers)
        if settings.tool.allowsModifierErasing, flags.contains(.command) {
            return BrushCursor.cursor(.eraser, diameter: Self.eraserRadius * 2, color: settings.color)
        }
        return switch settings.tool {
        case .pen where flags.contains(.option), .highlighter:
            BrushCursor.cursor(.highlighter, diameter: settings.width * CanvasItem.highlighterWidthFactor, color: settings.color)
        case .pen:
            BrushCursor.cursor(.pen, diameter: settings.width, color: settings.color)
        case .eraser:
            BrushCursor.cursor(.eraser, diameter: Self.eraserRadius * 2, color: settings.color)
        case .select, .passThrough, .spotlight: .arrow
        case .text: .iBeam
        case .laser, .zoom: Self.hiddenCursor
        default: .crosshair
        }
    }

    /// Picks a tool, from the HUD, a letter key or the radial menu. Never opens a popover; closes any that's open.
    func chooseTool(_ tool: DrawTool) {
        endTextEditing()
        finishInteraction(constrained: false)
        closePopover()
        if tool == .zoom, !services.isScreenRecordingGranted() {
            services.explainMissingScreenRecording("The Zoom tool")
            return
        }
        if tool == .passThrough, settings.tool != .passThrough {
            toolBeforePassThrough = settings.tool
        }
        // Only a selection's handles depend on the tool, so the canvas repaints only when there is one.
        let repaints = selection != nil
        if tool != .select {
            selection = nil
        }
        isOverGrabbableItem = false
        settings.tool = tool
        applyTool()
        if repaints {
            refreshAll()
        }
        focusCanvasUnderPointer()
    }

    /// Closes the HUD's popover, if one is open.
    private func closePopover() {
        if settings.openPopover != nil {
            hud.setPopover(nil)
        }
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

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        modifiers = flags
        cursor.set()
    }

    // MARK: Rendering

    func renderState(for page: CanvasPageID) -> CanvasRenderState {
        var state = CanvasRenderState(board: settings.board)
        var floatingIDs: Set<UUID> = []
        var drafts: [CanvasItem] = []
        switch interaction {
        case let .moving(movingPage, _, originals, moved) where movingPage == page && moved:
            floatingIDs = Set(originals.map(\.id))
        case let .resizing(resizingPage, _, original) where resizingPage == page:
            floatingIDs = [original.id]
        case let .shaping(shapePage, start, end, constrained) where shapePage == page:
            drafts += [shapeItem(from: start, to: end, constrained: constrained)].compactMap(\.self)
        default:
            break
        }
        var hiddenID: UUID?
        if let editing, editing.page == page {
            hiddenID = editing.item.id
            // The editor shows the text; a note still needs its paper behind it.
            if case .sticky = editing.item.kind {
                drafts.append(editing.item.withText(""))
            }
        }
        let items = document.items(on: page)
        state.items = items.filter { !floatingIDs.contains($0.id) && $0.id != hiddenID }
        state.floating = items.filter { floatingIDs.contains($0.id) && $0.id != hiddenID } + drafts
        if let selection, selection.page == page {
            let selected = items.filter { selection.ids.contains($0.id) }
            state.selectedBounds = selected.map(\.bounds)
            state.showsHandles = selected.count == 1 && (settings.tool == .select || settings.tool.grabsItems)
        }
        return state
    }

    private func view(_ page: CanvasPageID) -> CanvasView? {
        overlays[page]?.view
    }

    private func refresh(_ page: CanvasPageID) {
        view(page)?.refresh()
    }

    private func refreshAll() {
        for overlay in overlays.values {
            overlay.view.refresh()
        }
    }

    private func syncHistoryState() {
        settings.canUndo = history.canUndo
        settings.canRedo = history.canRedo
    }

    // MARK: Mouse

    func mouseDown(on page: CanvasPageID, at point: CGPoint, event: NSEvent) {
        // The HUD and the radial menu are for picking, never for drawing.
        guard radial == nil, !isOverHUD(point, on: page) else { return }
        // Clicking the canvas closes a popover and draws on: no extra click.
        closePopover()
        let flags = effectiveModifiers(event.modifierFlags)
        modifiers = event.modifierFlags
        if editing != nil {
            endTextEditing()
            // Clicking away from a text box or note only commits it.
            if settings.tool == .text || settings.tool == .sticky || settings.tool == .select || settings.tool.isInk {
                return
            }
        }
        let items = document.items(on: page)
        if settings.tool.allowsModifierErasing, flags.contains(.command) {
            interaction = .erasing(page: page, last: point, removed: [])
            erase(on: page, to: point)
            return
        }
        switch settings.tool {
        case .select:
            selectMouseDown(on: page, at: point, items: items, event: event)
        case .pen, .highlighter:
            if event.clickCount >= 2 {
                textBoxFromDoubleClick(on: page, at: point, items: items)
                return
            }
            beginInk(on: page, at: point, event: event, isHighlighter: settings.tool == .highlighter || flags.contains(.option))
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
            interaction = .shaping(page: page, start: point, end: point, constrained: flags.contains(.shift))
        case .text:
            if let hit = CanvasHitTester.topItem(at: point, in: items, tolerance: Self.selectTolerance), case .text = hit.kind {
                beginEditing(hit, on: page, isNew: false)
            } else {
                beginNewTextBox(on: page, at: point)
            }
        case .sticky:
            if let hit = CanvasHitTester.topItem(at: point, in: items, tolerance: Self.selectTolerance), case .sticky = hit.kind {
                beginEditing(hit, on: page, isNew: false)
            } else {
                let size = CanvasItem.stickySize
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                beginEditing(CanvasItem(kind: .sticky("", rect: rect, color: settings.stickyColor), style: settings.style), on: page, isNew: true)
            }
        case .stamp:
            placeStamp(on: page, at: point, items: items)
        case .laser:
            view(page)?.presenter.addLaserPoint(point, at: CACurrentMediaTime())
        case .passThrough, .spotlight, .zoom:
            break
        }
    }

    /// Whether `point` on `page` lies under the HUD's rail or its open popover.
    private func isOverHUD(_ point: CGPoint, on page: CanvasPageID) -> Bool {
        guard isActive, let view = view(page), let window = view.window else { return false }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        return hud.interactiveFrames.contains { $0.contains(screenPoint) }
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
            refresh(page)
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
        let flags = effectiveModifiers(event.modifierFlags)
        let shift = flags.contains(.shift)
        switch interaction {
        case .idle:
            pointerMoved(on: page, to: point)
        case var .inking(ink):
            continueInk(&ink, at: point, event: event, straight: shift)
            interaction = .inking(ink)
        case let .shaping(page, start, _, _):
            interaction = .shaping(page: page, start: start, end: point, constrained: shift)
            refresh(page)
        case .erasing(let page, _, _):
            erase(on: page, to: point)
        case let .moving(page, start, originals, _):
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            document.replace(originals.map { $0.translated(by: offset) }, on: page)
            interaction = .moving(page: page, start: start, originals: originals, moved: true)
            // The moving items leave the bitmap on the first drag, then draw live above it.
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
        if case var .inking(ink) = interaction {
            ink.latest = InkSample(point: point, pressure: ink.latest.pressure, time: event.timestamp)
            interaction = .inking(ink)
        }
        finishInteraction(constrained: effectiveModifiers(event.modifierFlags).contains(.shift))
    }

    /// Commits whatever the pointer was doing as one undoable step.
    private func finishInteraction(constrained: Bool) {
        let finished = interaction
        interaction = .idle
        switch finished {
        case .idle:
            return
        case let .inking(ink):
            finishInk(ink)
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
            refresh(page)
        case let .resizing(page, _, original):
            if let after = document.item(original.id, on: page), after != original {
                history.record(.transformItems(before: [original], after: [after], page: page))
            }
            refresh(page)
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

    // MARK: Ink

    private func beginInk(on page: CanvasPageID, at point: CGPoint, event: NSEvent, isHighlighter: Bool) {
        if selection != nil {
            selection = nil
            refreshAll()
        }
        var style = settings.style
        style.isNeon = settings.isNeon && !isHighlighter
        let sample = InkSample(point: point, pressure: CGFloat(event.pressure), time: event.timestamp)
        var ink = ActiveInk(page: page, samples: [], latest: sample, isHighlighter: isHighlighter, style: style, pauseAnchor: point)
        ink.samples = [InkSample(point: ink.filter.filter(point, at: sample.time), pressure: sample.pressure, time: sample.time)]
        interaction = .inking(ink)
        // Every sample, not just one per frame: fast strokes keep their shape.
        NSEvent.isMouseCoalescingEnabled = false
        showLiveInk(ink)
        schedulePause(for: ink)
    }

    private func continueInk(_ ink: inout ActiveInk, at point: CGPoint, event: NSEvent, straight: Bool) {
        let sample = InkSample(point: point, pressure: CGFloat(event.pressure), time: event.timestamp)
        ink.latest = sample
        let filtered = ink.filter.filter(point, at: sample.time)
        if let last = ink.samples.last, hypot(filtered.x - last.point.x, filtered.y - last.point.y) >= Self.strokeMinimumDistance {
            ink.samples.append(InkSample(point: filtered, pressure: sample.pressure, time: sample.time))
        }
        ink.straightEnd = straight ? CanvasHitTester.snappedEnd(from: ink.start, to: point, step: Self.straightLineStep) : nil
        if hypot(point.x - ink.pauseAnchor.x, point.y - ink.pauseAnchor.y) > Self.pauseTolerance {
            ink.pauseAnchor = point
            // Moving on after a snap goes back to freehand.
            if ink.snapped != nil {
                ink.snapped = nil
                view(ink.page)?.setSnapPreview(nil)
            }
            schedulePause(for: ink)
        }
        showLiveInk(ink)
    }

    private func inkOptions(_ ink: ActiveInk, pressures: [CGFloat]) -> StrokeBuilder.Options {
        ink.isHighlighter
            ? .highlighter(width: ink.style.width * CanvasItem.highlighterWidthFactor)
            : .pen(width: ink.style.width, simulatesPressure: !StrokeBuilder.hasAnalogPressure(pressures))
    }

    private func showLiveInk(_ ink: ActiveInk) {
        guard let view = view(ink.page) else { return }
        let samples: [InkSample] = if let end = ink.straightEnd {
            [InkSample(point: ink.start, pressure: 0.5, time: 0), InkSample(point: end, pressure: 0.5, time: 0)]
        } else {
            ink.allSamples
        }
        let pressures = samples.map(\.pressure)
        let analog = StrokeBuilder.hasAnalogPressure(pressures)
        var options = inkOptions(ink, pressures: analog ? pressures : [])
        // The end tapers only once the pen lifts; while drawing, the ink stays full width right up
        // to the cursor so it never looks like it's lagging.
        options.taperEnd = 0
        view.setLiveInk(LiveInk(
            points: samples.map(\.point),
            pressures: analog ? pressures : [],
            options: options,
            color: ink.isHighlighter ? ink.style.color.withAlpha(CanvasItem.highlighterAlpha) : ink.style.color,
            isNeon: ink.style.isNeon
        ))
    }

    private func schedulePause(for ink: ActiveInk) {
        pauseTask?.cancel()
        guard !ink.isHighlighter, ink.straightEnd == nil else { return }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.magicPause)
            guard !Task.isCancelled else { return }
            self?.pauseElapsed()
        }
    }

    /// The pen has been held still: if the stroke so far is a rough shape, snap it into a clean one.
    func pauseElapsed() {
        guard case var .inking(ink) = interaction, !ink.isHighlighter, ink.snapped == nil, ink.straightEnd == nil,
              let shape = ShapeRecognizer.recognize(ink.allSamples.map(\.point))
        else { return }
        let item = Self.item(for: shape, style: ink.style)
        ink.snapped = item
        interaction = .inking(ink)
        view(ink.page)?.setSnapPreview(item)
    }

    static func item(for shape: RecognizedShape, style: CanvasStyle) -> CanvasItem {
        let kind: CanvasItem.Kind = switch shape {
        case let .line(from, to): .line(from: from, to: to)
        case let .arrow(from, to): .arrow(from: from, to: to)
        case let .rectangle(rect): .shape(.rectangle, rect: rect)
        case let .ellipse(rect): .shape(.ellipse, rect: rect)
        case let .polygon(points): .polygon(points: points)
        }
        var style = style
        style.isFilled = false
        return CanvasItem(kind: kind, style: style)
    }

    private func finishInk(_ ink: ActiveInk) {
        NSEvent.isMouseCoalescingEnabled = true
        pauseTask?.cancel()
        pauseTask = nil
        let page = ink.page
        view(page)?.setLiveInk(nil)
        view(page)?.setSnapPreview(nil)
        lastDot = nil

        let samples = ink.allSamples
        let item: CanvasItem
        if let end = ink.straightEnd {
            item = ink.isHighlighter
                ? CanvasItem(kind: .stroke(points: [ink.start, end], pressures: [], isHighlighter: true), style: ink.style)
                : CanvasItem(kind: .line(from: ink.start, to: end), style: ink.style)
        } else if let snapped = ink.snapped {
            item = snapped
        } else {
            if !ink.isHighlighter, scratchOut(samples, on: page) {
                return
            }
            let pressures = samples.map(\.pressure)
            item = CanvasItem(
                kind: .stroke(points: samples.map(\.point), pressures: StrokeBuilder.hasAnalogPressure(pressures) ? pressures : [], isHighlighter: ink.isHighlighter),
                style: ink.style
            )
        }
        if settings.isDisappearingInk {
            view(page)?.showDisappearing(item)
            return
        }
        history.perform(.addItem(item, page: page), on: &document)
        if item.geometryBounds.width < 2, item.geometryBounds.height < 2 {
            lastDot = (item.id, page)
        }
        refresh(page)
    }

    /// A fast zig-zag over ink deletes the ink it crosses. Returns whether it did.
    private func scratchOut(_ samples: [InkSample], on page: CanvasPageID) -> Bool {
        guard ShapeRecognizer.isScratchOut(samples) else { return false }
        let items = document.items(on: page)
        var touched: Set<UUID> = []
        for (from, to) in zip(samples, samples.dropFirst()) {
            touched.formUnion(CanvasHitTester.itemsErased(from: from.point, to: to.point, radius: settings.width / 2, in: items))
        }
        guard !touched.isEmpty else { return false }
        let removed = document.indexedItems(withIDs: touched, on: page)
        history.perform(.removeItems(removed, page: page), on: &document)
        refresh(page)
        return true
    }

    /// Double-clicking empty space with the pen starts a text box there; on text, it edits it.
    private func textBoxFromDoubleClick(on page: CanvasPageID, at point: CGPoint, items: [CanvasItem]) {
        // The first click of the pair left a dot; take it back.
        if let dot = lastDot, dot.page == page, case let .addItem(added, addedPage)? = history.undoStack.last,
           added.id == dot.id, addedPage == page {
            history.retract(&document)
            syncHistoryState()
            refresh(page)
        }
        lastDot = nil
        let remaining = document.items(on: page)
        if let hit = CanvasHitTester.topItem(at: point, in: remaining, tolerance: Self.selectTolerance), hit.text != nil {
            beginEditing(hit, on: page, isNew: false)
        } else {
            beginNewTextBox(on: page, at: point)
        }
    }

    // MARK: Stamps

    static func stampSize(forWidth width: CGFloat) -> CGFloat {
        20 + width * 3.2
    }

    private func placeStamp(on page: CanvasPageID, at point: CGPoint, items: [CanvasItem]) {
        let stamp = settings.stampKind.stamp(after: items)
        var style = settings.style
        style.isNeon = false
        let item = CanvasItem(kind: .stamp(stamp, center: point, size: Self.stampSize(forWidth: settings.width)), style: style)
        history.perform(.addItem(item, page: page), on: &document)
        syncHistoryState()
        refresh(page)
    }

    // MARK: Text and sticky notes

    private func beginNewTextBox(on page: CanvasPageID, at point: CGPoint) {
        let size = CanvasRenderer.textSize("", fontSize: settings.fontSize)
        let rect = CGRect(x: point.x, y: point.y - size.height / 2, width: size.width, height: size.height)
        beginEditing(CanvasItem(kind: .text("", rect: rect), style: settings.style), on: page, isNew: true)
    }

    private func beginEditing(_ item: CanvasItem, on page: CanvasPageID, isNew: Bool) {
        editing = TextEditing(page: page, item: item, isNew: isNew)
        guard let view = view(page) else { return }
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

    var isEditingText: Bool { editing != nil }

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

    /// Types `text` into the box being edited. For tests, which have no text view on screen.
    func setEditingText(_ text: String) {
        guard let current = editing else { return }
        editing?.item = current.item.withText(text)
    }

    // MARK: Keyboard

    /// Runs a key through `DrawKeyRouter`. Returns whether the key was used.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: DrawKeyRouter.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let state = DrawKeyRouter.State(
            isEditingText: editing != nil,
            isPassThrough: settings.tool == .passThrough,
            hasSelection: selection != nil,
            isRadialOpen: radial != nil,
            isPopoverOpen: settings.openPopover != nil,
            usesLetterKeys: services.usesLetterKeys()
        )
        guard let command = DrawKeyRouter.route(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: modifiers, state: state
        ) else { return false }
        perform(command)
        return true
    }

    private func perform(_ command: DrawCommand) {
        switch command {
        case let .tool(tool): chooseTool(tool)
        case .togglePassThrough: togglePassThrough()
        case .undo: undo()
        case .redo: redo()
        case .snapshot: snapshot(shiftHeld: false)
        case .deleteSelection: deleteSelection()
        case .closePopover: closePopover()
        case .cancelRadial: cancelRadial()
        case .endTextEditing: endTextEditing()
        case .deselect:
            selection = nil
            refreshAll()
        case .exit: exit()
        case .cycleBoard: cycleBoard()
        case let .adjustWidth(thicker): settings.adjustWidth(thicker: thicker)
        case let .color(index):
            if CanvasColor.presets.indices.contains(index) {
                settings.color = CanvasColor.presets[index]
            }
        }
        if isActive {
            cursor.set()
        }
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

    // MARK: Radial menu

    func radialBegan(on page: CanvasPageID, at point: CGPoint, time: TimeInterval) {
        guard settings.tool != .passThrough, !isOverHUD(point, on: page) else { return }
        endTextEditing()
        finishInteraction(constrained: false)
        cancelRadial()
        radial = RadialGesture(page: page, start: point, startTime: time)
        radialTask = Task { [weak self] in
            try? await Task.sleep(for: Self.radialMenuDelay)
            guard !Task.isCancelled else { return }
            self?.showRadialMenu()
        }
    }

    private func showRadialMenu() {
        guard var radial, let view = view(radial.page) else { return }
        let menu = view.radialMenu
        let center = menu.geometry.clampedCenter(radial.start, in: view.bounds)
        radial.menuCenter = center
        self.radial = radial
        menu.show(at: center, color: settings.color, width: settings.width, scale: view.window?.backingScaleFactor ?? 2)
        NSCursor.arrow.set()
        if let pointer, pointer.page == radial.page {
            radialMoved(on: radial.page, to: pointer.point)
        }
    }

    func radialMoved(on page: CanvasPageID, to point: CGPoint) {
        pointer = (page, point)
        guard let radial, radial.page == page, let center = radial.menuCenter, let menu = view(page)?.radialMenu else { return }
        menu.highlight(menu.geometry.target(at: CGVector(dx: point.x - center.x, dy: point.y - center.y)))
    }

    func radialEnded(on page: CanvasPageID, at point: CGPoint, time: TimeInterval) {
        guard let radial else { return }
        cancelRadial()
        if let center = radial.menuCenter {
            let geometry = view(radial.page)?.radialMenu.geometry ?? RadialMenuGeometry()
            apply(geometry.target(at: CGVector(dx: point.x - center.x, dy: point.y - center.y)))
        } else if let slice = RadialMenuGeometry.flick(
            displacement: CGVector(dx: point.x - radial.start.x, dy: point.y - radial.start.y),
            duration: time - radial.startTime
        ) {
            apply(.slice(slice))
        }
        cursor.set()
    }

    /// A ⌃-click, which macOS treats as a right-click. Not while the draw hotkey (⌃⌥D) is held for
    /// quick ink: its ⌃ is already down.
    func isSecondaryClick(_ event: NSEvent) -> Bool {
        effectiveModifiers(event.modifierFlags).contains(.control) && settings.tool != .passThrough
    }

    private func cancelRadial() {
        radialTask?.cancel()
        radialTask = nil
        if let radial {
            view(radial.page)?.radialMenu.hide()
        }
        radial = nil
    }

    private func apply(_ target: RadialMenuGeometry.Target) {
        switch target {
        case .cancel:
            break
        case let .slice(index):
            guard let slice = RadialSlice(rawValue: index) else { return }
            // Picking Stamps again moves on to the next stamp.
            if slice.tool == .stamp, settings.tool == .stamp {
                settings.stampKind = settings.stampKind.next
            } else {
                chooseTool(slice.tool)
            }
        case let .color(index):
            guard CanvasColor.presets.indices.contains(index) else { return }
            settings.color = CanvasColor.presets[index]
        }
    }

    // MARK: Toolbar commands

    func undo() {
        endTextEditing()
        finishInteraction(constrained: false)
        guard history.undo(&document) != nil else { return }
        selection = nil
        lastDot = nil
        syncHistoryState()
        refreshAll()
    }

    func redo() {
        endTextEditing()
        finishInteraction(constrained: false)
        guard history.redo(&document) != nil else { return }
        selection = nil
        lastDot = nil
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
        lastDot = nil
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

    func toggleDisappearingInk() {
        settings.isDisappearingInk.toggle()
        focusCanvasUnderPointer()
    }

    /// Copies the display under the pointer, drawings included, or opens it in the editor with Shift.
    func snapshot(shiftHeld: Bool) {
        endTextEditing()
        finishInteraction(constrained: false)
        closePopover()
        selection = nil
        refreshAll()
        guard let screen = Screens.underMouse, let displayID = screen.displayID, let overlay = overlays[displayID] else { return }
        guard services.isScreenRecordingGranted() else {
            services.explainMissingScreenRecording("Snapshots of drawings")
            return
        }
        // The vignette only marks draw mode; it isn't part of the picture.
        overlay.view.showsVignette = false
        overlay.view.displayIfNeeded()
        CATransaction.flush()
        let windowID = CGWindowID(overlay.window.windowNumber)
        Task {
            defer {
                if isActive {
                    overlay.view.showsVignette = true
                }
            }
            do {
                let image = try await services.captureDisplay(displayID, windowID)
                if shiftHeld {
                    exit()
                    services.openEditor(image)
                } else {
                    await CaptureDelivery.deliver(image, noun: "Snapshot")
                }
            } catch {
                Logger.draw.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                CheeseToast.show("Snapshot failed: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    private func makeHUDActions() -> HUDActions {
        HUDActions(
            chooseTool: { [weak self] tool in self?.chooseTool(tool) },
            cycleBoard: { [weak self] in self?.cycleBoard() },
            toggleDisappearingInk: { [weak self] in self?.toggleDisappearingInk() },
            undo: { [weak self] in self?.undo() },
            redo: { [weak self] in self?.redo() },
            clearAll: { [weak self] in self?.clearAll() },
            snapshot: { [weak self] shiftHeld in self?.snapshot(shiftHeld: shiftHeld) },
            exit: { [weak self] in self?.exit() }
        )
    }

    // MARK: Scrolling and pinching

    func scrolled(on page: CanvasPageID, at point: CGPoint, delta: CGFloat, precise: Bool, modifiers flags: NSEvent.ModifierFlags) {
        pointer = (page, point)
        // A trackpad sends many small deltas; a wheel sends a notch at a time.
        let units = precise ? delta / 12 : (delta == 0 ? 0 : (delta > 0 ? 1 : -1))
        if radial == nil {
            switch settings.tool {
            case .spotlight:
                let range = DrawSettings.spotlightRadiusRange
                let step = precise ? delta : delta * 8
                settings.spotlightRadius = min(max(settings.spotlightRadius + step, range.lowerBound), range.upperBound)
                updatePresenters()
                return
            case .zoom:
                let range = DrawSettings.zoomRange
                let step = precise ? delta : delta * 8
                settings.zoomFactor = min(max(settings.zoomFactor * (1 + step * 0.01), range.lowerBound), range.upperBound)
                updatePresenters()
                return
            default:
                break
            }
        }
        if effectiveModifiers(flags).contains(.shift), radial == nil {
            colorScroll += units
            while abs(colorScroll) >= 1 {
                settings.cycleColor(forward: colorScroll > 0)
                colorScroll -= colorScroll > 0 ? 1 : -1
            }
        } else {
            widthScroll += units
            while abs(widthScroll) >= 1 {
                settings.adjustWidth(thicker: widthScroll > 0)
                widthScroll -= widthScroll > 0 ? 1 : -1
            }
        }
        if let radial {
            view(radial.page)?.radialMenu.updateBrush(color: settings.color, width: settings.width)
        } else {
            cursor.set()
        }
    }

    /// A trackpad pinch shows the zoom lens around the cursor while it lasts.
    func pinched(on page: CanvasPageID, at point: CGPoint, magnification: CGFloat, phase: NSEvent.Phase) {
        pointer = (page, point)
        if phase.contains(.began) {
            guard services.isScreenRecordingGranted() else {
                services.explainMissingScreenRecording("Pinch to zoom")
                return
            }
            isPinchZooming = true
        }
        guard isPinchZooming else { return }
        let range = DrawSettings.zoomRange
        settings.zoomFactor = min(max(settings.zoomFactor * (1 + magnification), range.lowerBound), range.upperBound)
        if phase.contains(.ended) || phase.contains(.cancelled) {
            isPinchZooming = false
        }
        updatePresenters()
    }

    // MARK: Laser, spotlight and zoom

    private var showsLens: Bool {
        isActive && (settings.tool == .zoom || isPinchZooming)
    }

    func pointerMoved(on page: CanvasPageID, to point: CGPoint) {
        pointer = (page, point)
        // The laser doesn't trail, nor the lens follow, under the palette.
        guard !isYielded else { return }
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
        if settings.tool == .spotlight || showsLens {
            updatePresenters()
        }
    }

    func pointerExited(_ page: CanvasPageID) {
        if pointer?.page == page, showsLens {
            view(page)?.presenter.hideLens()
        }
    }

    /// Where the pointer is right now, in the coordinates of the canvas under it.
    private func currentPointer() -> (page: CanvasPageID, point: CGPoint)? {
        let mouse = NSEvent.mouseLocation
        guard let (page, overlay) = overlays.first(where: { $0.value.window.frame.contains(mouse) }) else { return nil }
        let point = overlay.view.convert(overlay.window.convertPoint(fromScreen: mouse), from: nil)
        return (page, point)
    }

    private func updatePresenters() {
        if pointer == nil, isActive, settings.tool.isPresenter || isPinchZooming {
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
        guard showsLens else {
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
            guard showsLens, let pointer, pointer.page == page else {
                presenter.hideLens()
                continue
            }
            let surface = zoomStream.displayID == page ? zoomStream.surface : nil
            presenter.showLens(center: pointer.point, viewSize: overlay.view.bounds.size, factor: settings.zoomFactor, surface: surface)
        }
    }
}
