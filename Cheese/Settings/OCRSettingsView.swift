import SwiftUI

struct OCRSettingsView: View {
    let supportedLanguages: Set<OCRLanguage>

    @AppStorage(PreferenceKey.ocrLineBreakMode)
    private var lineBreakMode = Preferences.defaultLineBreakMode

    var body: some View {
        Form {
            Section("Languages") {
                ForEach(OCRLanguage.allCases) { language in
                    OCRLanguageToggle(language: language, isSupported: supportedLanguages.contains(language))
                }
            }

            Section("Line breaks") {
                Picker("Line breaks", selection: $lineBreakMode) {
                    Text("Keep line breaks").tag(OCRLineBreakMode.keepLineBreaks)
                    Text("Join into paragraphs").tag(OCRLineBreakMode.joinParagraphs)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }
}

private struct OCRLanguageToggle: View {
    let language: OCRLanguage
    let isSupported: Bool
    @AppStorage private var isEnabled: Bool

    init(language: OCRLanguage, isSupported: Bool) {
        self.language = language
        self.isSupported = isSupported
        _isEnabled = AppStorage(
            wrappedValue: Preferences.defaultOCRLanguageEnabled,
            PreferenceKey.ocrLanguageEnabled(language)
        )
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            Text(language.displayName)
            if !isSupported {
                Text("Not available on this Mac")
            }
        }
        .disabled(!isSupported)
    }
}
