import Testing
@testable import Cheese

struct HotkeySuggesterTests {
    private func suggest(_ name: String, taken: String = "") -> [Character] {
        HotkeySuggester.suggestions(for: name, taken: Set(taken))
    }

    @Test func firstLetterComesFirst() {
        #expect(suggest("Figma").first == "F")
        #expect(suggest("Safari").first == "S")
    }

    @Test func otherWordsInitialsFollow() {
        #expect(Array(suggest("Visual Studio Code").prefix(3)) == ["V", "S", "C"])
    }

    @Test func vendorPrefixIsSkippedAsTheFirstWord() {
        let word = suggest("Microsoft Word")
        #expect(Array(word.prefix(2)) == ["W", "M"])
        #expect(suggest("Adobe Photoshop 2026").first == "P")
        // A one-word name that happens to be a vendor keeps its own letter.
        #expect(suggest("Microsoft").first == "M")
    }

    @Test func remainingConsonantsThenVowels() {
        // F, then its other consonants G, M, then its vowels I, A.
        let figma = suggest("Figma")
        #expect(Array(figma.prefix(5)) == ["F", "G", "M", "I", "A"])
    }

    @Test func dotsAndDigitsInNames() {
        let zoom = suggest("zoom.us")
        #expect(Array(zoom.prefix(5)) == ["Z", "M", "S", "O", "U"])

        let onePassword = suggest("1Password")
        #expect(onePassword.first == "P")
        // Letters before digits, and the name's own digit first among the digits.
        let firstDigit = onePassword.firstIndex { $0.isNumber }
        #expect(firstDigit == 26)
        #expect(onePassword[26] == "1")
    }

    @Test func repeatedLettersAppearOnce() {
        let iina = suggest("IINA")
        #expect(Array(iina.prefix(3)) == ["I", "N", "A"])
        #expect(Set(iina).count == iina.count)
        #expect(iina.count == 36)
    }

    @Test func takenKeysAreNeverSuggested() {
        let suggestions = suggest("Figma", taken: "FGM")
        #expect(suggestions.first == "I")
        #expect(!suggestions.contains("F"))
        #expect(suggestions.count == 33)
    }

    @Test func saturatedLettersFallBackToDigits() {
        #expect(suggest("Figma", taken: "ABCDEFGHIJKLMNOPQRSTUVWXYZ") == Array("0123456789"))
        #expect(suggest("Figma", taken: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").isEmpty)
    }

    @Test func commonLettersSinkWithinATier() {
        // M and T are commonly claimed; R and K aren't. Among Markdown's consonants after M,
        // R (rank 0) and K (rank 1) both beat D (rank 2 + 1) and W (rank 3 + 1).
        let suggestions = suggest("Markdown")
        #expect(Array(suggestions.prefix(5)) == ["M", "R", "K", "D", "W"])

        let scored = HotkeySuggester.scoredCandidates(for: "Markdown", taken: [])
        #expect(scored.first == .init(key: "M", score: 3))
        #expect(scored.map(\.score) == scored.map(\.score).sorted())
    }

    @Test func penaltiesNeverOutrankAMoreMnemonicTier() {
        // S is the most penalised letter, but as Safari's first letter it still wins.
        let scored = HotkeySuggester.scoredCandidates(for: "Safari", taken: [])
        #expect(scored.first?.key == "S")
    }

    @Test func suggestAnotherCycles() {
        let suggestions: [Character] = ["F", "G", "M"]
        #expect(HotkeySuggester.next(after: nil, in: suggestions) == "F")
        #expect(HotkeySuggester.next(after: "F", in: suggestions) == "G")
        #expect(HotkeySuggester.next(after: "M", in: suggestions) == "F")
        #expect(HotkeySuggester.next(after: "Q", in: suggestions) == "F")
        #expect(HotkeySuggester.next(after: "F", in: []) == nil)
    }

    @Test func accentsAndOddNamesStillWork() {
        #expect(suggest("Écran Partagé").first == "E")
        #expect(suggest("").count == 36)
        #expect(suggest("123").first == "A")
    }
}
