import AppKit
import ApplicationServices
import os

/// Watches the pointer for another app's window being dragged to a screen edge or corner.
/// Reports the zone under the pointer while a window drag is on, and the zone it was released in.
/// Plain clicks cost nothing beyond the event; AX is read only while the button is held and
/// the pointer moves, at most ~60 times a second, and stops once the drag is recognised.
@MainActor
final class WindowDragMonitor {
    /// The zone under the pointer changed during a window drag (nil: left every zone, or the drag ended).
    var onZoneChange: ((SnapZoneHit?) -> Void)?
    /// The button came up over a zone with a window drag on.
    var onDrop: ((SnapZoneHit, AXWindow) -> Void)?

    private let windows: WindowManager
    private var monitor: Any?
    private var tracker = WindowDragTracker()
    private var window: AXWindow?
    private var displays: [CGRect] = []
    private var visibleFrames: [CGRect] = []
    private(set) var currentHit: SnapZoneHit?

    init(windows: WindowManager) {
        self.windows = windows
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        // Global monitors only see events bound for other apps, so Cheese's own windows never snap.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, at: time) }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        reset()
    }

    private func handle(_ type: NSEvent.EventType, at time: TimeInterval) {
        switch type {
        case .leftMouseDown:
            reset()
            tracker.mouseDown()
        case .leftMouseDragged:
            guard tracker.shouldSample(at: time) else { return }
            sample()
        case .leftMouseUp:
            let hit = tracker.isDraggingWindow ? zoneUnderPointer() : nil
            let dropped = window
            let wasDragging = tracker.mouseUp()
            setHit(nil)
            if wasDragging, let hit, let dropped {
                onDrop?(hit, dropped)
            }
            reset()
        default:
            break
        }
    }

    private func sample() {
        switch tracker.phase {
        case .pressed:
            guard AXIsProcessTrusted(), let found = windows.window(at: Screens.mouseLocationQuartz) else {
                tracker.found(windowOrigin: nil)
                return
            }
            window = found
            tracker.found(windowOrigin: windows.origin(of: found))
        case .watching:
            guard let window else { return }
            if tracker.moved(windowOrigin: windows.origin(of: window)) {
                // Measured once per drag: the live Dock costs an AX call, too much for every sample.
                displays = windows.displayFrames()
                visibleFrames = windows.visibleFrames()
                Logger.windows.debug("Window drag recognised for pid \(window.pid)")
                setHit(zoneUnderPointer())
            }
        case .dragging:
            setHit(zoneUnderPointer())
        case .idle, .ignored:
            break
        }
    }

    private func zoneUnderPointer() -> SnapZoneHit? {
        SnapZoneLayout.hit(at: Screens.mouseLocationQuartz, displays: displays, visibleFrames: visibleFrames)
    }

    private func setHit(_ hit: SnapZoneHit?) {
        guard hit != currentHit else { return }
        currentHit = hit
        onZoneChange?(hit)
    }

    private func reset() {
        if currentHit != nil { setHit(nil) }
        _ = tracker.mouseUp()
        window = nil
        displays = []
        visibleFrames = []
    }
}
