import CoreGraphics
import Foundation
import Vision
import os

/// What reading a region produced.
enum OCRResult: Equatable, Sendable {
    /// Barcode payloads, which take priority over text.
    case codes([String])
    case text(String)
    case nothing

    /// What to put on the pasteboard.
    var copyText: String? {
        switch self {
        case let .codes(payloads): payloads.joined(separator: "\n")
        case let .text(text): text
        case .nothing: nil
        }
    }

    var summary: String {
        switch self {
        case let .codes(payloads):
            payloads.count == 1 ? "Copied code contents" : "Copied \(payloads.count) codes"
        case let .text(text):
            OCRTextComposer.wordCount(text) == 1 ? "Copied 1 word" : "Copied \(OCRTextComposer.wordCount(text)) words"
        case .nothing:
            "No text found"
        }
    }
}

/// Reads text and codes from images using the languages and line-break mode set in Settings.
struct OCRService: Sendable {
    var languages: @Sendable () -> [Locale.Language]
    var lineBreakMode: @Sendable () -> OCRLineBreakMode

    static let live = OCRService(
        languages: {
            let preferences = Preferences()
            return OCRLanguageSupport.recognitionLanguages(
                enabled: OCRLanguage.allCases.filter(preferences.isOCRLanguageEnabled),
                supported: RecognizeTextRequest().supportedRecognitionLanguages
            )
        },
        lineBreakMode: { Preferences().ocrLineBreakMode }
    )

    /// Barcodes first; if there are none, text.
    func read(_ image: CGImage) async -> OCRResult {
        async let codes = BarcodeReader.payloads(in: image)
        async let text = TextRecognizer.recognizeText(in: image, languages: languages(), mode: lineBreakMode())

        do {
            let payloads = try await codes
            if !payloads.isEmpty { return .codes(payloads) }
        } catch {
            Logger.ocr.error("Barcode detection failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let recognized = try await text.trimmingCharacters(in: .whitespacesAndNewlines)
            return recognized.isEmpty ? .nothing : .text(recognized)
        } catch {
            Logger.ocr.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            return .nothing
        }
    }

    /// Plain text for indexing, ignoring line-break settings. Throws on Vision failure.
    func indexText(in image: CGImage) async throws -> String {
        try await TextRecognizer.recognizeText(in: image, languages: languages(), mode: .keepLineBreaks)
    }
}
