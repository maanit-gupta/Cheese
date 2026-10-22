import SwiftUI

struct PermissionsSettingsView: View {
    let permissions: any PermissionChecking
    let openSystemSettings: @MainActor (Permission) -> Void

    var body: some View {
        // Poll so the status updates live while the user flips switches in System Settings.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section {
                    ForEach(Permission.allCases) { permission in
                        PermissionRow(
                            permission: permission,
                            isGranted: permissions.isGranted(permission),
                            openSystemSettings: openSystemSettings
                        )
                    }
                } footer: {
                    Text("macOS may ask you to quit and reopen Cheese before a new Screen Recording grant takes effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}
