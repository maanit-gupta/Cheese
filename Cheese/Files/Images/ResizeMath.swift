import Foundation

enum ResizeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case percentage
    case maxSize
    case exact

    var id: Self { self }

    var title: String {
        switch self {
        case .percentage: "Percentage"
        case .maxSize: "Fit within"
        case .exact: "Exact size"
        }
    }
}

/// Pixel dimensions, upright (after EXIF orientation).
struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

/// Target dimensions for the resize tool. Pure, so every mode is tested.
enum ResizeMath {
    /// - percentage: scales both sides, at least 1 px each.
    /// - maxSize: shrinks to fit within `maxWidth`×`maxHeight` (0 means no limit), never enlarges.
    /// - exact: `width`×`height`; with the aspect locked, the height follows the width.
    static func target(
        for size: PixelSize,
        mode: ResizeMode,
        percent: Double = 100,
        maxWidth: Int = 0,
        maxHeight: Int = 0,
        width: Int = 0,
        height: Int = 0,
        lockAspect: Bool = true
    ) -> PixelSize {
        guard size.width > 0, size.height > 0 else { return size }
        let aspect = Double(size.height) / Double(size.width)
        switch mode {
        case .percentage:
            let factor = max(percent, 0) / 100
            return PixelSize(width: scaled(size.width, factor), height: scaled(size.height, factor))
        case .maxSize:
            let widthFactor = maxWidth > 0 ? Double(maxWidth) / Double(size.width) : .infinity
            let heightFactor = maxHeight > 0 ? Double(maxHeight) / Double(size.height) : .infinity
            let factor = min(widthFactor, heightFactor, 1)
            return PixelSize(width: scaled(size.width, factor), height: scaled(size.height, factor))
        case .exact:
            let newWidth = max(width, 1)
            let newHeight = lockAspect ? max(Int((Double(newWidth) * aspect).rounded()), 1) : max(height, 1)
            return PixelSize(width: newWidth, height: newHeight)
        }
    }

    /// The height that keeps the aspect ratio for a typed width, for the locked W×H fields.
    static func lockedHeight(forWidth width: Int, original: PixelSize) -> Int {
        guard original.width > 0 else { return width }
        return max(Int((Double(width) * Double(original.height) / Double(original.width)).rounded()), 1)
    }

    private static func scaled(_ value: Int, _ factor: Double) -> Int {
        max(Int((Double(value) * factor).rounded()), 1)
    }
}
