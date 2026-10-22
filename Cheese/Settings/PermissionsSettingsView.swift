import SwiftUI

/// Settings → Permissions: every permission Cheese can use, which tools use it, and its live status,
/// with the same rows as the welcome screen.
struct PermissionsSettingsView: View {
    @State private var status: PermissionStatus

    init(permissions: any PermissionChecking, openSystemSettings: @escaping @MainActor (Permission) -> Void) {
        _status = State(initialValue: PermissionStatus(permissions: permissions, openPermissionSettings: openSystemSettings))
    }

    var body: some View {
        Form {
            Section {
                ForEach(PermissionNeed.allCases) { need in
                    PermissionNeedRow(
                        need: need,
                        usedBy: PermissionPlan.tools(needing: need, among: Set(ModuleID.allCases)),
                        state: status.state(of: need),
                        grant: { status.grant(need) }
                    )
                    .listRowSeparator(.hidden)
                }
            } footer: {
                Text("macOS may ask you to quit and reopen Cheese before a new Screen Recording grant takes effect.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Polls so statuses update live while the user flips switches in System Settings.
        .task { await status.poll() }
    }
}
