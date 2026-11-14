/// The menu bar menu's shape: what goes where, and what's left once disabled modules' actions are
/// taken out. Pure, so the rules (a submenu with one item becomes a plain item, an empty one
/// disappears, separators never double up) are unit-tested without AppKit.
enum MenuLayout {
    indirect enum Node: Equatable {
        /// An action. `fullTitle` is set when a one-item submenu collapsed into its parent, so
        /// "Indefinitely" reads "Caffeinate: Indefinitely" once it's no longer under Caffeinate.
        case action(ActionID, keyEquivalent: String = "", fullTitle: Bool = false)
        /// Shown in place of the item before it while Option is held, like "Clear All…" for "Clear History".
        case alternate(ActionID)
        /// A submenu. One that `collapses` turns into its only item when the others are gone; one that
        /// doesn't stays a submenu as long as it has anything in it (Tools ▸ Mode ▸ Sweep). `id` is
        /// stable and never shown, so a customized order survives renames.
        case submenu(id: String, title: String, symbol: String, children: [Node], collapses: Bool = true)
        /// A headed group inside a submenu (Files ▸ PDF / Convert / Images): drawn as a separator, its
        /// header and its items; reordered as a whole.
        case section(id: String, title: String, children: [Node])
        case header(String)
        case separator

        /// The ID a customization refers to: an action's raw value, or a submenu's or section's own ID.
        /// Alternates, headers and separators have none: they go where their item or slot goes.
        var id: String? {
            switch self {
            case let .action(id, _, _): id.rawValue
            case let .submenu(id, _, _, _, _), let .section(id, _, _): id
            case .alternate, .header, .separator: nil
            }
        }

        var children: [Node] {
            switch self {
            case let .submenu(_, _, _, children, _), let .section(_, _, children): children
            default: []
            }
        }
    }

    /// The whole menu: what can be arranged, then the footer.
    static let standard: [Node] = body + footer

    /// The grouped menu: the verbs the user reaches for, one level deep where it can be. Everything
    /// here can be reordered within its parent and hidden (Settings → Menu).
    static let body: [Node] = [
        .action(.openHistory),
        // Right under Clipboard History, and only while a link is on the clipboard.
        .action(.copyCleanLink),
        .submenu(id: "capture", title: "Capture", symbol: "camera.viewfinder", children: [
            .action(.captureRegion),
            .action(.captureWindow),
            .action(.captureFullScreen),
            .action(.ocrRegion),
            .action(.scrollingCapture),
            .separator,
            .action(.recordRegion),
            .action(.recordFullScreen),
            .action(.stopRecording),
            .separator,
            .submenu(id: "afterCapture", title: "After Capture", symbol: "tray.and.arrow.down", children: CaptureDestination.allCases.map {
                .action(.captureDestination($0))
            } + [.separator, .action(.addToPhotos)]),
        ]),
        .action(.drawOnScreen),
        .submenu(id: "files", title: "Files", symbol: "doc.on.doc", children: filesChildren),
        .action(.showShare),
        .action(.toggleShelf),
        // These act on other apps' windows. Opening this menu doesn't activate Cheese, so the
        // frontmost window is still the one the user was working in.
        .submenu(id: "windows", title: "Windows", symbol: "macwindow.on.rectangle", children: [
            .action(.fillAllWindows), .action(.fillCurrentWindow), .action(.restoreAllWindows),
            .separator,
            .action(.snapLeft), .action(.snapRight), .action(.maximize), .action(.snapBottom), .action(.restoreWindow),
        ]),
        .submenu(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver", children: [
            .action(.autoKillPanel),
            .action(.killAllApps),
            .separator,
            .action(.showClipboardQR),
            // "terminalTrace" is the Copy Now action's ID, so the submenu has its own.
            .submenu(id: "terminalTraceMenu", title: "Terminal Trace", symbol: "terminal", children: [
                .action(.terminalTrace),
                .separator,
            ] + TerminalTraceScope.allCases.map { .action(.terminalTraceScope($0)) }),
            .submenu(id: "hush", title: "Hush", symbol: "bell.slash", children: hush, collapses: false),
            .separator,
            // Modes that take over the Mac for a while. Kept as a submenu even with one mode in it.
            .submenu(id: "mode", title: "Mode", symbol: "switch.2", children: [
                .action(.sweep),
            ], collapses: false),
        ]),
        // Keeping the Mac awake, lid open or closed, in one menu of its own.
        .submenu(id: "caffeinate", title: "Caffeinate", symbol: "cup.and.saucer", children: CaffeinatePreset.allCases.map {
            .action(.caffeinate($0))
        } + [
            .action(.caffeinateUntil), .action(.caffeinateIndefinitely),
            .separator,
            .action(.caffeinateLidClosed),
            .separator,
            .action(.caffeinateOff),
        ]),
    ]

    /// Always at the bottom, in this order. Clear History (with Clear All… under ⌥), the update items
    /// and Edit Menu… can be hidden; the version header, Settings… and Quit can't.
    static let footer: [Node] = [
        .separator,
        .action(.clearHistory),
        .alternate(.clearAll),
        .separator,
        // The running version, then whichever of the two update items applies.
        .header(Brand.versionTitle),
        .action(.checkForUpdates),
        .action(.installUpdate),
        .action(.editMenu),
        .action(.openSettings, keyEquivalent: ","),
        .action(.quit, keyEquivalent: "q"),
    ]

    /// Footer items that can be hidden.
    static let hideableFooter: [ActionID] = [.clearHistory, .checkForUpdates, .installUpdate, .editMenu]

    /// Tools ▸ Hush: what's happening, the automatic toggle, the lengths, Turn Off.
    static let hush: [Node] = [
        .action(.hushStatus),
        .separator,
        .action(.hushAutomatically),
        .separator,
    ] + CaffeinatePreset.allCases.map { .action(.hush($0)) } + [
        .action(.hushUntil), .action(.hushIndefinitely),
        .separator,
        .action(.hushOff),
        .separator,
        .action(.hushSettings),
    ]

    /// Every Files tool in a PDF / Convert / Images section, in the drop menu's order.
    static var filesChildren: [Node] {
        ToolApplicability.grouped(ToolID.allCases).map { group in
            .section(id: "files.\(group.group.rawValue)", title: group.group.title, children: group.tools.map { .action(.files($0)) })
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
            case let .submenu(id, title, symbol, children, collapses):
                let visibleChildren = visible(children, isAvailable: isAvailable)
                let items = visibleChildren.filter(\.isItem)
                if items.count > 1 || (!collapses && !items.isEmpty) {
                    kept.append(.submenu(id: id, title: title, symbol: symbol, children: visibleChildren, collapses: collapses))
                } else if let only = items.first {
                    kept.append(only.collapsed)
                }
            case let .section(_, title, children):
                // A separator (dropped if it would lead), the header, then the items.
                kept += [.separator, .header(title)] + visible(children, isAvailable: isAvailable)
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
            case let .submenu(_, _, _, children, _), let .section(_, _, children): actionIDs(in: children)
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
        case .action, .alternate, .submenu, .section: true
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
