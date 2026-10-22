import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import Cheese

struct OCRTextComposerTests {
    /// A line box in normalized coordinates, with `top` measured down from the top of the image.
    private func line(_ text: String, x: CGFloat = 0.05, top: CGFloat, width: CGFloat = 0.9, height: CGFloat = 0.04) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: 1 - top - height, width: width, height: height))
    }

    @Test func keepsLineBreaksInReadingOrder() {
        let lines = [line("second", top: 0.2), line("first", top: 0.1), line("third", top: 0.3)]
        #expect(OCRTextComposer.compose(lines, mode: .keepLineBreaks) == "first\nsecond\nthird")
    }

    @Test func sideBySideCellsShareARow() {
        let lines = [
            line("Total", x: 0.05, top: 0.1, width: 0.2),
            line("$42.00", x: 0.7, top: 0.105, width: 0.2),
            line("Next row", x: 0.05, top: 0.2, width: 0.3),
        ]
        #expect(OCRTextComposer.compose(lines, mode: .keepLineBreaks) == "Total $42.00\nNext row")
    }

    @Test func joinsWrappedLinesIntoParagraphs() {
        let lines = [
            line("The quick brown fox jumps over", top: 0.10),
            line("the lazy dog. It was not amused.", top: 0.15, width: 0.5),
            line("A new paragraph after a gap", top: 0.30),
            line("continues here.", top: 0.35, width: 0.3),
        ]
        let text = OCRTextComposer.compose(lines, mode: .joinParagraphs)
        #expect(text == "The quick brown fox jumps over the lazy dog. It was not amused.\n\nA new paragraph after a gap continues here.")
    }

    @Test func shortLineEndingASentenceStartsANewParagraph() {
        let lines = [
            line("Heading:", top: 0.10, width: 0.2),
            line("Body text that fills the whole line width", top: 0.15),
        ]
        #expect(OCRTextComposer.compose(lines, mode: .joinParagraphs) == "Heading:\n\nBody text that fills the whole line width")
    }

    @Test func rejoinsHyphenatedWordsButKeepsRealHyphens() {
        let split = [line("character recog-", top: 0.1), line("nition works", top: 0.15)]
        #expect(OCRTextComposer.compose(split, mode: .joinParagraphs) == "character recognition works")

        let real = [line("see the Jean-", top: 0.1), line("Luc story", top: 0.15)]
        #expect(OCRTextComposer.compose(real, mode: .joinParagraphs) == "see the Jean- Luc story")
    }

    @Test func handlesDevanagariDanda() {
        let lines = [line("यह पहला वाक्य है।", top: 0.1, width: 0.4), line("दूसरा अनुच्छेद", top: 0.15)]
        #expect(OCRTextComposer.compose(lines, mode: .joinParagraphs) == "यह पहला वाक्य है।\n\nदूसरा अनुच्छेद")
    }

    @Test func emptyInput() {
        #expect(OCRTextComposer.compose([], mode: .joinParagraphs).isEmpty)
        #expect(OCRTextComposer.compose([line("  ", top: 0.1)], mode: .keepLineBreaks).isEmpty)
    }

    @Test func countsWords() {
        #expect(OCRTextComposer.wordCount("one two\nthree\t four") == 4)
        #expect(OCRTextComposer.wordCount("नमस्ते दुनिया") == 2)
        #expect(OCRTextComposer.wordCount("") == 0)
    }
}

struct OCRResultTests {
    @Test func summaries() {
        #expect(OCRResult.text("one").summary == "Copied 1 word")
        #expect(OCRResult.text("one two three").summary == "Copied 3 words")
        #expect(OCRResult.codes(["x"]).summary == "Copied code contents")
        #expect(OCRResult.codes(["x", "y"]).summary == "Copied 2 codes")
        #expect(OCRResult.nothing.copyText == nil)
        #expect(OCRResult.codes(["a", "b"]).copyText == "a\nb")
    }

