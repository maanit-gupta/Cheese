import Foundation
import Testing
@testable import Cheese

struct TerminalLinkNormalizerTests {
    private typealias N = TerminalLinkNormalizer

    @Test func joinsALinkWrappedAtTheTerminalWidth() {
        let wrapped = "https://github.com/maanit-gupta/Cheese/pull/42/files?diff=split\n  &w=1#discussion_r123"
        #expect(N.link(in: wrapped, fromTerminal: true)
            == "https://github.com/maanit-gupta/Cheese/pull/42/files?diff=split&w=1#discussion_r123")
        #expect(N.link(in: "https://example.com/a/very/long/\r\npath/that/wraps", fromTerminal: false)
            == "https://example.com/a/very/long/path/that/wraps")
    }

    @Test func stripsEscapesEnclosuresAndAPrompt() {
        #expect(N.link(in: "\u{1B}[4;34mhttps://example.com/x\u{1B}[0m", fromTerminal: true) == "https://example.com/x")
        #expect(N.link(in: "\u{1B}]8;;https://a.b\u{07}https://example.com/osc\u{1B}]8;;\u{07}", fromTerminal: true)
            == "https://example.com/osc")
        #expect(N.link(in: "<https://example.com/angle>", fromTerminal: true) == "https://example.com/angle")
        #expect(N.link(in: "\"https://example.com/q\"", fromTerminal: true) == "https://example.com/q")
        #expect(N.link(in: "user@mac ~ % https://example.com/after-prompt", fromTerminal: true)
            == "https://example.com/after-prompt")
        #expect(N.link(in: "❯ https://example.com/z", fromTerminal: true) == "https://example.com/z")
    }

    @Test func leavesOrdinaryTextAlone() {
        // Prose around a link, several links, or a prompt from a non-terminal app are not "just a link".
        #expect(N.link(in: "Server running at https://localhost:3000", fromTerminal: true) == nil)
        #expect(N.link(in: "https://a.com/x\nhttps://b.com/y", fromTerminal: true) == nil)
        #expect(N.link(in: "https://a.com/x\nThis is a great article", fromTerminal: false) == nil)
        #expect(N.link(in: "user@mac ~ % https://example.com/p", fromTerminal: false) == nil)
        #expect(N.link(in: "no link here", fromTerminal: true) == nil)
        #expect(N.link(in: "ftp://example.com/file", fromTerminal: true) == nil)
    }

    @Test func rebuildsOnlyClipsThatChange() throws {
        let plain = "https://example.com/one\ntwo"
        let item = PasteboardItemContent(representations: [.init(type: PasteboardTypeID.plainText, data: Data(plain.utf8))])
        let rebuilt = N.linkClip(from: .text(plain: plain, items: [item], isRich: true), fromTerminal: false)
        guard case let .text(link, items, isRich) = try #require(rebuilt) else {
            Issue.record("expected a rebuilt link")
            return
        }
        #expect(link == "https://example.com/onetwo")
        #expect(!isRich)
        #expect(items.first?.data(forType: PasteboardTypeID.url) == Data(link.utf8))

        // Already a clean link, not from a terminal, or not text: untouched.
        #expect(N.linkClip(from: .text(plain: "https://example.com", items: [], isRich: false), fromTerminal: true) == nil)
        #expect(N.linkClip(from: .text(plain: "a https://example.com", items: [], isRich: false), fromTerminal: false) == nil)
        #expect(N.linkClip(from: .files([URL(filePath: "/tmp/x")]), fromTerminal: true) == nil)
    }
}

@MainActor
struct TerminalClipboardPipelineTests {
    private typealias T = PasteboardTypeID

    @Test func linkOnlyAndLegacyStringCopiesAreText() {
        #expect(ClipClassifier.classify([[T.url]]) == .text)
        #expect(ClipClassifier.classify([[T.legacyString]]) == .text)
        #expect(ClipClassifier.classify([[T.utf16Text]]) == .text)
        // Images still win over a page URL that came along with them, and markers still win over all.
        #expect(ClipClassifier.classify([[T.tiff, T.url]]) == .image)
        #expect(ClipClassifier.classify([[T.url, T.concealed]]) == nil)
    }

    @Test func readsFallbackTypesAndAddsUTF8() throws {
        let pasteboard = FakePasteboard()
        pasteboard.set([[(T.url, Data("https://example.com/u".utf8))]])
        guard case let .text(plain, items, _) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("expected text")
            return
        }
        #expect(plain == "https://example.com/u")
        #expect(items.first?.data(forType: T.plainText) == Data(plain.utf8))

        var utf16 = Data([0xFF, 0xFE])
        utf16.append("héllo".data(using: .utf16LittleEndian) ?? Data())
        pasteboard.set([[(T.utf16Text, utf16)]])
        guard case let .text(text, _, _) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("expected text")
            return
        }
        #expect(text == "héllo")
    }

    @Test func emptyChangeIsReReadOnceThenFallsBackToTheTerminalSelection() {
        let pasteboard = FakePasteboard()
        var captured: [CapturedClip] = []
        var selection: String? = "https://example.com/selected"
        let probe = ClipSourceProbe(isTerminal: { true }, terminalSelection: { selection })
        let monitor = PasteboardMonitor(pasteboard: pasteboard, source: probe) { captured.append($0) }

        // xterm.js bumped changeCount but its data isn't there yet.
        pasteboard.set([[]])
        monitor.poll()
        #expect(captured.isEmpty)
        monitor.settle(changeCount: pasteboard.changeCount, fromTerminal: true)
        #expect(captured.map(\.plainText) == ["https://example.com/selected"])

        // Data landed by the late look: that wins over the selection.
        pasteboard.set([[]])
        monitor.poll()
        let count = pasteboard.changeCount
        pasteboard.setStringKeepingChangeCount("https://example.com/\nlate")
        monitor.settle(changeCount: count, fromTerminal: true)
        #expect(captured.last?.plainText == "https://example.com/late")

        // A private copy is never replaced by the selection.
        pasteboard.set([[(T.concealed, Data())]])
        monitor.poll()
        monitor.settle(changeCount: pasteboard.changeCount, fromTerminal: true)
        #expect(captured.count == 2)

        // Nothing selected: nothing recorded.
        selection = nil
        pasteboard.set([[]])
        monitor.poll()
        monitor.settle(changeCount: pasteboard.changeCount, fromTerminal: true)
        #expect(captured.count == 2)
    }

    @Test func terminalCopiesRecordTheRebuiltLink() {
        let pasteboard = FakePasteboard()
        var captured: [CapturedClip] = []
        let probe = ClipSourceProbe(isTerminal: { true }, terminalSelection: { nil })
        let monitor = PasteboardMonitor(pasteboard: pasteboard, source: probe) { captured.append($0) }
        pasteboard.setString("user@mac ~ % https://example.com/a-long-\n    wrapped-path")
        monitor.poll()
        #expect(captured.map(\.plainText) == ["https://example.com/a-long-wrapped-path"])
    }
}

private extension CapturedClip {
    var plainText: String? {
        if case let .text(plain, _, _) = self { return plain }
        return nil
    }
}

private extension FakePasteboard {
    /// Writes data for the current change, as an async writer filling in a change it already announced.
    func setStringKeepingChangeCount(_ string: String) {
        setKeepingChangeCount([[(PasteboardTypeID.plainText, Data(string.utf8))]])
    }
}
