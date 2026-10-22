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
    /// Every ordinary, resizable window of every regular app on the current Space: no panels,
    /// minimized windows or native full-screen windows.
    func standardWindows() -> [Window]
    /// The app that owns the window.
    func processID(of window: Window) -> pid_t
}

extension WindowControlling {
    /// Moves the window to `target`. One that keeps a different size (a fixed-size panel, a minimum
    /// size) is kept on the target's display instead.
    @discardableResult
    func place(_ window: Window, at target: SnapTarget, displays: [CGRect]) -> CGRect {
        var result = setFrame(target.frame, of: window) ?? target.frame
        if result.size != target.frame.size {
            let origin = SnapLayout.clampedOrigin(for: result.size, target: target.frame, visible: displays[target.displayIndex])
            if origin != result.origin {
                result = setOrigin(origin, of: window) ?? CGRect(origin: origin, size: result.size)
            }
        }
        return result
    }
}

enum WindowCommand: Equatable, Sendable {
    case snap(SnapAction)
    case restore
    /// Fill to Screen for the focused window; Restore puts it back.
    case fillCurrent
}

/// Applies snap commands to the focused window and remembers frames for Restore, and fills every
/// window to the screen (Stage Manager aware) and back.
@MainActor
final class WindowSnapper<Controller: WindowControlling> {
    private let controller: Controller
    private let filler: BatchWindowFiller<Controller>
    private let fillLayout: () -> FillLayout
    private var history = FrameHistory<Controller.Key>()

    /// - Parameter fillLayout: where Fill to Screen puts windows, read at each fill.
    init(controller: Controller, fillLayout: @escaping () -> FillLayout = { .fullVisibleFrame }) {
        self.controller = controller
        filler = BatchWindowFiller(controller: controller)
        self.fillLayout = fillLayout
    }

    /// Fills every standard window of every regular app to its display.
    @discardableResult
    func fillAll() -> BatchWindowFiller<Controller>.Result {
        filler.fillAll(layout: fillLayout(), history: &history)
    }

    /// Puts back every window the last Fill All moved. Returns how many it restored.
    @discardableResult
    func restoreAll() -> Int {
        filler.restoreAll(history: &history)
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
            move(window, key: key, from: frame, to: target, displays: displays)

        case .fillCurrent:
            let displays = controller.visibleFrames()
            guard let target = StageManagerLayout.target(for: frame, displays: displays, layout: fillLayout()) else { return }
            move(window, key: key, from: frame, to: target, displays: displays)
        }
    }

    private func move(_ window: Controller.Window, key: Controller.Key, from frame: CGRect, to target: SnapTarget, displays: [CGRect]) {
        history.rememberOriginal(frame, for: key)
        let result = controller.place(window, at: target, displays: displays)
        history.recordSnap(SnapRecord(aimed: target.frame, result: result), for: key)
    }
}
