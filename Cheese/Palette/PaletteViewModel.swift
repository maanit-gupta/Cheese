import Foundation

/// The palette's query, ranked rows and selection.
@MainActor
@Observable
final class PaletteViewModel {
    var query = "" {
        didSet { refresh() }
    }
    private(set) var results: [PaletteEntry] = []
    var selection = 0

    /// Runs the chosen action. Set by the panel, which closes first.
    @ObservationIgnored var onRun: (ActionID) -> Void = { _ in }
    @ObservationIgnored private var entries: [PaletteEntry] = []
    @ObservationIgnored private let recency: RecencyStore

    init(recency: RecencyStore = RecencyStore()) {
        self.recency = recency
    }

    /// Starts fresh: empty query, the given actions, first row selected.
    func reset(entries: [PaletteEntry]) {
        self.entries = entries
        query = ""
        refresh()
    }

    var selectedEntry: PaletteEntry? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + offset, 0), results.count - 1)
    }

    func runSelected() {
        guard let entry = selectedEntry else { return }
        run(entry.id)
    }

    func run(_ id: ActionID) {
        recency.record(id)
        onRun(id)
    }

    private func refresh() {
        results = PaletteRanker.rank(entries, query: query, recent: recency.recent)
        selection = 0
    }
}
