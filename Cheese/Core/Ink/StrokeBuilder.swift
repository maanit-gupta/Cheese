import CoreGraphics

/// Turns pointer samples into the outline of a variable-width stroke: a closed polygon that's
/// filled, not a path that's stroked. Faster movement draws thinner, harder pressure draws thicker,
/// and the ends taper. A Swift port of the approach in the MIT-licensed perfect-freehand library
/// by Steve Ruiz (https://github.com/steveruizok/perfect-freehand).
enum StrokeBuilder {
    struct Options: Equatable, Sendable {
        /// The nominal diameter, in points.
        var size: CGFloat
        /// How much speed or pressure changes the width: 0 keeps it constant.
        var thinning: CGFloat = 0.5
        /// How much the outline's own corners are softened.
        var smoothing: CGFloat = 0.5
        /// How strongly points are eased toward the input: 0 follows it exactly. Kept low: easing
        /// makes the ink trail the pointer, and the 1€ filter already removes jitter.
        var streamline: CGFloat = 0.1
        /// Derive pressure from speed, for devices that don't report it (mice, most trackpads).
        var simulatesPressure = true
        /// Distances, in points, over which the start and end narrow to a point. 0 rounds them.
        var taperStart: CGFloat = 0
        var taperEnd: CGFloat = 0
        /// The stroke ends exactly at its last point rather than easing toward it.
        var isComplete = true

        /// The pen: thins with speed, tapered at both ends.
        static func pen(width: CGFloat, simulatesPressure: Bool = true) -> Options {
            let taper = min(width * 2.5, 28)
            return Options(size: width, simulatesPressure: simulatesPressure, taperStart: taper, taperEnd: taper)
        }

        /// The highlighter: a constant width with round ends.
        static func highlighter(width: CGFloat) -> Options {
            Options(size: width, thinning: 0, simulatesPressure: false)
        }
    }

    /// A point after easing, with the direction it came from and how far along the stroke it is.
    struct StrokePoint: Equatable, Sendable {
        var point: CGPoint
        var pressure: CGFloat
        /// Unit vector from this point back toward the previous one.
        var vector: CGPoint
        var distance: CGFloat
        var runningLength: CGFloat
    }

    /// How quickly simulated pressure follows changes in speed.
    static let rateOfPressureChange: CGFloat = 0.275
    /// Pressure used when a device doesn't report any.
    static let defaultPressure: CGFloat = 0.5
    /// Slightly more than π so rotated cap points never land exactly on each other.
    private static let fixedPi = CGFloat.pi + 0.0001

    /// Whether these pressures vary like a tablet's or a Force Touch trackpad's, rather than a
    /// mouse button's fixed 0 or 1.
    static func hasAnalogPressure(_ pressures: [CGFloat]) -> Bool {
        pressures.contains { $0 > 0.02 && $0 < 0.98 }
    }

    /// The filled outline for these samples. `pressures` may be empty, or shorter than `points`.
    static func outline(points: [CGPoint], pressures: [CGFloat] = [], options: Options) -> [CGPoint] {
        outline(strokePoints(points: points, pressures: pressures, options: options), options: options)
    }

    /// The outline as a closed path, its corners rounded with quadratic curves through edge midpoints.
    static func path(points: [CGPoint], pressures: [CGFloat] = [], options: Options) -> CGPath {
        path(outline: outline(points: points, pressures: pressures, options: options))
    }

    static func path(outline: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let count = outline.count
        guard count > 2 else { return path }
        path.move(to: midpoint(outline[0], outline[1]))
        for index in 1...count {
            let control = outline[index % count]
            let next = outline[(index + 1) % count]
            path.addQuadCurve(to: midpoint(control, next), control: control)
        }
        path.closeSubpath()
        return path
    }

    // MARK: Easing the input

