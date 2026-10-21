import SwiftUI

struct SettingsView: View {
    let dependencies: SettingsDependencies

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsView()
            }
            Tab("Clipboard", systemImage: "doc.on.clipboard") {
                ClipboardSettingsView()
            }
            Tab("OCR", systemImage: "text.viewfinder") {
                OCRSettingsView(supportedLanguages: dependencies.supportedOCRLanguages())
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsView(
                    permissions: dependencies.permissions,
                    openSystemSettings: dependencies.openPermissionSettings
                )
            }
        }
        .frame(width: 520, height: 440)
    }
}
