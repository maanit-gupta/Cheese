import Accelerate
import CoreGraphics
import Foundation

/// Tightly packed 8-bit RGBA pixels (premultiplied alpha), rows top to bottom. The stitcher's working format.
struct ImageBuffer: Equatable, Sendable {
    static let bytesPerPixel = 4

    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]
    /// The color space the pixels are in, kept so stitched captures don't shift color.
    let colorSpace: CGColorSpace

    var bytesPerRow: Int { width * Self.bytesPerPixel }

    init?(width: Int, height: Int, pixels: [UInt8], colorSpace: CGColorSpace = ImageBuffer.defaultColorSpace) {
        guard width > 0, height >= 0, pixels.count == width * height * Self.bytesPerPixel else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
        self.colorSpace = colorSpace
    }

    static var defaultColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Draws `image` into a new buffer in its own RGB color space (or sRGB).
    init?(_ image: CGImage) {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? Self.defaultColorSpace
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * Self.bytesPerPixel, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels, colorSpace: space)
    }

    func makeCGImage() -> CGImage? {
        guard height > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// A new buffer holding only `rows`.
    func rows(_ rows: Range<Int>) -> ImageBuffer? {
        let rows = rows.clamped(to: 0..<height)
        let bytes = Array(pixels[rows.lowerBound * bytesPerRow ..< rows.upperBound * bytesPerRow])
        return ImageBuffer(width: width, height: rows.count, pixels: bytes, colorSpace: colorSpace)
    }

    /// The pixel bytes of `rows`, for appending to another buffer.
    func bytes(ofRows rows: Range<Int>) -> ArraySlice<UInt8> {
        let rows = rows.clamped(to: 0..<height)
        return pixels[rows.lowerBound * bytesPerRow ..< rows.upperBound * bytesPerRow]
    }

    /// Fingerprints of `rows` (all rows by default), computed with vDSP so they stay fast in Debug builds.
    func rowSignatures(_ rows: Range<Int>? = nil) -> [RowSignature] {
        let rows = (rows ?? 0..<height).clamped(to: 0..<height)
        let count = bytesPerRow
        guard count > 0, !rows.isEmpty else { return [] }

        let weights = RowSignature.weights(count: count)
        // Σ weight over each channel's positions, for checking whether a row is one solid color.
        var channelWeights = [Double](repeating: 0, count: Self.bytesPerPixel)
        for index in 0..<count {
            channelWeights[index % Self.bytesPerPixel] += weights[index]
        }
        var values = [Double](repeating: 0, count: count)

        return pixels.withUnsafeBufferPointer { pixelBuffer -> [RowSignature] in
            guard let base = pixelBuffer.baseAddress else { return [] }
            var signatures: [RowSignature] = []
            signatures.reserveCapacity(rows.count)
            for row in rows {
                let start = base + row * count
                var sum = 0.0
                var weighted = 0.0
                values.withUnsafeMutableBufferPointer { valueBuffer in
                    guard let valueBase = valueBuffer.baseAddress else { return }
                    vDSP_vfltu8D(start, 1, valueBase, 1, vDSP_Length(count))
                    vDSP_sveD(valueBase, 1, &sum, vDSP_Length(count))
                    vDSP_dotprD(valueBase, 1, weights, 1, &weighted, vDSP_Length(count))
                }
                // A solid row has exactly the sums its first pixel would give if repeated.
                let first = (0..<Self.bytesPerPixel).map { Double(start[$0]) }
                let solidSum = first.reduce(0, +) * Double(width)
                let solidWeighted = zip(first, channelWeights).reduce(0) { $0 + $1.0 * $1.1 }
                let isUniform = sum == solidSum && weighted == solidWeighted
                signatures.append(RowSignature(sum: sum, weighted: weighted, isUniform: isUniform))
            }
            return signatures
        }
    }
}

/// A fingerprint of one pixel row. Equal rows always have equal signatures; different rows almost never do.
struct RowSignature: Hashable, Sendable {
    /// Σ of every byte in the row.
    var sum: Double
    /// Σ of every byte times a position weight, so the same pixels in a different order differ.
    var weighted: Double
    /// Every pixel in the row is the same color (blank margins, solid backgrounds).
    var isUniform: Bool

    /// Mean absolute difference per byte between two rows of the same width, for tolerant comparisons.
    func meanDifference(from other: RowSignature, bytesPerRow: Int) -> Double {
        abs(sum - other.sum) / Double(max(bytesPerRow, 1))
    }

    /// Pseudo-random position weights in 1…251: small enough that sums stay exact in a Double, and
    /// irregular so mirrored or shuffled rows don't collide the way a linear ramp would let them.
    static func weights(count: Int) -> [Double] {
        (0..<count).map { index in
            Double((UInt64(index) &* 2_654_435_761 >> 16) % 251 + 1)
        }
    }
}
