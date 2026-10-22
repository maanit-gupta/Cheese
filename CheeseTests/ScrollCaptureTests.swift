import CoreGraphics
import Foundation
import Testing
@testable import Cheese

/// A page behind a viewport with a sticky header and footer, built from the fixtures. Scrolling moves the
/// viewport; capturing renders it. Stands in for both the screen and the scroll wheel.
@MainActor
private final class SimulatedPage: RegionCapturing, ScrollPerforming {
    let scale: CGFloat = 1
    private let page: ImageBuffer
    private let header: ArraySlice<UInt8>
    private let footer: ArraySlice<UInt8>
    private let contentHeight = 608
    private(set) var offset: Int
    /// Simulates "natural" scrolling inverting synthesized events.
    var invertsScrolling = false
    private(set) var captures = 0
    private(set) var pointer: CGPoint?

    init(startingAt offset: Int = 0) throws {
        page = try Fixtures.image("scroll-page")
        let frame = try Fixtures.image("scroll-frame-0")
        header = frame.bytes(ofRows: 0..<Fixtures.headerHeight)
        footer = frame.bytes(ofRows: frame.height - Fixtures.footerHeight ..< frame.height)
        self.offset = offset
    }

    var maxOffset: Int { page.height - contentHeight }

    func capture() async throws -> CGImage {
        captures += 1
        var pixels = Array(header)
        pixels.append(contentsOf: page.bytes(ofRows: offset ..< offset + contentHeight))
        pixels.append(contentsOf: footer)
        guard let image = ImageBuffer(width: page.width, height: 700, pixels: pixels)?.makeCGImage() else {
            throw CaptureError.displayNotFound
        }
        return image
    }

    func movePointer(to point: CGPoint) {
        pointer = point
    }

    func scroll(by points: Int32, at point: CGPoint) async {
        let delta = Int(points) * (invertsScrolling ? -1 : 1)
        offset = min(max(offset + delta, 0), maxOffset)
    }
}

@MainActor
struct ScrollCaptureSessionTests {
    private let region = CGRect(x: 100, y: 100, width: 480, height: 700)
    private var settings: ScrollCaptureSession.Settings {
        var settings = ScrollCaptureSession.Settings()
        settings.settleDelay = .zero
        settings.showsHUD = false
        return settings
    }

    @Test func capturesWholePageAndStopsAtTheEnd() async throws {
        let page = try SimulatedPage()
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, settings: settings)
        let result = try #require(await session.run())
        let expected = try Fixtures.image("scroll-expected")
        let stitched = try #require(ImageBuffer(result.image))
        #expect(stitched.height == expected.height)
        #expect(stitched.pixels == expected.pixels)
        #expect(result.scale == 1)
        #expect(page.offset == page.maxOffset)
        #expect(page.pointer != nil)
    }

    @Test func handlesInvertedScrollDirection() async throws {
        let page = try SimulatedPage(startingAt: 600)
        page.invertsScrolling = true
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, settings: settings)
        let result = try #require(await session.run())
        // The first (wrong-way) scroll moved up by 315 rows; the capture restarts there and runs to the end.
        let expectedHeight = Fixtures.headerHeight + (2400 - 285) + Fixtures.footerHeight
        #expect(result.image.height == expectedHeight)
        #expect(page.offset == page.maxOffset)
    }

    @Test func respectsMaximumHeight() async throws {
        let page = try SimulatedPage()
        var settings = settings
        settings.maxHeight = 1200
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, settings: settings)
        let result = try #require(await session.run())
        #expect(result.image.height == 1200)
        #expect(page.offset < page.maxOffset)
    }

    @Test func pageThatDoesntScrollGivesOneFrame() async throws {
        let page = try SimulatedPage(startingAt: 1792)
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, settings: settings)
        let result = try #require(await session.run())
        #expect(result.image.height == 700)
    }

    @Test func stopEndsEarly() async throws {
        let page = try SimulatedPage()
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, settings: settings)
        session.stop()
        let result = try #require(await session.run())
        #expect(result.image.height == 700)
        #expect(page.offset == 0)
    }
}

struct StitchWorkerTests {
    @Test func stitchesFixtureFramesLikeTheStitcher() async throws {
        let frames = try Fixtures.frames()
        let worker = StitchWorker(maxHeight: 30_000)
        let first = try #require(frames[0].makeCGImage())
        #expect(await worker.begin(with: first))
        var outcomes: [StitchWorker.Outcome] = []
        for frame in frames.dropFirst() {
            outcomes.append(await worker.add(try #require(frame.makeCGImage())))
        }
        #expect(outcomes.last == .stitched(.noMovement))
        let image = try #require(await worker.finish())
        let expected = try Fixtures.image("scroll-expected")
        #expect(try #require(ImageBuffer(image)).pixels == expected.pixels)
    }

    @Test func detectsScrollingTheWrongWay() async throws {
        let frames = try Fixtures.frames()
        let worker = StitchWorker(maxHeight: 30_000)
        #expect(await worker.begin(with: try #require(frames[3].makeCGImage())))
        #expect(await worker.add(try #require(frames[2].makeCGImage())) == .reversed)
        #expect(await worker.height == 700)
    }

    @Test func settledFramesMatch() throws {
        let frames = try Fixtures.frames()
        let a = try #require(frames[5].makeCGImage())
        let b = try #require(frames[6].makeCGImage())
        let c = try #require(frames[4].makeCGImage())
        #expect(StitchWorker.framesMatch(a, b))
        #expect(!StitchWorker.framesMatch(a, c))
    }
}

struct ImageTilingTests {
    @Test func shortImagesAreOneTile() {
        #expect(ImageTiling.tileRanges(uniformRows: [Bool](repeating: false, count: 100), maxTileHeight: 200) == [0..<100])
        #expect(ImageTiling.tileRanges(uniformRows: [], maxTileHeight: 200).isEmpty)
    }

    @Test func cutsOnBlankRowsNearTheLimit() {
        var rows = [Bool](repeating: false, count: 1000)
        rows[350] = true
        rows[380] = true
        let ranges = ImageTiling.tileRanges(uniformRows: rows, maxTileHeight: 400, searchWindow: 100)
        #expect(ranges.first == 0..<380)
        #expect(ranges.map(\.count).reduce(0, +) == 1000)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func hardCutWithoutBlankRows() {
        let ranges = ImageTiling.tileRanges(uniformRows: [Bool](repeating: false, count: 1000), maxTileHeight: 400, searchWindow: 100)
        #expect(ranges == [0..<400, 400..<800, 800..<1000])
    }

    @Test func tilesTallImages() async throws {
        let page = try Fixtures.image("scroll-expected")
        let tall = try #require(ImageBuffer(width: page.width, height: page.height * 2, pixels: page.pixels + page.pixels))
        let tiles = await ImageTiling.tiles(of: try #require(tall.makeCGImage()))
        #expect(tiles.count >= 3)
        #expect(tiles.map(\.height).reduce(0, +) == tall.height)
        #expect(tiles.allSatisfy { $0.height <= ImageTiling.maxTileHeight })
    }
}

struct DisplayLocalRectTests {
    @Test func convertsToTopLeftWithinDisplay() {
        let display = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        let rect = CGRect(x: -1820, y: 1680, width: 400, height: 200)
        #expect(DisplayGeometry.displayLocalRect(fromAppKit: rect, displayFrame: display) == CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    @Test func primaryDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(DisplayGeometry.displayLocalRect(fromAppKit: rect, displayFrame: display) == CGRect(x: 0, y: 890, width: 10, height: 10))
    }
}
