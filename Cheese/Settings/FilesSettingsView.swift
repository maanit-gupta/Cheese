import FinderSync
import SwiftUI

/// State behind Settings → Files: whether the Finder extension is on.
@MainActor
@Observable
final class FilesSettingsModel {
    private(set) var isFinderExtensionEnabled = false

    func refresh() {
        isFinderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}

struct FilesSettingsView: View {
    let model: FilesSettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Finder menu") {
                    HStack {
                        Label(
                            model.isFinderExtensionEnabled ? "On" : "Off",
                            systemImage: model.isFinderExtensionEnabled ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .foregroundStyle(model.isFinderExtensionEnabled ? .green : .secondary)
                        Button("Open Extension Settings…") { model.openExtensionSettings() }
                    }
                }
            } header: {
                Text("Finder")
            } footer: {
                Text("Turn on Cheese under Finder Extensions to get a “Cheese ▸” submenu when you right-click files. You can also drop files on the menu bar icon, or use the command palette.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Everything runs on this Mac: files are never uploaded. Results are saved next to the original and nothing is overwritten.")
                Text("Office conversions are approximate. Word page breaks can differ, Excel keeps values but not cell styling, and PowerPoint drops animations, SmartArt and media. PDF to Word or Excel works best on simple, single-column layouts.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("About the Files tools")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // The user may have flipped the switch in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
