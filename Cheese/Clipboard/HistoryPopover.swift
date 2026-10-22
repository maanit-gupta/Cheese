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
    }

    // Commands are handled ahead of the search field, so arrows and Return work while typing.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let command = HistoryCommand(
                keyCode: Int(event.keyCode),
                modifiers: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                self?.handle(command, inWindowNumbered: windowNumber) ?? false
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
