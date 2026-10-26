import AppKit

/// Region, window and full-screen screenshots: copied and/or saved (After Capture), or into the
/// editor with Shift.
@MainActor
final class ScreenshotsModule: CheeseModule {
    let id = ModuleID.screenshots
    private let capture: CaptureController
    private let editor: AnnotationEditor

    init(capture: CaptureController, editor: AnnotationEditor) {
        self.capture = capture
        self.editor = editor
        capture.onCapture = { [weak self] image, wantsEditor in self?.handleScreenshot(image, wantsEditor: wantsEditor) }
    }

    var actions: [CheeseAction] {
        [
            CheeseAction(
                id: .captureRegion, title: "Capture Region", symbol: "crop", module: id,
                shortcut: .captureRegion, requiredPermissions: [.screenRecording]
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.capture.captureRegion() }
            },
            CheeseAction(
                id: .captureWindow, title: "Capture Window", symbol: "macwindow", module: id,
                shortcut: .captureWindow, requiredPermissions: [.screenRecording]
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.capture.captureWindow() }
            },
            // Shift + the shortcut (its hidden variant) or a Shift-click opens the editor.
            CheeseAction(
                id: .captureFullScreen, title: "Capture Full Screen", symbol: "display", module: id,
                shortcut: .captureFullScreen, hiddenShortcuts: [.captureFullScreenEditor], requiredPermissions: [.screenRecording]
            ) { [weak self] _ in
                guard let self else { return }
                let wantsEditor = NSEvent.modifierFlags.contains(.shift)
                Task { await self.capture.captureFullScreen(wantsEditor: wantsEditor) }
            },
        ]
    }

    // Captures only run on demand, so there's nothing to start or stop.
    func start() {}
    func stop() {}

    private func handleScreenshot(_ image: CapturedImage, wantsEditor: Bool) {
        if wantsEditor {
            editor.open(image)
            return
        }
        Task { await CaptureDelivery.deliver(image, noun: "Screenshot") }
    }
}
