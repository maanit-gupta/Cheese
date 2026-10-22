import CoreGraphics
import Foundation
import Testing
@testable import Cheese

/// Pixel access for rendered test images.
struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    /// RGBA at a top-left based pixel.
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<offset + 4])
    }
}

/// A white image with a black left half, for checking where things land.
func makeTestImage(width: Int = 200, height: Int = 100) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    return try #require(context.makeImage())
}

struct EditHistoryTests {
    @Test func undoRedo() {
        var history = EditHistory()
        history.apply { $0.annotations.append(.pixelate(.zero, blockSize: 1)) }
        history.apply { $0.crop = CGRect(x: 0, y: 0, width: 10, height: 10) }
        #expect(history.current.annotations.count == 1)
        #expect(history.current.crop != nil)

        history.undo()
        #expect(history.current.crop == nil)
        history.undo()
        #expect(history.current == EditorDocument())
        #expect(!history.canUndo)
        history.undo()
        #expect(history.current == EditorDocument())

        history.redo()
        history.redo()
        #expect(history.current.crop != nil)
        #expect(!history.canRedo)
    }

    @Test func newChangeClearsRedo() {
        var history = EditHistory()
        history.apply { $0.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
        history.undo()
        history.apply { $0.annotations.append(.pixelate(.zero, blockSize: 1)) }
        #expect(!history.canRedo)
    }

    @Test func noOpChangesAreNotRecorded() {
        var history = EditHistory()
        history.apply { $0.crop = nil }
        #expect(!history.canUndo)
    }
}

struct CanvasGeometryTests {
    @Test func fitsWithoutUpscaling() {
        let small = CanvasGeometry.fittedRect(imagePointSize: CGSize(width: 100, height: 50), in: CGSize(width: 400, height: 400))
        #expect(small == CGRect(x: 150, y: 175, width: 100, height: 50))
    }

    @Test func shrinksToFitPreservingAspect() {
        let large = CanvasGeometry.fittedRect(imagePointSize: CGSize(width: 1000, height: 500), in: CGSize(width: 500, height: 500))
        #expect(large == CGRect(x: 0, y: 125, width: 500, height: 250))
    }

    @Test func viewAndImagePointsRoundTrip() {
        let fitted = CGRect(x: 10, y: 20, width: 100, height: 50)
        let pixels = CGSize(width: 400, height: 200)
        let image = CanvasGeometry.imagePoint(fromView: CGPoint(x: 60, y: 45), fitted: fitted, imagePixelSize: pixels)
        #expect(image == CGPoint(x: 200, y: 100))
        #expect(image.applying(CanvasGeometry.imageToView(fitted: fitted, imagePixelSize: pixels)) == CGPoint(x: 60, y: 45))
    }

    @Test func dragRectIsNormalizedAndClamped() {
        let rect = CanvasGeometry.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: -10, y: 20), imagePixelSize: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: 0, y: 20, width: 50, height: 60))
    }
}

struct AnnotationRendererTests {
    @Test func noAnnotationsKeepsPixels() throws {
        let base = try makeTestImage()
        let rendered = try #require(AnnotationRenderer.render(base, document: EditorDocument(), applyCrop: true))
        let bitmap = Bitmap(rendered)
        #expect(bitmap.pixel(10, 10) == [0, 0, 0, 255])
        #expect(bitmap.pixel(190, 10) == [255, 255, 255, 255])
    }

    @Test func cropUsesTopLeftPixels() throws {
        let base = try makeTestImage()
        let document = EditorDocument(crop: CGRect(x: 90, y: 10, width: 20, height: 30))
        let cropped = try #require(AnnotationRenderer.render(base, document: document, applyCrop: true))
        #expect(cropped.width == 20)
        #expect(cropped.height == 30)
        let bitmap = Bitmap(cropped)
        #expect(bitmap.pixel(0, 0) == [0, 0, 0, 255])
        #expect(bitmap.pixel(19, 0) == [255, 255, 255, 255])

        let uncropped = try #require(AnnotationRenderer.render(base, document: document, applyCrop: false))
        #expect(uncropped.width == 200)
    }

