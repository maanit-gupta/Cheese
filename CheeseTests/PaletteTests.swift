import Foundation
import Testing
@testable import Cheese

private func entry(_ title: String, module: String = "Cheese") -> PaletteEntry {
    PaletteEntry(id: ActionID(rawValue: title), title: title, symbol: "star", moduleName: module, shortcut: nil)
}

private func titles(_ entries: [PaletteEntry]) -> [String] {
    entries.map(\.title)
}

struct PaletteRankerTests {
    private let entries = [
        entry("Snap Left Half", module: "Window Snapping"),
        entry("Capture Region", module: "Screenshots"),
        entry("Clear History", module: "Clipboard"),
        entry("Show Clipboard as QR", module: "QR"),
        entry("Settings: General"),
        entry("Capture Window", module: "Screenshots"),
    ]

    @Test func emptyQueryIsAlphabeticalWithoutHistory() {
        #expect(titles(PaletteRanker.rank(entries, query: "", recent: [])) == [
            "Capture Region", "Capture Window", "Clear History", "Settings: General", "Show Clipboard as QR", "Snap Left Half",
        ])
    }

    @Test func emptyQueryShowsRecentFirstThenTheRestAlphabetically() {
        let recent = [ActionID(rawValue: "Snap Left Half"), ActionID(rawValue: "Gone"), ActionID(rawValue: "Clear History")]
        #expect(titles(PaletteRanker.rank(entries, query: " ", recent: recent)) == [
            "Snap Left Half", "Clear History", "Capture Region", "Capture Window", "Settings: General", "Show Clipboard as QR",
        ])
    }

    @Test func atMostEightRecentLeadTheList() {
        let many = (1...12).map { entry(String(format: "Action %02d", $0)) }
        let recent = many.reversed().map(\.id)
        let ranked = titles(PaletteRanker.rank(many, query: "", recent: recent))
        #expect(Array(ranked.prefix(8)) == (5...12).reversed().map { String(format: "Action %02d", $0) })
        #expect(Array(ranked.suffix(4)) == ["Action 01", "Action 02", "Action 03", "Action 04"])
    }

    @Test func queryFiltersFuzzily() {
        #expect(titles(PaletteRanker.rank(entries, query: "capture", recent: [])) == ["Capture Region", "Capture Window"])
        #expect(titles(PaletteRanker.rank(entries, query: "snlf", recent: [])) == ["Snap Left Half"])
        #expect(PaletteRanker.rank(entries, query: "zzzz", recent: []).isEmpty)
    }

    @Test func moduleNamesMatchToo() {
        #expect(titles(PaletteRanker.rank(entries, query: "clipboard", recent: [])).contains("Clear History"))
    }

    @Test func recencyBoostsEqualMatches() {
        let ranked = PaletteRanker.rank(entries, query: "capture", recent: [ActionID(rawValue: "Capture Window")])
        #expect(titles(ranked) == ["Capture Window", "Capture Region"])
    }

    @Test func recencyDoesNotBeatAMuchBetterMatch() {
        // A real substring match outranks a fuzzy one even if the fuzzy one was just used.
        let ranked = PaletteRanker.rank(entries, query: "region", recent: [ActionID(rawValue: "Settings: General")])
        #expect(ranked.first?.title == "Capture Region")
    }
}

struct RecencyStoreTests {
    @Test func mostRecentFirstWithoutDuplicatesAndCapped() {
        let defaults = UserDefaults(suiteName: "RecencyStoreTests-\(UUID().uuidString)") ?? .standard
        let store = RecencyStore(defaults: defaults)
        #expect(store.recent.isEmpty)

        store.record(.captureRegion)
        store.record(.snapLeft)
        store.record(.captureRegion)
        #expect(store.recent == [.captureRegion, .snapLeft])

        for index in 0..<30 {
            store.record(ActionID(rawValue: "a\(index)"))
        }
        #expect(store.recent.count == RecencyStore.limit)
        #expect(store.recent.first == ActionID(rawValue: "a29"))
    }
}

@MainActor
struct PaletteViewModelTests {
    private func makeModel() -> PaletteViewModel {
        PaletteViewModel(recency: RecencyStore(defaults: UserDefaults(suiteName: "PaletteVM-\(UUID().uuidString)") ?? .standard))
    }

    @Test func selectionMovesWithinResultsAndResetsOnTyping() {
        let model = makeModel()
        model.reset(entries: [entry("Alpha"), entry("Beta"), entry("Gamma")])
        model.moveSelection(by: -1)
        #expect(model.selection == 0)
        model.moveSelection(by: 5)
        #expect(model.selectedEntry?.title == "Gamma")

        model.query = "be"
        #expect(model.selection == 0)
        #expect(model.selectedEntry?.title == "Beta")
    }

    @Test func runningRecordsRecencyAndReportsTheAction() {
        let model = makeModel()
        var ran: [ActionID] = []
        model.onRun = { ran.append($0) }
        model.reset(entries: [entry("Alpha"), entry("Beta")])
        model.moveSelection(by: 1)
        model.runSelected()
        #expect(ran == [ActionID(rawValue: "Beta")])

        // Next time, the recently used action leads the empty query.
        model.reset(entries: [entry("Alpha"), entry("Beta")])
        #expect(model.results.first?.title == "Beta")
    }

    @Test func noResultsRunsNothing() {
        let model = makeModel()
        var ran = false
        model.onRun = { _ in ran = true }
        model.reset(entries: [entry("Alpha")])
        model.query = "zzz"
        model.runSelected()
        #expect(!ran)
    }
}

@MainActor
struct PaletteEntriesTests {
    @Test func listsActionsWithModuleNamesButNotItself() {
        let actions = [
            CheeseAction(id: .commandPalette, title: "Command Palette", symbol: "command", module: .commandPalette) { _ in },
            CheeseAction(id: .captureRegion, title: "Capture Region", symbol: "crop", module: .screenshots, shortcut: .captureRegion) { _ in },
            CheeseAction(id: .openSettings, title: "Settings…", symbol: "gearshape", module: nil) { _ in },
        ]
        let entries = CommandPaletteModule.entries(from: actions)
        #expect(entries.map(\.id) == [.captureRegion, .openSettings])
        #expect(entries.map(\.moduleName) == ["Screenshots", "Cheese"])
        #expect(entries.last?.shortcut == nil)
    }

    @Test func disabledModulesNeverReachThePalette() {
        let screenshots = CheeseAction(id: .captureRegion, title: "Capture Region", symbol: "crop", module: .screenshots) { _ in }
        let manager = ModuleManager(modules: []) { _ in false }
        let registry = ActionRegistry(appActions: [screenshots], moduleManager: manager, permissions: SystemPermissions()) { _, _ in }
        // The action's module isn't running, so it isn't available and the palette doesn't list it.
        #expect(CommandPaletteModule.entries(from: registry.availableActions).isEmpty)
    }
}
