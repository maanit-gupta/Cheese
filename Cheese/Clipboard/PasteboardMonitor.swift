import Foundation

/// Polls the pasteboard's `changeCount` and hands each new clip to `onCapture`.
@MainActor
final class PasteboardMonitor {
    static let pollInterval = Duration.milliseconds(500)

    private let pasteboard: any PasteboardReading
    private let onCapture: (CapturedClip) -> Void
    private var lastChangeCount: Int
    private var ownChangeCount: Int?
    private var pollTask: Task<Void, Never>?

    init(pasteboard: any PasteboardReading, onCapture: @escaping (CapturedClip) -> Void) {
        self.pasteboard = pasteboard
        self.onCapture = onCapture
        // Whatever is on the pasteboard at launch was already seen (or predates Cheese).
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                self.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Cheese wrote this change itself (pasting from history); don't record it as a new copy.
    func ignoreChange(_ changeCount: Int) {
        ownChangeCount = changeCount
    }

    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard changeCount != ownChangeCount else { return }
        if let clip = ClipReader.read(from: pasteboard) {
            onCapture(clip)
        }
    }
}
