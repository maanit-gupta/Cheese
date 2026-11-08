import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case shortcuts
    case clipboard
    case ocr
    case windows
    case appHotkeys
    case files
    case share
    case autoKill
    case caffeinate
    case hush
    case sweep
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
            // Grouped only because a tab builder takes at most ten children.
            Group {
                Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                    GeneralSettingsView(showWelcome: dependencies.showWelcome, updates: dependencies.updates)
                }
                Tab("Shortcuts", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                    ShortcutsSettingsView()
                }
                Tab("Clipboard", systemImage: "doc.on.clipboard", value: SettingsTab.clipboard) {
                    ClipboardSettingsView()
                }
                Tab("OCR", systemImage: "text.viewfinder", value: SettingsTab.ocr) {
                    OCRSettingsView(supportedLanguages: dependencies.supportedOCRLanguages())
                }
            }
            Group {
                Tab("Windows", systemImage: "macwindow.on.rectangle", value: SettingsTab.windows) {
                    WindowsSettingsView()
                }
                Tab("App Hotkeys", systemImage: "app.badge", value: SettingsTab.appHotkeys) {
                    AppHotkeysSettingsView(model: dependencies.appHotkeys)
                }
                Tab("Files", systemImage: "doc.on.doc", value: SettingsTab.files) {
                    FilesSettingsView(model: dependencies.files)
                }
                Tab("Share", systemImage: "dot.radiowaves.left.and.right", value: SettingsTab.share) {
                    ShareSettingsView()
                }
            }
            Group {
                Tab("Auto-Kill", systemImage: "xmark.app", value: SettingsTab.autoKill) {
                    AutoKillSettingsView()
                }
                Tab("Caffeinate", systemImage: "cup.and.saucer", value: SettingsTab.caffeinate) {
                    CaffeinateSettingsView(controller: dependencies.caffeinate)
                }
                Tab("Hush", systemImage: "bell.slash", value: SettingsTab.hush) {
                    HushSettingsView(controller: dependencies.hush)
                }
                Tab("Sweep", systemImage: "bubbles.and.sparkles", value: SettingsTab.sweep) {
                    SweepSettingsView()
                }
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
