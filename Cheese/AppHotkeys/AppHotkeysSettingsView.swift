import AppKit
import KeyboardShortcuts
import SwiftUI

/// What the App Hotkeys tab needs: the bindings, the installed-app index, and which keys are taken.
@MainActor
@Observable
final class AppHotkeysSettingsModel {
    let store: AppHotkeyStore
    private(set) var installedApps: [InstalledApp] = []
    @ObservationIgnored private let index: InstalledAppIndex
    /// Letters and digits already bound with Ctrl+Opt+Cmd anywhere: Cheese, macOS, known utilities.
    @ObservationIgnored let takenCharacters: @MainActor () -> Set<Character>

    init(store: AppHotkeyStore, index: InstalledAppIndex, takenCharacters: @escaping @MainActor () -> Set<Character>) {
        self.store = store
        self.index = index
        self.takenCharacters = takenCharacters
    }

    /// Loads the cached app list, rescanning when it's older than ten minutes.
    func refreshInstalledApps() async {
        installedApps = await index.apps()
    }

    func matches(for query: String) -> [InstalledApp] {
        Array(FuzzyMatcher.rank(installedApps, query: query, text: \.name).prefix(60))
    }

    /// Suggestions for an app, ignoring its own current key so "Suggest another" can offer it again.
    func suggestions(for binding: AppHotkeyBinding) -> [Character] {
        var taken = takenCharacters()
        if let own = KeyboardShortcuts.getShortcut(for: binding.shortcutName).flatMap(AppHotkeyKeys.character(of:)) {
            taken.remove(own)
        }
        return HotkeySuggester.suggestions(for: binding.name, taken: taken)
    }
}

struct AppHotkeysSettingsView: View {
    let model: AppHotkeysSettingsModel
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                if model.store.bindings.isEmpty {
                    Text("No apps yet. Add one to open it with a shortcut.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.store.bindings) { binding in
                    AppHotkeyRow(binding: binding) {
                        model.store.remove(bundleID: binding.bundleID)
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("The shortcut opens the app, or brings it to the front if it's already running.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Add App…", systemImage: "plus") { isAdding = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isAdding) {
            AddAppHotkeySheet(model: model) { isAdding = false }
        }
    }
}

private struct AppIcon: View {
    let url: URL?

    var body: some View {
        Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            ?? NSWorkspace.shared.icon(for: .application))
            .resizable()
            .frame(width: DesignTokens.Size.rowIcon, height: DesignTokens.Size.rowIcon)
    }
}

private struct AppHotkeyRow: View {
    let binding: AppHotkeyBinding
    let remove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID)
        HStack {
            AppIcon(url: url)
                .opacity(url == nil ? 0.4 : 1)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text(binding.name)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                if url == nil {
                    Text("Not found")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: binding.shortcutName)
            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove \(binding.name)")
        }
    }
}

/// Pick an app, then accept the suggested shortcut, ask for another, or record your own.
private struct AddAppHotkeySheet: View {
    let model: AppHotkeysSettingsModel
    let dismiss: () -> Void

    @State private var query = ""
    @State private var chosen: AppHotkeyBinding?
    @State private var chosenURL: URL?
    @State private var suggestions: [Character] = []
    @State private var suggestion: Character?
    @State private var hasRecorded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            if let chosen {
                suggestionStep(for: chosen)
            } else {
                searchStep
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .frame(width: 420, height: 420)
        .task { await model.refreshInstalledApps() }
    }

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("Add an App")
                .font(DesignTokens.Typography.heading)
            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
            List(model.matches(for: query)) { app in
                Button {
                    choose(app)
                } label: {
                    HStack {
                        AppIcon(url: app.url)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if model.installedApps.isEmpty {
                    ProgressView()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func suggestionStep(for binding: AppHotkeyBinding) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            HStack {
                AppIcon(url: chosenURL)
                Text(binding.name)
                    .font(DesignTokens.Typography.heading)
            }
            if let suggestion, let shortcut = AppHotkeyKeys.shortcut(for: suggestion) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                    Text("Suggested shortcut")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text(shortcut.description)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                }
                HStack {
                    Button("Accept") {
                        KeyboardShortcuts.setShortcut(shortcut, for: binding.shortcutName)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Suggest Another") {
                        self.suggestion = HotkeySuggester.next(after: suggestion, in: suggestions)
                    }
                    .disabled(suggestions.count < 2)
                }
            } else {
                Text("Every Ctrl+Opt+Cmd letter and digit is taken. Record a different shortcut below.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("Or record your own") {
                KeyboardShortcuts.Recorder(for: binding.shortcutName) { hasRecorded = $0 != nil }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    // Nothing was bound, so don't leave an empty row behind.
                    if !hasRecorded {
                        model.store.remove(bundleID: binding.bundleID)
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done", action: dismiss)
                    .disabled(!hasRecorded)
            }
        }
    }

    private func choose(_ app: InstalledApp) {
        let binding = model.store.add(bundleID: app.bundleID, name: app.name)
        chosen = binding
        chosenURL = app.url
        suggestions = model.suggestions(for: binding)
        suggestion = suggestions.first
        hasRecorded = KeyboardShortcuts.getShortcut(for: binding.shortcutName) != nil
    }
}
