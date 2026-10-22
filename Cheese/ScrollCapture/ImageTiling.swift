import CoreGraphics

/// Splits tall images into strips for OCR. Vision downscales very tall images and loses small text, so a
/// stitched page is read strip by strip, cut on blank rows where possible so no line of text is split.
enum ImageTiling {
    static let maxTileHeight = 2_400
    /// How far above a hard cut to look for a blank row.
    static let searchWindow = 400

    static func tileRanges(uniformRows: [Bool], maxTileHeight: Int = maxTileHeight, searchWindow: Int = searchWindow) -> [Range<Int>] {
        let height = uniformRows.count
        guard height > 0, maxTileHeight > 0 else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < height {
            var end = min(start + maxTileHeight, height)
            if end < height {
                let lowest = max(start + 1, end - searchWindow)
                if let blank = (lowest..<end).reversed().first(where: { uniformRows[$0] }) {
                    end = blank
                }
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// The strips of `image`, top to bottom. A short image is a single strip.
    @concurrent
    static func tiles(of image: CGImage) async -> [CGImage] {
        guard image.height > maxTileHeight, let buffer = ImageBuffer(image) else { return [image] }
        let uniform = buffer.rowSignatures().map(\.isUniform)
        return tileRanges(uniformRows: uniform).compactMap { range in
            image.cropping(to: CGRect(x: 0, y: range.lowerBound, width: image.width, height: range.count))
        }
    }
}
