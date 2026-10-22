import Foundation
import KeyboardShortcuts
import Testing
@testable import Cheese

struct ReservedShortcutsTests {
    @Test func bundledListLoadsAndReservesInvertColors() {
        let entries = ReservedShortcuts.bundled()
        #expect(!entries.isEmpty)
        #expect(ReservedShortcuts.takenCharacters(in: entries).contains("8"))
    }

    @Test func onlyExactlyCtrlOptCmdLettersAndDigitsCount() throws {
        let json = """
        [
          { "key": "k", "modifiers": ["command", "option", "control"], "owner": "A" },
          { "key": "J", "modifiers": ["control", "option", "command", "shift"], "owner": "B" },
          { "key": "L", "modifiers": ["control", "option"], "owner": "C" },
          { "key": "leftArrow", "modifiers": ["control", "option", "command"], "owner": "D" },
          { "key": ",", "modifiers": ["control", "option", "command"], "owner": "E" },
          { "key": "3", "modifiers": ["Control", "Option", "Command"], "owner": "F" }
        ]
        """
        let entries = try ReservedShortcuts.decode(Data(json.utf8))
        #expect(entries.count == 6)
        #expect(ReservedShortcuts.takenCharacters(in: entries) == ["K", "3"])
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) { try ReservedShortcuts.decode(Data("{".utf8)) }
    }
}

struct AppHotkeyKeysTests {
    @Test func roundTripsEveryLetterAndDigit() throws {
        for character in HotkeySuggester.letters + HotkeySuggester.digits {
            let shortcut = try #require(AppHotkeyKeys.shortcut(for: character))
            #expect(shortcut.modifiers == AppHotkeyKeys.modifiers)
            #expect(AppHotkeyKeys.character(of: shortcut) == character)
        }
    }

    @Test func otherModifierFamiliesDontCount() {
        let cheeseDefault = KeyboardShortcuts.Shortcut(.v, modifiers: [.control, .option])
        let withShift = KeyboardShortcuts.Shortcut(.v, modifiers: [.control, .option, .command, .shift])
        let arrow = KeyboardShortcuts.Shortcut(.leftArrow, modifiers: AppHotkeyKeys.modifiers)
        #expect(AppHotkeyKeys.takenCharacters(in: [cheeseDefault, withShift, arrow]).isEmpty)
        #expect(AppHotkeyKeys.shortcut(for: "!") == nil)
    }
}

@MainActor
struct AppHotkeyStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "AppHotkeyStoreTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? .standard
    }

    @Test func namesHaveNoDots() {
        let name = AppHotkeyStore.shortcutName(for: "com.figma.Desktop")
        #expect(name.rawValue == "app_com_figma_Desktop")
    }

    @Test func bindingsPersistByBundleIDWithoutDuplicates() {
        let defaults = makeDefaults()
        let store = AppHotkeyStore(defaults: defaults)
        store.add(bundleID: "com.figma.Desktop", name: "Figma")
        store.add(bundleID: "com.figma.Desktop", name: "Figma 2")
        store.add(bundleID: "com.apple.Safari", name: "Safari")
        #expect(store.bindings.map(\.bundleID) == ["com.figma.Desktop", "com.apple.Safari"])
        #expect(store.bindings.first?.name == "Figma")

        let reopened = AppHotkeyStore(defaults: defaults)
        #expect(reopened.bindings == store.bindings)

        reopened.remove(bundleID: "com.figma.Desktop")
        #expect(AppHotkeyStore(defaults: defaults).bindings.map(\.bundleID) == ["com.apple.Safari"])
    }

    @Test func onlyBindingsWithAKeyAreActiveAndRemovingClearsTheKey() {
        let store = AppHotkeyStore(defaults: makeDefaults())
        let bundleID = "com.example.cheese-tests-\(UUID().uuidString)"
        let binding = store.add(bundleID: bundleID, name: "Example")
        #expect(store.activeBindings.isEmpty)

        KeyboardShortcuts.setShortcut(AppHotkeyKeys.shortcut(for: "Q"), for: binding.shortcutName)
        #expect(store.activeBindings == [binding])

        store.remove(bundleID: bundleID)
        #expect(KeyboardShortcuts.getShortcut(for: binding.shortcutName) == nil)
    }
}

struct InstalledAppIndexTests {
    private func makeApp(named name: String, bundleID: String, in folder: URL) throws {
        let contents = folder.appending(path: "\(name).app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    @Test func findsAppsAndVendorFoldersOnceSortedByName() async throws {
        let root = makeTemporaryDirectory()
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let utilities = applications.appending(path: "Utilities", directoryHint: .isDirectory)
        let vendor = applications.appending(path: "Microsoft Office", directoryHint: .isDirectory)
        try makeApp(named: "Zed", bundleID: "dev.zed.Zed", in: applications)
        try makeApp(named: "Figma", bundleID: "com.figma.Desktop", in: applications)
        try makeApp(named: "Microsoft Word", bundleID: "com.microsoft.Word", in: vendor)
        try makeApp(named: "Terminal", bundleID: "com.apple.Terminal", in: utilities)
        // The same app in a second folder is listed once.
        try makeApp(named: "Figma Copy", bundleID: "com.figma.Desktop", in: utilities)

        let apps = InstalledAppIndex.scan([applications, utilities])
        #expect(apps.map(\.name) == ["Figma", "Microsoft Word", "Terminal", "Zed"])
        #expect(apps.first?.bundleID == "com.figma.Desktop")

        // Utilities is a plain subfolder of Applications, so its apps are found too.
        let index = InstalledAppIndex(folders: [applications])
        #expect(await index.apps().count == 4)
        try makeApp(named: "Late", bundleID: "com.example.late", in: applications)
        // Cached until it's older than the max age.
        #expect(await index.apps().count == 4)
        #expect(await index.apps(maxAge: .zero).count == 5)
    }
}
