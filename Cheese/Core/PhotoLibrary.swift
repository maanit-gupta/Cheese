import AppKit
import ImageIO
import Photos
import UniformTypeIdentifiers
import os

/// Whether Cheese may add to the Photos library.
enum PhotoAccess: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

/// The Photos library behind a small protocol, so capture delivery is tested with a fake and tests
/// never touch the real library.
protocol PhotoLibraryWriting: Sendable {
    var authorizationStatus: PhotoAccess { get }
    func requestAccess() async -> PhotoAccess
    /// Adds a PNG to the "Cheese" album (made again if the user deleted it).
    func add(png: Data, filename: String) async throws
}

enum PhotoLibraryError: LocalizedError {
    case notAllowed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Cheese isn't allowed to add to Photos."
        case let .failed(reason): reason
        }
    }
}

/// PhotoKit. Read-write access, because finding and making the "Cheese" album means reading the
/// library's albums; the album's identifier is remembered in Preferences.
final class SystemPhotoLibrary: PhotoLibraryWriting {
    static let shared = SystemPhotoLibrary()
    static let albumTitle = "Cheese"
    /// Longer sides than this may be refused or downscaled by Photos; added anyway, with a warning.
    static let largeSide = 16_384

    /// UserDefaults is thread-safe; it just isn't marked Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var authorizationStatus: PhotoAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> PhotoAccess {
        Self.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func access(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func add(png: Data, filename: String) async throws {
        guard authorizationStatus == .granted else { throw PhotoLibraryError.notAllowed }
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) > Self.largeSide {
            Logger.capture.warning("Adding a \(width)×\(height) image to Photos; very long images may be downscaled there.")
        }
        let album = try await album()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.uniformTypeIdentifier = UTType.png.identifier
            request.addResource(with: .photo, data: png, options: options)
            if let placeholder = request.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        Logger.capture.notice("Added \(filename, privacy: .public) to Photos")
    }

    /// The remembered "Cheese" album, or one with that title, or a new one.
    private func album() async throws -> PHAssetCollection {
        if let identifier = defaults.string(forKey: PreferenceKey.photosAlbumIdentifier),
           let existing = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject {
            return existing
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", Self.albumTitle)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
            defaults.set(existing.localIdentifier, forKey: PreferenceKey.photosAlbumIdentifier)
            return existing
        }
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.albumTitle)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoLibraryError.failed("The Cheese album couldn't be made.")
        }
        defaults.set(identifier, forKey: PreferenceKey.photosAlbumIdentifier)
        return album
    }
}

/// Opening Photos and its privacy pane. There's no public way to open one asset or album.
@MainActor
enum PhotosApp {
    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")

    static func open() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func openSettings() {
        if let url = privacySettings {
            NSWorkspace.shared.open(url)
        }
    }

    /// Adds an image file (a history clip, a shelf item) as an explicit action, whatever the
    /// automatic switch says, and says how it went.
    static func add(_ file: URL, library: any PhotoLibraryWriting = SystemPhotoLibrary.shared) async {
        var access = library.authorizationStatus
        if access == .notDetermined {
            access = await library.requestAccess()
        }
        guard access == .granted else {
            CheeseToast.show("Couldn't add to Photos", systemImage: "exclamationmark.triangle.fill", action: CheeseToast.Action(title: "Open Settings") { openSettings() })
            return
        }
        do {
            let png = try await PhotoExport.png(fromFile: file)
            let name = file.deletingPathExtension().lastPathComponent + ".png"
            try await library.add(png: png, filename: name)
            CheeseToast.show("Added to Photos", systemImage: "photo.on.rectangle", action: CheeseToast.Action(title: "Show in Photos") { open() })
        } catch {
            Logger.capture.error("Adding to Photos failed: \(error.localizedDescription, privacy: .public)")
            CheeseToast.show("Couldn't add to Photos", systemImage: "exclamationmark.triangle.fill", action: CheeseToast.Action(title: "Open Settings") { openSettings() })
        }
    }
}

/// The "Also add to Photos" switch, from the menu or Settings. Access is asked for when it's turned
/// on (never at launch). A refusal doesn't turn it back off: captures still copy or save, and the
/// toast says Photos was skipped.
@MainActor
enum PhotosSwitch {
    static func set(_ enabled: Bool, announce: Bool, library: any PhotoLibraryWriting = SystemPhotoLibrary.shared, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: PreferenceKey.photosEnabled)
        guard enabled else {
            if announce {
                CheeseToast.show("Captures won't be added to Photos", systemImage: "photo.on.rectangle")
            }
            return
        }
        Task {
            var access = library.authorizationStatus
            if access == .notDetermined {
                access = await library.requestAccess()
            }
            if access != .granted {
                CheeseToast.show(
                    "Cheese isn't allowed to add to Photos", systemImage: "exclamationmark.triangle.fill",
                    action: CheeseToast.Action(title: "Open Settings") { PhotosApp.openSettings() }
                )
            } else if announce {
                CheeseToast.show("Captures will also be added to Photos", systemImage: "photo.on.rectangle")
            }
        }
    }
}

/// PNGs for Photos.
enum PhotoExport {
    /// Captures carry macOS's screenshot marker (EXIF user comment "Screenshot").
    static let marksScreenshots = true

    /// Any image file as PNG, upright, so Photos gets the same pixels Cheese shows.
    @concurrent
    static func png(fromFile file: URL) async throws -> Data {
        if FileKind(url: file) == .image, file.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: file) {
            return data
        }
        guard let picture = LocalImages.png(at: file) else { throw PhotoLibraryError.failed("\(file.lastPathComponent) isn't an image Cheese can read.") }
        return picture.png
    }
}
