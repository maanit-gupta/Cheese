/// One element of an accessibility tree, as the walker sees it. `LiveAXNode` wraps `AXUIElement`;
/// tests use in-memory trees.
protocol TerminalAXNode: Hashable {
    /// A string attribute such as `AXRole`, `AXValue`, `AXSelectedText`, `AXDescription`.
    func string(_ attribute: String) -> String?
    /// `AXDOMClassList` (web content only, empty elsewhere).
    var domClasses: [String] { get }
    var children: [Self] { get }
    var parent: Self? { get }
}

/// What the walker found in a terminal host's accessibility tree.
struct TerminalTreeSnapshot: Equatable, Sendable {
    /// Text the user selected in the terminal.
    var selection: String?
    /// The terminal's text (scrollback or visible rows).
    var buffer: String?
    /// Keyboard focus is in a terminal (always the case in a standalone terminal with a focused element).
    var isTerminalFocused: Bool

    static let empty = TerminalTreeSnapshot(selection: nil, buffer: nil, isTerminalFocused: false)

    /// The selection if there is one, else the buffer.
    var text: String? { selection ?? buffer }
}

/// Finds terminal text in an accessibility tree. Pure: cycle-safe, depth-bounded and capped, so a
/// huge or misbehaving tree can't stall Cheese.
enum TerminalTreeWalker {
    static let maxDepth = 12
    static let maxVisited = 4000
    static let maxAncestors = 10

    /// Roles that can hold a terminal (never buttons, tabs or labels that merely say "Terminal").
    static let containerRoles: Set<String> = [
        "AXGroup", "AXList", "AXScrollArea", "AXTextArea", "AXWebArea", "AXSplitGroup", "AXLayoutArea",
    ]

    static func snapshot<Node: TerminalAXNode>(focused: Node?, window: Node?, kind: TerminalHostKind) -> TerminalTreeSnapshot {
        var found: (container: Node, text: String?)?
        var focusedSelection: String?
        if let focused {
            found = terminalAncestor(of: focused)
            focusedSelection = selection(of: focused)
        }
        switch kind {
        case .integrated:
            if let found {
                let selection = focusedSelection ?? selection(under: found.container)
                return TerminalTreeSnapshot(selection: selection, buffer: found.text, isTerminalFocused: true)
            }
            // The terminal panel may be open without focus (the editor has it): read it, but never the
            // editor's own text.
            var buffer: String?
            if let window { buffer = firstTerminalText(under: window) }
            return TerminalTreeSnapshot(selection: nil, buffer: buffer, isTerminalFocused: false)
        case .standalone:
            var buffer = found?.text
            if buffer == nil, let focused {
                buffer = nonBlank(focused.string("AXValue")) ?? rows(under: focused)
            }
            if buffer == nil, let window {
                buffer = longestTextArea(under: window)
            }
            return TerminalTreeSnapshot(selection: focusedSelection, buffer: buffer, isTerminalFocused: focused != nil)
        }
    }

    /// Whether a node is a terminal container: a container role whose label, identifier or DOM classes
    /// mention a terminal or xterm.js.
    static func looksLikeTerminal<Node: TerminalAXNode>(_ node: Node) -> Bool {
        guard let role = node.string("AXRole"), containerRoles.contains(role) else { return false }
        let labels = ["AXDescription", "AXTitle", "AXIdentifier"].compactMap { node.string($0) } + node.domClasses
        return labels.contains { label in
            let lower = label.lowercased()
            return lower.contains("terminal") || lower.contains("xterm")
        }
    }

    /// The nearest terminal-looking ancestor (or the node itself) that holds text; else the nearest one
    /// at all (focused but empty).
    static func terminalAncestor<Node: TerminalAXNode>(of node: Node) -> (container: Node, text: String?)? {
        var seen: Set<Node> = []
        var current: Node? = node
        var firstMatch: Node?
        while let candidate = current, seen.count < maxAncestors, seen.insert(candidate).inserted {
            if looksLikeTerminal(candidate) {
                if let text = text(in: candidate) { return (candidate, text) }
                if firstMatch == nil { firstMatch = candidate }
            }
            current = candidate.parent
        }
        return firstMatch.map { ($0, nil) }
    }

    /// A terminal container's text: its own value if it's a text area, else the longer of its xterm.js
    /// rows (one static text per row) and its longest text area.
    static func text<Node: TerminalAXNode>(in node: Node) -> String? {
        if node.string("AXRole") == "AXTextArea", let value = nonBlank(node.string("AXValue")) { return value }
        let candidates = [rows(under: node), longestTextArea(under: node)].compactMap { $0 }
        return candidates.max { $0.count < $1.count }
    }

    static func selection<Node: TerminalAXNode>(of node: Node) -> String? {
        nonBlank(node.string("AXSelectedText"))
    }

    static func selection<Node: TerminalAXNode>(under root: Node) -> String? {
        var result: String?
        visit(root, depthFirst: false) { node in
            guard result == nil else { return false }
            result = selection(of: node)
            return result == nil
        }
        return result
    }

    /// Static text values under `root` in reading order, one per line.
    static func rows<Node: TerminalAXNode>(under root: Node) -> String? {
        var rows: [String] = []
        visit(root, depthFirst: true) { node in
            if node.string("AXRole") == "AXStaticText", let value = node.string("AXValue") { rows.append(value) }
            return true
        }
        return nonBlank(rows.joined(separator: "\n"))
    }

    static func longestTextArea<Node: TerminalAXNode>(under root: Node) -> String? {
        var longest: String?
        visit(root, depthFirst: false) { node in
            if node.string("AXRole") == "AXTextArea", let value = nonBlank(node.string("AXValue")),
               value.count > (longest?.count ?? 0) {
                longest = value
            }
            return true
        }
        return longest
    }

    /// The text of the shallowest terminal container under `root` that has any.
    static func firstTerminalText<Node: TerminalAXNode>(under root: Node) -> String? {
        var result: String?
        visit(root, depthFirst: false) { node in
            guard result == nil else { return false }
            if looksLikeTerminal(node) { result = text(in: node) }
            return result == nil
        }
        return result
    }

    /// Visits `root` and its descendants once each (cycle-safe), no deeper than `maxDepth` and no more
    /// than `maxVisited` nodes. Depth-first keeps reading order; breadth-first finds shallow matches
    /// first. `body` returns false to stop.
    static func visit<Node: TerminalAXNode>(_ root: Node, depthFirst: Bool, _ body: (Node) -> Bool) {
        var pending: [(node: Node, depth: Int)] = [(root, 0)]
        var head = 0
        var seen: Set<Node> = []
        while seen.count < maxVisited {
            let next: (node: Node, depth: Int)
            if depthFirst {
                guard let last = pending.popLast() else { return }
                next = last
            } else {
                guard head < pending.count else { return }
                next = pending[head]
                head += 1
            }
            guard seen.insert(next.node).inserted else { continue }
            guard body(next.node) else { return }
            guard next.depth < maxDepth else { continue }
            let children = next.node.children.map { (node: $0, depth: next.depth + 1) }
            pending += depthFirst ? children.reversed() : children
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        return text
    }
}
