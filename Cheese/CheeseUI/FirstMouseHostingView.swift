import AppKit
import SwiftUI

/// SwiftUI content for a panel that never becomes key, like the draw HUD. A plain `NSHostingView`
/// doesn't accept first mouse, so in a non-key window of an app that isn't active the first click
/// is spent on activation and the button under it does nothing. This takes that first click, and
/// answers for every point inside it, so gaps between controls never let a click fall through.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let view = super.hitTest(point) {
            return view
        }
        return frame.contains(point) ? self : nil
    }
}
