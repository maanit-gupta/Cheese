import Foundation
import Testing
@testable import Cheese

struct PreferencesTests {
    private let defaults: UserDefaults
    private let preferences: Preferences

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "CheeseTests-\(UUID().uuidString)"))
        preferences = Preferences(defaults: defaults)
    }

    @Test func unsetValuesFallBackToDefaults() {
        #expect(preferences.historySize == 200)
        #expect(preferences.ocrLineBreakMode == .keepLineBreaks)
        #expect(preferences.screenshotSaveFolder == Preferences.defaultSaveFolder)
        for language in OCRLanguage.allCases {
            #expect(preferences.isOCRLanguageEnabled(language))
        }
    }

    @Test func storedValuesAreRead() {
        defaults.set(500, forKey: PreferenceKey.historySize)
        defaults.set(OCRLineBreakMode.joinParagraphs.rawValue, forKey: PreferenceKey.ocrLineBreakMode)
        defaults.set("/tmp/Shots", forKey: PreferenceKey.screenshotSaveFolder)
        defaults.set(false, forKey: PreferenceKey.ocrLanguageEnabled(.hindi))

        #expect(preferences.historySize == 500)
        #expect(preferences.ocrLineBreakMode == .joinParagraphs)
        #expect(preferences.screenshotSaveFolder.path(percentEncoded: false) == "/tmp/Shots/")
        #expect(!preferences.isOCRLanguageEnabled(.hindi))
        #expect(preferences.isOCRLanguageEnabled(.english))
    }

    @Test(arguments: [(-5, 50), (0, 50), (49, 50), (1000, 1000), (5000, 1000)])
    func historySizeIsClamped(stored: Int, expected: Int) {
        defaults.set(stored, forKey: PreferenceKey.historySize)
        #expect(preferences.historySize == expected)
    }

    @Test func invalidValuesFallBackToDefaults() {
        defaults.set("sideways", forKey: PreferenceKey.ocrLineBreakMode)
        defaults.set("", forKey: PreferenceKey.screenshotSaveFolder)
        #expect(preferences.ocrLineBreakMode == .keepLineBreaks)
        #expect(preferences.screenshotSaveFolder == Preferences.defaultSaveFolder)
    }

    @Test func keysAreKVOSafe() {
        let keys = [PreferenceKey.screenshotSaveFolder, PreferenceKey.historySize, PreferenceKey.ocrLineBreakMode]
            + OCRLanguage.allCases.map(PreferenceKey.ocrLanguageEnabled)
        #expect(keys.allSatisfy { !$0.contains(".") })
        #expect(Set(keys).count == keys.count)
    }
}