    static func strokePoints(points: [CGPoint], pressures: [CGFloat], options: Options) -> [StrokePoint] {
        guard !points.isEmpty else { return [] }
        let t = 0.15 + (1 - options.streamline) * 0.85
        var input = points.enumerated().map { index, point in
            (point: point, pressure: index < pressures.count ? pressures[index] : defaultPressure)
        }
        // Two points become five, so the stroke still gets a shape between them.
        if input.count == 2 {
            let (a, b) = (input[0], input[1])
            input = [a] + (1...4).map { step in
                let f = CGFloat(step) / 4
                return (lerp(a.point, b.point, f), a.pressure + (b.pressure - a.pressure) * f)
            }
        }
        // A single point gets a neighbour, so it draws as a dot.
        if input.count == 1 {
            input.append((CGPoint(x: input[0].point.x + 1, y: input[0].point.y + 1), input[0].pressure))
        }

        var result = [StrokePoint(point: input[0].point, pressure: input[0].pressure, vector: CGPoint(x: 1, y: 1), distance: 0, runningLength: 0)]
        var reachedMinimumLength = false
        var runningLength: CGFloat = 0
        var previous = result[0]
        let lastIndex = input.count - 1
        for index in 1...lastIndex {
            let point = options.isComplete && index == lastIndex ? input[index].point : lerp(previous.point, input[index].point, t)
            if point == previous.point { continue }
            let distance = self.distance(point, previous.point)
            runningLength += distance
            // Skip the first few points until the stroke is as long as it is wide: they only add noise.
            if index < lastIndex, !reachedMinimumLength {
                if runningLength < options.size { continue }
                reachedMinimumLength = true
            }
            previous = StrokePoint(
                point: point,
                pressure: input[index].pressure,
                vector: unit(subtract(previous.point, point)),
                distance: distance,
                runningLength: runningLength
            )
            result.append(previous)
        }
        result[0].vector = result.count > 1 ? result[1].vector : .zero
        return result
    }

    // MARK: Outline

    static func outline(_ points: [StrokePoint], options: Options) -> [CGPoint] {
        guard let firstPoint = points.first, let lastStrokePoint = points.last, options.size > 0 else { return [] }
        let size = options.size
        let totalLength = lastStrokePoint.runningLength
        // Short strokes and dots keep round ends; tapering them would leave almost nothing.
        let taperStart = totalLength < size ? 0 : min(options.taperStart, totalLength * 0.4)
        let taperEnd = totalLength < size ? 0 : min(options.taperEnd, totalLength * 0.4)
        let minimumDistance = pow(size * options.smoothing, 2)

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        var previousPressure = points.prefix(10).reduce(firstPoint.pressure) { accumulated, current in
            var pressure = current.pressure
            if options.simulatesPressure {
                pressure = simulatedPressure(after: accumulated, distance: current.distance, size: size)
            }
            return (accumulated + pressure) / 2
        }
        var radius = strokeRadius(size: size, thinning: options.thinning, pressure: lastStrokePoint.pressure)
        var firstRadius: CGFloat?
        var previousVector = firstPoint.vector
        var previousLeft = firstPoint.point
        var previousRight = firstPoint.point
        var isPreviousSharpCorner = false

        for index in points.indices {
            let current = points[index]
            var pressure = current.pressure
            let isLast = index == points.count - 1
            // The last few points are noisy; the final point stands in for them.
            if !isLast, totalLength - current.runningLength < 3 { continue }

            if options.thinning != 0 {
                if options.simulatesPressure {
                    pressure = simulatedPressure(after: previousPressure, distance: current.distance, size: size)
                }
                radius = strokeRadius(size: size, thinning: options.thinning, pressure: pressure)
            } else {
                radius = size / 2
            }
            if firstRadius == nil {
                firstRadius = radius
            }

            let startScale = current.runningLength < taperStart ? easeOutQuad(current.runningLength / taperStart) : 1
            let remaining = totalLength - current.runningLength
            let endScale = remaining < taperEnd ? easeOutCubic(remaining / taperEnd) : 1
            radius = max(0.01, radius * min(startScale, endScale))

            let nextVector = isLast ? current.vector : points[index + 1].vector
            let nextDot = isLast ? 1 : dot(current.vector, nextVector)
            let previousDot = dot(current.vector, previousVector)
            let isSharpCorner = previousDot < 0 && !isPreviousSharpCorner
            let isNextSharpCorner = nextDot < 0

            // A hairpin turn: draw a half circle around the point so the outline doesn't fold over.
            if isSharpCorner || isNextSharpCorner {
                let offset = scale(perpendicular(previousVector), radius)
                var turnLeft = previousLeft
                var turnRight = previousRight
                for step in 0...13 {
                    let angle = fixedPi * CGFloat(step) / 13
                    turnLeft = rotate(subtract(current.point, offset), around: current.point, by: angle)
                    left.append(turnLeft)
                    turnRight = rotate(add(current.point, offset), around: current.point, by: -angle)
                    right.append(turnRight)
                }
                previousLeft = turnLeft
                previousRight = turnRight
                if isNextSharpCorner {
                    isPreviousSharpCorner = true
                }
                continue
            }
            isPreviousSharpCorner = false

            if isLast {
                let offset = scale(perpendicular(current.vector), radius)
                left.append(subtract(current.point, offset))
                right.append(add(current.point, offset))
                continue
            }

            let offset = scale(perpendicular(lerp(nextVector, current.vector, nextDot)), radius)
            let leftPoint = subtract(current.point, offset)
            if index <= 1 || distanceSquared(previousLeft, leftPoint) > minimumDistance {
                left.append(leftPoint)
                previousLeft = leftPoint
            }
            let rightPoint = add(current.point, offset)
            if index <= 1 || distanceSquared(previousRight, rightPoint) > minimumDistance {
                right.append(rightPoint)
                previousRight = rightPoint
            }
            previousPressure = pressure
            previousVector = current.vector
        }

        let first = firstPoint.point
        let last = points.count > 1 ? lastStrokePoint.point : add(first, CGPoint(x: 1, y: 1))

        if points.count == 1 || left.isEmpty || right.isEmpty {
            // A dot: a circle around the first point.
            let dotRadius = firstRadius ?? radius
            let start = add(first, scale(unit(perpendicular(subtract(first, last))), -dotRadius))
            return (1...13).map { rotate(start, around: first, by: fixedPi * 2 * CGFloat($0) / 13) }
        }

        var startCap: [CGPoint] = []
        if taperStart == 0 {
            for step in 0...13 {
                startCap.append(rotate(right[0], around: first, by: fixedPi * CGFloat(step) / 13))
            }
        }
        var endCap: [CGPoint] = []
        if taperEnd > 0 {
            endCap.append(last)
        } else {
            let direction = perpendicular(scale(lastStrokePoint.vector, -1))
            let start = add(last, scale(direction, radius))
            for step in 1..<29 {
                endCap.append(rotate(start, around: last, by: fixedPi * 3 * CGFloat(step) / 29))
            }
        }
        return left + endCap + right.reversed() + startCap
    }

