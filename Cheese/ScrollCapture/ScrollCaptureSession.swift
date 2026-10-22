import AppKit
import os

/// One scrolling capture: scroll, capture, stitch, repeat until the page ends, the user stops, or the
/// image reaches its maximum height.
@MainActor
final class ScrollCaptureSession {
    struct Settings {
        /// Tallest output image, to protect memory.
        var maxHeight = 30_000
        /// Each scroll moves this share of the region, leaving plenty of overlap to match.
        var stepFraction = 0.45
        /// Wait after scrolling before the first capture.
        var settleDelay = Duration.milliseconds(90)
        /// Captures taken while waiting for animated scrolling to stop.
        var maxSettleCaptures = 6
        var maxFrames = 400
        /// Consecutive frames that can't be matched before giving up.
        var maxUnmatched = 3
        /// The border and Stop panel; off in tests.
        var showsHUD = true
    }

    /// AppKit global points.
    let region: CGRect
    private let settings: Settings
    private let capturer: any RegionCapturing
    private let scroller: any ScrollPerforming
    private var hud: ScrollCaptureHUD?
    private(set) var isStopped = false

    init(
        region: CGRect,
        capturer: any RegionCapturing,
        scroller: any ScrollPerforming = AutoScroller(),
        settings: Settings = Settings()
    ) {
        self.region = region
        self.capturer = capturer
        self.scroller = scroller
        self.settings = settings
    }

    /// Ends the capture after the current frame, keeping what's been stitched.
    func stop() {
        isStopped = true
    }

    /// Runs until done. Returns nil only if not even the first frame could be captured.
    func run() async -> CapturedImage? {
        if settings.showsHUD {
            let hud = ScrollCaptureHUD(region: region) { [weak self] in self?.stop() }
            self.hud = hud
            hud.show()
        }
        defer {
            hud?.close()
            hud = nil
        }

        let quartzRegion = Screens.quartzRect(fromAppKit: region)
        let center = CGPoint(x: quartzRegion.midX, y: quartzRegion.midY)
        scroller.movePointer(to: center)

        let worker = StitchWorker(maxHeight: settings.maxHeight)
        guard let first = await settledCapture(after: nil), await worker.begin(with: first) else {
            CheeseToast.show("Couldn't capture the region", systemImage: "exclamationmark.triangle.fill")
            return nil
        }

        let step = Int32(max((region.height * settings.stepFraction).rounded(), 20))
        var direction: Int32 = 1
        var hasMoved = false
        var unmatched = 0
        var previous = first

        frames: for _ in 0..<settings.maxFrames where !isStopped {
            await scroller.scroll(by: step * direction, at: center)
            guard !isStopped, let frame = await settledCapture(after: previous) else { break }
            previous = frame

            switch await worker.add(frame) {
            case .reversed:
                guard !hasMoved else { break frames }
                direction = -direction
                hasMoved = true
            case .stitched(.appended):
                hasMoved = true
                unmatched = 0
                hud?.update(height: await worker.height)
            case .stitched(.noMovement), .stitched(.limitReached):
                break frames
            case .stitched(.unmatched):
                unmatched += 1
                Logger.scrollCapture.notice("Couldn't match frame (\(unmatched) in a row)")
                if unmatched >= settings.maxUnmatched { break frames }
            }
        }

        guard let image = await worker.finish() else { return nil }
        Logger.scrollCapture.info("Scrolling capture finished at \(image.width)×\(image.height) px")
        return CapturedImage(image: image, scale: capturer.scale)
    }

    /// Captures until two consecutive captures match, so smooth-scrolling animations have finished.
    private func settledCapture(after previous: CGImage?) async -> CGImage? {
        try? await Task.sleep(for: settings.settleDelay)
        var latest: CGImage
        do {
            latest = try await capturer.capture()
        } catch {
            Logger.scrollCapture.error("Region capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        for _ in 1..<max(settings.maxSettleCaptures, 2) {
            try? await Task.sleep(for: .milliseconds(50))
            guard let next = try? await capturer.capture() else { break }
            if await Self.framesMatch(latest, next) { return next }
            latest = next
        }
        return latest
    }

    @concurrent
    private static func framesMatch(_ a: CGImage, _ b: CGImage) async -> Bool {
        StitchWorker.framesMatch(a, b)
    }
}
