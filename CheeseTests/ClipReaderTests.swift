import Foundation
import Testing
@testable import Cheese

@MainActor
struct ClipReaderTests {
    private typealias T = PasteboardTypeID
    private let pasteboard = FakePasteboard()

    @Test func readsPlainText() throws {
        pasteboard.setString("hello")
        guard case let .text(plain, items, isRich) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("Expected text")
            return
        }
        #expect(plain == "hello")
        #expect(!isRich)
        #expect(items == [PasteboardItemContent(representations: [.init(type: T.plainText, data: Data("hello".utf8))])])
    }

    @Test func keepsEveryRepresentationOfRichText() throws {
        let rtf = Data(#"{\rtf1\ansi {\b bold}}"#.utf8)
        pasteboard.set([[(T.plainText, Data("bold".utf8)), (T.rtf, rtf), ("com.example.custom", Data([1, 2, 3]))]])
        guard case let .text(plain, items, isRich) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("Expected text")
            return
        }
        #expect(plain == "bold")
        #expect(isRich)
        #expect(items.first?.representations.map(\.type) == [T.plainText, T.rtf, "com.example.custom"])
    }

    @Test func derivesTextFromRTFWhenNoPlainText() throws {
        pasteboard.set([[(T.rtf, Data(#"{\rtf1\ansi Hello {\b world}}"#.utf8))]])
        guard case let .text(plain, _, isRich) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("Expected text")
            return
        }
        #expect(plain.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello world")
        #expect(isRich)
    }

    @Test func whitespaceOnlyTextIsIgnored() {
        pasteboard.setString("  \n\t ")
        #expect(ClipReader.read(from: pasteboard) == nil)
    }

    @Test func concealedItemsAreNeverRead() {
        pasteboard.set([[(T.plainText, Data("hunter2".utf8)), (T.concealed, Data())]])
        #expect(ClipReader.read(from: pasteboard) == nil)
        #expect(pasteboard.dataRequests.isEmpty)
    }

    @Test func readsFileURLsFromEveryItem() throws {
        let a = URL(filePath: "/tmp/a.txt")
        let b = URL(filePath: "/tmp/b folder", directoryHint: .isDirectory)
        pasteboard.set([
            [(T.fileURL, a.dataRepresentation), (T.plainText, Data("a.txt".utf8))],
            [(T.fileURL, b.dataRepresentation)],
        ])
        guard case let .files(urls) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("Expected files")
            return
        }
        #expect(urls == [a, b])
    }

    @Test func prefersPNGAndReadsOnlyOneImageType() throws {
        let png = TestImages.encoded()
        pasteboard.set([[(T.tiff, Data([9, 9])), (T.png, png)]])
        guard case let .image(data) = try #require(ClipReader.read(from: pasteboard)) else {
            Issue.record("Expected image")
            return
        }
        #expect(data == png)
        #expect(pasteboard.dataRequests == [T.png])
    }
}
