import AppKit
import SwiftUI
import os

/// Shows a finished scrolling capture with Copy, Save, Annotate and OCR.
@MainActor
final class ScrollPreviewWindow {
    struct Actions {
        var annotate: (CapturedImage) -> Void
        /// Reads the text in the image and copies it.
        var recognizeText: (CapturedImage) async -> Void
    }

    private let actions: Actions
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    init(actions: Actions) {
        self.actions = actions
    }

    func show(_ image: CapturedImage) {
        let visible = (Screens.underMouse ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(image.pointSize.width + 40, 520), visible.width * 0.8)
        let size = CGSize(width: width, height: visible.height * 0.85)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scrolling Capture"
        window.isReleasedWhenClosed = false
        let view = ScrollPreviewView(
            image: image,
            annotate: { [weak self, weak window] in
                self?.actions.annotate(image)
                window?.performClose(nil)
            },
            recognizeText: { [weak self] in await self?.actions.recognizeText(image) },
            close: { [weak window] in window?.performClose(nil) }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.center()

        let id = ObjectIdentifier(window)
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose(id) }
        }
        windows[id] = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func windowWillClose(_ id: ObjectIdentifier) {
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[id] = nil
    }
}

private struct ScrollPreviewView: View {
    let image: CapturedImage
    let annotate: () -> Void
    let recognizeText: () async -> Void
    let close: () -> Void
    @State private var isReading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(image.image.width) × \(image.image.height) px")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    Task {
                        if await ImageExport.copy(image) { Toast.show("Copied") }
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Annotate", action: annotate)
                Button {
                    Task {
                        isReading = true
                        await recognizeText()
                        isReading = false
                    }
                } label: {
                    if isReading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("OCR")
                    }
                }
                .disabled(isReading)
                Button("Close", action: close)
                    .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            TiledImageScrollView(image: image)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func save() async {
        do {
            let url = try await ImageExport.save(image, in: Preferences().screenshotSaveFolder)
            Toast.show("Saved \(url.lastPathComponent)", systemImage: "square.and.arrow.down.fill", action: Toast.Action(title: "Show") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        } catch {
            Logger.scrollCapture.error("Saving failed: \(error.localizedDescription, privacy: .public)")
            Toast.show("Couldn't save: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
        }
    }
}

/// A vertically scrolling view of a very tall image. The image is drawn as a stack of layer tiles,
/// since a single layer can't hold an image taller than the GPU's texture limit.
private struct TiledImageScrollView: NSViewRepresentable {
    let image: CapturedImage

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        let document = TiledImageView(image: image)
        scrollView.documentView = document
        document.frame.size.width = scrollView.contentSize.width
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

private final class TiledImageView: NSView {
    private static let tileHeight = 2_048
    private let image: CapturedImage
    private var tiles: [(layer: CALayer, rows: Range<Int>)] = []

    init(image: CapturedImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        postsFrameChangedNotifications = true
        var start = 0
        while start < image.image.height {
            let end = min(start + Self.tileHeight, image.image.height)
            let layer = CALayer()
            layer.contents = image.image.cropping(to: CGRect(x: 0, y: start, width: image.image.width, height: end - start))
            layer.contentsGravity = .resize
            layer.magnificationFilter = .trilinear
            layer.minificationFilter = .trilinear
            self.layer?.addSublayer(layer)
            tiles.append((layer, start..<end))
            start = end
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fitToClipView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewChanged), name: NSView.frameDidChangeNotification, object: superview
        )
        superview?.postsFrameChangedNotifications = true
    }

    @objc private func clipViewChanged() {
        fitToClipView()
    }

    /// Fills the width (never wider than the image's natural size) and lays out the tiles.
    private func fitToClipView() {
        guard let clip = superview else { return }
        let width = min(clip.bounds.width, image.pointSize.width)
        let scale = width / CGFloat(max(image.image.width, 1))
        setFrameSize(CGSize(width: clip.bounds.width, height: CGFloat(image.image.height) * scale))
        let inset = (clip.bounds.width - width) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in tiles {
            tile.layer.frame = CGRect(
                x: inset,
                y: CGFloat(tile.rows.lowerBound) * scale,
                width: width,
                height: CGFloat(tile.rows.count) * scale
            )
        }
        CATransaction.commit()
    }
}
