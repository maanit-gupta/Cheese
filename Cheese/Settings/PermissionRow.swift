import SwiftUI

/// One permission's live status with a button to its System Settings pane.
/// Shared by Settings → Permissions and the welcome window.
struct PermissionRow: View {
    let permission: Permission
    let isGranted: Bool
    let openSystemSettings: @MainActor (Permission) -> Void

    var body: some View {
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