    @Test func onlySingleWebLinksAreOpenable() {
        #expect(BarcodeReader.openableURL(from: ["https://example.com/a?b=1"])?.host() == "example.com")
        #expect(BarcodeReader.openableURL(from: [" http://example.com "]) != nil)
        #expect(BarcodeReader.openableURL(from: ["file:///etc/passwd"]) == nil)
        #expect(BarcodeReader.openableURL(from: ["myapp://do-something"]) == nil)
        #expect(BarcodeReader.openableURL(from: ["just some text"]) == nil)
        #expect(BarcodeReader.openableURL(from: ["https://a.com", "https://b.com"]) == nil)
    }

    @Test func recognitionLanguagesUseVisionIdentifiersInOrder() {
        let supported = [Locale.Language(identifier: "en-Latn-US"), Locale.Language(identifier: "hi-Deva-IN")]
        #expect(OCRLanguageSupport.recognitionLanguages(enabled: [.english, .hindi], supported: supported) == supported)
        #expect(OCRLanguageSupport.recognitionLanguages(enabled: [.hindi], supported: supported) == [supported[1]])
        #expect(OCRLanguageSupport.recognitionLanguages(enabled: [.hindi], supported: [supported[0]]).isEmpty)
    }
}

/// End-to-end checks that run Vision on rendered images.
struct VisionIntegrationTests {
    private func renderedText(_ text: String, size: CGSize = CGSize(width: 900, height: 200)) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 56),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 30, y: 70)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    private func qrCode(_ payload: String) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        let output = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -40, dy: -40)))
        return try #require(CIContext().createCGImage(padded, from: padded.extent))
    }

    @Test func recognizesRenderedEnglish() async throws {
        let image = try renderedText("Hello Cheese 2026")
        let service = OCRService(languages: { [Locale.Language(identifier: "en-US")] }, lineBreakMode: { .keepLineBreaks })
        let result = await service.read(image)
        guard case let .text(text) = result else {
            Issue.record("Expected text, got \(result)")
            return
        }
        #expect(text.localizedCaseInsensitiveContains("hello cheese"))
    }

    @Test func barcodesTakePriorityOverText() async throws {
        let image = try qrCode("https://github.com/maanit-gupta/Cheese")
        let result = await OCRService(languages: { [] }, lineBreakMode: { .keepLineBreaks }).read(image)
        #expect(result == .codes(["https://github.com/maanit-gupta/Cheese"]))
    }

    @Test func blankImageHasNothing() async throws {
        let image = try renderedText("")
        #expect(await OCRService(languages: { [] }, lineBreakMode: { .keepLineBreaks }).read(image) == .nothing)
    }
}

@MainActor
struct LiveTextIndexerTests {
    private func writePNG(_ image: CGImage, to url: URL) throws {
        let png = try ImageExport.pngData(for: CapturedImage(image: image, scale: 1))
        try png.write(to: url)
    }

    private func renderedText(_ text: String) throws -> CGImage {
        let size = CGSize(width: 900, height: 200)
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black,
        ]))
        context.textPosition = CGPoint(x: 30, y: 70)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    @Test func indexesImagesAndReportsFailuresAsEmpty() async throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appending(path: "good.png")
        try writePNG(try renderedText("Invoice 4521"), to: good)
        let missing = folder.appending(path: "missing.png")

        var results: [UUID: String] = [:]
        let indexer = LiveTextIndexer(ocr: OCRService(languages: { [] }, lineBreakMode: { .keepLineBreaks })) { id, text in
            results[id] = text
        }
        let goodID = UUID()
        let missingID = UUID()
        indexer.enqueue(goodID, imageURL: good)
        indexer.enqueue(goodID, imageURL: good)
        indexer.enqueue(missingID, imageURL: missing)

        for _ in 0..<600 where results.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(results[goodID]?.contains("4521") == true)
        #expect(results[missingID] == "")
        #expect(indexer.isIdle)
    }
}
