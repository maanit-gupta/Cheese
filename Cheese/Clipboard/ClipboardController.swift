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
    private let source: ClipSourceProbe

    /// The app that was frontmost before the panel opened: where pastes go.
    private var targetApp: NSRunningApplication?

    /// The link on the clipboard right now, nil when it holds anything else. Drives the
    /// "Copy clean link automatically" item under Clipboard History.
    private(set) var currentLink: ClipboardLink?
    var currentClipboardURL: URL? { currentLink?.original }
    var currentCleanedURL: URL? { currentLink?.cleaned }

    /// Whether copied links are cleaned as soon as they're copied. Read fresh, so Settings and the menu agree.
    var copyCleanLinkAutomatically: Bool {
        get { Preferences().copyCleanLinkAutomatically }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.copyCleanLinkAutomatically) }
    }

    init(
        store: ClipStore,
        canPostEvents: @escaping () -> Bool,
        onMissingAccessibility: @escaping () -> Void,
        source: ClipSourceProbe = .none
    ) {
        self.store = store
        self.source = source
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
        let monitor = PasteboardMonitor(pasteboard: SystemPasteboard(), source: source) { [weak self] clip in
            self?.record(clip)
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

    /// Adds a new copy to history. With "Copy clean link automatically" on, a link with trackers is
    /// cleaned on the clipboard first and only the clean link is recorded.
    private func record(_ clip: CapturedClip) {
        var clip = clip
        var link = ClipboardLink(clip: clip)
        if let found = link, found.hasTrackers, copyCleanLinkAutomatically, writeLink(found.cleaned) {
            clip = found.cleanedClip
            link = found.afterCleaning
        }
        currentLink = link
        Task { await store.add(clip) }
    }

    /// Re-reads the link on the clipboard, for when it changed without a new copy (Cheese pasted from
    /// history, or the module was off). Concealed items (password managers) never count.
    func refreshCurrentLink() {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !ClipClassifier.isPrivate([types]), let text = pasteboard.string(forType: .string) else {
            currentLink = nil
            return
        }
        currentLink = ClipboardLink(text: text)
    }

    /// Replaces the link on the clipboard with its cleaned form and updates its history item in place.
    /// - Returns: false when there's no link on the clipboard or nothing to clean.
    @discardableResult
    func cleanCurrentLink() -> Bool {
        refreshCurrentLink()
        guard let link = currentLink, link.hasTrackers else { return false }
        let copied = NSPasteboard.general.string(forType: .string)
        guard writeLink(link.cleaned) else { return false }
        currentLink = link.afterCleaning

        // The history item holds the copied text, or the link rebuilt from it (a terminal-wrapped link).
        let cleanedText = link.cleaned.absoluteString
        let hashes = Set([copied, link.original.absoluteString].compactMap { $0 }.map { ClipHasher.hash(text: $0) })
        if let item = store.items.first(where: { hashes.contains($0.contentHash) }) {
            store.updateText(for: item.id, newText: cleanedText)
        } else {
            let clip = link.cleanedClip
            Task { await store.add(clip) }
        }
        return true
    }

    /// Puts `url` on the clipboard as plain text. The monitor skips the write, so it isn't recorded twice.
    private func writeLink(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.absoluteString, forType: .string) else { return false }
        monitor?.ignoreChange(pasteboard.changeCount)
        return true
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
