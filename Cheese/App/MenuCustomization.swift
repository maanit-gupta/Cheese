import Foundation

/// How the user arranged the menu bar menu (Settings → Menu): a preset, or their own order and
/// hidden items. Stored as JSON in UserDefaults. IDs are `MenuLayout.Node.id`s: an action's
/// `ActionID` raw value or a submenu's or section's own ID, never text the user sees.
struct MenuCustomization: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Everything, in Cheese's order.
        case full
        /// Clipboard History, the Capture submenu, Share and Shelf, then the locked footer.
        case minimal
        /// The user's own order and hidden items: set as soon as they change anything.
        case custom

        var id: Self { self }
        var title: String {
            switch self {
            case .full: "Full"
            case .minimal: "Minimal"
            case .custom: "Custom"
            }
        }
    }

    var preset = Preset.full
    /// Each parent's children in the user's order; the top level is `MenuCustomization.root`.
    var order: [String: [String]] = [:]
    var hidden: Set<String> = []
    /// Items the user has seen in the editor. Others are marked "New" there until it's opened again.
    var seen: Set<String> = []

    static let root = "root"
    /// What Minimal keeps showing (besides the locked footer).
    static let minimalItems: Set<String> = [ActionID.openHistory.rawValue, "capture", ActionID.showShare.rawValue, ActionID.toggleShelf.rawValue]
    /// Never hidden, whatever's stored.
    static let locked: Set<String> = [ActionID.openSettings.rawValue, ActionID.quit.rawValue]

    /// What's hidden: nothing for Full, everything but the essentials for Minimal (items added
    /// later included), the user's choice for Custom.
    func effectiveHidden(body: [MenuLayout.Node] = MenuLayout.body) -> Set<String> {
        switch preset {
        case .full:
            return []
        case .minimal:
            let topLevel = body.compactMap(\.id).filter { !Self.minimalItems.contains($0) }
            return Set(topLevel + MenuLayout.hideableFooter.map(\.rawValue))
        case .custom:
            return hidden.subtracting(Self.locked)
        }
    }

    /// The stored order, which only Custom uses.
    var effectiveOrder: [String: [String]] {
        preset == .custom ? order : [:]
    }

    static func load(from defaults: UserDefaults) -> MenuCustomization {
        guard let data = defaults.data(forKey: PreferenceKey.menuCustomization),
              let decoded = try? JSONDecoder().decode(MenuCustomization.self, from: data)
        else { return MenuCustomization() }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: PreferenceKey.menuCustomization)
        }
    }
}

extension MenuLayout {
    /// The layout as the user arranged it: each parent's children in their order (items they've never
    /// ordered, like ones added in an update, at their default spot next to their nearest neighbour;
    /// items that no longer exist dropped), then without hidden items, except Settings…, Quit and the
    /// version header. `visible(_:isAvailable:)` then tidies it as usual.
    static func customized(_ standard: [Node], with customization: MenuCustomization) -> [Node] {
        let footerStart = standard.count - footer.count
        let isStandard = footerStart >= 0 && Array(standard[footerStart...]) == footer
        let body = isStandard ? Array(standard[..<footerStart]) : standard
        let tail = isStandard ? footer : []
        let hidden = customization.effectiveHidden(body: body)
        let ordered = arranged(body, parent: MenuCustomization.root, order: customization.effectiveOrder)
        return removingHidden(ordered, hidden: hidden) + removingHidden(tail, hidden: hidden.intersection(hideableFooter.map(\.rawValue)))
    }

    /// `nodes` (and every submenu and section under them) in the stored order, hidden items kept.
    static func arranged(_ nodes: [Node], parent: String, order: [String: [String]]) -> [Node] {
        let nodes = nodes.map { node -> Node in
            switch node {
            case let .submenu(id, title, symbol, children, collapses):
                .submenu(id: id, title: title, symbol: symbol, children: arranged(children, parent: id, order: order), collapses: collapses)
            case let .section(id, title, children):
                .section(id: id, title: title, children: arranged(children, parent: id, order: order))
            default:
                node
            }
        }
        guard let stored = order[parent] else { return nodes }
        // Units: an item with any alternates right after it. Separators and headers keep their slots.
        var units: [String: [Node]] = [:]
        var defaultIDs: [String] = []
        var lastID: String?
        for node in nodes {
            if let id = node.id {
                units[id] = [node]
                defaultIDs.append(id)
                lastID = id
            } else if case .alternate = node, let lastID {
                units[lastID, default: []].append(node)
            }
        }
        var queue = mergedOrder(defaultIDs: defaultIDs, stored: stored)[...]
        var result: [Node] = []
        for node in nodes {
            if node.id != nil, let next = queue.popFirst(), let unit = units[next] {
                result += unit
            } else if node.id == nil, !node.isAlternate {
                result.append(node)
            }
        }
        return result
    }

    /// The stored order with IDs that no longer exist dropped and new ones inserted next to their
    /// nearest neighbour in the default order (after the one before, else before the one after).
    static func mergedOrder(defaultIDs: [String], stored: [String]) -> [String] {
        let known = Set(defaultIDs)
        var result: [String] = []
        for id in stored where known.contains(id) && !result.contains(id) {
            result.append(id)
        }
        for (index, id) in defaultIDs.enumerated() where !result.contains(id) {
            if let previous = defaultIDs[..<index].last(where: result.contains), let position = result.firstIndex(of: previous) {
                result.insert(id, at: position + 1)
            } else if let following = defaultIDs[(index + 1)...].first(where: result.contains), let position = result.firstIndex(of: following) {
                result.insert(id, at: position)
            } else {
                result.append(id)
            }
        }
        return result
    }

    /// Without hidden items (an alternate goes with its primary). Never removes Settings… or Quit.
    static func removingHidden(_ nodes: [Node], hidden: Set<String>) -> [Node] {
        guard !hidden.isEmpty else { return nodes }
        var result: [Node] = []
        var skippingAlternates = false
        for node in nodes {
            if case .alternate = node {
                if !skippingAlternates { result.append(node) }
                continue
            }
            skippingAlternates = false
            if let id = node.id, hidden.contains(id), !MenuCustomization.locked.contains(id) {
                skippingAlternates = true
                continue
            }
            switch node {
            case let .submenu(id, title, symbol, children, collapses):
                result.append(.submenu(id: id, title: title, symbol: symbol, children: removingHidden(children, hidden: hidden), collapses: collapses))
            case let .section(id, title, children):
                result.append(.section(id: id, title: title, children: removingHidden(children, hidden: hidden)))
            default:
                result.append(node)
            }
        }
        return result
    }

    /// Every ID a customization can refer to, parents included.
    static func customizableIDs(in nodes: [Node]) -> [String] {
        nodes.flatMap { node in (node.id.map { [$0] } ?? []) + customizableIDs(in: node.children) }
    }
}

extension MenuLayout.Node {
    var isAlternate: Bool {
        if case .alternate = self { return true }
        return false
    }
}
