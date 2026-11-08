import os

/// Scrolling capture: select a region, scroll it by hand (or let Auto-scroll do it) until Done,
/// copy and/or save the stitched image (After Capture), then show the preview.
@MainActor
final class ScrollCaptureModule: CheeseModule {
    let id = ModuleID.scrollingCapture
    private let capture: CaptureController
    private let preview: ScrollPreviewWindow
    private var session: ScrollCaptureSession?

    init(capture: CaptureController, previewActions: ScrollPreviewWindow.Actions) {
        self.capture = capture
        preview = ScrollPreviewWindow(actions: previewActions)
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .scrollingCapture, title: "Scrolling Capture", symbol: "rectangle.expand.vertical", module: id,
                shortcut: .scrollingCapture, requiredPermissions: [.screenRecording, .accessibility]
            ) { [weak self] _ in
                guard let self else { return }
                // The hotkey again is Done for a capture that's running.
                if let session {
                    session.finish()
                } else {
                    Task { await self.scrollingCapture() }
                }
            },
        ]
    }

    func start() {}

    /// Ends a capture that's running; it still stitches what it has and shows the preview.
    func stop() {
        session?.finish()
    }

    private func scrollingCapture() async {
        guard let selection = await capture.selectRegion() else { return }
        selection.session.end(restoreFocus: true)
        let capturer: any RegionCapturing
        do {
            capturer = try await capture.regionCapturer(for: selection)
        } catch {
            Logger.app.error("Scrolling capture setup failed: \(error.localizedDescription, privacy: .public)")
            CheeseToast.show("Capture failed: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let session = ScrollCaptureSession(region: selection.rect, capturer: capturer)
        self.session = session
        let result = await session.run()
        self.session = nil
        if let result {
            await CaptureDelivery.deliver(result, noun: "Scrolling capture")
            preview.show(result)
            if session.reachedLimit {
                CheeseToast.show("Reached the 30,000 px limit — kept what fit", systemImage: "ruler")
            }
        }
    }
}
