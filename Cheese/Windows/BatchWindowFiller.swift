import CoreGraphics
import os

/// Fill All to Screen and Restore All Windows: every standard window of every regular app, resized
/// to fill its display (leaving Stage Manager's strip clear), never put into native full screen.
/// The frames from before the fill go into `FrameHistory`, so the whole fill can be undone.
@MainActor
struct BatchWindowFiller<Controller: WindowControlling> {
    struct Result: Equatable {
        var windows: Int
        var apps: Int
    }

    let controller: Controller

    func fillAll(layout: FillLayout, history: inout FrameHistory<Controller.Key>) -> Result {
        let displays = controller.visibleFrames()
        var originals: [(key: Controller.Key, frame: CGRect)] = []
        var apps = Set<pid_t>()

        for window in controller.standardWindows() {
            guard let frame = controller.frame(of: window),
                  let target = StageManagerLayout.target(for: frame, displays: displays, layout: layout)
            else { continue }
            originals.append((controller.key(for: window), frame))
            if !SnapLayout.approximatelyEqual(frame, target.frame, tolerance: 1) {
                controller.place(window, at: target, displays: displays)
            }
            apps.insert(controller.processID(of: window))
        }
        history.rememberBatchOriginals(originals)
        Logger.windows.info("Filled \(originals.count) windows across \(apps.count) apps")
        return Result(windows: originals.count, apps: apps.count)
    }

    /// Windows closed since the fill are skipped; the rest go back to where they were.
    func restoreAll(history: inout FrameHistory<Controller.Key>) -> Int {
        let originals = Dictionary(history.takeBatch().map { ($0.key, $0.frame) }, uniquingKeysWith: { first, _ in first })
        guard !originals.isEmpty else { return 0 }
        var restored = 0
        for window in controller.standardWindows() {
            guard let original = originals[controller.key(for: window)] else { continue }
            _ = controller.setFrame(original, of: window)
            restored += 1
        }
        return restored
    }
}
