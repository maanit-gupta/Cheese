import AppKit
import SwiftUI
import os

struct GeneralSettingsView: View {
    let showWelcome: @MainActor () -> Void
    @ObservedObject var updates: UpdateService

    @AppStorage(PreferenceKey.screenshotSaveFolder)
    private var saveFolderPath = Preferences.defaultSaveFolder.path(percentEncoded: false)

    @AppStorage(PreferenceKey.captureDestination)
    private var captureDestination = Preferences.defaultCaptureDestination

    @AppStorage(PreferenceKey.drawLetterKeys) private var drawLetterKeys = true

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
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("After a capture", selection: $captureDestination) {
                    ForEach(CaptureDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                LabeledContent("Save folder") {
                    HStack {
                        Text((saveFolderPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseSaveFolder)
                    }
                }
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Applies to region, window, full-screen and scrolling captures and to draw-mode snapshots. Also under Capture ▸ After Capture in the menu bar. Hold ⇧ while capturing to open the editor instead.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Single-letter tool keys", isOn: $drawLetterKeys)
            } header: {
                Text("Draw on Screen")
            } footer: {
                Text("Pick tools with one letter while drawing: P pen, H highlighter, E eraser, I line, A arrow, R rectangle, O ellipse, T text, V select, M click-through. Each letter shows on its button in the draw HUD. Turn this off if you'd rather keep letters for the apps underneath; the mouse alone still does everything.")
                    .font(DesignTokens.Typography.caption)
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
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $updates.autoCheckEnabled)
                LabeledContent("Version") {
                    HStack {
                        Text(verbatim: "Cheese \(updates.currentVersion)")
                        if updates.updateAvailable {
                            Button("Update to \(updates.latestVersion)…") {
                                updates.presentUpdatePrompt()
                            }
                            .disabled(updates.isInstalling)
                        } else {
                            Button("Check Now") {
                                Task { await updates.checkForUpdates(userInitiated: true) }
                            }
                            .disabled(updates.isChecking || updates.isInstalling)
                        }
                    }
                }
                if !updates.statusMessage.isEmpty {
                    Text(updates.statusMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Cheese asks GitHub for its newest release when it starts and every 12 hours; nothing about you or this Mac is sent. Updating downloads Cheese.zip, checks its checksum and signature, replaces Cheese where it is, and reopens it. Also under Check for Updates… in the menu bar.")
                    .font(DesignTokens.Typography.caption)
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
