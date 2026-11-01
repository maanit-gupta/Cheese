import AppKit
import SwiftUI

/// Settings → Caffeinate: the lid-closed toggle, the battery floor, the root helper, and the
/// session that's running.
struct CaffeinateSettingsView: View {
    let controller: CaffeinateController
    @AppStorage(PreferenceKey.caffeinateBatteryFloor) private var batteryFloor = Preferences.defaultCaffeinateBatteryFloor
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep awake with the lid closed", isOn: Binding(
                    get: { controller.wantsLid },
                    set: { controller.setCoversLid($0) }
                ))
                Picker("On battery, stop at", selection: $batteryFloor) {
                    ForEach(Preferences.caffeinateBatteryFloors, id: \.self) { floor in
                        Text(floor == 0 ? "Never" : "\(floor)%").tag(floor)
                    }
                }
                .onChange(of: batteryFloor) { controller.batteryFloorChanged() }
            } footer: {
                Text("With the lid closed, a Mac keeps running and warming up, so don't leave it in a bag. When a session's time runs out with the lid shut, the Mac goes to sleep.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                helperRow
            } header: {
                Text("Lid-closed helper")
            } footer: {
                Text("Keeping a Mac awake with the lid closed needs administrator rights. Cheese installs a small helper once, so it never asks for your password again; macOS lists it as a background item for Cheese under Login Items & Extensions. It only switches lid-close sleep off while Cheese asks, and always switches it back on, even if Cheese quits, crashes or the Mac restarts.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                sessionRow
            } header: {
                Text("Now")
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshHelperStatus() }
    }

    @ViewBuilder
    private var helperRow: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            if controller.isHelperBlocked {
                Label("Not allowed to run in the background", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items…") {
                    if let url = CaffeinateController.loginItemsURL { NSWorkspace.shared.open(url) }
                }
            } else {
                switch controller.helperStatus {
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove…") { run { await controller.removeHelper() } }
                case .outdated:
                    Label("Needs an update", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("Update…") { run { await controller.installHelper() } }
                case .notInstalled:
                    Text("Not installed. Cheese asks to install it the first time a session needs it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Install…") { run { await controller.installHelper() } }
                }
            }
        }
        .disabled(isWorking)
    }

    @ViewBuilder
    private var sessionRow: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            if let session = controller.session {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                    Text("Caffeinating \(session.duration.phrase())")
                    Text(session.coversLid ? "Covers a closed lid" : "Closing the lid sleeps the Mac")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Turn Off") { controller.turnOff() }
            } else {
                Text("Off. Start a session from the Caffeinate menu.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}
