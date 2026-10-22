import AppKit
import SwiftUI

/// Settings → Auto-Kill: force-quitting stragglers, and the shielded apps sweeps leave open.
struct AutoKillSettingsView: View {
    @AppStorage(PreferenceKey.autoKillForcesStragglers) private var forcesStragglers = false
    @State private var protectedIDs: [String] = []

    private let store = ProtectedAppsStore()

    var body: some View {
        Form {
            Section {
                Toggle("Force-kill unresponsive apps after 3 s", isOn: $forcesStragglers)
            } footer: {
                Text("Any app still open 3 seconds after Kill All is force-quit, including one waiting on “Save changes?”, and its unsaved work is lost. Holding ⌥ in the Auto-Kill panel does this for one sweep.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if protectedIDs.isEmpty {
                    Text("No protected apps. Click the lock next to an app in the Auto-Kill panel to keep it open.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(protectedIDs, id: \.self) { bundleID in
                        ProtectedAppRow(bundleID: bundleID) {
                            store.setProtected(false, bundleID)
                            reload()
                        }
                    }
                }
            } header: {
                Text("Protected apps")
            } footer: {
                Text("Kill All never quits Cheese or Finder, and leaves these open too.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in reload() }
    }

    private func reload() {
        let ids = store.bundleIDs.sorted { ProtectedAppRow.name(of: $0).localizedStandardCompare(ProtectedAppRow.name(of: $1)) == .orderedAscending }
        if ids != protectedIDs {
            protectedIDs = ids
        }
    }
}

private struct ProtectedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: DesignTokens.Spacing.small) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: DesignTokens.Size.rowIcon, height: DesignTokens.Size.rowIcon)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: DesignTokens.Size.rowIcon)
                    .foregroundStyle(.secondary)
            }
            Text(Self.name(of: bundleID))
            if url == nil {
                Text("Not found")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CheeseIconButton(symbol: "minus.circle", help: "Stop protecting", action: remove)
        }
    }

    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }
}
