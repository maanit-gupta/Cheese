import CoreGraphics
import os

/// Reads and moves the focused window. Frames are in Quartz global coordinates.
@MainActor
protocol WindowControlling {
    associatedtype Window
    associatedtype Key: Hashable

    /// The focused window of the frontmost app, if it's an ordinary window that can be moved.
    func focusedWindow() -> Window?
    func key(for window: Window) -> Key
    func frame(of window: Window) -> CGRect?
    /// Moves and resizes the window, returning the frame it actually ended up with.
    func setFrame(_ frame: CGRect, of window: Window) -> CGRect?
    /// Moves the window without resizing it.
    func setOrigin(_ origin: CGPoint, of window: Window) -> CGRect?
    /// Every display's visible frame in Quartz coordinates.
    func visibleFrames() -> [CGRect]
}

enum WindowCommand: Equatable, Sendable {
    case snap(SnapAction)
    case restore
}

/// Applies snap commands to the focused window and remembers frames for Restore.
@MainActor
final class WindowSnapper<Controller: WindowControlling> {
    private let controller: Controller
    private var history = FrameHistory<Controller.Key>()

    init(controller: Controller) {
        self.controller = controller
    }

    func perform(_ command: WindowCommand) {
        guard let window = controller.focusedWindow(), let frame = controller.frame(of: window) else {
            Logger.windows.info("No movable focused window")
            return
        }
        let key = controller.key(for: window)

        switch command {
        case .restore:
            guard let original = history.original(for: key) else { return }
            _ = controller.setFrame(original, of: window)
            history.forget(key)

        case let .snap(action):
            let displays = controller.visibleFrames()
            guard let target = SnapLayout.target(
                for: action,
                windowFrame: frame,
                displays: displays,
                previousSnap: history.lastSnap(for: key)
            ) else { return }

            history.rememberOriginal(frame, for: key)
            var result = controller.setFrame(target.frame, of: window) ?? target.frame
            if result.size != target.frame.size {
                // The window kept a different size (fixed-size panel, minimum size): keep it on the display.
                let origin = SnapLayout.clampedOrigin(for: result.size, target: target.frame, visible: displays[target.displayIndex])
                if origin != result.origin {
                    result = controller.setOrigin(origin, of: window) ?? CGRect(origin: origin, size: result.size)
                }
            }
            history.recordSnap(SnapRecord(aimed: target.frame, result: result), for: key)
        }
    }
}
