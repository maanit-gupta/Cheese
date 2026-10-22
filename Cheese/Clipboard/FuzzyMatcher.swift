import Foundation

/// Type-to-filter scoring for the history search field. Matching ignores case and diacritics,
/// and every whitespace-separated word of the query has to match somewhere in the candidate.
enum FuzzyMatcher {
    /// Non-contiguous matching only looks this far into a long text; substring matching sees all of it.
    static let fuzzyWindow = 2_000
    /// Highest score a non-contiguous match can earn, so a real substring always ranks above it.
    static let maxFuzzyScore = 900
    private static let maxFuzzyStarts = 16
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Higher is better. Nil when some query word doesn't match; 0 for an empty query.
    static func score(query: String, in candidate: String) -> Int? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }

        var folded: [Character]?
        var total = 0
        for word in words {
            if let score = substringScore(word, in: candidate) {
                total += score
                continue
            }
            let text = folded ?? fold(String(candidate.prefix(fuzzyWindow)))
            folded = text
            guard let score = subsequenceScore(fold(word), in: text) else { return nil }
            total += score
        }
        return total
    }

    /// The items that match, best first. Ties keep their original order. An empty query keeps everything.
    static func rank<Item>(_ items: [Item], query: String, text: (Item) -> String) -> [Item] {
        guard query.contains(where: { !$0.isWhitespace }) else { return items }
        return items.enumerated()
            .compactMap { index, item in
                score(query: query, in: text(item)).map { (index: index, item: item, score: $0) }
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }

    private static func substringScore(_ word: String, in text: String) -> Int? {
        guard let range = text.range(of: word, options: options) else { return nil }
        var score = 1_000 + word.count * 10
        if range.lowerBound == text.startIndex {
            score += 200
        } else if isBoundary(text[text.index(before: range.lowerBound)]) {
            score += 100
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        return score - min(offset, 100) / 10
    }

    /// Best greedy in-order match of `word`'s characters, trying the first few places it could start.
    private static func subsequenceScore(_ word: [Character], in text: [Character]) -> Int? {
        guard let first = word.first else { return 0 }
        var best: Int?
        var starts = 0
        for start in text.indices where text[start] == first {
            // A later start has fewer characters left, so once one fails every later one does too.
            guard let score = greedyScore(word, in: text, from: start) else { break }
            best = max(best ?? score, score)
            starts += 1
            if starts == maxFuzzyStarts { break }
        }
        return best.map { min($0, maxFuzzyScore) }
    }

    private static func greedyScore(_ word: [Character], in text: [Character], from start: Int) -> Int? {
        var score = 0
        var position = start
        var previous: Int?
        for character in word {
            while position < text.count, text[position] != character {
                position += 1
            }
            guard position < text.count else { return nil }

            score += 10
            if let previous {
                let gap = position - previous - 1
                score += gap == 0 ? 15 : -min(gap, 10)
            }
            if position == 0 || isBoundary(text[position - 1]) {
                score += 20
            }
            previous = position
            position += 1
        }
        return max(score, 1)
    }

    private static func fold(_ text: String) -> [Character] {
        Array(text.folding(options: options, locale: nil))
    }

    private static func isBoundary(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber
    }
}
