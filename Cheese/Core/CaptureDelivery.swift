import AppKit
import os

/// Where a finished capture goes (Settings → General → Screenshots, or Capture ▸ After Capture).
/// Applies to region, window, full-screen and scrolling captures and to draw-mode snapshots.
enum CaptureDestination: String, CaseIterable, Identifiable, Sendable {
    case clipboard
    case folder
    case clipboardAndFolder

    var id: Self { self }

    var title: String {
        switch self {
        case .clipboard: "Copy to Clipboard"
        case .folder: "Save to Folder"
        case .clipboardAndFolder: "Copy and Save"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .folder: "folder"
        case .clipboardAndFolder: "square.and.arrow.down.on.square"
        }
    }

    var copies: Bool { self != .folder }
    var saves: Bool { self != .clipboard }
}

/// What happened to a capture, and the toast that says so. Pure, so the wording is tested.
struct CaptureDeliveryOutcome: Equatable, Sendable {
    var copied: Bool
    var savedName: String?
    var saveFailed: Bool

    /// - Parameter noun: "Screenshot", "Scrolling capture", "Snapshot".
    func message(noun: String) -> String? {
        switch (copied, savedName, saveFailed) {
        case (true, let name?, _): "\(noun) copied and saved as \(name)"
        case (false, let name?, _): "Saved \(name)"
        case (true, nil, true): "Couldn't save the \(noun.lowercased()) — copied it instead"
        case (true, nil, false): "\(noun) copied"
        case (false, nil, _): nil
        }
    }

    var isProblem: Bool { saveFailed || (!copied && savedName == nil) }
}

enum CaptureDelivery {
    /// Copies and/or saves `image` as the user chose, then shows one toast. A save that fails still
    /// copies the image, so a capture is never lost.
    @MainActor
    static func deliver(_ image: CapturedImage, noun: String, preferences: Preferences = Preferences()) async {
        let destination = preferences.captureDestination
        var outcome = CaptureDeliveryOutcome(copied: false, savedName: nil, saveFailed: false)
        var savedURL: URL?
        if destination.saves {
            do {
                savedURL = try await ImageExport.save(image, in: preferences.screenshotSaveFolder)
                outcome.savedName = savedURL?.lastPathComponent
            } catch {
                Logger.capture.error("Saving the capture failed: \(error.localizedDescription, privacy: .public)")
                outcome.saveFailed = true
            }
        }
        if destination.copies || outcome.saveFailed {
            outcome.copied = await ImageExport.copy(image)
        }

        guard let message = outcome.message(noun: noun) else {
            CheeseToast.show("Couldn't copy or save the \(noun.lowercased())", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let action = savedURL.map { url in
            CheeseToast.Action(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        let symbol = outcome.isProblem ? "exclamationmark.triangle.fill" : (savedURL == nil ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
        CheeseToast.show(message, systemImage: symbol, action: action)
    }
}
