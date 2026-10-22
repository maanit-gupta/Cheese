import AppKit
import os

/// Runs the three screenshot modes and hands each result to `onCapture`.
@MainActor
final class CaptureController {
    /// Called with the captured image and whether the user asked for the editor (Shift held).
    var onCapture: (CapturedImage, _ wantsEditor: Bool) -> Void = { _, _ in }

    private let capturer: any ScreenCapturing
    /// Overlays don't stack: a second hotkey press while one is up is ignored.
    private(set) var isBusy = false

    init(capturer: any ScreenCapturing) {
        self.capturer = capturer
    }

    func captureRegion() async {
        guard let selection = await selectRegion() else { return }
        guard let image = selection.image else {
            selection.session.end(restoreFocus: true)
            return
        }
        selection.session.end(restoreFocus: !selection.shiftHeld)
        onCapture(image, selection.shiftHeld)
    }

    func captureWindow() async {
        guard begin() else { return }
        defer { isBusy = false }
        guard let pick = await WindowPicker.pickWindow() else { return }
        do {
            let image = try await capturer.captureWindow(pick.window.windowID)
            pick.session.end(restoreFocus: !pick.shiftHeld)
            onCapture(image, pick.shiftHeld)
        } catch {
            pick.session.end(restoreFocus: true)
            report(error)
        }
    }

    func captureFullScreen(wantsEditor: Bool) async {
        guard begin() else { return }
        defer { isBusy = false }
        guard let screen = Screens.underMouse, let displayID = screen.displayID else { return }
        do {
            onCapture(try await capturer.captureDisplay(displayID), wantsEditor)
        } catch {
            report(error)
        }
    }

    /// Freezes every display and lets the user drag out a region. Shared with OCR and scrolling capture.
    /// The caller must end the returned selection's session.
    func selectRegion() async -> RegionSelection? {
        guard begin() else { return nil }
        defer { isBusy = false }
        let snapshots: [DisplaySnapshot]
        do {
            snapshots = try await capturer.snapshotAllDisplays()
        } catch {
            report(error)
            return nil
        }
        return await SelectionOverlay.selectRegion(on: snapshots)
    }

    /// Repeated captures of a selected region, for scrolling capture.
    func regionCapturer(for selection: RegionSelection) async throws -> any RegionCapturing {
        try await capturer.makeRegionCapturer(for: selection.rect, displayID: selection.snapshot.displayID)
    }

    private func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    private func report(_ error: any Error) {
        Logger.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        Toast.show("Capture failed: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
    }
}
