import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage(PreferenceKey.historySize) private var historySize = Preferences.defaultHistorySize

    var body: some View {
        Form {
            Section {
                Stepper(value: $historySize, in: Preferences.historySizeRange, step: 50) {
                    LabeledContent("History size", value: "\(historySize) items")
                }
            } footer: {
                Text("Pinned items don't count toward this limit and never expire.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
