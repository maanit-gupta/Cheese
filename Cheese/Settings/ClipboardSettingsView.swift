import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage(PreferenceKey.historySize) private var historySize = Preferences.defaultHistorySize
    @AppStorage(PreferenceKey.copyCleanLinkAutomatically)
    private var copyCleanLinkAutomatically = Preferences.defaultCopyCleanLinkAutomatically

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
            Section {
                Toggle("Copy clean link automatically", isOn: $copyCleanLinkAutomatically)
            } footer: {
                Text("Removes tracking parameters (utm_, fbclid, YouTube's si…) from copied links, on this Mac. The menu also offers this while a link is on the clipboard.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
