import Foundation
import Testing
@testable import Cheese

struct MenuCustomizationTests {
    private typealias Node = MenuLayout.Node

    /// A small layout in the same shape as the real one: a body, then the real footer.
    private let body: [Node] = [
        .action(.openHistory),
        .submenu(id: "capture", title: "Capture", symbol: "c", children: [
            .action(.captureRegion), .action(.captureWindow), .separator, .action(.ocrRegion),
        ]),
        .action(.drawOnScreen),
        .submenu(id: "files", title: "Files", symbol: "f", children: [
            .section(id: "files.pdf", title: "PDF", children: [.action(.files(.mergeFiles)), .action(.files(.splitPDF))]),
            .section(id: "files.images", title: "Images", children: [.action(.files(.resizeImage))]),
        ]),
        .action(.showShare),
        .action(.toggleShelf),
    ]

    private var standard: [Node] { body + MenuLayout.footer }

    private func ids(_ nodes: [Node]) -> [String] {
        nodes.map { node in
            switch node {
            case let .action(id, _, _): id.rawValue
            case let .alternate(id): "alt:\(id.rawValue)"
            case let .submenu(id, _, _, _, _), let .section(id, _, _): id
            case let .header(title): "#\(title)"
            case .separator: "—"
            }
        }
    }

    private func children(_ id: String, in nodes: [Node]) -> [Node] {
        for node in nodes {
            if node.id == id { return node.children }
            let found = children(id, in: node.children)
            if !found.isEmpty { return found }
        }
        return []
    }

    private func custom(order: [String: [String]] = [:], hidden: Set<String> = []) -> MenuCustomization {
        MenuCustomization(preset: .custom, order: order, hidden: hidden)
    }

    private let footerIDs = ["—", "clearHistory", "alt:clearAll", "—", "#\(Brand.versionTitle)", "checkForUpdates", "installUpdate", "editMenu", "openSettings", "quit"]

    @Test func fullIsTheStandardLayout() {
        #expect(MenuLayout.customized(standard, with: MenuCustomization()) == standard)
        #expect(MenuLayout.customized(MenuLayout.standard, with: MenuCustomization()) == MenuLayout.standard)
    }

    @Test func reordersTopLevelAndInsideSubmenusKeepingSeparatorSlots() {
        let customization = custom(order: [
            MenuCustomization.root: ["toggleShelf", "openHistory", "capture", "drawOnScreen", "files", "showShare"],
            "capture": ["ocrRegion", "captureRegion", "captureWindow"],
        ])
        let result = MenuLayout.customized(standard, with: customization)
        #expect(Array(ids(result).prefix(6)) == ["toggleShelf", "openHistory", "capture", "drawOnScreen", "files", "showShare"])
        // The separator stays in its slot; the items fill the others in the user's order.
        #expect(ids(children("capture", in: result)) == ["ocrRegion", "captureRegion", "—", "captureWindow"])
        #expect(Array(ids(result).suffix(footerIDs.count)) == footerIDs)
    }

    @Test func sectionsReorderInsideFilesAndToolsInsideTheirSection() {
        let customization = custom(order: ["files": ["files.images", "files.pdf"], "files.pdf": ["files.splitPDF", "files.mergePDFs"]])
        let result = MenuLayout.customized(standard, with: customization)
        #expect(ids(children("files", in: result)) == ["files.images", "files.pdf"])
        #expect(ids(children("files.pdf", in: result)) == ["files.splitPDF", "files.mergePDFs"])
        // Drawn as header sections; the leading separator is tidied away.
        let visible = MenuLayout.visible(result) { _ in true }
        #expect(ids(children("files", in: visible)) == ["#Images", "files.resizeImage", "—", "#PDF", "files.splitPDF", "files.mergePDFs"])
    }

    @Test func hidesItemsAndWholeSubmenus() {
        let result = MenuLayout.customized(standard, with: custom(hidden: ["drawOnScreen", "files", "captureWindow"]))
        #expect(!ids(result).contains("drawOnScreen") && !ids(result).contains("files"))
        #expect(ids(children("capture", in: result)) == ["captureRegion", "—", "ocrRegion"])
    }

    @Test func aSubmenuLeftWithOneItemCollapses() {
        let result = MenuLayout.customized(standard, with: custom(hidden: ["captureWindow", "ocrRegion"]))
        let visible = MenuLayout.visible(result) { _ in true }
        #expect(ids(visible).contains("captureRegion"))
        #expect(!ids(visible).contains("capture"))
        guard case let .action(_, _, fullTitle) = visible[1] else {
            Issue.record("not collapsed")
            return
        }
        #expect(fullTitle)
    }

