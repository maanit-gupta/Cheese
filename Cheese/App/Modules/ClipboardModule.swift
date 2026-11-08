import AppKit
import SwiftData
import os

/// Clipboard history, plus Live Text indexing of the images in it. Off means the pasteboard
/// isn't polled at all; the stored history stays on disk for when it's switched back on.
@MainActor
final class ClipboardModule: CheeseModule {
    let id = ModuleID.clipboard
    private let permissions: any PermissionChecking
    private let permissionPrompter: PermissionPrompter
    /// The view the history popover anchors to: the menu bar icon.
    private let anchorView: () -> NSView?
    private var clipboard: ClipboardController?
    private var liveText: LiveTextIndexer?

    init(permissions: any PermissionChecking, permissionPrompter: PermissionPrompter, anchorView: @escaping () -> NSView?) {
        self.permissions = permissions
        self.permissionPrompter = permissionPrompter
        self.anchorView = anchorView
    }

    var actions: [CheeseAction] {
        [
            // Needs no permission: without Accessibility, pasting from history falls back to copying only.
            CheeseAction(id: .openHistory, title: "Clipboard History", symbol: "doc.on.clipboard", module: id, shortcut: .openHistory) { [weak self] context in
                self?.clipboard?.toggleHistory(anchoredTo: self?.anchorView(), target: context.previousApp)
            },
            // Shown only while a link is on the clipboard. Turning it on cleans that link right away.
            CheeseAction(
                id: .copyCleanLink, title: "Copy clean link automatically", symbol: "link", module: id,
                paletteTitle: "Copy Clean Links Automatically",
                precondition: { [weak self] in
                    guard let clipboard = self?.clipboard else { return false }
                    clipboard.refreshCurrentLink()
                    return clipboard.currentClipboardURL != nil
                },
                isChecked: { [weak self] in self?.clipboard?.copyCleanLinkAutomatically ?? false }
            ) { [weak self] _ in
                self?.toggleCleanLinks()
            },
            CheeseAction(id: .clearHistory, title: "Clear History", symbol: "clear", module: id) { [weak self] _ in
                self?.clipboard?.store.clearHistory()
            },
            CheeseAction(id: .clearAll, title: "Clear All…", symbol: "trash", module: id) { [weak self] _ in
                self?.confirmClearAll()
            },
        ]
    }

    func start() {
        // The store opens on first start, so a Cheese launched with Clipboard off never touches it.
        if clipboard == nil {
            makeClipboard()
        }
        clipboard?.start()
    }

    func stop() {
        clipboard?.stop()
    }

    /// Applies a changed history size right away.
    func enforceRetention() {
        clipboard?.store.enforceRetention()
    }

    private func makeClipboard() {
        let preferences = Preferences()
        let container: ModelContainer
        do {
            container = try ClipStore.makeContainer()
        } catch {
            // Keep the app usable; history just won't survive this launch.
            Logger.app.error("Couldn't open the history store, using memory only: \(error.localizedDescription, privacy: .public)")
            do {
                container = try ClipStore.makeContainer(storeURL: nil)
            } catch {
                Logger.app.fault("Couldn't create an in-memory history store: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let store = ClipStore(container: container, images: ClipImageStorage()) { preferences.historySize }
        clipboard = ClipboardController(
            store: store,
            canPostEvents: { [permissions] in permissions.isGranted(.accessibility) },
            onMissingAccessibility: { [permissionPrompter] in
                permissionPrompter.presentAlert(for: .accessibility, feature: "Pasting from history")
            },
            source: Self.terminalSourceProbe
        )

        // Live Text: OCR history images in the background so search finds the text in them.
        let liveText = LiveTextIndexer(ocr: .live) { [weak store] id, text in
            store?.setRecognizedText(text, for: id)
        }
        self.liveText = liveText
        store.onImageItemAdded = { [weak liveText] id, url in liveText?.enqueue(id, imageURL: url) }
        for item in store.imageItemsAwaitingRecognition {
            liveText.enqueue(item.id, imageURL: item.url)
        }
    }

    /// Copies from terminals and editor terminal panels: the host registry and Accessibility inspector
    /// Terminal Trace uses, so the clipboard can rebuild wrapped links and read a selection xterm.js didn't write.
    private static var terminalSourceProbe: ClipSourceProbe {
        ClipSourceProbe(
            isTerminal: { TerminalHostRegistry.isTerminalHost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) },
            terminalSelection: { TerminalTreeInspector.frontmost()?.selectedText() }
        )
    }

    private func toggleCleanLinks() {
        guard let clipboard else { return }
        let isOn = !clipboard.copyCleanLinkAutomatically
        clipboard.copyCleanLinkAutomatically = isOn
        guard isOn else {
            CheeseToast.show("Links will be copied as they are", systemImage: "link")
            return
        }
        if clipboard.cleanCurrentLink() {
            CheeseToast.show("Link cleaned")
        } else {
            CheeseToast.show("Copied links will be cleaned automatically", systemImage: "link")
        }
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes every item, including pinned ones. It can't be undone."
        alert.addButton(withTitle: "Clear All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clipboard?.store.clearAll()
    }
}
