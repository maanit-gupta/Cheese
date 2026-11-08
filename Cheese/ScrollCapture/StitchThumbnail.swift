import CoreGraphics

/// A small copy of the image being stitched, for the scrolling capture bar. Built as rows are
/// added, by keeping every `step`-th row and column, so it never redraws the whole tall image.
struct StitchThumbnail: Sendable {
    let sourceWidth: Int
    /// Rows and columns kept: one in `step`.
    let step: Int
    let width: Int
    private(set) var height = 0
    private var pixels: [UInt8] = []
    private var rowsSeen = 0

    init(sourceWidth: Int, targetWidth: Int = 64) {
        self.sourceWidth = max(sourceWidth, 1)
        step = max(Int((Double(self.sourceWidth) / Double(max(targetWidth, 1))).rounded(.up)), 1)
        width = (self.sourceWidth + step - 1) / step
    }

    /// Adds `rows` of `frame`, which come next in the stitched image.
    mutating func append(rows: Range<Int>, of frame: ImageBuffer) {
        guard frame.width == sourceWidth else { return }
        let bytesPerPixel = ImageBuffer.bytesPerPixel
        let source = frame.pixels
        for row in rows.clamped(to: 0..<frame.height) {
            defer { rowsSeen += 1 }
            guard rowsSeen % step == 0 else { continue }
            let rowStart = row * frame.bytesPerRow
            for column in stride(from: 0, to: sourceWidth, by: step) {
                let index = rowStart + column * bytesPerPixel
                pixels.append(contentsOf: source[index ..< index + bytesPerPixel])
            }
            height += 1
        }
    }

    func image(colorSpace: CGColorSpace = ImageBuffer.defaultColorSpace) -> CGImage? {
        ImageBuffer(width: width, height: height, pixels: pixels, colorSpace: colorSpace)?.makeCGImage()
    }
}
