import AppKit
import SwiftUI

/// Shows `HistoryView` in a popover under the menu bar icon and routes panel key presses to the model.
@MainActor
final class HistoryPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model: HistoryViewModel
    private var keyMonitor: Any?
    private var closedAt: ContinuousClock.Instant?

    var isShown: Bool { popover.isShown }

    /// True right after the popover closed. Clicking the menu bar icon closes a transient popover on
    /// mouse-down, before the click's action runs; without this the same click would reopen it.
    var justClosed: Bool {
        closedAt.map { ContinuousClock.now - $0 < .milliseconds(300) } ?? false
    }

    init(model: HistoryViewModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentSize = HistoryView.size
        popover.contentViewController = NSHostingController(rootView: HistoryView(model: model))
        popover.delegate = self

        // A transient popover could close under a drag still in flight; it stays put until the drop.
        model.onDragBegan = { [weak self] in self?.popover.behavior = .applicationDefined }
        model.onDragEnded = { [weak self] dropped in
            guard let self else { return }
            popover.behavior = .transient
            if dropped { close() }
        }
    }

    func show(relativeTo anchor: NSView) {
        model.prepareForDisplay()
        // An LSUIElement app has to activate for the popover to take keyboard focus.
        NSApp.activate()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installKeyMonitor()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = .now
        removeKeyMonitor()
        model.panelClosed()
    }

    // Commands are handled ahead of the search field, so arrows and Return work while typing.
    // While a text item is being edited, the editor gets every key but ⌘E, ⌘Return and Esc.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let modifiers = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let command = HistoryCommand(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    charactersIgnoringModifiers: characters,
                    isEditing: self.model.isEditingText
                )
                return self.handle(command, inWindowNumbered: windowNumber)
            }
            return handled ? nil : event
        }
    }

    private func handle(_ command: HistoryCommand?, inWindowNumbered windowNumber: Int) -> Bool {
        guard let command, popover.isShown,
              windowNumber == popover.contentViewController?.view.window?.windowNumber
        else { return false }
        model.perform(command)
        return true
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
