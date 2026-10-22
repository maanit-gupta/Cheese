import AppKit
import SwiftUI
import os

struct GeneralSettingsView: View {
    let showWelcome: @MainActor () -> Void

    @AppStorage(PreferenceKey.screenshotSaveFolder)
    private var saveFolderPath = Preferences.defaultSaveFolder.path(percentEncoded: false)

    @AppStorage(PreferenceKey.drawLetterKeys) private var drawLetterKeys = false

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Screenshots") {
                LabeledContent("Save folder") {
                    HStack {
                        Text((saveFolderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseSaveFolder)
                    }
                }
            }

            Section {
                Toggle("Advanced: single-letter tool keys", isOn: $drawLetterKeys)
            } header: {
                Text("Draw on Screen")
            } footer: {
                Text("Draw mode works with the mouse alone: hold the right button for tools and colors, ⇧ for straight lines, ⌘ to erase, ⌥ to highlight, and scroll to size the brush. Turn this on to also pick tools with letters (P, H, E, R…).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ModuleID.allCases) { module in
                    ModuleToggle(module: module)
                }
            } header: {
                Text("Modules")
            } footer: {
                Text("A module that's off has no shortcuts, runs nothing in the background, and leaves the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Show Welcome…") {
                    showWelcome()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLaunchAtLogin)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Reverting the toggle after a failure re-enters here; the status already matches, so stop.
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            Logger.settings.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
        if LaunchAtLogin.requiresApproval {
            launchAtLoginMessage = "Approve Cheese in System Settings → General → Login Items."
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(filePath: saveFolderPath, directoryHint: .isDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path(percentEncoded: false)
        }
    }
}

/// One module's on/off switch. Cheese picks the change up from UserDefaults and applies it immediately.
/// Shared by Settings and the welcome tool picker.
struct ModuleToggle<Label: View>: View {
    let module: ModuleID
    @ViewBuilder var label: Label
    @AppStorage private var isOn: Bool

    init(module: ModuleID, @ViewBuilder label: () -> Label) {
        self.module = module
        self.label = label()
        _isOn = AppStorage(wrappedValue: Preferences.defaultModuleEnabled, PreferenceKey.moduleEnabled(module))
    }

    var body: some View {
        Toggle(isOn: $isOn) { label }
    }
}

extension ModuleToggle where Label == Text {
    init(module: ModuleID) {
        self.init(module: module) { Text(module.title) }
    }
}
