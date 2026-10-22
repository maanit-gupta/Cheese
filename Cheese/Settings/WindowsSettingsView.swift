import SwiftUI

/// Settings → Windows: how Fill to Screen sizes windows around Stage Manager.
struct WindowsSettingsView: View {
    @AppStorage(PreferenceKey.windowFillMode) private var fillMode = Preferences.defaultWindowFillMode
    @AppStorage(PreferenceKey.stageManagerStripInset) private var stripInset = Double(StageManagerLayout.defaultStripInset)
    @State private var stageManager = StageManagerState.off

    var body: some View {
        Form {
            Section {
                Picker("Fill to Screen", selection: $fillMode) {
                    ForEach(WindowFillMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Stage Manager strip") {
                    HStack {
                        Slider(
                            value: $stripInset,
                            in: Double(StageManagerLayout.stripInsetRange.lowerBound)...Double(StageManagerLayout.stripInsetRange.upperBound),
                            step: 4
                        )
                        .frame(width: 180)
                        Text("\(Int(stripInset)) pt")
                            .font(DesignTokens.Typography.numeric)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
                .disabled(fillMode == .fullVisibleFrame)
            } header: {
                Text("Fill to Screen")
            } footer: {
                Text("\(status) Fill All Windows (⌃⌥M) and Fill Current Window (⌃⌥⇧M) resize windows to fill their display, never into native full screen, so Stage Manager's strip stays in reach. Restore All Windows puts them back.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { stageManager = StageManagerDetector.current() }
    }

    private var status: String {
        guard stageManager.isEnabled else { return "Stage Manager is off, so windows fill the whole visible screen." }
        if stageManager.stripAutoHides {
            return "Stage Manager hides its strip of recent apps, so windows fill the whole visible screen."
        }
        let side = StageManagerLayout.stripEdge(dock: stageManager.dockOrientation) == .left ? "left" : "right"
        return "Stage Manager is on, with its strip on the \(side)."
    }
}
