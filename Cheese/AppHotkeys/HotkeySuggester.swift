import Foundation

/// Proposes a `Ctrl+Opt+Cmd+<key>` shortcut for an app, offline: mnemonic letters first, minus keys
/// that are already taken, nudging letters other apps commonly claim further down.
enum HotkeySuggester {
    struct Candidate: Equatable, Sendable {
        var key: Character
        var score: Int
    }

    /// Every key considered: A–Z first, then 0–9.
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digits = Array("0123456789")

    /// Vendor names skipped as an app's first word, so Microsoft Word suggests `W` first.
    static let vendorPrefixes: Set<String> = [
        "adobe", "affinity", "apple", "autodesk", "corel", "google", "jetbrains", "microsoft", "mozilla", "the",
    ]

    /// How often other apps and launchers claim a letter with this modifier family, 0–3.
    /// Mostly the initials of very common apps (Safari, Slack, Chrome, Mail, Terminal…).
    static let commonness: [Character: Int] = [
        "C": 3, "M": 3, "S": 3, "T": 3,
        "B": 2, "F": 2, "N": 2, "P": 2,
        "A": 1, "D": 1, "E": 1, "O": 1, "V": 1, "W": 1, "X": 1, "Z": 1,
    ]

    /// Points per mnemonic tier. A penalty (at most 3) reorders keys within a tier, never across tiers.
    private static let tierWeight = 100

    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]

    /// Free keys for `appName`, best first. `taken` holds keys already bound with Ctrl+Opt+Cmd.
    static func suggestions(for appName: String, taken: Set<Character>) -> [Character] {
        scoredCandidates(for: appName, taken: taken).map(\.key)
    }

    /// Each free key with its score, `mnemonicRank + conflictPenalty`, lowest (best) first.
    static func scoredCandidates(for appName: String, taken: Set<Character>) -> [Candidate] {
        var seen = taken
        var candidates: [Candidate] = []
        for (tier, keys) in tiers(for: appName).enumerated() {
            var position = 0
            for key in keys where seen.insert(key).inserted {
                let penalty = commonness[key] ?? 0
                candidates.append(Candidate(key: key, score: tier * tierWeight + position + penalty))
                position += 1
            }
        }
        // Stable: equal scores keep tier order.
        return candidates.enumerated()
            .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
            .map(\.element)
    }

    /// The key after `current` in the suggestion order, wrapping around: "Suggest another".
    static func next(after current: Character?, in suggestions: [Character]) -> Character? {
        guard let current, let index = suggestions.firstIndex(of: current) else { return suggestions.first }
        return suggestions[(index + 1) % suggestions.count]
    }

    /// Mnemonic tiers, best first. Keys can repeat across tiers; the first appearance counts.
    private static func tiers(for appName: String) -> [[Character]] {
        let words = self.words(in: appName)
        // The vendor goes to the back of the "other words" rather than vanishing.
        var ordered = words
        if words.count > 1, let first = words.first, vendorPrefixes.contains(first.lowercased()) {
            ordered = Array(words.dropFirst()) + [first]
        }
        let wordLetters = ordered.map(letters(in:))
        let nameLetters = wordLetters.joined()

        let firstLetter = wordLetters.first { !$0.isEmpty }?.first.map { [$0] } ?? []
        let otherInitials = wordLetters.dropFirst().compactMap(\.first)
        let consonants = nameLetters.filter { !vowels.contains($0) }
        let nameVowels = nameLetters.filter { vowels.contains($0) }
        let nameDigits = Array(appName.filter { $0.isASCII && $0.isNumber })

        return [firstLetter, otherInitials, consonants, nameVowels, letters, nameDigits + digits]
    }

    /// Words split on spaces, hyphens and underscores.
    private static func words(in name: String) -> [String] {
        name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }.map(String.init)
    }

    /// A word's letters as uppercase A–Z, accents removed, everything else dropped.
    private static func letters(in word: String) -> [Character] {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
            .filter { $0.isASCII && $0.isLetter }
            .map { $0 }
    }
}
