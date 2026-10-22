import CoreGraphics

/// Captures the same screen region over and over, cheaply. Capture provides it; scrolling capture uses it.
@MainActor
protocol RegionCapturing {
    /// Pixels per point of the captured region.
    var scale: CGFloat { get }
    func capture() async throws -> CGImage
}
