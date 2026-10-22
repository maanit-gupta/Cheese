/// Rows at the top and bottom of every frame that never move while the content scrolls:
/// sticky headers, toolbars, footers.
struct StickyRegion: Equatable, Sendable {
    var top: Int
    var bottom: Int

    static let none = StickyRegion(top: 0, bottom: 0)

    /// The scrolling rows of a frame `height` tall.
    func contentRows(height: Int) -> Range<Int> {
        top ..< max(top, height - bottom)
    }
}

enum StickyRegionDetector {
    /// Neither band may take more than this share of the frame, so there's always content left to match.
    static let maxFraction = 0.4
    /// Rows of content that must remain between the bands.
    static let minimumContentRows = 16

    static func detect(_ frames: [ImageBuffer]) -> StickyRegion {
        guard let first = frames.first, frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            return .none
        }
        return detect(signatures: frames.map { $0.rowSignatures() })
    }

    /// Counts leading and trailing rows that are identical in every frame. Frames that all look the same
    /// say nothing about what scrolls, so they give no sticky region.
    static func detect(signatures frames: [[RowSignature]]) -> StickyRegion {
        guard let first = frames.first, frames.count >= 2,
              frames.allSatisfy({ $0.count == first.count }),
              frames.dropFirst().contains(where: { $0 != first })
        else { return .none }

        let height = first.count
        let limit = Int(Double(height) * maxFraction)
        func isStill(_ row: Int) -> Bool {
            frames.dropFirst().allSatisfy { $0[row] == first[row] }
        }

        var top = 0
        while top < limit, isStill(top) {
            top += 1
        }
        var bottom = 0
        while bottom < limit, isStill(height - 1 - bottom) {
            bottom += 1
        }

        // Keep enough content to match frames; trim the larger band first.
        while height - top - bottom < minimumContentRows, top + bottom > 0 {
            if top >= bottom { top -= 1 } else { bottom -= 1 }
        }
        return StickyRegion(top: top, bottom: bottom)
    }
}
