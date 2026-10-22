/// The menu bar menu's shape: what goes where, and what's left once disabled modules' actions are
/// taken out. Pure, so the rules (a submenu with one item becomes a plain item, an empty one
/// disappears, separators never double up) are unit-tested without AppKit.
enum MenuLayout {
    indirect enum Node: Equatable {
        /// An action. `fullTitle` is set when a one-item submenu collapsed into its parent, so
        /// "Indefinitely" reads "Keep Awake: Indefinitely" once it's no longer under Keep Awake.
        case action(ActionID, keyEquivalent: String = "", fullTitle: Bool = false)
        /// Shown in place of the item before it while Option is held, like "Clear All…" for "Clear History".
        case alternate(ActionID)
        case submenu(title: String, symbol: String, children: [Node])
        case header(String)
        case separator
    }

    /// The grouped menu: the verbs the user reaches for, one level deep where it can be.
    static let standard: [Node] = [
        .action(.openHistory),
        .submenu(title: "Capture", symbol: "camera.viewfinder", children: [
            .action(.captureRegion),
            .action(.captureWindow),
            .action(.captureFullScreen),
            .action(.ocrRegion),
            .action(.scrollingCapture),
        ]),
        .action(.drawOnScreen),
        .submenu(title: "Files", symbol: "doc.on.doc", children: filesChildren),
        .action(.showShare),
        .action(.toggleShelf),
        // These act on other apps' windows. Opening this menu doesn't activate Cheese, so the
        // frontmost window is still the one the user was working in.
        .submenu(title: "Windows", symbol: "macwindow.on.rectangle", children: [
            .action(.fillAllWindows), .action(.fillCurrentWindow), .action(.restoreAllWindows),
            .separator,
            .action(.snapLeft), .action(.snapRight), .action(.maximize), .action(.snapBottom), .action(.restoreWindow),
        ]),
        .submenu(title: "Tools", symbol: "wrench.and.screwdriver", children: [
            .action(.autoKillPanel),
            .action(.killAllApps),
            .separator,
            .action(.showClipboardQR),
            .submenu(title: "Keep Awake", symbol: "cup.and.saucer", children: [
                .action(.keepAwakeIndefinitely), .action(.keepAwakeUntil), .action(.keepAwakeOff),
            ]),
        ]),
        .separator,
        .action(.clearHistory),
        .alternate(.clearAll),
        .action(.openSettings, keyEquivalent: ","),
        .action(.quit, keyEquivalent: "q"),
    ]

    /// Every Files tool under PDF / Convert / Images headers, in the drop menu's order.
    static var filesChildren: [Node] {
        ToolApplicability.grouped(ToolID.allCases).enumerated().flatMap { index, group -> [Node] in
            (index > 0 ? [.separator] : []) + [.header(group.group.title)] + group.tools.map { .action(.files($0)) }
        }
    }

    /// `nodes` without unavailable actions, and tidied: submenus left with one action become that
    /// action, empty ones disappear, headers with nothing under them go, and separators never lead,
    /// trail or double up.
    static func visible(_ nodes: [Node], isAvailable: (ActionID) -> Bool) -> [Node] {
        var kept: [Node] = []
        for node in nodes {
            switch node {
            case let .action(id, _, _), let .alternate(id):
                if isAvailable(id) {
                    kept.append(node)
                }
            case let .submenu(title, symbol, children):
                let visibleChildren = visible(children, isAvailable: isAvailable)
                let items = visibleChildren.filter(\.isItem)
                if items.count > 1 {
                    kept.append(.submenu(title: title, symbol: symbol, children: visibleChildren))
                } else if let only = items.first {
                    kept.append(only.collapsed)
                }
            case .header, .separator:
                kept.append(node)
            }
        }
        return tidied(kept)
    }

    /// Every action a layout can show, submenus included.
    static func actionIDs(in nodes: [Node]) -> [ActionID] {
        nodes.flatMap { node -> [ActionID] in
            switch node {
            case let .action(id, _, _), let .alternate(id): [id]
            case let .submenu(_, _, children): actionIDs(in: children)
            case .header, .separator: []
            }
        }
    }

    /// Drops alternates whose primary is gone, headers with no items after them, and stray separators.
    private static func tidied(_ nodes: [Node]) -> [Node] {
        var result: [Node] = []
        for (index, node) in nodes.enumerated() {
            switch node {
            case .alternate:
                // An alternate only shows by standing in for the item right before it.
                guard let previous = result.last, previous.isPrimaryItem else {
                    // Without its primary, it's an ordinary item.
                    if case let .alternate(id) = node { result.append(.action(id)) }
                    continue
                }
                result.append(node)
            case .header:
                let rest = nodes[(index + 1)...]
                let hasItems = rest.prefix { !$0.isSectionBreak }.contains(where: \.isItem)
                if hasItems { result.append(node) }
            case .separator:
                if let last = result.last, !last.isSeparator {
                    result.append(node)
                }
            default:
                result.append(node)
            }
        }
        while result.last?.isSeparator == true {
            result.removeLast()
        }
        return result
    }
}

private extension MenuLayout.Node {
    var isItem: Bool {
        switch self {
        case .action, .alternate, .submenu: true
        case .header, .separator: false
        }
    }

    var isPrimaryItem: Bool {
        if case .action = self { return true }
        return false
    }

    var isSeparator: Bool {
        self == .separator
    }

    var isSectionBreak: Bool {
        switch self {
        case .header, .separator: true
        default: false
        }
    }

    /// How the only item of a submenu appears once it stands in for the submenu.
    var collapsed: MenuLayout.Node {
        switch self {
        case let .action(id, keyEquivalent, _): .action(id, keyEquivalent: keyEquivalent, fullTitle: true)
        case let .alternate(id): .action(id, fullTitle: true)
        default: self
        }
    }
}