    @Test func rectangleIsDrawnWhereTopLeftCoordinatesSay() throws {
        let base = try makeTestImage()
        let document = EditorDocument(annotations: [.rectangle(CGRect(x: 120, y: 10, width: 60, height: 40), color: .red, lineWidth: 4)])
        let bitmap = Bitmap(try #require(AnnotationRenderer.render(base, document: document, applyCrop: false)))
        let edge = bitmap.pixel(150, 10)
        #expect(edge[0] > 200 && edge[1] < 100)
        // The inside of the rectangle and the bottom of the image are untouched.
        #expect(bitmap.pixel(150, 30) == [255, 255, 255, 255])
        #expect(bitmap.pixel(150, 90) == [255, 255, 255, 255])
    }

    @Test func arrowReachesItsTip() throws {
        let base = try makeTestImage()
        let document = EditorDocument(annotations: [.arrow(from: CGPoint(x: 110, y: 80), to: CGPoint(x: 190, y: 20), color: .blue, lineWidth: 4)])
        let bitmap = Bitmap(try #require(AnnotationRenderer.render(base, document: document, applyCrop: false)))
        let nearTip = bitmap.pixel(186, 23)
        #expect(nearTip[2] > 200 && nearTip[0] < 100)
        #expect(bitmap.pixel(110, 20) == [255, 255, 255, 255])
    }

    @Test func pixelateReplacesDetailWithBlocks() throws {
        let base = try makeTestImage()
        // A region straddling the black/white edge becomes blocks; the edge column blurs into a uniform block.
        let rect = CGRect(x: 90, y: 0, width: 20, height: 20)
        let document = EditorDocument(annotations: [.pixelate(rect, blockSize: 20)])
        let bitmap = Bitmap(try #require(AnnotationRenderer.render(base, document: document, applyCrop: false)))
        let left = bitmap.pixel(92, 5)
        let right = bitmap.pixel(108, 5)
        #expect(left == right)
        #expect(left[0] > 40 && left[0] < 215)
        // Outside the region nothing changes.
        #expect(bitmap.pixel(80, 5) == [0, 0, 0, 255])
        #expect(bitmap.pixel(120, 5) == [255, 255, 255, 255])
    }

    @Test func textInksPixelsBelowItsOrigin() throws {
        let base = try makeTestImage()
        let document = EditorDocument(annotations: [.text("HELLO", at: CGPoint(x: 110, y: 30), color: .red, fontSize: 30)])
        let bitmap = Bitmap(try #require(AnnotationRenderer.render(base, document: document, applyCrop: false)))
        var inked = 0
        for y in 30..<62 {
            for x in 110..<200 where bitmap.pixel(x, y)[1] < 128 {
                inked += 1
            }
        }
        #expect(inked > 50)
        // Nothing above the origin.
        for x in 110..<200 {
            #expect(bitmap.pixel(x, 5) == [255, 255, 255, 255])
        }
    }

    @Test func highlighterTintsWithoutHiding() throws {
        let base = try makeTestImage()
        let stroke = Annotation.highlight(points: [CGPoint(x: 110, y: 50), CGPoint(x: 190, y: 50)], color: RGBAColor.yellow.withAlpha(0.4), lineWidth: 10)
        let bitmap = Bitmap(try #require(AnnotationRenderer.render(base, document: EditorDocument(annotations: [stroke]), applyCrop: false)))
        let tinted = bitmap.pixel(150, 50)
        #expect(tinted[0] > 200)
        #expect(tinted[2] < 230)
    }
}

@MainActor
struct EditorModelTests {
    private func model() throws -> EditorModel {
        EditorModel(image: CapturedImage(image: try makeTestImage(), scale: 1), saveFolder: { makeTemporaryDirectory() })
    }

    @Test func dragsMakeAnnotationsAndStrayClicksDont() throws {
        let model = try model()
        model.tool = .rectangle
        model.finishDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11), path: [])
        #expect(model.document.annotations.isEmpty)
        model.finishDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40), path: [])
        #expect(model.document.annotations == [.rectangle(CGRect(x: 10, y: 10, width: 50, height: 30), color: .red, lineWidth: 4)])
        model.undo()
        #expect(model.document.annotations.isEmpty)
        model.redo()
        #expect(model.document.annotations.count == 1)
    }

    @Test func textToolPlacesAndCommitsText() throws {
        let model = try model()
        model.tool = .text
        model.finishDrag(from: CGPoint(x: 5, y: 6), to: CGPoint(x: 5, y: 6), path: [])
        model.pendingText?.string = "  note "
        model.commitPendingText()
        #expect(model.document.annotations == [.text("note", at: CGPoint(x: 5, y: 6), color: .red, fontSize: 20)])
        // Empty text is dropped.
        model.finishDrag(from: .zero, to: .zero, path: [])
        model.commitPendingText()
        #expect(model.document.annotations.count == 1)
    }

    @Test func cropAndExport() async throws {
        let model = try model()
        model.tool = .crop
        model.finishDrag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 70), path: [])
        #expect(model.document.crop == CGRect(x: 20, y: 20, width: 100, height: 50))
        let exported = try #require(await model.export())
        #expect(exported.pixelSize == CGSize(width: 100, height: 50))
        model.resetCrop()
        #expect(model.document.crop == nil)
    }

    @Test func savesPNGIntoFolder() async throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(image: CapturedImage(image: try makeTestImage(), scale: 2), saveFolder: { folder })
        await model.save()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(files.count == 1)
        #expect(files.first?.hasPrefix("Cheese ") == true)
    }

    @Test func retinaImagesGetThickerMarks() throws {
        let model = EditorModel(image: CapturedImage(image: try makeTestImage(), scale: 2))
        #expect(model.lineWidth == 8)
        #expect(model.fontSize == 40)
    }
}
