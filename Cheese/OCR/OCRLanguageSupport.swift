import Foundation
import Vision

enum OCRLanguageSupport {
    /// Languages Vision can recognize at the accurate level on this Mac.
    static func supportedLanguages() -> Set<OCRLanguage> {
        available(among: RecognizeTextRequest().supportedRecognitionLanguages)
    }

    /// Vision's own identifiers for the enabled languages it supports, in `OCRLanguage` order.
    /// Empty means "let Vision choose", which happens when nothing enabled is supported.
    static func recognitionLanguages(enabled: [OCRLanguage], supported: [Locale.Language]) -> [Locale.Language] {
        enabled.compactMap { language in
            supported.first { $0.languageCode == language.languageCode }
        }
    }

    static func available(among recognized: [Locale.Language]) -> Set<OCRLanguage> {
        let codes = Set(recognized.compactMap(\.languageCode))
        return Set(OCRLanguage.allCases.filter { codes.contains($0.languageCode) })
    }
}
