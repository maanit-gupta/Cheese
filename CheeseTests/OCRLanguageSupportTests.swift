import Foundation
import Testing
@testable import Cheese

struct OCRLanguageSupportTests {
    @Test func matchesByLanguageCodeIgnoringRegionAndScript() {
        let recognized = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "hi-Deva-IN")]
        #expect(OCRLanguageSupport.available(among: recognized) == [.english, .hindi])
    }

    @Test func reportsHindiUnavailableWhenVisionLacksIt() {
        let recognized = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "fr-FR")]
        #expect(OCRLanguageSupport.available(among: recognized) == [.english])
    }

    @Test func doesNotConfuseHindiWithOtherDevanagariLanguages() {
        let recognized = [Locale.Language(identifier: "mr-Deva-IN")]
        #expect(OCRLanguageSupport.available(among: recognized).isEmpty)
    }
}
