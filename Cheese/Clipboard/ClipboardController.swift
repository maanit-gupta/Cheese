import AppKit
import os

/// Ties the clipboard pieces together: monitoring, the history panel and the paste flow.
@MainActor
final class ClipboardController {
    let store: ClipStore
    private let paster: Paster
    private let model: HistoryViewModel
    private let popover: HistoryPopover
    private var monitor: PasteboardMonitor?
    private let canPostEvents: () -> Bool
    private let onMissingAccessibility: () -> Void

    /// The app that was frontmost before the panel opened: where pastes go.
    private var targetApp: NSRunningApplication?

    init(
        store: ClipStore,
        canPostEvents: @escaping () -> Bool,
        onMissingAccessibility: @escaping () -> Void
    ) {
        self.store = store
        self.canPostEvents = canPostEvents
        self.onMissingAccessibility = onMissingAccessibility
        paster = Paster(images: store.images)
        model = HistoryViewModel(store: store)
        popover = HistoryPopover(model: model)

        model.onPaste = { [weak self] item, plainText in self?.paste(item, plainText: plainText) }
        model.onClose = { [weak self] in self?.popover.close() }
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = PasteboardMonitor(pasteboard: SystemPasteboard()) { [weak self] clip in
            guard let self else { return }
            Task { await self.store.add(clip) }
        }
        self.monitor = monitor
        monitor.start()
        store.enforceRetention()
        Task { await store.removeOrphanedImages() }
    }

    /// Stops recording copies and closes the panel. Copies made while stopped are never recorded.
    func stop() {
        monitor?.stop()
        monitor = nil
        popover.close()
    }

    /// Opens or closes the history panel. `target` is the app pastes go to.
    func toggleHistory(anchoredTo anchor: NSView?, target: NSRunningApplication?) {
        if popover.isShown {
            popover.close()
            return
        }
        guard !popover.justClosed else { return }
        guard let anchor else {
            Logger.clipboard.error("No menu bar icon to anchor the history panel to")
            return
        }
        // Record the target before activating Cheese, which takes the front.
        targetApp = target
        popover.show(relativeTo: anchor)
    }

    private func paste(_ item: ClipItem, plainText: Bool) {
        let id = item.id
        let target = targetApp
        Task {
            if let changeCount = await paster.write(item, plainTextOnly: plainText) {
                monitor?.ignoreChange(changeCount)
            }
            store.touch(id)
            popover.close()

            guard let target, !target.isTerminated else { return }
            guard canPostEvents() else {
                // Copy-only fallback: the item is on the pasteboard, ready for Cmd+V.
                onMissingAccessibility()
                return
            }
            await paster.paste(into: target)
        }
    }
}
