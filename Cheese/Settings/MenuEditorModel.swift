import Foundation
import Observation

/// What the editor shows for an action: from the action registry, so titles, symbols and shortcuts
/// match the menu.
struct MenuEditorItemInfo: Equatable, Sendable {
    var title: String
    var symbol: String
    var shortcut: String?
    /// Its module is off in General → Modules, so it won't show whatever the customization says.
    var moduleOff: Bool
}

/// One row of the editor's tree.
struct MenuEditorRow: Identifiable, Equatable, Sendable {
    var id: String
    var parent: String
    var title: String
    var symbol: String
    var shortcut: String?
    var isHidden: Bool
    var isNew: Bool
    var moduleOff: Bool
    /// Nil for an item; the submenu's or section's rows otherwise.
    var children: [MenuEditorRow]?
}

/// Builds the editor's tree and turns edits into a new customization. Pure.
enum MenuEditorTree {
    static func rows(
        body: [MenuLayout.Node] = MenuLayout.body, customization: MenuCustomization, newIDs: Set<String>,
        info: (ActionID) -> MenuEditorItemInfo?
    ) -> [MenuEditorRow] {
        let hidden = customization.effectiveHidden(body: body)
        let arranged = MenuLayout.arranged(body, parent: MenuCustomization.root, order: customization.effectiveOrder)
        return rows(arranged, parent: MenuCustomization.root, hidden: hidden, newIDs: newIDs, info: info)
    }

    private static func rows(
        _ nodes: [MenuLayout.Node], parent: String, hidden: Set<String>, newIDs: Set<String>, info: (ActionID) -> MenuEditorItemInfo?
    ) -> [MenuEditorRow] {
        nodes.compactMap { node -> MenuEditorRow? in
            switch node {
            case let .action(actionID, _, _):
                let details = info(actionID)
                return MenuEditorRow(
                    id: actionID.rawValue, parent: parent, title: details?.title ?? actionID.rawValue, symbol: details?.symbol ?? "circle",
                    shortcut: details?.shortcut, isHidden: hidden.contains(actionID.rawValue), isNew: newIDs.contains(actionID.rawValue),
                    moduleOff: details?.moduleOff ?? false, children: nil
                )
            case let .submenu(id, title, symbol, children, _):
                let childRows = rows(children, parent: id, hidden: hidden, newIDs: newIDs, info: info)
                return MenuEditorRow(
                    id: id, parent: parent, title: title, symbol: symbol, shortcut: nil, isHidden: hidden.contains(id), isNew: newIDs.contains(id),
                    moduleOff: !childRows.isEmpty && childRows.allSatisfy(\.moduleOff), children: childRows
                )
            case let .section(id, title, children):
                let childRows = rows(children, parent: id, hidden: hidden, newIDs: newIDs, info: info)
                return MenuEditorRow(
                    id: id, parent: parent, title: title, symbol: "rectangle.split.3x1", shortcut: nil, isHidden: hidden.contains(id),
                    isNew: newIDs.contains(id), moduleOff: !childRows.isEmpty && childRows.allSatisfy(\.moduleOff), children: childRows
                )
            case .alternate, .header, .separator:
                return nil
            }
        }
    }

