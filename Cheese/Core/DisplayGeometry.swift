import CoreGraphics

/// Coordinate conversion between the two global spaces macOS uses:
///
/// - **AppKit** (`NSScreen`, `NSWindow`, `NSEvent.mouseLocation`): origin at the bottom-left of the
///   primary display, y grows upward.
/// - **Quartz** (Accessibility, `CGWindowList`, `CGEvent`, `CGDisplayBounds`): origin at the top-left of
///   the primary display, y grows downward.
///
/// The primary display is the one whose AppKit frame starts at (0, 0). Displays above it have negative
/// Quartz y and AppKit y above its height; displays left of it have negative x in both spaces.
enum DisplayGeometry {
    /// Converts an AppKit rect to Quartz.
    static func quartzRect(fromAppKit rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        flipped(rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// Converts a Quartz rect to AppKit.
    static func appKitRect(fromQuartz rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        flipped(rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    static func quartzPoint(fromAppKit point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    static func appKitPoint(fromQuartz point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// The flip is its own inverse, so both directions share it.
    private static func flipped(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        let rect = rect.standardized
        return CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// An AppKit global rect as a rect within one display, top-left origin, in points: the form
    /// ScreenCaptureKit's `sourceRect` takes.
    static func displayLocalRect(fromAppKit rect: CGRect, displayFrame: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX - displayFrame.minX,
            y: displayFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The primary display's height, given every display's AppKit frame.
    static func primaryDisplayHeight(appKitFrames frames: [CGRect]) -> CGFloat {
        (frames.first { $0.origin == .zero } ?? frames.first)?.height ?? 0
    }

    /// Index of the display containing `point`, or the nearest one when the point is in a gap between displays.
    static func indexOfDisplay(containing point: CGPoint, frames: [CGRect]) -> Int? {
        if let index = frames.firstIndex(where: { $0.contains(point) }) { return index }
        return frames.indices.min { distance(from: point, to: frames[$0]) < distance(from: point, to: frames[$1]) }
    }

    /// Index of the display that holds most of `rect`, falling back to the one nearest its center.
    static func indexOfDisplay(bestMatching rect: CGRect, frames: [CGRect]) -> Int? {
        let areas = frames.map { frame -> CGFloat in
            let overlap = frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
            return best
        }
        return indexOfDisplay(containing: CGPoint(x: rect.midX, y: rect.midY), frames: frames)
    }

    /// Maps a rect in a view that shows an image scaled to fill it (view origin bottom-left, in points)
    /// to the image's pixel rect (origin top-left), rounded outward and clamped to the image.
    static func pixelRect(forViewRect rect: CGRect, viewSize: CGSize, imagePixelSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .null }
        let scaleX = imagePixelSize.width / viewSize.width
        let scaleY = imagePixelSize.height / viewSize.height
        let rect = rect.standardized
        let pixels = CGRect(
            x: rect.minX * scaleX,
            y: (viewSize.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        // Snap to whole pixels; the tiny inset keeps float noise from adding a pixel row.
        return pixels.insetBy(dx: 0.001, dy: 0.001).integral
            .intersection(CGRect(origin: .zero, size: imagePixelSize))
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
