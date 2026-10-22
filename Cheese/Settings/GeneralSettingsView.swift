import AppKit
import SwiftUI
import os

struct GeneralSettingsView: View {
    let showWelcome: @MainActor () -> Void

    @AppStorage(PreferenceKey.screenshotSaveFolder)
    private var saveFolderPath = Preferences.defaultSaveFolder.path(percentEncoded: false)

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
                Button("Show Welcome Guide…") {
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
private struct ModuleToggle: View {
    let module: ModuleID
    @AppStorage private var isOn: Bool

    init(module: ModuleID) {
        self.module = module
        _isOn = AppStorage(wrappedValue: Preferences.defaultModuleEnabled, PreferenceKey.moduleEnabled(module))
    }

    var body: some View {
        Toggle(module.title, isOn: $isOn)
    }
}
