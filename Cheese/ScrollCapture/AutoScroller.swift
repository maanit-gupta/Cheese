import CoreGraphics
import os

/// Moves the pointer and scrolls, behind a protocol so sessions can be tested without real events.
@MainActor
protocol ScrollPerforming {
    func movePointer(to point: CGPoint)
    /// Scrolls the content under `point` (Quartz global) by `points`; positive moves toward the end of the page.
    func scroll(by points: Int32, at point: CGPoint) async
}

/// Synthesizes scroll-wheel events. Needs Accessibility.
@MainActor
struct AutoScroller: ScrollPerforming {
    /// Large scrolls go out as several small events, the way a trackpad sends them; some apps ignore
    /// or clamp a single huge delta.
    static let chunkSize: Int32 = 40

    /// Puts the pointer over the content, since scroll events go to whatever is under it.
    func movePointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }

    func scroll(by points: Int32, at point: CGPoint) async {
        let direction: Int32 = points < 0 ? -1 : 1
        var remaining = abs(points)
        while remaining > 0 {
            let amount = min(remaining, Self.chunkSize)
            // Negative wheel deltas scroll down.
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: -direction * amount, wheel2: 0, wheel3: 0
            ) else {
                Logger.scrollCapture.error("Couldn't create a scroll event")
                return
            }
            event.location = point
            event.post(tap: .cghidEventTap)
            remaining -= amount
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}
