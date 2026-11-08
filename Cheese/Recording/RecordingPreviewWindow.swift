import AVKit
import AppKit
import SwiftUI
import os

/// Shows a finished recording: plays an MP4 (with Trim) or an animated GIF, with Copy, Show in
/// Finder, Export as GIF and Delete.
@MainActor
final class RecordingPreviewWindow {
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func show(_ url: URL, format: RecordingFormat) {
        let visible = (Screens.underMouse ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size = CGSize(width: min(900, visible.width * 0.7), height: min(620, visible.height * 0.75))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        let model = RecordingPreviewModel(url: url, format: format) { [weak window] in window?.performClose(nil) }
        window.contentViewController = NSHostingController(rootView: RecordingPreviewView(model: model))
        window.setContentSize(size)
        window.center()

        let id = ObjectIdentifier(window)
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                model.player?.pause()
                self?.windows[id] = nil
                if let observer = self?.closeObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        windows[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class RecordingPreviewModel {
    let url: URL
    let format: RecordingFormat
    let player: AVPlayer?
    var isWorking = false
    @ObservationIgnored weak var playerView: AVPlayerView?
    @ObservationIgnored private let close: () -> Void

    init(url: URL, format: RecordingFormat, close: @escaping () -> Void) {
        self.url = url
        self.format = format
        self.close = close
        player = format == .mp4 ? AVPlayer(url: url) : nil
    }

    func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        CheeseToast.show("Recording copied")
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func delete() {
        player?.pause()
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error {
                Logger.recording.error("Couldn't move the recording to the Trash: \(error.localizedDescription, privacy: .public)")
            }
        }
        close()
    }

    func exportGIF() {
        guard !isWorking else { return }
        isWorking = true
        CheeseToast.show("Making GIF…", systemImage: "photo.stack")
        let source = url
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let settings = GIFSettings.stored(in: .standard)
        Task {
            let fileManager = FileManager.default
            var output = folder.appending(path: "\(base).gif")
            var counter = 2
            while fileManager.fileExists(atPath: output.path(percentEncoded: false)) {
                output = folder.appending(path: "\(base) (\(counter)).gif")
                counter += 1
            }
            do {
                try await GIFEncoder.makeGIF(from: source, to: output, settings: settings)
                let made = output
                CheeseToast.show("Saved \(made.lastPathComponent)", action: CheeseToast.Action(title: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([made])
                })
            } catch {
                CheeseToast.show("Couldn't make the GIF", systemImage: "exclamationmark.triangle.fill")
            }
            isWorking = false
        }
    }

    /// AVKit's trim bar; keeping the trimmed part replaces the file.
    func trim() {
        guard let playerView, playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            MainActor.assumeIsolated { self?.saveTrim() }
        }
    }

    private func saveTrim() {
        guard let item = player?.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard end > start else { return }
        isWorking = true
        let asset = item.asset
        let url = url
        Task {
            let trimmed = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).mp4")
            do {
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw RecordingError.export("Couldn't trim the recording")
                }
                export.timeRange = CMTimeRange(start: start, end: end)
                try await export.export(to: trimmed, as: .mp4)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: trimmed)
                player?.replaceCurrentItem(with: AVPlayerItem(url: url))
                CheeseToast.show("Recording trimmed")
            } catch {
                try? FileManager.default.removeItem(at: trimmed)
                Logger.recording.error("Trimming failed: \(error.localizedDescription, privacy: .public)")
                CheeseToast.show("Couldn't trim the recording", systemImage: "exclamationmark.triangle.fill")
            }
            isWorking = false
        }
    }
}

private struct RecordingPreviewView: View {
    let model: RecordingPreviewModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let player = model.player {
                    PlayerView(player: player, model: model)
                } else {
                    AnimatedImageView(url: model.url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            CheeseDivider()
            HStack(spacing: DesignTokens.Spacing.small) {
                if model.format == .mp4 {
                    Button("Trim", systemImage: "scissors", action: model.trim)
                        .disabled(model.isWorking)
                }
                Button("Copy", systemImage: "doc.on.doc", action: model.copy)
                    .keyboardShortcut("c")
                Button("Show in Finder", systemImage: "folder", action: model.showInFinder)
                if model.format == .mp4 {
                    Button("Export as GIF", systemImage: "photo.stack", action: model.exportGIF)
                        .disabled(model.isWorking)
                }
                Spacer()
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Delete", systemImage: "trash", role: .destructive, action: model.delete)
            }
            .padding(DesignTokens.Spacing.large)
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let model: RecordingPreviewModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsSharingServiceButton = true
        model.playerView = view
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(contentsOf: url)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
