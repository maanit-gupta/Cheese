import AppKit
import QuartzCore

/// A soft accent-colored circle that follows the pointer during a recording, and ripples on each
/// click. It's drawn in a click-through window above everything that's part of the recording;
/// the real cursor is recorded on top of it as usual.
@MainActor
final class CursorHalo {
    static let diameter: CGFloat = 40

    private var window: NSPanel?
    private var halo: CALayer?
    private var monitors: [Any] = []

    /// The window the recording should include.
    var windowID: CGWindowID? {
        window.map { CGWindowID($0.windowNumber) }
    }

    /// Covers `screen`.
    func show(on screen: NSScreen) {
        guard window == nil else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Before `level`: setting it afterwards would put the level back to `.floating`.
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setFrame(screen.frame, display: false)

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let halo = CALayer()
        halo.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        halo.cornerRadius = Self.diameter / 2
        halo.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(DesignTokens.Opacity.activeTint).cgColor
        halo.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        halo.borderWidth = 1.5
        halo.contentsScale = screen.backingScaleFactor
        view.layer?.addSublayer(halo)
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
        self.halo = halo
        move(to: NSEvent.mouseLocation)

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let handler: (NSEvent) -> Void = { [weak self] event in
            let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown
            MainActor.assumeIsolated {
                self?.move(to: NSEvent.mouseLocation)
                if isClick { self?.pulse() }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves.union(clicks), handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves.union(clicks), handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        window?.close()
        window = nil
        halo = nil
    }

    /// `point` in AppKit global coordinates.
    private func move(to point: NSPoint) {
        guard let window, let halo else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.position = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        CATransaction.commit()
    }

    /// A ring that grows and fades from the halo.
    private func pulse() {
        guard let halo, let host = halo.superlayer, !DesignTokens.reducesMotion else { return }
        let ring = CALayer()
        ring.bounds = halo.bounds
        ring.position = halo.position
        ring.cornerRadius = halo.cornerRadius
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.borderWidth = 2
        ring.contentsScale = halo.contentsScale
        host.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "pulse")
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            ring.removeFromSuperlayer()
        }
    }
}
