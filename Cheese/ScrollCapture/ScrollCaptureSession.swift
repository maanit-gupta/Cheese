import AppKit
import os

/// One scrolling capture. The user scrolls the region by hand, or turns on Auto-scroll, and every
/// new part of the page is stitched on, until they click Done (or the image reaches its maximum
/// height). Scrolling back up is ignored until the page passes the furthest point again.
@MainActor
final class ScrollCaptureSession {
    struct Settings {
        /// Tallest output image, to protect memory.
        var maxHeight = 30_000
        /// Each automatic scroll moves this share of the region, leaving plenty of overlap to match.
        var stepFraction = 0.45
        /// Wait after an automatic scroll before the first capture.
        var settleDelay = Duration.milliseconds(90)
        /// Captures taken while waiting for animated scrolling to stop.
        var maxSettleCaptures = 6
        /// How often the region is looked at while the user scrolls by hand.
        var pollInterval = Duration.milliseconds(80)
        /// Frames in a row that match nothing before the bar says the page was lost.
        var lostAfter = 3
        /// Captures in a row that can fail before giving up.
        var maxFailedCaptures = 5
        /// Finishes by itself once Auto-scroll reaches the end of the page. Off in the app, where
        /// it waits for Done; tests of the automatic scroll turn it on.
        var finishesAtPageEnd = false
        /// The border and bar; off in tests.
        var showsHUD = true
    }

    enum Ending: Equatable {
        case done
        case cancelled
    }

    static let lostHint = "Lost the page — scroll back up a little"
    static let endHint = "Reached the end · Return or Done to finish"

    /// AppKit global points.
    let region: CGRect
    private let settings: Settings
    private let capturer: any RegionCapturing
    private let scroller: any ScrollPerforming
    private var hud: ScrollCaptureHUD?
    private(set) var ending: Ending?
    /// Auto-scroll on: Cheese scrolls the region itself.
    private(set) var autoScroll: Bool
    /// Stopped at the maximum height.
    private(set) var reachedLimit = false
    private var reachedEnd = false
    private var pointerPlaced = false
    private var lastThumbnail = ContinuousClock.now

    init(
        region: CGRect,
        capturer: any RegionCapturing,
        scroller: any ScrollPerforming = AutoScroller(),
        autoScroll: Bool = Preferences().scrollCaptureAutoScroll,
        settings: Settings = Settings()
    ) {
        self.region = region
        self.capturer = capturer
        self.scroller = scroller
        self.autoScroll = autoScroll
        self.settings = settings
    }

    /// Done: keeps what's been stitched.
    func finish() {
        if ending == nil {
            ending = .done
        }
    }

    /// Ends the capture after the current frame, keeping what's been stitched.
    func stop() {
        finish()
    }

    /// Throws the capture away.
    func cancel() {
        ending = .cancelled
    }

    func setAutoScroll(_ isOn: Bool) {
        autoScroll = isOn
        UserDefaults.standard.set(isOn, forKey: PreferenceKey.scrollCaptureAutoScroll)
        if isOn {
            reachedEnd = false
            hud?.setHint(nil)
        }
    }

    /// Runs until Done or Cancel. Returns nil when cancelled or when not even the first frame
    /// could be captured.
    func run() async -> CapturedImage? {
        if settings.showsHUD {
            let hud = ScrollCaptureHUD(region: region, autoScroll: autoScroll, actions: ScrollCaptureHUD.Actions(
                done: { [weak self] in self?.finish() },
                cancel: { [weak self] in self?.cancel() },
                autoScrollChanged: { [weak self] in self?.setAutoScroll($0) }
            ))
            self.hud = hud
            hud.show()
        }
        defer {
            hud?.close()
            hud = nil
        }

        let quartzRegion = Screens.quartzRect(fromAppKit: region)
        let center = CGPoint(x: quartzRegion.midX, y: quartzRegion.midY)
        if autoScroll {
            scroller.movePointer(to: center)
            pointerPlaced = true
        }

        let worker = StitchWorker(maxHeight: settings.maxHeight)
        guard let first = await settledCapture(after: nil), await worker.begin(with: first) else {
            CheeseToast.show("Couldn't capture the region", systemImage: "exclamationmark.triangle.fill")
            return nil
        }
        await refreshHUD(worker, force: true)

        let step = Int32(max((region.height * settings.stepFraction).rounded(), 20))
        var direction: Int32 = 1
        var hasMoved = false
        var unmatched = 0
        var failedCaptures = 0
        var previous = first

        frames: while ending == nil {
            let frame: CGImage
            // Only frames Cheese scrolled for can say the page has ended.
            let scrolled = autoScroll && !reachedEnd
            if scrolled {
                if !pointerPlaced {
                    scroller.movePointer(to: center)
                    pointerPlaced = true
                }
                await scroller.scroll(by: step * direction, at: center)
                guard ending == nil else { break }
                guard let settled = await settledCapture(after: previous) else { break }
                frame = settled
            } else {
                try? await Task.sleep(for: settings.pollInterval)
                guard ending == nil else { break }
                do {
                    frame = try await capturer.capture()
                    failedCaptures = 0
                } catch {
                    failedCaptures += 1
                    Logger.scrollCapture.error("Region capture failed: \(error.localizedDescription, privacy: .public)")
                    if failedCaptures >= settings.maxFailedCaptures { break }
                    continue
                }
            }
            previous = frame

            switch await worker.add(frame) {
            case .reversed:
                // Auto-scroll went the wrong way first: go the other way. By hand, the capture
                // simply starts from where the user scrolled to.
                if autoScroll, !hasMoved {
                    direction = -direction
                    hasMoved = true
                }
                await refreshHUD(worker, force: true)
            case .stitched(.appended):
                hasMoved = true
                unmatched = 0
                hud?.setHint(nil)
                await refreshHUD(worker)
            case .behind:
                unmatched = 0
                hud?.setHint(nil)
            case .stitched(.noMovement):
                unmatched = 0
                if scrolled {
                    reachedEnd = true
                    hud?.setHint(Self.endHint)
                    if settings.finishesAtPageEnd { break frames }
                }
            case .stitched(.unmatched):
                unmatched += 1
                Logger.scrollCapture.notice("Couldn't match frame (\(unmatched) in a row)")
                if unmatched >= settings.lostAfter {
                    hud?.setHint(Self.lostHint)
                    if scrolled {
                        // Auto-scroll can't recover by itself; leave it to the user.
                        reachedEnd = true
                        if settings.finishesAtPageEnd { break frames }
                    }
                }
            case .stitched(.limitReached):
                reachedLimit = true
                break frames
            }
        }

        guard ending != .cancelled else {
            Logger.scrollCapture.info("Scrolling capture cancelled")
            return nil
        }
        guard let image = await worker.finish() else { return nil }
        Logger.scrollCapture.info("Scrolling capture finished at \(image.width)×\(image.height) px")
        return CapturedImage(image: image, scale: capturer.scale)
    }

    /// The height every time, the thumbnail at most twice a second.
    private func refreshHUD(_ worker: StitchWorker, force: Bool = false) async {
        guard let hud else { return }
        let height = await worker.height
        var thumbnail: CGImage?
        if force || ContinuousClock.now - lastThumbnail > .milliseconds(500) {
            thumbnail = await worker.thumbnailImage()
            lastThumbnail = .now
        }
        hud.update(height: height, thumbnail: thumbnail)
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
