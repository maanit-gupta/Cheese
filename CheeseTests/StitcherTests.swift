import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Cheese

/// Loads the fixtures made by `Design/make-scroll-fixtures.swift`.
enum Fixtures {
    private final class BundleToken {}

    static let frameCount = 7
    static let headerHeight = 56
    static let footerHeight = 36
    static let offsets = [0, 400, 800, 1200, 1600, 1792, 1792]

    static func image(_ name: String) throws -> ImageBuffer {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "png", subdirectory: "Fixtures"),
            "Missing fixture \(name).png"
        )
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(ImageBuffer(image))
    }

    static func frames() throws -> [ImageBuffer] {
        try (0..<frameCount).map { try image("scroll-frame-\($0)") }
    }
}

/// Builds frames by slicing a page, optionally with solid header and footer bars.
private func slice(_ page: ImageBuffer, offsets: [Int], height: Int, header: Int = 0, footer: Int = 0) throws -> [ImageBuffer] {
    try offsets.map { offset in
        var pixels: [UInt8] = []
        pixels.append(contentsOf: [UInt8](repeating: 40, count: header * page.bytesPerRow))
        pixels.append(contentsOf: page.bytes(ofRows: offset ..< offset + height - header - footer))
        pixels.append(contentsOf: [UInt8](repeating: 200, count: footer * page.bytesPerRow))
        return try #require(ImageBuffer(width: page.width, height: height, pixels: pixels))
    }
}

struct RowSignatureTests {
    @Test func equalRowsEqualSignaturesAndUniformDetection() throws {
        // Rows: solid gray, solid gray, two-color, the two colors swapped.
        let a: [UInt8] = [10, 20, 30, 255]
        let b: [UInt8] = [30, 20, 10, 255]
        let pixels = a + a + a + a + a + b + b + a
        let buffer = try #require(ImageBuffer(width: 2, height: 4, pixels: pixels))
        let signatures = buffer.rowSignatures()
        #expect(signatures[0] == signatures[1])
        #expect(signatures[0].isUniform)
        #expect(!signatures[2].isUniform)
        #expect(signatures[2] != signatures[3])
        #expect(signatures[2].sum == signatures[3].sum)
    }

    @Test func rangeOfRows() throws {
        let page = try Fixtures.image("scroll-page")
        let all = page.rowSignatures()
        #expect(page.rowSignatures(100..<150) == Array(all[100..<150]))
        #expect(page.rowSignatures(0..<0).isEmpty)
    }
}

struct StickyRegionDetectorTests {
    @Test func findsHeaderAndFooterInFixtures() throws {
        let sticky = StickyRegionDetector.detect(try Fixtures.frames())
        // Rows just below the header/above the footer can be blank in every frame, so allow a few extra.
        #expect(sticky.top >= Fixtures.headerHeight && sticky.top < Fixtures.headerHeight + 12)
        #expect(sticky.bottom >= Fixtures.footerHeight && sticky.bottom < Fixtures.footerHeight + 12)
    }

    @Test func noStickyRowsWhenEverythingScrolls() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [3, 301, 650], height: 500)
        let sticky = StickyRegionDetector.detect(frames)
        #expect(sticky.top < 8)
        #expect(sticky.bottom < 8)
    }

    @Test func identicalFramesSayNothing() throws {
        let frame = try Fixtures.image("scroll-frame-0")
        #expect(StickyRegionDetector.detect([frame, frame]) == .none)
        #expect(StickyRegionDetector.detect([frame]) == .none)
    }

    @Test func bandsAreCappedToLeaveContent() {
        let still = RowSignature(sum: 1, weighted: 1, isUniform: false)
        let a = [RowSignature](repeating: still, count: 100)
        var b = a
        b[50] = RowSignature(sum: 2, weighted: 2, isUniform: false)
        let sticky = StickyRegionDetector.detect(signatures: [a, b])
        #expect(sticky.top <= 40 && sticky.bottom <= 40)
        #expect(100 - sticky.top - sticky.bottom >= StickyRegionDetector.minimumContentRows)
    }

    @Test func mismatchedSizesGiveNone() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [0], height: 300) + slice(page, offsets: [0], height: 200)
        #expect(StickyRegionDetector.detect(frames) == .none)
    }
}

struct StitcherOffsetTests {
    @Test func findsFixtureOffsets() throws {
        let frames = try Fixtures.frames()
        let sticky = StickyRegion(top: Fixtures.headerHeight, bottom: Fixtures.footerHeight)
        let rows = sticky.contentRows(height: frames[0].height)
        for index in 1..<frames.count {
            let offset = Stitcher.offset(previous: frames[index - 1].rowSignatures(rows), next: frames[index].rowSignatures(rows))
            #expect(offset == Fixtures.offsets[index] - Fixtures.offsets[index - 1], "frame \(index)")
        }
    }

