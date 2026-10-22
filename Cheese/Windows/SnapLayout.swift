import CoreGraphics

enum SnapAction: Equatable, Hashable, Sendable {
    case leftHalf
    case rightHalf
    case maximize
    case bottomHalf
}

struct SnapTarget: Equatable, Sendable {
    var frame: CGRect
    var displayIndex: Int
}

/// What happened the last time a window was snapped: the frame aimed for and the frame it ended up with,
/// which differ for windows that resize in steps (Terminal) or refuse some sizes.
struct SnapRecord: Equatable, Sendable {
    var aimed: CGRect
    var result: CGRect
}

/// Frame math for window snapping. Every rect is in Quartz global coordinates (top-left origin, y down),
/// the space Accessibility uses, and `displays` are the displays' visible frames (no menu bar or Dock).
enum SnapLayout {
    /// How far a window can be from a snap position and still count as being there.
    static let matchTolerance: CGFloat = 8

    /// The frame for `action` within one display's visible frame. Halves split on whole points.
    static func frame(for action: SnapAction, in visible: CGRect) -> CGRect {
        let visible = visible.standardized
        switch action {
        case .leftHalf:
            let width = (visible.width / 2).rounded(.down)
            return CGRect(x: visible.minX, y: visible.minY, width: width, height: visible.height)
        case .rightHalf:
            let leftWidth = (visible.width / 2).rounded(.down)
            return CGRect(x: visible.minX + leftWidth, y: visible.minY, width: visible.width - leftWidth, height: visible.height)
        case .maximize:
            return visible
        case .bottomHalf:
            let topHeight = (visible.height / 2).rounded(.down)
            return CGRect(x: visible.minX, y: visible.minY + topHeight, width: visible.width, height: visible.height - topHeight)
        }
    }

    /// Where `action` sends a window currently at `windowFrame`, or nil when there's nowhere to go
    /// (a repeated half-snap on the last display in that direction).
    ///
    /// Pressing right while a window already fills the right half moves it to the left half of the next
    /// display to the right; left mirrors that.
    static func target(
        for action: SnapAction,
        windowFrame: CGRect,
        displays: [CGRect],
        previousSnap: SnapRecord? = nil
    ) -> SnapTarget? {
        guard let current = DisplayGeometry.indexOfDisplay(bestMatching: windowFrame, frames: displays) else { return nil }
        let here = frame(for: action, in: displays[current])

        switch action {
        case .maximize, .bottomHalf:
            return SnapTarget(frame: here, displayIndex: current)
        case .leftHalf, .rightHalf:
            let alreadyThere = approximatelyEqual(windowFrame, here)
                || previousSnap.map { approximatelyEqual($0.aimed, here, tolerance: 1) && approximatelyEqual(windowFrame, $0.result, tolerance: 2) } == true
            guard alreadyThere else { return SnapTarget(frame: here, displayIndex: current) }

            let towardRight = action == .rightHalf
            guard let next = neighbor(of: current, towardRight: towardRight, in: displays) else { return nil }
            return SnapTarget(frame: frame(for: towardRight ? .leftHalf : .rightHalf, in: displays[next]), displayIndex: next)
        }
    }

    /// The nearest display beyond `index` in that direction, preferring the one most level with it.
    static func neighbor(of index: Int, towardRight: Bool, in displays: [CGRect]) -> Int? {
        let current = displays[index]
        let candidates = displays.indices.filter { candidate in
            guard candidate != index else { return false }
            return towardRight ? displays[candidate].midX > current.midX : displays[candidate].midX < current.midX
        }
        func ranking(_ candidate: Int) -> (CGFloat, CGFloat) {
            let display = displays[candidate]
            let gap = towardRight ? max(display.minX - current.maxX, 0) : max(current.minX - display.maxX, 0)
            return (gap, abs(display.midY - current.midY))
        }
        return candidates.min { ranking($0) < ranking($1) }
    }

    /// Origin for a window that ended up `size` instead of the target's size: as close to the target
    /// as possible while staying on the display, or pinned to its top-left when it's larger than the display.
    static func clampedOrigin(for size: CGSize, target: CGRect, visible: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            length >= upper - lower ? lower : min(max(value, lower), upper - length)
        }
        return CGPoint(
            x: clamp(target.minX, length: size.width, lower: visible.minX, upper: visible.maxX),
            y: clamp(target.minY, length: size.height, lower: visible.minY, upper: visible.maxY)
        )
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = matchTolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
