import AppKit
import SwiftUI

/// "Pixel 8 wants to send 3 files (24 MB)": Decline, Accept, or Always accept from this device.
/// Unanswered prompts decline themselves after `timeout`.
@MainActor
final class ReceivePrompt {
    static let timeout: Duration = .seconds(120)
    private var panel: CheesePanel?

    func ask(_ summary: String, from sender: LocalSend.DeviceInfo) async -> ReceiveAnswer {
        // One question at a time; a second device asking meanwhile is declined.
        guard panel == nil else { return .decline }
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: @MainActor (ReceiveAnswer) -> Void = { [weak self] value in
                guard !answered else { return }
                answered = true
                self?.panel?.dismiss()
                self?.panel = nil
                continuation.resume(returning: value)
            }
            let peer = LocalSendPeer(info: sender, address: "-")
            let view = ReceivePromptView(summary: summary, symbol: peer?.symbol ?? "desktopcomputer", answer: answer)
            var behavior = CheesePanel.Behavior()
            behavior.dismissesOnOutsideClick = false
            let panel = CheesePanel(rootView: view, behavior: behavior)
            panel.onCancel = { answer(.decline) }
            self.panel = panel
            panel.present(at: .centered)
            NSSound.beep()
            Task {
                try? await Task.sleep(for: Self.timeout)
                answer(.decline)
            }
        }
    }
}

private struct ReceivePromptView: View {
    let summary: String
    let symbol: String
    let answer: @MainActor (ReceiveAnswer) -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.Size.emptyStateSymbol))
                .foregroundStyle(.tint)
            Text(summary)
                .font(DesignTokens.Typography.panelTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Files go to \(Preferences().shareDestination.lastPathComponent).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Decline") { answer(.decline) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Always Accept from This Device") { answer(.alwaysAccept) }
                Button("Accept") { answer(.accept) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .frame(width: 460)
        .cheesePanelBackground()
    }
}
