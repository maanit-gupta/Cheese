import Foundation
import Testing
@testable import Cheese

struct LinkCleanerTests {
    private typealias C = LinkCleaner

    @Test func stripsGlobalTrackersAndKeepsTheRest() {
        #expect(C.clean("https://example.com/post?id=7&utm_source=news&utm_Medium=email&fbclid=abc#top")
            == "https://example.com/post?id=7#top")
        #expect(C.clean("https://shop.example.com/?GCLID=x&msclkid=y&_hsenc=z&hsCtaTracking=1&page=2")
            == "https://shop.example.com/?page=2")
        #expect(C.clean("https://example.com/a?utm_custom_thing=1") == "https://example.com/a")
    }

    @Test func dropsTheQuestionMarkWhenNothingIsLeft() {
        #expect(C.clean("https://example.com/path?utm_source=x&igshid=y") == "https://example.com/path")
        #expect(C.clean("https://example.com/?utm_source=x&&") == "https://example.com/")
    }

    @Test func leavesCleanAndNonWebLinksUntouched() {
        let encoded = "https://example.com/search?q=caf%C3%A9+au+lait&sort=new"
        #expect(C.clean(encoded) == encoded)
        #expect(!C.containsTrackers(encoded))
        #expect(C.clean("mailto:me@example.com?utm_source=x") == "mailto:me@example.com?utm_source=x")
        #expect(C.clean("not a url") == "not a url")
        // Host-specific names are only trackers on their own hosts.
        #expect(C.clean("https://example.com/watch?si=1&t=30&tag=red") == "https://example.com/watch?si=1&t=30&tag=red")
    }

    @Test func youTube() {
        #expect(C.clean("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42&list=PL1&index=3&si=abc&feature=share&pp=ygU&ab_channel=Rick")
            == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42&list=PL1&index=3")
        #expect(C.clean("https://youtu.be/dQw4w9WgXcQ?si=Xyz123&t=10") == "https://youtu.be/dQw4w9WgXcQ?t=10")
        #expect(C.clean("https://m.youtube.com/watch?v=a&kw=b") == "https://m.youtube.com/watch?v=a")
    }

    @Test func amazon() {
        #expect(C.clean("https://www.amazon.com/Some-Thing/dp/B08N5WRWNW/ref=sr_1_3?crid=2X&keywords=mouse&qid=1700&sprefix=mo&sr=8-3&th=1")
            == "https://www.amazon.com/Some-Thing/dp/B08N5WRWNW?th=1")
        #expect(C.clean("https://www.amazon.co.uk/dp/B0ABC/?tag=aff-21&linkCode=ll1&psc=1")
            == "https://www.amazon.co.uk/dp/B0ABC/")
        #expect(C.clean("https://amazon.in/gp/product/B0X/ref=ppx_yo_dt_b_asin_title")
            == "https://amazon.in/gp/product/B0X")
    }

    @Test func socialAndGoogle() {
        #expect(C.clean("https://x.com/user/status/123?s=20&t=AbC") == "https://x.com/user/status/123")
        #expect(C.clean("https://twitter.com/user/status/1?cxt=H4s&lang=en") == "https://twitter.com/user/status/1?lang=en")
        #expect(C.clean("https://open.spotify.com/track/4uLU6?si=abc&context=spotify%3Aplaylist&pt=x")
            == "https://open.spotify.com/track/4uLU6")
        #expect(C.clean("https://www.linkedin.com/posts/someone_123?trk=public&trkInfo=x&lipi=y&rcm=z")
            == "https://www.linkedin.com/posts/someone_123")
        #expect(C.clean("https://www.google.co.in/search?q=swift+urlcomponents&tbm=isch&start=10&ei=abc&ved=0ah&oq=swift&gs_lcp=x&sclient=gws&sourceid=chrome&biw=1440&bih=800")
            == "https://www.google.co.in/search?q=swift+urlcomponents&tbm=isch&start=10")
    }

    @Test func extractsAndCleansACopiedLink() throws {
        let result = try #require(C.extractAndCleanURL(from: "  <https://example.com/a?utm_source=x&b=1>\n"))
        #expect(result.original.absoluteString == "https://example.com/a?utm_source=x&b=1")
        #expect(result.cleaned.absoluteString == "https://example.com/a?b=1")
        #expect(result.didClean)

        let clean = try #require(C.extractAndCleanURL(from: "https://example.com/plain"))
        #expect(!clean.didClean)
        #expect(clean.cleaned == clean.original)

        #expect(C.extractAndCleanURL(from: "Read https://example.com/a?utm_source=x today") == nil)
        #expect(C.extractAndCleanURL(from: "just words") == nil)
    }
}
