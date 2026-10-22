import CoreGraphics

/// Owns the in-progress stitch off the main actor, so megabytes of pixels are never copied between actors.
actor StitchWorker {
    enum Outcome: Equatable, Sendable {
        case stitched(StitchProgress.Outcome)
        /// The first scroll moved the content the wrong way (an inverted scroll direction).
        /// The worker restarted from this frame; scroll the other way from now on.
        case reversed
    }

    let maxHeight: Int
    private var first: ImageBuffer?
    private var progress: StitchProgress?

    init(maxHeight: Int) {
        self.maxHeight = maxHeight
    }

    /// Height of the stitched image so far.
    var height: Int {
        progress?.finishedHeight ?? first?.height ?? 0
    }

    func begin(with image: CGImage) -> Bool {
        first = ImageBuffer(image)
        progress = nil
        return first != nil
    }

    func add(_ image: CGImage) -> Outcome {
        guard let frame = ImageBuffer(image) else { return .stitched(.unmatched) }
        if var progress {
            let outcome = progress.add(frame, fallback: VisionRegistration.fallback)
            self.progress = progress
            return .stitched(outcome)
        }
        guard let first else {
            first = frame
            return .stitched(.appended(rows: frame.height))
        }

        // The first frame that moved decides which rows are sticky.
        let firstSignatures = first.rowSignatures()
        let frameSignatures = frame.rowSignatures()
        if Stitcher.offset(previous: firstSignatures, next: frameSignatures) == 0 {
            return .stitched(.noMovement)
        }
        let sticky = StickyRegionDetector.detect([first, frame])
        var progress = StitchProgress(first: first, sticky: sticky, maxHeight: maxHeight)
        let outcome = progress.add(frame, fallback: VisionRegistration.fallback)
        if outcome == .unmatched, isScrolledBack(from: first, to: frame, sticky: sticky) {
            self.first = frame
            return .reversed
        }
        self.progress = progress
        return .stitched(outcome)
    }

    /// The content moved down instead of up.
    private func isScrolledBack(from first: ImageBuffer, to frame: ImageBuffer, sticky: StickyRegion) -> Bool {
        let rows = sticky.contentRows(height: first.height)
        let backward = Stitcher.offset(previous: frame.rowSignatures(rows), next: first.rowSignatures(rows))
        return (backward ?? 0) > 0
    }

    /// Whether two captures show the same thing, for waiting until scrolling has settled.
    static func framesMatch(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let left = ImageBuffer(a), let right = ImageBuffer(b)
        else { return false }
        return left.rowSignatures() == right.rowSignatures()
    }

    func finish() -> CGImage? {
        if let progress {
            return progress.finish()?.makeCGImage()
        }
        return first?.makeCGImage()
    }
}
