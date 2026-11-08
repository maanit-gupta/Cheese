import SwiftUI

/// Settings → Recording: how GIFs are made, and where recordings go.
struct RecordingSettingsView: View {
    @AppStorage(PreferenceKey.gifFrameRate) private var frameRate = GIFSettings.defaultFrameRate
    @AppStorage(PreferenceKey.gifMaxWidth) private var maxWidth = GIFSettings.defaultMaxWidth
    @AppStorage(PreferenceKey.webcamSize) private var webcamSize = WebcamBubble.Size.medium.rawValue

    var body: some View {
        Form {
            Section {
                Text("Record a region with ⌃⌥R or the whole screen with ⌃⌥⇧R (press again to stop), or use Capture in the menu. Before it starts, the bar under the region switches on your microphone, system audio, camera and the cursor highlight, and picks MP4 or GIF. Recordings are saved to the screenshot folder from Settings → General.")
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("GIF") {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach(GIFSettings.frameRates, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                Picker("Largest width", selection: $maxWidth) {
                    ForEach(GIFSettings.maxWidths, id: \.self) { width in
                        Text(width == 0 ? "Full size" : "\(width) px").tag(width)
                    }
                }
            }
            Section {
                Picker("Webcam size", selection: $webcamSize) {
                    ForEach(WebcamBubble.Size.allCases, id: \.rawValue) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
            } footer: {
                Text("Drag the webcam bubble anywhere over the recording; right-click it to change its size. MP4 recordings keep your voice and system audio on separate tracks, so a video editor can mute either. GIFs have no sound.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
