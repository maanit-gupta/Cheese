import CoreGraphics
import Foundation
import Vision
import os

/// Vision text recognition at the accurate level with language correction.
enum TextRecognizer {
    /// Recognizes text lines in `image`, preferring `languages` in order.
    /// Runs off the caller's actor; Vision work can take a second on a large image.
    @concurrent
    static func recognizeLines(in image: CGImage, languages: [Locale.Language]) async throws -> [OCRLine] {
        do {
            return try await perform(on: image, languages: languages)
        } catch where languages.count > 1 {
            // Some language combinations aren't supported together; fall back to the first.
            Logger.ocr.notice("Recognition with \(languages.count) languages failed, retrying with one: \(error.localizedDescription, privacy: .public)")
            return try await perform(on: image, languages: Array(languages.prefix(1)))
        }
    }

    @concurrent
    static func recognizeText(in image: CGImage, languages: [Locale.Language], mode: OCRLineBreakMode) async throws -> String {
        OCRTextComposer.compose(try await recognizeLines(in: image, languages: languages), mode: mode)
    }

    @concurrent
    private static func perform(on image: CGImage, languages: [Locale.Language]) async throws -> [OCRLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return OCRLine(text: text, box: observation.boundingBox.cgRect)
        }
    }
}

/// QR codes and barcodes.
enum BarcodeReader {
    /// Payloads of every code in `image`, in the order found, without duplicates.
    @concurrent
    static func payloads(in image: CGImage) async throws -> [String] {
        let observations = try await DetectBarcodesRequest().perform(on: image)
        var seen = Set<String>()
        return observations.compactMap(\.payloadString).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// A web link worth offering to open: exactly one payload, and it's an http(s) URL.
    /// Other schemes (file:, custom app schemes) are never opened from a scanned code.
    static func openableURL(from payloads: [String]) -> URL? {
        guard payloads.count == 1, let payload = payloads.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}
