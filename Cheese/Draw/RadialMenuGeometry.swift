import CoreGraphics
import Foundation

/// Where things sit in the right-click radial menu, and what a release or flick picks. Pure.
/// Offsets are measured from the menu's center in view coordinates (y down).
struct RadialMenuGeometry: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// Released in the middle: nothing changes.
        case cancel
        case slice(Int)
        /// One of the color swatches on the outer ring.
        case color(Int)
    }

    static let sliceCount = 8
    static var sliceAngle: CGFloat { 2 * .pi / CGFloat(sliceCount) }

    /// Inside this, releasing cancels.
    var cancelRadius: CGFloat = 30
    /// The tool slices end here; the color ring starts.
    var sliceRadius: CGFloat = 104
    /// The color ring's outer edge, as drawn. Releasing farther out still picks a color.
    var ringRadius: CGFloat = 136

    /// A flick shorter than this isn't a flick.
    static let flickMinimumDistance: CGFloat = 24
    /// Points per second.
    static let flickMinimumSpeed: CGFloat = 250

    /// The slice in a direction. Slice 0 is centered straight up; the rest follow clockwise.
    static func slice(forAngle angle: CGFloat) -> Int {
        // atan2 in y-down coordinates grows clockwise; shift so "up" is zero.
        var fromTop = angle + .pi / 2 + sliceAngle / 2
        fromTop = fromTop.truncatingRemainder(dividingBy: 2 * .pi)
        if fromTop < 0 {
            fromTop += 2 * .pi
        }
        return Int(fromTop / sliceAngle) % sliceCount
    }

    static func slice(for offset: CGVector) -> Int {
        slice(forAngle: atan2(offset.dy, offset.dx))
    }

    func target(at offset: CGVector) -> Target {
        let distance = hypot(offset.dx, offset.dy)
        if distance < cancelRadius {
            return .cancel
        }
        let index = Self.slice(for: offset)
        return distance <= sliceRadius ? .slice(index) : .color(index)
    }

    /// The slice a quick flick points at, without waiting for the menu: far and fast enough, or nil.
    static func flick(displacement: CGVector, duration: TimeInterval) -> Int? {
        let distance = hypot(displacement.dx, displacement.dy)
        guard distance >= flickMinimumDistance else { return nil }
        let speed = distance / CGFloat(max(duration, 0.001))
        guard speed >= flickMinimumSpeed else { return nil }
        return slice(for: displacement)
    }

    /// The middle of a slice (for its icon) or of a ring swatch, as an offset from the center.
    func center(ofSlice index: Int) -> CGVector {
        offset(at: (cancelRadius + sliceRadius) / 2, slice: index)
    }

    func center(ofSwatch index: Int) -> CGVector {
        offset(at: (sliceRadius + ringRadius) / 2, slice: index)
    }

    private func offset(at radius: CGFloat, slice index: Int) -> CGVector {
        let angle = CGFloat(index) * Self.sliceAngle - .pi / 2
        return CGVector(dx: cos(angle) * radius, dy: sin(angle) * radius)
    }

    /// Where to draw the menu so the whole ring stays inside `bounds`.
    func clampedCenter(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        let inset = bounds.insetBy(dx: ringRadius + 4, dy: ringRadius + 4)
        guard !inset.isNull, inset.width >= 0, inset.height >= 0 else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return CGPoint(x: min(max(point.x, inset.minX), inset.maxX), y: min(max(point.y, inset.minY), inset.maxY))
    }
}