    @Test func newItemsShowAtTheirDefaultSpotAndRemovedOnesDrop() {
        // Saved before drawOnScreen and captureWindow existed, and with an item that's since gone.
        let customization = custom(order: [
            MenuCustomization.root: ["toggleShelf", "openHistory", "capture", "files", "showShare", "removedThing"],
            "capture": ["ocrRegion", "captureRegion"],
        ])
        let result = MenuLayout.customized(standard, with: customization)
        // drawOnScreen followed capture by default, so it lands right after capture, visible.
        #expect(Array(ids(result).prefix(6)) == ["toggleShelf", "openHistory", "capture", "drawOnScreen", "files", "showShare"])
        #expect(!ids(result).contains("removedThing"))
        #expect(ids(children("capture", in: result)) == ["ocrRegion", "captureRegion", "—", "captureWindow"])
        #expect(MenuLayout.mergedOrder(defaultIDs: ["a", "b", "c"], stored: ["c"]) == ["a", "b", "c"])
        #expect(MenuLayout.mergedOrder(defaultIDs: ["a", "b", "c", "d"], stored: ["c", "a"]) == ["c", "d", "a", "b"])
    }

    @Test func minimalKeepsTheEssentialsAndTheLockedFooter() {
        let result = MenuLayout.visible(MenuLayout.customized(standard, with: MenuCustomization(preset: .minimal))) { _ in true }
        #expect(ids(result) == ["openHistory", "capture", "showShare", "toggleShelf", "—", "#\(Brand.versionTitle)", "openSettings", "quit"])
        // Items added later stay hidden under Minimal.
        let later = MenuCustomization(preset: .minimal).effectiveHidden(body: body + [.action(.showClipboardQR)])
        #expect(later.contains("showClipboardQR"))
        // The real menu too.
        let real = MenuLayout.visible(MenuLayout.customized(MenuLayout.standard, with: MenuCustomization(preset: .minimal))) { _ in true }
        #expect(ids(real).filter { !$0.hasPrefix("#") && $0 != "—" } == ["openHistory", "capture", "showShare", "toggleShelf", "openSettings", "quit"])
    }

    @Test func theFooterStaysAtTheBottomAndSettingsAndQuitCantBeHidden() {
        let customization = custom(
            order: [MenuCustomization.root: ["quit", "openSettings", "clearHistory", "openHistory"]],
            hidden: ["openSettings", "quit", "checkForUpdates", "installUpdate", "editMenu"]
        )
        let result = MenuLayout.customized(standard, with: customization)
        #expect(Array(ids(result).suffix(7)) == ["—", "clearHistory", "alt:clearAll", "—", "#\(Brand.versionTitle)", "openSettings", "quit"])
        #expect(ids(result).first == "openHistory")
        #expect(customization.togglingHidden("quit") == customization)
    }

    @Test func alternatesGoWithTheirPrimary() {
        let hidden = MenuLayout.customized(standard, with: custom(hidden: ["clearHistory"]))
        #expect(!ids(hidden).contains("alt:clearAll") && !ids(hidden).contains("clearAll"))
        // Unavailable (not hidden) primaries still turn their alternate into a plain item.
        let visible = MenuLayout.visible(MenuLayout.customized(standard, with: MenuCustomization())) { $0 != .clearHistory }
        #expect(ids(visible).contains("clearAll"))
    }

    @Test func modulesOffWinOverTheCustomization() {
        let customization = custom(order: [MenuCustomization.root: ["drawOnScreen", "openHistory"]])
        let visible = MenuLayout.visible(MenuLayout.customized(standard, with: customization)) { $0 != .drawOnScreen }
        #expect(!ids(visible).contains("drawOnScreen"))
    }

    @Test func everySubmenuHasAStableUniqueID() {
        let allIDs = MenuLayout.customizableIDs(in: MenuLayout.standard)
        #expect(Set(allIDs).count == allIDs.count, "\(Dictionary(grouping: allIDs, by: { $0 }).filter { $0.value.count > 1 }.keys)")
        for id in ["capture", "afterCapture", "files", "files.pdf", "files.convert", "files.images", "windows", "tools", "terminalTraceMenu", "hush", "mode", "caffeinate"] {
            #expect(allIDs.contains(id), "\(id)")
        }
        #expect(allIDs.contains("addToPhotos") && allIDs.contains("files.mergePDFs") && allIDs.contains("editMenu"))
    }

