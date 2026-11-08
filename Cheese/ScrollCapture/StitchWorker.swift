import CoreGraphics

/// Owns the in-progress stitch off the main actor, so megabytes of pixels are never copied between actors.
actor StitchWorker {
    enum Outcome: Equatable, Sendable {
        case stitched(StitchProgress.Outcome)
        /// The first scroll moved the content the wrong way (an inverted scroll direction, or the
        /// user scrolling up first). The worker restarted from this frame.
        case reversed
        /// The frame is above where the stitch has got to: the user scrolled back up. It's skipped;
        /// the stitch carries on once they scroll past the furthest point again.
        case behind
    }

    let maxHeight: Int
    private let thumbnailWidth: Int
    private var first: ImageBuffer?
    private var progress: StitchProgress?
    private var thumbnail: StitchThumbnail?

    init(maxHeight: Int, thumbnailWidth: Int = 64) {
        self.maxHeight = maxHeight
        self.thumbnailWidth = thumbnailWidth
    }

    /// Height of the stitched image so far.
    var height: Int {
        progress?.finishedHeight ?? first?.height ?? 0
    }

    func begin(with image: CGImage) -> Bool {
        first = ImageBuffer(image)
        progress = nil
        restartThumbnail(with: first, rows: first.map { 0..<$0.height } ?? 0..<0)
        return first != nil
    }

    func add(_ image: CGImage) -> Outcome {
        guard let frame = ImageBuffer(image) else { return .stitched(.unmatched) }
        if var progress {
            let outcome = progress.add(frame, fallback: VisionRegistration.fallback)
            self.progress = progress
            switch outcome {
            case .appended, .limitReached:
                thumbnail?.append(rows: progress.lastAppendedRows, of: frame)
            case .unmatched:
                if isScrolledBack(from: progress.lastFrame, to: frame, sticky: progress.sticky) {
                    return .behind
                }
            case .noMovement:
                break
            }
            return .stitched(outcome)
        }
        guard let first else {
            first = frame
            restartThumbnail(with: frame, rows: 0..<frame.height)
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
        let initialRows = progress.lastAppendedRows
        let outcome = progress.add(frame, fallback: VisionRegistration.fallback)
        if outcome == .unmatched, isScrolledBack(from: first, to: frame, sticky: sticky) {
            self.first = frame
            restartThumbnail(with: frame, rows: 0..<frame.height)
            return .reversed
        }
        if outcome != .unmatched {
            // From here on the thumbnail leaves out the footer, like the stitched image until it's finished.
            restartThumbnail(with: first, rows: initialRows)
            thumbnail?.append(rows: progress.lastAppendedRows, of: frame)
        }
        self.progress = progress
        return .stitched(outcome)
    }

    /// A small copy of the stitch so far, for the bar under the region.
    func thumbnailImage() -> CGImage? {
        thumbnail?.image(colorSpace: first?.colorSpace ?? ImageBuffer.defaultColorSpace)
    }

    private func restartThumbnail(with frame: ImageBuffer?, rows: Range<Int>) {
        guard let frame else {
            thumbnail = nil
            return
        }
        var fresh = StitchThumbnail(sourceWidth: frame.width, targetWidth: thumbnailWidth)
        fresh.append(rows: rows, of: frame)
        thumbnail = fresh
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
