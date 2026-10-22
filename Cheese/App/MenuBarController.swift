import AppKit
import KeyboardShortcuts

/// Who's showing status text beside the menu bar icon. Listed in the order they're shown.
enum IndicatorSource: CaseIterable {
    case keepAwake
    case files
    case share

    /// Every source's text, in order, joined with " · ": `∞ · 3/10`. Nil when none has any.
    static func joined(_ texts: [IndicatorSource: String]) -> String? {
        let parts = allCases.compactMap { texts[$0] }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Owns the status item. Any click on the icon opens the feature menu; dropping files, images,
/// links or text on it opens the drop hub under the icon.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let statusItem: NSStatusItem
    private let statusMenu: StatusMenu
    private var indicators: [IndicatorSource: String] = [:]
    /// Shows what can be done with a drop; nil when nothing can be dropped.
    private let dropHub: StatusItemDropPanelController?
    /// The payload of the drag hovering over the icon, when the hub can take it.
    private var hoveringPayload: DropPayload?
    /// Clicking the Share indicator reopens the Share panel.
    private let openShare: () -> Void
    /// While the Share panel is showing, the indicator opens the menu like the rest of the icon.
    private let isShareShown: () -> Bool

    /// The view popovers anchor to, so they appear under the menu bar icon.
    var anchorView: NSView? { statusItem.button }

    init(
        statusMenu: StatusMenu,
        dropHub: StatusItemDropPanelController? = nil,
        openShare: @escaping () -> Void = {},
        isShareShown: @escaping () -> Bool = { false }
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusMenu = statusMenu
        self.dropHub = dropHub
        self.openShare = openShare
        self.isShareShown = isShareShown
        super.init()

        statusMenu.menu.delegate = self
        if let button = statusItem.button {
            // Clicks open the menu, except on the Share indicator, which reopens a closed Share panel.
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            // Template image from the asset catalog, so it tints for light/dark menu bars.
            let icon = NSImage(resource: .menuBarIcon)
            icon.accessibilityDescription = "Cheese"
            button.image = icon
            button.toolTip = "Cheese"
            // The status item's window forwards drags to its delegate.
            button.window?.registerForDraggedTypes(StatusItemDropHandler.acceptedTypes)
            button.window?.delegate = self
        }
    }

    /// Short status text beside the icon, like the keep-awake countdown or Files progress.
    /// Nil clears this source's text; with none left the icon shows alone.
    func setIndicator(_ text: String?, for source: IndicatorSource) {
        indicators[source] = text
        guard let button = statusItem.button else { return }
        if let text = IndicatorSource.joined(indicators) {
            statusItem.length = NSStatusItem.variableLength
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
            button.title = text
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, isOnShareIndicator(event, in: sender), !isShareShown() {
            openShare()
            return
        }
        openMenu()
    }

    /// Opens the feature menu under the icon, as a click on it does.
    func openMenu() {
        guard let button = statusItem.button else { return }
        // Attaching the menu only for this click keeps the button's action for the next one.
        statusItem.menu = statusMenu.menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// The Share indicator is the last piece of the title, at the button's trailing edge.
    private func isOnShareIndicator(_ event: NSEvent, in button: NSStatusBarButton) -> Bool {
        guard let share = indicators[.share], let font = button.font else { return false }
        let point = button.convert(event.locationInWindow, from: nil)
        let width = (share as NSString).size(withAttributes: [.font: font]).width + 8
        return point.x >= button.bounds.maxX - width
    }

    // MARK: NSMenuDelegate

    // Modules may have been switched on or off since the menu last opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu.menu {
            statusMenu.rebuild()
        }
    }

    // NSMenu's tracking loop buffers global hotkeys and replays them on close, so pause them while open.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = false
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.isEnabled = true
    }

    // MARK: Dropping on the icon

    /// The icon's frame on screen, which the drop hub hangs under.
    private var iconFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let dropHub, let payload = StatusItemDropHandler.payload(from: sender.draggingPasteboard), dropHub.accepts(payload) else {
            hoveringPayload = nil
            return []
        }
        hoveringPayload = payload
        if let button = statusItem.button {
            StatusItemDropHandler.setHighlighted(true, button)
        }
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hoveringPayload == nil ? [] : .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endHover()
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { endHover() }
        guard let dropHub, let payload = hoveringPayload, let anchor = iconFrame else { return false }
        // Show the hub once the drag session has ended, or it takes the session's last events.
        Task { @MainActor in dropHub.show(payload, below: anchor) }
        return true
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        endHover()
    }

    private func endHover() {
        hoveringPayload = nil
        if let button = statusItem.button {
            StatusItemDropHandler.setHighlighted(false, button)
        }
    }
}
