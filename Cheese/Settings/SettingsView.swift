import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case shortcuts
    case clipboard
    case ocr
    case appHotkeys
    case files
    case share
    case permissions
    case about
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
            Tab("App Hotkeys", systemImage: "app.badge", value: .appHotkeys) {
                AppHotkeysSettingsView(model: dependencies.appHotkeys)
            }
            Tab("Files", systemImage: "doc.on.doc", value: .files) {
                FilesSettingsView(model: dependencies.files)
            }
            Tab("Share", systemImage: "dot.radiowaves.left.and.right", value: .share) {
                ShareSettingsView()
            }
            Tab("Permissions", systemImage: "lock.shield", value: .permissions) {
                PermissionsSettingsView(
                    permissions: dependencies.permissions,
                    openSystemSettings: dependencies.openPermissionSettings
                )
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader {
            SettingsSidebarHeader()
        }
        .frame(width: 720, height: 500)
    }
}

/// Icon and tagline at the top of the Settings sidebar.
private struct SettingsSidebarHeader: View {
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(Brand.name)
                    .font(DesignTokens.Typography.heading)
                Text(Brand.tagline)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.small)
    }
}
