import AVFoundation
import AppKit
import SwiftUI

/// What the recording bars show and send back. Owned by `RecordingController`.
@MainActor
@Observable
final class RecordingBarModel {
    var options = RecordingOptions()
    var phase = RecordingPhase.idle
    var elapsedText = "0:00"
    var microphones: [AudioInput] = []

    struct AudioInput: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @ObservationIgnored var onRecord: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onOptionsChange: (RecordingOptions) -> Void = { _ in }
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onPauseResume: () -> Void = {}
    @ObservationIgnored var onRestart: () -> Void = {}
    @ObservationIgnored var onDiscard: () -> Void = {}

    func update(_ change: (inout RecordingOptions) -> Void) {
        var options = options
        change(&options)
        self.options = options
        onOptionsChange(options)
    }

    func refreshMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        microphones = session.devices.map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
    }
}

// MARK: - Setup bar

/// Before recording: what to record along with the screen, MP4 or GIF, and Record.
struct RecordingSetupBar: View {
    @Bindable var model: RecordingBarModel

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.hairline) {
                CheeseIconButton(
                    symbol: model.options.microphone ? "mic.fill" : "mic.slash",
                    help: model.options.microphone ? "Microphone on" : "Record your voice",
                    isActive: model.options.microphone && model.options.format == .mp4
                ) {
                    model.update { $0.microphone.toggle() }
                }
                .disabled(model.options.format == .gif)
                microphoneMenu
            }
            CheeseIconButton(
                symbol: model.options.systemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                help: model.options.systemAudio ? "System audio on" : "Record system audio",
                isActive: model.options.systemAudio && model.options.format == .mp4
            ) {
                model.update { $0.systemAudio.toggle() }
            }
            .disabled(model.options.format == .gif)
            CheeseIconButton(
                symbol: model.options.camera ? "video.fill" : "video.slash",
                help: model.options.camera ? "Camera on" : "Show your camera",
                isActive: model.options.camera
            ) {
                model.update { $0.camera.toggle() }
            }
            CheeseIconButton(
                symbol: "cursorarrow.rays",
                help: model.options.cursorHalo ? "Cursor highlight on" : "Highlight the cursor",
                isActive: model.options.cursorHalo
            ) {
                model.update { $0.cursorHalo.toggle() }
            }
            CheeseDivider(axis: .vertical).frame(height: DesignTokens.Size.iconButton.height)
            Picker("Format", selection: Binding(
                get: { model.options.format },
                set: { format in model.update { $0.format = format } }
            )) {
                ForEach(RecordingFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            CheeseDivider(axis: .vertical).frame(height: DesignTokens.Size.iconButton.height)
            Button("Cancel", action: model.onCancel)
                .keyboardShortcut(.cancelAction)
            Button(action: model.onRecord) {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.large)
        .padding(.vertical, DesignTokens.Spacing.small)
        .cheesePanelBackground()
        .fixedSize()
        .onAppear { model.refreshMicrophones() }
    }

    private var microphoneMenu: some View {
        Menu {
            Picker("Microphone", selection: Binding(
                get: { model.options.microphoneID ?? "" },
                set: { id in model.update { $0.microphoneID = id.isEmpty ? nil : id } }
            )) {
                Text("System Default").tag("")
                ForEach(model.microphones) { input in
                    Text(input.name).tag(input.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a microphone")
        .disabled(model.options.format == .gif)
    }
}

// MARK: - Control bar

/// While recording: the time, Pause or Resume, Restart, Discard and Stop. Never in the video.
struct RecordingControlBar: View {
    let model: RecordingBarModel

    private var isPaused: Bool { model.phase == .paused }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Circle()
                .fill(isPaused ? Color.secondary : Color.red)
                .frame(width: DesignTokens.Spacing.small, height: DesignTokens.Spacing.small)
            Text(model.elapsedText)
                .font(DesignTokens.Typography.numeric)
                .frame(minWidth: 44, alignment: .leading)
            CheeseIconButton(symbol: isPaused ? "play.fill" : "pause.fill", help: isPaused ? "Resume" : "Pause", action: model.onPauseResume)
            CheeseIconButton(symbol: "arrow.counterclockwise", help: "Restart", action: model.onRestart)
            CheeseIconButton(symbol: "trash", help: "Discard", role: .destructive, action: model.onDiscard)
            Button(action: model.onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.large)
        .padding(.vertical, DesignTokens.Spacing.xSmall)
        .cheeseSurface(in: Capsule())
        .fixedSize()
    }
}

/// A floating window for the control bar that never takes the keyboard from the app being
/// recorded, and acts on the first click.
@MainActor
final class RecordingControlPanel {
    private var panel: NSPanel?

    func show(model: RecordingBarModel, around region: CGRect) {
        guard panel == nil else { return }
        let panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Before `level`: setting it afterwards would put the level back to `.floating`.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = FirstMouseHostingView(rootView: RecordingControlBar(model: model))
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(PanelPositions.origin(around: region, size: hosting.fittingSize, in: visible))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Countdown

/// The 3-2-1 before recording starts, in the middle of the region. Not in the video.
@MainActor
final class RecordingCountdown {
    @Observable
    final class Model {
        var number = 3
    }

    private let model = Model()
    private var panel: NSPanel?

    func show(_ number: Int, centeredIn region: CGRect) {
        model.number = number
        guard panel == nil else { return }
        let side: CGFloat = 120
        let panel = NSPanel(
            contentRect: CGRect(x: region.midX - side / 2, y: region.midY - side / 2, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct CountdownView: View {
    let model: RecordingCountdown.Model

    var body: some View {
        Text("\(model.number)")
            .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cheeseSurface(in: Circle())
            .contentTransition(.numericText(countsDown: true))
            .animation(DesignTokens.animation(DesignTokens.Duration.gentle, reduceMotion: DesignTokens.reducesMotion), value: model.number)
    }
}
