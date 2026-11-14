import Foundation
import ImageIO
import Testing
@testable import Cheese

struct CaptureDeliveryTests {
    @Test func destinationsCopyAndSaveAsNamed() {
        #expect(CaptureDestination.clipboard.copies && !CaptureDestination.clipboard.saves)
        #expect(!CaptureDestination.folder.copies && CaptureDestination.folder.saves)
        #expect(CaptureDestination.clipboardAndFolder.copies && CaptureDestination.clipboardAndFolder.saves)
    }

    @Test func toastSaysWhatHappened() {
        let name = "Cheese 2026-10-26 at 09.30.00.png"
        #expect(CaptureDeliveryOutcome(copied: true, savedName: nil, saveFailed: false).message(noun: "Screenshot")
            == "Screenshot copied")
        #expect(CaptureDeliveryOutcome(copied: false, savedName: name, saveFailed: false).message(noun: "Scrolling capture")
            == "Saved \(name)")
        #expect(CaptureDeliveryOutcome(copied: true, savedName: name, saveFailed: false).message(noun: "Snapshot")
            == "Snapshot copied and saved as \(name)")
    }

    @Test func aFailedSaveFallsBackToTheClipboard() {
        let outcome = CaptureDeliveryOutcome(copied: true, savedName: nil, saveFailed: true)
        #expect(outcome.message(noun: "Scrolling capture") == "Couldn't save the scrolling capture — copied it instead")
        #expect(outcome.isProblem)
        #expect(CaptureDeliveryOutcome(copied: false, savedName: nil, saveFailed: true).message(noun: "Screenshot") == nil)
    }

    @Test func preferenceDefaultsToTheClipboard() throws {
        let suite = "CaptureDeliveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Preferences(defaults: defaults).captureDestination == .clipboard)
        defaults.set("folder", forKey: PreferenceKey.captureDestination)
        #expect(Preferences(defaults: defaults).captureDestination == .folder)
        defaults.set("printer", forKey: PreferenceKey.captureDestination)
        #expect(Preferences(defaults: defaults).captureDestination == .clipboard)
    }
}

// MARK: - Add to Photos

/// A Photos library that records what it's given and never touches the real one.
final class FakePhotoLibrary: PhotoLibraryWriting, @unchecked Sendable {
    var status: PhotoAccess
    var statusAfterRequest: PhotoAccess
    var failure: (any Error)?
    private(set) var added: [(png: Data, filename: String)] = []
    private(set) var requests = 0

    init(status: PhotoAccess, statusAfterRequest: PhotoAccess = .granted, failure: (any Error)? = nil) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest
        self.failure = failure
    }

    var authorizationStatus: PhotoAccess { status }

    func requestAccess() async -> PhotoAccess {
        requests += 1
        status = statusAfterRequest
        return status
    }

    func add(png: Data, filename: String) async throws {
        if let failure { throw failure }
        added.append((png, filename))
    }
}

struct CapturePhotosWordingTests {
    private let name = "Cheese 2026-11-14 at 19.40.00.png"

    private func outcome(copied: Bool = false, saved: Bool = false, saveFailed: Bool = false, added: Bool = false, failed: Bool = false) -> CaptureDeliveryOutcome {
        CaptureDeliveryOutcome(copied: copied, savedName: saved ? name : nil, saveFailed: saveFailed, addedToPhotos: added, photosFailed: failed)
    }

    @Test func everyCombinationReadsRight() {
        #expect(outcome(copied: true, added: true).message(noun: "Screenshot") == "Screenshot copied and added to Photos")
        #expect(outcome(saved: true, added: true).message(noun: "Screenshot") == "Saved \(name) and added to Photos")
        #expect(outcome(copied: true, saved: true, added: true).message(noun: "Snapshot") == "Snapshot copied, saved as \(name) and added to Photos")
        #expect(outcome(copied: true, saveFailed: true, added: true).message(noun: "Scrolling capture")
            == "Couldn't save the scrolling capture — copied it and added it to Photos")
        #expect(outcome(copied: true, failed: true).message(noun: "Screenshot") == "Screenshot copied — couldn't add to Photos")
        #expect(outcome(saved: true, failed: true).message(noun: "Screenshot") == "Saved \(name) — couldn't add to Photos")
        #expect(outcome(copied: true, saved: true, failed: true).message(noun: "Screenshot") == "Screenshot copied and saved as \(name) — couldn't add to Photos")
        #expect(outcome(copied: true, saveFailed: true, failed: true).message(noun: "Screenshot")
            == "Couldn't save the screenshot — copied it instead — couldn't add to Photos")
        // Without Photos, nothing changes.
        #expect(outcome(copied: true).message(noun: "Screenshot") == "Screenshot copied")
        #expect(outcome(saveFailed: true, failed: true).message(noun: "Screenshot") == nil)
    }

    @Test func oneButtonWithTheMostUsefulAction() {
        #expect(outcome(copied: true, added: true).action == .showInPhotos)
        #expect(outcome(saved: true, added: true).action == .showInFinder)
        #expect(outcome(copied: true, saved: true, added: true).action == .showInFinder)
        #expect(outcome(saved: true, failed: true).action == .openPhotosSettings)
        #expect(outcome(copied: true, failed: true).action == .openPhotosSettings)
        #expect(outcome(copied: true).action == nil)
        #expect(outcome(saved: true).action == .showInFinder)
        #expect(outcome(copied: true, added: true).isProblem == false)
        #expect(outcome(copied: true, failed: true).isProblem)
        #expect(CaptureDeliveryOutcome.Action.openPhotosSettings.title == "Open Settings")
        #expect(CaptureDeliveryOutcome.Action.showInPhotos.title == "Show in Photos")
    }
}

