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
                        row(for: permission, isGranted: permissions.isGranted(permission))
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

    private func row(for permission: Permission, isGranted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .red)
                .accessibilityLabel(isGranted ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") {
                openSystemSettings(permission)
            }
        }
    }
}
