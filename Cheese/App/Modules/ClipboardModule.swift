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
            }
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