@MainActor
struct CapturePhotosDeliveryTests {
    private let suite = "CapturePhotosDeliveryTests-\(UUID().uuidString)"
    private let folder = makeTemporaryDirectory()

    private func preferences(photos: Bool, kinds: [CaptureKind: Bool] = [:]) throws -> Preferences {
        let defaults = try #require(UserDefaults(suiteName: suite))
        // Save to a folder, so the tests don't touch the real clipboard.
        defaults.set(CaptureDestination.folder.rawValue, forKey: PreferenceKey.captureDestination)
        defaults.set(folder.path(percentEncoded: false), forKey: PreferenceKey.screenshotSaveFolder)
        defaults.set(photos, forKey: PreferenceKey.photosEnabled)
        for (kind, on) in kinds {
            defaults.set(on, forKey: kind.photosKey)
        }
        return Preferences(defaults: defaults)
    }

    private var image: CapturedImage {
        get throws { CapturedImage(image: try #require(FileFixtures.halfTransparentImage()), scale: 2) }
    }

    @Test func offByDefaultAndPerKind() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!Preferences(defaults: defaults).addsToPhotos(.standard))
        defaults.set(true, forKey: PreferenceKey.photosEnabled)
        #expect(CaptureKind.allCases.allSatisfy { Preferences(defaults: defaults).addsToPhotos($0) })
        defaults.set(false, forKey: PreferenceKey.photosScrollingCaptures)
        #expect(!Preferences(defaults: defaults).addsToPhotos(.scrolling))
        #expect(Preferences(defaults: defaults).addsToPhotos(.drawSnapshot))
    }

    @Test func savesFirstThenAddsTheSamePNGUnderTheSameName() async throws {
        let library = FakePhotoLibrary(status: .granted)
        let result = await CaptureDelivery.deliverWithoutToast(try image, kind: .standard, preferences: try preferences(photos: true), photos: library)
        #expect(result.outcome.addedToPhotos && !result.outcome.photosFailed)
        let saved = try #require(result.savedURL)
        #expect(library.added.map(\.filename) == [saved.lastPathComponent])
        // Marked as a screenshot (EXIF user comment), at the capture's pixel size.
        let png = try #require(library.added.first?.png)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] as? String == "Screenshot")
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func turnedOffOrUntickedKindsStayOutOfPhotos() async throws {
        let library = FakePhotoLibrary(status: .granted)
        _ = await CaptureDelivery.deliverWithoutToast(try image, kind: .standard, preferences: try preferences(photos: false), photos: library)
        _ = await CaptureDelivery.deliverWithoutToast(try image, kind: .scrolling, preferences: try preferences(photos: true, kinds: [.scrolling: false]), photos: library)
        #expect(library.added.isEmpty)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func deniedOrRevokedStillSavesAndSaysSo() async throws {
        let denied = FakePhotoLibrary(status: .denied)
        let result = await CaptureDelivery.deliverWithoutToast(try image, kind: .drawSnapshot, preferences: try preferences(photos: true), photos: denied)
        #expect(result.savedURL != nil)
        #expect(result.outcome.photosFailed && result.outcome.action == .openPhotosSettings)
        #expect(denied.requests == 0)
        // The switch stays on.
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: PreferenceKey.photosEnabled) == true)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func aFailedAddStillSavesAndNotYetAskedAsksOnce() async throws {
        let failing = FakePhotoLibrary(status: .granted, failure: PhotoLibraryError.failed("disk full"))
        let failed = await CaptureDelivery.deliverWithoutToast(try image, kind: .standard, preferences: try preferences(photos: true), photos: failing)
        #expect(failed.savedURL != nil && failed.outcome.photosFailed)

        let unasked = FakePhotoLibrary(status: .notDetermined, statusAfterRequest: .granted)
        let asked = await CaptureDelivery.deliverWithoutToast(try image, kind: .standard, preferences: try preferences(photos: true), photos: unasked)
        #expect(unasked.requests == 1 && asked.outcome.addedToPhotos)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

struct PhotosWiringTests {
    @Test func photosIsNeverInTheWelcomePlanButListedInSettings() {
        #expect(!PermissionPlan.plan(for: Set(ModuleID.allCases)).contains(.photos))
        #expect(PermissionNeed.photos.isOptional)
        #expect(PermissionPlan.tools(needing: .photos, among: Set(ModuleID.allCases)) == [.clipboard, .screenshots, .scrollingCapture, .drawOnScreen, .shelf])
    }

    @Test func addToPhotosSitsBelowTheDestinations() throws {
        let captureNode = try #require(MenuLayout.standard.first { if case .submenu("Capture", _, _, _) = $0 { true } else { false } })
        guard case let .submenu(_, _, capture, _) = captureNode, let last = capture.last, case let .submenu(_, _, afterCapture, _) = last else {
            Issue.record("no After Capture submenu")
            return
        }
        #expect(Array(afterCapture.suffix(2)) == [.separator, .action(.addToPhotos)])
    }
}
