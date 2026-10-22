import CoreGraphics
import Foundation

/// A clean shape a rough freehand stroke was recognized as.
enum RecognizedShape: Equatable, Sendable {
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    /// A triangle, or a four-cornered shape that isn't upright.
    case polygon([CGPoint])
}

/// Recognizes rough shapes for the magic pen, and the zig-zag that scratches ink out. Pure.
enum ShapeRecognizer {
    /// Strokes smaller than this (bounding-box diagonal, points) are never snapped.
    static let minimumSize: CGFloat = 24
    /// Points are resampled evenly along the stroke before analysis.
    static let sampleCount = 64

    /// How closely the stroke has to follow each shape, as mean distance over the bounding-box diagonal.
    static let maximumEllipseError: CGFloat = 0.04
    static let maximumPolygonError: CGFloat = 0.035
    /// End-to-end distance over path length at which a stroke counts as a straight line.
    static let minimumStraightness: CGFloat = 0.94
    /// Rectangle edges this close to horizontal or vertical snap upright.
    static let uprightTolerance: CGFloat = 12 * .pi / 180

    /// The shape the stroke was meant to be, or nil when it doesn't fit one confidently
    /// (handwriting, scribbles), so it stays freehand.
    static func recognize(_ input: [CGPoint]) -> RecognizedShape? {
        let points = deduplicated(input)
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let bounds = CanvasItem.boundingBox(of: points)
        let diagonal = hypot(bounds.width, bounds.height)
        let length = pathLength(points)
        guard diagonal >= minimumSize, length > 0 else { return nil }
        let samples = resample(points, count: sampleCount)
        let chord = distance(first, last)

        if chord / length >= minimumStraightness,
           samples.allSatisfy({ CanvasHitTester.distance(from: $0, toSegment: first, last) <= chord * 0.06 }) {
            return .line(from: first, to: last)
        }
        if let arrow = arrow(samples, diagonal: diagonal) {
            return arrow
        }
        // Closed shapes end near where they started.
        guard chord <= diagonal * 0.3 else { return nil }

        let ellipseRect = bounds
        let ellipseError = self.ellipseError(samples, in: ellipseRect) / diagonal
        var best: (shape: RecognizedShape, error: CGFloat)?
        if ellipseError <= maximumEllipseError {
            best = (.ellipse(ellipseRect), ellipseError)
        }
        let corners = self.corners(samples, diagonal: diagonal)
        if corners.count == 3 || corners.count == 4 {
            let error = polygonError(samples, corners: corners) / diagonal
            if error <= maximumPolygonError, error < (best?.error ?? .infinity) {
                best = (polygonShape(corners), error)
            }
        }
        return best?.shape
    }

    // MARK: Scratch-out

    /// A fast zig-zag: at least five passes back and forth along one direction, quickly.
    /// The caller decides whether it covered any ink.
    static func isScratchOut(_ samples: [InkSample]) -> Bool {
        let points = deduplicated(samples.map(\.point))
        guard points.count >= 8, let start = samples.first, let end = samples.last else { return false }
        let length = pathLength(points)
        guard length >= 120 else { return false }
        let duration = end.time - start.time
        // Quick: under two seconds and moving at a fair pace.
        guard duration > 0, duration <= 2, length / CGFloat(duration) >= 300 else { return false }

        let axis = principalAxis(points)
        let projections = points.map { $0.x * axis.x + $0.y * axis.y }
        guard let low = projections.min(), let high = projections.max() else { return false }
        let extent = high - low
        guard extent >= 20, length >= extent * 3 else { return false }
        return reversals(projections, threshold: extent * 0.3) >= 4
    }

    /// How many times a sequence changes direction by more than `threshold`.
    static func reversals(_ values: [CGFloat], threshold: CGFloat) -> Int {
        guard var extreme = values.first else { return 0 }
        var direction: CGFloat = 0
        var count = 0
        for value in values.dropFirst() {
            if direction == 0 {
                if abs(value - extreme) >= threshold {
                    direction = value > extreme ? 1 : -1
                    extreme = value
                }
            } else if (value - extreme) * direction > 0 {
                extreme = value
            } else if abs(value - extreme) >= threshold {
                count += 1
                direction = -direction
                extreme = value
            }
        }
        return count
    }

    // MARK: Arrows

    /// A straight shaft followed by a small head drawn without lifting: everything after the
    /// shaft's end stays close to it and behind it.
    private static func arrow(_ samples: [CGPoint], diagonal: CGFloat) -> RecognizedShape? {
        let vertices = simplify(samples, epsilon: diagonal * 0.05)
        guard vertices.count >= 4, let start = vertices.first else { return nil }
        let tipIndex = vertices[1]
        let shaftStart = samples[start]
        let tip = samples[tipIndex]
        let shaft = distance(shaftStart, tip)
        guard shaft >= diagonal * 0.6 else { return nil }
        let direction = CGPoint(x: (tip.x - shaftStart.x) / shaft, y: (tip.y - shaftStart.y) / shaft)
        let head = samples[tipIndex...]
        let headLength = pathLength(Array(head))
        guard headLength >= shaft * 0.2, headLength <= shaft * 1.6 else { return nil }
        let tipProjection = tip.x * direction.x + tip.y * direction.y
        let fitsHead = head.allSatisfy { point in
            distance(point, tip) <= shaft * 0.45
                && point.x * direction.x + point.y * direction.y <= tipProjection + shaft * 0.08
        }
        // The head has to spread to both sides of the shaft, like barbs.
        let sides = head.map { ($0.x - tip.x) * direction.y - ($0.y - tip.y) * direction.x }
        let spreads = (sides.max() ?? 0) >= shaft * 0.05 && (sides.min() ?? 0) <= -shaft * 0.05
        guard fitsHead, spreads else { return nil }
        return .arrow(from: shaftStart, to: tip)
    }

