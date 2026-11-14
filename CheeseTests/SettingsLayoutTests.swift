import AppKit
import SwiftUI
import Testing
@testable import Cheese

/// Every Settings tab must fit the fixed window. A tab whose minimum height is taller than the window
/// stretches the sidebar split view past it and the whole window shows up blank (the Menu tab did).
@MainActor
struct SettingsLayoutTests {
    @Test func everyTabFitsTheWindow() async throws {
        let navigation = SettingsNavigation()
        let dependencies = SettingsDependencies(
            permissions: SystemPermissions(),
            openPermissionSettings: { _ in },
            supportedOCRLanguages: { [] },
            showWelcome: {},
            appHotkeys: AppHotkeysSettingsModel(store: AppHotkeyStore(defaults: UserDefaults(suiteName: "SettingsLayoutTests") ?? .standard), index: InstalledAppIndex(folders: [])) { [] },
            files: FilesSettingsModel(),
            caffeinate: CaffeinateController(),
            hush: HushController(),
            updates: UpdateService.shared,
            menuEditor: MenuEditorContext()
        )
        let host = NSHostingController(rootView: SettingsView(dependencies: dependencies, navigation: navigation))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.orderFrontRegardless()
        defer { window.close() }

        for tab in SettingsTab.allCases {
            navigation.tab = tab
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutSubtreeIfNeeded()
            let split = try #require(Self.firstSplitView(in: host.view), "no split view on \(tab)")
            #expect(split.frame.height <= host.view.bounds.height + 1, "\(tab) is \(split.frame.height) pt tall")
        }
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }
}
