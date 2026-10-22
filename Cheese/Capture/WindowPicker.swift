import AppKit
import CoreGraphics

/// An on-screen window the picker can highlight.
struct PickableWindow: Equatable, Sendable {
    var windowID: CGWindowID
    /// AppKit global points.
    var frame: CGRect
}

/// Hover to highlight a window, click to pick it.
@MainActor
enum WindowPicker {
    struct Pick {
        var window: PickableWindow
        var shiftHeld: Bool
        var session: OverlaySession
    }

    static func pickWindow() async -> Pick? {
        let windows = onScreenWindows()
        let session = OverlaySession()
        let state = WindowPickerState(windows: windows)

        let result: (PickableWindow, Bool)? = await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ result: (PickableWindow, Bool)?) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            session.show { screen in
                WindowPickerView(
                    screenFrame: screen.frame,
                    state: state,
                    onPick: { window, shift in finish((window, shift)) },
                    onCancel: { finish(nil) }
                )
            }
            state.updateHover(at: NSEvent.mouseLocation)
            if session.windows.isEmpty { finish(nil) }
        }
        state.views = []
        guard let (window, shiftHeld) = result else {
            session.end(restoreFocus: true)
            return nil
        }
        // Hide the overlay right away so it can't end up in the window capture.
        for overlay in session.windows {
            overlay.orderOut(nil)
        }
        return Pick(window: window, shiftHeld: shiftHeld, session: session)
    }

    /// Ordinary app windows, front to back, excluding Cheese's own.
    static func onScreenWindows() -> [PickableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != ownProcess,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 20, bounds.height >= 20
            else { return nil }
            return PickableWindow(windowID: CGWindowID(number), frame: Screens.appKitRect(fromQuartz: bounds))
        }
    }

    /// The front-most window under `point` (AppKit global).
    nonisolated static func window(at point: CGPoint, in windows: [PickableWindow]) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }
}

/// Hover state shared by the picker's overlay on every display.
@MainActor
final class WindowPickerState {
    let windows: [PickableWindow]
    private(set) var hovered: PickableWindow?
    var views: [NSView] = []

    init(windows: [PickableWindow]) {
        self.windows = windows
    }

    func updateHover(at point: CGPoint) {
        let window = WindowPicker.window(at: point, in: windows)
        guard window != hovered else { return }
        hovered = window
        for view in views {
            view.needsDisplay = true
        }
    }
}

final class WindowPickerView: NSView {
    private let screenFrame: CGRect
    private let state: WindowPickerState
    private let onPick: (PickableWindow, Bool) -> Void
    private let onCancel: () -> Void

    init(
        screenFrame: CGRect,
        state: WindowPickerState,
        onPick: @escaping (PickableWindow, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screenFrame = screenFrame
        self.state = state
        self.onPick = onPick
        self.onCancel = onCancel
        super.init(frame: .zero)
        state.views.append(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        // A nearly invisible fill keeps the window hit-testable everywhere.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        guard let hovered = state.hovered else { return }
        let local = hovered.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard local.intersects(bounds) else { return }
        NSColor.controlAccentColor.withAlphaComponent(DesignTokens.Opacity.activeTint).setFill()
        local.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        state.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        state.updateHover(at: NSEvent.mouseLocation)
        guard let hovered = state.hovered else { return }
        onPick(hovered, event.modifierFlags.contains(.shift))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}
