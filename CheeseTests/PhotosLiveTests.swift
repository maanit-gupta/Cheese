import Foundation
import Photos
import Testing
@testable import Cheese

/// Adds two images to the real Photos library and reads them back: whether the EXIF "Screenshot"
/// marker files a capture under Screenshots, and whether a 30,000-pixel-tall capture goes in whole.
/// `TEST_RUNNER_PHOTOS_LIVE=1 … -only-testing:CheeseTests/PhotosLiveTests`. Asks for Photos access
/// for the test host, and leaves the two images in a "Cheese" album for the person running it to delete.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_LIVE"] == "1"))
struct PhotosLiveTests {
    private func image(width: Int, height: Int) throws -> CapturedImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        for row in stride(from: 0, to: height, by: 400) {
            context.fill(CGRect(x: 20, y: row + 20, width: width - 40, height: 120))
        }
        return CapturedImage(image: try #require(context.makeImage()), scale: 2)
    }

    @Test func screenshotsAndATallCaptureLandInTheCheeseAlbum() async throws {
        let suite = "PhotosLiveTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let library = SystemPhotoLibrary(defaults: defaults)
        var access = library.authorizationStatus
        if access == .notDetermined {
            access = await library.requestAccess()
        }
        try #require(access == .granted, "Photos access wasn't granted")

        let stamp = Int(Date().timeIntervalSince1970)
        let screenshotName = "Cheese live test screenshot \(stamp).png"
        let tallName = "Cheese live test tall \(stamp).png"
        try await library.add(png: ImageExport.pngData(for: image(width: 1200, height: 800), markedAsScreenshot: true), filename: screenshotName)
        try await library.add(png: ImageExport.pngData(for: image(width: 400, height: 30_000), markedAsScreenshot: true), filename: tallName)

        let albumID = try #require(defaults.string(forKey: PreferenceKey.photosAlbumIdentifier))
        let album = try #require(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject)
        #expect(album.localizedTitle == "Cheese")

        func asset(named name: String) -> PHAsset? {
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var found: PHAsset?
            assets.enumerateObjects { asset, _, stop in
                if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename == name }) {
                    found = asset
                    stop.pointee = true
                }
            }
            return found
        }
        // Photos may file the subtype a moment after import.
        var screenshot = asset(named: screenshotName)
        for _ in 0..<10 where screenshot?.mediaSubtypes.contains(.photoScreenshot) != true {
            try await Task.sleep(for: .seconds(1))
            screenshot = asset(named: screenshotName)
        }
        let shot = try #require(screenshot)
        print("PHOTOS-LIVE screenshot subtypes=\(shot.mediaSubtypes.rawValue) isScreenshot=\(shot.mediaSubtypes.contains(.photoScreenshot)) size=\(shot.pixelWidth)x\(shot.pixelHeight)")
        let tall = try #require(asset(named: tallName))
        print("PHOTOS-LIVE tall size=\(tall.pixelWidth)x\(tall.pixelHeight) isScreenshot=\(tall.mediaSubtypes.contains(.photoScreenshot))")
        #expect(tall.pixelHeight == 30_000 && tall.pixelWidth == 400)
        #expect(shot.mediaSubtypes.contains(.photoScreenshot))
        // Let the person running this find and delete them.
        print("PHOTOS-LIVE added \(screenshotName) and \(tallName) to the Cheese album")
    }
}
