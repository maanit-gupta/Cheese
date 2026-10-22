import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Cheese

struct ResizeMathTests {
    private let photo = PixelSize(width: 4000, height: 3000)

    @Test func percentageScalesBothSidesAndKeepsAtLeastOnePixel() {
        #expect(ResizeMath.target(for: photo, mode: .percentage, percent: 25) == PixelSize(width: 1000, height: 750))
        #expect(ResizeMath.target(for: PixelSize(width: 3, height: 1), mode: .percentage, percent: 10) == PixelSize(width: 1, height: 1))
    }

    @Test func maxSizeFitsWithinAndNeverEnlarges() {
        #expect(ResizeMath.target(for: photo, mode: .maxSize, maxWidth: 1920, maxHeight: 1920) == PixelSize(width: 1920, height: 1440))
        #expect(ResizeMath.target(for: photo, mode: .maxSize, maxWidth: 0, maxHeight: 600) == PixelSize(width: 800, height: 600))
        let small = PixelSize(width: 300, height: 200)
        #expect(ResizeMath.target(for: small, mode: .maxSize, maxWidth: 1920, maxHeight: 1080) == small)
    }

    @Test func exactSizeWithAndWithoutAspectLock() {
        #expect(ResizeMath.target(for: photo, mode: .exact, width: 1000, height: 1000, lockAspect: true) == PixelSize(width: 1000, height: 750))
        #expect(ResizeMath.target(for: photo, mode: .exact, width: 1000, height: 1000, lockAspect: false) == PixelSize(width: 1000, height: 1000))
        #expect(ResizeMath.lockedHeight(forWidth: 800, original: photo) == 600)
    }
}

struct ImagePageLayoutTests {
    @Test func fitToImageAddsMargins() {
        let result = ImagePageLayout.layout(imageSize: CGSize(width: 400, height: 300), pageSize: .fitToImage, margin: .small)
        #expect(result.page == CGSize(width: 436, height: 336))
        #expect(result.imageRect == CGRect(x: 18, y: 18, width: 400, height: 300))
    }

    @Test func fixedSizesTurnLandscapeForWideImagesAndCenter() {
        let result = ImagePageLayout.layout(imageSize: CGSize(width: 1000, height: 500), pageSize: .letter, margin: .none)
        #expect(result.page == CGSize(width: 792, height: 612))
        #expect(result.imageRect.width == 792)
        #expect(result.imageRect.midY == 306)
        let portrait = ImagePageLayout.layout(imageSize: CGSize(width: 100, height: 200), pageSize: .a4, margin: .normal)
        #expect(portrait.page.height > portrait.page.width)
        #expect(abs(portrait.imageRect.height - (841.89 - 72)) < 0.01)
    }

    @Test func hugeImagesStayWithinThePDFLimit() {
        let result = ImagePageLayout.layout(imageSize: CGSize(width: 30_000, height: 10_000), pageSize: .fitToImage, margin: .none)
        #expect(result.page.width == ImagePageLayout.maxPageSide)
        #expect(result.page.height == 4_800)
    }
}

@MainActor
struct ImageToolTests {
    private func photo(named name: String = "Photo.jpg", orientation: Int = 1, gps: Bool = false) throws -> URL {
        let url = makeTemporaryDirectory().appending(path: name)
        let image = try #require(FileFixtures.halfTransparentImage(width: 400, height: 200))
        let type: UTType = name.hasSuffix(".png") ? .png : .jpeg
        #expect(FileFixtures.write(image, to: url, type: type, orientation: orientation, gps: gps))
        return url
    }

    @Test func resizeIsUprightAndKeepsTheFormat() async throws {
        let input = try photo(orientation: 6)
        let options = ResizeImageTool.Options(mode: .percentage, percent: 50)
        let report = try await runJob(ResizeImageTool().work(inputs: [input], options: options))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Photo (resized).jpg")
        let properties = FileFixtures.properties(of: output)
        // 400×200 rotated by the EXIF tag is 200×400 upright; half of that is 100×200.
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 200)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 1)
    }

    @Test func compressStripsLocationAndReportsSizes() async throws {
        let input = try photo(gps: true)
        let report = try await runJob(CompressImageTool().work(inputs: [input], options: .init(quality: 0.1, stripMetadata: true)))
        if let output = report.outputs.first {
            let properties = FileFixtures.properties(of: output)
            #expect(properties[kCGImagePropertyGPSDictionary] == nil)
            #expect(report.notes.first?.contains("→") == true)
        } else {
            // A tiny test image may not shrink; then the original is kept and the note says so.
            #expect(report.notes.first?.contains("kept the original") == true)
        }
    }

    @Test func compressKeepsTheOriginalWhenTheResultIsBigger() async throws {
        let input = try photo()
        let report = try await runJob(CompressImageTool().work(inputs: [input], options: .init(quality: 1, stripMetadata: false)))
        #expect(report.outputs.isEmpty)
        #expect(report.notes == ["Photo.jpg is already as small as it gets; kept the original."])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: input.deletingLastPathComponent().path(percentEncoded: false))
        #expect(leftovers == ["Photo.jpg"])
    }

    @Test func removeBackgroundWritesNothingWithoutASubject() async throws {
        let input = makeTemporaryDirectory().appending(path: "Blank.png")
        try TestImages.encoded(width: 64, height: 64, gray: 200).write(to: input)
        let report = try await runJob(RemoveBackgroundTool().work(inputs: [input], options: NoOptions()))
        #expect(report.outputs.isEmpty)
        #expect(report.failures.count == 1)
    }

    @Test func imagesToPDFMakesOneUprightPagePerImage() async throws {
        let first = try photo(named: "Scan.jpg", orientation: 6)
        let second = first.deletingLastPathComponent().appending(path: "Logo.png")
        let image = try #require(FileFixtures.halfTransparentImage(width: 100, height: 50))
        FileFixtures.write(image, to: second, type: .png)

        let report = try await runJob(ImagesToPDFTool().work(inputs: [first, second], options: .init(pageSize: .fitToImage, margin: .none)))
        let output = try #require(report.outputs.first)
        #expect(output.lastPathComponent == "Scan.pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 200, height: 400))
        #expect(document.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 100, height: 50))
    }

    @Test func pdfToImagesRendersChosenPagesIntoAFolder() async throws {
        let input = TestPDFs.write(pages: 3, to: makeTemporaryDirectory().appending(path: "Report.pdf"))
        let report = try await runJob(PDFToImagesTool().work(inputs: [input], options: .init(format: .png, dpi: 72, pages: "1, 3")))
        let folder = try #require(report.outputs.first)
        #expect(folder.lastPathComponent == "Report (images)")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(files == ["Report-001.png", "Report-003.png"])
        let properties = FileFixtures.properties(of: folder.appending(path: "Report-001.png"))
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 612)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 792)
    }

    @Test func pageNumbersDefaultToAllAndDropRepeats() throws {
        #expect(try PDFToImagesTool.pageNumbers("", pageCount: 3) == [1, 2, 3])
        #expect(try PDFToImagesTool.pageNumbers("2-3, 2", pageCount: 3) == [2, 3])
    }
}
