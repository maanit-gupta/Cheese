/// Finds how far content scrolled between frames and appends only the new rows. Pure: no system calls.
enum Stitcher {
    /// Share of overlapping rows that must match exactly for an offset to be accepted.
    static let requiredMatch = 0.95
    /// Fewest overlapping rows an offset can be judged on.
    static let minimumOverlap = 12
    /// Candidate offsets checked in full after voting.
    private static let candidateCount = 8

    /// Rows the content moved up between two frames' content regions: `next[r]` shows `previous[r + offset]`.
    /// Returns 0 when the content didn't move, and nil when no offset fits well enough.
    static func offset(previous: [RowSignature], next: [RowSignature]) -> Int? {
        let height = min(previous.count, next.count)
        guard height > 0 else { return nil }
        if matchRatio(previous: previous, next: next, offset: 0) >= requiredMatch { return 0 }

        // Vote: every distinctive row of `next` suggests the offsets where it appears in `previous`.
        // Rows that are everywhere (blank lines, solid backgrounds) carry no information and are skipped.
        var positions: [RowSignature: [Int]] = [:]
        for (index, signature) in previous.prefix(height).enumerated() where !signature.isUniform {
            positions[signature, default: []].append(index)
        }
        let commonLimit = max(4, height / 20)
        var votes: [Int: Int] = [:]
        for (index, signature) in next.prefix(height).enumerated() where !signature.isUniform {
            guard let matches = positions[signature], matches.count <= commonLimit else { continue }
            for match in matches where match > index {
                votes[match - index, default: 0] += 1
            }
        }

        let candidates = votes
            .filter { height - $0.key >= minimumOverlap }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(candidateCount)

        var best: (offset: Int, ratio: Double)?
        for candidate in candidates {
            let ratio = matchRatio(previous: previous, next: next, offset: candidate.key)
            if ratio >= requiredMatch, ratio > best?.ratio ?? 0 {
                best = (candidate.key, ratio)
            }
        }
        return best?.offset
    }

    /// Share of overlapping rows that are identical at `offset`.
    static func matchRatio(previous: [RowSignature], next: [RowSignature], offset: Int) -> Double {
        let height = min(previous.count, next.count)
        let overlap = height - offset
        guard offset >= 0, overlap > 0 else { return 0 }
        var matches = 0
        for row in 0..<overlap where next[row] == previous[row + offset] {
            matches += 1
        }
        return Double(matches) / Double(overlap)
    }

    /// A looser check for offsets found by image registration, which tolerates anti-aliasing noise.
    static func isPlausible(offset: Int, previous: [RowSignature], next: [RowSignature], bytesPerRow: Int) -> Bool {
        let height = min(previous.count, next.count)
        let overlap = height - offset
        guard offset > 0, overlap >= minimumOverlap else { return false }
        var close = 0
        for row in 0..<overlap where next[row].meanDifference(from: previous[row + offset], bytesPerRow: bytesPerRow) <= 3 {
            close += 1
        }
        return Double(close) / Double(overlap) >= 0.85
    }

    /// Stitches a complete list of frames. Used by tests and anywhere all frames are at hand.
    static func stitch(
        _ frames: [ImageBuffer],
        maxHeight: Int,
        fallback: StitchProgress.OffsetFallback? = nil
    ) -> StitchResult? {
        guard let first = frames.first else { return nil }
        let sticky = StickyRegionDetector.detect(frames)
        var progress = StitchProgress(first: first, sticky: sticky, maxHeight: maxHeight)
        var outcomes: [StitchProgress.Outcome] = []
        for frame in frames.dropFirst() {
            let outcome = progress.add(frame, fallback: fallback)
            outcomes.append(outcome)
            if outcome == .noMovement || outcome == .limitReached { break }
        }
        guard let image = progress.finish() else { return nil }
        return StitchResult(image: image, sticky: sticky, outcomes: outcomes)
    }
}

struct StitchResult: Sendable {
    var image: ImageBuffer
    var sticky: StickyRegion
    var outcomes: [StitchProgress.Outcome]
}

/// An image being stitched frame by frame. Keeps only the output so far and the last accepted frame.
struct StitchProgress: Sendable {
    /// Finds an offset when row matching can't, e.g. with image registration. Arguments are the previous
    /// and next frames and the sticky region; the result is in rows, like `Stitcher.offset`.
    typealias OffsetFallback = @Sendable (ImageBuffer, ImageBuffer, StickyRegion) -> Int?

    enum Outcome: Equatable, Sendable {
        case appended(rows: Int)
        /// The frame shows the same content as the last one: the end of the page.
        case noMovement
        /// No offset fits; the frame was skipped.
        case unmatched
        /// The output hit the maximum height; nothing more will be added.
        case limitReached
    }

    let sticky: StickyRegion
    let maxHeight: Int
    let width: Int
    let frameHeight: Int
    private(set) var reachedLimit = false
    private(set) var framesUsed = 1

    private var output: [UInt8]
    private(set) var outputHeight: Int
    private var previous: ImageBuffer
    private var previousSignatures: [RowSignature]

    /// Starts with the first frame's header and content. The footer is added once, at the end.
    init(first: ImageBuffer, sticky: StickyRegion, maxHeight: Int) {
        self.sticky = sticky
        self.maxHeight = max(maxHeight, 1)
        width = first.width
        frameHeight = first.height
        previous = first
        previousSignatures = first.rowSignatures(sticky.contentRows(height: first.height))

        let keep = min(first.height - sticky.bottom, self.maxHeight - sticky.bottom)
        output = Array(first.bytes(ofRows: 0..<max(keep, 0)))
        outputHeight = max(keep, 0)
        reachedLimit = keep < first.height - sticky.bottom
    }

    /// Height the finished image will have.
    var finishedHeight: Int { outputHeight + sticky.bottom }

    mutating func add(_ frame: ImageBuffer, fallback: OffsetFallback? = nil) -> Outcome {
        guard !reachedLimit else { return .limitReached }
        guard frame.width == width, frame.height == frameHeight else { return .unmatched }

        let contentRows = sticky.contentRows(height: frameHeight)
        let signatures = frame.rowSignatures(contentRows)
        var offset = Stitcher.offset(previous: previousSignatures, next: signatures)
        if offset == nil, let fallback, let found = fallback(previous, frame, sticky),
           Stitcher.isPlausible(offset: found, previous: previousSignatures, next: signatures, bytesPerRow: frame.bytesPerRow) {
            offset = found
        }
        guard let offset, offset < contentRows.count else { return .unmatched }
        guard offset > 0 else { return .noMovement }

        // The new rows are the bottom `offset` rows of the content.
        let room = maxHeight - sticky.bottom - outputHeight
        let count = min(offset, max(room, 0))
        let start = contentRows.upperBound - offset
        output.append(contentsOf: frame.bytes(ofRows: start ..< start + count))
        outputHeight += count
        previous = frame
        previousSignatures = signatures
        framesUsed += 1

        if count < offset {
            reachedLimit = true
            return .limitReached
        }
        return .appended(rows: count)
    }

    /// The stitched image, with the last frame's footer.
    func finish() -> ImageBuffer? {
        var pixels = output
        pixels.append(contentsOf: previous.bytes(ofRows: frameHeight - sticky.bottom ..< frameHeight))
        return ImageBuffer(width: width, height: outputHeight + sticky.bottom, pixels: pixels, colorSpace: previous.colorSpace)
    }
}
