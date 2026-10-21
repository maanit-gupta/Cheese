import Foundation
import Vision

enum OCRLanguageSupport {
    /// Languages Vision can recognize at the accurate level on this Mac.
    static func supportedLanguages() -> Set<OCRLanguage> {
        available(among: RecognizeTextRequest().supportedRecognitionLanguages)
    }

    static func available(among recognized: [Locale.Language]) -> Set<OCRLanguage> {
        let codes = Set(recognized.compactMap(\.languageCode))
        return Set(OCRLanguage.allCases.filter { codes.contains($0.languageCode) })
    }
}
