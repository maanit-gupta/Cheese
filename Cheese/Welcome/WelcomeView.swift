import AppKit
import KeyboardShortcuts
import SwiftUI
import os

struct WelcomeView: View {
    let permissions: any PermissionChecking
    let openSystemSettings: @MainActor (Permission) -> Void
    let finish: @MainActor () -> Void

    @State private var step = WelcomeStep.intro

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .intro: IntroPage()
                case .permissions: PermissionsPage(permissions: permissions, openSystemSettings: openSystemSettings)
                case .shortcuts: ShortcutsPage()
                case .finish: FinishPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 620, height: 580)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(WelcomeStep.allCases, id: \.self) { page in
                    Circle()
                        .fill(page == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(step.rawValue + 1) of \(WelcomeStep.allCases.count)")

            Spacer()

            if let previous = step.previous {
                Button("Back") { step = previous }
                    .keyboardShortcut(.cancelAction)
            }
            Button(step.isLast ? "Start Using Cheese" : "Continue") {
                if let next = step.next {
                    step = next
                } else {
                    finish()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: - Pages

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title.bold())
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
    }
}

private struct IntroPage: View {
    private static let features: [(symbol: String, title: String, detail: String, hotkey: Hotkey)] = [
        ("doc.on.clipboard", "Clipboard history", "Everything you copy, searchable and one keystroke from pasting.", .openHistory),
        ("camera.viewfinder", "Screenshots", "Region, window or full screen, straight to the clipboard. Hold Shift to annotate.", .captureRegion),
        ("text.viewfinder", "Copy text from anything", "OCR any part of the screen. QR codes and barcodes too.", .ocrRegion),
        ("rectangle.expand.vertical", "Scrolling capture", "Cheese scrolls the page for you and stitches one tall image.", .scrollingCapture),
        ("rectangle.split.2x1", "Window snapping", "Halves, maximize and multi-display moves from the keyboard.", .snapLeft),
        ("pencil.and.scribble", "Draw on screen", "Pens, shapes, sticky notes and a laser pointer over everything.", .drawOnScreen),
        ("command", "Command palette", "Search every Cheese action, plus QR sharing and Keep Awake.", .commandPalette),
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                PageHeader(title: "Welcome to Cheese", subtitle: "Everyday tools that live in your menu bar.")
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.features, id: \.title) { feature in
                    HStack(spacing: 14) {
                        Image(systemName: feature.symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline)
                            Text(feature.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if let shortcut = KeyboardShortcuts.getShortcut(for: feature.hotkey.name) {
                            Text(shortcut.description)
                                .font(.callout.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: .rect(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(.horizontal, 48)
        }
        .padding(.top, 28)
    }
}

private struct PermissionsPage: View {
    let permissions: any PermissionChecking
    let openSystemSettings: @MainActor (Permission) -> Void

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(
                title: "Two quick permissions",
                subtitle: "macOS asks you to approve these yourself. You can skip this step: Cheese asks again the first time a feature needs one."
            )
            .padding(.top, 36)

            // Poll so the status updates live while the user flips switches in System Settings.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Form {
                    Section {
                        ForEach(Permission.allCases) { permission in
                            PermissionRow(
                                permission: permission,
                                isGranted: permissions.isGranted(permission),
                                openSystemSettings: openSystemSettings
                            )
                        }
                    } footer: {
                        Text("After turning on Screen Recording, macOS may ask you to quit and reopen Cheese.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
        }
    }
}

private struct ShortcutsPage: View {
    var body: some View {
        VStack(spacing: 4) {
            PageHeader(
                title: "Make the shortcuts yours",
                subtitle: "These are the defaults. Change any of them now or later from the menu bar icon → Keyboard Shortcuts…"
            )
            .padding(.top, 36)
            ShortcutsSettingsView()
        }
    }
}

private struct FinishPage: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            PageHeader(title: "You're all set", subtitle: "Cheese is running in your menu bar. Look for the cheese wedge near the clock.")

            VStack(alignment: .leading, spacing: 12) {
                Label("Click the icon for every tool, starting with Clipboard History.", systemImage: "cursorarrow.click")
                Label("Change any shortcut from Keyboard Shortcuts… in that menu.", systemImage: "keyboard")
                Label("Hold Shift as you finish a screenshot to annotate it.", systemImage: "shift")
            }
            .font(.callout)

            VStack(spacing: 4) {
                Toggle("Open Cheese automatically when you log in", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 48)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Reverting the toggle after a failure re-enters here; the status already matches, so stop.
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            Logger.welcome.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        if LaunchAtLogin.requiresApproval {
            launchAtLoginMessage = "Approve Cheese in System Settings → General → Login Items."
        }
    }
}
