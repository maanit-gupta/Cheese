import CoreGraphics

/// Per-window memory for snapping: the frame before the first snap (for Restore) and the last snap.
/// Bounded, so windows that were closed long ago eventually drop out. Also the frames every window
/// had before Fill All to Screen, for Restore All Windows.
struct FrameHistory<Key: Hashable> {
    private struct Entry {
        var original: CGRect?
        var lastSnap: SnapRecord?
    }

    let capacity: Int
    private var entries: [Key: Entry] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    /// Frames from before the current batch fill, in the order the windows were filled.
    private var batch: [Key: CGRect] = [:]
    private var batchOrder: [Key] = []

    init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    func original(for key: Key) -> CGRect? {
        entries[key]?.original
    }

    func lastSnap(for key: Key) -> SnapRecord? {
        entries[key]?.lastSnap
    }

    /// Records `frame` as the window's original unless one is already remembered.
    mutating func rememberOriginal(_ frame: CGRect, for key: Key) {
        update(key) { entry in
            if entry.original == nil { entry.original = frame }
        }
    }

    mutating func recordSnap(_ record: SnapRecord, for key: Key) {
        update(key) { $0.lastSnap = record }
    }

    /// Forgets the window after Restore, so the next snap remembers a fresh original.
    mutating func forget(_ key: Key) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    // MARK: Batch fills

    var hasBatch: Bool { !batch.isEmpty }

    func batchOriginal(for key: Key) -> CGRect? {
        batch[key]
    }

    /// Records the frames windows had before a batch fill. A window already in the batch keeps the
    /// frame from before its first fill, so filling twice and restoring still gets back to it.
    mutating func rememberBatchOriginals(_ frames: [(key: Key, frame: CGRect)]) {
        for (key, frame) in frames where batch[key] == nil {
            batch[key] = frame
            batchOrder.append(key)
        }
    }

    /// Hands the batch to Restore All Windows and forgets it.
    mutating func takeBatch() -> [(key: Key, frame: CGRect)] {
        let taken = batchOrder.compactMap { key in batch[key].map { (key: key, frame: $0) } }
        batch = [:]
        batchOrder = []
        return taken
    }

    private mutating func update(_ key: Key, _ change: (inout Entry) -> Void) {
        var entry = entries[key] ?? Entry()
        change(&entry)
        entries[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }
}
