import Testing
@testable import Cheese

struct FuzzyMatcherTests {
    @Test func emptyQueryMatchesEverythingInOrder() {
        let items = ["b", "a", "c"]
        #expect(FuzzyMatcher.score(query: "", in: "anything") == 0)
        #expect(FuzzyMatcher.rank(items, query: "   ", text: { $0 }) == items)
    }

    @Test func ignoresCaseAndDiacritics() {
        #expect(FuzzyMatcher.score(query: "CAFE", in: "Le café du coin") != nil)
        #expect(FuzzyMatcher.score(query: "résumé", in: "my RESUME.pdf") != nil)
    }

    @Test func matchesCharactersInOrderOnly() {
        #expect(FuzzyMatcher.score(query: "gthb", in: "github.com") != nil)
        #expect(FuzzyMatcher.score(query: "bhtg", in: "github.com") == nil)
        #expect(FuzzyMatcher.score(query: "xyz", in: "github.com") == nil)
    }

    @Test func everyWordMustMatch() {
        #expect(FuzzyMatcher.score(query: "swift actor", in: "An actor in Swift") != nil)
        #expect(FuzzyMatcher.score(query: "swift kotlin", in: "An actor in Swift") == nil)
    }

    @Test func substringBeatsScatteredMatch() throws {
        let substring = try #require(FuzzyMatcher.score(query: "port", in: "import Foundation"))
        let scattered = try #require(FuzzyMatcher.score(query: "port", in: "p-o-r-t"))
        #expect(substring > scattered)
    }

    @Test func prefixAndWordStartBeatMidWord() throws {
        let prefix = try #require(FuzzyMatcher.score(query: "log", in: "logger output"))
        let wordStart = try #require(FuzzyMatcher.score(query: "log", in: "the logger"))
        let midWord = try #require(FuzzyMatcher.score(query: "log", in: "biologist"))
        #expect(prefix > wordStart)
        #expect(wordStart > midWord)
    }

    @Test func fuzzyScoreIsCapped() throws {
        let long = String(repeating: "a-", count: 200)
        let query = String(repeating: "a", count: 150)
        let score = try #require(FuzzyMatcher.score(query: query, in: long))
        #expect(score <= FuzzyMatcher.maxFuzzyScore)
    }

    @Test func substringSearchSeesWholeLongText() {
        let text = String(repeating: "x", count: FuzzyMatcher.fuzzyWindow * 3) + "needle"
        #expect(FuzzyMatcher.score(query: "needle", in: text) != nil)
    }

    @Test func rankSortsByScoreThenOriginalOrder() {
        let items = ["unrelated", "biologist", "logger", "the logger", "logger too"]
        let ranked = FuzzyMatcher.rank(items, query: "log", text: { $0 })
        #expect(ranked == ["logger", "logger too", "the logger", "biologist"])
    }
}
