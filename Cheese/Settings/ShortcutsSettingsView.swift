import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    private static let sections: [(title: String, hotkeys: [Hotkey])] = [
        ("Clipboard", [.openHistory]),
        ("Capture", [.captureRegion, .captureFullScreen, .captureWindow, .ocrRegion, .scrollingCapture]),
        ("Windows", [.snapLeft, .snapRight, .maximize, .snapBottom, .restoreWindow]),
        ("Tools", [.drawOnScreen, .commandPalette]),
        ("Share", [.toggleShelf, .showShare]),
    ]

    var body: some View {
        Form {
            Section {
                Text("Click a shortcut and press the keys you want instead. Click ⓧ to turn one off.")
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }

            ForEach(Self.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.hotkeys, id: \.self) { hotkey in
                        KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                    }
                }
            }

            Section {
                Button("Restore Defaults") {
                    KeyboardShortcuts.reset(Hotkey.allCases.map(\.name))
                }
            }
        }
        .formStyle(.grouped)
    }
}
