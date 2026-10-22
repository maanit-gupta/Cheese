import CoreGraphics
import Foundation

/// Which items a point or eraser touches, and how selection handles resize.
enum CanvasHitTester {
    enum Purpose {
        /// Clicking with Select: shapes count anywhere inside, so an outline is easy to grab.
        case select
        /// Erasing: an outlined shape is only touched on its outline.
        case erase
    }

    enum Handle: CaseIterable, Sendable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.infinity
        for index in 1..<points.count {
            best = min(best, distance(from: point, toSegment: points[index - 1], points[index]))
        }
        return best
    }

    /// Whether `point` is within `tolerance` of the item as drawn.
    static func hits(_ item: CanvasItem, at point: CGPoint, tolerance: CGFloat, purpose: Purpose) -> Bool {
        let reach = tolerance + item.renderedWidth / 2
        // Cheap reject first.
        guard item.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        switch item.kind {
        case let .stroke(points, _):
            return distance(from: point, toPolyline: StrokeSmoother.smoothed(points, samplesPerCurve: 3)) <= reach
        case let .line(from, to), let .arrow(from, to):
            return distance(from: point, toSegment: from, to) <= reach
        case .text, .sticky:
            return true
        case let .shape(kind, rect):
            let inside = purpose == .select || item.style.isFilled
            return hitsShape(kind, rect: rect.standardized, at: point, reach: reach, countsInside: inside)
        }
    }

    /// The top-most item under `point`. Highlighters sit beneath everything else, so they're checked last.
    static func topItem(at point: CGPoint, in items: [CanvasItem], tolerance: CGFloat) -> CanvasItem? {
        let others = items.filter { !$0.isHighlighter }
        let highlighters = items.filter(\.isHighlighter)
        return (others.reversed() + highlighters.reversed()).first { hits($0, at: point, tolerance: tolerance, purpose: .select) }
    }

    /// Items an eraser of `radius` touches moving from `start` to `end`.
    static func itemsErased(from start: CGPoint, to end: CGPoint, radius: CGFloat, in items: [CanvasItem]) -> Set<UUID> {
        let length = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int((length / max(radius / 2, 1)).rounded(.up)))
        var touched: Set<UUID> = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            for item in items where !touched.contains(item.id) && hits(item, at: sample, tolerance: radius, purpose: .erase) {
                touched.insert(item.id)
            }
        }
        return touched
    }

    // MARK: Handles

    static func point(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The handle of `rect` under `point`, if any.
    static func handle(at point: CGPoint, of rect: CGRect, radius: CGFloat) -> Handle? {
        Handle.allCases.first { handle in
            let corner = self.point(of: handle, in: rect)
            return hypot(point.x - corner.x, point.y - corner.y) <= radius
        }
    }

    /// `rect` with `handle` dragged to `point` and the opposite corner fixed. With `keepAspect`
    /// (Shift) the original proportions are kept. Never smaller than `minimumSize`.
    static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint, keepAspect: Bool, minimumSize: CGFloat = 4) -> CGRect {
        let opposite: Handle = switch handle {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .bottomRight: .topLeft
        }
        let anchor = self.point(of: opposite, in: rect)
        var width = max(abs(point.x - anchor.x), minimumSize)
        var height = max(abs(point.y - anchor.y), minimumSize)
        if keepAspect, rect.width > 0, rect.height > 0 {
            let scale = max(width / rect.width, height / rect.height)
            width = rect.width * scale
            height = rect.height * scale
        }
        // Grow away from the anchor, toward where the pointer is.
        let x = point.x >= anchor.x ? anchor.x : anchor.x - width
        let y = point.y >= anchor.y ? anchor.y : anchor.y - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Constraints

    /// The drag from `start` to `end` as a square (or circle) when constrained.
    static func shapeRect(from start: CGPoint, to end: CGPoint, constrained: Bool) -> CGRect {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if constrained {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: start.x, y: start.y, width: dx, height: dy).standardized
    }

    /// `end` snapped so the line from `start` lies on a 45° step.
    static func snappedEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private static func hitsShape(_ kind: ShapeKind, rect: CGRect, at point: CGPoint, reach: CGFloat, countsInside: Bool) -> Bool {
        switch kind {
        case .rectangle:
            if countsInside, rect.insetBy(dx: -reach, dy: -reach).contains(point) { return true }
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            ]
            return distance(from: point, toPolyline: corners + [corners[0]]) <= reach
        case .ellipse:
            let radiusX = rect.width / 2
            let radiusY = rect.height / 2
            guard radiusX > 0, radiusY > 0 else {
                return distance(from: point, toSegment: CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)) <= reach
            }
            let nx = (point.x - rect.midX) / radiusX
            let ny = (point.y - rect.midY) / radiusY
            let normalized = (nx * nx + ny * ny).squareRoot()
            if countsInside, normalized <= 1 { return true }
            // Distance to the outline, measured along the ray from the center.
            let fromCenter = hypot(point.x - rect.midX, point.y - rect.midY)
            let outlineRadius = normalized > 0.0001 ? fromCenter / normalized : min(radiusX, radiusY)
            return abs(fromCenter - outlineRadius) <= reach
        }
    }
}
