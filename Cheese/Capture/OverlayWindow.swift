import AppKit

/// A borderless window covering one display above everything, including the menu bar and full-screen apps.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // Borderless windows refuse key status by default; overlays need it for Esc.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows overlay windows on every display and restores the previously active app afterwards.
@MainActor
final class OverlaySession {
    private(set) var windows: [OverlayWindow] = []
    /// The app that was in front before the overlay appeared.
    let previousApp: NSRunningApplication?

    init() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
    }

    func show(_ makeContent: (NSScreen) -> NSView?) {
        for screen in NSScreen.screens {
            guard let content = makeContent(screen) else { continue }
            let window = OverlayWindow(screen: screen)
            content.frame = CGRect(origin: .zero, size: screen.frame.size)
            window.contentView = content
            windows.append(window)
        }
        NSApp.activate()
        for window in windows {
            window.orderFrontRegardless()
        }
        // The display under the pointer gets keyboard focus, so Esc works right away.
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()
        if let view = keyWindow?.contentView {
            keyWindow?.makeFirstResponder(view)
        }
        NSCursor.crosshair.set()
    }

    /// Closes the overlays. Pass `restoreFocus: false` when Cheese opens a window of its own next.
    func end(restoreFocus: Bool) {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        NSCursor.arrow.set()
        if restoreFocus {
            previousApp?.activate()
        }
    }
}
