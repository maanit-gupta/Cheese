import AppKit
import SwiftUI

/// Settings → Hush: setting up the two shortcuts, the automatic toggle, and what's happening now.
struct HushSettingsView: View {
    let controller: HushController
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                setupStatus
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    step(1, "In Shortcuts, make a shortcut named exactly **\(HushShortcuts.on)**. Give it a **Set Focus** action set to *Turn Do Not Disturb On*. Optionally, put **Get Current Focus** before it and **Stop and Output** (Current Focus) after it, so Hush leaves a Focus you'd already turned on alone.")
                    step(2, "Make a second shortcut named **\(HushShortcuts.off)** with **Set Focus** set to *Turn Do Not Disturb Off*.")
                    step(3, "Click Test. Hush runs them quietly in the background from then on.")
                }
                HStack {
                    Button("Open Shortcuts") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    Button("Test") {
                        isTesting = true
                        Task {
                            testResult = await controller.test()
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if let testResult {
                    Text(testResult)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Set up")
            } footer: {
                Text("macOS doesn't let apps switch Focus themselves, so Hush uses two shortcuts you make once. If Do Not Disturb is set to share across devices, your iPhone is hushed too.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hush automatically while sharing the screen", isOn: Binding(
                    get: { controller.automatic },
                    set: { controller.setAutomatic($0) }
                ))
            } footer: {
                Text("Counts as sharing: Zoom, Teams, Webex, Slack, Discord, FaceTime and Google Meet (or any site) sharing your screen from a browser, a mirrored display or AirPlay, someone viewing this Mac with Screen Sharing, and Cheese's own screen recordings. Notifications come back 30 seconds after sharing ends. Spotting meeting apps needs Screen Recording.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Label(controller.statusText, systemImage: controller.isEngaged ? "bell.slash.fill" : "bell")
                    Spacer()
                    if controller.reason != nil || controller.isEngaged {
                        Button("Turn Off") { controller.turnOff() }
                    }
                }
            } header: {
                Text("Now")
            }
        }
        .formStyle(.grouped)
        .task { await controller.checkSetup() }
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch controller.setup {
        case .unknown, .checking:
            Label("Checking your shortcuts…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Both shortcuts are set up", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .missing(names):
            Label("Missing: " + names.map { "“\($0)”" }.joined(separator: " and "), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
            Text("\(number).")
                .font(DesignTokens.Typography.numeric)
                .foregroundStyle(.secondary)
            Text(text)
                .font(DesignTokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
