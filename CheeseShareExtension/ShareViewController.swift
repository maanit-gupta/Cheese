import AppKit
import UniformTypeIdentifiers
import os

/// "Cheese Share" in the macOS Share menu. It holds no sharing logic: it copies what it was given
/// into the App Group container and hands it to Cheese, which opens the Share panel with it ready
/// to send. When the Share module is off, it says so and offers Settings instead.
final class ShareViewController: NSViewController {
    private let logger = Logger(subsystem: "com.maanitgupta.cheese", category: "ShareExtension")

    override func loadView() {
        let label = NSTextField(labelWithString: ShareHandoff.isEnabled ? "Handing over to Cheese Share…" : "Cheese Share is turned off")
        label.font = .preferredFont(forTextStyle: .headline)
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        if !ShareHandoff.isEnabled {
            let detail = NSTextField(wrappingLabelWithString: "Turn on Cheese Share in Cheese's Settings to send things to nearby devices.")
            let buttons = NSStackView(views: [
                NSButton(title: "Cancel", target: self, action: #selector(cancel)),
                NSButton(title: "Open Settings", target: self, action: #selector(openSettings)),
            ])
            buttons.arrangedSubviews.last.map { ($0 as? NSButton)?.keyEquivalent = "\r" }
            stack.addArrangedSubview(detail)
            stack.addArrangedSubview(buttons)
        }
        view = stack
        preferredContentSize = NSSize(width: 340, height: ShareHandoff.isEnabled ? 70 : 150)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard ShareHandoff.isEnabled else { return }
        Task { @MainActor in
            await handOff()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func openSettings() {
        if let url = ShareHandoff.settingsURL {
            NSWorkspace.shared.open(url)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func handOff() async {
        guard let container = FilesHandoff.container else {
            logger.error("No App Group container")
            return
        }
        do {
            let (id, folder) = try ShareHandoff.makeJob(in: container)
            var files: [String] = []
            var texts: [String] = []
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            for item in items {
                let providers = item.attachments ?? []
                for provider in providers {
                    if let name = await copyFile(from: provider, into: folder, taken: Set(files)) {
                        files.append(name)
                    } else if let text = await loadText(from: provider) {
                        texts.append(text)
                    }
                }
                if providers.isEmpty, let text = item.attributedContentText?.string, !text.isEmpty {
                    texts.append(text)
                }
            }
            guard !files.isEmpty || !texts.isEmpty else { return }
            try ShareHandoff.finish(ShareHandoff.Job(files: files, texts: texts), in: folder)
            if let url = ShareHandoff.url(for: id) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            logger.error("Couldn't hand off: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Files (and images given as data) are copied in, since the originals may not outlive the sheet.
    private func copyFile(from provider: NSItemProvider, into folder: URL, taken: Set<String>) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(from: provider), url.isFileURL, !url.hasDirectoryPath {
            return copy(url, named: url.lastPathComponent, into: folder, taken: taken)
        }
        let imageType = UTType.image.identifier
        if provider.hasItemConformingToTypeIdentifier(imageType) {
            let suggested = provider.suggestedName ?? "Image"
            return await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
                    // The file is only there until this returns, so copy it now.
                    let name = url.map { self.copy($0, named: suggested + "." + $0.pathExtension, into: folder, taken: taken) } ?? nil
                    continuation.resume(returning: name)
                }
            }
        }
        return nil
    }

    private nonisolated func copy(_ url: URL, named name: String, into folder: URL, taken: Set<String>) -> String? {
        let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
        let ext = (name as NSString).pathExtension
        var candidate = name.replacingOccurrences(of: "/", with: "-")
        var number = 2
        while taken.contains(candidate) || candidate == "job.json" || FileManager.default.fileExists(atPath: folder.appending(path: candidate).path(percentEncoded: false)) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: folder.appending(path: candidate, directoryHint: .notDirectory))
            return candidate
        } catch {
            return nil
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await loadURL(from: provider), !url.isFileURL {
            return url.absoluteString
        }
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
