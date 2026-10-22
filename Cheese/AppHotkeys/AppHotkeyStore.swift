import AppKit
import KeyboardShortcuts
import os

/// An app with a hotkey. Stored by bundle ID so renamed or moved apps keep working; the name is
/// only for showing an uninstalled app in Settings.
struct AppHotkeyBinding: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String

    var id: String { bundleID }

    /// `KeyboardShortcuts` stores the key itself under this name. Names can't contain dots.
    var shortcutName: KeyboardShortcuts.Name {
        AppHotkeyStore.shortcutName(for: bundleID)
    }
}

/// The list of apps with hotkeys, kept in UserDefaults. The shortcuts themselves live in
/// `KeyboardShortcuts`, under `app_<bundle ID>` names.
@MainActor
@Observable
final class AppHotkeyStore {
    static let defaultsKey = "appHotkeyBindings"

    private(set) var bindings: [AppHotkeyBinding]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = Self.load(from: defaults)
    }

    nonisolated static func shortcutName(for bundleID: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("app_" + bundleID.replacing(".", with: "_"))
    }

    /// Bindings that have a shortcut set.
    var activeBindings: [AppHotkeyBinding] {
        bindings.filter { KeyboardShortcuts.getShortcut(for: $0.shortcutName) != nil }
    }

    /// Adds the app (once) and returns its binding.
    @discardableResult
    func add(bundleID: String, name: String) -> AppHotkeyBinding {
        if let existing = bindings.first(where: { $0.bundleID == bundleID }) {
            return existing
        }
        let binding = AppHotkeyBinding(bundleID: bundleID, name: name)
        bindings.append(binding)
        save()
        return binding
    }

    /// Removes the app and clears its shortcut.
    func remove(bundleID: String) {
        guard let index = bindings.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let binding = bindings.remove(at: index)
        KeyboardShortcuts.setShortcut(nil, for: binding.shortcutName)
        save()
    }

    func reload() {
        let stored = Self.load(from: defaults)
        if stored != bindings {
            bindings = stored
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(bindings), forKey: Self.defaultsKey)
        } catch {
            Logger.appHotkeys.error("Couldn't save app hotkeys: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [AppHotkeyBinding] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([AppHotkeyBinding].self, from: data)) ?? []
    }
}

/// Opens an app from its hotkey: launches it if it isn't running, otherwise brings it to the front.
@MainActor
enum AppLauncher {
    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func launchOrActivate(_ binding: AppHotkeyBinding) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) else {
            Toast.show("\(binding.name) isn't installed", systemImage: "questionmark.app")
            return
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: binding.bundleID) where app.isHidden {
            app.unhide()
        }
        // Launch Services activates reliably from the background, where NSRunningApplication.activate()
        // can be refused under cooperative activation. For a running app this only brings it forward.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Logger.appHotkeys.error("Couldn't open \(binding.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
