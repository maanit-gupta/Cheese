import SwiftUI

enum SettingsTab: Hashable {
    case general
    case shortcuts
    case clipboard
    case ocr
    case permissions
}

/// Which tab Settings shows, so the status menu can open it straight on Shortcuts.
@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    let dependencies: SettingsDependencies
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsView(showWelcome: dependencies.showWelcome)
            }
            Tab("Shortcuts", systemImage: "keyboard", value: .shortcuts) {
                ShortcutsSettingsView()
            }
            Tab("Clipboard", systemImage: "doc.on.clipboard", value: .clipboard) {
                ClipboardSettingsView()
            }
            Tab("OCR", systemImage: "text.viewfinder", value: .ocr) {
                OCRSettingsView(supportedLanguages: dependencies.supportedOCRLanguages())
            }
            Tab("Permissions", systemImage: "lock.shield", value: .permissions) {
                PermissionsSettingsView(
                    permissions: dependencies.permissions,
                    openSystemSettings: dependencies.openPermissionSettings
                )
            }
        }
        .frame(width: 520, height: 440)
    }
}