    // MARK: Closed shapes

    /// Mean distance from the samples to the ellipse inscribed in `rect`, measured along rays from its center.
    static func ellipseError(_ samples: [CGPoint], in rect: CGRect) -> CGFloat {
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        guard radiusX > 0, radiusY > 0, !samples.isEmpty else { return .infinity }
        let total = samples.reduce(CGFloat(0)) { sum, point in
            let nx = (point.x - rect.midX) / radiusX
            let ny = (point.y - rect.midY) / radiusY
            let normalized = (nx * nx + ny * ny).squareRoot()
            let fromCenter = hypot(point.x - rect.midX, point.y - rect.midY)
            let outline = normalized > 0.0001 ? fromCenter / normalized : min(radiusX, radiusY)
            return sum + abs(fromCenter - outline)
        }
        return total / CGFloat(samples.count)
    }

    /// The corners of a closed stroke: simplified, with the start and end merged and nearly
    /// straight vertices dropped (a stroke can start halfway along an edge).
    static func corners(_ samples: [CGPoint], diagonal: CGFloat) -> [CGPoint] {
        var corners = simplify(samples, epsilon: diagonal * 0.07).map { samples[$0] }
        guard corners.count >= 3, let first = corners.first, let last = corners.last else { return corners }
        corners.removeLast()
        corners[0] = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        var changed = true
        while changed, corners.count > 2 {
            changed = false
            for index in corners.indices {
                let previous = corners[(index + corners.count - 1) % corners.count]
                let next = corners[(index + 1) % corners.count]
                if turn(previous, corners[index], next) < 35 * .pi / 180 || distance(previous, corners[index]) < diagonal * 0.08 {
                    corners.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        return corners
    }

    static func polygonError(_ samples: [CGPoint], corners: [CGPoint]) -> CGFloat {
        guard corners.count >= 2, !samples.isEmpty else { return .infinity }
        let closed = corners + [corners[0]]
        let total = samples.reduce(CGFloat(0)) { $0 + CanvasHitTester.distance(from: $1, toPolyline: closed) }
        return total / CGFloat(samples.count)
    }

    private static func polygonShape(_ corners: [CGPoint]) -> RecognizedShape {
        guard corners.count == 4 else { return .polygon(corners) }
        let upright = corners.indices.allSatisfy { index in
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let angle = abs(atan2(b.y - a.y, b.x - a.x)).truncatingRemainder(dividingBy: .pi / 2)
            return min(angle, .pi / 2 - angle) <= uprightTolerance
        }
        return upright ? .rectangle(CanvasItem.boundingBox(of: corners)) : .polygon(corners)
    }

    /// How sharply the path turns at `b`, in radians: 0 is straight on, π doubles back.
    private static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let first = atan2(b.y - a.y, b.x - a.x)
        let second = atan2(c.y - b.y, c.x - b.x)
        var difference = abs(second - first)
        if difference > .pi {
            difference = 2 * .pi - difference
        }
        return difference
    }

    // MARK: Geometry helpers

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// `count` points evenly spaced along the path, first and last included.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard let first = points.first, points.count > 1, count > 1 else { return points }
        let interval = pathLength(points) / CGFloat(count - 1)
        guard interval > 0 else { return Array(repeating: first, count: count) }
        var result = [first]
        var carried: CGFloat = 0
        var previous = first
        for point in points.dropFirst() {
            var segmentStart = previous
            var segment = distance(segmentStart, point)
            while carried + segment >= interval, result.count < count - 1 {
                let t = (interval - carried) / segment
                let sample = CGPoint(x: segmentStart.x + (point.x - segmentStart.x) * t, y: segmentStart.y + (point.y - segmentStart.y) * t)
                result.append(sample)
                segmentStart = sample
                segment = distance(segmentStart, point)
                carried = 0
            }
            carried += segment
            previous = point
        }
        result.append(points[points.count - 1])
        return result
    }

    /// Ramer–Douglas–Peucker: indices of the points that keep the path within `epsilon`.
    static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end - start > 1 else { continue }
            var farthest = start
            var farthestDistance: CGFloat = 0
            for index in (start + 1)..<end {
                let d = CanvasHitTester.distance(from: points[index], toSegment: points[start], points[end])
                if d > farthestDistance {
                    farthestDistance = d
                    farthest = index
                }
            }
            if farthestDistance > epsilon {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// The unit direction along which the points spread the most.
    static func principalAxis(_ points: [CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var xx: CGFloat = 0, xy: CGFloat = 0, yy: CGFloat = 0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where result.last != point {
            result.append(point)
        }
        return result
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
