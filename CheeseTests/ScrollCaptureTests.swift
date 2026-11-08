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
    /// Where the user has scrolled by each capture, for capturing by hand. Used up in order.
    var script: [Int] = []
    /// Called on every capture once the script is used up, with how many captures that's been.
    var afterScript: ((Int) -> Void)?
    private var capturesAfterScript = 0

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
        if !script.isEmpty {
            offset = min(max(script.removeFirst(), 0), maxOffset)
        } else if let afterScript {
            capturesAfterScript += 1
            afterScript(capturesAfterScript)
        }
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
    /// Auto-scroll that finishes at the end of the page, as scrolling capture worked before Done.
    private var settings: ScrollCaptureSession.Settings {
        var settings = ScrollCaptureSession.Settings()
        settings.settleDelay = .zero
        settings.pollInterval = .zero
        settings.finishesAtPageEnd = true
        settings.showsHUD = false
        return settings
    }

    private var manualSettings: ScrollCaptureSession.Settings {
        var settings = settings
        settings.finishesAtPageEnd = false
        return settings
    }

    private func autoSession(_ page: SimulatedPage, settings: ScrollCaptureSession.Settings? = nil) -> ScrollCaptureSession {
        ScrollCaptureSession(region: region, capturer: page, scroller: page, autoScroll: true, settings: settings ?? self.settings)
    }

    /// The user scrolls through `offsets`, then clicks Done.
    private func manualSession(_ page: SimulatedPage, offsets: [Int]) -> ScrollCaptureSession {
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, autoScroll: false, settings: manualSettings)
        page.script = offsets
        page.afterScript = { [weak session] _ in session?.finish() }
        return session
    }

    @Test func scrollingByHandStitchesTheWholePageAndWaitsForDone() async throws {
        let page = try SimulatedPage()
        // Uneven steps, pauses, and a scroll back up that's ignored.
        let session = manualSession(page, offsets: [0, 0, 0, 150, 150, 420, 400, 300, 300, 700, 1100, 1100, 1500, 1792, 1792, 1792, 1792])
        let result = try #require(await session.run())
        let expected = try Fixtures.image("scroll-expected")
        let stitched = try #require(ImageBuffer(result.image))
        #expect(stitched.height == expected.height)
        #expect(stitched.pixels == expected.pixels)
        // Never scrolled for the user, never moved the pointer.
        #expect(page.pointer == nil)
        #expect(session.ending == .done)
    }

    @Test func aJumpPastTheOverlapIsSkippedUntilTheUserScrollsBack() async throws {
        let page = try SimulatedPage()
        let session = manualSession(page, offsets: [0, 0, 1000, 1000, 1000, 1000, 400])
        let result = try #require(await session.run())
        #expect(result.image.height == Fixtures.headerHeight + 400 + 608 + Fixtures.footerHeight)
    }

    @Test func cancelThrowsTheCaptureAway() async throws {
        let page = try SimulatedPage()
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, autoScroll: false, settings: manualSettings)
        page.script = [0, 0, 300]
        page.afterScript = { [weak session] _ in session?.cancel() }
        #expect(await session.run() == nil)
        #expect(session.ending == .cancelled)
    }

    @Test func autoScrollWaitsForDoneAtTheEndOfThePage() async throws {
        let page = try SimulatedPage()
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, autoScroll: true, settings: manualSettings)
        page.afterScript = { [weak session, weak page] count in
            // Still looking a while after the end: only Done finishes it.
            if let page, page.offset == page.maxOffset, count > 40 { session?.finish() }
        }
        let result = try #require(await session.run())
        let expected = try Fixtures.image("scroll-expected")
        #expect(result.image.height == expected.height)
        #expect(page.captures > 40)
    }

    @Test func turningAutoScrollOnPartWayScrollsTheRest() async throws {
        let page = try SimulatedPage()
        let session = ScrollCaptureSession(region: region, capturer: page, scroller: page, autoScroll: false, settings: settings)
        page.script = [0, 0, 300, 600]
        page.afterScript = { [weak session] count in
            if count == 1 { session?.setAutoScroll(true) }
        }
        let result = try #require(await session.run())
        #expect(result.image.height == (try Fixtures.image("scroll-expected")).height)
        #expect(page.pointer != nil)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.scrollCaptureAutoScroll)
    }

    @Test func capturesWholePageAndStopsAtTheEnd() async throws {
        let page = try SimulatedPage()
        let session = autoSession(page, settings: settings)
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
        let session = autoSession(page, settings: settings)
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
        let session = autoSession(page, settings: settings)
        let result = try #require(await session.run())
        #expect(result.image.height == 1200)
        #expect(page.offset < page.maxOffset)
    }

    @Test func pageThatDoesntScrollGivesOneFrame() async throws {
        let page = try SimulatedPage(startingAt: 1792)
        let session = autoSession(page, settings: settings)
        let result = try #require(await session.run())
        #expect(result.image.height == 700)
    }

    @Test func stopEndsEarly() async throws {
        let page = try SimulatedPage()
        let session = autoSession(page, settings: settings)
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

    @Test func scrollingBackUpIsBehindAndThenCarriesOn() async throws {
        let frames = try Fixtures.frames()
        let worker = StitchWorker(maxHeight: 30_000)
        #expect(await worker.begin(with: try #require(frames[0].makeCGImage())))
        #expect(await worker.add(try #require(frames[1].makeCGImage())) == .stitched(.appended(rows: 400)))
        #expect(await worker.add(try #require(frames[2].makeCGImage())) == .stitched(.appended(rows: 400)))
        #expect(await worker.add(try #require(frames[1].makeCGImage())) == .behind)
        #expect(await worker.add(try #require(frames[0].makeCGImage())) == .stitched(.unmatched))
        #expect(await worker.add(try #require(frames[3].makeCGImage())) == .stitched(.appended(rows: 400)))
    }

    @Test func thumbnailGrowsWithTheStitch() async throws {
        let frames = try Fixtures.frames()
        let worker = StitchWorker(maxHeight: 30_000, thumbnailWidth: 48)
        #expect(await worker.begin(with: try #require(frames[0].makeCGImage())))
        let first = try #require(await worker.thumbnailImage())
        _ = await worker.add(try #require(frames[1].makeCGImage()))
        _ = await worker.add(try #require(frames[2].makeCGImage()))
        let later = try #require(await worker.thumbnailImage())
        #expect(later.width == first.width)
        #expect(later.width <= 48)
        #expect(later.height > first.height)
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
