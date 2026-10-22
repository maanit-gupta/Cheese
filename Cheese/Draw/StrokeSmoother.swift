import CoreGraphics

/// Freehand smoothing with quadratic curves through the midpoints of the input points: each input
/// point becomes the control point of a curve between its neighbours' midpoints. The stroke still
/// starts and ends exactly where the pointer did.
enum StrokeSmoother {
    struct Curve: Equatable {
        var control: CGPoint
        var end: CGPoint
    }

    /// Drops points closer than `minimumDistance` to the last kept one (always keeping the last point),
    /// so jitter from a still pointer doesn't add kinks.
    static func filtered(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        var kept = [first]
        for point in points.dropFirst().dropLast() where distance(point, kept[kept.count - 1]) >= minimumDistance {
            kept.append(point)
        }
        if points.count > 1 {
            // The stroke ends exactly where the pointer did; a kept point too close to the end gives way.
            if kept.count > 1, distance(last, kept[kept.count - 1]) < minimumDistance {
                kept.removeLast()
            }
            kept.append(last)
        }
        return kept
    }

    /// The smoothed path as a start point plus quadratic curves.
    static func curves(through points: [CGPoint]) -> (start: CGPoint, curves: [Curve])? {
        guard let first = points.first else { return nil }
        guard points.count > 2 else {
            return (first, points.dropFirst().map { Curve(control: midpoint(first, $0), end: $0) })
        }
        var curves = [Curve(control: midpoint(first, midpoint(points[0], points[1])), end: midpoint(points[0], points[1]))]
        for index in 1..<(points.count - 1) {
            curves.append(Curve(control: points[index], end: midpoint(points[index], points[index + 1])))
        }
        let last = points[points.count - 1]
        let lastMid = midpoint(points[points.count - 2], last)
        curves.append(Curve(control: midpoint(lastMid, last), end: last))
        return (first, curves)
    }

    /// The smoothed path sampled as a polyline, for hit-testing and tests.
    static func smoothed(_ points: [CGPoint], samplesPerCurve: Int = 6) -> [CGPoint] {
        guard let (start, curves) = curves(through: points) else { return [] }
        var result = [start]
        var current = start
        for curve in curves {
            for step in 1...max(samplesPerCurve, 1) {
                let t = CGFloat(step) / CGFloat(max(samplesPerCurve, 1))
                result.append(quadratic(from: current, control: curve.control, to: curve.end, t: t))
            }
            current = curve.end
        }
        return result
    }

    static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let (start, curves) = curves(through: points) else { return path }
        path.move(to: start)
        if curves.isEmpty {
            // A dot: a zero-length line still draws a round cap.
            path.addLine(to: start)
        }
        for curve in curves {
            path.addQuadCurve(to: curve.end, control: curve.control)
        }
        return path
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func quadratic(from start: CGPoint, control: CGPoint, to end: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }
}
