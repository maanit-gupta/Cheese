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

/// What kind of capture is being delivered, for the per-kind "Also add to Photos" checkboxes.
/// (OCR is text, so it never goes to Photos.)
enum CaptureKind: String, CaseIterable, Identifiable, Sendable {
    /// Region, window and full screen.
    case standard
    case scrolling
    case drawSnapshot

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Region, window and full screen"
        case .scrolling: "Scrolling captures"
        case .drawSnapshot: "Draw-mode snapshots"
        }
    }

    var photosKey: String {
        switch self {
        case .standard: PreferenceKey.photosStandardCaptures
        case .scrolling: PreferenceKey.photosScrollingCaptures
        case .drawSnapshot: PreferenceKey.photosDrawSnapshots
        }
    }
}

/// What happened to a capture, and the toast that says so. Pure, so the wording is tested.
struct CaptureDeliveryOutcome: Equatable, Sendable {
    var copied: Bool
    var savedName: String?
    var saveFailed: Bool
    var addedToPhotos = false
    var photosFailed = false

    /// The toast's one button.
    enum Action: Equatable, Sendable {
        case showInFinder
        case showInPhotos
        case openPhotosSettings

        var title: String {
            switch self {
            case .showInFinder: "Show"
            case .showInPhotos: "Show in Photos"
            case .openPhotosSettings: "Open Settings"
            }
        }
    }

    /// - Parameter noun: "Screenshot", "Scrolling capture", "Snapshot".
    func message(noun: String) -> String? {
        let base: String? = switch (copied, savedName, saveFailed) {
        case (true, let name?, _): "\(noun) copied and saved as \(name)"
        case (false, let name?, _): "Saved \(name)"
        case (true, nil, true): "Couldn't save the \(noun.lowercased()) — copied it instead"
        case (true, nil, false): "\(noun) copied"
        case (false, nil, _): nil
        }
        guard let base else { return nil }
        if photosFailed {
            return base + " — couldn't add to Photos"
        }
        guard addedToPhotos else { return base }
        if saveFailed {
            return "Couldn't save the \(noun.lowercased()) — copied it and added it to Photos"
        }
        if copied, let savedName {
            return "\(noun) copied, saved as \(savedName) and added to Photos"
        }
        return base + " and added to Photos"
    }

    /// The most useful next step: fixing Photos access when that failed, else the saved file,
    /// else the photo (only when nothing went to a folder).
    var action: Action? {
        if photosFailed { return .openPhotosSettings }
        if savedName != nil { return .showInFinder }
        if addedToPhotos { return .showInPhotos }
        return nil
    }

    var isProblem: Bool { saveFailed || photosFailed || (!copied && savedName == nil) }
}

enum CaptureDelivery {
    /// Copies and/or saves `image` as the user chose, then (if turned on for this kind) adds it to
    /// Photos, and shows one toast. A save that fails still copies the image, and Photos never
    /// blocks or undoes the copy or save, so a capture is never lost.
    @MainActor
    static func deliver(
        _ image: CapturedImage, noun: String, kind: CaptureKind, preferences: Preferences = Preferences(),
        photos: any PhotoLibraryWriting = SystemPhotoLibrary.shared
    ) async {
        let outcome = await deliverWithoutToast(image, kind: kind, preferences: preferences, photos: photos)
        guard let message = outcome.outcome.message(noun: noun) else {
            CheeseToast.show("Couldn't copy or save the \(noun.lowercased())", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let savedURL = outcome.savedURL
        let action = outcome.outcome.action.map { action in
            CheeseToast.Action(title: action.title) {
                switch action {
                case .showInFinder: if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                case .showInPhotos: PhotosApp.open()
                case .openPhotosSettings: PhotosApp.openSettings()
                }
            }
        }
        let symbol = outcome.outcome.isProblem ? "exclamationmark.triangle.fill"
            : savedURL != nil ? "square.and.arrow.down.fill" : outcome.outcome.addedToPhotos ? "photo.on.rectangle" : "checkmark.circle.fill"
        CheeseToast.show(message, systemImage: symbol, action: action)
    }

    /// The copy, save and Photos steps, in that order, without the toast.
    @MainActor
    static func deliverWithoutToast(
        _ image: CapturedImage, kind: CaptureKind, preferences: Preferences, photos: any PhotoLibraryWriting
    ) async -> (outcome: CaptureDeliveryOutcome, savedURL: URL?) {
        let destination = preferences.captureDestination
        var outcome = CaptureDeliveryOutcome(copied: false, savedName: nil, saveFailed: false)
        var savedURL: URL?
        let date = Date.now
        if destination.saves {
            do {
                savedURL = try await ImageExport.save(image, in: preferences.screenshotSaveFolder, date: date)
                outcome.savedName = savedURL?.lastPathComponent
            } catch {
                Logger.capture.error("Saving the capture failed: \(error.localizedDescription, privacy: .public)")
                outcome.saveFailed = true
            }
        }
        if destination.copies || outcome.saveFailed {
            outcome.copied = await ImageExport.copy(image)
        }

        if preferences.addsToPhotos(kind) {
            var access = photos.authorizationStatus
            if access == .notDetermined {
                access = await photos.requestAccess()
            }
            if access == .granted {
                do {
                    let png = try await ImageExport.pngDataInBackground(for: image, markedAsScreenshot: PhotoExport.marksScreenshots)
                    let name = savedURL?.lastPathComponent ?? ScreenshotNaming.baseName(for: date) + ".png"
                    try await photos.add(png: png, filename: name)
                    outcome.addedToPhotos = true
                } catch {
                    Logger.capture.error("Adding the capture to Photos failed: \(error.localizedDescription, privacy: .public)")
                    outcome.photosFailed = true
                }
            } else {
                Logger.capture.notice("Not adding the capture to Photos: access isn't granted")
                outcome.photosFailed = true
            }
        }
        return (outcome, savedURL)
    }
}