    @Test func roundTripsAsJSONAndDefaultsToFull() throws {
        let suite = "MenuCustomizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MenuCustomization.load(from: defaults) == MenuCustomization())
        let customization = MenuCustomization(preset: .custom, order: ["root": ["a"]], hidden: ["b"], seen: ["a", "b"])
        customization.save(to: defaults)
        #expect(MenuCustomization.load(from: defaults) == customization)
        defaults.set(Data("nonsense".utf8), forKey: PreferenceKey.menuCustomization)
        #expect(MenuCustomization.load(from: defaults) == MenuCustomization())
    }
}

struct MenuEditorTests {
    private let body: [MenuLayout.Node] = [
        .action(.openHistory),
        .submenu(id: "capture", title: "Capture", symbol: "c", children: [.action(.captureRegion), .action(.captureWindow)]),
        .action(.showShare),
    ]

    private func info(_ id: ActionID) -> MenuEditorItemInfo? {
        MenuEditorItemInfo(title: id.rawValue.capitalized, symbol: "circle", shortcut: id == .openHistory ? "⌃⌥V" : nil, moduleOff: id == .showShare)
    }

    @Test func rowsShowTheTreeHiddenNewAndModuleOff() {
        let customization = MenuCustomization(preset: .custom, hidden: ["captureWindow"])
        let rows = MenuEditorTree.rows(body: body, customization: customization, newIDs: ["showShare"], info: info)
        #expect(rows.map(\.id) == ["openHistory", "capture", "showShare"])
        #expect(rows[0].shortcut == "⌃⌥V")
        #expect(rows[1].children?.map(\.id) == ["captureRegion", "captureWindow"])
        #expect(rows[1].children?.last?.isHidden == true)
        #expect(rows[1].children?.first?.parent == "capture")
        #expect(rows[2].isNew && rows[2].moduleOff)
    }

    @Test func editsTurnAPresetIntoCustomAndMoveWithinTheParent() {
        let minimal = MenuCustomization(preset: .minimal)
        let shown = minimal.togglingHidden("drawOnScreen")
        #expect(shown.preset == .custom)
        #expect(!shown.hidden.contains("drawOnScreen") && shown.hidden.contains("windows"))

        let moved = MenuCustomization().moving("showShare", in: MenuCustomization.root, to: 0, body: body)
        #expect(moved.preset == .custom)
        #expect(MenuEditorTree.childIDs(of: MenuCustomization.root, body: body, customization: moved) == ["showShare", "openHistory", "capture"])
        let inside = moved.moving("captureWindow", in: "capture", to: 0, body: body)
        #expect(MenuEditorTree.childIDs(of: "capture", body: body, customization: inside) == ["captureWindow", "captureRegion"])
        // An item can't move into another parent.
        #expect(inside.moving("captureWindow", in: MenuCustomization.root, to: 0, body: body) == inside)

        let reset = MenuCustomization(preset: .custom, order: ["root": ["x"]], hidden: ["y"], seen: ["z"]).reset()
        #expect(reset == MenuCustomization(seen: ["z"]))
    }

    @MainActor
    @Test func openingTheTabMarksNewItemsOnceAndMovesAreAnnounced() throws {
        let suite = "MenuEditorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = MenuEditorContext()
        context.info = info
        // First visit ever: nothing is "New".
        let first = MenuEditorModel(context: context, defaults: defaults)
        first.opened()
        #expect(first.rows.allSatisfy { !$0.isNew })
        // An update adds Add to Photos: the next visit marks it, the one after doesn't.
        var stored = MenuCustomization.load(from: defaults)
        stored.seen.remove("addToPhotos")
        stored.save(to: defaults)
        let second = MenuEditorModel(context: context, defaults: defaults)
        second.opened()
        #expect(second.newIDs == ["addToPhotos"])
        let third = MenuEditorModel(context: context, defaults: defaults)
        third.opened()
        #expect(third.newIDs.isEmpty)

        third.selection = "captureWindow"
        #expect(third.canMoveSelection(by: -1))
        #expect(third.moveSelection(by: -1) == "Moved Capturewindow up, 1 of 9")
        #expect(MenuCustomization.load(from: defaults).order["capture"].map { Array($0.prefix(2)) } == ["captureWindow", "captureRegion"])
        #expect(!third.canMoveSelection(by: -1))
    }
}
