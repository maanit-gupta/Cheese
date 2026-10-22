import Foundation

/// One row of the command palette.
struct PaletteEntry: Equatable, Identifiable, Sendable {
    var id: ActionID
    var title: String
    var symbol: String
    /// Shown in grey after the title.
    var moduleName: String
    /// The action's current hotkey, shown on the right so people learn it.
    var shortcut: String?
}

/// Orders palette rows: fuzzy match plus a boost for recently used actions.
enum PaletteRanker {
    /// With an empty query, this many recent actions come first.
    static let recentCount = 8
    /// The most recent action's boost; each older one gets `recencyStep` less.
    static let maxRecencyBoost = 200
    static let recencyStep = 20

    /// - Parameter recent: action IDs, most recently used first.
    static func rank(_ entries: [PaletteEntry], query: String, recent: [ActionID]) -> [PaletteEntry] {
        guard query.contains(where: { !$0.isWhitespace }) else {
            return emptyQueryOrder(entries, recent: recent)
        }
        let recencyIndex = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return entries
            .compactMap { entry -> (entry: PaletteEntry, score: Int)? in
                guard let match = FuzzyMatcher.score(query: query, in: entry.title + " " + entry.moduleName) else { return nil }
                let boost = recencyIndex[entry.id].map { max(0, maxRecencyBoost - $0 * recencyStep) } ?? 0
                return (entry, match + boost)
            }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : alphabetical(lhs.entry, rhs.entry)
            }
            .map(\.entry)
    }

    /// The most recent actions (up to `recentCount`), then everything else alphabetically.
    private static func emptyQueryOrder(_ entries: [PaletteEntry], recent: [ActionID]) -> [PaletteEntry] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<ActionID> = []
        var result: [PaletteEntry] = []
        for id in recent where result.count < recentCount {
            if let entry = byID[id], seen.insert(id).inserted {
                result.append(entry)
            }
        }
        result += entries.filter { !seen.contains($0.id) }.sorted(by: alphabetical)
        return result
    }

    private static func alphabetical(_ lhs: PaletteEntry, _ rhs: PaletteEntry) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// Recently run palette actions, most recent first, kept in UserDefaults.
struct RecencyStore {
    static let defaultsKey = "paletteRecentActions"
    static let limit = 20

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var recent: [ActionID] {
        (defaults.stringArray(forKey: Self.defaultsKey) ?? []).map(ActionID.init(rawValue:))
    }

    func record(_ id: ActionID) {
        let updated = [id] + recent.filter { $0 != id }
        defaults.set(updated.prefix(Self.limit).map(\.rawValue), forKey: Self.defaultsKey)
    }
}
