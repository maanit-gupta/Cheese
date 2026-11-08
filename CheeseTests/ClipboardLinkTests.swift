import Foundation
import Testing
@testable import Cheese

struct ClipboardLinkTests {
    private func textClip(_ text: String) -> CapturedClip {
        .text(plain: text, items: [], isRich: false)
    }

    @Test func aTrackedLinkIsFoundWithItsCleanForm() throws {
        let link = try #require(ClipboardLink(text: "https://example.com/post?id=7&utm_source=x&fbclid=abc"))
        #expect(link.original.absoluteString == "https://example.com/post?id=7&utm_source=x&fbclid=abc")
        #expect(link.cleaned.absoluteString == "https://example.com/post?id=7")
        #expect(link.hasTrackers)
    }

    @Test func aCleanLinkStillCountsButHasNothingToStrip() throws {
        let link = try #require(ClipboardLink(text: "https://www.youtube.com/watch?v=abc&t=42"))
        #expect(!link.hasTrackers)
        #expect(link.original == link.cleaned)
    }

    @Test func textImagesAndFilesThatArentLinksDontCount() {
        #expect(ClipboardLink(text: "just some notes") == nil)
        #expect(ClipboardLink(text: "see https://example.com for more") == nil)
        #expect(ClipboardLink(clip: .image(data: Data([1, 2, 3]))) == nil)
        #expect(ClipboardLink(clip: .files([URL(fileURLWithPath: "/tmp/a.txt")])) == nil)
    }

    @Test func theCleanedClipIsPlainTextOfTheCleanLink() throws {
        let link = try #require(ClipboardLink(clip: textClip("https://youtu.be/abc?si=tracker")))
        guard case let .text(plain, items, isRich) = link.cleanedClip else {
            Issue.record("Expected a text clip")
            return
        }
        #expect(plain == "https://youtu.be/abc")
        #expect(!isRich)
        #expect(items.first?.data(forType: PasteboardTypeID.plainText) == Data("https://youtu.be/abc".utf8))
    }

    @Test func afterCleaningTheLinkHasNoTrackersLeft() throws {
        let link = try #require(ClipboardLink(text: "https://x.com/user/status/1?s=20&t=abc"))
        #expect(link.hasTrackers)
        #expect(!link.afterCleaning.hasTrackers)
        #expect(link.afterCleaning.original == link.cleaned)
    }

    @Test func cleaningIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "ClipboardLinkTests-\(UUID().uuidString)") ?? .standard
        #expect(Preferences(defaults: defaults).copyCleanLinkAutomatically == false)
        defaults.set(true, forKey: PreferenceKey.copyCleanLinkAutomatically)
        #expect(Preferences(defaults: defaults).copyCleanLinkAutomatically)
    }

    /// Features 2 + 3 together: a tracking link soft-wrapped by a terminal is rebuilt by the
    /// normalizer, recognized as a link, and cleaned of every tracker.
    @Test func aWrappedTerminalTrackingLinkIsRebuiltAndCleaned() throws {
        let wrapped = "https://example.com/article?id=42&utm_source=news\n  letter&utm_medium=email&fbclid=IwAR0abc"
        let rebuilt = try #require(TerminalLinkNormalizer.linkClip(from: textClip(wrapped), fromTerminal: true))
        let link = try #require(ClipboardLink(clip: rebuilt))
        #expect(link.original.absoluteString == "https://example.com/article?id=42&utm_source=newsletter&utm_medium=email&fbclid=IwAR0abc")
        #expect(link.hasTrackers)
        #expect(link.cleaned.absoluteString == "https://example.com/article?id=42")
        #expect(!link.afterCleaning.hasTrackers)
    }

    @Test func dragToEdgeSnappingIsOnByDefaultAndPersists() {
        let defaults = UserDefaults(suiteName: "ClipboardLinkTests-drag-\(UUID().uuidString)") ?? .standard
        #expect(Preferences(defaults: defaults).dragToEdgeSnappingEnabled)
        defaults.set(false, forKey: PreferenceKey.dragToEdgeSnappingEnabled)
        #expect(!Preferences(defaults: defaults).dragToEdgeSnappingEnabled)
    }
}
