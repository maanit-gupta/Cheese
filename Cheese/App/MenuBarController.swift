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

/// Owns the status item. Any click on the icon opens the feature menu; dropping files on it
/// opens a menu of the tools that apply to them.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let statusItem: NSStatusItem
    private let statusMenu: StatusMenu
    private var indicators: [IndicatorSource: String] = [:]
    /// The menu for dropped files, or nil when they can't be dropped (the Files module is off).
    private let dropMenu: ([URL]) -> NSMenu?
    /// Clicking the Share indicator reopens the Share panel.
    private let openShare: () -> Void
    /// While the Share panel is showing, the indicator opens the menu like the rest of the icon.
    private let isShareShown: () -> Bool

    /// The view popovers anchor to, so they appear under the menu bar icon.
    var anchorView: NSView? { statusItem.button }

    init(
        statusMenu: StatusMenu,
        dropMenu: @escaping ([URL]) -> NSMenu? = { _ in nil },
        openShare: @escaping () -> Void = {},
        isShareShown: @escaping () -> Bool = { false }
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusMenu = statusMenu
        self.dropMenu = dropMenu
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
            button.window?.registerForDraggedTypes([.fileURL])
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

    // MARK: Dropping files on the icon

    private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dropMenu(droppedFiles(sender)) != nil else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        statusItem.button?.isHighlighted == true ? .copy : []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        guard let menu = dropMenu(droppedFiles(sender)) else { return false }
        // Pop the menu once the drag session has ended, or it eats the menu's first click.
        Task { @MainActor [weak self] in
            guard let button = self?.statusItem.button else { return }
            menu.delegate = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        return true
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        statusItem.button?.highlight(false)
    }
}
