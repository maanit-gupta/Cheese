import AppKit

/// The real recording windows.
@MainActor
final class SystemRecordingPresenter: RecordingPresenting {
    private var setupPanel: CheesePanel?
    private let countdown = RecordingCountdown()
    private let controlPanel = RecordingControlPanel()
    private var border: RegionBorderWindow?
    private let halo = CursorHalo()
    private let webcam = WebcamBubble()
    private let preview = RecordingPreviewWindow()

    func showSetup(_ model: RecordingBarModel, around region: CGRect, onCancel: @escaping () -> Void) {
        closeSetup()
        // Clicks outside don't cancel: the webcam may need dragging into place first.
        let panel = CheesePanel(
            rootView: RecordingSetupBar(model: model),
            behavior: CheesePanel.Behavior(dismissesOnOutsideClick: false, isMovable: true, level: .statusBar)
        )
        panel.onCancel = onCancel
        panel.present(at: .around(region))
        setupPanel = panel
    }

    func closeSetup() {
        setupPanel?.dismiss()
        setupPanel = nil
    }

    func showCountdown(_ number: Int, in region: CGRect) {
        countdown.show(number, centeredIn: region)
    }

    func closeCountdown() {
        countdown.close()
    }

    func showRecordingChrome(_ model: RecordingBarModel, region: CGRect, showsBorder: Bool) {
        if showsBorder {
            let border = RegionBorderWindow(region: region)
            border.show()
            self.border = border
        }
        controlPanel.show(model: model, around: region)
    }

    func closeRecordingChrome() {
        border?.close()
        border = nil
        controlPanel.close()
    }

    func showHalo(onDisplay displayID: CGDirectDisplayID) {
        guard let screen = Screens.screen(withDisplayID: displayID) else { return }
        halo.show(on: screen)
    }

    func hideHalo() {
        halo.hide()
    }

    func showWebcam(over region: CGRect) -> Bool {
        webcam.show(over: region)
    }

    func hideWebcam() {
        webcam.hide()
    }

    var includedWindowIDs: [CGWindowID] {
        [halo.windowID, webcam.windowID].compactMap { $0 }
    }

    func showPreview(_ url: URL, format: RecordingFormat) {
        preview.show(url, format: format)
    }
}
