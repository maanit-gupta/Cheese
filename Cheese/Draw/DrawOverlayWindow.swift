import AppKit

/// Where draw mode's windows sit, in one place. The canvas is above normal and floating windows;
/// the HUD and its popovers are above the canvas; everything else Cheese opens while drawing (the
/// command palette, Share, QR, the shelf) is a `CheesePanel` at `.modalPanel` or `.floating`
/// behavior level, which the palette's `.modalPanel` keeps above both.
enum DrawLevels {
    static let canvas = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    static let hud = NSWindow.Level(rawValue: canvas.rawValue + 1)
    /// The command palette and the other popups' default level.
    static let panels = NSWindow.Level.modalPanel
}

/// A transparent, click-through-capable panel over one display for drawing. Above normal and
/// floating windows, on every Space and over full-screen apps. Non-activating, so the app the user
/// was in stays frontmost while they draw.
final class DrawOverlayWindow: NSPanel {
    let displayID: CGDirectDisplayID

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // Before `level`: turning on isFloatingPanel resets the level to `.floating`.
        isFloatingPanel = true
        level = DrawLevels.canvas
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // Keyboard shortcuts and text editing need key status, except in pass-through, where the
    // keyboard belongs to the app underneath.
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}
