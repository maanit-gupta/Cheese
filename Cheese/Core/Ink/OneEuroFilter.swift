import CoreGraphics
import Foundation

/// The 1€ filter (Casiez, Roussel and Vogel, 2012) for pointer input. It smooths hard while the
/// pointer is slow, where jitter shows, and barely at all while it's fast, where lag would show.
/// Works on points and seconds.
struct OneEuroFilter: Sendable {
    /// The cutoff frequency, in Hz, at rest. Lower removes more jitter from slow strokes, but the
    /// ink trails the pointer by about 1 / (2π × cutoff) seconds.
    var minimumCutoff: Double = 10
    /// How fast the cutoff rises with speed (per point/second). Higher keeps fast strokes tighter.
    var beta: Double = 0.05
    /// The cutoff for smoothing the speed itself.
    var derivativeCutoff: Double = 1

    private var previous: (point: CGPoint, time: TimeInterval, speed: Double)?

    /// The interval assumed when two samples share a timestamp: one 120 Hz frame.
    static let fallbackInterval: TimeInterval = 1.0 / 120

    init(minimumCutoff: Double = 10, beta: Double = 0.05, derivativeCutoff: Double = 1) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// The smoothing factor of a low-pass filter with `cutoff` Hz, sampled every `interval` seconds.
    static func alpha(cutoff: Double, interval: TimeInterval) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / interval)
    }

    /// Feeds one sample and returns it filtered. The first sample passes through unchanged.
    mutating func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        guard let previous else {
            self.previous = (point, time, 0)
            return point
        }
        let elapsed = time - previous.time
        let interval = elapsed > 0 ? elapsed : Self.fallbackInterval
        let rawSpeed = Double(hypot(point.x - previous.point.x, point.y - previous.point.y)) / interval
        let speedAlpha = Self.alpha(cutoff: derivativeCutoff, interval: interval)
        let speed = previous.speed + speedAlpha * (rawSpeed - previous.speed)
        let cutoff = minimumCutoff + beta * speed
        let alpha = CGFloat(Self.alpha(cutoff: cutoff, interval: interval))
        let filtered = CGPoint(
            x: previous.point.x + alpha * (point.x - previous.point.x),
            y: previous.point.y + alpha * (point.y - previous.point.y)
        )
        self.previous = (filtered, time, speed)
        return filtered
    }

    mutating func reset() {
        previous = nil
    }
}
