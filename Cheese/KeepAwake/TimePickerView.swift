import AppKit
import SwiftUI

/// The "Keep Awake Until…" picker: hour and minute, shown 12- or 24-hour per the system locale.
struct TimePickerView: View {
    @State var time: Date
    let onStart: (Date) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            Text("Keep the Mac awake until")
                .font(DesignTokens.Typography.heading)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
            Text("A time that has already passed today means tomorrow.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Keep Awake") { onStart(time) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .frame(width: 300)
    }
}

/// Shows `TimePickerView` in a small window and reports the picked hour and minute.
@MainActor
final class TimePickerWindow {
    private var window: NSWindow?

    func show(onPick: @escaping (_ hour: Int, _ minute: Int) -> Void) {
        close()
        // An hour from now, on the minute.
        let initial = Calendar.current.date(bySetting: .second, value: 0, of: .now.addingTimeInterval(3600)) ?? .now
        let view = TimePickerView(
            time: initial,
            onStart: { [weak self] date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                self?.close()
                onPick(components.hour ?? 0, components.minute ?? 0)
            },
            onCancel: { [weak self] in self?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Keep Awake"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}
