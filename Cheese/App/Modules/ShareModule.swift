import AppKit
import UniformTypeIdentifiers
import os

/// Cheese Share: send and receive files, text and links with phones and computers nearby, through a
/// browser page or LocalSend. Nothing listens until the Share panel opens.
@MainActor
final class ShareModule: CheeseModule {
    let id = ModuleID.share
    private let setIndicator: (Bool) -> Void
    private let openMenu: () -> Void
    private let prompt = ReceivePrompt()
    private var service: ShareService?
    private var panel: SharePanelController?
    private(set) var isRunning = false

    /// - Parameters:
    ///   - setIndicator: shows or hides the listening indicator beside the menu bar icon.
    ///   - openMenu: opens the menu bar menu, for the Share panel's back button.
    init(setIndicator: @escaping (Bool) -> Void, openMenu: @escaping () -> Void = {}) {
        self.setIndicator = setIndicator
        self.openMenu = openMenu
    }

    var isPanelShown: Bool { panel?.isShown ?? false }

    /// Gets the Share panel out of the way of another Cheese feature. Sharing keeps running for the
    /// usual 10 minutes after.
    func closePanel() {
        panel?.close()
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(id: .showShare, title: "Share…", symbol: "square.and.arrow.up", module: id, shortcut: .showShare) { [weak self] _ in
                self?.open()
            },
            CheeseAction(id: .sendClipboard, title: "Send Clipboard to…", symbol: "doc.on.clipboard", module: id) { [weak self] _ in
                self?.open(ready: Self.clipboardItems())
            },
        ]
    }

    func start() {
        isRunning = true
        ShareHandoff.setEnabled(true)
    }

    /// Stops everything at once: listener, discovery, transfers and the panel.
    func stop() {
        isRunning = false
        ShareHandoff.setEnabled(false)
        panel?.close()
        service?.stop()
    }

    /// Opens the Share panel, with `ready` waiting to be sent.
    func open(ready: [OutgoingItem] = []) {
        guard isRunning else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.show(ready: ready)
    }

    /// From the Shelf's Send….
    func open(files: [URL], texts: [String]) {
        open(ready: files.map(OutgoingItem.file) + texts.map(OutgoingItem.text))
    }

    /// `cheese://share/<uuid>` from the macOS Share menu.
    func openHandoff(_ url: URL) {
        guard let id = ShareHandoff.jobID(from: url), let container = FilesHandoff.container else { return }
        guard isRunning else {
            CheeseToast.show("Cheese Share is turned off in Settings", systemImage: "exclamationmark.triangle.fill")
            return
        }
        do {
            let job = try ShareHandoff.read(id, from: container)
            open(files: job.files, texts: job.texts)
        } catch {
            Logger.share.error("Couldn't read the Share menu job: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makePanel() -> SharePanelController {
        let service = ShareService(hooks: ShareService.Hooks(
            ask: { [prompt] summary, sender in await prompt.ask(summary, from: sender) },
            receivedText: { text, sender in Self.receivedText(text, from: sender) },
            setListening: { [weak self] listening in
                self?.setIndicator(listening)
                if !listening, let container = FilesHandoff.container {
                    // Share-menu items were only kept for sending.
                    ShareHandoff.removeAll(in: container)
                }
            }
        ))
        self.service = service
        return SharePanelController(service: service, clipboardItems: { Self.clipboardItems() }, openMenu: openMenu)
    }

    /// Received text goes on the clipboard, where clipboard history (when it's on) records it.
    private static func receivedText(_ text: String, from sender: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        CheeseToast.show("Text from \(sender) — copied", systemImage: "text.bubble.fill")
    }

    /// The clipboard as things to send: its files, its text, or its image as a PNG.
    static func clipboardItems() -> [OutgoingItem] {
        switch QRModule.source(from: SystemPasteboard()) {
        case .empty:
            return []
        case let .text(text), let .richText(text):
            return [.text(text)]
        case let .files(urls):
            // No folder sending.
            return urls.filter { !$0.hasDirectoryPath }.map(OutgoingItem.file)
        case let .image(png):
            let folder = FileManager.default.temporaryDirectory.appending(path: "CheeseShare-\(UUID().uuidString)", directoryHint: .isDirectory)
            let file = folder.appending(path: "Clipboard Image.png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: file)
                return [.file(file)]
            } catch {
                Logger.share.error("Couldn't save the clipboard image: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
    }
}