    @Test func noOverlapIsNil() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [0, 1200], height: 400)
        #expect(Stitcher.offset(previous: frames[0].rowSignatures(), next: frames[1].rowSignatures()) == nil)
    }

    @Test func blankContentIsNil() throws {
        let blank = try #require(ImageBuffer(width: 10, height: 50, pixels: [UInt8](repeating: 255, count: 10 * 50 * 4)))
        var other = [UInt8](repeating: 255, count: 10 * 50 * 4)
        other[0] = 0
        let changed = try #require(ImageBuffer(width: 10, height: 50, pixels: other))
        // Identical blank frames: no movement. A changed pixel with no distinctive rows: nothing to match.
        #expect(Stitcher.offset(previous: blank.rowSignatures(), next: blank.rowSignatures()) == 0)
        #expect(Stitcher.offset(previous: changed.rowSignatures(), next: blank.rowSignatures()) == 0)
    }

    @Test func smallStepsAndOneRowSteps() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [500, 501, 537], height: 300)
        #expect(Stitcher.offset(previous: frames[0].rowSignatures(), next: frames[1].rowSignatures()) == 1)
        #expect(Stitcher.offset(previous: frames[1].rowSignatures(), next: frames[2].rowSignatures()) == 36)
    }
}

struct StitcherTests {
    @Test func stitchesFixturesIntoExpectedImage() throws {
        let result = try #require(Stitcher.stitch(try Fixtures.frames(), maxHeight: 30_000))
        let expected = try Fixtures.image("scroll-expected")
        #expect(result.image.width == expected.width)
        #expect(result.image.height == expected.height)
        #expect(result.image.pixels == expected.pixels)
        #expect(result.outcomes == [
            .appended(rows: 400), .appended(rows: 400), .appended(rows: 400), .appended(rows: 400),
            .appended(rows: 192), .noMovement,
        ])
    }

    @Test func stitchesWithoutStickyBands() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [0, 350, 700, 1000], height: 500)
        let result = try #require(Stitcher.stitch(frames, maxHeight: 30_000))
        let expected = try #require(page.rows(0..<1500))
        #expect(result.image.height == 1500)
        #expect(result.image.pixels == expected.pixels)
    }

    @Test func enforcesMaximumHeight() throws {
        let frames = try Fixtures.frames()
        let result = try #require(Stitcher.stitch(frames, maxHeight: 1000))
        #expect(result.image.height == 1000)
        #expect(result.outcomes.last == .limitReached)
        // The footer is still at the bottom.
        let expected = try Fixtures.image("scroll-expected")
        let footer = Fixtures.footerHeight
        #expect(Array(result.image.bytes(ofRows: 1000 - footer ..< 1000)) == Array(expected.bytes(ofRows: expected.height - footer ..< expected.height)))
    }

    @Test func skipsAnUnmatchableFrameAndContinues() throws {
        let page = try Fixtures.image("scroll-page")
        var frames = try slice(page, offsets: [0, 300, 600], height: 500)
        let noise = try #require(ImageBuffer(width: page.width, height: 500, pixels: (0..<(page.width * 500 * 4)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) }))
        frames.insert(noise, at: 2)
        let result = try #require(Stitcher.stitch(frames, maxHeight: 30_000))
        #expect(result.outcomes == [.appended(rows: 300), .unmatched, .appended(rows: 300)])
        #expect(result.image.pixels == (try #require(page.rows(0..<1100))).pixels)
    }

    @Test func usesFallbackOnlyWhenRowsDontMatch() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [0, 1200], height: 400)
        // A fallback that claims an implausible offset is rejected by verification.
        let lying: StitchProgress.OffsetFallback = { _, _, _ in 100 }
        let result = try #require(Stitcher.stitch(frames, maxHeight: 30_000, fallback: lying))
        #expect(result.outcomes == [.unmatched])
    }

    @Test func visionRegistrationFindsTheScrollOffset() throws {
        let page = try Fixtures.image("scroll-page")
        let frames = try slice(page, offsets: [200, 440], height: 500)
        let offset = VisionRegistration.offset(previous: frames[0], next: frames[1], sticky: .none)
        #expect(offset == 240)
    }

    @Test func roundTripsThroughCGImage() throws {
        let frame = try Fixtures.image("scroll-frame-3")
        let image = try #require(frame.makeCGImage())
        #expect(try #require(ImageBuffer(image)).pixels == frame.pixels)
    }
}
