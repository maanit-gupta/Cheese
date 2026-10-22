import AppKit
import SwiftUI

/// The floating, non-activating container every Cheese popup uses. It takes keyboard focus without
/// activating Cheese, so the app the user was in stays frontmost. `Esc` calls `onCancel`, and so do
/// clicks outside it unless `Behavior.dismissesOnOutsideClick` is off.
@MainActor
final class CheesePanel: NSPanel {
    struct Behavior {
        /// Clicks anywhere outside the panel call `onCancel` (the palette, the QR panel).
        var dismissesOnOutsideClick = true
        /// The user can drag the panel by its background (the shelf).
        var isMovable = false
        var level: NSWindow.Level = .modalPanel
    }

    /// Where `present` puts the panel.
    enum Placement {
        /// Centered on the display under the pointer.
        case centered
        /// Just below and right of the pointer, kept on its display.
        case nearPointer
        /// Where the user last dragged it, saved under `key`; `fallback` until then.
        case remembered(key: String, fallback: Fallback)

        enum Fallback {
            case centered
            case nearPointer
        }
    }

    var onCancel: () -> Void = {}
    private let behavior: Behavior
    private var clickMonitors: [Any] = []
    private var rememberedKey: String?
    private var moveObserver: NSObjectProtocol?

    init(rootView: some View, behavior: Behavior = Behavior()) {
        self.behavior = behavior
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = behavior.level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = behavior.isMovable
        animationBehavior = DesignTokens.reducesMotion ? .none : .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    /// Places the panel and focuses it.
    func present(at placement: Placement = .centered) {
        // Size to the SwiftUI content now; on first show the window hasn't been sized yet.
        if let fitting = contentViewController?.view.fittingSize, fitting.width > 0, fitting.height > 0 {
            setContentSize(fitting)
        }
        place(placement)
        makeKeyAndOrderFront(nil)
        if behavior.dismissesOnOutsideClick {
            installClickMonitors()
        }
    }

    func dismiss() {
        removeClickMonitors()
        orderOut(nil)
    }

    // MARK: Placement

    private func place(_ placement: Placement) {
        let screen = Screens.underMouse
        switch placement {
        case .centered:
            center(on: screen)
        case .nearPointer:
            placeNearPointer(on: screen)
        case let .remembered(key, fallback):
            rememberedKey = key
            observeMoves()
            if let origin = PanelPositions.origin(forKey: key),
               NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: origin, size: frame.size)) }) {
                setFrameOrigin(origin)
            } else {
                switch fallback {
                case .centered: center(on: screen)
                case .nearPointer: placeNearPointer(on: screen)
                }
            }
        }
    }

    private func center(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    private func placeNearPointer(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(PanelPositions.origin(nearPointer: NSEvent.mouseLocation, size: frame.size, in: visible))
    }

    /// Saves the position whenever the user drags the panel somewhere.
    private func observeMoves() {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.rememberedKey, self.isVisible else { return }
                PanelPositions.save(self.frame.origin, forKey: key)
            }
        }
    }

    // MARK: Clicks outside

    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel() }
        }) {
            clickMonitors.append(global)
        }
        // Clicks in Cheese's other windows.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                if let self, window !== self { self.onCancel() }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }
}

/// Remembered panel positions, and the pure placement math behind `CheesePanel`.
enum PanelPositions {
    private static func defaultsKey(_ key: String) -> String {
        "panelOrigin_\(key)"
    }

    static func origin(forKey key: String, defaults: UserDefaults = .standard) -> NSPoint? {
        guard let values = defaults.array(forKey: defaultsKey(key)) as? [Double], values.count == 2 else { return nil }
        return NSPoint(x: values[0], y: values[1])
    }

    static func save(_ origin: NSPoint, forKey key: String, defaults: UserDefaults = .standard) {
        defaults.set([Double(origin.x), Double(origin.y)], forKey: defaultsKey(key))
    }

    /// Down and to the right of the pointer, flipped to the other side near a display edge, and
    /// always inside `visible`. AppKit coordinates (bottom-left origin).
    static func origin(nearPointer pointer: NSPoint, size: NSSize, in visible: NSRect, offset: CGFloat = 16) -> NSPoint {
        var x = pointer.x + offset
        var y = pointer.y - offset - size.height
        if x + size.width > visible.maxX {
            x = pointer.x - offset - size.width
        }
        if y < visible.minY {
            y = pointer.y + offset
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}
