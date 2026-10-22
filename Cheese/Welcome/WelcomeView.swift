import AppKit
import KeyboardShortcuts
import SwiftUI

/// The welcome flow's three screens in one panel: who Cheese is, the tool picker, and the permissions
/// the chosen tools need. Everything is skippable.
struct WelcomeView: View {
    let finish: @MainActor () -> Void
    @State private var step = WelcomeStep.intro
    @State private var status: PermissionStatus

    init(
        permissions: any PermissionChecking,
        openSystemSettings: @escaping @MainActor (Permission) -> Void,
        finish: @escaping @MainActor () -> Void
    ) {
        self.finish = finish
        _status = State(initialValue: PermissionStatus(permissions: permissions, openPermissionSettings: openSystemSettings))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .intro: IntroScreen()
                case .tools: ToolPickerScreen()
                case .permissions: PermissionsScreen(status: status)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 660, height: 580)
        .cheesePanelBackground()
    }

    private var footer: some View {
        CheeseToolbar {
            HStack(spacing: DesignTokens.Spacing.xSmall) {
                ForEach(WelcomeStep.allCases, id: \.self) { page in
                    Circle()
                        .fill(page == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Screen \(step.rawValue + 1) of \(WelcomeStep.allCases.count)")
        } trailing: {
            if step.isFirst {
                Button("Skip") { finish() }
            } else if let previous = step.previous {
                Button("Back") { step = previous }
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
        .controlSize(.regular)
        .padding(.vertical, DesignTokens.Spacing.small)
    }
}

// MARK: - Screens

private struct ScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xSmall) {
            Text(title)
                .font(DesignTokens.Typography.pageTitle)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.xxxLarge)
    }
}

private struct IntroScreen: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xLarge) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text(Brand.name)
                .font(.largeTitle.bold())
            VStack(spacing: DesignTokens.Spacing.xSmall) {
                Text(Brand.tagline)
                    .font(.title2.weight(.medium))
                Text(Brand.subline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: DesignTokens.Spacing.large) {
                ForEach(Verb.allCases) { verb in
                    Label(verb.title, systemImage: verb.symbol)
                        .font(DesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, DesignTokens.Spacing.small)
        }
        .padding(DesignTokens.Spacing.xxxLarge)
    }
}

private struct ToolPickerScreen: View {
    private let columns = [GridItem(.flexible(), spacing: DesignTokens.Spacing.large), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            ScreenHeader(
                title: "Pick your tools",
                subtitle: "Keep what you'll use. A tool that's off has no shortcuts and runs nothing. Change this any time in Settings."
            )
            .padding(.top, DesignTokens.Spacing.xxLarge)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.large) {
                    ForEach(Verb.allCases) { verb in
                        VerbCard(verb: verb)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xxLarge)
                .padding(.bottom, DesignTokens.Spacing.large)
            }
        }
    }
}

private struct VerbCard: View {
    let verb: Verb

    var body: some View {
        CheeseCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                CheeseSectionHeader(verb.title, symbol: verb.symbol)
                ForEach(verb.modules) { module in
                    ModuleToggle(module: module) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                            HStack(spacing: DesignTokens.Spacing.xSmall) {
                                Text(module.title)
                                if let hotkey = module.mainHotkey, let shortcut = KeyboardShortcuts.getShortcut(for: hotkey.name) {
                                    CheeseKeycap(text: shortcut.description)
                                }
                            }
                            Text(module.blurb)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PermissionsScreen: View {
    let status: PermissionStatus

    private var enabled: Set<ModuleID> {
        let preferences = Preferences()
        return Set(ModuleID.allCases.filter(preferences.isModuleEnabled))
    }

    var body: some View {
        let enabled = enabled
        let plan = PermissionPlan.plan(for: enabled)
        VStack(spacing: DesignTokens.Spacing.large) {
            ScreenHeader(
                title: plan.isEmpty ? "No permissions needed" : "Permissions for your tools",
                subtitle: plan.isEmpty
                    ? "The tools you picked work without asking macOS for anything."
                    : "Only what your tools need. You can skip this: Cheese asks again the first time a tool needs one."
            )
            .padding(.top, DesignTokens.Spacing.xxLarge)
            VStack(spacing: DesignTokens.Spacing.small) {
                ForEach(plan) { need in
                    PermissionNeedRow(
                        need: need,
                        usedBy: PermissionPlan.tools(needing: need, among: enabled),
                        state: status.state(of: need),
                        grant: { status.grant(need) }
                    )
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xxLarge)
            Spacer(minLength: 0)
        }
        .task { await status.poll() }
    }
}

/// One permission with the tools that need it, its live status and a Grant button.
struct PermissionNeedRow: View {
    let need: PermissionNeed
    let usedBy: [ModuleID]
    let state: PermissionStatus.State
    let grant: () -> Void

    var body: some View {
        CheeseCard {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Image(systemName: need.symbol)
                    .font(.title3)
                    .frame(width: DesignTokens.Size.rowIcon + 6)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                    Text(need.title)
                        .font(DesignTokens.Typography.heading)
                    Text("For " + ListFormatter.localizedString(byJoining: usedBy.map(\.title)))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch state {
                case .granted:
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .missing:
                    Button("Grant…", action: grant)
                case .unknown:
                    Text("Asked on first use")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    Button("Settings…", action: grant)
                }
            }
        }
    }
}
