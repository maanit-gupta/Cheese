import AppKit

/// A transparent, click-through-capable panel over one display for drawing. Above normal and
/// floating windows, on every Space and over full-screen apps. Non-activating, so the app the user
/// was in stays frontmost while they draw.
final class DrawOverlayWindow: NSPanel {
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    let displayID: CGDirectDisplayID

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = Self.overlayLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // Keyboard shortcuts and text editing need key status.
    override var canBecomeKey: Bool { true }
}
