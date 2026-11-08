import SwiftUI

/// Settings → Sweep: how long the keyboard and trackpad stay locked.
struct SweepSettingsView: View {
    @AppStorage(PreferenceKey.sweepDuration) private var seconds = SweepDuration.standard.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Lock for", selection: Binding(
                    get: { SweepDuration.stored(seconds) },
                    set: { seconds = $0.rawValue }
                )) {
                    ForEach(SweepDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
            } footer: {
                Text("Start it from Tools ▸ Mode ▸ Sweep. After a three-second countdown, every key, click, movement, scroll and gesture is ignored, brightness and volume keys included, and the display stays on. A chime plays when it's over. To stop early, hold Esc for three seconds. The power button and Touch ID can't be locked by any app.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