    static func strokeRadius(size: CGFloat, thinning: CGFloat, pressure: CGFloat) -> CGFloat {
        size * (0.5 - thinning * (0.5 - pressure))
    }

    /// Slow movement presses harder; fast movement lightens up.
    private static func simulatedPressure(after previous: CGFloat, distance: CGFloat, size: CGFloat) -> CGFloat {
        let speed = min(1, distance / size)
        let target = min(1, 1 - speed)
        return min(1, previous + (target - previous) * (speed * rateOfPressureChange))
    }

    private static func easeOutQuad(_ t: CGFloat) -> CGFloat {
        t * (2 - t)
    }

    private static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let u = t - 1
        return u * u * u + 1
    }

    // MARK: Vector math

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + b.x, y: a.y + b.y)
    }

    private static func subtract(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x - b.x, y: a.y - b.y)
    }

    private static func scale(_ a: CGPoint, _ factor: CGFloat) -> CGPoint {
        CGPoint(x: a.x * factor, y: a.y * factor)
    }

    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        a.x * b.x + a.y * b.y
    }

    private static func perpendicular(_ a: CGPoint) -> CGPoint {
        CGPoint(x: a.y, y: -a.x)
    }

    private static func unit(_ a: CGPoint) -> CGPoint {
        let length = hypot(a.x, a.y)
        return length > 0 ? CGPoint(x: a.x / length, y: a.y / length) : .zero
    }

    private static func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let s = sin(angle)
        let c = cos(angle)
        let px = point.x - center.x
        let py = point.y - center.y
        return CGPoint(x: px * c - py * s + center.x, y: px * s + py * c + center.y)
    }
}
