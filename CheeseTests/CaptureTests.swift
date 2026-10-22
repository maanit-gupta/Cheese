import AppKit
import ImageIO
import KeyboardShortcuts
import Testing
@testable import Cheese

struct PixelRectTests {
    @Test func retinaSelectionMapsToDoublePixelsWithFlippedY() {
        // A 100×50 pt view showing a 200×100 px image; the selection sits in the view's top-left corner.
        let rect = DisplayGeometry.pixelRect(
            forViewRect: CGRect(x: 0, y: 30, width: 40, height: 20),
            viewSize: CGSize(width: 100, height: 50),
            imagePixelSize: CGSize(width: 200, height: 100)
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 80, height: 40))
    }

    @Test func fractionalPointsRoundOutwardToWholePixels() {
        let rect = DisplayGeometry.pixelRect(
            forViewRect: CGRect(x: 10.3, y: 10.3, width: 5.2, height: 5.2),
            viewSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 100, height: 100)
        )
        #expect(rect == CGRect(x: 10, y: 84, width: 6, height: 6))
    }

    @Test func clampsToImage() {
        let rect = DisplayGeometry.pixelRect(
            forViewRect: CGRect(x: -10, y: -10, width: 200, height: 200),
            viewSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 150, height: 150)
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 150, height: 150))
    }

    @Test func emptyViewGivesNull() {
        let rect = DisplayGeometry.pixelRect(forViewRect: .zero, viewSize: .zero, imagePixelSize: CGSize(width: 1, height: 1))
        #expect(rect.isNull)
    }
}

struct DisplaySnapshotTests {
    private func snapshot(frame: CGRect, scale: CGFloat) throws -> DisplaySnapshot {
        let width = Int(frame.width * scale)
        let height = Int(frame.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        return DisplaySnapshot(displayID: 1, frame: frame, captured: CapturedImage(image: image, scale: scale))
    }

    @Test func cropsAtNativeResolutionOnSecondaryDisplay() throws {
        // A Retina display to the left of the primary one.
        let display = try snapshot(frame: CGRect(x: -1440, y: 0, width: 1440, height: 900), scale: 2)
        let cropped = try #require(display.crop(to: CGRect(x: -1440 + 100, y: 900 - 250, width: 300, height: 150)))
        #expect(cropped.pixelSize == CGSize(width: 600, height: 300))
        #expect(cropped.scale == 2)
        #expect(cropped.pointSize == CGSize(width: 300, height: 150))
    }

    @Test func cropOutsideDisplayIsNil() throws {
        let display = try snapshot(frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
        #expect(display.crop(to: CGRect(x: 500, y: 500, width: 10, height: 10)) == nil)
    }
}

struct ScreenshotNamingTests {
    private let utc = TimeZone(identifier: "UTC") ?? .gmt
    // 2026-03-07 09:05:02 UTC
    private let date = Date(timeIntervalSince1970: 1_772_874_302)

    @Test func matchesSpecFormat() {
        #expect(ScreenshotNaming.baseName(for: date, timeZone: utc) == "Cheese 2026-03-07 at 09.05.02")
    }

    @Test func avoidsOverwritingWithinTheSameSecond() {
        let folder = URL(filePath: "/tmp/shots", directoryHint: .isDirectory)
        let taken: Set<String> = ["Cheese 2026-03-07 at 09.05.02.png", "Cheese 2026-03-07 at 09.05.02 (2).png"]
        let url = ScreenshotNaming.uniqueURL(in: folder, date: date, timeZone: utc) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Cheese 2026-03-07 at 09.05.02 (3).png")
        #expect(url.deletingLastPathComponent().path(percentEncoded: false) == "/tmp/shots/")
    }
}

struct ImageExportTests {
    @Test func pngKeepsPixelsAndRecordsRetinaDPI() throws {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let png = try ImageExport.pngData(for: CapturedImage(image: image, scale: 2))

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties["PixelWidth"] as? Int == 40)
        #expect(properties["PixelHeight"] as? Int == 20)
        #expect((properties["DPIWidth"] as? Double).map { Int($0.rounded()) } == 144)
    }

    @Test func savesIntoFolderWithTimestampedName() async throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let captured = CapturedImage(image: try #require(context.makeImage()), scale: 1)
        let date = Date()
        let first = try await ImageExport.save(captured, in: folder, date: date)
        let second = try await ImageExport.save(captured, in: folder, date: date)
        #expect(first.lastPathComponent.hasPrefix("Cheese "))
        #expect(first.pathExtension == "png")
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
    }
}

struct WindowPickerTests {
    @Test func picksFrontmostWindowUnderPoint() {
        let front = PickableWindow(windowID: 1, frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let back = PickableWindow(windowID: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(WindowPicker.window(at: CGPoint(x: 150, y: 150), in: [front, back]) == front)
        #expect(WindowPicker.window(at: CGPoint(x: 20, y: 20), in: [front, back]) == back)
        #expect(WindowPicker.window(at: CGPoint(x: 900, y: 900), in: [front, back]) == nil)
    }
}

struct EditorShortcutVariantTests {
    @Test func addsShift() {
        let base = KeyboardShortcuts.Shortcut(.three, modifiers: [.control, .option])
        #expect(EditorShortcutVariant.shiftVariant(of: base) == .init(.three, modifiers: [.control, .option, .shift]))
    }

    @Test func noVariantWhenUnboundOrAlreadyShifted() {
        #expect(EditorShortcutVariant.shiftVariant(of: nil) == nil)
        #expect(EditorShortcutVariant.shiftVariant(of: .init(.three, modifiers: [.command, .shift])) == nil)
    }
}
