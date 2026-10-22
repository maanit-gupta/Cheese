import CoreGraphics
import Foundation

/// One pointer sample of a stroke.
struct InkSample: Equatable, Sendable {
    var point: CGPoint
    /// 0…1 as the device reports it: a mouse button reads 1 while pressed; tablets and Force Touch
    /// trackpads vary.
    var pressure: CGFloat
    /// Seconds, from the event's timestamp.
    var time: TimeInterval
}
