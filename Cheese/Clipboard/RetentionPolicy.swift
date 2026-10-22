import Foundation

/// The parts of a history item that decide whether it's kept.
struct RetentionCandidate: Equatable, Sendable {
    var id: UUID
    var isPinned: Bool
    var lastCopiedAt: Date
}

enum RetentionPolicy {
    /// Unpinned items beyond the newest `limit`. Pinned items never count and are never removed.
    static func itemsToRemove(from candidates: [RetentionCandidate], limit: Int) -> [UUID] {
        let unpinned = candidates
            .filter { !$0.isPinned }
            .sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        return unpinned.dropFirst(max(limit, 0)).map(\.id)
    }
}
