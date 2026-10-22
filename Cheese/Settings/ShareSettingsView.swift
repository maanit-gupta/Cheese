import AppKit
import SwiftUI

/// Settings → Share: this Mac's name, where received files go, the size limit, and trusted devices.
struct ShareSettingsView: View {
    @AppStorage(PreferenceKey.shareDeviceName) private var deviceName = ""
    @AppStorage(PreferenceKey.shareDestination) private var destinationPath = Preferences.defaultShareDestination.path(percentEncoded: false)
    @AppStorage(PreferenceKey.shareMaxGigabytes) private var maxGigabytes = Preferences.defaultShareMaxGigabytes
    @State private var trusted = TrustStore().devices
    @State private var fingerprint = TLSIdentity.existing()?.fingerprint

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: $deviceName, prompt: Text(Host.current().localizedName ?? "Mac"))
                LabeledContent("Save received files to") {
                    HStack {
                        Text((destinationPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseDestination)
                    }
                }
                Stepper(value: $maxGigabytes, in: 1...1000) {
                    LabeledContent("Largest transfer accepted", value: "\(maxGigabytes) GB")
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Nearby phones and computers see this name. Text and links you receive go on the clipboard (and into clipboard history when it's on).")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Encryption") {
                    if fingerprint != nil {
                        Label("On (HTTPS)", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Set up the first time you open Share", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }
                if let fingerprint {
                    LabeledContent("Certificate fingerprint") {
                        Text(fingerprint.prefix(16).uppercased() + "…")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .help(fingerprint)
                    }
                }
                LabeledContent("Local Network") {
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("LocalSend")
            } footer: {
                Text("Transfers with LocalSend apps are encrypted with a certificate Cheese makes for this Mac and keeps in your Keychain; its fingerprint is how other devices recognize this Mac. The Phone page uses plain HTTP, because phone browsers refuse self-signed certificates. Cheese only listens while the Share panel is open and for 10 minutes after.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if trusted.isEmpty {
                    Text("No trusted devices. Choose \u{201C}Always Accept from This Device\u{201D} when one sends you something.")
                        .foregroundStyle(.secondary)
                }
                ForEach(trusted) { device in
                    LabeledContent {
                        Button("Remove") {
                            TrustStore().remove(device.fingerprint)
                            trusted = TrustStore().devices
                        }
                    } label: {
                        Text(device.alias)
                        Text("Trusted \(device.addedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            } header: {
                Text("Trusted devices")
            } footer: {
                Text("Sends from these are accepted without asking.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            trusted = TrustStore().devices
            fingerprint = TLSIdentity.existing()?.fingerprint
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(filePath: destinationPath, directoryHint: .isDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path(percentEncoded: false)
        }
    }
}