    /// The IDs under `parent` in the current order.
    static func childIDs(of parent: String, body: [MenuLayout.Node] = MenuLayout.body, customization: MenuCustomization) -> [String] {
        let arranged = MenuLayout.arranged(body, parent: MenuCustomization.root, order: customization.effectiveOrder)
        if parent == MenuCustomization.root {
            return arranged.compactMap(\.id)
        }
        func find(_ nodes: [MenuLayout.Node]) -> [MenuLayout.Node]? {
            for node in nodes {
                if node.id == parent { return node.children }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(arranged)?.compactMap(\.id) ?? []
    }
}

extension MenuCustomization {
    /// Custom, starting from what the current preset shows, so the first edit changes only itself.
    func materialized(body: [MenuLayout.Node] = MenuLayout.body) -> MenuCustomization {
        guard preset != .custom else { return self }
        var copy = self
        copy.hidden = effectiveHidden(body: body)
        copy.order = effectiveOrder
        copy.preset = .custom
        return copy
    }

    func togglingHidden(_ id: String, body: [MenuLayout.Node] = MenuLayout.body) -> MenuCustomization {
        guard !Self.locked.contains(id) else { return self }
        var copy = materialized(body: body)
        if copy.hidden.contains(id) {
            copy.hidden.remove(id)
        } else {
            copy.hidden.insert(id)
        }
        return copy
    }

    /// `id` moved to `index` among its siblings under `parent` (never into another parent).
    func moving(_ id: String, in parent: String, to index: Int, body: [MenuLayout.Node] = MenuLayout.body) -> MenuCustomization {
        var siblings = MenuEditorTree.childIDs(of: parent, body: body, customization: self)
        guard let from = siblings.firstIndex(of: id) else { return self }
        var copy = materialized(body: body)
        siblings.remove(at: from)
        siblings.insert(id, at: max(0, min(index, siblings.count)))
        copy.order[parent] = siblings
        return copy
    }

    /// Back to Full; what's been seen stays seen.
    func reset() -> MenuCustomization {
        MenuCustomization(seen: seen)
    }
}

/// Hooks the Menu tab needs from the rest of the app, filled in once the action registry and the
/// menu bar exist (Settings is built before them).
@MainActor
final class MenuEditorContext {
    var info: (ActionID) -> MenuEditorItemInfo? = { _ in nil }
    var showMenu: () -> Void = {}
    var openModules: () -> Void = {}
}

/// The Menu tab's state. Every change is saved at once; the menu rebuilds each time it opens.
@MainActor
@Observable
final class MenuEditorModel {
    private(set) var customization: MenuCustomization
    private(set) var rows: [MenuEditorRow] = []
    /// Items that came with an update since the tab was last opened.
    private(set) var newIDs: Set<String> = []
    var selection: String?
    private let defaults: UserDefaults
    let context: MenuEditorContext

    init(context: MenuEditorContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
        customization = MenuCustomization.load(from: defaults)
    }

    /// Opening the tab: whatever wasn't seen before is "New" for this visit, then everything is seen.
    func opened() {
        customization = MenuCustomization.load(from: defaults)
        let all = Set(MenuLayout.customizableIDs(in: MenuLayout.standard))
        newIDs = customization.seen.isEmpty ? [] : all.subtracting(customization.seen)
        customization.seen = all
        customization.save(to: defaults)
        refresh()
    }

    func refresh() {
        rows = MenuEditorTree.rows(customization: customization, newIDs: newIDs, info: context.info)
    }

    func setPreset(_ preset: MenuCustomization.Preset) {
        apply(preset == .custom ? customization.materialized() : {
            var copy = customization
            copy.preset = preset
            return copy
        }())
    }

    func toggle(_ id: String) {
        apply(customization.togglingHidden(id))
    }

    func isHidden(_ id: String) -> Bool {
        customization.effectiveHidden().contains(id)
    }

    func move(_ id: String, in parent: String, to index: Int) {
        apply(customization.moving(id, in: parent, to: index))
    }

    /// Moves the selected row one place up (-1) or down (+1); returns what to announce.
    @discardableResult
    func moveSelection(by offset: Int) -> String? {
        guard let id = selection, let row = row(id) else { return nil }
        let siblings = MenuEditorTree.childIDs(of: row.parent, customization: customization)
        guard let index = siblings.firstIndex(of: id), siblings.indices.contains(index + offset) else { return nil }
        move(id, in: row.parent, to: index + offset)
        return "Moved \(row.title) \(offset < 0 ? "up" : "down"), \(index + offset + 1) of \(siblings.count)"
    }

    func canMoveSelection(by offset: Int) -> Bool {
        guard let id = selection, let row = row(id) else { return false }
        let siblings = MenuEditorTree.childIDs(of: row.parent, customization: customization)
        guard let index = siblings.firstIndex(of: id) else { return false }
        return siblings.indices.contains(index + offset)
    }

    func reset() {
        apply(customization.reset())
    }

    func row(_ id: String) -> MenuEditorRow? {
        func find(_ rows: [MenuEditorRow]) -> MenuEditorRow? {
            for row in rows {
                if row.id == id { return row }
                if let found = find(row.children ?? []) { return found }
            }
            return nil
        }
        return find(rows)
    }

    private func apply(_ new: MenuCustomization) {
        customization = new
        customization.save(to: defaults)
        refresh()
    }
}
