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
        model.onBatch = { [weak self] items, mode in self?.pasteBatch(items, mode: mode) }
        model.onClose = { [weak self] in self?.popover.close() }
        model.onEditSaved = { [weak self] item in self?.copyEdit(of: item) }
    }

    /// Puts a live-edited item on the clipboard. The monitor skips the write, so the edit doesn't
    /// come back as a new history entry.
    private func copyEdit(of item: ClipItem) {
        Task {
            if let changeCount = await paster.write(item, plainTextOnly: true) {
                monitor?.ignoreChange(changeCount)
            }
        }
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

    /// Delay between pastes when a batch goes in one item at a time.
    private static let oneByOneDelay = Duration.milliseconds(150)

    /// Pastes or copies several items. `.oneByOne` writes and pastes each in turn, for apps that
    /// take one image per paste. Without Accessibility, the batch is copied and the prompt shown.
    private func pasteBatch(_ items: [ClipItem], mode: ClipBatchMode) {
        let target = targetApp
        Task {
            popover.close()
            let livingTarget = target.flatMap { $0.isTerminated ? nil : $0 }
            if mode == .oneByOne, let livingTarget, canPostEvents() {
                var isFirst = true
                for item in items {
                    if !isFirst { try? await Task.sleep(for: Self.oneByOneDelay) }
                    isFirst = false
                    guard let changeCount = await paster.write(item, plainTextOnly: false) else { continue }
                    monitor?.ignoreChange(changeCount)
                    await paster.paste(into: livingTarget)
                }
                return
            }

            guard let changeCount = paster.writeBatch(items) else { return }
            monitor?.ignoreChange(changeCount)
            guard mode != .copyOnly, let livingTarget else { return }
            guard canPostEvents() else {
                onMissingAccessibility()
                return
            }
            await paster.paste(into: livingTarget)
        }
    }
}
